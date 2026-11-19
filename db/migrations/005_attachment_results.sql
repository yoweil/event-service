BEGIN;

ALTER TABLE public.event_attachments ADD COLUMN IF NOT EXISTS upload_revision bigint CHECK (upload_revision > 0);

CREATE OR REPLACE FUNCTION public.capture_attachment_revision() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
    SELECT revision INTO NEW.upload_revision FROM public.events WHERE id = NEW.event_id FOR SHARE;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER capture_attachment_revision BEFORE INSERT ON public.event_attachments
FOR EACH ROW EXECUTE FUNCTION public.capture_attachment_revision();

CREATE TABLE IF NOT EXISTS public.attachment_results (
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
    UNIQUE (attachment_id, field_key),
    CHECK ((applied_revision IS NULL) = (reason IS NOT NULL)),
    CHECK (value_number IS NULL OR (sheet_name IS NOT NULL AND cell_ref IS NOT NULL))
);

COMMIT;
