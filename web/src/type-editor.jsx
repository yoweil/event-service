import { useRef, useState } from "react";
import { Alert, Button, Checkbox, IconButton, Input, PageHeader, Textarea, toast } from "@intetech/ui-kit";
import { Busy, Choice, Failure } from "./common.jsx";
import { useResource } from "./api.js";
import { buildType, buildTypeEdit, fieldKinds, suggestedCode } from "./type-definition.js";

function NameAndCode({ item, change, nameLabel, codeLabel, option = false, fixedCode = false }) {
  return (
    <>
      <Input
        block
        required
        label={nameLabel}
        value={item.label}
        onChange={(e) => change({ label: e.target.value })}
      />
      <Input
        block
        required
        label={codeLabel}
        readOnly={fixedCode}
        spellCheck={false}
        maxLength={option ? undefined : 64}
        value={item.code ?? suggestedCode(item.label)}
        onChange={(e) => change({ code: e.target.value })}
      />
    </>
  );
}

function replaceRow(rows, id, patch) {
  return rows.map((row) => (row.id === id ? { ...row, ...patch } : row));
}

function FieldEditor({ field, index, update, remove, nextId }) {
  function changeChoice(id, patch) {
    update({ options: replaceRow(field.options, id, patch) });
  }
  return (
    <section className="type-field" aria-label={"Поле " + (index + 1)}>
      <div className="condition-head">
        <h3>Поле {index + 1}</h3>
        <IconButton
          type="button"
          name="trash-2"
          aria-label={"Удалить поле " + (index + 1)}
          onClick={remove}
        />
      </div>
      <div className="form-grid">
        <NameAndCode item={field} change={update} nameLabel="Название поля" codeLabel="Ключ поля" />
        <Choice
          label="Тип данных"
          value={field.data_type}
          options={fieldKinds}
          onChange={(data_type) => update({ data_type })}
        />
        {["number", "integer"].includes(field.data_type) && (
          <Input
            block
            label="Единица измерения"
            value={field.unit_code}
            onChange={(e) => update({ unit_code: e.target.value })}
          />
        )}
      </div>
      <Checkbox checked={field.is_required} onChange={(is_required) => update({ is_required })}>
        Обязательное поле
      </Checkbox>
      {field.data_type === "select" && (
        <div className="type-options">
          <strong>Варианты выбора</strong>
          {field.options.map((choice, i) => (
            <div key={choice.id} className="option-row">
              <NameAndCode
                item={choice}
                change={(patch) => changeChoice(choice.id, patch)}
                option
                nameLabel="Название варианта"
                codeLabel="Код варианта"
              />
              <IconButton
                type="button"
                name="x"
                aria-label={"Удалить вариант " + (i + 1)}
                onClick={() => update({ options: field.options.filter((o) => o.id !== choice.id) })}
              />
            </div>
          ))}
          <Button
            type="button"
            variant="ghost"
            icon="plus"
            onClick={() => update({ options: [...field.options, { id: nextId(), label: "" }] })}
          >
            Добавить вариант
          </Button>
        </div>
      )}
    </section>
  );
}

export function EditTypePage({ api, id, onSaved }) {
  const { data, error, retry } = useResource(api, "/event-types/" + id + "?include_archived=true");
  if (error) return <Failure error={error} retry={retry} />;
  if (!data) return <Busy />;
  if (data.is_archived) return <Alert variant="info" title="Тип находится в архиве" />;
  return <TypeEditor key={id} api={api} definition={data} onSaved={onSaved} reload={retry} />;
}

