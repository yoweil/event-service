package main

import (
	"encoding/json"
	"net/http"
	"net/url"
	"strconv"
)

func (a *api) eventHistory(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(w, r, "event")
	if !ok {
		return
	}
	query, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil {
		respondError(w, http.StatusBadRequest, "invalid query string")
		return
	}
	var before *int64
	if values, exists := query["before_revision"]; exists {
		revision, err := strconv.ParseInt(values[0], 10, 64)
		if len(values) != 1 || err != nil || revision < 1 {
			respondError(w, http.StatusBadRequest, "expected a positive before_revision")
			return
		}
		before = &revision
	}
	var history json.RawMessage
	err = a.db.QueryRowContext(r.Context(), `
        SELECT coalesce((SELECT json_agg(page ORDER BY page.revision DESC) FROM (
            SELECT c.revision, c.operation, c.changed_at, c.actor_kind, c.actor_id,
                (SELECT coalesce(json_agg(json_build_object(
                    'scope', CASE WHEN i.base_key IS NULL THEN 'field' ELSE 'base' END,
                    'key', coalesce(i.base_key,i.field_key), 'old_value', i.old_value, 'new_value', i.new_value
                ) ORDER BY i.id), '[]'::json) FROM public.event_change_items i
                 WHERE i.event_id=c.event_id AND i.revision=c.revision) AS changes
            FROM public.event_changes c WHERE c.event_id=e.id AND ($2::bigint IS NULL OR c.revision < $2)
            ORDER BY c.revision DESC LIMIT 20
        ) AS page), '[]'::json) FROM public.events e WHERE e.id=$1`, id, before).Scan(&history)
	if err != nil {
		databaseError(w, err)
		return
	}
	respond(w, http.StatusOK, history)
}
