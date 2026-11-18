\set ON_ERROR_STOP on

BEGIN;
SET LOCAL search_path = public, pg_catalog;

CREATE FUNCTION pg_temp.expect_error(statement text, expected_state text, test_name text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    actual_state text;
BEGIN
    BEGIN
        EXECUTE statement;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS actual_state = RETURNED_SQLSTATE;
        IF actual_state <> expected_state THEN
            RAISE EXCEPTION '%: expected SQLSTATE %, got % (%)',
                test_name, expected_state, actual_state, SQLERRM;
        END IF;
        RETURN;
    END;
    RAISE EXCEPTION '%: statement succeeded; expected SQLSTATE %', test_name, expected_state;
END;
$$;

CREATE FUNCTION pg_temp.assert_true(condition boolean, test_name text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF condition IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'Assertion failed: %', test_name;
    END IF;
END;
$$;

INSERT INTO event_types (code, name, created_by_kind, created_by_id)
VALUES ('test_research', 'Исследование', 'user', 'alice') RETURNING id AS research \gset
INSERT INTO event_types (code, name, created_by_kind, created_by_id)
VALUES ('test_shutdown', 'Остановка', 'service', 'source') RETURNING id AS shutdown \gset

INSERT INTO event_type_fields (event_type_id, field_key, label, data_type, unit_code) VALUES
  (:research, 'pressure', 'Давление', 'number', 'bar'),
  (:research, 'reason', 'Причина', 'select', NULL),
  (:shutdown, 'reason', 'Причина остановки', 'select', NULL),
  (:research, 'confirmed', 'Проверено', 'boolean', NULL),
  (:research, 'count', 'Число замеров', 'integer', NULL),
  (:research, 'note', 'Комментарий', 'text', NULL),
  (:research, 'day', 'Дата пробы', 'date', NULL),
  (:research, 'sampled_at', 'Время пробы', 'datetime', NULL);

INSERT INTO event_field_options (event_type_id, field_key, code, label) VALUES
  (:research, 'reason', 'control', 'Контроль'),
  (:shutdown, 'reason', 'repair', 'Ремонт');

INSERT INTO events (event_type_id, well_id, time_kind, started_at, created_by_kind, created_by_id)
VALUES (:research, 'well-test', 'instant', '2026-01-01 10:00Z', 'user', 'alice')
RETURNING id AS card \gset
INSERT INTO events (event_type_id, well_id, time_kind, started_at, created_by_kind, created_by_id)
VALUES (:shutdown, 'well-test', 'period', '2026-01-01 12:00Z', 'service', 'source')
RETURNING id AS stop_card \gset

INSERT INTO event_field_values (event_id, event_type_id, field_key, data_type, value_number)
VALUES (:card, :research, 'pressure', 'number', 120.5), (:card, :research, 'count', 'integer', 0);
INSERT INTO event_field_values (event_id, event_type_id, field_key, data_type, value_boolean)
VALUES (:card, :research, 'confirmed', 'boolean', false);
INSERT INTO event_field_values (event_id, event_type_id, field_key, data_type, value_option)
VALUES (:stop_card, :shutdown, 'reason', 'select', 'repair');
INSERT INTO event_field_values (event_id, event_type_id, field_key, data_type, value_text)
VALUES (:card, :research, 'note', 'text', 'Замер до остановки');
INSERT INTO event_field_values (event_id, event_type_id, field_key, data_type, value_date)
VALUES (:card, :research, 'day', 'date', DATE '2026-01-01');
INSERT INTO event_field_values (event_id, event_type_id, field_key, data_type, value_datetime)
VALUES (:card, :research, 'sampled_at', 'datetime', '2026-01-01 09:00Z');

SELECT pg_temp.assert_true((SELECT array_agg(e.id ORDER BY v.value_number) = ARRAY[:card::bigint]
  FROM events e JOIN event_field_values v ON v.event_id = e.id
  WHERE e.well_id = 'well-test' AND e.event_type_id = :research AND v.field_key = 'pressure'
    AND v.value_number > 100 AND e.started_at >= '2026-01-01'::date), 'numeric search');

INSERT INTO event_type_fields (event_type_id, field_key, label, data_type)
VALUES (:research, 'temperature', 'Температура', 'number');
SELECT pg_temp.assert_true(
  NOT EXISTS (SELECT FROM event_field_values WHERE event_id = :card AND field_key = 'temperature')
  AND (SELECT value_number = 0 FROM event_field_values WHERE event_id = :card AND field_key = 'count')
  AND (SELECT value_boolean IS FALSE FROM event_field_values WHERE event_id = :card AND field_key = 'confirmed'),
  'adding an optional field preserves missing, zero and false');

SELECT pg_temp.expect_error(format(
  'INSERT INTO event_field_values(event_id,event_type_id,field_key,data_type,value_number) VALUES (%s,%s,%L,%L,1)',
  :stop_card, :research, 'pressure', 'number'), '23503', 'field belongs to another event type');
SELECT pg_temp.expect_error(format(
  'UPDATE event_field_values SET data_type=%L WHERE event_id=%s AND field_key=%L',
  'number', :card, 'count'), '23503', 'declared field type must match the definition');
SELECT pg_temp.expect_error(format(
  'INSERT INTO event_field_values(event_id,event_type_id,field_key,data_type,value_number) VALUES (%s,%s,%L,%L,5)',
  :card, :research, 'count', 'integer'), '23505', 'one value per field');
SELECT pg_temp.expect_error(format(
  'UPDATE event_field_values SET value_option=%L WHERE event_id=%s AND field_key=%L',
  'control', :stop_card, 'reason'), '23503', 'option belongs to the selected field');
SELECT pg_temp.expect_error(format(
  'INSERT INTO event_field_options(event_type_id,field_key,code,label) VALUES (%s,%L,%L,%L)',
  :research, 'pressure', 'high', 'High'), '23503', 'only select fields define options');

SELECT pg_temp.expect_error(format(
  'UPDATE event_field_values SET %s WHERE event_id=%s AND field_key=%L', change, :card, 'count'
), '23514', label) FROM (VALUES
  ('value_number = NULL', 'missing payload'), ('value_text = ''0''', 'two payloads'),
  ('value_number = NULL, value_text = ''0''', 'incorrect storage column'),
  ('value_number = 0.5', 'fractional count'), ('value_number = ''NaN''', 'non-finite count')
) AS bad(change, label);

SELECT pg_temp.expect_error(format(
  'UPDATE event_type_fields SET %s WHERE event_type_id=%s AND field_key=%L', change, :research, 'pressure'
), '23514', label) FROM (VALUES
  ('min_number=5,max_number=1', 'reversed range'), ('min_length=2', 'length rule on number'),
  ('unit_code=''MPa''', 'historical unit cannot silently change')
) AS bad(change, label);

SELECT pg_temp.expect_error(format('UPDATE events SET ended_at=started_at WHERE id=%s', :stop_card),
  '23514', 'empty period');
SELECT pg_temp.expect_error(format('UPDATE events SET ended_at=started_at WHERE id=%s', :card),
  '23514', 'instant with end');
UPDATE events SET ended_at = started_at + interval '1 hour' WHERE id = :stop_card;
SELECT pg_temp.expect_error(format('UPDATE events SET started_at=%L WHERE id=%s', '-infinity', :card),
  '23514', 'finite start required');
SELECT pg_temp.expect_error(format('UPDATE events SET status=%L WHERE id=%s', 'unknown', :card),
  '23514', 'unknown event status');
SELECT pg_temp.expect_error(format('UPDATE event_types SET code=%L WHERE id=%s', repeat('a',65), :research),
  '23514', 'technical code exceeds the agreed limit');
SELECT pg_temp.expect_error(format(
  'INSERT INTO event_type_fields(event_type_id,field_key,label,data_type) VALUES (%s,%L,%L,%L)',
  :research,'pressure','Другое давление','number'), '23505', 'same key twice in one type');

INSERT INTO event_changes (event_id, revision, operation, actor_kind, actor_id)
VALUES (:card, 1, 'created', 'user', 'alice');
INSERT INTO event_change_items (event_id, revision, event_type_id, field_key, new_value)
VALUES (:card, 1, :research, 'pressure', '120.5');
UPDATE events SET revision=revision+1 WHERE id=:card AND revision=1;
UPDATE event_field_values SET value_number=121 WHERE event_id=:card AND field_key='pressure';
INSERT INTO event_changes (event_id, revision, operation, actor_kind, actor_id)
VALUES (:card, 2, 'updated', 'service', 'meter');
INSERT INTO event_change_items (event_id, revision, event_type_id, field_key, old_value, new_value)
VALUES (:card, 2, :research, 'pressure', '120.5', '121');
INSERT INTO event_change_items (event_id, revision, event_type_id, base_key, old_value, new_value)
VALUES (:card, 2, :research, 'description', '', 'Проверено');
UPDATE events SET description='Проверено' WHERE id=:card;
WITH stale AS (UPDATE events SET revision=revision+1 WHERE id=:card AND revision=1 RETURNING id)
SELECT pg_temp.assert_true(count(*)=0,'stale revision fails compare-and-update') FROM stale;

UPDATE event_type_fields SET is_archived=true WHERE event_type_id=:research AND field_key='pressure';
UPDATE event_field_options SET is_archived=true WHERE event_type_id=:shutdown AND field_key='reason' AND code='repair';
SELECT pg_temp.assert_true((SELECT f.unit_code='bar' AND v.value_number=121 AND f.is_archived
  FROM event_type_fields f JOIN event_field_values v USING (event_type_id,field_key)
  WHERE v.event_id=:card AND f.field_key='pressure'), 'archived measurement is readable');
SELECT pg_temp.assert_true((SELECT o.label='Ремонт' AND o.is_archived
  FROM event_field_options o JOIN event_field_values v
    ON (v.event_type_id,v.field_key,v.value_option)=(o.event_type_id,o.field_key,o.code)
  WHERE v.event_id=:stop_card AND v.field_key='reason'), 'archived option is readable');
DELETE FROM event_field_values WHERE event_id=:card AND field_key='pressure';
UPDATE events SET revision=3 WHERE id=:card AND revision=2;
INSERT INTO event_changes (event_id,revision,operation,actor_kind,actor_id)
VALUES (:card,3,'updated','user','alice');
INSERT INTO event_change_items (event_id, revision, event_type_id, field_key, old_value)
VALUES (:card,3,:research,'pressure','121');
SELECT pg_temp.expect_error(format(
  'DELETE FROM event_type_fields WHERE event_type_id=%s AND field_key=%L',:research,'pressure'),
  '23001','history keeps the field definition after a value is cleared');
SELECT pg_temp.assert_true((SELECT i.old_value='120.5' AND i.new_value='121' AND c.actor_id='meter'
  FROM event_change_items i JOIN event_changes c USING (event_id,revision)
  WHERE i.event_id=:card AND i.revision=2 AND i.field_key='pressure'), 'old and new measurement and author');

SELECT pg_temp.expect_error(format(
  'INSERT INTO event_change_items(event_id,revision,event_type_id,field_key,new_value) VALUES (%s,3,%s,%L,%L)',
  :card,:research,'pressure','123'), '23505', 'one audit item per property in a revision');

DO $$
DECLARE
    target_id bigint;
BEGIN
    SELECT id INTO STRICT target_id FROM events WHERE well_id='well-test' AND time_kind='instant';
    BEGIN
        UPDATE events SET revision=4, description='must roll back' WHERE id=target_id;
        INSERT INTO event_changes (event_id,revision,operation,actor_kind,actor_id)
        VALUES (target_id,4,'updated','unknown','alice');
        RAISE EXCEPTION 'invalid audit author accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    PERFORM pg_temp.assert_true((SELECT revision=3 AND description='Проверено' FROM events WHERE id=target_id),
        'failed history write rolls back the card');
END;
$$;

ROLLBACK;
\echo 'Schema checks passed; fixture data rolled back.'
