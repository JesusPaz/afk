package relay

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/JesusPaz/afk/server/internal/store"
	"github.com/coder/websocket"
)

const tunnelFrameLimit = 64 * 1024

type relayMetrics struct {
	requests    atomic.Uint64
	connections atomic.Int64
	tunnels     atomic.Int64
	frames      atomic.Uint64
	bytes       atomic.Uint64
	rejected    atomic.Uint64
}
type tunnelOffer struct {
	Type     string `json:"type"`
	ID       string `json:"id"`
	ClientID string `json:"clientID"`
}
type controlPeer struct {
	offers chan tunnelOffer
	cancel context.CancelFunc
}
type tunnel struct {
	hostID, clientID string
	client           *websocket.Conn
	host             chan *websocket.Conn
	cancel           context.CancelFunc
	claimed          bool
	done             <-chan struct{}
}
type Tunnels struct {
	mu       sync.Mutex
	controls map[string]*controlPeer
	pending  map[string]*tunnel
	metrics  relayMetrics
}

func NewTunnels() *Tunnels {
	return &Tunnels{controls: map[string]*controlPeer{}, pending: map[string]*tunnel{}}
}
func (h *Tunnels) Close() {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, p := range h.controls {
		p.cancel()
	}
	for _, p := range h.pending {
		p.cancel()
	}
}
func (h *Tunnels) Revoke(host, client string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, p := range h.pending {
		if p.hostID == host && p.clientID == client {
			p.cancel()
		}
	}
}
func (h *Tunnels) control(ctx context.Context, ws *websocket.Conn, host string) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	defer ws.CloseNow()
	p := &controlPeer{offers: make(chan tunnelOffer, 16), cancel: cancel}
	h.mu.Lock()
	if len(h.controls) >= 64 && h.controls[host] == nil {
		h.mu.Unlock()
		h.metrics.rejected.Add(1)
		return
	}
	if old := h.controls[host]; old != nil {
		old.cancel()
	}
	// A new host generation cannot inherit any old TLS connection.
	for _, t := range h.pending {
		if t.hostID == host {
			t.cancel()
		}
	}
	h.controls[host] = p
	h.mu.Unlock()
	p.offers <- tunnelOffer{Type: "ready"}
	h.metrics.connections.Add(1)
	defer h.metrics.connections.Add(-1)
	defer func() {
		h.mu.Lock()
		defer h.mu.Unlock()
		if h.controls[host] == p {
			delete(h.controls, host)
			for _, t := range h.pending {
				if t.hostID == host {
					t.cancel()
				}
			}
		}
	}()
	ws.SetReadLimit(1024)
	// Control is server-to-host only. The reader also handles WebSocket ping/pong.
	go func() { defer cancel(); _, _, _ = ws.Read(ctx) }()
	ticker := time.NewTicker(25 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case offer := <-p.offers:
			b, _ := json.Marshal(offer)
			c, stop := context.WithTimeout(ctx, 5*time.Second)
			err := ws.Write(c, websocket.MessageText, b)
			stop()
			if err != nil {
				return
			}
		case <-ticker.C:
			c, stop := context.WithTimeout(ctx, 10*time.Second)
			err := ws.Ping(c)
			stop()
			if err != nil {
				return
			}
		}
	}
}
func (h *Tunnels) connect(ctx context.Context, ws *websocket.Conn, identity store.Identity, validate func() bool) {
	ctx, cancel := context.WithTimeout(ctx, 8*time.Hour)
	defer cancel()
	defer ws.CloseNow()
	var random [16]byte
	if _, err := rand.Read(random[:]); err != nil {
		return
	}
	id := hex.EncodeToString(random[:])
	t := &tunnel{hostID: identity.HostID, clientID: identity.ID, client: ws, host: make(chan *websocket.Conn, 1), cancel: cancel, done: ctx.Done()}
	h.mu.Lock()
	control := h.controls[t.hostID]
	count := 0
	for _, old := range h.pending {
		if old.hostID == t.hostID {
			count++
		}
		if old.hostID == t.hostID && old.clientID == t.clientID {
			old.cancel()
		}
	}
	if control == nil || count >= 8 || len(h.pending) >= 256 {
		h.mu.Unlock()
		h.metrics.rejected.Add(1)
		return
	}
	h.pending[id] = t
	select {
	case control.offers <- tunnelOffer{Type: "open", ID: id, ClientID: t.clientID}:
	default:
		delete(h.pending, id)
		h.mu.Unlock()
		h.metrics.rejected.Add(1)
		return
	}
	h.mu.Unlock()
	h.metrics.tunnels.Add(1)
	defer h.metrics.tunnels.Add(-1)
	defer func() { h.mu.Lock(); delete(h.pending, id); h.mu.Unlock() }()
	if !validate() {
		return
	}
	timer := time.NewTimer(15 * time.Second)
	defer timer.Stop()
	select {
	case host := <-t.host:
		defer host.CloseNow()
		ws.SetReadLimit(tunnelFrameLimit)
		host.SetReadLimit(tunnelFrameLimit)
		go func() {
			ticker := time.NewTicker(30 * time.Second)
			defer ticker.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-ticker.C:
					if !validate() {
						cancel()
						return
					}
					for _, peer := range []*websocket.Conn{host, ws} {
						ping, stop := context.WithTimeout(ctx, 10*time.Second)
						err := peer.Ping(ping)
						stop()
						if err != nil {
							cancel()
							return
						}
					}
				}
			}
		}()
		go h.copy(ctx, cancel, host, ws)
		h.copy(ctx, cancel, ws, host)
	case <-timer.C:
		h.metrics.rejected.Add(1)
	case <-ctx.Done():
	}
}
func (h *Tunnels) accept(ctx context.Context, w http.ResponseWriter, r *http.Request, identity store.Identity) {
	h.mu.Lock()
	t := h.pending[r.PathValue("id")]
	if t == nil || t.hostID != identity.ID || t.claimed {
		h.mu.Unlock()
		fail(w, 404, "channel unavailable")
		return
	}
	t.claimed = true
	h.mu.Unlock()
	ws, err := websocket.Accept(w, r, nil)
	if err != nil {
		t.cancel()
		return
	}
	defer ws.CloseNow()
	h.mu.Lock()
	active := h.pending[r.PathValue("id")] == t
	h.mu.Unlock()
	if !active {
		return
	}
	t.host <- ws
	// The connect handler owns both readers/writers until cancellation.
	select {
	case <-ctx.Done():
		t.cancel()
	case <-t.done:
	}
}
func (h *Tunnels) copy(ctx context.Context, cancel context.CancelFunc, dst, src *websocket.Conn) {
	defer cancel()
	window := time.Now()
	frames, bytes := 0, 0
	for {
		kind, b, err := src.Read(ctx)
		if err != nil {
			return
		}
		if time.Since(window) >= time.Second {
			window = time.Now()
			frames = 0
			bytes = 0
		}
		frames++
		bytes += len(b)
		if kind != websocket.MessageBinary || len(b) == 0 || len(b) > tunnelFrameLimit || frames > 256 || bytes > 4*1024*1024 {
			h.metrics.rejected.Add(1)
			return
		}
		c, stop := context.WithTimeout(ctx, 5*time.Second)
		err = dst.Write(c, websocket.MessageBinary, b)
		stop()
		if err != nil {
			return
		}
		h.metrics.frames.Add(1)
		h.metrics.bytes.Add(uint64(len(b)))
	}
}

