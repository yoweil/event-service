package main

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

type notificationDB interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
	ExecContext(context.Context, string, ...any) (sql.Result, error)
}

type notification struct {
	ID           string          `json:"id"`
	Type         string          `json:"type"`
	EventID      int64           `json:"event_id,string"`
	AttachmentID int64           `json:"attachment_id,string,omitempty"`
	OccurredAt   time.Time       `json:"occurred_at"`
	Filename     string          `json:"filename,omitempty"`
	SHA256       string          `json:"sha256,omitempty"`
	DownloadPath string          `json:"download_path,omitempty"`
	Revision     int64           `json:"revision,string,omitempty"`
	EventTypeID  int64           `json:"event_type_id,string,omitempty"`
	ActorKind    string          `json:"actor_kind,omitempty"`
	ActorID      string          `json:"actor_id,omitempty"`
	Changes      json.RawMessage `json:"changes,omitempty"`
	Attempt      int64           `json:"-"`
}

type deliveryQueue struct {
	configPrefix string
	table        string
	claim        func(context.Context, notificationDB) (notification, error)
}

var attachmentQueue = deliveryQueue{"ATTACHMENT", "public.notification_outbox", claimAttachmentNotification}
var eventQueue = deliveryQueue{"EVENT", "public.event_notification_outbox", claimEventNotification}

type webhook struct {
	queue    deliveryQueue
	endpoint string
	token    string
	client   *http.Client
}

func newWebhook(queue deliveryQueue, address, token string) (*webhook, error) {
	address = strings.TrimSpace(address)
	if address == "" {
		return nil, nil
	}
	u, err := url.Parse(address)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Hostname() == "" || u.User != nil || u.Fragment != "" {
		return nil, fmt.Errorf("%s_WEBHOOK_URL must be an absolute HTTP(S) URL without credentials or a fragment", queue.configPrefix)
	}
	return &webhook{
		queue: queue, endpoint: address, token: token,
		client: &http.Client{Timeout: 8 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }},
	}, nil
}

func claimAttachmentNotification(ctx context.Context, db notificationDB) (notification, error) {
	var n notification
	err := db.QueryRowContext(ctx, `
    WITH candidate AS MATERIALIZED (
        SELECT id FROM public.notification_outbox
        WHERE delivered_at IS NULL AND next_attempt_at <= statement_timestamp()
        ORDER BY next_attempt_at, id LIMIT 1 FOR UPDATE SKIP LOCKED
    )
    UPDATE public.notification_outbox AS n
    SET attempts=n.attempts+1, next_attempt_at=clock_timestamp()+interval '30 seconds'
    FROM candidate, public.event_attachments a
    WHERE n.id=candidate.id AND a.id=n.attachment_id
    RETURNING n.id,n.attempts,a.event_id,a.id,a.uploaded_at,a.filename,encode(a.digest,'hex')`).
		Scan(&n.ID, &n.Attempt, &n.EventID, &n.AttachmentID, &n.OccurredAt, &n.Filename, &n.SHA256)
	if err != nil {
		return n, err
	}
	n.Type = "attachment.added"
	n.DownloadPath = "/events/" + strconv.FormatInt(n.EventID, 10) + "/attachments/" + strconv.FormatInt(n.AttachmentID, 10)
	n.OccurredAt = n.OccurredAt.UTC()
	return n, nil
}

func claimEventNotification(ctx context.Context, db notificationDB) (notification, error) {
	var n notification
	err := db.QueryRowContext(ctx, `
    WITH candidate AS MATERIALIZED (
        SELECT q.id FROM public.event_notification_outbox q
        WHERE q.delivered_at IS NULL AND q.next_attempt_at <= statement_timestamp()
          AND NOT EXISTS (
              SELECT FROM public.event_notification_outbox earlier
              WHERE earlier.event_id=q.event_id AND earlier.revision<q.revision AND earlier.delivered_at IS NULL
          )
        ORDER BY q.next_attempt_at, q.id LIMIT 1 FOR UPDATE OF q SKIP LOCKED
    ), claimed AS (
        UPDATE public.event_notification_outbox q
        SET attempts=q.attempts+1, next_attempt_at=clock_timestamp()+interval '30 seconds'
        FROM candidate WHERE q.id=candidate.id
        RETURNING q.id, q.event_id, q.revision, q.attempts
    )
    SELECT q.id, q.attempts, q.event_id, e.event_type_id, q.revision, 'event.' || c.operation,
           c.changed_at, c.actor_kind, c.actor_id, (
               SELECT coalesce(json_agg(json_build_object(
                   'scope', CASE WHEN i.base_key IS NULL THEN 'field' ELSE 'base' END,
                   'key', coalesce(i.base_key,i.field_key), 'old_value', i.old_value, 'new_value', i.new_value
               ) ORDER BY i.id), '[]'::json)
               FROM public.event_change_items i WHERE i.event_id=q.event_id AND i.revision=q.revision
           )
    FROM claimed q JOIN public.event_changes c USING (event_id, revision)
    JOIN public.events e ON e.id=q.event_id`).
		Scan(&n.ID, &n.Attempt, &n.EventID, &n.EventTypeID, &n.Revision, &n.Type, &n.OccurredAt, &n.ActorKind, &n.ActorID, &n.Changes)
	n.OccurredAt = n.OccurredAt.UTC()
	return n, err
}

func (q deliveryQueue) finish(ctx context.Context, db notificationDB, n notification, delivered bool) error {
	delaySeconds := min(int64(1)<<min(n.Attempt, 9), int64(300))
	_, err := db.ExecContext(ctx, `
    UPDATE `+q.table+`
    SET delivered_at=CASE WHEN $3 THEN clock_timestamp() END,
        next_attempt_at=CASE WHEN $3 THEN next_attempt_at ELSE clock_timestamp()+$4 * interval '1 second' END
    WHERE id=$1 AND attempts=$2 AND delivered_at IS NULL`, n.ID, n.Attempt, delivered, delaySeconds)
	return err
}

func (h *webhook) send(ctx context.Context, n notification) error {
	body, err := json.Marshal(n)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, h.endpoint, bytes.NewReader(body))
	if err != nil {
		return errors.New("invalid webhook request")
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Idempotency-Key", n.ID)
	if h.token != "" {
		req.Header.Set("Authorization", "Bearer "+h.token)
	}
	resp, err := h.client.Do(req)
	if err != nil {
		return errors.New("webhook connection failed or timed out")
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("webhook returned HTTP %d", resp.StatusCode)
	}
	return nil
}

func (h *webhook) deliverOne(ctx context.Context, db notificationDB) (bool, error) {
	n, err := h.queue.claim(ctx, db)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	sendErr := h.send(ctx, n)
	if ctx.Err() != nil {
		return true, ctx.Err()
	}
	if sendErr != nil {
		log.Printf("%s notification %s attempt %d: %v", n.Type, n.ID, n.Attempt, sendErr)
	}
	return true, h.queue.finish(ctx, db, n, sendErr == nil)
}

func (h *webhook) run(ctx context.Context, db *sql.DB) {
	for ctx.Err() == nil {
		attempt, cancel := context.WithTimeout(ctx, 20*time.Second)
		worked, err := h.deliverOne(attempt, db)
		cancel()
		if err != nil && ctx.Err() == nil {
			log.Printf("%s notification queue: %v", h.queue.configPrefix, err)
		}
		if worked && err == nil {
			continue
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Second):
		}
	}
}
