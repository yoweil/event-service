BEGIN;

ALTER TABLE public.attachment_results
    ADD COLUMN IF NOT EXISTS calculation_method text CHECK (calculation_method ~ '[^[:space:]]');

COMMIT;
