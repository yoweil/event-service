import { useEffect, useRef, useState } from "react";
import { Alert, Button, Icon } from "@intetech/ui-kit";
import { useResource } from "./api.js";
import { Busy, Failure } from "./common.jsx";
import { showTime } from "./model.js";

const numberFormat = new Intl.NumberFormat("ru-RU", { maximumFractionDigits: 1 });
function fileSize(bytes) {
  if (bytes < 1024) return bytes + " Б";
  if (bytes < 1024 * 1024) return numberFormat.format(bytes / 1024) + " КиБ";
  return numberFormat.format(bytes / (1024 * 1024)) + " МиБ";
}

export function Attachments({ eventId, api, fields, refreshCard }) {
  const path = "/events/" + eventId + "/attachments";
  const list = useResource(api, path);
  const picker = useRef(null);
  const lifetime = useRef(null);
  const [progress, setProgress] = useState("");
  const [failed, setFailed] = useState([]);
  const [downloading, setDownloading] = useState(null);
  const [downloadError, setDownloadError] = useState(null);
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
                  {fileSize(file.size_bytes)} · {showTime(file.uploaded_at)} · {file.uploaded_by_id}
                </span>
                {file.results?.map((result) => (
                  <div className="file-result" key={result.id}>
                    <strong>{result.state === "applied" ? "Заполнено автоматически" : "Требует проверки"}</strong>
                    <span>
                      {fields?.find((field) => field.field_key === result.field_key)?.label ?? result.field_key}
                      {result.value_number != null && " · " + String(result.value_number).replace(".", ",") + (result.unit_code ? " " + result.unit_code : "")}
                    </span>
                    {result.sheet_name && <span>Лист «{result.sheet_name}» · {result.cell_ref}</span>}
                    {result.applied_revision && <span>Ревизия {result.applied_revision}</span>}
                    {result.reason && <span>{result.reason}</span>}
                  </div>
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