export function TypeEditor({ api, onSaved, definition, reload }) {
  const [draft, setDraft] = useState(() => ({
    label: definition?.name ?? "",
    code: definition?.code,
    description: definition?.description ?? "",
    fields: [],
    archive: [],
  }));
  const id = useRef(0);
  const nextId = () => ++id.current;
  const [error, setError] = useState("");
  const [stale, setStale] = useState(false);
  const [saving, setSaving] = useState(false);
  const patch = (changes) => setDraft((d) => ({ ...d, ...changes }));
  const back = () => {
    location.hash = definition ? "/types/" + definition.id : "/types";
  };
  const changed =
    !definition ||
    draft.label.trim() !== definition.name ||
    draft.description.trim() !== (definition.description ?? "") ||
    draft.fields.length > 0 ||
    draft.archive.length > 0;
  function addField() {
    const field = {
      id: nextId(),
      label: "",
      data_type: "text",
      is_required: false,
      unit_code: "",
      options: [],
    };
    setDraft((d) => ({ ...d, fields: [...d.fields, field] }));
  }
  async function save(e) {
    e.preventDefault();
    if (saving || stale || !changed) return;
    setSaving(true);
    setError("");
    try {
      const saved = definition
        ? await api("/event-types/" + definition.id, {
            method: "PATCH",
            body: buildTypeEdit(draft, definition),
          })
        : await api("/event-types", { method: "POST", body: buildType(draft) });
      toast.success(definition ? "Изменения сохранены" : "Тип создан");
      onSaved(saved.id);
    } catch (err) {
      if (err.reason === "event type has changed") setStale(true);
      else if (err.reason === "New required field would invalidate ready events")
        setError("У типа уже есть готовые события. Снимите отметку «Обязательное поле» у новых полей.");
      else if (err.status === 409)
        setError(
          definition
            ? "Ключ поля уже занят. Выберите другой ключ."
            : "Код типа уже занят. Введите другой код.",
        );
      else setError(err.message);
    } finally {
      setSaving(false);
    }
  }
  return (
    <>
      <PageHeader
        className="page-title"
        size="lg"
        bordered={false}
        title={definition ? "Изменить тип события" : "Новый тип события"}
        onBack={back}
        backLabel={definition ? "К типу события" : "К типам событий"}
      />
      <form className="editor" onSubmit={save}>
        <fieldset className="surface panel type-editor" disabled={saving}>
          <h2>Сведения о типе</h2>
          <div className="form-grid">
            <NameAndCode
              item={draft}
              change={patch}
              nameLabel="Название типа"
              codeLabel="Код типа"
              fixedCode={!!definition}
            />
          </div>
          {!definition && (
            <p className="type-hint">
              Код и ключи заполняются по названию. Начните с латинской буквы. Можно использовать строчные
              латинские буквы, цифры и подчёркивание, до 64 символов.
            </p>
          )}
          <Textarea
            label="Описание"
            value={draft.description}
            rows={2}
            onChange={(e) => patch({ description: e.target.value })}
          />
          <h2>Дополнительные поля</h2>
          {definition?.fields.map((field) => {
            const queued = draft.archive.includes(field.field_key);
            const kind = fieldKinds.find((k) => k.value === field.data_type)?.label;
            return (
              <div key={field.field_key} className="existing-field">
                <div>
                  <strong>{field.label}</strong>
                  <p className="type-hint">
                    {[kind, field.unit_code, field.field_key].filter(Boolean).join(" · ")}
                  </p>
                </div>
                {field.is_archived ? (
                  <span>В архиве</span>
                ) : (
                  <Button
                    type="button"
                    variant="secondary"
                    aria-pressed={queued}
                    aria-label={(queued ? "Отменить архивирование поля " : "В архив поле ") + field.label}
                    onClick={() =>
                      patch({
                        archive: queued
                          ? draft.archive.filter((k) => k !== field.field_key)
                          : [...draft.archive, field.field_key],
                      })
                    }
                  >
                    {queued ? "Отменить архивирование" : "В архив"}
                  </Button>
                )}
              </div>
            );
          })}
          {draft.archive.length > 0 && (
            <p className="type-hint">
              После сохранения выбранные поля исчезнут из формы ввода. Прежние значения останутся в карточках.
            </p>
          )}
          {draft.fields.map((field, index) => (
            <FieldEditor
              key={field.id}
              field={field}
              index={index}
              nextId={nextId}
              update={(changes) =>
                setDraft((d) => ({ ...d, fields: replaceRow(d.fields, field.id, changes) }))
              }
              remove={() => setDraft((d) => ({ ...d, fields: d.fields.filter((f) => f.id !== field.id) }))}
            />
          ))}
          <Button variant="secondary" type="button" icon="plus" onClick={addField}>
            Добавить поле
          </Button>
          {error && <Alert variant="danger" title={error} role="alert" />}
          {stale && (
            <Alert
              variant="warning"
              title="Настройки типа уже изменились"
              role="alert"
              description={
                <>
                  Загрузка актуальных настроек сбросит правки в этой форме.{" "}
                  <Button type="button" variant="ghost" onClick={reload}>
                    Загрузить актуальные настройки
                  </Button>
                </>
              }
            />
          )}
          <div className="editor-footer">
            <Button variant="secondary" type="button" onClick={back}>
              Отмена
            </Button>
            <Button type="submit" loading={saving} disabled={!changed || stale}>
              {definition ? "Сохранить изменения" : "Создать тип"}
            </Button>
          </div>
        </fieldset>
      </form>
    </>
  );
}
