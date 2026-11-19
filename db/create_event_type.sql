BEGIN;

DO $$
BEGIN
    IF to_regtype('public.event_field_definition') IS NULL THEN
        CREATE TYPE public.event_field_definition AS (
            field_key text,
            label text,
            data_type text,
            is_required boolean,
            description text,
            unit_code text,
            min_number numeric,
            max_number numeric,
            min_length integer,
            max_length integer,
            sort_order integer
        );
    END IF;
    IF to_regtype('public.event_option_definition') IS NULL THEN
        CREATE TYPE public.event_option_definition AS (
            field_key text,
            code text,
            label text,
            sort_order integer
        );
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.protect_event_type_code() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Event type code cannot be changed' USING ERRCODE = 'check_violation';
END;
$$;

CREATE OR REPLACE TRIGGER protect_event_type_code
BEFORE UPDATE OF code ON public.event_types
FOR EACH ROW WHEN (OLD.code IS DISTINCT FROM NEW.code)
EXECUTE FUNCTION public.protect_event_type_code();

CREATE OR REPLACE FUNCTION public.insert_event_type_fields(
    p_type_id bigint, p_fields public.event_field_definition[], p_options public.event_option_definition[]
) RETURNS void
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE
    field_without_options text;
BEGIN
    INSERT INTO public.event_type_fields (
        event_type_id, field_key, label, data_type, is_required, description, unit_code,
        min_number, max_number, min_length, max_length, sort_order
    )
    SELECT p_type_id, f.field_key, f.label, f.data_type, coalesce(f.is_required, false),
           f.description, f.unit_code, f.min_number, f.max_number, f.min_length, f.max_length,
           coalesce(f.sort_order, 0)
    FROM unnest(p_fields) AS f;

    INSERT INTO public.event_field_options (event_type_id, field_key, code, label, sort_order)
    SELECT p_type_id, o.field_key, o.code, o.label, coalesce(o.sort_order, 0)
    FROM unnest(p_options) AS o;

    SELECT f.field_key INTO field_without_options
    FROM unnest(p_fields) AS f
    WHERE f.data_type = 'select'
      AND NOT EXISTS (
          SELECT FROM public.event_field_options AS o
          WHERE o.event_type_id = p_type_id AND o.field_key = f.field_key
      )
    ORDER BY f.field_key LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'Select field % requires at least one option', field_without_options
            USING ERRCODE = 'check_violation';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_event_type(
    p_code text, p_name text, p_actor_kind text, p_actor_id text,
    p_description text DEFAULT NULL,
    p_fields public.event_field_definition[] DEFAULT '{}',
    p_options public.event_option_definition[] DEFAULT '{}'
) RETURNS public.event_types
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE
    created_type public.event_types;
BEGIN
    INSERT INTO public.event_types (code, name, description, created_by_kind, created_by_id)
    VALUES (p_code, p_name, p_description, p_actor_kind, p_actor_id)
    RETURNING * INTO created_type;

    PERFORM public.insert_event_type_fields(created_type.id, p_fields, p_options);
    RETURN created_type;
END;
$$;

CREATE OR REPLACE FUNCTION public.edit_event_type(
    p_id bigint, p_expected_updated_at timestamptz, p_name text, p_description text,
    p_fields public.event_field_definition[], p_options public.event_option_definition[], p_archive_keys text[]
) RETURNS public.event_types
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE
    current_type public.event_types;
BEGIN
    SELECT * INTO STRICT current_type FROM public.event_types WHERE id = p_id FOR UPDATE;
    IF current_type.is_archived THEN
        RAISE EXCEPTION 'Archived event type' USING ERRCODE = '23514';
    END IF;
    IF current_type.updated_at IS DISTINCT FROM p_expected_updated_at THEN
        RAISE EXCEPTION 'Event type has changed' USING ERRCODE = 'ET409';
    END IF;
    IF EXISTS (
        SELECT FROM unnest(p_options) o WHERE NOT EXISTS (
            SELECT FROM unnest(p_fields) f WHERE f.field_key = o.field_key AND f.data_type = 'select'
        )
    ) THEN
        RAISE EXCEPTION 'Options must belong to a new select field' USING ERRCODE = '23514';
    END IF;
    IF EXISTS (SELECT FROM unnest(p_fields) f WHERE f.is_required)
       AND EXISTS (SELECT FROM public.events WHERE event_type_id = p_id AND status = 'ready') THEN
        RAISE EXCEPTION 'New required field would invalidate ready events' USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        SELECT FROM unnest(p_archive_keys) AS a(key) WHERE NOT EXISTS (
            SELECT FROM public.event_type_fields f
            WHERE f.event_type_id = p_id AND f.field_key = a.key AND NOT f.is_archived
        )
    ) THEN
        RAISE EXCEPTION 'Unknown or already archived field' USING ERRCODE = '23514';
    END IF;
    UPDATE public.event_type_fields SET is_archived = true
        WHERE event_type_id = p_id AND field_key = ANY (p_archive_keys);
    PERFORM public.insert_event_type_fields(p_id, p_fields, p_options);
    UPDATE public.event_types
        SET name = coalesce(p_name, name),
            description = CASE WHEN p_description IS NULL THEN description ELSE nullif(p_description,'') END,
            updated_at = greatest(clock_timestamp(), updated_at + interval '1 microsecond')
        WHERE id = p_id
        RETURNING * INTO current_type;
    RETURN current_type;
END;
$$;

COMMIT;
