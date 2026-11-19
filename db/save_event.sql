BEGIN;

DO $$
BEGIN
    IF to_regtype('public.event_field_edit') IS NULL THEN
        CREATE TYPE public.event_field_edit AS (
            field_key text,
            value_text text,
            value_number numeric,
            value_boolean boolean,
            value_date date,
            value_datetime timestamptz,
            value_option text
        );
    END IF;
    IF to_regtype('public.event_property_change') IS NULL THEN
        CREATE TYPE public.event_property_change AS (
            base_key text, field_key text, old_value text, new_value text
        );
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.event_audit_time(moment timestamptz)
RETURNS text LANGUAGE sql STABLE STRICT
SET timezone = 'UTC' SET datestyle = 'ISO, YMD'
AS $$
    SELECT regexp_replace(moment::text, '^([^ ]+) ([^ ]+)[+]00( BC)?$', '\1T\2Z\3');
$$;

CREATE OR REPLACE FUNCTION public.event_audit_value(v public.event_field_values)
RETURNS text LANGUAGE sql STABLE
SET datestyle = 'ISO, YMD'
AS $$
    SELECT coalesce(v.value_text, trim_scale(v.value_number)::text, v.value_boolean::text,
                    v.value_date::text, public.event_audit_time(v.value_datetime), v.value_option);
$$;

CREATE OR REPLACE FUNCTION public.save_event_with_source(
    p_type_id bigint, p_well_id text, p_status text, p_time_kind text,
    p_started_at timestamptz, p_ended_at timestamptz, p_description text,
    p_actor_kind text, p_actor_id text, p_fields public.event_field_edit[],
    p_event_id bigint, p_expected_revision bigint, p_source_notification_id uuid
) RETURNS public.events
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE
    previous_card public.events;
    card public.events;
    type_archived boolean;
    edit public.event_field_edit;
    definition public.event_type_fields;
    previous_value public.event_field_values;
    saved_value public.event_field_values;
    changes public.event_property_change[];
    invalid_key text;
