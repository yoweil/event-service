package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
)

var fieldKeyPattern = regexp.MustCompile(`^[a-z][a-z0-9_]{0,63}$`)
var decimalPattern = regexp.MustCompile(`^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$`)
var comparisons = map[string]string{"eq": "=", "lt": "<", "lte": "<=", "gt": ">", "gte": ">="}

type searchError string

func (e searchError) Error() string { return string(e) }

type fieldFilter struct{ key, op, value string }
type pageCursor struct {
	Scope string  `json:"s"`
	Value *string `json:"v"`
	ID    int64   `json:"id"`
}
type eventSearch struct {
	well, text, sortKey, scope string
	typeID                     int64
	from, to                   *time.Time
	descending                 bool
	limit                      int
	filters                    []fieldFilter
	after                      *pageCursor
}

func parseEventSearch(raw string) (eventSearch, error) {
	s := eventSearch{descending: true, limit: 50}
	q, err := url.ParseQuery(raw)
	if err != nil {
		return s, searchError("invalid query string")
	}
	keys := make([]string, 0, len(q))
	for k := range q {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	for _, key := range keys {
		if len(q[key]) != 1 {
			return s, searchError("repeated search parameter: " + key)
		}
		value := q.Get(key)
		switch key {
		case "well_id":
			if strings.TrimSpace(value) == "" {
				return s, searchError("well_id must not be blank")
			}
			s.well = value
		case "event_type_id":
			s.typeID, err = strconv.ParseInt(value, 10, 64)
			if err != nil || s.typeID < 1 {
				return s, searchError("expected a positive event_type_id")
			}
		case "q":
			s.text = value
		case "from", "to":
			t, err := parseTimestamp(value)
			if err != nil {
				return s, searchError(key + " requires an RFC 3339 timestamp")
			}
			if key == "from" {
				s.from = &t
			} else {
				s.to = &t
			}
		case "limit":
			s.limit, err = strconv.Atoi(value)
			if err != nil || s.limit < 1 || s.limit > 100 {
				return s, searchError("limit must be between 1 and 100")
			}
		case "sort":
			s.descending = strings.HasPrefix(value, "-")
			name := strings.TrimPrefix(value, "-")
			if name != "started_at" {
				field, ok := strings.CutPrefix(name, "field.")
				if !ok || !fieldKeyPattern.MatchString(field) {
					return s, searchError("sort requires started_at or field.<key>, optionally prefixed with -")
				}
				s.sortKey = field
			}
		case "cursor":
			data, err := base64.RawURLEncoding.DecodeString(value)
			var c pageCursor
			if err != nil || json.Unmarshal(data, &c) != nil || c.ID < 1 {
				return s, searchError("invalid cursor")
			}
			s.after = &c
		default:
			field, ok := strings.CutPrefix(key, "field.")
			name, op, _ := strings.Cut(field, ".")
			if !ok || !fieldKeyPattern.MatchString(name) || comparisons[op] == "" {
				return s, searchError("unknown search parameter: " + key)
			}
			s.filters = append(s.filters, fieldFilter{name, op, value})
		}
	}
	if s.from != nil && s.to != nil && !s.from.Before(*s.to) {
		return s, searchError("from must precede to")
	}
	if s.typeID == 0 && (len(s.filters) > 0 || s.sortKey != "") {
		return s, searchError("field filters and field sorting require event_type_id")
	}
	q.Del("cursor")
	q.Del("limit")
	digest := sha256.Sum256([]byte(q.Encode()))
	s.scope = base64.RawURLEncoding.EncodeToString(digest[:16])
	if s.after != nil && (s.after.Scope != s.scope || (s.sortKey == "" && s.after.Value == nil)) {
		return s, searchError("cursor does not match this search")
	}
	return s, nil
}

func searchValue(kind, value string) (string, error) {
	switch kind {
	case "number", "integer":
		if !decimalPattern.MatchString(value) {
			return "", searchError("expected a decimal field value")
		}
	case "boolean":
		if value != "true" && value != "false" {
			return "", searchError("expected true or false")
		}
	case "date":
		day, err := time.Parse(time.DateOnly, value)
		if err != nil || day.Year() < 1 {
			return "", searchError("expected YYYY-MM-DD")
		}
	case "datetime":
		t, err := parseTimestamp(value)
		if err != nil {
			return "", searchError("expected RFC 3339 field value")
		}
		return t.Format(time.RFC3339Nano), nil
	}
	return value, nil
}

func (a *api) listEvents(w http.ResponseWriter, r *http.Request) {
	s, err := parseEventSearch(r.URL.RawQuery)
	if err != nil {
		respondError(w, http.StatusBadRequest, err.Error())
		return
	}
	page, err := a.searchEvents(r.Context(), s)
	if err != nil {
		var bad searchError
		if errors.As(err, &bad) {
			respondError(w, http.StatusBadRequest, bad.Error())
		} else {
			databaseError(w, err)
		}
		return
	}
	respond(w, http.StatusOK, page)
}
