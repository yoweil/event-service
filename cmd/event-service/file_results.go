package main

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
)

func (a *api) recordAttachmentResult(w http.ResponseWriter, r *http.Request) {
	eventID, ok := pathID(w, r, "event")
	if !ok {
		return
	}
	fileID, err := strconv.ParseInt(r.PathValue("attachment"), 10, 64)
	if err != nil || fileID < 1 {
		respondError(w, 400, "expected a positive attachment id")
		return
	}
	var input struct {
		Notice string       `json:"notification_id"`
		Key    string       `json:"field_key"`
		Unit   *string      `json:"unit_code"`
		Value  *json.Number `json:"value_number"`
		Sheet  *string      `json:"sheet_name"`
		Cell   *string      `json:"cell_ref"`
		Issue  *string      `json:"issue"`
	}
	if !readBody(w, r, &input) {
		return
	}
	if input.Notice == "" || input.Key == "" || (input.Value == nil && input.Issue == nil) ||
		(input.Issue != nil && strings.TrimSpace(*input.Issue) == "") ||
		(input.Value != nil && (input.Sheet == nil || input.Cell == nil || strings.TrimSpace(*input.Sheet) == "" || strings.TrimSpace(*input.Cell) == "")) {
		respondError(w, 400, "expected notification_id, field_key and either a sourced numeric value or an issue")
		return
	}
	var result json.RawMessage
	err = a.db.QueryRowContext(r.Context(), `SELECT row_to_json(r) FROM public.record_attachment_result($1,$2,$3,$4,$5,$6,$7,$8,$9) r`,
		eventID, fileID, input.Notice, input.Key, input.Unit, input.Value, input.Sheet, input.Cell, input.Issue).Scan(&result)
	if err != nil {
		databaseError(w, err)
		return
	}
	respond(w, http.StatusOK, result)
}