func (s *Server) tunnelIdentity(w http.ResponseWriter, r *http.Request, role string) (store.Identity, bool) {
	if r.Header.Get("Origin") != "" {
		fail(w, 403, "native clients only")
		return store.Identity{}, false
	}
	return s.identity(w, r, role)
}
func (s *Server) tunnelHandlers(mux *http.ServeMux) {
	mux.HandleFunc("GET /v2/control", func(w http.ResponseWriter, r *http.Request) {
		id, ok := s.tunnelIdentity(w, r, "host")
		if !ok {
			return
		}
		ws, err := websocket.Accept(w, r, nil)
		if err == nil {
			s.Tunnels.control(r.Context(), ws, id.ID)
		}
	})
	mux.HandleFunc("GET /v2/connect", func(w http.ResponseWriter, r *http.Request) {
		id, ok := s.tunnelIdentity(w, r, "client")
		if !ok {
			return
		}
		ws, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		s.Tunnels.connect(r.Context(), ws, id, func() bool {
			c, stop := context.WithTimeout(r.Context(), 3*time.Second)
			defer stop()
			_, err := s.Store.Authenticate(c, r.Header.Get("Authorization")[7:])
			return err == nil
		})
	})
	mux.HandleFunc("GET /v2/accept/{id}", func(w http.ResponseWriter, r *http.Request) {
		id, ok := s.tunnelIdentity(w, r, "host")
		if ok {
			s.Tunnels.accept(r.Context(), w, r, id)
		}
	})
	mux.HandleFunc("POST /v2/clients", func(w http.ResponseWriter, r *http.Request) {
		var b struct {
			ID    string `json:"id"`
			Token string `json:"token"`
			Code  string `json:"code"`
			Name  string `json:"name"`
		}
		if !decode(w, r, &b) {
			return
		}
		if len(b.ID) != 36 || len(b.Token) < 40 || len(b.Token) > 128 || len(b.Code) > 16 || len(b.Name) == 0 || len(b.Name) > 80 {
			fail(w, 400, "invalid registration")
			return
		}
		host, err := s.Store.RegisterClient(r.Context(), b.ID, b.Token, b.Code, b.Name)
		if errors.Is(err, store.ErrUnauthorized) {
			fail(w, 401, "unauthorized")
			return
		}
		if err != nil {
			fail(w, 503, "registration unavailable")
			return
		}
		writeJSON(w, 200, host)
	})
}
