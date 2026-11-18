CREATE INDEX IF NOT EXISTS events_started_idx ON public.events (started_at DESC, id DESC);
