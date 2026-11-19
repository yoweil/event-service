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

CREATE INDEX events_started_idx ON public.events (started_at DESC, id DESC);
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
    option_field_key text,

    CHECK (num_nonnulls(base_key, field_key) = 1),
    CHECK (old_value IS DISTINCT FROM new_value),
    CHECK (revision <> 1 OR old_value IS NULL),
    UNIQUE NULLS NOT DISTINCT (event_id, revision, base_key, field_key),
    FOREIGN KEY (event_id, revision)
        REFERENCES public.event_changes (event_id, revision) ON UPDATE RESTRICT ON DELETE RESTRICT,
    FOREIGN KEY (event_id, event_type_id)
        REFERENCES public.events (id, event_type_id) ON UPDATE RESTRICT ON DELETE RESTRICT,
    FOREIGN KEY (event_type_id, field_key)
        REFERENCES public.event_type_fields (event_type_id, field_key) ON UPDATE RESTRICT ON DELETE RESTRICT,
    FOREIGN KEY (event_type_id, option_field_key, old_value)
        REFERENCES public.event_field_options (event_type_id, field_key, code) ON UPDATE RESTRICT ON DELETE RESTRICT,
    FOREIGN KEY (event_type_id, option_field_key, new_value)
        REFERENCES public.event_field_options (event_type_id, field_key, code) ON UPDATE RESTRICT ON DELETE RESTRICT
);

CREATE FUNCTION public.set_audit_option_field() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.option_field_key := NULL;
    IF NEW.field_key IS NOT NULL THEN
        SELECT CASE WHEN f.data_type = 'select' THEN f.field_key END
          INTO NEW.option_field_key
          FROM public.event_type_fields f
         WHERE (f.event_type_id, f.field_key) = (NEW.event_type_id, NEW.field_key)
           FOR KEY SHARE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unknown event field % for event type %', NEW.field_key, NEW.event_type_id
                USING ERRCODE = 'foreign_key_violation';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER set_audit_option_field
BEFORE INSERT OR UPDATE ON public.event_change_items
FOR EACH ROW EXECUTE FUNCTION public.set_audit_option_field();

CREATE INDEX event_change_items_by_field ON public.event_change_items (event_type_id, field_key)
    WHERE field_key IS NOT NULL;
CREATE INDEX event_change_items_by_option_field ON public.event_change_items (event_type_id, option_field_key)
    WHERE option_field_key IS NOT NULL;

CREATE TABLE public.event_attachments (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id bigint NOT NULL REFERENCES public.events(id) ON DELETE RESTRICT,
    filename text NOT NULL CHECK (char_length(filename) BETWEEN 1 AND 255 AND btrim(filename) <> ''),
    content bytea NOT NULL,
    size_bytes integer GENERATED ALWAYS AS (octet_length(content)) STORED,
    digest bytea GENERATED ALWAYS AS (sha256(content)) STORED,
    uploaded_by_id text NOT NULL CHECK (btrim(uploaded_by_id) <> ''),
    uploaded_by_kind text CHECK (uploaded_by_kind IN ('user','service')),
    uploaded_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (event_id, filename, digest)
);

CREATE TABLE public.notification_outbox (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    attachment_id bigint NOT NULL UNIQUE REFERENCES public.event_attachments(id) ON DELETE RESTRICT,
    attempts bigint NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    delivered_at timestamptz
);

CREATE INDEX notification_outbox_pending ON public.notification_outbox (next_attempt_at, id)
    WHERE delivered_at IS NULL;

CREATE FUNCTION public.notify_attachment_insert() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
    INSERT INTO public.notification_outbox (attachment_id) VALUES (NEW.id);
    RETURN NEW;
END;
$$;

CREATE TRIGGER notify_attachment_insert
AFTER INSERT ON public.event_attachments
FOR EACH ROW EXECUTE FUNCTION public.notify_attachment_insert();

