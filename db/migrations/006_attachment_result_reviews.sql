BEGIN;

ALTER TABLE public.attachment_results
    ADD COLUMN IF NOT EXISTS review_decision text CHECK (review_decision IN ('accept','correct','reject')),
    ADD COLUMN IF NOT EXISTS reviewed_by_id text CHECK (btrim(reviewed_by_id) <> ''),
    ADD COLUMN IF NOT EXISTS reviewed_at timestamptz,
    ADD COLUMN IF NOT EXISTS reviewed_value_number numeric CHECK (reviewed_value_number NOT IN ('NaN','Infinity','-Infinity')),
    ADD COLUMN IF NOT EXISTS reviewed_revision bigint CONSTRAINT attachment_results_review_check CHECK (
        (review_decision IS NULL AND num_nonnulls(reviewed_by_id, reviewed_at, reviewed_value_number, reviewed_revision) = 0)
        OR (review_decision IS NOT NULL AND applied_revision IS NULL
            AND reviewed_by_id IS NOT NULL AND reviewed_at IS NOT NULL
            AND CASE WHEN review_decision = 'reject' THEN reviewed_value_number IS NULL AND reviewed_revision IS NULL
                     ELSE reviewed_value_number IS NOT NULL AND reviewed_revision IS NOT NULL AND reviewed_revision > 0 END)
    );

COMMIT;
