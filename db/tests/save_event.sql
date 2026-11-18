\set ON_ERROR_STOP on
BEGIN;

INSERT INTO event_types (code, name, created_by_kind, created_by_id)
VALUES ('test_save_card', 'Исследование', 'user', 'author');
INSERT INTO event_type_fields (event_type_id, field_key, label, data_type, is_required, max_number)
SELECT id, 'pressure', 'Давление', 'number', true, 500 FROM event_types WHERE code = 'test_save_card';

CREATE FUNCTION pg_temp.save_card(
    target_status text, edits public.event_field_edit[] DEFAULT '{}',
    card_id bigint DEFAULT NULL, expected bigint DEFAULT NULL, description text DEFAULT ''
) RETURNS public.events LANGUAGE sql AS $$
    SELECT saved.* FROM public.save_event(
        (SELECT id FROM event_types WHERE code='test_save_card'), 'well-1', target_status, 'instant',
        '2026-01-01 12:00Z', NULL, description, 'user', 'alice', edits, card_id, expected
    ) AS saved;
$$;

DO $$
DECLARE
    card events;
    saved events;
    zero_pressure public.event_field_edit := ROW('pressure',NULL,0,NULL,NULL,NULL,NULL);
    clear_pressure public.event_field_edit := ROW('pressure',NULL,NULL,NULL,NULL,NULL,NULL);
BEGIN
    SELECT * INTO STRICT card FROM pg_temp.save_card('draft');
    IF card.revision <> 1 OR NOT EXISTS (
        SELECT FROM event_changes WHERE event_id=card.id AND revision=1 AND operation='created'
    ) THEN RAISE EXCEPTION 'Missing creation revision'; END IF;

    BEGIN
        PERFORM pg_temp.save_card('ready', '{}', card.id, 1, 'must roll back');
        RAISE EXCEPTION 'Incomplete ready card accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    SELECT * INTO STRICT saved FROM pg_temp.save_card('ready', ARRAY[zero_pressure], card.id, 1, 'Готово');
    IF saved.revision <> 2 OR NOT EXISTS (
        SELECT FROM event_change_items WHERE event_id=card.id AND revision=2
          AND field_key='pressure' AND old_value IS NULL AND new_value='0'
    ) OR NOT EXISTS (
        SELECT FROM event_change_items WHERE event_id=card.id AND revision=2
          AND base_key='description' AND old_value='' AND new_value='Готово'
    ) THEN RAISE EXCEPTION 'Missing change history'; END IF;

    SELECT * INTO STRICT saved FROM pg_temp.save_card('ready', ARRAY[zero_pressure], card.id, 2, 'Готово');
    IF saved.revision <> 2 THEN RAISE EXCEPTION 'Identical save changed revision'; END IF;
    BEGIN
        PERFORM pg_temp.save_card('draft', ARRAY[clear_pressure], card.id, 1);
        RAISE EXCEPTION 'Stale edit accepted';
    EXCEPTION WHEN SQLSTATE 'EV409' THEN NULL;
    END;
    BEGIN
        PERFORM pg_temp.save_card('ready', ARRAY[clear_pressure], card.id, 2);
        RAISE EXCEPTION 'Required field cleared on ready card';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        PERFORM pg_temp.save_card('draft', ARRAY[ROW('pressure',NULL,501,NULL,NULL,NULL,NULL)::public.event_field_edit],
                                  card.id, 2);
        RAISE EXCEPTION 'Invalid pressure accepted on draft';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    IF NOT EXISTS (SELECT FROM events WHERE id=card.id AND revision=2 AND status='ready' AND description='Готово')
        OR NOT EXISTS (SELECT FROM event_field_values WHERE event_id=card.id AND field_key='pressure' AND value_number=0)
        OR EXISTS (SELECT FROM event_changes WHERE event_id=card.id AND revision>2)
    THEN RAISE EXCEPTION 'Failed save leaked data'; END IF;

    SELECT * INTO STRICT saved FROM pg_temp.save_card('draft', ARRAY[clear_pressure], card.id, 2);
    IF saved.revision <> 3 OR EXISTS (SELECT FROM event_field_values WHERE event_id=card.id)
        OR NOT EXISTS (SELECT FROM event_change_items WHERE event_id=card.id AND revision=3
              AND field_key='pressure' AND old_value='0' AND new_value IS NULL)
    THEN RAISE EXCEPTION 'Clearing a field did not record the previous value'; END IF;
END;
$$;

INSERT INTO event_type_fields (event_type_id, field_key, label, data_type, is_required)
SELECT t.id, f.key, f.key, f.kind, true FROM event_types t
CROSS JOIN (VALUES ('confirmed','boolean'), ('method','select')) f(key,kind)
WHERE t.code = 'test_save_card';
INSERT INTO event_field_options (event_type_id, field_key, code, label)
SELECT id, 'method', 'manual', 'Вручную' FROM event_types WHERE code = 'test_save_card';

DO $$
DECLARE
    card events;
    saved events;
    edits public.event_field_edit[] := ARRAY[
        ROW('pressure',NULL,12.50,NULL,NULL,NULL,NULL)::public.event_field_edit,
        ROW('confirmed',NULL,NULL,false,NULL,NULL,NULL)::public.event_field_edit,
        ROW('method',NULL,NULL,NULL,NULL,NULL,'manual')::public.event_field_edit
    ];
BEGIN
    SELECT * INTO STRICT card FROM pg_temp.save_card('ready', edits);
    UPDATE event_field_options SET is_archived = true
    WHERE (event_type_id, field_key, code) = (card.event_type_id, 'method', 'manual');
    SELECT * INTO STRICT saved FROM pg_temp.save_card('ready', '{}', card.id, 1, 'Описание');
    IF saved.revision <> 2 OR (SELECT count(*) FROM event_field_values WHERE event_id = card.id) <> 3
       OR (SELECT count(*) FROM event_change_items WHERE event_id = card.id AND revision = 2) <> 1
       OR NOT EXISTS (SELECT FROM event_change_items WHERE event_id = card.id AND field_key = 'confirmed' AND new_value = 'false')
    THEN RAISE EXCEPTION 'A base-property edit lost or rewrote retained fields'; END IF;
    BEGIN
        PERFORM pg_temp.save_card('ready', edits);
        RAISE EXCEPTION 'Archived option assigned to a new card';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    ALTER TABLE event_change_items ADD CHECK (new_value IS DISTINCT FROM 'fail-audit');
    BEGIN
        PERFORM pg_temp.save_card('ready', ARRAY[
            ROW('pressure',NULL,24,NULL,NULL,NULL,NULL)::public.event_field_edit
        ], card.id, 2, 'fail-audit');
        RAISE EXCEPTION 'Failed history write unexpectedly succeeded';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    IF NOT EXISTS (SELECT FROM events WHERE id = card.id AND revision = 2 AND description = 'Описание')
       OR NOT EXISTS (SELECT FROM event_field_values WHERE event_id = card.id AND field_key = 'pressure' AND value_number = 12.50)
       OR EXISTS (SELECT FROM event_changes WHERE event_id = card.id AND revision > 2)
    THEN RAISE EXCEPTION 'Failed history write leaked a partial save'; END IF;
END;
$$;

ROLLBACK;