BEGIN
    IF (p_event_id IS NULL) <> (p_expected_revision IS NULL) OR p_expected_revision < 1 THEN
        RAISE EXCEPTION 'Update requires an event id and a positive expected revision' USING ERRCODE = '22023';
    END IF;
    IF p_actor_kind IS NULL OR p_actor_kind NOT IN ('user','service')
       OR p_actor_id IS NULL OR btrim(p_actor_id) = '' THEN
        RAISE EXCEPTION 'Missing or invalid actor' USING ERRCODE = '22023';
    END IF;
    IF p_source_notification_id IS NOT NULL AND NOT EXISTS (
        SELECT FROM public.event_notification_outbox
        WHERE id = p_source_notification_id AND event_id = p_event_id
          AND revision = p_expected_revision AND attempts > 0
    ) THEN
        RAISE EXCEPTION 'Notification does not match an attempted delivery for this event revision' USING ERRCODE = '22023';
    END IF;
    IF p_fields IS NULL OR EXISTS (
        SELECT FROM unnest(p_fields) AS patch GROUP BY patch.field_key
        HAVING patch.field_key IS NULL OR count(*) > 1
    ) THEN
        RAISE EXCEPTION 'Each edit needs a distinct field key' USING ERRCODE = '22023';
    END IF;

    SELECT t.is_archived INTO STRICT type_archived FROM public.event_types AS t
    WHERE t.id = p_type_id FOR SHARE;
    IF p_event_id IS NULL THEN
        IF type_archived THEN
            RAISE EXCEPTION 'Archived event type' USING ERRCODE = '23514';
        END IF;
        INSERT INTO public.events (event_type_id, well_id, status, time_kind, started_at, ended_at,
                                   description, created_by_kind, created_by_id)
        VALUES (p_type_id, p_well_id, p_status, p_time_kind, p_started_at, p_ended_at,
                p_description, p_actor_kind, p_actor_id)
        RETURNING * INTO card;
    ELSE
        SELECT * INTO STRICT previous_card FROM public.events
        WHERE id = p_event_id AND event_type_id = p_type_id FOR UPDATE;
        IF previous_card.revision <> p_expected_revision THEN
            RAISE EXCEPTION 'Event % has revision %, expected %', p_event_id, previous_card.revision,
                p_expected_revision USING ERRCODE = 'EV409';
        END IF;
        card := previous_card;
    END IF;

    changes := ARRAY(
        SELECT ROW(d.key, NULL, d.old_value, d.new_value)::public.event_property_change
        FROM (VALUES
            ('well_id', previous_card.well_id, p_well_id),
            ('status', previous_card.status, p_status),
            ('time_kind', previous_card.time_kind, p_time_kind),
            ('started_at', public.event_audit_time(previous_card.started_at), public.event_audit_time(p_started_at)),
            ('ended_at', public.event_audit_time(previous_card.ended_at), public.event_audit_time(p_ended_at)),
            ('description', previous_card.description, p_description)
        ) AS d(key, old_value, new_value)
        WHERE d.old_value IS DISTINCT FROM d.new_value
    );

    FOREACH edit IN ARRAY p_fields LOOP
        SELECT * INTO definition FROM public.event_type_fields
        WHERE event_type_id = p_type_id AND field_key = edit.field_key;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unknown field % for this event type', edit.field_key USING ERRCODE = '22023';
        END IF;
        SELECT * INTO previous_value FROM public.event_field_values
        WHERE event_id = card.id AND field_key = edit.field_key;

        IF ROW(edit.value_text, edit.value_number, edit.value_boolean, edit.value_date,
               edit.value_datetime, edit.value_option) IS NOT DISTINCT FROM
           ROW(previous_value.value_text, previous_value.value_number, previous_value.value_boolean,
               previous_value.value_date, previous_value.value_datetime, previous_value.value_option) THEN
            CONTINUE;
        END IF;

        IF definition.is_archived THEN
            RAISE EXCEPTION 'Archived field: %', edit.field_key USING ERRCODE = '23514';
        END IF;
        IF num_nonnulls(edit.value_text, edit.value_number, edit.value_boolean, edit.value_date,
                        edit.value_datetime, edit.value_option) = 0 THEN
            DELETE FROM public.event_field_values WHERE event_id = card.id AND field_key = edit.field_key;
            saved_value := NULL;
        ELSE
            IF edit.value_option IS NOT NULL AND NOT EXISTS (
                SELECT FROM public.event_field_options WHERE event_type_id = p_type_id
                  AND field_key = edit.field_key AND code = edit.value_option AND NOT is_archived
            ) THEN
                RAISE EXCEPTION 'Unknown or archived option for %', edit.field_key USING ERRCODE = '23514';
            END IF;

            INSERT INTO public.event_field_values (event_id, event_type_id, field_key, data_type,
                value_text, value_number, value_boolean, value_date, value_datetime, value_option)
            VALUES (card.id, p_type_id, edit.field_key, definition.data_type, edit.value_text,
                edit.value_number, edit.value_boolean, edit.value_date, edit.value_datetime, edit.value_option)
            ON CONFLICT (event_id, field_key) DO UPDATE SET
                (value_text, value_number, value_boolean, value_date, value_datetime, value_option) =
                (excluded.value_text, excluded.value_number, excluded.value_boolean,
                 excluded.value_date, excluded.value_datetime, excluded.value_option)
            RETURNING * INTO saved_value;
        END IF;
        changes := array_append(changes, ROW(NULL, edit.field_key, public.event_audit_value(previous_value),
            public.event_audit_value(saved_value))::public.event_property_change);
    END LOOP;

    SELECT f.field_key INTO invalid_key FROM public.event_type_fields f
    LEFT JOIN public.event_field_values v ON v.event_id = card.id AND v.field_key = f.field_key
    WHERE f.event_type_id = p_type_id AND NOT f.is_archived AND (
        (p_status = 'ready' AND f.is_required AND
            (v.event_id IS NULL OR (f.data_type = 'text' AND v.value_text ~ '^[[:space:]]*$')))
        OR v.value_number < f.min_number OR v.value_number > f.max_number
        OR length(v.value_text) < f.min_length OR length(v.value_text) > f.max_length
    ) ORDER BY f.sort_order, f.field_key LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'Missing required value or violated bounds for %', invalid_key USING ERRCODE = '23514';
    END IF;

    IF p_event_id IS NOT NULL THEN
        IF cardinality(changes) = 0 THEN RETURN previous_card; END IF;
        UPDATE public.events SET well_id = p_well_id, status = p_status, time_kind = p_time_kind,
            started_at = p_started_at, ended_at = p_ended_at, description = p_description,
            revision = revision + 1, updated_at = clock_timestamp()
        WHERE id = p_event_id RETURNING * INTO card;
    END IF;

    INSERT INTO public.event_changes (event_id, revision, operation, actor_kind, actor_id, changed_at, source_notification_id)
    VALUES (card.id, card.revision, CASE WHEN p_event_id IS NULL THEN 'created' ELSE 'updated' END,
            p_actor_kind, p_actor_id, card.updated_at, p_source_notification_id);
    INSERT INTO public.event_change_items (event_id, revision, event_type_id, base_key, field_key, old_value, new_value)
    SELECT card.id, card.revision, p_type_id, d.base_key, d.field_key, d.old_value, d.new_value
    FROM unnest(changes) AS d;
    RETURN card;
