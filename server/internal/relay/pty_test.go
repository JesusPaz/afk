package relay

import (
	"context"
	"crypto/rand"
	"fmt"
	"net/http/httptest"
	"os"
	"os/exec"
	"testing"
	"time"

	"github.com/JesusPaz/afk/server/internal/store"
	"github.com/JesusPaz/afk/server/migrations"
	"github.com/jackc/pgx/v5/pgxpool"
)

// The native XCTest uses two actual TLS peers and a real macOS PTY.
func TestRealSecureSwiftPTY(t *testing.T) {
	// Local scenarios get separate relays and request budgets; production limits stay intact.
	for _, scenario := range []string{
		"testSecurePairingRealPTYReconnectAndRevocation",
		"testConsentCancellationConcurrencyAndPhonePersistence",
		"testAllSessionCommandsRejectedWhilePending",
	} {
		t.Run(scenario, func(t *testing.T) { runSecureSwift(t, scenario) })
	}
}

func runSecureSwift(t *testing.T, scenario string) {
	packagePath, database := os.Getenv("AFK_TEST_SWIFT_PACKAGE"), os.Getenv("AFK_TEST_DATABASE_URL")
	if packagePath == "" || database == "" {
		t.Skip("requires prebuilt Swift tests and PostgreSQL")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	db, err := pgxpool.New(ctx, database)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err = migrations.Apply(ctx, db); err != nil {
		t.Fatal(err)
	}
	relayURL := os.Getenv("AFK_TEST_RELAY_URL")
	if relayURL == "" {
		app := New(&store.Store{DB: db})
		srv := httptest.NewServer(app.Handler())
		defer srv.Close()
		defer app.Tunnels.Close()
		defer app.Hub.Close()
		relayURL = srv.URL
	}
	random := make([]byte, 16)
	if _, err = rand.Read(random); err != nil {
		t.Fatal(err)
	}
	id := fmt.Sprintf("%x-%x-%x-%x-%x", random[:4], random[4:6], random[6:8], random[8:10], random[10:])
	defer func() {
		cleanup, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		removed, err := db.Exec(cleanup, "DELETE FROM hosts WHERE id=$1", id)
		if err != nil {
			t.Error("could not delete the temporary test host")
		} else if !t.Failed() && removed.RowsAffected() != 1 {
			t.Error("successful scenario did not remove exactly one temporary host")
		}
	}()
	cmd := exec.CommandContext(ctx, "swift", "test", "--skip-build", "--filter", "SecureIntegrationTests/"+scenario)
	cmd.Dir = packagePath
	cmd.Env = append(os.Environ(), "AFK_E2EE_TEST_URL="+relayURL, "AFK_E2EE_HOST_ID="+id, "SHELL=/bin/sh")
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("secure native integration failed: %v\n%s", err, output)
	}
	t.Logf("native secure scenario %s passed", scenario)
}
