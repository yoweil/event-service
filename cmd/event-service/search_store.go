package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"strconv"
	"strings"

	"github.com/lib/pq"
)

type eventPage struct {
	Items      []json.RawMessage `json:"items"`
	NextCursor *string           `json:"next_cursor"`
}

var valueColumns = map[string]string{
	"integer": "value_number", "number": "value_number", "text": "value_text", "select": "value_option",
	"boolean": "value_boolean", "date": "value_date", "datetime": "value_datetime",
}

func (a *api) searchFieldKinds(ctx context.Context, s eventSearch) (map[string]string, error) {
	var keys []string
	if s.sortKey != "" {
		keys = append(keys, s.sortKey)
	}
	for _, filter := range s.filters {
		keys = append(keys, filter.key)
	}
	if len(keys) == 0 {
		return nil, nil
	}
	rows, err := a.db.QueryContext(ctx, `SELECT field_key, data_type FROM public.event_type_fields
        WHERE event_type_id=$1 AND field_key=ANY($2::text[])`, s.typeID, pq.Array(keys))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	kinds := make(map[string]string)
	for rows.Next() {
		var key, kind string
		if err := rows.Scan(&key, &kind); err != nil {
			return nil, err
		}
		kinds[key] = kind
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for _, key := range keys {
		if _, ok := kinds[key]; !ok {
			return nil, searchError("unknown field for this event type: " + key)
		}
	}
	return kinds, nil
}

func (s eventSearch) query(kinds map[string]string) (string, []any, error) {
	var args []any
	bind := func(value any) string {
		args = append(args, value)
		return "$" + strconv.Itoa(len(args))
	}
	var predicates []string
	if s.well != "" {
		predicates = append(predicates, "e.well_id = "+bind(s.well))
	}
	if s.typeID != 0 {
		predicates = append(predicates, "e.event_type_id = "+bind(s.typeID))
	}
	if s.from != nil {
		lower := bind(*s.from)
		predicates = append(predicates, "(e.started_at >= "+lower+" OR (e.time_kind = 'period' AND (e.ended_at IS NULL OR e.ended_at > "+lower+")))")
	}
	if s.to != nil {
		predicates = append(predicates, "e.started_at < "+bind(*s.to))
	}
	if s.text != "" {
		needle := "lower(" + bind(s.text) + "::text)"
		predicates = append(predicates, "(strpos(lower(e.description), "+needle+`) > 0 OR EXISTS (
            SELECT FROM public.event_field_values v WHERE v.event_id=e.id AND strpos(lower(v.value_text), `+needle+") > 0))")
	}
	for _, f := range s.filters {
		kind := kinds[f.key]
		if f.op != "eq" && (kind == "text" || kind == "select" || kind == "boolean") {
			return "", nil, searchError("this field supports only eq: " + f.key)
		}
		value, err := searchValue(kind, f.value)
		if err != nil {
			return "", nil, err
		}
		predicates = append(predicates, `EXISTS (SELECT FROM public.event_field_values v
            WHERE v.event_type_id=e.event_type_id AND v.event_id=e.id AND v.field_key=`+bind(f.key)+
			" AND v."+valueColumns[kind]+" "+comparisons[f.op]+" "+bind(value)+")")
	}

	sortExpr := "e.started_at"
	join := ""
	direction, after := " ASC", ">"
	if s.descending {
		direction, after = " DESC", "<"
	}
	order := direction
	if s.sortKey != "" {
		join = " LEFT JOIN public.event_field_values sv ON sv.event_id=e.id AND sv.field_key=" + bind(s.sortKey)
		sortExpr = "sv." + valueColumns[kinds[s.sortKey]]
		order += " NULLS LAST"
	}
	if c := s.after; c != nil {
		id := bind(c.ID)
		if c.Value == nil {
			predicates = append(predicates, "("+sortExpr+" IS NULL AND e.id "+after+" "+id+")")
		} else {
			next := "(" + sortExpr + ",e.id) " + after + " (" + bind(*c.Value) + "," + id + ")"
			if s.sortKey != "" {
				next = "(" + next + " OR " + sortExpr + " IS NULL)"
			}
			predicates = append(predicates, next)
		}
	}
	where := ""
	if len(predicates) > 0 {
		where = " WHERE " + strings.Join(predicates, " AND ")
	}
	query := `SELECT e.id, to_json(` + sortExpr + `) #>> '{}', json_build_object(
            'id',e.id,'well_id',e.well_id,'event_type_id',e.event_type_id,'event_type_name',t.name,
            'started_at',e.started_at,'ended_at',e.ended_at,'time_kind',e.time_kind,
            'status',e.status,'description',e.description,'revision',e.revision)
        FROM public.events e JOIN public.event_types t ON t.id=e.event_type_id` + join + where +
		" ORDER BY " + sortExpr + order + ", e.id" + direction + " LIMIT " + bind(s.limit+1)
	return query, args, nil
}

func (a *api) searchEvents(ctx context.Context, s eventSearch) (eventPage, error) {
	page := eventPage{Items: make([]json.RawMessage, 0, s.limit)}
	kinds, err := a.searchFieldKinds(ctx, s)
	if err != nil {
		return page, err
	}
	query, args, err := s.query(kinds)
	if err != nil {
		return page, err
	}
	rows, err := a.db.QueryContext(ctx, query, args...)
	if err != nil {
		return page, err
	}
	defer rows.Close()
	last := pageCursor{Scope: s.scope}
	for rows.Next() {
		if len(page.Items) == s.limit {
			data, err := json.Marshal(last)
			if err != nil {
				return page, err
			}
			encoded := base64.RawURLEncoding.EncodeToString(data)
			page.NextCursor = &encoded
			break
		}
		var item json.RawMessage
		if err := rows.Scan(&last.ID, &last.Value, &item); err != nil {
			return page, err
		}
		page.Items = append(page.Items, item)
	}
	return page, rows.Err()
}
