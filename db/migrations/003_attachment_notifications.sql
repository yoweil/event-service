BEGIN;

CREATE TABLE IF NOT EXISTS public.notification_outbox (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    attachment_id bigint NOT NULL UNIQUE REFERENCES public.event_attachments(id) ON DELETE RESTRICT,
    attempts bigint NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    delivered_at timestamptz
);

CREATE INDEX IF NOT EXISTS notification_outbox_pending ON public.notification_outbox (next_attempt_at, id)
    WHERE delivered_at IS NULL;

CREATE OR REPLACE FUNCTION public.notify_attachment_insert() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
    INSERT INTO public.notification_outbox (attachment_id) VALUES (NEW.id);
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER notify_attachment_insert
AFTER INSERT ON public.event_attachments
FOR EACH ROW EXECUTE FUNCTION public.notify_attachment_insert();

COMMIT;
