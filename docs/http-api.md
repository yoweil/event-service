# HTTP API событий

Передавайте `Authorization: Bearer <API_TOKEN>`. API использует JSON, а файлы загружаются через `multipart/form-data` и скачиваются в исходном виде. Ошибки содержат поле `error`. Основные коды ошибок - `400` (формат запроса), `401` (токен), `404` (ресурс), `409` (конфликт) и `422` (ограничения данных).

## Маршруты

| Метод и путь | Запрос | Успешный ответ |
| --- | --- | --- |
| `GET /event-types` | `include_archived=true` для включения архивных типов | `200`, массив типов |
| `POST /event-types` | `code`, `name`, при необходимости `description`, `fields` и `options` | `201`, `id`, `code`, `name` |
| `GET /event-types/{id}` | `include_archived=true` для включения архивных полей и вариантов | `200`, тип с `updated_at`, полями и вариантами |
| `PATCH /event-types/{id}` | `expected_updated_at` и изменения `name`, `description`, `add_fields`, `options` или `archive_fields` | `200`, `id`, `code`, `name` |
| `GET /events` | Фильтры, сортировка и курсор | `200`, `items` и `next_cursor` |
| `POST /events` | Свойства карточки и `fields` | `201`, `id` и `revision`, адрес карточки в `Location` |
| `GET /events/{id}` | Идентификатор карточки | `200`, карточка со значениями полей и ревизией |
| `PUT /events/{id}` | Свойства карточки, `expected_revision` и изменённые `fields` | `200`, `id` и актуальная `revision` |
| `POST /events/{id}/attachments` | Одно поле `file` в `multipart/form-data` | `200`, метаданные и адрес скачивания в `Location` |
| `GET /events/{id}/attachments` | Идентификатор карточки | `200`, массив файлов с `sha256` и `results` |
| `GET /events/{id}/attachments/{attachment}` | Идентификаторы карточки и файла | `200`, оригинал с именем в `Content-Disposition`. `HEAD` отдаёт заголовки |
| `POST /events/{id}/attachments/{attachment}/results` | Числовой результат обработки или причина для проверки | `200`, сохранённый результат |

## Типы и карточки

- Определение поля содержит `field_key`, `label` и `data_type`. Для варианта списка передайте `field_key`, `code` и `label` в `options`. Форматы полей описаны в [схеме PostgreSQL](database-schema.md#3-event_type_fields).
- При изменении типа передайте точный `updated_at` из `GET` в `expected_updated_at`. `archive_fields` принимает массив ключей. При конфликте перечитайте тип после `409`. Для типа с готовыми карточками добавление обязательного поля даёт `422`.
- Для записи карточки обязательны `event_type_id`, `well_id`, `status` (`draft` или `ready`), `time_kind` (`instant` или `period`) и `started_at`. `ended_at` задаёт конец периода. Дата и время передаются в RFC 3339 с часовым поясом. `PUT` также требует `description` и актуальную `expected_revision`.
- Пример элемента `fields` - `{"field_key":"pressure","value_number":120.5}`. Передавайте одно свойство значения из `value_text`, `value_number`, `value_boolean`, `value_date`, `value_datetime` и `value_option`. Элемент только с `field_key` очищает значение. Пропущенные поля сохраняются. Для `ready` обязательные поля должны быть заполнены.

## Поиск

- `well_id` и `event_type_id` фильтруют по скважине и типу. `q` ищет по описанию и текстовым полям без учёта регистра. `from` и `to` задают период в RFC 3339.
- `field.<key>.<op>` фильтрует по дополнительному полю, например `field.pressure.gte=100`. Операторы - `eq`, `lt`, `lte`, `gt`, `gte`. Текст, список и логическое значение поддерживают `eq`.
- `sort` принимает `started_at` или `field.<key>` и префикс `-` для убывания. По умолчанию действует `-started_at`. Для фильтрации и сортировки по дополнительному полю укажите `event_type_id`.
- `limit` принимает от 1 до 100, по умолчанию 50. Передайте `next_cursor` в `cursor` с теми же фильтрами и сортировкой.

## Вложения

Лимит одного файла - 20 МиБ. Превышение даёт `413`, другой тип запроса на загрузку - `415`. Повтор с теми же именем и содержимым в одной карточке возвращает прежний ID.

## Уведомления

| Тип | Адрес и токен получателя | Дополнительные поля сообщения |
| --- | --- | --- |
| `attachment.added` | `ATTACHMENT_WEBHOOK_URL` и `ATTACHMENT_WEBHOOK_TOKEN` | `attachment_id`, `filename`, `sha256`, `download_path` |
| `event.created`, `event.updated` | `EVENT_WEBHOOK_URL` и `EVENT_WEBHOOK_TOKEN` | `event_type_id`, `revision`, `actor_kind`, `actor_id`, `changes` |

Каждый `POST` содержит `id`, `type`, `event_id` и `occurred_at`. Идентификаторы карточки, типа, файла и ревизия передаются строками. Элемент `changes` содержит `scope` (`base` или `field`), `key`, `old_value` и `new_value`. Значения передаются строками или `null`. Сохранение без изменений не создаёт уведомление.

Если задан токен получателя, сервис отправляет его как Bearer-токен. `Idempotency-Key` совпадает с UUID из `id`. Сохраните задание или результат с уникальным UUID и подтвердите `2xx`. При сбое сервис повторяет запрос с тем же UUID и телом. Ревизии одной карточки доставляются по порядку. Для скачивания файла добавьте `download_path` к адресу API и используйте `API_TOKEN`.

Для записи по `event.created` или `event.updated` передайте UUID в `source_notification_id` при `PUT /events/{id}` и номер этой ревизии числом в `expected_revision`. UUID должен относиться к начатой доставке для этой карточки и ревизии. Новое уведомление для такой записи подавляется.

## Результаты обработки вложения

Передайте `notification_id` из `attachment.added` и `field_key`. Для извлечённого числа укажите `value_number`, `sheet_name`, `cell_ref` и `unit_code`, если у поля есть единица измерения. При ошибке разбора передайте `issue`. Сервис проверяет принадлежность уведомления указанному файлу и карточке.

- `applied` - число записано в пустое поле. `applied_revision` указывает на ревизию этой записи
- `review` - результат требует проверки. `reason` содержит причину, например изменение карточки после загрузки, занятое поле или несовпадающую единицу
