package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func request(t *testing.T, handler http.Handler, method, path, token, body string, want int) []byte {
	t.Helper()
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if w.Code != want {
		t.Fatalf("%s %s: got %d, want %d: %s", method, path, w.Code, want, w.Body.String())
	}
	return w.Body.Bytes()
}

func TestRejectInvalidRequestBeforeDatabase(t *testing.T) {
	h := newHandler(nil, "secret", "integration-client", time.Second)
	request(t, h, "GET", "/events/1", "wrong", "", 401)
	request(t, h, "GET", "/events/0", "secret", "", 400)
	request(t, h, "POST", "/event-types", "secret", `{"code":"ok","actor_id":"someone"}`, 400)
	request(t, h, "POST", "/events", "secret", `{} {}`, 400)
	request(t, h, "PUT", "/events/1", "secret", `{"event_type_id":1,"well_id":"w","status":"draft","time_kind":"instant","started_at":"2026-01-01T00:00:00Z","description":""}`, 400)
}

func testTransaction(t *testing.T) *sql.Tx {
	t.Helper()
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("set TEST_DATABASE_URL to a database with the event schema")
	}
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	tx, err := db.Begin()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { tx.Rollback() })
	return tx
}

func TestEventLifecycle(t *testing.T) {
	tx := testTransaction(t)
	h := newHandler(tx, "secret", "integration-client", 5*time.Second)
	created := request(t, h, "POST", "/event-types", "secret", `{
        "code":"http_lifecycle_test","name":"Исследование",
        "fields":[{"field_key":"pressure","label":"Давление","data_type":"number","is_required":true},
                  {"field_key":"approved","label":"Проверено","data_type":"boolean"},
                  {"field_key":"method","label":"Способ","data_type":"select"}],
        "options":[{"field_key":"method","code":"manual","label":"Вручную"}]
    }`, 201)
	var typ struct{ ID int64 }
	if err := json.Unmarshal(created, &typ); err != nil || typ.ID < 1 {
		t.Fatalf("created type: %s", created)
	}
	base := fmt.Sprintf(`"event_type_id":%d,"well_id":"well-1","status":"ready","time_kind":"instant","started_at":"2026-01-01T00:00:00Z"`, typ.ID)
	saved := request(t, h, "POST", "/events", "secret", "{"+base+`,"fields":[
        {"field_key":"pressure","value_number":12345678901234567890.12345},
        {"field_key":"approved","value_boolean":false},{"field_key":"method","value_option":"manual"}]}`, 201)
	var card struct{ ID, Revision int64 }
	if err := json.Unmarshal(saved, &card); err != nil || card.Revision != 1 || card.ID < 1 {
		t.Fatalf("created event: %s", saved)
	}
	path := fmt.Sprintf("/events/%d", card.ID)
	update := "{" + base + `,"description":"updated","expected_revision":1,"fields":[{"field_key":"method"}]}`
	saved = request(t, h, "PUT", path, "secret", update, 200)
	if err := json.Unmarshal(saved, &card); err != nil || card.Revision != 2 {
		t.Fatalf("updated event: %s", saved)
	}
	data := request(t, h, "GET", path, "secret", "", 200)
	var got struct {
		Description string
		CreatedBy   string `json:"created_by_id"`
		Fields      []struct {
			Key    string      `json:"field_key"`
			Number json.Number `json:"value_number"`
			Bool   *bool       `json:"value_boolean"`
		}
	}
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	if got.Description != "updated" || got.CreatedBy != "integration-client" || len(got.Fields) != 2 ||
		got.Fields[0].Key != "approved" || got.Fields[0].Bool == nil || *got.Fields[0].Bool ||
		got.Fields[1].Key != "pressure" || got.Fields[1].Number.String() != "12345678901234567890.12345" {
		t.Fatalf("unexpected card after update: %s", data)
	}
	request(t, h, "GET", "/events/9223372036854775807", "secret", "", 404)
	request(t, h, "PUT", path, "secret", update, 409)
}

func TestRoutingErrorsUseJSON(t *testing.T) {
	h := newHandler(nil, "secret", "integration-client", time.Second)
	for _, tc := range []struct {
		method, path, allow string
		status              int
	}{
		{"GET", "/missing", "", 404},
		{"DELETE", "/events/1", "GET, HEAD, PUT", 405},
		{"DELETE", "/events", "GET, HEAD, POST", 405},
		{"PUT", "/event-types", "GET, HEAD, POST", 405},
		{"POST", "/event-types/1", "GET, HEAD", 405},
	} {
		r := httptest.NewRequest(tc.method, tc.path, nil)
		r.Header.Set("Authorization", "Bearer secret")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		var result struct{ Error string }
		if w.Code != tc.status || w.Header().Get("Allow") != tc.allow ||
			!strings.HasPrefix(w.Header().Get("Content-Type"), "application/json") ||
			json.Unmarshal(w.Body.Bytes(), &result) != nil || result.Error == "" {
			t.Errorf("%s %s: %d, %v, %s", tc.method, tc.path, w.Code, w.Header(), w.Body.String())
		}
	}
}

func TestTimestampInput(t *testing.T) {
	var valid timestamp
	if err := json.Unmarshal([]byte(`"2026-01-01T00:00:00.123456+03:00"`), &valid); err != nil || valid != "2025-12-31T21:00:00.123456Z" {
		t.Fatalf("valid UTC offset: %q, %v", valid, err)
	}
	for _, bad := range []string{"2026-01-01T00:00:00+24:00", "2026-01-01T00:00:00+03:60", "2026-01-01T1:00:00Z"} {
		for _, key := range []string{"started_at", "ended_at", "value_datetime"} {
			body := fmt.Sprintf(`{"%s":%q}`, key, bad)
			if key == "value_datetime" {
				body = `{"fields":[` + body + `]}`
			}
			var input saveInput
			if err := json.Unmarshal([]byte(body), &input); err == nil {
				t.Errorf("accepted %s in %s", bad, key)
			}
		}
	}
}

func TestDatabaseLockDeadline(t *testing.T) {
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("set TEST_DATABASE_URL to run the lock test")
	}
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	lock, err := db.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Rollback()
	const code = "http_lock_test"
	if _, err = lock.Exec("SELECT id FROM public.create_event_type($1,'Lock test','service','test')", code); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	r := httptest.NewRequest("POST", "/event-types", strings.NewReader(`{"code":"http_lock_test","name":"Second writer"}`)).WithContext(ctx)
	r.Header.Set("Authorization", "Bearer secret")
	w := httptest.NewRecorder()
	newHandler(db, "secret", "test", 250*time.Millisecond).ServeHTTP(w, r)
	if w.Code != http.StatusServiceUnavailable || ctx.Err() != nil {
		t.Fatalf("blocked write: %d, %s, context: %v", w.Code, w.Body.String(), ctx.Err())
	}
	if err := lock.Rollback(); err != nil {
		t.Fatal(err)
	}
	var found bool
	if err := db.QueryRow("SELECT EXISTS (SELECT FROM public.event_types WHERE code=$1)", code).Scan(&found); err != nil || found {
		t.Fatalf("timed out write persisted: %t, %v", found, err)
	}
}
