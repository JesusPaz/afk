package relay

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/JesusPaz/afk/server/internal/store"
	"github.com/coder/websocket"
)

type Server struct {
	Store       *store.Store
	Hub         *Hub
	Tunnels     *Tunnels
	AllowLegacy bool
	mu          sync.Mutex
	attempts    map[string]bucket
}
type bucket struct {
	start time.Time
	count int
}

func New(s *store.Store) *Server {
	return &Server{Store: s, Hub: NewHub(), Tunnels: NewTunnels(), attempts: map[string]bucket{}}
}
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func fail(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}
func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 8192)
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if d.Decode(v) != nil || d.Decode(new(any)) != io.EOF {
		fail(w, 400, "invalid request")
		return false
	}
	return true
}
func (s *Server) allowed(r *http.Request) bool {
	ip, _, _ := net.SplitHostPort(r.RemoteAddr)
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	for k, v := range s.attempts {
		if now.Sub(v.start) > time.Minute {
			delete(s.attempts, k)
		}
	}
	b := s.attempts[ip]
	if b.start.IsZero() {
		if len(s.attempts) >= 4096 {
			return false
		}
		b.start = now
	}
	b.count++
	s.attempts[ip] = b
	return b.count <= 30
}
func (s *Server) identity(w http.ResponseWriter, r *http.Request, role string) (store.Identity, bool) {
	value := r.Header.Get("Authorization")
	if !strings.HasPrefix(value, "Bearer ") || len(value) > 256 {
		fail(w, 401, "unauthorized")
		return store.Identity{}, false
	}
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	id, err := s.Store.Authenticate(ctx, strings.TrimPrefix(value, "Bearer "))
	if err != nil {
		if errors.Is(err, store.ErrUnauthorized) {
			fail(w, 401, "unauthorized")
		} else {
			fail(w, 503, "identity store unavailable")
		}
		return id, false
	}
	if role != "" && id.Role != role {
		fail(w, 403, "forbidden")
		return id, false
	}
	return id, true
}
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, map[string]int{"protocol": 2}) })
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), time.Second)
		defer cancel()
		if s.Store.DB.Ping(ctx) != nil {
			fail(w, 503, "not ready")
			return
		}
		writeJSON(w, 200, map[string]bool{"ready": true})
	})
	registerHost := func(w http.ResponseWriter, r *http.Request) {
		var b struct {
			ID    string `json:"id"`
			Name  string `json:"name"`
			Token string `json:"token"`
		}
		if !decode(w, r, &b) {
			return
		}
		if len(b.ID) != 36 || len(b.Token) < 40 || len(b.Token) > 128 || len(b.Name) == 0 || len(b.Name) > 80 {
			fail(w, 400, "invalid registration")
			return
		}
		h, err := s.Store.Register(r.Context(), b.ID, b.Name, b.Token)
		if errors.Is(err, store.ErrUnauthorized) {
			fail(w, 401, "unauthorized")
			return
		}
		if err != nil {
			fail(w, 503, "registration unavailable")
			return
		}
		writeJSON(w, 200, h)
	}
	mux.HandleFunc("POST /v1/hosts", registerHost)
	mux.HandleFunc("POST /v2/hosts", registerHost)
	mux.HandleFunc("POST /v1/pairing", func(w http.ResponseWriter, r *http.Request) {
		id, ok := s.identity(w, r, "host")
		if !ok {
			return
		}
		p, err := s.Store.NewPairing(r.Context(), id.ID)
		if err != nil {
			fail(w, 503, "pairing unavailable")
			return
		}
		writeJSON(w, 200, p)
	})
	mux.HandleFunc("POST /v1/pair", func(w http.ResponseWriter, r *http.Request) {
		var b struct {
			Code   string `json:"code"`
			Secret string `json:"secret"`
			Name   string `json:"name"`
		}
		if !decode(w, r, &b) {
			return
		}
		if len(b.Code) > 16 || len(b.Secret) > 128 || len(b.Name) > 80 || b.Name == "" {
			fail(w, 400, "invalid pairing")
			return
		}
		c, err := s.Store.Pair(r.Context(), strings.ToUpper(strings.ReplaceAll(b.Code, " ", "")), b.Secret, b.Name)
		if errors.Is(err, store.ErrUnauthorized) {
			fail(w, 401, "invalid or expired pairing")
			return
		}
		if err != nil {
			fail(w, 503, "pairing unavailable")
			return
		}
		writeJSON(w, 200, c)
	})
	mux.HandleFunc("GET /v1/clients", func(w http.ResponseWriter, r *http.Request) {
		id, ok := s.identity(w, r, "host")
		if !ok {
			return
		}
		c, err := s.Store.Clients(r.Context(), id.ID)
		if err != nil {
			fail(w, 503, "devices unavailable")
			return
		}
		writeJSON(w, 200, c)
	})
	revokeClient := func(w http.ResponseWriter, r *http.Request) {
		id, ok := s.identity(w, r, "host")
		if !ok {
			return
		}
		clientID := r.PathValue("id")
		if s.Store.Revoke(r.Context(), id.ID, clientID) != nil {
			fail(w, 503, "revocation unavailable")
			return
		}
		s.Hub.Revoke(id.ID, clientID)
		s.Tunnels.Revoke(id.ID, clientID)
		w.WriteHeader(204)
	}
	mux.HandleFunc("DELETE /v1/clients/{id}", revokeClient)
	mux.HandleFunc("DELETE /v2/clients/{id}", revokeClient)
	mux.HandleFunc("GET /v1/connect", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Origin") != "" {
			fail(w, 403, "native clients only")
			return
		}
		id, ok := s.identity(w, r, "")
		if !ok {
			return
		}
		ws, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		s.Hub.Serve(r.Context(), ws, id, func() bool {
			ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
			defer cancel()
			_, err := s.Store.Authenticate(ctx, strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
			return err == nil
		})
	})
	s.tunnelHandlers(mux)
	mux.HandleFunc("GET /metrics", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		m := &s.Tunnels.metrics
		values := []struct {
			name, kind, help string
			value            any
		}{
			{"afk_relay_requests_total", "counter", "HTTP requests including probes.", m.requests.Load()},
			{"afk_relay_host_connections", "gauge", "Connected host control channels.", m.connections.Load()},
			{"afk_relay_tunnels", "gauge", "Pending and active encrypted tunnels.", m.tunnels.Load()},
			{"afk_relay_frames_total", "counter", "Forwarded opaque binary frames.", m.frames.Load()},
			{"afk_relay_bytes_total", "counter", "Forwarded opaque payload bytes.", m.bytes.Load()},
			{"afk_relay_rejected_total", "counter", "Rejected malformed or capacity limited tunnel requests.", m.rejected.Load()},
		}
		for _, v := range values {
			fmt.Fprintf(w, "# HELP %s %s\n# TYPE %s %s\n%s %v\n", v.name, v.help, v.name, v.kind, v.name, v.value)
		}
	})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.Tunnels.metrics.requests.Add(1)
		if strings.HasPrefix(r.URL.Path, "/v1/") && !s.AllowLegacy {
			fail(w, 426, "protocol upgrade required")
			return
		}

		if r.URL.Path != "/healthz" && r.URL.Path != "/readyz" && r.URL.Path != "/metrics" && !s.allowed(r) {
			fail(w, 429, "too many requests")
			return
		}
		w.Header().Set("X-Content-Type-Options", "nosniff")
		mux.ServeHTTP(w, r)
	})
}
