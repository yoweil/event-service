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
    IF to_regtype('public.attachment_result_input') IS NULL THEN
        CREATE TYPE public.attachment_result_input AS (
            field_key text,
            unit_code text,
            value_number numeric,
            sheet_name text,
            cell_ref text,
            issue text
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

CREATE OR REPLACE FUNCTION public.record_attachment_results(
    p_event bigint, p_attachment bigint, p_notice uuid, p_results public.attachment_result_input[]
) RETURNS public.attachment_results[] LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE
    uploaded_revision bigint;
    card public.events;
    pending public.attachment_result_input[];
    edits public.event_field_edit[];
    applied bigint;
    save_failure text;
BEGIN
    IF coalesce(cardinality(p_results), 0) = 0 OR EXISTS (
        SELECT FROM unnest(p_results) AS input
        WHERE input.field_key IS NULL OR input.field_key COLLATE "C" !~ '^[a-z][a-z0-9_]{0,63}$'
           OR (input.value_number IS NULL AND input.issue IS NULL)
           OR (input.issue IS NOT NULL AND btrim(input.issue) = '')
           OR (input.value_number IS NOT NULL AND (
               coalesce(btrim(input.sheet_name), '') = '' OR coalesce(btrim(input.cell_ref), '') = ''
               OR input.value_number IN ('NaN','Infinity','-Infinity')
           ))
    ) THEN
        RAISE EXCEPTION 'Expected a field key and either a sourced number or an issue for each result'
            USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT FROM unnest(p_results) AS input GROUP BY input.field_key HAVING count(*) > 1) THEN
        RAISE EXCEPTION 'Each field may occur only once in a batch' USING ERRCODE = '22023';
    END IF;

    SELECT a.upload_revision INTO STRICT uploaded_revision
    FROM public.event_attachments a JOIN public.notification_outbox n ON n.attachment_id = a.id
    WHERE a.event_id = p_event AND a.id = p_attachment AND n.id = p_notice AND n.attempts > 0;

    PERFORM t.id FROM public.event_types t JOIN public.events e ON e.event_type_id = t.id
    WHERE e.id = p_event FOR SHARE OF t;
    SELECT * INTO STRICT card FROM public.events WHERE id = p_event FOR UPDATE;

    pending := ARRAY(
        SELECT ROW(input.field_key, input.unit_code, input.value_number, input.sheet_name, input.cell_ref,
            CASE
                WHEN input.issue IS NOT NULL THEN input.issue
                WHEN f.field_key IS NULL OR f.is_archived OR f.data_type NOT IN ('number','integer')
                    THEN 'Поле отсутствует, архивировано или имеет другой тип.'
                WHEN input.unit_code IS DISTINCT FROM f.unit_code
                    THEN 'Единица измерения файла отличается от единицы поля.'
                WHEN uploaded_revision IS DISTINCT FROM card.revision
                    THEN 'Ревизия при загрузке неизвестна или карточка уже изменилась.'
                WHEN v.event_id IS NOT NULL
                    THEN 'В карточке уже есть значение этого поля.'
                WHEN input.value_number < f.min_number OR input.value_number > f.max_number
                  OR (f.data_type = 'integer' AND trunc(input.value_number) <> input.value_number)
                    THEN 'Значение не прошло проверку настроек карточки.'
            END
        )::public.attachment_result_input
        FROM unnest(p_results) WITH ORDINALITY AS input
        LEFT JOIN public.event_type_fields f ON f.event_type_id = card.event_type_id AND f.field_key = input.field_key
        LEFT JOIN public.event_field_values v ON v.event_id = card.id AND v.field_key = input.field_key
        WHERE NOT EXISTS (
            SELECT FROM public.attachment_results r WHERE r.attachment_id = p_attachment AND r.field_key = input.field_key
        )
        ORDER BY input.ordinality
    );

    edits := ARRAY(
        SELECT ROW(input.field_key,NULL,input.value_number,NULL,NULL,NULL,NULL)::public.event_field_edit
        FROM unnest(pending) AS input WHERE input.issue IS NULL
    );
    IF cardinality(edits) > 0 THEN
        BEGIN
            SELECT s.revision INTO applied
            FROM public.save_event(card.event_type_id, card.well_id, card.status, card.time_kind,
                card.started_at, card.ended_at, card.description, 'service', 'attachment-processor',
                edits, card.id, card.revision) s;
        EXCEPTION WHEN check_violation OR invalid_parameter_value THEN
            save_failure := 'Значение не прошло проверку настроек карточки.';
        END;
    END IF;

    INSERT INTO public.attachment_results (attachment_id, field_key, unit_code, value_number,
        sheet_name, cell_ref, reason, applied_revision)
    SELECT p_attachment, input.field_key, input.unit_code, input.value_number, input.sheet_name, input.cell_ref,
        coalesce(input.issue, save_failure), CASE WHEN input.issue IS NULL THEN applied END
    FROM unnest(pending) AS input;

    RETURN (
        SELECT array_agg(r ORDER BY input.ordinality)
        FROM unnest(p_results) WITH ORDINALITY AS input
        JOIN public.attachment_results r ON r.attachment_id = p_attachment AND r.field_key = input.field_key
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.record_attachment_result(
    p_event bigint, p_attachment bigint, p_notice uuid, p_key text, p_unit text,
    p_value numeric, p_sheet text, p_cell text, p_issue text
) RETURNS public.attachment_results LANGUAGE sql AS $$
    SELECT (public.record_attachment_results(p_event, p_attachment, p_notice,
        ARRAY[ROW(p_key,p_unit,p_value,p_sheet,p_cell,p_issue)::public.attachment_result_input]))[1];
$$;

CREATE OR REPLACE FUNCTION public.review_attachment_result(
    p_event bigint, p_attachment bigint, p_result bigint, p_expected_revision bigint,
    p_decision text, p_value numeric, p_actor text
) RETURNS public.attachment_results LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE
    card public.events;
    proposal public.attachment_results;
    definition public.event_type_fields;
    chosen_value numeric;
    saved_revision bigint;
BEGIN
    IF p_decision IS NULL OR p_decision NOT IN ('accept','correct','reject')
       OR (p_decision = 'correct') <> (p_value IS NOT NULL)
       OR p_expected_revision IS NULL OR p_expected_revision < 1
       OR coalesce(btrim(p_actor), '') = '' THEN
        RAISE EXCEPTION 'Invalid review decision, value, revision or author' USING ERRCODE = '22023';
    END IF;

    PERFORM t.id FROM public.event_types t JOIN public.events e ON e.event_type_id = t.id
    WHERE e.id = p_event FOR SHARE OF t;
    SELECT * INTO STRICT card FROM public.events WHERE id = p_event FOR UPDATE;
    SELECT r.* INTO STRICT proposal
    FROM public.attachment_results r JOIN public.event_attachments a ON a.id = r.attachment_id
    WHERE r.id = p_result AND a.id = p_attachment AND a.event_id = p_event;

    IF proposal.review_decision = p_decision AND proposal.reviewed_by_id = p_actor
       AND (p_decision <> 'correct' OR proposal.reviewed_value_number = p_value) THEN
        RETURN proposal;
    END IF;
    IF proposal.applied_revision IS NOT NULL OR proposal.review_decision IS NOT NULL THEN
        RAISE EXCEPTION 'Result has already been resolved' USING ERRCODE = 'AR409';
    END IF;
    IF card.revision <> p_expected_revision THEN
        RAISE EXCEPTION 'Event revision has changed' USING ERRCODE = 'EV409';
    END IF;

    IF p_decision <> 'reject' THEN
        SELECT * INTO definition FROM public.event_type_fields
        WHERE event_type_id = card.event_type_id AND field_key = proposal.field_key;
        IF NOT FOUND OR definition.is_archived OR definition.data_type NOT IN ('integer','number') THEN
            RAISE EXCEPTION 'Review requires an active numeric field' USING ERRCODE = '22023';
        END IF;
        IF p_decision = 'accept' AND
           (proposal.value_number IS NULL OR proposal.unit_code IS DISTINCT FROM definition.unit_code) THEN
            RAISE EXCEPTION 'Accept requires a proposed number in the field unit' USING ERRCODE = '22023';
        END IF;
        chosen_value := CASE WHEN p_decision = 'accept' THEN proposal.value_number ELSE p_value END;
        SELECT s.revision INTO saved_revision
        FROM public.save_event(card.event_type_id, card.well_id, card.status, card.time_kind,
            card.started_at, card.ended_at, card.description, 'user', p_actor,
            ARRAY[ROW(proposal.field_key,NULL,chosen_value,NULL,NULL,NULL,NULL)::public.event_field_edit],
            card.id, card.revision) s;
    END IF;

    UPDATE public.attachment_results SET review_decision = p_decision, reviewed_by_id = p_actor,
        reviewed_at = clock_timestamp(), reviewed_value_number = chosen_value, reviewed_revision = saved_revision
    WHERE id = p_result RETURNING * INTO proposal;
    RETURN proposal;
END;
$$;

COMMIT;
