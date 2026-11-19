import { useEffect, useState } from "react";
import { Alert, Button, Empty, Icon, IconButton, Input, PageHeader, Table } from "@intetech/ui-kit";
import { useResource } from "./api.js";
import { Choice, ExtraInput, StateBadge, Busy, Failure, option, allOption } from "./common.jsx";
import { emptyFilters, queryFor, showTime } from "./model.js";

const timeSort = [option("-started_at", "Сначала новые"), option("started_at", "Сначала ранние")];
const operators = [
  option("eq", "Равно"),
  option("gt", "Больше"),
  option("gte", "Не меньше"),
  option("lt", "Меньше"),
  option("lte", "Не больше"),
];
const columns = [
  {
    title: "Событие",
    width: "41%",
    dataIndex: "event_type_name",
    render: (v, row) => (
      <div className="subject">
        <a href={"#/events/" + row.id}>{v}</a>
        <span className="truncate">{row.description || "№ " + row.id}</span>
      </div>
    ),
  },
  { title: "Скважина", dataIndex: "well_id", render: (v) => <span className="well">{v}</span> },
  {
    title: "Дата и время",
    dataIndex: "started_at",
    render: (v, row) => (
      <div className="subject">
        <span>{showTime(v)}</span>
        {row.time_kind === "period" && (
          <span>{row.ended_at ? "до " + showTime(row.ended_at) : "Открытый период"}</span>
        )}
      </div>
    ),
  },
  { title: "Статус", width: "15%", dataIndex: "status", render: (s) => <StateBadge status={s} /> },
];

function Results({ api, query, filtered, reset }) {
  const [cursor, setCursor] = useState("");
  const [attempt, setAttempt] = useState(0);
  const [state, setState] = useState({ items: [], busy: true });
  useEffect(() => {
    const ctl = new AbortController();
    const params = new URLSearchParams(query);
    if (cursor) params.set("cursor", cursor);
    setState((s) => ({ ...s, busy: true, error: null }));
    api("/events?" + params, { signal: ctl.signal })
      .then((page) => {
        if (!ctl.signal.aborted)
          setState((s) => ({
            items: cursor ? [...s.items, ...page.items] : page.items,
            next: page.next_cursor,
            busy: false,
          }));
      })
      .catch((error) => {
        if (!ctl.signal.aborted) setState((s) => ({ ...s, error, busy: false }));
      });
    return () => ctl.abort();
  }, [api, query, cursor, attempt]);
  return (
    <section className="surface results" aria-label="Найденные события" aria-busy={state.busy}>
      {state.error && <Failure error={state.error} retry={() => setAttempt((n) => n + 1)} />}
      {state.busy && !state.items.length ? (
        <Busy />
      ) : state.items.length ? (
        <div className="table-scroll">
          <Table
            standard
            rowKey="id"
            aria-label="События"
            columns={columns}
            dataSource={state.items}
            onRow={(row) => ({
              className: "event-row",
              onClick: (e) => {
                if (!e.target.closest("a")) location.hash = "/events/" + row.id;
              },
            })}
          />
        </div>
      ) : (
        !state.error && (
          <Empty
            icon="list-filter"
            title={filtered ? "События не найдены" : "В журнале пока нет событий"}
            description={
              filtered ? "Попробуйте изменить условия поиска." : "Создайте первое событие для скважины."
            }
          >
            {filtered && (
              <Button variant="secondary" onClick={reset}>
                Сбросить фильтры
              </Button>
            )}
          </Empty>
        )
      )}
      {!!state.items.length && (
        <footer className="list-footer">
          <span>Загружено событий: {state.items.length}</span>
          {state.next && !state.error && (
            <Button variant="secondary" loading={state.busy} onClick={() => setCursor(state.next)}>
              Показать ещё
            </Button>
          )}
        </footer>
      )}
    </section>
  );
}

