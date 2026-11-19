import { Alert, Badge, Button, FormField, Input, Select, Spinner } from "@intetech/ui-kit";
import { statusName } from "./model.js";

export const option = (value, label) => ({ value, label });
export const allOption = option("", "Все типы");
export const statuses = [option("draft", "Черновик"), option("ready", "Готово")];
export const kinds = [option("instant", "Момент"), option("period", "Период")];
export function StateBadge({ status }) {
  return (
    <Badge dot variant={status === "ready" ? "success" : "default"}>
      {statusName(status)}
    </Badge>
  );
}
export function Choice({ label, helper, required, ...props }) {
  return (
    <FormField label={label} helper={helper} required={required}>
      <Select block {...props} />
    </FormField>
  );
}
export function Busy() {
  return (
    <div className="feedback" role="status">
      <Spinner size="sm" tip="Загрузка" /> Загрузка…
    </div>
  );
}
export function Failure({ error, retry }) {
  return (
    <Alert variant="danger" title={error.message} role="alert">
      {retry && (
        <Button variant="ghost" onClick={retry}>
          Повторить
        </Button>
      )}
    </Alert>
  );
}
export function ExtraInput({ field, value, onChange, label, required, filter = false }) {
  const shared = {
    label: label ?? field.label,
    value,
    onChange,
    required,
    helper: filter ? undefined : field.description,
  };
  if (field.data_type === "boolean" || field.data_type === "select") {
    const choices =
      field.data_type === "boolean"
        ? [option("true", "Да"), option("false", "Нет")]
        : field.options
            .filter((o) => !o.is_archived || o.code === value)
            .map((o) => option(o.code, o.label + (o.is_archived ? " (архив)" : "")));
    return <Choice {...shared} options={[option("", "Не задано"), ...choices]} />;
  }
  const numeric = ["integer", "number"].includes(field.data_type);
  const type = { date: "date", datetime: "datetime-local" }[field.data_type] ?? "text";
  const bounds = numeric
    ? [
        field.min_number != null && "от " + field.min_number,
        field.max_number != null && "до " + field.max_number,
      ]
        .filter(Boolean)
        .join(" ")
    : "";
  return (
    <Input
      {...shared}
      block
      type={type}
      step={type === "datetime-local" ? "any" : undefined}
      inputMode={numeric ? "decimal" : undefined}
      maxLength={field.max_length ?? undefined}
      label={(label ?? field.label) + (field.unit_code ? " (" + field.unit_code + ")" : "")}
      helper={!filter && ([field.description, bounds].filter(Boolean).join(" · ") || undefined)}
      onChange={(e) => onChange(e.target.value)}
    />
  );
}
