package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"regexp"
	"time"

	"github.com/lib/pq"
)

type queryer interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
	QueryContext(context.Context, string, ...any) (*sql.Rows, error)
}

type fieldDefinition struct {
	Key         string       `json:"field_key"`
	Label       string       `json:"label"`
	Type        string       `json:"data_type"`
	Required    bool         `json:"is_required"`
	Description *string      `json:"description"`
	Unit        *string      `json:"unit_code"`
	MinNumber   *json.Number `json:"min_number"`
	MaxNumber   *json.Number `json:"max_number"`
	MinLength   *int32       `json:"min_length"`
	MaxLength   *int32       `json:"max_length"`
	Order       int32        `json:"sort_order"`
}

type optionDefinition struct {
	Key   string `json:"field_key"`
	Code  string `json:"code"`
	Label string `json:"label"`
	Order int32  `json:"sort_order"`
}

type createTypeInput struct {
	Code        string             `json:"code"`
	Name        string             `json:"name"`
	Description *string            `json:"description"`
	Fields      []fieldDefinition  `json:"fields"`
	Options     []optionDefinition `json:"options"`
}

var timestampFormat = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$`)

type timestamp string

func (t *timestamp) UnmarshalJSON(data []byte) error {
	var raw string
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	utc, err := parseTimestamp(raw)
	if err != nil {
		return err
	}
	*t = timestamp(utc.Format(time.RFC3339Nano))
	return nil
}

func parseTimestamp(raw string) (time.Time, error) {
	parsed, err := time.Parse(time.RFC3339Nano, raw)
	if err != nil || !timestampFormat.MatchString(raw) {
		return time.Time{}, errors.New("expected RFC 3339 timestamp with timezone")
	}
	utc := parsed.UTC()
	if utc.Year() < 1 || utc.Year() > 9999 {
		return time.Time{}, errors.New("timestamp outside supported UTC years")
	}
	return utc, nil
}

type fieldEdit struct {
	Key      string       `json:"field_key"`
	Text     *string      `json:"value_text"`
	Number   *json.Number `json:"value_number"`
	Boolean  *bool        `json:"value_boolean"`
	Date     *string      `json:"value_date"`
	DateTime *timestamp   `json:"value_datetime"`
	Option   *string      `json:"value_option"`
}

type saveInput struct {
	TypeID               int64       `json:"event_type_id"`
	WellID               string      `json:"well_id"`
	Status               string      `json:"status"`
	TimeKind             string      `json:"time_kind"`
	Start                *timestamp  `json:"started_at"`
	End                  *timestamp  `json:"ended_at"`
	Description          *string     `json:"description"`
	Fields               []fieldEdit `json:"fields"`
	ExpectedRevision     *int64      `json:"expected_revision"`
	SourceNotificationID *string     `json:"source_notification_id"`
}

func arrayParam[T any](items []T) (string, error) {
	if len(items) == 0 {
		return "[]", nil
	}
	data, err := json.Marshal(items)
	return string(data), err
}

type eventTypeRef struct {
	ID   int64  `json:"id"`
	Code string `json:"code"`
	Name string `json:"name"`
}

func (a *api) readTypes(ctx context.Context, includeArchived bool) (json.RawMessage, error) {
	var types json.RawMessage
	err := a.db.QueryRowContext(ctx, `
		SELECT coalesce(json_agg(t ORDER BY t.name, t.code), '[]'::json)
		FROM (
			SELECT id, code, name, description, is_archived
			FROM public.event_types WHERE $1 OR NOT is_archived
		) AS t`, includeArchived).Scan(&types)
	return types, err
}

func (a *api) readType(ctx context.Context, id int64, includeArchived bool) (json.RawMessage, error) {
	var definition json.RawMessage
	err := a.db.QueryRowContext(ctx, `
		WITH options AS (
			SELECT field_key, json_agg(json_build_object(
				'code', code, 'label', label, 'sort_order', sort_order, 'is_archived', is_archived
			) ORDER BY sort_order, code) AS choices
			FROM public.event_field_options
			WHERE event_type_id = $1 AND ($2 OR NOT is_archived)
			GROUP BY field_key
		), fields AS (
			SELECT f.field_key, f.label, f.data_type, f.is_required, f.is_archived,
			       f.description, f.unit_code, f.min_number, f.max_number,
			       f.min_length, f.max_length, f.sort_order, coalesce(o.choices, '[]'::json) AS options
			FROM public.event_type_fields AS f LEFT JOIN options AS o USING (field_key)
			WHERE f.event_type_id = $1 AND ($2 OR NOT f.is_archived)
		)
		SELECT row_to_json(definition) FROM (
			SELECT t.id, t.code, t.name, t.description, t.is_archived, t.updated_at,
			       (SELECT coalesce(json_agg(f ORDER BY f.sort_order, f.field_key), '[]'::json)
			        FROM fields AS f) AS fields
			FROM public.event_types AS t WHERE t.id = $1
		) AS definition`, id, includeArchived).Scan(&definition)
	return definition, err
}

func (a *api) insertType(ctx context.Context, input createTypeInput) (eventTypeRef, error) {
	var result eventTypeRef
	fields, err := arrayParam(input.Fields)
	if err != nil {
		return result, err
	}
	options, err := arrayParam(input.Options)
	if err != nil {
		return result, err
	}
	who := requestActor(ctx)
	err = a.db.QueryRowContext(ctx, `
        SELECT id, code, name FROM public.create_event_type($1, $2, $3, $4, $5,
            ARRAY(SELECT f FROM json_populate_recordset(NULL::public.event_field_definition, $6::json) AS f),
            ARRAY(SELECT o FROM json_populate_recordset(NULL::public.event_option_definition, $7::json) AS o))`,
		input.Code, input.Name, who.Kind, who.ID, input.Description, fields, options).Scan(&result.ID, &result.Code, &result.Name)
	return result, err
}

type editTypeInput struct {
	ExpectedUpdatedAt *timestamp         `json:"expected_updated_at"`
	Name              *string            `json:"name"`
	Description       *string            `json:"description"`
	Fields            []fieldDefinition  `json:"add_fields"`
	Options           []optionDefinition `json:"options"`
	ArchiveKeys       []string           `json:"archive_fields"`
}

func (a *api) applyTypeEdit(ctx context.Context, id int64, input editTypeInput) (eventTypeRef, error) {
	var result eventTypeRef
	fields, err := arrayParam(input.Fields)
	if err != nil {
		return result, err
	}
	options, err := arrayParam(input.Options)
	if err != nil {
		return result, err
	}
	err = a.db.QueryRowContext(ctx, `
		SELECT id, code, name FROM public.edit_event_type($1, $2, $3, $4,
			ARRAY(SELECT f FROM json_populate_recordset(NULL::public.event_field_definition, $5::json) AS f),
			ARRAY(SELECT o FROM json_populate_recordset(NULL::public.event_option_definition, $6::json) AS o),
			$7::text[])`, id, input.ExpectedUpdatedAt, input.Name, input.Description, fields, options,
		pq.Array(input.ArchiveKeys)).Scan(&result.ID, &result.Code, &result.Name)
	return result, err
}

type eventRef struct {
	ID       int64 `json:"id"`
	Revision int64 `json:"revision"`
}

func (a *api) persistEvent(ctx context.Context, id *int64, input saveInput) (eventRef, error) {
	var result eventRef
	fields, err := arrayParam(input.Fields)
	if err != nil {
		return result, err
	}
	who := requestActor(ctx)
	err = a.db.QueryRowContext(ctx, `
        SELECT id, revision FROM public.save_event_with_source($1, $2, $3, $4, $5, $6, coalesce($7,''), $8, $9,
            ARRAY(SELECT f FROM json_populate_recordset(NULL::public.event_field_edit, $10::json) AS f), $11, $12, $13)`,
		input.TypeID, input.WellID, input.Status, input.TimeKind, input.Start, input.End, input.Description,
		who.Kind, who.ID, fields, id, input.ExpectedRevision, input.SourceNotificationID).Scan(&result.ID, &result.Revision)
	return result, err
}

func (a *api) readEvent(ctx context.Context, id int64) (json.RawMessage, error) {
	var card json.RawMessage
	err := a.db.QueryRowContext(ctx, `
        SELECT row_to_json(card) FROM (
            SELECT e.*, coalesce((
                SELECT json_agg(json_strip_nulls(row_to_json(f)) ORDER BY f.field_key)
                FROM (
                    SELECT field_key, value_text, value_number, value_boolean,
                           value_date, value_datetime, value_option
                    FROM public.event_field_values WHERE event_id = e.id
                ) AS f
            ), '[]'::json) AS fields
            FROM public.events AS e WHERE e.id = $1
        ) AS card`, id).Scan(&card)
	return card, err
}
