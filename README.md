# Сервис событий

Журнал событий по скважинам с настраиваемыми типами и полями, поиском и вложениями. Go API хранит данные в PostgreSQL, отправляет уведомления и принимает результаты обработки файлов.

## Запуск

Задайте `DATABASE_URL`. Для раздельного учёта авторов укажите в `API_TOKENS_FILE` путь к локальному JSON-файлу за пределами репозитория. Для каждого оператора и каждой программы создайте свой токен командой `openssl rand -hex 32` и подставьте его в файл

```json
[
  {"kind": "user", "id": "operator-1", "token": "<operator-token>"},
  {"kind": "service", "id": "excel-processor", "token": "<processor-token>"}
]
```

Сервис читает файл при запуске. Для локального запуска с одним общим токеном можно задать только `DATABASE_URL` и `API_TOKEN`. При заданном `API_TOKENS_FILE` действуют только токены из файла.

```bash
psql -v ON_ERROR_STOP=1 "$DATABASE_URL" -f db/schema.sql -f db/create_event_type.sql -f db/save_event.sql
go run ./cmd/event-service
```

При обновлении базы примените недостающие [миграции](db/migrations/) и повторно выполните `db/create_event_type.sql` и `db/save_event.sql`.

Для сборки интерфейса поместите `intetech-ui-kit-1.8.0.tgz` в `web/vendor/` и выполните `(cd web && npm ci && npm run build)`. Откройте [журнал](http://127.0.0.1:8080/ui/) и введите свой токен.

## Документация

- [Модель данных](docs/data-model.md)
- [Схема PostgreSQL](docs/database-schema.md)
- [HTTP API, уведомления и результаты обработки файлов](docs/http-api.md)
