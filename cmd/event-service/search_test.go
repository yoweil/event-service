package main

import (
	"encoding/json"
	"fmt"
	"net/url"
	"slices"
	"strconv"
	"testing"
	"time"
)

func TestSearchInput(t *testing.T) {
	h := newHandler(nil, "secret", "test", time.Second)
	for _, query := range []string{
		"limit=0", "limit=101", "limit=1&limit=2", "event_type_id=-1", "from=bad", "to=2026-01-01",
		"from=2026-01-02T00:00:00Z&to=2026-01-01T00:00:00Z", "sort=unknown", "cursor=broken",
		"field.pressure.gt=10", "sort=-field.pressure", "event_type_id=1&field.pressure.bad=10", "well_typo=w",
	} {
		request(t, h, "GET", "/events?"+query, "secret", "", 400)
	}
	request(t, h, "GET", "/events", "invalid", "", 401)
}

func TestSearchEvents(t *testing.T) {
	tx := testTransaction(t)
	h := newHandler(tx, "secret", "list-test", 5*time.Second)
	var typ, other eventTypeRef
	parse := func(b []byte, dst any) {
		t.Helper()
		if err := json.Unmarshal(b, dst); err != nil {
			t.Fatal(err)
		}
	}
	parse(request(t, h, "POST", "/event-types", "secret", `{"code":"search_test","name":"Исследование",
        "fields":[{"field_key":"pressure","label":"Давление","data_type":"number"},
            {"field_key":"approved","label":"Проверено","data_type":"boolean"},
            {"field_key":"note","label":"Заметка","data_type":"text"},
            {"field_key":"day","label":"День","data_type":"date"},
            {"field_key":"at","label":"Время","data_type":"datetime"},
            {"field_key":"reason","label":"Причина","data_type":"select"}],
        "options":[{"field_key":"reason","code":"repair","label":"Ремонт"}]}`, 201), &typ)
	parse(request(t, h, "POST", "/event-types", "secret", `{"code":"search_other","name":"Остановка"}`, 201), &other)
	add := func(typeID int64, well, kind, start, end, description, fields string) int64 {
		t.Helper()
		body := fmt.Sprintf(`{"event_type_id":%d,"well_id":%q,"status":"draft","time_kind":%q,"started_at":%q,
            "ended_at":%s,"description":%q,"fields":%s}`, typeID, well, kind, start, end, description, fields)
		var e eventRef
		parse(request(t, h, "POST", "/events", "secret", body, 201), &e)
		return e.ID
	}
	const well = "well-search-test"
	const start = "2026-01-12T10:00:00Z"
	open := add(typ.ID, well, "period", "2025-12-01T00:00:00Z", "null", "open", `[{"field_key":"pressure","value_number":0}]`)
	ended := add(typ.ID, well, "period", "2026-01-01T00:00:00Z", `"2026-01-12T10:00:00Z"`, "ended", "[]")
	measured := add(typ.ID, well, "instant", start, "null", "Замер 25%", `[
        {"field_key":"approved","value_boolean":false},{"field_key":"pressure","value_number":100.25},
        {"field_key":"note","value_text":"ПрОба_A"},{"field_key":"day","value_date":"2026-01-12"},
        {"field_key":"at","value_datetime":"2026-01-12T13:00:00+03:00"},{"field_key":"reason","value_option":"repair"}]`)
	tied := add(typ.ID, well, "instant", start, "null", "Замер 25x", `[{"field_key":"pressure","value_number":100.25}]`)
	later := add(typ.ID, well, "instant", "2026-01-13T00:00:00Z", "null", "later", "[]")
	add(other.ID, well, "instant", start, "null", "other type", "[]")
	add(typ.ID, "well-search-other", "instant", start, "null", "other well", "[]")
	base := url.Values{"well_id": {well}, "event_type_id": {strconv.FormatInt(typ.ID, 10)}}
	type summary struct {
		ID       int64
		TypeName string `json:"event_type_name"`
		Well     string `json:"well_id"`
	}
	get := func(extra url.Values) ([]int64, *string) {
		t.Helper()
		params := url.Values{}
		for k, v := range base {
			params[k] = v
		}
		for k, v := range extra {
			params[k] = v
		}
		var page struct {
			Items []summary `json:"items"`
			Next  *string   `json:"next_cursor"`
		}
		parse(request(t, h, "GET", "/events?"+params.Encode(), "secret", "", 200), &page)
		if page.Items == nil {
			t.Fatal("items must be an array")
		}
		ids := make([]int64, 0, len(page.Items))
		for _, s := range page.Items {
			if s.TypeName != "Исследование" || s.Well != well {
				t.Fatalf("unexpected summary: %+v", s)
			}
			ids = append(ids, s.ID)
		}
		return ids, page.Next
	}
	for _, tc := range []struct {
		name   string
		params url.Values
		want   []int64
	}{
		{"period overlap", url.Values{"from": {start}, "to": {"2026-01-13T00:00:00Z"}}, []int64{tied, measured, open}},
		{"description literal", url.Values{"q": {"зАмЕр 25%"}}, []int64{measured}},
		{"extra text literal", url.Values{"q": {"проба_"}}, []int64{measured}},
		{"combined fields", url.Values{"field.approved.eq": {"false"}, "field.pressure.gt": {"100"}, "field.pressure.lte": {"100.25"},
			"field.day.gte": {"2026-01-12"}, "field.at.eq": {start}, "field.reason.eq": {"repair"}}, []int64{measured}},
		{"zero", url.Values{"field.pressure.eq": {"0"}}, []int64{open}},
		{"empty", url.Values{"field.note.eq": {"missing"}}, []int64{}},
	} {
		ids, next := get(tc.params)
		if !slices.Equal(ids, tc.want) || next != nil {
			t.Errorf("%s: ids %v, next %v", tc.name, ids, next)
		}
	}
	for sort, want := range map[string][]int64{
		"-started_at": {later, tied, measured, ended, open}, "started_at": {open, ended, measured, tied, later},
		"field.pressure": {open, measured, tied, ended, later}, "-field.pressure": {tied, measured, open, later, ended},
	} {
		params := url.Values{"sort": {sort}, "limit": {"1"}}
		var got []int64
		for {
			ids, next := get(params)
			got = append(got, ids...)
			if next == nil {
				break
			}
			if len(ids) == 0 || len(got) >= len(want) {
				t.Fatalf("unexpected cursor: %s %v", sort, got)
			}
			params.Set("cursor", *next)
		}
		if !slices.Equal(got, want) {
			t.Errorf("sort %s: %v", sort, got)
		}
	}
	for _, param := range []string{"field.unknown.eq=x", "sort=field.unknown", "field.pressure.gt=bad", "field.approved.gt=true", "field.at.eq=now", "field.day.eq=today"} {
		request(t, h, "GET", "/events?"+base.Encode()+"&"+param, "secret", "", 400)
	}
	_, next := get(url.Values{"limit": {"1"}})
	request(t, h, "GET", "/events?"+url.Values{"cursor": {*next}, "well_id": {"different"}}.Encode(), "secret", "", 400)
	add(typ.ID, well, "instant", "2026-01-14T00:00:00Z", "null", "newer event", "[]")
	ids, _ := get(url.Values{"limit": {"1"}, "cursor": {*next}})
	if !slices.Equal(ids, []int64{tied}) {
		t.Fatalf("inserting a newer event shifted the next page: %v", ids)
	}
}
