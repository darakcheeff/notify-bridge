package db

import (
	"log"
	"time"

	"github.com/jmoiron/sqlx"
	_ "github.com/mattn/go-sqlite3"
)

type DB struct {
	*sqlx.DB
}

func InitDB(dsn string) (*DB, error) {
	db, err := sqlx.Open("sqlite3", dsn)
	if err != nil {
		return nil, err
	}

	if err := db.Ping(); err != nil {
		return nil, err
	}

	schema := `
	CREATE TABLE IF NOT EXISTS groups (
		group_id TEXT PRIMARY KEY,
		last_activity DATETIME
	);
	CREATE TABLE IF NOT EXISTS message_queue (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		group_id TEXT,
		payload TEXT,
		created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
		is_delivered BOOLEAN DEFAULT 0
	);
	CREATE INDEX IF NOT EXISTS idx_message_queue_group_id ON message_queue(group_id);
	`
	if _, err := db.Exec(schema); err != nil {
		log.Fatalf("Failed to execute schema: %v", err)
	}

	return &DB{db}, nil
}

func (db *DB) AutoProvisionGroup(guid string) error {
	query := `INSERT INTO groups (group_id, last_activity) VALUES (?, ?) ON CONFLICT(group_id) DO UPDATE SET last_activity = excluded.last_activity`
	_, err := db.Exec(query, guid, time.Now())
	return err
}

func (db *DB) SaveMessage(guid string, payload []byte) error {
	query := `INSERT INTO message_queue (group_id, payload) VALUES (?, ?)`
	_, err := db.Exec(query, guid, string(payload))
	return err
}

type QueuedMessage struct {
	ID      int    `db:"id"`
	Payload string `db:"payload"`
}

func (db *DB) GetPendingMessages(guid string) ([]QueuedMessage, error) {
	var msgs []QueuedMessage
	err := db.Select(&msgs, `SELECT id, payload FROM message_queue WHERE group_id = ? AND is_delivered = 0 ORDER BY id ASC`, guid)
	return msgs, err
}

func (db *DB) MarkDelivered(ids []int) error {
	if len(ids) == 0 {
		return nil
	}
	query, args, err := sqlx.In(`UPDATE message_queue SET is_delivered = 1 WHERE id IN (?)`, ids)
	if err != nil {
		return err
	}
	query = db.Rebind(query)
	_, err = db.Exec(query, args...)
	return err
}