CREATE TABLE public.event_notification_outbox (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id bigint NOT NULL,
    revision bigint NOT NULL,
    attempts bigint NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    delivered_at timestamptz,
    UNIQUE (event_id, revision),
    FOREIGN KEY (event_id, revision) REFERENCES public.event_changes (event_id, revision)
);

CREATE INDEX event_notification_pending ON public.event_notification_outbox (next_attempt_at, id)
    WHERE delivered_at IS NULL;
CREATE INDEX event_notification_pending_revision ON public.event_notification_outbox (event_id, revision)
    WHERE delivered_at IS NULL;

ALTER TABLE public.event_changes ADD COLUMN source_notification_id uuid
    REFERENCES public.event_notification_outbox (id);

CREATE FUNCTION public.notify_event_change() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
    INSERT INTO public.event_notification_outbox (event_id, revision) VALUES (NEW.event_id, NEW.revision);
    RETURN NEW;
END;
$$;

CREATE TRIGGER notify_event_change
AFTER INSERT ON public.event_changes
FOR EACH ROW WHEN (NEW.source_notification_id IS NULL) EXECUTE FUNCTION public.notify_event_change();

ALTER TABLE public.event_attachments ADD COLUMN upload_revision bigint CHECK (upload_revision > 0);

CREATE FUNCTION public.capture_attachment_revision() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
    SELECT revision INTO NEW.upload_revision FROM public.events WHERE id = NEW.event_id FOR SHARE;
    RETURN NEW;
END;
$$;

CREATE TRIGGER capture_attachment_revision BEFORE INSERT ON public.event_attachments
FOR EACH ROW EXECUTE FUNCTION public.capture_attachment_revision();

CREATE TABLE public.attachment_results (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    attachment_id bigint NOT NULL REFERENCES public.event_attachments(id),
    field_key text NOT NULL CHECK (field_key COLLATE "C" ~ '^[a-z][a-z0-9_]{0,63}$'),
    unit_code text,
    value_number numeric CHECK (value_number NOT IN ('NaN','Infinity','-Infinity')),
    sheet_name text,
    cell_ref text,
    reason text,
    applied_revision bigint CHECK (applied_revision > 0),
    state text GENERATED ALWAYS AS (CASE WHEN applied_revision IS NULL THEN 'review' ELSE 'applied' END) STORED,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    review_decision text CHECK (review_decision IN ('accept','correct','reject')),
    reviewed_by_id text CHECK (btrim(reviewed_by_id) <> ''),
    reviewed_at timestamptz,
    reviewed_value_number numeric CHECK (reviewed_value_number NOT IN ('NaN','Infinity','-Infinity')),
    reviewed_revision bigint CONSTRAINT attachment_results_review_check CHECK (
        (review_decision IS NULL AND num_nonnulls(reviewed_by_id, reviewed_at, reviewed_value_number, reviewed_revision) = 0)
        OR (review_decision IS NOT NULL AND applied_revision IS NULL
            AND reviewed_by_id IS NOT NULL AND reviewed_at IS NOT NULL
            AND CASE WHEN review_decision = 'reject' THEN reviewed_value_number IS NULL AND reviewed_revision IS NULL
                     ELSE reviewed_value_number IS NOT NULL AND reviewed_revision IS NOT NULL AND reviewed_revision > 0 END)
    ),
    calculation_method text CHECK (calculation_method ~ '[^[:space:]]'),
    submitted_by_kind text CHECK (submitted_by_kind IN ('user','service')),
    submitted_by_id text CHECK (btrim(submitted_by_id) <> ''),
    CONSTRAINT attachment_result_submitter_check CHECK ((submitted_by_kind IS NULL) = (submitted_by_id IS NULL)),
    UNIQUE (attachment_id, field_key),
    CHECK ((applied_revision IS NULL) = (reason IS NOT NULL)),
    CHECK (value_number IS NULL OR (sheet_name IS NOT NULL AND cell_ref IS NOT NULL))
);

COMMIT;