END;
$$;

CREATE OR REPLACE FUNCTION public.save_event(
    p_type_id bigint, p_well_id text, p_status text, p_time_kind text,
    p_started_at timestamptz, p_ended_at timestamptz, p_description text,
    p_actor_kind text, p_actor_id text, p_fields public.event_field_edit[] DEFAULT '{}',
    p_event_id bigint DEFAULT NULL, p_expected_revision bigint DEFAULT NULL
) RETURNS public.events LANGUAGE sql AS $$
    SELECT * FROM public.save_event_with_source(
        p_type_id, p_well_id, p_status, p_time_kind, p_started_at, p_ended_at, p_description,
        p_actor_kind, p_actor_id, p_fields, p_event_id, p_expected_revision, NULL
    );
$$;

CREATE OR REPLACE FUNCTION public.record_attachment_result(
    p_event bigint, p_attachment bigint, p_notice uuid, p_key text, p_unit text,
    p_value numeric, p_sheet text, p_cell text, p_issue text
) RETURNS public.attachment_results LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE
    uploaded_revision bigint;
    card public.events;
    definition public.event_type_fields;
    result public.attachment_results;
    problem text := p_issue;
    applied bigint;
BEGIN
    SELECT a.upload_revision INTO STRICT uploaded_revision
    FROM public.event_attachments a JOIN public.notification_outbox n ON n.attachment_id = a.id
    WHERE a.event_id = p_event AND a.id = p_attachment AND n.id = p_notice AND n.attempts > 0;

    PERFORM t.id FROM public.event_types t JOIN public.events e ON e.event_type_id = t.id
    WHERE e.id = p_event FOR SHARE OF t;
    SELECT * INTO STRICT card FROM public.events WHERE id = p_event FOR UPDATE;
    SELECT * INTO result FROM public.attachment_results WHERE attachment_id = p_attachment AND field_key = p_key;
    IF FOUND THEN RETURN result; END IF;

    SELECT * INTO definition FROM public.event_type_fields WHERE event_type_id = card.event_type_id AND field_key = p_key;
    IF problem IS NULL THEN
        CASE
        WHEN definition.data_type IS NULL OR definition.is_archived OR definition.data_type NOT IN ('number','integer') THEN
            problem := 'Поле отсутствует, архивировано или имеет другой тип.';
        WHEN p_unit IS DISTINCT FROM definition.unit_code THEN
            problem := 'Единица измерения файла отличается от единицы поля.';
        WHEN uploaded_revision IS DISTINCT FROM card.revision THEN
            problem := 'Ревизия при загрузке неизвестна или карточка уже изменилась.';
        WHEN EXISTS (SELECT FROM public.event_field_values WHERE event_id = p_event AND field_key = p_key) THEN
            problem := 'В карточке уже есть значение этого поля.';
        ELSE
            IF p_value IS NULL OR p_sheet IS NULL OR p_cell IS NULL THEN
                RAISE EXCEPTION 'Expected a numeric value and its worksheet location' USING ERRCODE = '22023';
            END IF;
            BEGIN
                SELECT s.revision INTO applied FROM public.save_event(card.event_type_id, card.well_id,
                    card.status, card.time_kind, card.started_at, card.ended_at, card.description,
                    'service', 'attachment-processor',
                    ARRAY[ROW(p_key,NULL,p_value,NULL,NULL,NULL,NULL)::public.event_field_edit],
                    card.id, card.revision) s;
            EXCEPTION WHEN check_violation OR invalid_parameter_value THEN
                problem := 'Значение не прошло проверку настроек карточки.';
            END;
        END CASE;
    END IF;
    INSERT INTO public.attachment_results (attachment_id, field_key, unit_code, value_number,
        sheet_name, cell_ref, reason, applied_revision)
    VALUES (p_attachment, p_key, p_unit, p_value, p_sheet, p_cell, problem, applied)
    RETURNING * INTO result;
    RETURN result;
END;
$$;

COMMIT;
