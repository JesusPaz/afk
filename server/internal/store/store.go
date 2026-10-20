package store

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base32"
	"encoding/base64"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var ErrUnauthorized = errors.New("unauthorized")

type Store struct{ DB *pgxpool.Pool }
type Identity struct{ ID, HostID, Role string }
type Host struct {
	ID   string `json:"id"`
	Code string `json:"code"`
	Name string `json:"name"`
}
type Client struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}
type Pairing struct {
	Secret    string    `json:"secret"`
	ExpiresAt time.Time `json:"expiresAt"`
}
type Credentials struct {
	ClientID string `json:"clientID"`
	Token    string `json:"token"`
	Host     Host   `json:"host"`
}

func Hash(s string) []byte { h := sha256.Sum256([]byte(s)); return h[:] }
func RandomToken(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}
func code() string {
	b := make([]byte, 5)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(b)
}

func (s *Store) Register(ctx context.Context, id, name, token string) (Host, error) {
	// Registration is idempotent by locally generated ID and proof of possession.
	h := Host{ID: id, Name: name}
	_, err := s.DB.Exec(ctx, `INSERT INTO hosts(id,code,name,token_hash) VALUES($1,$2,$3,$4) ON CONFLICT(id) DO NOTHING`, id, code(), name, Hash(token))
	if err != nil {
		return Host{}, err
	}
	var hash []byte
	err = s.DB.QueryRow(ctx, `SELECT code,name,token_hash FROM hosts WHERE id=$1`, id).Scan(&h.Code, &h.Name, &hash)
	if err != nil {
		return Host{}, err
	}
	if subtle.ConstantTimeCompare(hash, Hash(token)) != 1 {
		return Host{}, ErrUnauthorized
	}
	return h, nil
}
func (s *Store) Authenticate(ctx context.Context, token string) (Identity, error) {
	var i Identity
	err := s.DB.QueryRow(ctx, `SELECT id,id,'host' FROM hosts WHERE token_hash=$1
 UNION ALL SELECT id,host_id,'client' FROM clients WHERE token_hash=$1 AND revoked_at IS NULL LIMIT 1`, Hash(token)).Scan(&i.ID, &i.HostID, &i.Role)
	if errors.Is(err, pgx.ErrNoRows) {
		return i, ErrUnauthorized
	}
	return i, err
}
func (s *Store) NewPairing(ctx context.Context, hostID string) (Pairing, error) {
	p := Pairing{Secret: RandomToken(16), ExpiresAt: time.Now().UTC().Add(5 * time.Minute)}
	_, err := s.DB.Exec(ctx, `UPDATE hosts SET pairing_hash=$2,pairing_expires_at=$3 WHERE id=$1`, hostID, Hash(p.Secret), p.ExpiresAt)
	return p, err
}
func (s *Store) Pair(ctx context.Context, code, secret, name string) (Credentials, error) {
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return Credentials{}, err
	}
	defer tx.Rollback(ctx)
	var h Host
	var hash []byte
	var expires *time.Time
	err = tx.QueryRow(ctx, `SELECT id,code,name,pairing_hash,pairing_expires_at FROM hosts WHERE code=$1 FOR UPDATE`, code).Scan(&h.ID, &h.Code, &h.Name, &hash, &expires)
	if errors.Is(err, pgx.ErrNoRows) {
		return Credentials{}, ErrUnauthorized
	}
	if err != nil {
		return Credentials{}, err
	}
	if expires == nil || time.Now().After(*expires) || subtle.ConstantTimeCompare(hash, Hash(secret)) != 1 {
		return Credentials{}, ErrUnauthorized
	}
	c := Credentials{ClientID: RandomToken(16), Token: RandomToken(32), Host: h}
	if _, err = tx.Exec(ctx, `INSERT INTO clients(id,host_id,name,token_hash) VALUES($1,$2,$3,$4)`, c.ClientID, h.ID, name, Hash(c.Token)); err != nil {
		return Credentials{}, err
	}
	if _, err = tx.Exec(ctx, `UPDATE hosts SET pairing_hash=NULL,pairing_expires_at=NULL WHERE id=$1`, h.ID); err != nil {
		return Credentials{}, err
	}
	return c, tx.Commit(ctx)
}
func (s *Store) Clients(ctx context.Context, hostID string) ([]Client, error) {
	rows, err := s.DB.Query(ctx, `SELECT id,name FROM clients WHERE host_id=$1 AND revoked_at IS NULL ORDER BY created_at`, hostID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	clients := []Client{}
	for rows.Next() {
		var c Client
		if err := rows.Scan(&c.ID, &c.Name); err != nil {
			return nil, err
		}
		clients = append(clients, c)
	}
	return clients, rows.Err()
}
func (s *Store) Revoke(ctx context.Context, hostID, clientID string) error {
	_, err := s.DB.Exec(ctx, `UPDATE clients SET revoked_at=now() WHERE host_id=$1 AND id=$2`, hostID, clientID)
	return err
}

// RegisterClient grants transport access only. The Mac separately authorizes the TLS identity.
func (s *Store) RegisterClient(ctx context.Context, id, token, code, name string) (Host, error) {
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return Host{}, err
	}
	defer tx.Rollback(ctx)
	var h Host
	err = tx.QueryRow(ctx, "SELECT id,code,name FROM hosts WHERE code=$1 FOR UPDATE", code).Scan(&h.ID, &h.Code, &h.Name)
	if errors.Is(err, pgx.ErrNoRows) {
		return Host{}, ErrUnauthorized
	}
	if err != nil {
		return Host{}, err
	}
	var hash []byte
	var hostID string
	var revoked *time.Time
	err = tx.QueryRow(ctx, "SELECT host_id,token_hash,revoked_at FROM clients WHERE id=$1", id).Scan(&hostID, &hash, &revoked)
	if err == nil {
		if hostID != h.ID || revoked != nil || subtle.ConstantTimeCompare(hash, Hash(token)) != 1 {
			return Host{}, ErrUnauthorized
		}
	} else if errors.Is(err, pgx.ErrNoRows) {
		var count int
		// A rolling enrollment budget, not a lifetime device limit. Keep revoked
		// rows as tombstones so freeing a slot never revives their credentials.
		if err = tx.QueryRow(ctx, `SELECT count(*) FROM clients WHERE host_id=$1
 AND revoked_at IS NULL AND created_at > now()-interval '24 hours'`, h.ID).Scan(&count); err != nil {
			return Host{}, err
		}
		if count >= 64 {
			return Host{}, ErrUnauthorized
		}
		_, err = tx.Exec(ctx, "INSERT INTO clients(id,host_id,name,token_hash) VALUES($1,$2,$3,$4)", id, h.ID, name, Hash(token))
		if err != nil {
			return Host{}, err
		}
	} else {
		return Host{}, err
	}
	return h, tx.Commit(ctx)
}
