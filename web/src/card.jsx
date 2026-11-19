import { useState } from "react";
import { Alert, Button, Empty, Input, PageHeader, Textarea, toast } from "@intetech/ui-kit";
import { useResource } from "./api.js";
import { Attachments } from "./attachments.jsx";
import { Busy, Choice, ExtraInput, Failure, kinds, option, StateBadge, statuses } from "./common.jsx";
import { initialForm, payload, showTime, valueColumns } from "./model.js";

function displayField(f, row) {
  if (!row) return "—";
  const value = row[valueColumns[f.data_type]];
  if (f.data_type === "boolean") return value ? "Да" : "Нет";
  if (f.data_type === "select") return f.options.find((o) => o.code === value)?.label ?? value;
  if (f.data_type === "datetime") return showTime(value);
  return String(value) + (f.unit_code ? " " + f.unit_code : "");
}
function Datum({ label, children }) {
  return (
    <div>
      <dt>{label}</dt>
      <dd>{children}</dd>
    </div>
  );
}
function Details({ card, definition }) {
  const stored = new Map(card.fields.map((f) => [f.field_key, f]));
  const fields = definition.fields.filter((f) => !f.is_archived || stored.has(f.field_key));
  return (
    <div className="card-layout">
      <section className="surface panel">
        <h2>Параметры события</h2>
        <dl className="data-grid">
          <Datum label="Скважина">{card.well_id}</Datum>
          <Datum label="Тип события">{definition.name}</Datum>
          <Datum label="Начало">{showTime(card.started_at)}</Datum>
          <Datum label="Длительность">
            {card.time_kind === "instant"
              ? "Момент"
              : card.ended_at
                ? "До " + showTime(card.ended_at)
                : "Открытый период"}
          </Datum>
        </dl>
        <h2>Описание</h2>
        <p className="description">{card.description || "Описание не указано."}</p>
        <h2>Дополнительные поля</h2>
        {fields.length ? (
          <dl className="data-grid">
            {fields.map((f) => (
              <Datum key={f.field_key} label={f.label + (f.is_archived ? " (архив)" : "")}>
                {displayField(f, stored.get(f.field_key))}
              </Datum>
            ))}
          </dl>
        ) : (
          <p>У этого типа нет дополнительных полей.</p>
        )}
      </section>
      <aside className="surface panel meta">
        <h2>Сведения о записи</h2>
        <dl>
          <Datum label="Ревизия">{card.revision}</Datum>
          <Datum label="Создал">{card.created_by_id}</Datum>
          <Datum label="Создано">{showTime(card.created_at)}</Datum>
          <Datum label="Обновлено">{showTime(card.updated_at)}</Datum>
        </dl>
      </aside>
    </div>
  );
}

