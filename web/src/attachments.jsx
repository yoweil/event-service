import { useEffect, useRef, useState } from "react";
import { Alert, Button, Icon, Input } from "@intetech/ui-kit";
import { useResource } from "./api.js";
import { Busy, Failure } from "./common.jsx";
import { showActor, showTime } from "./model.js";

const numberFormat = new Intl.NumberFormat("ru-RU", { maximumFractionDigits: 1 });
function fileSize(bytes) {
  if (bytes < 1024) return bytes + " Б";
  if (bytes < 1024 * 1024) return numberFormat.format(bytes / 1024) + " КиБ";
  return numberFormat.format(bytes / (1024 * 1024)) + " МиБ";
}

const reviewLabels = {
  accept: "Принято",
  correct: "Исправлено и принято",
  reject: "Отклонено",
};

function shownNumber(value, unit) {
  return value == null ? "—" : String(value).replace(".", ",") + (unit ? " " + unit : "");
}

function FileResult({ result, field, currentValue, canReview, decide }) {
  const [correction, setCorrection] = useState(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);
  const pending = result.state === "review" && !result.review_decision;
  const numericField = field && !field.is_archived && ["integer", "number"].includes(field.data_type);
  const canAccept = numericField && result.value_number != null && result.unit_code === field.unit_code;
  const conflict = error?.status === 409;

  async function submit(decision) {
    if (saving || conflict) return;
    setSaving(true);
    setError(null);
    try {
      await decide(decision, decision === "correct" ? correction.trim().replace(",", ".") : undefined);
    } catch (err) {
      if (err.name !== "AbortError") setError(err);
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="file-result">
      <strong>{reviewLabels[result.review_decision] ?? (pending ? "Требует проверки" : "Заполнено автоматически")}</strong>
      <span>{field?.label ?? result.field_key}</span>
      <span>Из файла · {shownNumber(result.value_number, result.unit_code)}</span>
      {pending && numericField && <span>В карточке · {shownNumber(currentValue, field.unit_code)}</span>}
      {result.sheet_name && <span>Лист «{result.sheet_name}» · {result.cell_ref}</span>}
      {result.calculation_method && <span>Способ расчёта · {result.calculation_method}</span>}
      {result.submitted_by_id && <span>Источник · {showActor(result.submitted_by_kind, result.submitted_by_id)}</span>}
      {result.applied_revision && <span>Ревизия {result.applied_revision}</span>}
      {pending && result.reason && <span>{result.reason}</span>}
      {result.review_decision && (
        <>
          {result.reviewed_value_number != null && (
            <span>Записано · {shownNumber(result.reviewed_value_number, field?.unit_code)}</span>
          )}
          <span>{result.reviewed_by_id} · {showTime(result.reviewed_at)}</span>
        </>
      )}
      {pending && canReview && (
        <>
          {conflict ? (
            <Alert variant="warning" title="Обновите результаты и проверьте значения ещё раз" role="alert" />
          ) : (
            error && <Failure error={error} />
          )}
          {correction !== null ? (
            <form
              onSubmit={(event) => {
                event.preventDefault();
                if (correction.trim()) submit("correct");
              }}
            >
              <Input
                block
                inputMode="decimal"
                label={field?.unit_code ? "Исправленное значение (" + field.unit_code + ")" : "Исправленное значение"}
                value={correction}
                onChange={(event) => setCorrection(event.target.value)}
                disabled={saving || conflict}
              />
              <div className="file-review-actions">
                <Button type="submit" size="sm" loading={saving} disabled={conflict || !correction.trim()}>
                  Сохранить исправление
                </Button>
                <Button type="button" size="sm" variant="ghost" disabled={saving} onClick={() => setCorrection(null)}>
                  Отмена
                </Button>
              </div>
            </form>
          ) : (
            <div className="file-review-actions">
              {canAccept && (
                <Button type="button" size="sm" disabled={saving || conflict} onClick={() => submit("accept")}>
                  Принять
                </Button>
              )}
              {numericField && (
                <Button
                  type="button"
                  size="sm"
                  variant="secondary"
                  disabled={saving || conflict}
                  onClick={() => {
                    setError(null);
                    setCorrection(canAccept ? String(result.value_number).replace(".", ",") : "");
                  }}
                >
                  Исправить
                </Button>
              )}
              <Button type="button" size="sm" variant="ghost" disabled={saving || conflict} onClick={() => submit("reject")}>
                Отклонить
              </Button>
            </div>
          )}
        </>
      )}
    </div>
  );
}

export function Attachments({ eventId, api, card, fields, refreshCard, canReview }) {
  const path = "/events/" + eventId + "/attachments";
  const list = useResource(api, path);
  const picker = useRef(null);
  const lifetime = useRef(null);
  const [progress, setProgress] = useState("");
  const [failed, setFailed] = useState([]);
  const [downloading, setDownloading] = useState(null);
  const [downloadError, setDownloadError] = useState(null);
  const definitions = new Map(fields?.map((field) => [field.field_key, field]));
  const currentNumbers = new Map(card?.fields.map((row) => [row.field_key, row.value_number]));
  useEffect(() => {
    const controller = new AbortController();
    lifetime.current = controller;
    return () => controller.abort();
  }, [eventId]);

  async function upload(files) {
    if (!files.length || progress) return;
    const signal = lifetime.current.signal;
    setFailed([]);
    const errors = [];
    let uploaded = 0;
    for (const [index, file] of files.entries()) {
      if (signal.aborted) return;
      setProgress("Загрузка " + (index + 1) + " из " + files.length + " · " + file.name);
      const body = new FormData();
      body.append("file", file);
      try {
        await api(path, { method: "POST", body, signal });
        uploaded++;
      } catch (err) {
        if (signal.aborted || err.status === 401) return;
        errors.push({ file, message: err.message });
      }
    }
    if (signal.aborted) return;
    if (uploaded) list.retry();
    setFailed(errors);
    setProgress("");
  }
  async function download(file) {
    const signal = lifetime.current.signal;
    setDownloading(file.id);
    setDownloadError(null);
    try {
      const blob = await api(path + "/" + file.id, { responseType: "blob", signal });
      if (signal.aborted) return;
      const href = URL.createObjectURL(blob);
      const link = document.createElement("a");
      link.href = href;
      link.download = file.filename;
      document.body.append(link);
      link.click();
      link.remove();
      setTimeout(() => URL.revokeObjectURL(href), 30000);
    } catch (err) {
      if (!signal.aborted) setDownloadError(err);
    } finally {
      if (!signal.aborted) setDownloading(null);
    }
  }
  async function review(file, result, decision, value) {
    const signal = lifetime.current.signal;
    await api(path + "/" + file.id + "/results/" + result.id + "/review", {
      method: "POST",
      body: { decision, expected_revision: card.revision, value_number: value },
      signal,
    });
    if (!signal.aborted) {
      list.retry();
      refreshCard();
    }
  }
  return (
    <section className="surface panel attachments" aria-labelledby="attachment-heading">
      <div className="attachment-header">
        <h2 id="attachment-heading">Вложения</h2>
        <input
          type="file"
          multiple
          hidden
          ref={picker}
          aria-label="Выбрать файлы"
          onChange={(e) => {
            const files = Array.from(e.target.files);
            e.target.value = "";
            upload(files);
          }}
        />
        <Button
          type="button"
          icon="paperclip"
          variant="secondary"
          disabled={!!progress}
          onClick={() => picker.current.click()}
        >
          Прикрепить файлы
        </Button>
      </div>
      <p className="type-hint">Можно выбрать несколько файлов, до 20 МиБ каждый.</p>
      {progress && <p role="status">{progress}</p>}
      {failed.length > 0 && (
        <Alert
          variant="danger"
          title="Не удалось прикрепить файлы"
          role="alert"
          description={
            <ul>
              {failed.map(({ file, message }, i) => (
                <li key={i}>
                  {file.name} — {message}
                </li>
              ))}
            </ul>
          }
        />
      )}
      {downloadError && <Failure error={downloadError} />}
      {list.error ? (
        <Failure error={list.error} retry={list.retry} />
      ) : !list.data ? (
        <Busy />
      ) : !list.data.length ? (
        <p className="type-hint">Вложений пока нет.</p>
      ) : (
        <ul className="attachment-list">
          {list.data.map((file) => (
            <li key={file.id}>
              <Icon name="file" size={18} />
              <div className="attachment-info">
                <strong>{file.filename}</strong>
                <span>
                  {fileSize(file.size_bytes)} · {showTime(file.uploaded_at)} · {showActor(file.uploaded_by_kind, file.uploaded_by_id)}
                </span>
                {file.results?.map((result) => (
                  <FileResult
                    key={result.id}
                    result={result}
                    field={definitions.get(result.field_key)}
                    currentValue={currentNumbers.get(result.field_key)}
                    canReview={Boolean(canReview && refreshCard && card && fields)}
                    decide={(decision, value) => review(file, result, decision, value)}
                  />
                ))}
              </div>
              <Button
                type="button"
                variant="ghost"
                icon="download"
                aria-label={"Скачать " + file.filename}
                loading={downloading === file.id}
                disabled={downloading !== null}
                onClick={() => download(file)}
              >
                Скачать
              </Button>
            </li>
          ))}
        </ul>
      )}
      {!!list.data?.length && (
        <Button type="button" variant="ghost" onClick={() => { list.retry(); refreshCard?.(); }}>
          Обновить результаты
        </Button>
      )}
    </section>
  );
}
