package main

import (
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestWebUIAndProtectedAPI(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte("Журнал событий"), 0600); err != nil {
		t.Fatal(err)
	}
	h := withWebUI(newHandler(nil, "secret", "test", time.Second), dir)
	for path, status := range map[string]int{"/ui/": 200, "/events": 401, "/event-types": 401, "/ui/missing.js": 404} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
		if w.Code != status {
			t.Errorf("%s: %d", path, w.Code)
		}
	}
}
