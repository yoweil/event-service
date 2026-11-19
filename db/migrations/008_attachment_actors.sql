BEGIN;

ALTER TABLE public.event_attachments
    ADD COLUMN IF NOT EXISTS uploaded_by_kind text CHECK (uploaded_by_kind IN ('user','service'));

ALTER TABLE public.attachment_results
    ADD COLUMN IF NOT EXISTS submitted_by_kind text CHECK (submitted_by_kind IN ('user','service')),
    ADD COLUMN IF NOT EXISTS submitted_by_id text CHECK (btrim(submitted_by_id) <> '')
        CONSTRAINT attachment_result_submitter_check CHECK ((submitted_by_kind IS NULL) = (submitted_by_id IS NULL));

COMMIT;
