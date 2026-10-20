package store

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/JesusPaz/afk/server/migrations"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestEnrollmentBudgetRecoversWithoutRevivingCredentials(t *testing.T) {
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
	if err := migrations.Apply(ctx, db); err != nil {
		t.Fatal(err)
	}
	s := &Store{DB: db}
	host, err := s.Register(ctx, RandomToken(27), "enrollment test", RandomToken(32))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Exec(context.Background(), "DELETE FROM hosts WHERE id=$1", host.ID)
	firstID, firstToken := RandomToken(27), RandomToken(32)
	if _, err := s.RegisterClient(ctx, firstID, firstToken, host.Code, "phone"); err != nil {
		t.Fatal(err)
	}
	for i := 1; i < 64; i++ {
		if _, err := s.RegisterClient(ctx, RandomToken(27), RandomToken(32), host.Code, "attempt"); err != nil {
			t.Fatal(err)
		}
	}
	enroll := func() error {
		_, err := s.RegisterClient(ctx, RandomToken(27), RandomToken(32), host.Code, "new phone")
		return err
	}
	if err := enroll(); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("recent enrollment limit: %v", err)
	}
	if _, err := s.RegisterClient(ctx, firstID, firstToken, host.Code, "phone"); err != nil {
		t.Fatalf("existing device must reconnect at capacity: %v", err)
	}
	if err := s.Revoke(ctx, host.ID, firstID); err != nil {
		t.Fatal(err)
	}
	if err := enroll(); err != nil {
		t.Fatalf("revocation must free a slot: %v", err)
	}
	if err := enroll(); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("replacement must consume the slot: %v", err)
	}
	if _, err := db.Exec(ctx, "UPDATE clients SET created_at=now()-interval '25 hours' WHERE host_id=$1", host.ID); err != nil {
		t.Fatal(err)
	}
	if err := enroll(); err != nil {
		t.Fatalf("old attempts must not exhaust the budget forever: %v", err)
	}
	if _, err := s.Authenticate(ctx, firstToken); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("revoked token authenticated: %v", err)
	}
	if _, err := s.RegisterClient(ctx, firstID, firstToken, host.Code, "phone"); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("revoked credentials registered again: %v", err)
	}
}
