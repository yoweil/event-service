# HTTP API событий

Все маршруты принимают заголовок `Authorization: Bearer <API_TOKEN>`.
Для первого локального клиента сервер записывает в журнал автора вида
`service` с идентификатором `local-client`. Его можно задать через `API_ACTOR_ID`

| Метод и путь | Запрос | Результат |
| --- | --- | --- |
| `GET /event-types` | Список типов для выбора | `200`, массив с идентификатором, кодом, названием, описанием и признаком архива |
| `POST /event-types` | Код, название, определения полей и варианты выбора | `201`, объект с `id`, `code` и `name` |
| `GET /event-types/{id}` | Идентификатор типа в пути | `200`, тип с массивом `fields`. У каждого поля есть массив `options` |
| `GET /events` | Фильтры, сортировка и курсор страницы | `200`, объект с массивом `items` и `next_cursor` |
| `POST /events` | Базовые свойства карточки и дополнительные поля | `201`, объект с `id` и `revision`, путь к карточке в `Location` |
| `PUT /events/{id}` | Базовые свойства, `expected_revision` и изменённые дополнительные поля | `200`, объект с `id` и актуальной `revision` |
| `GET /events/{id}` | Идентификатор карточки в пути | `200`, карточка с ревизией, автором и массивом текущих значений `fields` |

## От создания типа до чтения карточки

Для команд ниже нужны `curl`, `jq` и токен запущенного сервера в `API_TOKEN`.
Пример создаёт новый тип с уникальным в каталоге кодом `research`.

```bash
base=http://127.0.0.1:8080
auth="Authorization: Bearer $API_TOKEN"
type_id=$(curl -fsS "$base/event-types" -H "$auth" --json '{
  "code":"research","name":"Исследование",
  "fields":[{"field_key":"pressure","label":"Давление","data_type":"number",
             "is_required":true,"unit_code":"bar","min_number":0}]
}' | jq -er .id)

curl -fsS "$base/event-types" -H "$auth" | jq .
curl -fsS "$base/event-types/$type_id" -H "$auth" | jq '.fields'

card=$(curl -fsS "$base/events" -H "$auth" --json "{
  \"event_type_id\":$type_id,\"well_id\":\"well-5\",\"status\":\"draft\",
  \"time_kind\":\"instant\",\"started_at\":\"2026-01-12T08:00:00Z\"
}")
id=$(jq -er .id <<< "$card")
revision=$(jq -er .revision <<< "$card")

curl -fsS -X PUT "$base/events/$id" -H "$auth" --json "{
  \"event_type_id\":$type_id,\"well_id\":\"well-5\",\"status\":\"ready\",
  \"time_kind\":\"instant\",\"started_at\":\"2026-01-12T08:00:00Z\",\"description\":\"\",
  \"expected_revision\":$revision,\"fields\":[{\"field_key\":\"pressure\",\"value_number\":120.5}]
}"
curl -fsS "$base/events/$id" -H "$auth" | jq .
```
