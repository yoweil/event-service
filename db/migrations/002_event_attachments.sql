CREATE TABLE IF NOT EXISTS public.event_attachments (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id bigint NOT NULL REFERENCES public.events(id) ON DELETE RESTRICT,
    filename text NOT NULL CHECK (char_length(filename) BETWEEN 1 AND 255 AND btrim(filename) <> ''),
    content bytea NOT NULL,
    size_bytes integer GENERATED ALWAYS AS (octet_length(content)) STORED,
    digest bytea GENERATED ALWAYS AS (sha256(content)) STORED,
    uploaded_by_id text NOT NULL CHECK (btrim(uploaded_by_id) <> ''),
    uploaded_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (event_id, filename, digest)
);
