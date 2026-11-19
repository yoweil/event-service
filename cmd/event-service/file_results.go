package main

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
)

func resultActor(ctx context.Context) actor {
	who := requestActor(ctx)
	if who.shared {
		who.ID = "attachment-processor"
	}
	return who
}

type attachmentResultInput struct {
	Key               string       `json:"field_key"`
	Unit              *string      `json:"unit_code"`
	Value             *json.Number `json:"value_number"`
	Sheet             *string      `json:"sheet_name"`
	Cell              *string      `json:"cell_ref"`
	Issue             *string      `json:"issue"`
	CalculationMethod *string      `json:"calculation_method"`
}

func (input attachmentResultInput) valid() bool {
	return input.Key != "" &&
		(input.Value != nil || input.Issue != nil) &&
		(input.Issue == nil || strings.TrimSpace(*input.Issue) != "") &&
		(input.CalculationMethod == nil || strings.TrimSpace(*input.CalculationMethod) != "") &&
		(input.Value == nil || (input.Sheet != nil && input.Cell != nil &&
			strings.TrimSpace(*input.Sheet) != "" && strings.TrimSpace(*input.Cell) != ""))
}

func (a *api) recordAttachmentResult(w http.ResponseWriter, r *http.Request) {
	eventID, ok := pathID(w, r, "event")
	if !ok {
		return
	}
	fileID, ok := positivePathID(w, r, "attachment", "attachment")
	if !ok {
		return
	}
	var input struct {
		Notice string `json:"notification_id"`
		attachmentResultInput
	}
	if !readBody(w, r, &input) {
		return
	}
	if input.Notice == "" || !input.valid() {
		respondError(w, 400, "expected notification_id, field_key and either a sourced numeric value or an issue")
		return
	}
	var result json.RawMessage
	who := resultActor(r.Context())
	err := a.db.QueryRowContext(r.Context(), `SELECT row_to_json(r) FROM public.record_attachment_result($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12) r`,
		eventID, fileID, input.Notice, input.Key, input.Unit, input.Value, input.Sheet, input.Cell, input.Issue, input.CalculationMethod,
		who.Kind, who.ID).Scan(&result)
	if err != nil {
		databaseError(w, err)
		return
	}
	respond(w, http.StatusOK, result)
}

func (a *api) recordAttachmentResults(w http.ResponseWriter, r *http.Request) {
	eventID, ok := pathID(w, r, "event")
	if !ok {
		return
	}
	fileID, ok := positivePathID(w, r, "attachment", "attachment")
	if !ok {
		return
	}
	var input struct {
		Notice  string                  `json:"notification_id"`
		Results []attachmentResultInput `json:"results"`
	}
	if !readBody(w, r, &input) {
		return
	}
	if input.Notice == "" || len(input.Results) == 0 {
		respondError(w, http.StatusBadRequest, "expected notification_id and a nonempty results array")
		return
	}
	for _, result := range input.Results {
		if !result.valid() {
			respondError(w, http.StatusBadRequest, "expected field_key and either a sourced numeric value or an issue for each result")
			return
		}
	}
	results, err := arrayParam(input.Results)
	if err != nil {
		respondError(w, http.StatusBadRequest, "invalid results")
		return
	}
	var response json.RawMessage
	who := resultActor(r.Context())
	err = a.db.QueryRowContext(r.Context(), `
        SELECT array_to_json(public.record_attachment_results($1,$2,$3,
            ARRAY(SELECT result FROM json_populate_recordset(NULL::public.attachment_result_input, $4::json) AS result),$5,$6))`,
		eventID, fileID, input.Notice, results, who.Kind, who.ID).Scan(&response)
	if err != nil {
		databaseError(w, err)
		return
	}
	respond(w, http.StatusOK, response)
}

func (a *api) reviewAttachmentResult(w http.ResponseWriter, r *http.Request) {
	who := requestActor(r.Context())
	if !who.canReview() {
		respondError(w, http.StatusForbidden, "manual review requires a user token")
		return
	}
	eventID, ok := pathID(w, r, "event")
	if !ok {
		return
	}
	fileID, ok := positivePathID(w, r, "attachment", "attachment")
	if !ok {
		return
	}
	resultID, ok := positivePathID(w, r, "result", "result")
	if !ok {
		return
	}
	var input struct {
		Decision         string       `json:"decision"`
		ExpectedRevision int64        `json:"expected_revision"`
		Value            *json.Number `json:"value_number"`
	}
	if !readBody(w, r, &input) {
		return
	}
	if input.ExpectedRevision < 1 || (input.Decision != "accept" && input.Decision != "correct" && input.Decision != "reject") ||
		(input.Decision == "correct") != (input.Value != nil) {
		respondError(w, http.StatusBadRequest, "expected decision and positive expected_revision, with value_number only for correct")
		return
	}
	var result json.RawMessage
	err := a.db.QueryRowContext(r.Context(), `SELECT row_to_json(r) FROM public.review_attachment_result($1,$2,$3,$4,$5,$6,$7) r`,
		eventID, fileID, resultID, input.ExpectedRevision, input.Decision, input.Value, who.ID).Scan(&result)
	if err != nil {
		databaseError(w, err)
		return
	}
	respond(w, http.StatusOK, result)
}
