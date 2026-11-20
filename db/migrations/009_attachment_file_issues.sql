BEGIN;

ALTER TABLE public.attachment_results
    ALTER COLUMN field_key DROP NOT NULL,
    DROP CONSTRAINT IF EXISTS attachment_results_review_check,
    DROP CONSTRAINT IF EXISTS attachment_results_file_issue_check,
    ADD CONSTRAINT attachment_results_review_check CHECK (
        (review_decision IS NULL AND num_nonnulls(reviewed_by_id, reviewed_at, reviewed_value_number, reviewed_revision) = 0)
        OR (review_decision IS NOT NULL AND applied_revision IS NULL
            AND reviewed_by_id IS NOT NULL AND reviewed_at IS NOT NULL
            AND CASE WHEN review_decision = 'reject' OR field_key IS NULL THEN reviewed_value_number IS NULL AND reviewed_revision IS NULL
                     ELSE reviewed_value_number IS NOT NULL AND reviewed_revision IS NOT NULL AND reviewed_revision > 0 END)
    ),
    ADD CONSTRAINT attachment_results_file_issue_check CHECK (
        field_key IS NOT NULL OR (
            reason IS NOT NULL AND reason ~ '[^[:space:]]'
            AND num_nonnulls(unit_code, value_number, sheet_name, cell_ref, calculation_method, applied_revision) = 0
            AND review_decision IS DISTINCT FROM 'correct'
        )
    );

CREATE UNIQUE INDEX IF NOT EXISTS attachment_results_one_file_issue ON public.attachment_results (attachment_id)
    WHERE field_key IS NULL;

COMMIT;
