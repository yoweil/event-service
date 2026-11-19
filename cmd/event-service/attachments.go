package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

const maxAttachmentBytes = 20 << 20

func multipartError(w http.ResponseWriter, err error) {
	var large *http.MaxBytesError
	if errors.As(err, &large) {
		respondError(w, http.StatusRequestEntityTooLarge, "file exceeds 20 MiB")
		return
	}
	respondError(w, http.StatusBadRequest, "expected one complete file in multipart field file")
}

func readAttachment(w http.ResponseWriter, r *http.Request) (string, []byte, bool) {
	r.Body = http.MaxBytesReader(w, r.Body, maxAttachmentBytes+(64<<10))
	mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || mediaType != "multipart/form-data" {
		respondError(w, http.StatusUnsupportedMediaType, "expected multipart/form-data")
		return "", nil, false
	}
	reader, err := r.MultipartReader()
	if err != nil {
		multipartError(w, err)
		return "", nil, false
	}
	part, err := reader.NextRawPart()
	if err != nil {
		multipartError(w, err)
		return "", nil, false
	}
	disposition, params, err := mime.ParseMediaType(part.Header.Get("Content-Disposition"))
	name := params["filename"]
	if err != nil || disposition != "form-data" || params["name"] != "file" || !validAttachmentName(name) {
		respondError(w, http.StatusBadRequest, "expected field file with a valid filename")
		return "", nil, false
	}
	data, err := io.ReadAll(io.LimitReader(part, maxAttachmentBytes+1))
	if err != nil {
		multipartError(w, err)
		return "", nil, false
	}
	if len(data) > maxAttachmentBytes {
		respondError(w, http.StatusRequestEntityTooLarge, "file exceeds 20 MiB")
		return "", nil, false
	}
	if _, err = reader.NextRawPart(); err != io.EOF {
		multipartError(w, err)
		return "", nil, false
	}
	return name, data, true
}

func validAttachmentName(name string) bool {
	return strings.TrimSpace(name) != "" && name != "." && name != ".." && utf8.ValidString(name) &&
		utf8.RuneCountInString(name) <= 255 && !strings.ContainsAny(name, "/\\") &&
		strings.IndexFunc(name, unicode.IsControl) < 0
}

func (a *api) uploadAttachment(w http.ResponseWriter, r *http.Request) {
	eventID, ok := pathID(w, r, "event")
	if !ok {
		return
	}
	name, data, ok := readAttachment(w, r)
	if !ok {
		return
	}
	var fileID int64
	var metadata json.RawMessage
	err := a.db.QueryRowContext(r.Context(), `
  WITH saved AS (
   INSERT INTO public.event_attachments AS a (event_id,filename,content,uploaded_by_id)
   SELECT e.id,$2,$3,$4 FROM public.events e WHERE e.id=$1
   ON CONFLICT (event_id,filename,digest) DO UPDATE SET filename=a.filename
   RETURNING id,filename,size_bytes,encode(digest,'hex') AS sha256,uploaded_by_id,uploaded_at
  ) SELECT id,row_to_json(saved) FROM saved`, eventID, name, data, a.actor).Scan(&fileID, &metadata)
	if err != nil {
		databaseError(w, err)
		return
	}
	w.Header().Set("Location", "/events/"+strconv.FormatInt(eventID, 10)+"/attachments/"+strconv.FormatInt(fileID, 10))
	respond(w, http.StatusOK, metadata)
}

func (a *api) listAttachments(w http.ResponseWriter, r *http.Request) {
	eventID, ok := pathID(w, r, "event")
	if !ok {
		return
	}
	var files json.RawMessage
	err := a.db.QueryRowContext(r.Context(), `
  SELECT coalesce((SELECT json_agg(file ORDER BY file.id DESC) FROM (
   SELECT a.id,a.filename,a.size_bytes,encode(a.digest,'hex') AS sha256,a.uploaded_by_id,a.uploaded_at,
          coalesce((SELECT json_agg(r ORDER BY r.id) FROM public.attachment_results r
                    WHERE r.attachment_id=a.id),'[]'::json) AS results
   FROM public.event_attachments a WHERE a.event_id=e.id
  ) AS file),'[]'::json) FROM public.events e WHERE e.id=$1`, eventID).Scan(&files)
	if err != nil {
		databaseError(w, err)
		return
	}
	respond(w, http.StatusOK, files)
}

func (a *api) downloadAttachment(w http.ResponseWriter, r *http.Request) {
	eventID, ok := pathID(w, r, "event")
	if !ok {
		return
	}
	fileID, err := strconv.ParseInt(r.PathValue("attachment"), 10, 64)
	if err != nil || fileID < 1 {
		respondError(w, http.StatusBadRequest, "expected a positive attachment id")
		return
	}
	var name string
	var size int
	var data []byte
	err = a.db.QueryRowContext(r.Context(), `
  SELECT filename,size_bytes,CASE WHEN $3 THEN content END FROM public.event_attachments
  WHERE event_id=$1 AND id=$2`, eventID, fileID, r.Method != http.MethodHead).Scan(&name, &size, &data)
	if errors.Is(err, sql.ErrNoRows) {
		respondError(w, http.StatusNotFound, "attachment not found")
		return
	}
	if err != nil {
		databaseError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": name}))
	w.Header().Set("Content-Length", strconv.Itoa(size))
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Cache-Control", "private, no-store")
	if r.Method != http.MethodHead {
		_, _ = w.Write(data)
	}
}
