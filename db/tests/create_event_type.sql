\set ON_ERROR_STOP on
BEGIN;

SELECT id FROM public.create_event_type('test_basic', 'Общее событие', 'user', 'anna');

DO $$
BEGIN
    UPDATE event_types SET name = 'Новое название', is_archived = true WHERE code = 'test_basic';
    BEGIN
        UPDATE event_types SET code = 'renamed_basic' WHERE code = 'test_basic';
        RAISE EXCEPTION 'Renamed a permanent type code';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END;
$$;

DO $$
DECLARE
    research public.event_types;
    shutdown public.event_types;
    pressure_event public.events;
    stop_event public.events;
    pressure public.event_field_definition := ROW(
        'pressure', 'Давление', 'number', true, 'В устье скважины', 'bar', 0, 500, NULL, NULL, 10
    );
    reason public.event_field_definition := ROW(
        'reason', 'Причина', 'select', true, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    );
    repair public.event_option_definition := ROW('reason', 'repair', 'Ремонт', 20);
    scheduled public.event_option_definition := ROW('reason', 'scheduled', 'По графику', NULL);
BEGIN
    SELECT * INTO STRICT research FROM public.create_event_type(
        'test_research', 'Исследование', 'user', 'anna', p_fields => ARRAY[pressure]
    );
    SELECT * INTO STRICT shutdown FROM public.create_event_type(
        'test_shutdown', 'Остановка', 'service', 'importer', p_description => 'Простой скважины',
        p_fields => ARRAY[reason], p_options => ARRAY[repair, scheduled]
    );
    IF (shutdown.description, shutdown.created_by_kind, shutdown.created_by_id)
       IS DISTINCT FROM ('Простой скважины'::text, 'service'::text, 'importer'::text)
       OR NOT EXISTS (
           SELECT FROM event_type_fields WHERE event_type_id = research.id AND field_key = 'pressure'
             AND label = 'Давление' AND description = 'В устье скважины' AND is_required
             AND unit_code = 'bar' AND min_number = 0 AND max_number = 500 AND sort_order = 10
       ) OR NOT EXISTS (
           SELECT FROM event_field_options WHERE event_type_id = shutdown.id AND field_key = 'reason'
             AND code = 'scheduled' AND label = 'По графику' AND sort_order = 0
       ) THEN RAISE EXCEPTION 'Field or option metadata lost during creation'; END IF;

    SELECT * INTO STRICT pressure_event FROM public.save_event(
        research.id, 'well-5', 'ready', 'instant', '2026-01-12 08:00Z', NULL, '', 'user', 'anna',
        ARRAY[ROW('pressure', NULL, 120.5, NULL, NULL, NULL, NULL)::public.event_field_edit]
    );
    SELECT * INTO STRICT stop_event FROM public.save_event(
        shutdown.id, 'well-5', 'ready', 'period', '2026-01-13 08:00Z', NULL, '', 'user', 'anna',
        ARRAY[ROW('reason', NULL, NULL, NULL, NULL, NULL, 'repair')::public.event_field_edit]
    );
    IF NOT EXISTS (SELECT FROM event_field_values WHERE event_id = pressure_event.id AND value_number = 120.5)
       OR NOT EXISTS (SELECT FROM event_field_values WHERE event_id = stop_event.id AND value_option = 'repair')
    THEN RAISE EXCEPTION 'Created types cannot be used to store their respective values'; END IF;

    BEGIN
        PERFORM public.create_event_type('test_shutdown', 'Дубликат', 'user', 'anna');
        RAISE EXCEPTION 'Reused a type code';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        PERFORM public.create_event_type('test_invalid_type', 'Неверный тип', 'user', 'anna',
            p_fields => ARRAY[reason], p_options => ARRAY[repair, repair]);
        RAISE EXCEPTION 'Duplicate option accepted';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        PERFORM public.create_event_type('test_invalid_type', 'Неверный тип', 'user', 'anna',
            p_fields => ARRAY[pressure], p_options => ARRAY[repair]);
        RAISE EXCEPTION 'Option for an unknown field accepted';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        PERFORM public.create_event_type('test_invalid_type', 'Неверный тип', 'user', 'anna',
            p_fields => ARRAY[reason]);
        RAISE EXCEPTION 'Select field without options accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    IF EXISTS (SELECT FROM event_types WHERE code = 'test_invalid_type') THEN
        RAISE EXCEPTION 'Failed creation left a partially configured type';
    END IF;
END;
$$;

ROLLBACK;