function Editor({ api, card, types, initialType, done, cancel, reload }) {
  const [form, setForm] = useState(() =>
    initialForm(card, types.find((t) => t.id === initialType)?.id ?? types[0]?.id),
  );
  const [error, setError] = useState(null);
  const [saving, setSaving] = useState(false);
  const def = useResource(
    api,
    form.event_type_id ? "/event-types/" + form.event_type_id + (card ? "?include_archived=true" : "") : null,
  );
  const set = (key, value) => setForm((f) => ({ ...f, [key]: value }));
  const fields = def.data?.fields ?? [];
  async function save(e) {
    e.preventDefault();
    if (!def.data || saving || error?.status === 409) return;
    setError(null);
    setSaving(true);
    try {
      const body = payload(form, fields, card);
      const saved = await api(card ? "/events/" + card.id : "/events", {
        method: card ? "PUT" : "POST",
        body,
      });
      toast.success(card ? "Изменения сохранены" : "Событие создано");
      done(saved.id);
    } catch (err) {
      setError(err);
    } finally {
      setSaving(false);
    }
  }
  return (
    <form onSubmit={save} className="editor">
      <fieldset disabled={saving} className="surface panel">
        <h2>Параметры события</h2>
        <div className="form-grid">
          {card ? (
            <Input block label="Тип события" readOnly value={def.data?.name ?? "…"} />
          ) : (
            <Choice
              label="Тип события"
              required
              value={form.event_type_id}
              options={types.map((t) => option(t.id, t.name))}
              onChange={(id) => {
                setForm((f) => ({ ...f, event_type_id: id, values: Object.create(null) }));
                setError(null);
              }}
            />
          )}
          <Input
            block
            label="Скважина"
            required
            placeholder="Идентификатор скважины"
            value={form.well_id}
            onChange={(e) => set("well_id", e.target.value)}
          />
          <Choice label="Статус" value={form.status} options={statuses} onChange={(s) => set("status", s)} />
          <Choice
            label="Вид времени"
            value={form.time_kind}
            options={kinds}
            onChange={(v) => set("time_kind", v)}
          />
          <Input
            block
            label="Начало"
            required
            type="datetime-local"
            helper={"Часовой пояс: " + Intl.DateTimeFormat().resolvedOptions().timeZone}
            step="any"
            value={form.started_at}
            onChange={(e) => set("started_at", e.target.value)}
          />
          {form.time_kind === "period" && (
            <Input
              block
              label="Конец периода"
              type="datetime-local"
              step="any"
              value={form.ended_at}
              onChange={(e) => set("ended_at", e.target.value)}
            />
          )}
        </div>
        <Textarea
          label="Описание"
          rows={3}
          value={form.description}
          onChange={(e) => set("description", e.target.value)}
        />
        <h2>Дополнительные поля</h2>
        {def.loading ? (
          <Busy />
        ) : def.error ? (
          <Failure error={def.error} retry={def.retry} />
        ) : fields.some((f) => !f.is_archived) ? (
          <div className="form-grid">
            {fields
              .filter((f) => !f.is_archived)
              .map((f) => (
                <ExtraInput
                  key={f.field_key}
                  field={f}
                  required={form.status === "ready" && f.is_required}
                  value={Object.hasOwn(form.values, f.field_key) ? form.values[f.field_key] : ""}
                  onChange={(value) =>
                    setForm((old) => ({ ...old, values: { ...old.values, [f.field_key]: value } }))
                  }
                />
              ))}
          </div>
        ) : (
          <p>У этого типа нет активных дополнительных полей.</p>
        )}
        {error &&
          (error.status === 409 ? (
            <Alert
              variant="warning"
              role="alert"
              title="Карточку уже изменили"
              description={
                <>
                  Исправления остаются в форме. Загрузка актуальной карточки сбросит их.{" "}
                  <Button variant="ghost" onClick={reload}>
                    Загрузить актуальную карточку
                  </Button>
                </>
              }
            />
          ) : (
            <Failure error={error} />
          ))}
        {!card && <p className="type-hint">Файлы можно прикрепить после сохранения события.</p>}
        <div className="editor-footer">
          <Button variant="secondary" onClick={cancel}>
            Отмена
          </Button>
          <Button type="submit" loading={saving} disabled={!def.data || error?.status === 409} icon="check">
            Сохранить
          </Button>
        </div>
      </fieldset>
    </form>
  );
}

export function EventCard({ api, types, id, initialType }) {
  const create = id === "new";
  const [editing, setEditing] = useState(create);
  const record = useResource(api, create ? null : "/events/" + id);
  const card = record.data;
  const definition = useResource(
    api,
    !editing && card ? "/event-types/" + card.event_type_id + "?include_archived=true" : null,
  );
  function back() {
    location.hash = "/";
  }
  function done(savedID) {
    if (create) location.hash = "/events/" + savedID;
    else {
      setEditing(false);
      record.retry();
    }
  }
  return (
    <>
      <PageHeader
        className="page-title"
        size="lg"
        bordered={false}
        onBack={back}
        backLabel="В журнал"
        title={create ? "Новое событие" : "Событие №" + id}
        tags={card && <StateBadge status={card.status} />}
        extra={
          !create &&
          !editing &&
          card && (
            <Button icon="pencil" variant="secondary" onClick={() => setEditing(true)}>
              Редактировать
            </Button>
          )
        }
      />
      {record.error ? (
        <Failure error={record.error} retry={record.retry} />
      ) : !create && !card ? (
        <Busy />
      ) : editing ? (
        create && !types.length ? (
          <Empty title="Нет активных типов событий">
            <a href="#/types/new">Создать тип события</a>
          </Empty>
        ) : (
          <Editor
            card={card}
            api={api}
            types={types}
            initialType={initialType}
            done={done}
            cancel={() => (create ? back() : setEditing(false))}
            reload={() => {
              setEditing(false);
              record.retry();
            }}
          />
        )
      ) : definition.error ? (
        <Failure error={definition.error} retry={definition.retry} />
      ) : definition.data ? (
        <Details card={card} definition={definition.data} />
      ) : (
        <Busy />
      )}
      {!create && !record.error && (
        <Attachments
          eventId={id}
          api={api}
          card={card}
          fields={definition.data?.fields}
          refreshCard={editing ? undefined : record.retry}
        />
      )}
    </>
  );
}
