export const fieldKinds = [
  { value: "text", label: "Текст" },
  { value: "integer", label: "Целое число" },
  { value: "number", label: "Число" },
  { value: "boolean", label: "Да / нет" },
  { value: "date", label: "Дата" },
  { value: "datetime", label: "Дата и время" },
  { value: "select", label: "Список вариантов" },
];

const transliteration = {
  а: "a",
  б: "b",
  в: "v",
  г: "g",
  д: "d",
  е: "e",
  ё: "yo",
  ж: "zh",
  з: "z",
  и: "i",
  й: "y",
  к: "k",
  л: "l",
  м: "m",
  н: "n",
  о: "o",
  п: "p",
  р: "r",
  с: "s",
  т: "t",
  у: "u",
  ф: "f",
  х: "kh",
  ц: "ts",
  ч: "ch",
  ш: "sh",
  щ: "shch",
  ъ: "",
  ы: "y",
  ь: "",
  э: "e",
  ю: "yu",
  я: "ya",
};

export function suggestedCode(label) {
  const words = label
    .trim()
    .toLowerCase()
    .replace(/[а-яё]/gu, (letter) => transliteration[letter])
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "");
  return (/^\d/.test(words) ? "n_" + words : words).slice(0, 64);
}

function namedItem(item, context, technicalKey = true) {
  const label = item.label.trim();
  if (!label) throw new Error("Укажите название " + context + ".");
  const code = (item.code ?? suggestedCode(label)).trim();
  if (!code || (technicalKey && !/^[a-z][a-z0-9_]{0,63}$/.test(code)))
    throw new Error("Проверьте код для «" + label + "».");
  return { label, code };
}

export function buildType(draft) {
  const { label: name, code } = namedItem(draft, "типа события");
  const fields = [],
    options = [];
  const keys = new Set();
  for (const field of draft.fields) {
    const { label, code: field_key } = namedItem(field, "поля " + (fields.length + 1));
    if (keys.has(field_key)) throw new Error("Ключ поля «" + field_key + "» повторяется.");
    keys.add(field_key);
    const item = {
      field_key,
      label,
      data_type: field.data_type,
      is_required: !!field.is_required,
      sort_order: fields.length,
    };
    if (["number", "integer"].includes(field.data_type) && field.unit_code?.trim())
      item.unit_code = field.unit_code.trim();
    fields.push(item);
    if (field.data_type !== "select") continue;
    if (!field.options?.length) throw new Error("Добавьте вариант для поля «" + label + "».");
    const codes = new Set();
    for (const choice of field.options) {
      const option = namedItem(choice, "варианта поля «" + label + "»", false);
      if (codes.has(option.code))
        throw new Error("В поле «" + label + "» повторяется код варианта «" + option.code + "».");
      options.push({ field_key, ...option, sort_order: codes.size });
      codes.add(option.code);
    }
  }
  return {
    code,
    name,
    ...(draft.description?.trim() ? { description: draft.description.trim() } : {}),
    fields,
    options,
  };
}

export function buildTypeEdit(draft, definition) {
  const added = buildType(draft);
  const existingKeys = new Set(definition.fields.map((f) => f.field_key));
  const lastOrder = definition.fields.reduce((last, field) => Math.max(last, field.sort_order), -1);
  for (const field of added.fields) {
    if (existingKeys.has(field.field_key))
      throw new Error("Ключ «" + field.field_key + "» уже занят в этом типе, включая архив.");
    field.sort_order = Math.min(2147483647, lastOrder + 1 + field.sort_order);
  }
  const update = { expected_updated_at: definition.updated_at };
  if (added.name !== definition.name) update.name = added.name;
  const description = draft.description.trim();
  if (description !== (definition.description ?? "")) update.description = description;
  if (added.fields.length) update.add_fields = added.fields;
  if (added.options.length) update.options = added.options;
  if (draft.archive.length) update.archive_fields = draft.archive;
  return update;
}
