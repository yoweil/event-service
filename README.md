# Сервис событий

Журнал событий по скважинам с настраиваемыми типами и полями, поиском и вложениями. Go API хранит данные в PostgreSQL, отправляет уведомления и принимает результаты обработки файлов.

## Запуск

требуемые env переменные:
`DATABASE_URL`,
`API_TOKEN`

```bash
psql -v ON_ERROR_STOP=1 "$DATABASE_URL" -f db/schema.sql -f db/create_event_type.sql -f db/save_event.sql
go run ./cmd/event-service
```

При обновлении базы примените недостающие [миграции](db/migrations/) и повторно выполните `db/create_event_type.sql` и `db/save_event.sql`.

Для сборки интерфейса поместите `intetech-ui-kit-1.8.0.tgz` в `web/vendor/` и выполните `(cd web && npm ci && npm run build)`. Откройте [журнал](http://127.0.0.1:8080/ui/) и введите `API_TOKEN`

## Документация

- [Модель данных](docs/data-model.md)
- [Схема PostgreSQL](docs/database-schema.md)
- [HTTP API, уведомления и результаты обработки файлов](docs/http-api.md)