export function Registry({ api, types, filters, apply }) {
  const [draft, setDraft] = useState(filters);
  const [error, setError] = useState("");
  const [mobileFilters, setMobileFilters] = useState(false);
  const definition = useResource(api, draft.type ? "/event-types/" + draft.type : null);
  const fields = definition.data?.fields ?? [];
  const set = (key, value) => setDraft((s) => ({ ...s, [key]: value }));
  const query = queryFor(filters).toString();
  function reset() {
    setDraft(emptyFilters);
    apply(emptyFilters);
    setError("");
  }
  function submit(e) {
    e.preventDefault();
    try {
      queryFor(draft);
      apply(draft);
      setError("");
      setMobileFilters(false);
    } catch (err) {
      setError(err.message);
    }
  }
  function condition(index, updates) {
    setDraft((s) => ({
      ...s,
      conditions: s.conditions.map((c, i) => (i === index ? { ...c, ...updates } : c)),
    }));
  }
  return (
    <>
      <PageHeader
        className="page-title"
        size="lg"
        bordered={false}
        title="Журнал событий"
        extra={
          <div className="actions">
            <Button
              variant="secondary"
              onClick={() => {
                location.hash = "/types";
              }}
            >
              Типы событий
            </Button>
            <Button
              icon="plus"
              disabled={!types.length}
              onClick={() => {
                location.hash = "/events/new";
              }}
            >
              Новое событие
            </Button>
          </div>
        }
      />
      {!types.length && (
        <Alert
          variant="info"
          title="Для первого события нужен тип"
          description={<a href="#/types/new">Создать тип события</a>}
        />
      )}
      <div className="workspace">
        <Button
          className="mobile-filter-toggle"
          variant="secondary"
          icon="sliders-horizontal"
          aria-expanded={mobileFilters}
          onClick={() => setMobileFilters(!mobileFilters)}
        >
          Фильтры
        </Button>
        <aside className={"surface filters" + (mobileFilters ? " expanded" : "")}>
          <h2>
            <Icon name="sliders-horizontal" />
            Фильтры
          </h2>
          <form id="event-filters" onSubmit={submit}>
            <Input
              block
              label="Скважина"
              placeholder="Идентификатор скважины"
              value={draft.well}
              onChange={(e) => set("well", e.target.value)}
            />
            <Choice
              label="Тип события"
              value={draft.type}
              options={[allOption, ...types.map((t) => option(t.id, t.name))]}
              onChange={(type) =>
                setDraft((s) => ({
                  ...s,
                  type,
                  conditions: [],
                  sort: timeSort.some((o) => o.value === s.sort) ? s.sort : "-started_at",
                }))
              }
            />
            <div className="range">
              <Input
                block
                label="Период с"
                type="date"
                value={draft.from}
                onChange={(e) => set("from", e.target.value)}
              />
              <Input
                block
                label="Период по"
                type="date"
                value={draft.to}
                onChange={(e) => set("to", e.target.value)}
              />
            </div>
            {definition.error && <Failure error={definition.error} retry={definition.retry} />}
            {draft.conditions.map((c, i) => {
              const f = fields.find((f) => f.field_key === c.key);
              return (
                <div className="condition" key={i}>
                  <div className="condition-head">
                    <strong>Условие {i + 1}</strong>
                    <IconButton
                      name="x"
                      aria-label={"Удалить условие " + (i + 1)}
                      onClick={() =>
                        set(
                          "conditions",
                          draft.conditions.filter((_, idx) => idx !== i),
                        )
                      }
                    />
                  </div>
                  <Choice
                    label="Поле"
                    value={c.key}
                    options={fields.map((f) => option(f.field_key, f.label))}
                    onChange={(key) =>
                      condition(i, {
                        key,
                        kind: fields.find((f) => f.field_key === key).data_type,
                        op: "eq",
                        value: "",
                      })
                    }
                  />
                  {f && (
                    <>
                      <Choice
                        label="Сравнение"
                        value={c.op}
                        options={
                          ["text", "select", "boolean"].includes(f.data_type)
                            ? operators.slice(0, 1)
                            : operators
                        }
                        onChange={(op) => condition(i, { op })}
                      />
                      <ExtraInput
                        field={f}
                        filter
                        label="Значение"
                        value={c.value}
                        onChange={(value) => condition(i, { value })}
                      />
                    </>
                  )}
                </div>
              );
            })}
            {fields.length > 0 && (
              <Button
                variant="ghost"
                icon="list-plus"
                onClick={() =>
                  set("conditions", [
                    ...draft.conditions,
                    { key: fields[0].field_key, kind: fields[0].data_type, op: "eq", value: "" },
                  ])
                }
              >
                Условие по полю
              </Button>
            )}
            <div className="filter-actions">
              <Button type="submit">Применить</Button>
              <Button variant="ghost" onClick={reset}>
                Сбросить
              </Button>
            </div>
          </form>
        </aside>
        <div className="registry-main">
          <div className="searchbar">
            <Input
              block
              form="event-filters"
              variant="search"
              aria-label="Поиск по описанию и полям"
              placeholder="Поиск по описанию и полям"
              value={draft.q}
              onChange={(e) => set("q", e.target.value)}
            />
            <Button form="event-filters" type="submit" variant="secondary">
              Найти
            </Button>
          </div>
          <div className="table-tools">
            <strong>События</strong>
            <Choice
              label="Сортировка"
              value={draft.sort}
              options={[
                ...timeSort,
                ...fields.flatMap((f) => [
                  option("field." + f.field_key, f.label + " ↑"),
                  option("-field." + f.field_key, f.label + " ↓"),
                ]),
              ]}
              onChange={(sort) => {
                const next = { ...draft, sort };
                setDraft(next);
                try {
                  queryFor(next);
                  apply(next);
                  setError("");
                } catch (err) {
                  setError(err.message);
                }
              }}
            />
          </div>
          {error && <Failure error={new Error(error)} />}
          <Results
            key={query}
            api={api}
            query={query}
            filtered={!!(filters.well || filters.type || filters.q || filters.from || filters.to)}
            reset={reset}
          />
        </div>
      </div>
    </>
  );
}
