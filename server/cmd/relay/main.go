package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/JesusPaz/afk/server/internal/relay"
	"github.com/JesusPaz/afk/server/internal/store"
	"github.com/JesusPaz/afk/server/migrations"
	"github.com/jackc/pgx/v5/pgxpool"
)

func main() {
	if err := run(); err != nil {
		slog.Error("relay stopped", "error", err)
		os.Exit(1)
	}
}
func run() error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	cfg, err := pgxpool.ParseConfig(os.Getenv("DATABASE_URL"))
	if err != nil {
		return errors.New("invalid DATABASE_URL")
	}
	cfg.MaxConns = 8
	db, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return errors.New("database connection failed")
	}
	defer db.Close()
	setup, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	if migrations.Apply(setup, db) != nil {
		return errors.New("database migration failed")
	}
	app := relay.New(&store.Store{DB: db})
	defer app.Hub.Close()
	defer app.Tunnels.Close()
	addr := os.Getenv("AFK_LISTEN")
	if addr == "" {
		addr = "127.0.0.1:8787"
	}
	srv := &http.Server{Addr: addr, Handler: app.Handler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 15 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 8192}
	done := make(chan error, 1)
	go func() { done <- srv.ListenAndServe() }()
	slog.Info("AFK development relay ready", "address", addr, "protocol", 2)
	select {
	case err := <-done:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
		app.Hub.Close()
		app.Tunnels.Close()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		return srv.Shutdown(shutdown)
	}
}
