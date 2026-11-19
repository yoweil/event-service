const numericKeys = new Set([
  "id",
  "event_type_id",
  "revision",
  "expected_revision",
  "value_number",
  "reviewed_value_number",
  "min_number",
  "max_number",
]);
const decimal = /^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$/;

export function decode(text) {
  return JSON.parse(text, (key, value, context) =>
    numericKeys.has(key) && typeof value === "number" ? context.source : value,
  );
}

export function encode(value) {
  return JSON.stringify(value, (key, item) => {
    if (!numericKeys.has(key) || typeof item !== "string") return item;
    if (!decimal.test(item)) throw new Error("Проверьте формат числа.");
    return JSON.rawJSON(item);
  });
}

export const valueColumns = {
  text: "value_text",
  number: "value_number",
  integer: "value_number",
  date: "value_date",
  datetime: "value_datetime",
  boolean: "value_boolean",
  select: "value_option",
};
export const statusName = (s) => (s === "ready" ? "Готово" : "Черновик");
export const showTime = (value) =>
  value
    ? new Intl.DateTimeFormat("ru-RU", { dateStyle: "short", timeStyle: "short" }).format(new Date(value))
    : "—";

function localTime(value) {
  if (!value) return "";
  const date = new Date(value);
  return new Date(date.getTime() - date.getTimezoneOffset() * 60000)
    .toISOString()
    .slice(0, 23)
    .replace(/\.000$/, "");
}

export function initialForm(card, type = "") {
  const values = Object.create(null);
  for (const row of card?.fields ?? []) {
    const key = Object.keys(row).find((k) => k.startsWith("value_"));
    if (key) values[row.field_key] = key === "value_datetime" ? localTime(row[key]) : String(row[key]);
  }
  return {
    event_type_id: card?.event_type_id ?? type,
    well_id: card?.well_id ?? "",
    status: card?.status ?? "draft",
    time_kind: card?.time_kind ?? "instant",
    started_at: localTime(card?.started_at ?? new Date()),
    ended_at: localTime(card?.ended_at),
    description: card?.description ?? "",
    values,
  };
}

function wireTime(local, original) {
  if (!local) return null;
  return original && local === localTime(original) ? original : new Date(local).toISOString();
}
function epochMicros(value) {
  const fraction = value.match(/\.\d{3}(\d{1,3})/)?.[1] ?? "";
  return BigInt(Date.parse(value)) * 1000n + BigInt(fraction.padEnd(3, "0"));
}

export function payload(form, fields, card) {
  if (!form.event_type_id || !form.well_id.trim() || !form.started_at)
    throw new Error("Укажите тип, скважину и начало события.");
  const start = wireTime(form.started_at, card?.started_at);
  const end = form.time_kind === "period" ? wireTime(form.ended_at, card?.ended_at) : null;
  if (end && epochMicros(end) <= epochMicros(start))
    throw new Error("Конец периода должен быть позже начала.");
  const previous = card ? initialForm(card).values : Object.create(null);
  const changes = [];
  for (const f of fields) {
    if (f.is_archived) continue;
    const key = f.field_key;
    const value = Object.hasOwn(form.values, key) ? form.values[key] : "";
    if (f.is_required && form.status === "ready" && value.trim() === "")
      throw new Error("Заполните поле «" + f.label + "».");
    if (value === (previous[key] ?? "")) continue;
    const edit = { field_key: key };
    if (value !== "") {
      let wire = value;
      if (["number", "integer"].includes(f.data_type)) {
        wire = value.replace(",", ".");
        if (!decimal.test(wire)) throw new Error("Проверьте число в поле «" + f.label + "».");
      }
      if (f.data_type === "boolean") wire = value === "true";
      if (f.data_type === "datetime") wire = wireTime(value);
      edit[valueColumns[f.data_type]] = wire;
    }
    changes.push(edit);
  }
  return {
    well_id: form.well_id,
    event_type_id: form.event_type_id,
    status: form.status,
    time_kind: form.time_kind,
    started_at: start,
    ended_at: end,
    description: form.description,
    fields: changes,
    ...(card ? { expected_revision: card.revision } : {}),
  };
}

export const emptyFilters = {
  q: "",
  well: "",
  type: "",
  from: "",
  to: "",
  sort: "-started_at",
  conditions: [],
};

function midnight(day, offset) {
  const d = new Date(day + "T00:00");
  d.setDate(d.getDate() + offset);
  return d.toISOString();
}
export function queryFor(filters) {
  const q = new URLSearchParams();
  if (filters.from && filters.to && filters.from > filters.to) throw new Error("Проверьте границы периода.");
  for (const [key, value] of Object.entries({
    q: filters.q?.trim(),
    well_id: filters.well?.trim(),
    event_type_id: filters.type,
    from: filters.from && midnight(filters.from, 0),
    to: filters.to && midnight(filters.to, 1),
    sort: filters.sort,
  })) {
    if (value) q.set(key, value);
  }
  for (const c of filters.conditions) {
    if (!c.key || c.value === "") throw new Error("Выберите поле и значение для фильтра.");
    const key = "field." + c.key + "." + c.op;
    if (q.has(key)) throw new Error("Для одного поля выберите разные условия.");
    q.set(key, c.kind === "datetime" ? wireTime(c.value) : c.value);
  }
  return q;
}
