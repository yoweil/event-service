package main

import (
	"context"
	"crypto/subtle"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/lib/pq"
)

type api struct {
	db    queryer
	actor string
}

func newHandler(db queryer, token, actor string, requestTimeout time.Duration) http.Handler {
	a := api{db: db, actor: actor}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /event-types", a.listTypes)
	mux.HandleFunc("POST /event-types", a.createType)
	mux.HandleFunc("GET /event-types/{id}", a.getType)
	mux.HandleFunc("PATCH /event-types/{id}", a.editType)

	mux.HandleFunc("POST /events", a.saveEvent)
	mux.HandleFunc("GET /events", a.listEvents)
	mux.HandleFunc("PUT /events/{id}", a.saveEvent)
	mux.HandleFunc("GET /events/{id}", a.getEvent)

	mux.HandleFunc("GET /events/{id}/attachments", a.listAttachments)
	mux.HandleFunc("POST /events/{id}/attachments", a.uploadAttachment)
	mux.HandleFunc("GET /events/{id}/attachments/{attachment}", a.downloadAttachment)
	mux.HandleFunc("POST /events/{id}/attachments/{attachment}/results", a.recordAttachmentResult)
	mux.HandleFunc("POST /events/{id}/attachments/{attachment}/results/batch", a.recordAttachmentResults)
	mux.HandleFunc("POST /events/{id}/attachments/{attachment}/results/{result}/review", a.reviewAttachmentResult)

	mux.HandleFunc("/events/{id}/attachments/{attachment}/results/{result}/review", methodNotAllowed("POST"))
	mux.HandleFunc("/events/{id}/attachments/{attachment}/results", methodNotAllowed("POST"))
	mux.HandleFunc("/events/{id}/attachments/{attachment}/results/batch", methodNotAllowed("POST"))
	mux.HandleFunc("/events/{id}/attachments", methodNotAllowed("GET, HEAD, POST"))
	mux.HandleFunc("/events/{id}/attachments/{attachment}", methodNotAllowed("GET, HEAD"))

	mux.HandleFunc("/event-types", methodNotAllowed("GET, HEAD, POST"))
	mux.HandleFunc("/event-types/{id}", methodNotAllowed("GET, HEAD, PATCH"))
	mux.HandleFunc("/events", methodNotAllowed("GET, HEAD, POST"))
	mux.HandleFunc("/events/{id}", methodNotAllowed("GET, HEAD, PUT"))
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		respondError(w, http.StatusNotFound, "route not found")
	})

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		scheme, credential, ok := strings.Cut(r.Header.Get("Authorization"), " ")
		if !ok || !strings.EqualFold(scheme, "Bearer") || credential == "" || subtle.ConstantTimeCompare([]byte(credential), []byte(token)) != 1 {
			w.Header().Set("WWW-Authenticate", "Bearer")
			respondError(w, http.StatusUnauthorized, "invalid bearer token")
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), requestTimeout)
		defer cancel()
		mux.ServeHTTP(w, r.WithContext(ctx))
	})
}

func methodNotAllowed(allow string) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Allow", allow)
		respondError(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

func respond(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		log.Printf("write response: %v", err)
	}
}

func respondError(w http.ResponseWriter, status int, message string) {
	respond(w, status, map[string]string{"error": message})
}

func readBody(w http.ResponseWriter, r *http.Request, dst any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	err := dec.Decode(dst)
	if err == nil {
		err = dec.Decode(new(json.RawMessage))
		if err == io.EOF {
			return true
		}
	}
	var tooLarge *http.MaxBytesError
	if errors.As(err, &tooLarge) {
		respondError(w, http.StatusRequestEntityTooLarge, "request exceeds 1 MiB")
	} else {
		respondError(w, http.StatusBadRequest, "expected one JSON object with valid field names and values")
	}
	return false
}

func databaseError(w http.ResponseWriter, err error) {
	if errors.Is(err, context.DeadlineExceeded) {
		respondError(w, http.StatusServiceUnavailable, "database request timed out")
		return
	}
	if errors.Is(err, sql.ErrNoRows) {
		respondError(w, http.StatusNotFound, "event not found")
		return
	}
	var pg *pq.Error
	if errors.As(err, &pg) {
		switch pg.Code {
		case "57014", "55P03":
			respondError(w, http.StatusServiceUnavailable, "database request interrupted or lock unavailable")
			return
		case "EV409":
			respondError(w, http.StatusConflict, "event revision has changed")
			return
		case "AR409":
			respondError(w, http.StatusConflict, "result has already been resolved")
			return
		case "ET409":
			respondError(w, http.StatusConflict, "event type has changed")
			return
		case "23505":
			respondError(w, http.StatusConflict, "duplicate code or field key")
			return
		case "P0002":
			respondError(w, http.StatusNotFound, "event or event type not found")
			return
		case "23514", "22023":
			if pg.Constraint == "" {
				respondError(w, http.StatusUnprocessableEntity, pg.Message)
				return
			}
		}
		class := pg.Code.Class()
		if class == "22" || class == "23" {
			respondError(w, http.StatusUnprocessableEntity, "invalid property, field value or option")
			return
		}
	}
	log.Printf("event database: %v", err)
	respondError(w, http.StatusInternalServerError, "database request failed")
}

