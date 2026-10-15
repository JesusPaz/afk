package relay

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"github.com/JesusPaz/afk/server/internal/store"
	"github.com/coder/websocket"
)

type Message struct {
	Type      string          `json:"type"`
	ClientID  string          `json:"clientID,omitempty"`
	SessionID string          `json:"sessionID,omitempty"`
	Epoch     uint64          `json:"epoch,omitempty"`
	Sequence  uint64          `json:"sequence,omitempty"`
	Data      string          `json:"data,omitempty"`
	Columns   int             `json:"columns,omitempty"`
	Rows      int             `json:"rows,omitempty"`
	Owner     string          `json:"owner,omitempty"`
	Name      string          `json:"name,omitempty"`
	Sessions  json.RawMessage `json:"sessions,omitempty"`
	Message   string          `json:"message,omitempty"`
}
type peer struct {
	identity store.Identity
	ws       *websocket.Conn
	out      chan Message
	ctx      context.Context
	cancel   context.CancelFunc
}
type room struct {
	host    *peer
	clients map[string]*peer
}
type Hub struct {
	mu    sync.Mutex
	rooms map[string]*room
}

func NewHub() *Hub { return &Hub{rooms: map[string]*room{}} }
func (p *peer) send(m Message) {
	select {
	case <-p.ctx.Done():
	case p.out <- m:
	default:
		p.cancel()
	}
}
func (h *Hub) add(p *peer) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	r := h.rooms[p.identity.HostID]
	if r == nil {
		r = &room{clients: map[string]*peer{}}
		h.rooms[p.identity.HostID] = r
	}
	if p.identity.Role == "host" {
		if r.host != nil {
			r.host.cancel()
		}
		r.host = p
		p.send(Message{Type: "welcome"})
		for id, c := range r.clients {
			c.send(Message{Type: "hostOnline"})
			p.send(Message{Type: "clientConnected", ClientID: id})
		}
	} else {
		if len(r.clients) >= 8 && r.clients[p.identity.ID] == nil {
			return false
		}
		if old := r.clients[p.identity.ID]; old != nil {
			old.cancel()
			if r.host != nil {
				r.host.send(Message{Type: "clientDisconnected", ClientID: p.identity.ID})
			}
		}
		r.clients[p.identity.ID] = p
		p.send(Message{Type: "welcome", ClientID: p.identity.ID})
		if r.host != nil {
			r.host.send(Message{Type: "clientConnected", ClientID: p.identity.ID})
			p.send(Message{Type: "hostOnline"})
		} else {
			p.send(Message{Type: "hostOffline"})
		}
	}
	return true
}
func (h *Hub) remove(p *peer) {
	h.mu.Lock()
	defer h.mu.Unlock()
	r := h.rooms[p.identity.HostID]
	if r == nil {
		return
	}
	if p.identity.Role == "host" && r.host == p {
		r.host = nil
		for _, c := range r.clients {
			c.send(Message{Type: "hostOffline"})
		}
	}
	if p.identity.Role == "client" && r.clients[p.identity.ID] == p {
		delete(r.clients, p.identity.ID)
		if r.host != nil {
			r.host.send(Message{Type: "clientDisconnected", ClientID: p.identity.ID})
		}
	}
	if r.host == nil && len(r.clients) == 0 {
		delete(h.rooms, p.identity.HostID)
	}
}
func (h *Hub) Revoke(hostID, clientID string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if r := h.rooms[hostID]; r != nil {
		if p := r.clients[clientID]; p != nil {
			p.cancel()
		}
	}
}
func (h *Hub) Close() {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, r := range h.rooms {
		if r.host != nil {
			r.host.cancel()
		}
		for _, p := range r.clients {
			p.cancel()
		}
	}
}
func (h *Hub) route(p *peer, m Message) {
	h.mu.Lock()
	defer h.mu.Unlock()
	r := h.rooms[p.identity.HostID]
	if r == nil || p.ctx.Err() != nil {
		return
	}
	if p.identity.Role == "client" {
		if r.clients[p.identity.ID] != p {
			return
		}
		switch m.Type {
		case "list", "attach", "claim", "release", "renew", "input", "resize", "create", "terminate":
		default:
			p.cancel()
			return
		}
		m.ClientID = p.identity.ID // Never trust a caller-supplied identity.
		if r.host != nil {
			r.host.send(m)
		} else {
			p.send(Message{Type: "hostOffline"})
		}
		return
	}
	if r.host != p {
		return
	}
	switch m.Type {
	case "sessions", "snapshot", "output", "control", "exit", "error":
	default:
		p.cancel()
		return
	}
	if m.ClientID != "" {
		if c := r.clients[m.ClientID]; c != nil {
			c.send(m)
		}
	} else {
		for _, c := range r.clients {
			c.send(m)
		}
	}
}
func (h *Hub) Serve(ctx context.Context, ws *websocket.Conn, id store.Identity, validate func() bool) {
	ctx, cancel := context.WithCancel(ctx)
	p := &peer{identity: id, ws: ws, out: make(chan Message, 16), ctx: ctx, cancel: cancel}
	defer cancel()
	defer ws.CloseNow()
	if !h.add(p) {
		return
	}
	defer h.remove(p)
	// Recheck after joining: revocation either sees this socket or this check sees revocation.
	if !validate() {
		return
	}
	ws.SetReadLimit(512 * 1024)
	go func() {
		defer cancel()
		for {
			select {
			case <-ctx.Done():
				return
			case m := <-p.out:
				b, err := json.Marshal(m)
				if err != nil {
					return
				}
				wctx, stop := context.WithTimeout(ctx, 5*time.Second)
				err = ws.Write(wctx, websocket.MessageText, b)
				stop()
				if err != nil {
					return
				}
			}
		}
	}()
	go func() {
		ticker := time.NewTicker(25 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				pctx, stop := context.WithTimeout(ctx, 10*time.Second)
				err := ws.Ping(pctx)
				stop()
				if err != nil {
					cancel()
					return
				}
			}
		}
	}()
	for {
		kind, b, err := ws.Read(ctx)
		if err != nil {
			return
		}
		if kind != websocket.MessageText {
			return
		}
		var m Message
		if json.Unmarshal(b, &m) != nil {
			return
		}
		h.route(p, m)
	}
}
