package relay

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/JesusPaz/afk/server/internal/store"
	"github.com/JesusPaz/afk/server/migrations"
	"github.com/coder/websocket"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestV2OpaqueTunnel(t *testing.T) {
	database := os.Getenv("AFK_TEST_DATABASE_URL")
	if database == "" {
		t.Skip("requires PostgreSQL")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	db, err := pgxpool.New(ctx, database)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err = migrations.Apply(ctx, db); err != nil {
		t.Fatal(err)
	}
	st := &store.Store{DB: db}
	app := New(st)
	srv := httptest.NewServer(app.Handler())
	defer srv.Close()
	defer app.Tunnels.Close()
	defer app.Hub.Close()
	hostToken := store.RandomToken(32)
	hostID := store.RandomToken(27)
	host, err := st.Register(ctx, hostID, "v2 test", hostToken)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Exec(context.Background(), "DELETE FROM hosts WHERE id=$1", hostID)
	clientToken, clientID := store.RandomToken(32), store.RandomToken(27)
	if _, err = st.RegisterClient(ctx, clientID, clientToken, host.Code, "phone"); err != nil {
		t.Fatal(err)
	}
	if _, err = st.RegisterClient(ctx, clientID, "different", host.Code, "phone"); err == nil {
		t.Fatal("accepted changed token")
	}
	dial := func(path, token string) *websocket.Conn {
		t.Helper()
		headers := http.Header{}
		headers.Set("Authorization", "Bearer "+token)
		ws, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(srv.URL, "http")+path, &websocket.DialOptions{HTTPHeader: headers})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { ws.CloseNow() })
		return ws
	}
	control := dial("/v2/control", hostToken)
	_, b, err := control.Read(ctx)
	if err != nil || !bytes.Contains(b, []byte("ready")) {
		t.Fatal("control not ready", err)
	}
	client := dial("/v2/connect", clientToken)
	_, b, err = control.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var offer tunnelOffer
	if err = json.Unmarshal(b, &offer); err != nil {
		t.Fatal(err)
	}
	if offer.ClientID != clientID || len(offer.ID) != 32 {
		t.Fatal("wrong channel offer")
	}
	// Client bearer cannot accept a host-side channel.
	req, _ := http.NewRequestWithContext(ctx, "GET", srv.URL+"/v2/accept/"+offer.ID, nil)
	req.Header.Set("Authorization", "Bearer "+clientToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 403 {
		t.Fatalf("client accepted as host: %d", resp.StatusCode)
	}
	remote := dial("/v2/accept/"+offer.ID, hostToken)
	payload := []byte{0x17, 0x03, 0x03, 0x00, 0x04, 0xde, 0xad, 0xbe, 0xef}
	for _, direction := range [][2]*websocket.Conn{{client, remote}, {remote, client}} {
		if err = direction[0].Write(ctx, websocket.MessageBinary, payload); err != nil {
			t.Fatal(err)
		}
		kind, got, err := direction[1].Read(ctx)
		if err != nil || kind != websocket.MessageBinary || !bytes.Equal(got, payload) {
			t.Fatal("opaque bytes changed", err)
		}
	}
	// Revocation cancels the active stream and denies subsequent authentication.
	if err = st.Revoke(ctx, hostID, clientID); err != nil {
		t.Fatal(err)
	}
	app.Tunnels.Revoke(hostID, clientID)
	if _, _, err = client.Read(ctx); err == nil {
		t.Fatal("revoked channel remained open")
	}
	if _, err = st.RegisterClient(ctx, clientID, clientToken, host.Code, "phone"); err == nil {
		t.Fatal("revoked registration revived")
	}
	resp, err = http.Get(srv.URL + "/metrics")
	if err != nil {
		t.Fatal(err)
	}
	metrics, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if !bytes.Contains(metrics, []byte("afk_relay_frames_total 2")) {
		t.Fatalf("missing counters: %s", metrics)
	}
	for _, sensitive := range []string{hostID, clientID, hostToken, clientToken} {
		if bytes.Contains(metrics, []byte(sensitive)) {
			t.Fatal("metrics leaked identity")
		}
	}
}

func TestV2RejectsLegacyAndSupportsProbes(t *testing.T) {
	app := New(&store.Store{})
	defer app.Tunnels.Close()
	defer app.Hub.Close()
	handler := app.Handler()
	for _, path := range []string{"/v1/connect", "/v1/pair", "/v1/hosts"} {
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, httptest.NewRequest("GET", path, nil))
		if response.Code != http.StatusUpgradeRequired {
			t.Fatalf("legacy accepted: %s %d", path, response.Code)
		}
	}
	for _, path := range []string{"/healthz", "/metrics"} {
		for i := 0; i < 35; i++ {
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, httptest.NewRequest("GET", path, nil))
			if response.Code != 200 {
				t.Fatalf("probe throttled: %s", path)
			}
		}
	}
}

func TestTunnelRejectsTextAndOversize(t *testing.T) {
	for _, invalid := range []struct {
		name string
		kind websocket.MessageType
		body []byte
	}{
		{"plaintext", websocket.MessageText, []byte(`{"type":"input"}`)},
		{"oversize", websocket.MessageBinary, make([]byte, tunnelFrameLimit+1)},
		{"empty", websocket.MessageBinary, []byte{}},
	} {
		t.Run(invalid.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			hub := NewTunnels()
			defer hub.Close()
			finished := make(chan struct{})
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				ws, err := websocket.Accept(w, r, nil)
				if err != nil {
					return
				}
				defer ws.CloseNow()
				ws.SetReadLimit(tunnelFrameLimit)
				hub.copy(ctx, func() {}, ws, ws)
				close(finished)
			}))
			defer srv.Close()
			ws, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(srv.URL, "http"), nil)
			if err != nil {
				t.Fatal(err)
			}
			defer ws.CloseNow()
			_ = ws.Write(ctx, invalid.kind, invalid.body)
			select {
			case <-finished:
			case <-ctx.Done():
				t.Fatal("invalid frame not closed")
			}
		})
	}
}