func pathID(w http.ResponseWriter, r *http.Request, resource string) (int64, bool) {
	return positivePathID(w, r, "id", resource)
}

func positivePathID(w http.ResponseWriter, r *http.Request, param, resource string) (int64, bool) {
	id, err := strconv.ParseInt(r.PathValue(param), 10, 64)
	if err != nil || id < 1 {
		respondError(w, http.StatusBadRequest, "expected a positive "+resource+" id")
		return 0, false
	}
	return id, true
}

func includeArchived(w http.ResponseWriter, r *http.Request) (bool, bool) {
	query, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil {
		respondError(w, http.StatusBadRequest, "invalid query string")
		return false, false
	}
	values, present := query["include_archived"]
	if !present {
		return false, true
	}
	if len(values) != 1 || (values[0] != "true" && values[0] != "false") {
		respondError(w, http.StatusBadRequest, "include_archived must be true or false")
		return false, false
	}
	return values[0] == "true", true
}

func (a *api) listTypes(w http.ResponseWriter, r *http.Request) {
	archived, ok := includeArchived(w, r)
	if !ok {
		return
	}
	types, err := a.readTypes(r.Context(), archived)
	if err != nil {
		databaseError(w, err)
		return
	}
	respond(w, http.StatusOK, types)
}

func (a *api) getType(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(w, r, "event type")
	if !ok {
		return
	}
	archived, ok := includeArchived(w, r)
	if !ok {
		return
	}
	definition, err := a.readType(r.Context(), id, archived)
	if errors.Is(err, sql.ErrNoRows) {
		respondError(w, http.StatusNotFound, "event type not found")
		return
	}
	if err != nil {
		databaseError(w, err)
		return
	}
	respond(w, http.StatusOK, definition)
}

func (a *api) createType(w http.ResponseWriter, r *http.Request) {
	var input createTypeInput
	if !readBody(w, r, &input) {
		return
	}
	if input.Code == "" || strings.TrimSpace(input.Name) == "" {
		respondError(w, http.StatusBadRequest, "code and name are required")
		return
	}
	result, err := a.insertType(r.Context(), input)
	if err != nil {
		databaseError(w, err)
		return
	}
	respond(w, http.StatusCreated, result)
}

func (a *api) editType(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(w, r, "event type")
	if !ok {
		return
	}
	var input editTypeInput
	if !readBody(w, r, &input) {
		return
	}
	if input.ExpectedUpdatedAt == nil || (input.Name != nil && strings.TrimSpace(*input.Name) == "") {
		respondError(w, http.StatusBadRequest, "expected_updated_at is required and name cannot be blank")
		return
	}
	if input.Name == nil && input.Description == nil && len(input.Fields)+len(input.Options)+len(input.ArchiveKeys) == 0 {
		respondError(w, http.StatusBadRequest, "no changes supplied")
		return
	}
	result, err := a.applyTypeEdit(r.Context(), id, input)
	if err != nil {
		databaseError(w, err)
		return
	}
	respond(w, http.StatusOK, result)
}

func (a *api) saveEvent(w http.ResponseWriter, r *http.Request) {
	var input saveInput
	if !readBody(w, r, &input) {
		return
	}
	var id *int64
	status := http.StatusCreated
	if r.Method == http.MethodPut {
		target, ok := pathID(w, r, "event")
		if !ok {
			return
		}
		id = &target
		status = http.StatusOK
		if input.ExpectedRevision == nil || *input.ExpectedRevision < 1 || input.Description == nil {
			respondError(w, http.StatusBadRequest, "update requires expected_revision and description")
			return
		}
	} else if input.ExpectedRevision != nil || input.SourceNotificationID != nil {
		respondError(w, http.StatusBadRequest, "expected_revision and source_notification_id apply only to updates")
		return
	}
	if input.TypeID < 1 || strings.TrimSpace(input.WellID) == "" || input.Start == nil || input.TimeKind == "" || input.Status == "" {
		respondError(w, http.StatusBadRequest, "event_type_id, well_id, started_at, time_kind and status are required")
		return
	}
	for _, field := range input.Fields {
		if field.Date != nil {
			if _, err := time.Parse(time.DateOnly, *field.Date); err != nil {
				respondError(w, http.StatusBadRequest, "value_date must use YYYY-MM-DD")
				return
			}
		}
	}
	result, err := a.persistEvent(r.Context(), id, input)
	if err != nil {
		databaseError(w, err)
		return
	}
	if id == nil {
		w.Header().Set("Location", "/events/"+strconv.FormatInt(result.ID, 10))
	}
	respond(w, status, result)
}

func (a *api) getEvent(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(w, r, "event")
	if !ok {
		return
	}
	card, err := a.readEvent(r.Context(), id)
	if err != nil {
		databaseError(w, err)
		return
	}
	respond(w, http.StatusOK, card)
}
