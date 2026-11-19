import { useState } from "react";
import { Button } from "@intetech/ui-kit";
import { useResource } from "./api.js";
import { Busy, Failure } from "./common.jsx";
import { showActor, showTime, statusName } from "./model.js";

const baseLabels = {
  well_id: "Скважина", status: "Статус", time_kind: "Вид времени",
  started_at: "Начало", ended_at: "Окончание", description: "Описание",
};

function displayValue(value, change, field) {
  if (value == null || value === "") return "—";
  if (change.scope === "base") {
    if (change.key === "status") return statusName(value);
    if (change.key === "time_kind") return value === "instant" ? "Момент" : "Период";
    if (change.key === "started_at" || change.key === "ended_at") return showTime(value);
  }
  if (field?.data_type === "select") return field.options.find((o) => o.code === value)?.label ?? value;
  if (field?.data_type === "boolean") return value === "true" ? "Да" : "Нет";
  if (field?.data_type === "datetime") return showTime(value);
  return field?.unit_code ? value + " " + field.unit_code : value;
}

export function EventHistory({ api, id, fields }) {
  const [before, setBefore] = useState(null);
  const history = useResource(api, "/events/" + id + "/history" + (before ? "?before_revision=" + before : ""));
  const definitions = new Map(fields.map((f) => [f.field_key, f]));
  const oldest = history.data?.at(-1)?.revision;
  return (
    <section className="surface panel event-history">
      <h2>История изменений</h2>
      {history.error ? <Failure error={history.error} retry={history.retry} /> : !history.data ? <Busy /> : (
        history.data.map((entry) => (
          <details key={entry.revision}>
            <summary>
              {entry.operation === "created" ? "Создание" : "Изменение"} · {showActor(entry.actor_kind, entry.actor_id)}
              {" · "}{showTime(entry.changed_at)} · Ревизия {entry.revision}
            </summary>
            <ul>
              {entry.changes.map((change) => {
                const field = change.scope === "field" ? definitions.get(change.key) : null;
                const label = change.scope === "base" ? baseLabels[change.key] : field?.label;
                return <li key={change.scope + "/" + change.key}>
                  <strong>{label ?? change.key}</strong>{" · "}
                  {displayValue(change.old_value, change, field)} → {displayValue(change.new_value, change, field)}
                </li>;
              })}
            </ul>
          </details>
        ))
      )}
      {(before || (oldest && oldest !== "1")) && (
        <div className="actions">
          {before && <Button variant="ghost" onClick={() => setBefore(null)}>К последним</Button>}
          {oldest && oldest !== "1" && <Button variant="ghost" onClick={() => setBefore(oldest)}>Более ранние</Button>}
        </div>
      )}
    </section>
  );
}
