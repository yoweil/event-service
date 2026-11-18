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

CREATE OR REPLACE FUNCTION public.create_event_type(
    p_code text, p_name text, p_actor_kind text, p_actor_id text,
    p_description text DEFAULT NULL,
    p_fields public.event_field_definition[] DEFAULT '{}',
    p_options public.event_option_definition[] DEFAULT '{}'
) RETURNS public.event_types
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE
    created_type public.event_types;
    field_without_options text;
BEGIN
    INSERT INTO public.event_types (code, name, description, created_by_kind, created_by_id)
    VALUES (p_code, p_name, p_description, p_actor_kind, p_actor_id)
    RETURNING * INTO created_type;

    INSERT INTO public.event_type_fields (
        event_type_id, field_key, label, data_type, is_required, description, unit_code,
        min_number, max_number, min_length, max_length, sort_order
    )
    SELECT created_type.id, f.field_key, f.label, f.data_type, coalesce(f.is_required, false),
           f.description, f.unit_code, f.min_number, f.max_number, f.min_length, f.max_length,
           coalesce(f.sort_order, 0)
    FROM unnest(p_fields) AS f;

    INSERT INTO public.event_field_options (event_type_id, field_key, code, label, sort_order)
    SELECT created_type.id, o.field_key, o.code, o.label, coalesce(o.sort_order, 0)
    FROM unnest(p_options) AS o;

    SELECT f.field_key INTO field_without_options
    FROM public.event_type_fields AS f
    WHERE f.event_type_id = created_type.id AND f.data_type = 'select'
      AND NOT EXISTS (
          SELECT FROM public.event_field_options AS o
          WHERE o.event_type_id = f.event_type_id AND o.field_key = f.field_key
      )
    ORDER BY f.field_key LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'Select field % requires at least one option', field_without_options
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN created_type;
END;
$$;

COMMIT;
