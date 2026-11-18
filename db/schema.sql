BEGIN;
SET LOCAL search_path = pg_catalog, public;

CREATE TABLE public.event_types (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code text NOT NULL UNIQUE,
    name text NOT NULL,
    description text,
    is_archived boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    created_by_kind text NOT NULL,
    created_by_id text NOT NULL,

    CONSTRAINT event_types_code_format_check
        CHECK (code COLLATE "C" ~ '^[a-z][a-z0-9_]{0,63}$'),
    CONSTRAINT event_types_name_check CHECK (btrim(name) <> ''),
    CONSTRAINT event_types_created_by_kind_check CHECK (created_by_kind IN ('user', 'service')),
    CONSTRAINT event_types_created_by_id_check CHECK (btrim(created_by_id) <> '')
);

CREATE TABLE public.events (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    well_id text NOT NULL,
    event_type_id bigint NOT NULL,
    status text NOT NULL DEFAULT 'draft',
    time_kind text NOT NULL,
    started_at timestamptz NOT NULL,
    ended_at timestamptz,
    description text NOT NULL DEFAULT '',
    revision bigint NOT NULL DEFAULT 1,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    created_by_kind text NOT NULL,
    created_by_id text NOT NULL,

    UNIQUE (id, event_type_id),
    CONSTRAINT events_type_fk FOREIGN KEY (event_type_id)
        REFERENCES public.event_types (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT events_well_id_check CHECK (btrim(well_id) <> ''),
    CONSTRAINT events_status_check CHECK (status IN ('draft', 'ready')),
    CONSTRAINT events_time_kind_check CHECK (time_kind IN ('instant', 'period')),
    CONSTRAINT events_time_bounds_check CHECK (
        (time_kind = 'instant' AND ended_at IS NULL)
        OR (time_kind = 'period' AND (ended_at IS NULL OR ended_at > started_at))
    ),
    CONSTRAINT events_finite_time_check
        CHECK (isfinite(started_at) AND (ended_at IS NULL OR isfinite(ended_at))),
    CONSTRAINT events_revision_check CHECK (revision >= 1),
    CONSTRAINT events_created_by_kind_check CHECK (created_by_kind IN ('user', 'service')),
    CONSTRAINT events_created_by_id_check CHECK (btrim(created_by_id) <> '')
);

CREATE INDEX events_well_started_idx ON public.events (well_id, started_at DESC, id DESC);
CREATE INDEX events_type_started_idx ON public.events (event_type_id, started_at DESC, id DESC);

CREATE TABLE public.event_type_fields (
    event_type_id bigint NOT NULL REFERENCES public.event_types (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    field_key text NOT NULL CHECK (field_key COLLATE "C" ~ '^[a-z][a-z0-9_]{0,63}$'),
    label text NOT NULL CHECK (btrim(label) <> ''),
    description text,
    data_type text NOT NULL CHECK (data_type IN ('text','integer','number','boolean','date','datetime','select')),
    is_required boolean NOT NULL DEFAULT false,
    is_archived boolean NOT NULL DEFAULT false,
    unit_code text,
    min_number numeric,
    max_number numeric,
    min_length integer,
    max_length integer,
    sort_order integer NOT NULL DEFAULT 0 CHECK (sort_order >= 0),

    PRIMARY KEY (event_type_id, field_key),
    UNIQUE (event_type_id, field_key, data_type),
    CHECK (unit_code IS NULL OR (data_type IN ('integer','number') AND btrim(unit_code) <> '')),
    CHECK ((min_number IS NULL AND max_number IS NULL) OR data_type IN ('integer','number')),
    CHECK (min_number <= max_number),
    CHECK (min_number NOT IN ('NaN','Infinity','-Infinity') AND max_number NOT IN ('NaN','Infinity','-Infinity')),
    CHECK (data_type <> 'integer' OR (trunc(min_number) = min_number AND trunc(max_number) = max_number)),
    CHECK ((min_length IS NULL AND max_length IS NULL) OR data_type = 'text'),
    CHECK (min_length >= 0 AND max_length >= 0 AND min_length <= max_length)
);

CREATE FUNCTION public.protect_field_definition() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF (NEW.event_type_id, NEW.field_key, NEW.data_type, NEW.unit_code)
       IS DISTINCT FROM (OLD.event_type_id, OLD.field_key, OLD.data_type, OLD.unit_code) THEN
        RAISE EXCEPTION 'Create a new field to change its key, owner, data type or unit'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER protect_field_definition
BEFORE UPDATE OF event_type_id, field_key, data_type, unit_code ON public.event_type_fields
FOR EACH ROW EXECUTE FUNCTION public.protect_field_definition();

CREATE TABLE public.event_field_options (
    event_type_id bigint NOT NULL,
    field_key text NOT NULL,
    data_type text GENERATED ALWAYS AS ('select'::text) STORED,
    code text NOT NULL CHECK (btrim(code) <> ''),
    label text NOT NULL CHECK (btrim(label) <> ''),
    sort_order integer NOT NULL DEFAULT 0 CHECK (sort_order >= 0),
    is_archived boolean NOT NULL DEFAULT false,
    PRIMARY KEY (event_type_id, field_key, code),
    FOREIGN KEY (event_type_id, field_key, data_type)
        REFERENCES public.event_type_fields (event_type_id, field_key, data_type) ON UPDATE RESTRICT ON DELETE RESTRICT
);

CREATE TABLE public.event_field_values (
    event_id bigint NOT NULL,
    event_type_id bigint NOT NULL,
    field_key text NOT NULL,
    data_type text NOT NULL,
    value_text text,
    value_number numeric,
    value_boolean boolean,
    value_date date,
    value_datetime timestamptz,
    value_option text,

    PRIMARY KEY (event_id, field_key),
    FOREIGN KEY (event_id, event_type_id)
        REFERENCES public.events (id, event_type_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    FOREIGN KEY (event_type_id, field_key, data_type)
        REFERENCES public.event_type_fields (event_type_id, field_key, data_type) ON UPDATE RESTRICT ON DELETE RESTRICT,
    FOREIGN KEY (event_type_id, field_key, value_option)
        REFERENCES public.event_field_options (event_type_id, field_key, code) ON UPDATE RESTRICT ON DELETE RESTRICT,
    CHECK (num_nonnulls(value_text, value_number, value_boolean, value_date, value_datetime, value_option) = 1),
    CHECK (CASE data_type
        WHEN 'text' THEN value_text IS NOT NULL
        WHEN 'number' THEN value_number IS NOT NULL
        WHEN 'integer' THEN value_number IS NOT NULL AND trunc(value_number) = value_number
        WHEN 'boolean' THEN value_boolean IS NOT NULL
        WHEN 'date' THEN value_date IS NOT NULL AND isfinite(value_date)
        WHEN 'datetime' THEN value_datetime IS NOT NULL AND isfinite(value_datetime)
        WHEN 'select' THEN value_option IS NOT NULL
        ELSE false END),
    CHECK (value_number NOT IN ('NaN','Infinity','-Infinity'))
);

CREATE INDEX event_field_values_by_field ON public.event_field_values (event_type_id, field_key);
CREATE INDEX event_field_values_numeric_search ON public.event_field_values
    (event_type_id, field_key, value_number, event_id) WHERE value_number IS NOT NULL;

CREATE TABLE public.event_changes (
    event_id bigint NOT NULL REFERENCES public.events (id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    revision bigint NOT NULL CHECK (revision >= 1),
    operation text NOT NULL CHECK ((revision = 1 AND operation = 'created')
                               OR (revision > 1 AND operation = 'updated')),
    actor_kind text NOT NULL CHECK (actor_kind IN ('user','service')),
    actor_id text NOT NULL CHECK (btrim(actor_id) <> ''),
    changed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (event_id, revision)
);

CREATE TABLE public.event_change_items (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id bigint NOT NULL,
    revision bigint NOT NULL,
    event_type_id bigint NOT NULL,
    base_key text CHECK (base_key IN ('well_id','status','time_kind','started_at','ended_at','description')),
    field_key text,
    old_value text,
    new_value text,

    CHECK (num_nonnulls(base_key, field_key) = 1),
    CHECK (old_value IS DISTINCT FROM new_value),
    CHECK (revision <> 1 OR old_value IS NULL),
    UNIQUE NULLS NOT DISTINCT (event_id, revision, base_key, field_key),
    FOREIGN KEY (event_id, revision)
        REFERENCES public.event_changes (event_id, revision) ON UPDATE RESTRICT ON DELETE RESTRICT,
    FOREIGN KEY (event_id, event_type_id)
        REFERENCES public.events (id, event_type_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    FOREIGN KEY (event_type_id, field_key)
        REFERENCES public.event_type_fields (event_type_id, field_key) ON UPDATE RESTRICT ON DELETE RESTRICT
);

CREATE INDEX event_change_items_by_field ON public.event_change_items (event_type_id, field_key)
    WHERE field_key IS NOT NULL;

COMMIT;
