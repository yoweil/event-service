import { Button, Empty, PageHeader, Table } from "@intetech/ui-kit";
import { useResource } from "./api.js";
import { Busy, Failure } from "./common.jsx";
import { fieldKinds } from "./type-definition.js";

const typeColumns = [
  { title: "Название", dataIndex: "name", render: (name, row) => <a href={"#/types/" + row.id}>{name}</a> },
  { title: "Код типа", dataIndex: "code" },
  { title: "Описание", dataIndex: "description", render: (value) => value || "—" },
];
const labels = Object.fromEntries(fieldKinds.map((kind) => [kind.value, kind.label]));
const fieldColumns = [
  {
    title: "Поле",
    dataIndex: "label",
    render: (label, row) => (
      <div className="subject">
        <strong>{label}</strong>
        <span>{row.field_key}</span>
      </div>
    ),
  },
  { title: "Тип данных", dataIndex: "data_type", render: (kind) => labels[kind] },
  { title: "Обязательное", dataIndex: "is_required", render: (required) => (required ? "Да" : "Нет") },
  {
    title: "Единица или варианты",
    dataIndex: "unit_code",
    render: (unit, row) => unit || row.options.map((o) => o.label).join(", ") || "—",
  },
];

export function TypeCatalog({ types }) {
  return (
    <>
      <PageHeader
        className="page-title"
        size="lg"
        bordered={false}
        title="Типы событий"
        onBack={() => {
          location.hash = "/";
        }}
        backLabel="В журнал"
        extra={
          <Button
            icon="plus"
            onClick={() => {
              location.hash = "/types/new";
            }}
          >
            Создать тип
          </Button>
        }
      />
      {types.length ? (
        <div className="surface table-scroll">
          <Table standard rowKey="id" columns={typeColumns} dataSource={types} aria-label="Типы событий" />
        </div>
      ) : (
        <Empty
          title="Пока нет типов событий"
          description="Создайте тип, чтобы настроить поля первой карточки."
        />
      )}
    </>
  );
}

export function TypeDetails({ id, api }) {
  const { data, error, retry } = useResource(api, "/event-types/" + id);
  if (error) return <Failure error={error} retry={retry} />;
  if (!data) return <Busy />;
  return (
    <>
      <PageHeader
        className="page-title"
        size="lg"
        bordered={false}
        title={data.name}
        subtitle={data.code}
        onBack={() => {
          location.hash = "/types";
        }}
        backLabel="К типам событий"
        extra={
          !data.is_archived && (
            <div className="actions">
              <Button
                variant="secondary"
                icon="pencil"
                onClick={() => {
                  location.hash = "/types/" + id + "/edit";
                }}
              >
                Изменить тип
              </Button>
              <Button
                icon="plus"
                onClick={() => {
                  location.hash = "/events/new?type=" + id;
                }}
              >
                Создать событие
              </Button>
            </div>
          )
        }
      />
      {data.description && <p className="type-description">{data.description}</p>}
      <h2 className="type-table-title">Дополнительные поля</h2>
      {data.fields.length ? (
        <div className="surface table-scroll">
          <Table
            standard
            columns={fieldColumns}
            rowKey="field_key"
            dataSource={data.fields}
            aria-label="Поля типа"
          />
        </div>
      ) : (
        <Empty
          title="Дополнительных полей нет"
          description="Для событий этого типа доступны общие поля карточки."
        />
      )}
    </>
  );
}
