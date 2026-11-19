BEGIN;

CREATE TABLE IF NOT EXISTS public.event_notification_outbox (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id bigint NOT NULL,
    revision bigint NOT NULL,
    attempts bigint NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    delivered_at timestamptz,
    UNIQUE (event_id, revision),
    FOREIGN KEY (event_id, revision) REFERENCES public.event_changes (event_id, revision)
);

CREATE INDEX IF NOT EXISTS event_notification_pending ON public.event_notification_outbox (next_attempt_at, id)
    WHERE delivered_at IS NULL;
CREATE INDEX IF NOT EXISTS event_notification_pending_revision ON public.event_notification_outbox (event_id, revision)
    WHERE delivered_at IS NULL;

ALTER TABLE public.event_changes ADD COLUMN IF NOT EXISTS source_notification_id uuid
    REFERENCES public.event_notification_outbox (id);

CREATE OR REPLACE FUNCTION public.notify_event_change() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
    INSERT INTO public.event_notification_outbox (event_id, revision) VALUES (NEW.event_id, NEW.revision);
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER notify_event_change
AFTER INSERT ON public.event_changes
FOR EACH ROW WHEN (NEW.source_notification_id IS NULL) EXECUTE FUNCTION public.notify_event_change();

COMMIT;
