package relay

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/JesusPaz/afk/server/internal/store"
	"github.com/JesusPaz/afk/server/migrations"
	"github.com/coder/websocket"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Cross-language test: real Swift host -> PTY -> Go relay -> two remote clients.
func TestRealSwiftPTY(t *testing.T) {
	binary, database := os.Getenv("AFK_TEST_HOST_BINARY"), os.Getenv("AFK_TEST_DATABASE_URL")
	if binary == "" || database == "" {
		t.Skip("requires built Swift host and PostgreSQL")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 35*time.Second)
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
	defer app.Hub.Close()
	id, token := store.RandomToken(27), store.RandomToken(32)
	defer db.Exec(context.Background(), "DELETE FROM hosts WHERE id=$1", id)
	cmd := exec.Command(binary)
	cmd.Stderr = os.Stderr
	cmd.Env = append(os.Environ(), "AFK_HOST_ID="+id, "AFK_HOST_TOKEN="+token, "AFK_SERVER="+srv.URL, "SHELL=/bin/sh")
	if err = cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { cmd.Process.Kill(); cmd.Wait() }()
	var code string
	for deadline := time.Now().Add(10 * time.Second); time.Now().Before(deadline); {
		if db.QueryRow(ctx, "SELECT code FROM hosts WHERE id=$1", id).Scan(&code) == nil {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if code == "" {
		t.Fatal("Swift host did not register")
	}
	pair := func() store.Credentials {
		t.Helper()
		p, e := st.NewPairing(ctx, id)
		if e != nil {
			t.Fatal(e)
		}
		c, e := st.Pair(ctx, code, p.Secret, "Smoke client")
		if e != nil {
			t.Fatal(e)
		}
		return c
	}
	dial := func(c store.Credentials) *websocket.Conn {
		t.Helper()
		h := http.Header{}
		h.Set("Authorization", "Bearer "+c.Token)
		ws, _, e := websocket.Dial(ctx, strings.Replace(srv.URL, "http", "ws", 1)+"/v1/connect", &websocket.DialOptions{HTTPHeader: h})
		if e != nil {
			t.Fatal(e)
		}
		t.Cleanup(func() { ws.CloseNow() })
		return ws
	}
	send := func(ws *websocket.Conn, m Message) {
		t.Helper()
		b, _ := json.Marshal(m)
		if e := ws.Write(ctx, websocket.MessageText, b); e != nil {
			t.Fatal(e)
		}
	}
	read := func(ws *websocket.Conn, kind string) Message {
		t.Helper()
		for {
			_, b, e := ws.Read(ctx)
			if e != nil {
				t.Fatal(e)
			}
			var m Message
			if e = json.Unmarshal(b, &m); e != nil {
				t.Fatal(e)
			}
			if m.Type == kind {
				return m
			}
		}
	}
	a, b := pair(), pair()
	wa, wb := dial(a), dial(b)
	send(wa, Message{Type: "list"})
	var sessions []struct {
		ID string `json:"id"`
	}
	json.Unmarshal(read(wa, "sessions").Sessions, &sessions)
	if len(sessions) != 1 {
		t.Fatal("missing real shell")
	}
	sid := sessions[0].ID
	send(wa, Message{Type: "attach", SessionID: sid})
	read(wa, "snapshot")
	send(wa, Message{Type: "claim", SessionID: sid})
	leaseA := read(wa, "control")
	if leaseA.Owner != a.ClientID {
		t.Fatal("A did not get control")
	}
	send(wb, Message{Type: "claim", SessionID: sid})
	var leaseB Message
	for {
		leaseB = read(wa, "control")
		if leaseB.Owner == b.ClientID {
			break
		}
	}
	// Resize shares the lease's command sequence and output event ordering.
	send(wb, Message{Type: "resize", SessionID: sid, Epoch: leaseB.Epoch, Sequence: 1, Columns: 39, Rows: 30})
	resized := read(wa, "resized")
	if resized.Columns != 39 || resized.Rows != 30 {
		t.Fatal("wrong resize")
	}
	send(wa, Message{Type: "resize", SessionID: sid, Epoch: leaseA.Epoch, Sequence: 2, Columns: 120, Rows: 40})
	send(wb, Message{Type: "resize", SessionID: sid, Epoch: leaseB.Epoch, Sequence: 2, Columns: 0, Rows: 40})
	// If stale input runs, its marker will appear in the replay below.
	send(wa, Message{Type: "input", SessionID: sid, Epoch: leaseA.Epoch, Sequence: 1, Data: base64.StdEncoding.EncodeToString([]byte("printf 'STALE_INPUT_RAN\\n'\n"))})
	send(wb, Message{Type: "input", SessionID: sid, Epoch: leaseB.Epoch, Sequence: 2, Data: base64.StdEncoding.EncodeToString([]byte("stty size; printf 'AFK_%s\\n' 'PTY_OK'\n"))})
	for _, ws := range []*websocket.Conn{wa, wb} {
		output := ""
		for !strings.Contains(output, "AFK_PTY_OK") {
			m := read(ws, "output")
			d, _ := base64.StdEncoding.DecodeString(m.Data)
			output += string(d)
		}
		if strings.Contains(output, "STALE_INPUT_RAN") {
			t.Fatal("stale owner wrote to PTY")
		}
	}
	send(wa, Message{Type: "attach", SessionID: sid})
	snapshot := read(wa, "snapshot")
	var events []struct {
		Data []byte `json:"data"`
		Size *struct {
			Columns int `json:"columns"`
			Rows    int `json:"rows"`
		} `json:"size"`
	}
	if err := json.Unmarshal(snapshot.Events, &events); err != nil {
		t.Fatal(err)
	}
	var data []byte
	resizeCount := 0
	for _, event := range events {
		data = append(data, event.Data...)
		if event.Size != nil {
			resizeCount++
			if event.Size.Columns != 39 {
				t.Fatal("unauthorized resize")
			}
		}
	}
	if resizeCount != 1 || snapshot.Columns != 39 || !strings.Contains(string(data), "30 39") {
		t.Fatal("PTY geometry or replay incorrect")
	}
	if !strings.Contains(string(data), "AFK_PTY_OK") || strings.Contains(string(data), "STALE_INPUT_RAN") {
		t.Fatal("incorrect replay")
	}
	// Close the real PTY cleanly, not just the test host process.
	send(wb, Message{Type: "input", SessionID: sid, Epoch: leaseB.Epoch, Sequence: 3, Data: base64.StdEncoding.EncodeToString([]byte("exit\n"))})
	read(wb, "exit")
	t.Log("real PTY, two-client fanout, stale-owner rejection, replay and shell exit passed")
}
