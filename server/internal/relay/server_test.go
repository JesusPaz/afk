package relay

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/JesusPaz/afk/server/internal/store"
	"github.com/JesusPaz/afk/server/migrations"
	"github.com/coder/websocket"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestPostgresAndRelay(t *testing.T) {
	url := os.Getenv("AFK_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("set AFK_TEST_DATABASE_URL to run PostgreSQL integration tests")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	db, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := migrations.Apply(ctx, db); err != nil {
		t.Fatal(err)
	}
	st := &store.Store{DB: db}
	app := New(st)
	server := httptest.NewServer(app.Handler())
	defer server.Close()
	defer app.Hub.Close()
	token := store.RandomToken(32)
	id := store.RandomToken(27)
	defer db.Exec(context.Background(), "DELETE FROM hosts WHERE id=$1", id)
	request := func(path, method, token string, body any, out any) int {
		t.Helper()
		data, _ := json.Marshal(body)
		r, _ := http.NewRequestWithContext(ctx, method, server.URL+path, bytes.NewReader(data))
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		resp, err := http.DefaultClient.Do(r)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		if out != nil {
			if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
				t.Fatal(err)
			}
		}
		return resp.StatusCode
	}
	var host store.Host
	if status := request("/v1/hosts", "POST", "", map[string]string{"id": id, "name": "Test Mac", "token": token}, &host); status != 200 {
		t.Fatal(status)
	}
	t.Run("stable registration and identity proof", func(t *testing.T) {
		same, err := st.Register(ctx, id, "Test Mac", token)
		if err != nil || same.Code != host.Code {
			t.Fatalf("registration changed: %v", err)
		}
		if _, err = st.Register(ctx, id, "Impostor", store.RandomToken(32)); err != store.ErrUnauthorized {
			t.Fatal("identity takeover accepted")
		}
	})
	t.Run("identity persists across store connections", func(t *testing.T) {
		reopened, err := pgxpool.New(ctx, url)
		if err != nil {
			t.Fatal(err)
		}
		defer reopened.Close()
		fresh := &store.Store{DB: reopened}
		identity, err := fresh.Authenticate(ctx, token)
		if err != nil || identity.ID != id {
			t.Fatal("persisted identity unavailable")
		}
		same, err := fresh.Register(ctx, id, "Test Mac", token)
		if err != nil || same.Code != host.Code {
			t.Fatal("host code changed after reconnect")
		}
	})
	t.Run("single use under concurrent pairing", func(t *testing.T) {
		p, err := st.NewPairing(ctx, id)
		if err != nil {
			t.Fatal(err)
		}
		var successes atomic.Int32
		var wg sync.WaitGroup
		for i := 0; i < 12; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				if _, err := st.Pair(ctx, host.Code, p.Secret, "Phone"); err == nil {
					successes.Add(1)
				}
			}()
		}
		wg.Wait()
		if successes.Load() != 1 {
			t.Fatalf("got %d successful uses", successes.Load())
		}
	})
	t.Run("expired secret", func(t *testing.T) {
		p, _ := st.NewPairing(ctx, id)
		_, err := db.Exec(ctx, "UPDATE hosts SET pairing_expires_at=now()-interval '1 second' WHERE id=$1", id)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := st.Pair(ctx, host.Code, p.Secret, "Phone"); err != store.ErrUnauthorized {
			t.Fatal("expired pairing accepted")
		}
	})
	dial := func(token string) *websocket.Conn {
		t.Helper()
		headers := http.Header{}
		headers.Set("Authorization", "Bearer "+token)
		ws, _, err := websocket.Dial(ctx, strings.Replace(server.URL, "http", "ws", 1)+"/v1/connect", &websocket.DialOptions{HTTPHeader: headers})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { ws.CloseNow() })
		return ws
	}
	read := func(ws *websocket.Conn, kind string) Message {
		t.Helper()
		for {
			_, b, err := ws.Read(ctx)
			if err != nil {
				t.Fatal(err)
			}
			var m Message
			if json.Unmarshal(b, &m) != nil {
				t.Fatal("bad JSON")
			}
			if m.Type == kind {
				return m
			}
		}
	}
	send := func(ws *websocket.Conn, m Message) {
		t.Helper()
		b, _ := json.Marshal(m)
		if err := ws.Write(ctx, websocket.MessageText, b); err != nil {
			t.Fatal(err)
		}
	}
	hostWS := dial(token)
	read(hostWS, "welcome")
	pair := func() store.Credentials {
		t.Helper()
		p, err := st.NewPairing(ctx, id)
		if err != nil {
			t.Fatal(err)
		}
		c, err := st.Pair(ctx, host.Code, p.Secret, "Phone")
		if err != nil {
			t.Fatal(err)
		}
		return c
	}
	a, b := pair(), pair()
	aWS, bWS := dial(a.Token), dial(b.Token)
	read(aWS, "welcome")
	read(bWS, "welcome")
	t.Run("server assigns sender identity", func(t *testing.T) {
		send(aWS, Message{Type: "claim", ClientID: b.ClientID, SessionID: "session"})
		m := read(hostWS, "claim")
		if m.ClientID != a.ClientID {
			t.Fatal("forged sender accepted")
		}
	})
	t.Run("output reaches both clients", func(t *testing.T) {
		send(hostWS, Message{Type: "output", SessionID: "session", Data: "aGVsbG8="})
		for _, ws := range []*websocket.Conn{aWS, bWS} {
			if read(ws, "output").Data != "aGVsbG8=" {
				t.Fatal("wrong output")
			}
		}
	})
	t.Run("revocation persists and closes active socket", func(t *testing.T) {
		if request("/v1/clients/"+a.ClientID, "DELETE", token, nil, nil) != 204 {
			t.Fatal("revoke failed")
		}
		if _, err := st.Authenticate(ctx, a.Token); err != store.ErrUnauthorized {
			t.Fatal("revoked token accepted")
		}
		if _, _, err := aWS.Read(ctx); err == nil {
			t.Fatal("revoked socket still open")
		}
	})
	t.Run("unauthenticated and cross origin rejected", func(t *testing.T) {
		if request("/v1/clients", "GET", "", nil, nil) != 401 {
			t.Fatal("unauthenticated request accepted")
		}
		r, _ := http.NewRequestWithContext(ctx, "GET", server.URL+"/v1/connect", nil)
		r.Header.Set("Origin", "https://evil.example")
		resp, err := http.DefaultClient.Do(r)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != 403 {
			t.Fatal(fmt.Sprintf("origin returned %d", resp.StatusCode))
		}
	})
}
