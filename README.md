# Telegram support bot on n8n, Supabase pgvector and OpenAI

Проект содержит готовый каркас саппорт-бота:

- Telegram принимает вопрос пользователя.
- n8n получает embedding через OpenAI `text-embedding-3-small`.
- Supabase RPC `match_documents` ищет релевантные чанки через pgvector.
- Если найден контекст, `gpt-4o-mini` отвечает строго по базе знаний.
- Повторяющиеся по смыслу вопросы могут отвечаться из semantic cache без повторного вызова LLM.
- Если контекст не найден, создается тикет.
- `qa_log` хранит similarity и факт ответа для настройки порога.

## Структура

```text
docker-compose.yml
nginx_bot_swagadayz.conf
.env.example
n8n-workflows/
  telegram_question.json
  knowledge_ingestion.json
  ticket_close.json
  admin_commands.json
supabase/migrations/
  001_init.sql
  002_pgvector.sql
  003_functions.sql
  004_semantic_cache.sql
  005_rate_limits.sql
  006_feedback.sql
docs/
  PROMPTS.md
scripts/
  backup.sh
  diagnose.sh
```

## 1. Подготовка .env

```bash
cp .env.example .env
```

Заполните минимум:

```env
N8N_ENCRYPTION_KEY=long-random-string
N8N_BASIC_AUTH_ACTIVE=true
N8N_BASIC_AUTH_USER=admin
N8N_BASIC_AUTH_PASSWORD=...
OPENAI_API_KEY=sk-...
OPENAI_BASE_URL=https://aitunnel.ru/v1
SUPABASE_URL=https://YOUR_PROJECT.supabase.co
SUPABASE_SERVICE_ROLE_KEY=...
TELEGRAM_BOT_TOKEN=...
TELEGRAM_ADMIN_BOT_TOKEN=...
TG_WEBHOOK_SECRET=...
TG_ADMIN_WEBHOOK_SECRET=...
INTERNAL_WEBHOOK_SECRET=...
ADMIN_TELEGRAM_IDS=123456789,987654321
```

Для production используйте два HTTPS-домена: один для UI n8n, второй для Telegram/webhook traffic. В текущем деплое UI находится на `https://n8n.swagadayz.ru`, webhook endpoint — на `https://bot.swagadayz.ru`:

```env
N8N_HOST=n8n.swagadayz.ru
N8N_PROTOCOL=https
WEBHOOK_URL=https://bot.swagadayz.ru/
```

Без `N8N_BASIC_AUTH_ACTIVE=true` (или IP whitelist на Nginx) публиковать n8n UI в интернет нельзя.

## 2. Запуск n8n

```bash
docker-compose up -d
```

UI будет доступен на `http://localhost:5678` или на вашем публичном URL.

Проверка контейнера:

```bash
docker-compose ps
```

Для VPS с Nginx используйте [nginx_bot_swagadayz.conf](nginx_bot_swagadayz.conf) как рекомендуемый конфиг для `bot.swagadayz.ru`. Он проксирует Telegram webhooks на `127.0.0.1:5678` и выставляет таймауты, достаточные для n8n.

## 3. Supabase migrations

Откройте Supabase Dashboard -> SQL Editor и выполните файлы по порядку:

1. `supabase/migrations/001_init.sql`
2. `supabase/migrations/002_pgvector.sql`
3. `supabase/migrations/003_functions.sql`
4. `supabase/migrations/004_semantic_cache.sql`
5. `supabase/migrations/005_rate_limits.sql`
6. `supabase/migrations/006_feedback.sql`

`001_init.sql` идемпотентно включает `vector`, потому что таблица `documents` использует тип `vector(1536)`. `002_pgvector.sql` повторно вызывает `CREATE EXTENSION IF NOT EXISTS vector` и создает IVFFlat индекс.

`004_semantic_cache.sql` добавляет таблицу `cache_answers` и RPC для кеширования готовых ответов. Если миграция еще не применена, основной workflow продолжит работать по обычному RAG-пути, но кеш будет отключен.

После загрузки значимого объема документов можно повторно выполнить:

```sql
analyze public.documents;
```

## 4. n8n credentials

Основной workflow отправляет сообщения через Telegram Bot API по `TELEGRAM_BOT_TOKEN`.

Для админ-команд используйте отдельного Telegram-бота и заполните `TELEGRAM_ADMIN_BOT_TOKEN`. После активации `04 Telegram Admin Commands` установите webhook второго бота на:

```text
https://bot.swagadayz.ru/webhook/admin-commands
```

### Setting Telegram webhooks

```bash
curl "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setWebhook?url=${WEBHOOK_URL}webhook/telegram-question&secret_token=${TG_WEBHOOK_SECRET}"
curl "https://api.telegram.org/bot${TELEGRAM_ADMIN_BOT_TOKEN}/setWebhook?url=${WEBHOOK_URL}webhook/admin-commands&secret_token=${TG_ADMIN_WEBHOOK_SECRET}"
```

Для production лучше добавить `max_connections=10`, чтобы Telegram мог параллельно доставлять несколько updates:

```bash
curl "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setWebhook?url=${WEBHOOK_URL}webhook/telegram-question&secret_token=${TG_WEBHOOK_SECRET}&max_connections=10"
curl "https://api.telegram.org/bot${TELEGRAM_ADMIN_BOT_TOKEN}/setWebhook?url=${WEBHOOK_URL}webhook/admin-commands&secret_token=${TG_ADMIN_WEBHOOK_SECRET}&max_connections=10"
```

Workflow используют HTTP Request для OpenAI и Supabase, поэтому отдельные credentials для них не нужны: ключи читаются из env-переменных контейнера.

## 5. Import workflows

В UI n8n импортируйте все файлы из `n8n-workflows/`:

1. `telegram_question.json`
2. `knowledge_ingestion.json`
3. `ticket_close.json`
4. `admin_commands.json`

После импорта активируйте workflow:

- `01 Telegram Support RAG`
- `02 Knowledge Ingestion`
- `03 Ticket Close Webhook`
- `04 Telegram Admin Commands` только после заполнения `TELEGRAM_ADMIN_BOT_TOKEN` и настройки webhook второго бота

## 6. Загрузка базы знаний

### Через webhook

Production URL будет вида:

```text
https://bot.swagadayz.ru/webhook/knowledge-ingestion
```

Пример POST:

```bash
curl -X POST "$KNOWLEDGE_INGESTION_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -H "X-Internal-Token: ${INTERNAL_WEBHOOK_SECRET}" \
  -d '{
    "text": "Текст документа базы знаний...",
    "metadata": { "source": "manual-test", "title": "Test KB" }
  }'
```

Для URL-документа:

```bash
curl -X POST "$KNOWLEDGE_INGESTION_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -H "X-Internal-Token: ${INTERNAL_WEBHOOK_SECRET}" \
  -d '{
    "url": "https://example.com/help/article",
    "metadata": { "source": "example-help" }
  }'
```

Workflow режет текст примерно на чанки по 600 токенов с overlap 100 токенов. В n8n нет токенизатора OpenAI без кастомного сервиса, поэтому используется приближение по словам. Для production этого достаточно как стартовая настройка, но качество чанкинга стоит проверить на реальных статьях.

### Через manual run

Заполните в `.env`:

```env
KNOWLEDGE_SEED_TEXT=Текст тестового документа...
```

Перезапустите n8n, чтобы env обновились:

```bash
docker-compose restart n8n
```

Запустите `02 Knowledge Ingestion` вручную.

## 7. Основной сценарий проверки

1. Выполните миграции в Supabase.
2. Импортируйте и активируйте workflow.
3. Загрузите тестовый документ через `02 Knowledge Ingestion`.
4. Напишите боту вопрос по документу.
5. Бот должен ответить через `gpt-4o-mini` на основе найденных чанков.
6. Напишите вопрос не по теме.
7. Бот должен предложить передать вопрос поддержке через inline-кнопки `Да/Нет`; после `Да` создается тикет.
8. Проверьте таблицу `qa_log` в Supabase.

## 8. Закрытие тикета

Webhook endpoint:

```text
POST /webhook/close-ticket
```

Пример:

```bash
curl -X POST "https://bot.swagadayz.ru/webhook/close-ticket" \
  -H "Content-Type: application/json" \
  -H "X-Internal-Token: ${INTERNAL_WEBHOOK_SECRET}" \
  -d '{
    "ticket_id": 1,
    "notify": true,
    "message": "Ваш вопрос решен поддержкой. Тикет закрыт."
  }'
```

Workflow обновит:

```sql
status = 'closed', closed_at = now()
```

Если `notify=true`, пользователю отправится Telegram-уведомление.

## 9. Admin commands

Доступ ограничен `ADMIN_TELEGRAM_IDS`. Админ-команды используют отдельный бот из `TELEGRAM_ADMIN_BOT_TOKEN`, чтобы не конфликтовать с webhook основного саппорт-бота.

Команды:

```text
/stats
/tickets
/reply <ticket_id> <текст ответа>
/reload
```

`/stats` показывает:

- открытые тикеты;
- закрытые тикеты;
- answered тикеты;
- всего вопросов;
- процент отвеченных;
- среднюю similarity.

`/tickets` показывает последние 10 открытых тикетов и готовую подсказку для `/reply`.

`/reply` отправляет ответ пользователю через основного Telegram-бота и переводит тикет в `answered`.

`/reload` сначала очищает semantic cache через `purge_cache`, затем вызывает `KNOWLEDGE_INGESTION_WEBHOOK_URL` и отправляет туда `KNOWLEDGE_SEED_TEXT`. Для больших seed-файлов лучше вызывать ingestion webhook напрямую из CI/script и передавать текст в body.

Для `/reload` workflow автоматически добавляет `X-Internal-Token` в запрос к webhook загрузки знаний.

## 10. Порог similarity

По умолчанию в `telegram_question.json` используется:

```json
"match_threshold": 0.30,
"match_count": 3
```

Настройка:

- если бот часто создает тикеты при наличии ответа, снижайте threshold до `0.70`;
- если бот отвечает по нерелевантному контексту, повышайте threshold до `0.80`;
- смотрите `qa_log.similarity` и реальные диалоги.

## 11. Security notes

- `SUPABASE_SERVICE_ROLE_KEY` должен быть только в self-hosted n8n, не в браузере и не в клиентском коде.
- Миграции включают RLS на таблицах без публичных policies. Workflow работают через service role key, который обходит RLS.
- Не включайте публичный доступ к n8n без auth/reverse proxy.
- Для production используйте HTTPS `WEBHOOK_URL`, иначе Telegram не сможет стабильно доставлять webhook.
- Для Telegram webhooks лучше использовать отдельный короткий домен, например `bot.swagadayz.ru`, а n8n UI держать на `n8n.swagadayz.ru`.
- Все публичные webhook-и проверяют секреты: `TG_WEBHOOK_SECRET`, `TG_ADMIN_WEBHOOK_SECRET`, `INTERNAL_WEBHOOK_SECRET`.
- Вопросы пользователя ограничены 1000 символами, и включен rate limit (`15` запросов в `60` секунд на `user_id`).

## 12. Backups

В репозитории есть [scripts/backup.sh](scripts/backup.sh) для `pg_dump` Supabase и ротации бэкапов (хранит 14 дней).

Пример cron на VPS (каждую ночь в 03:30):

```bash
30 3 * * * BACKUP_DIR=/var/backups/swaga-bot SUPABASE_DB_URL='postgresql://...' /opt/allaibot_v2/scripts/backup.sh >> /var/log/swaga-backup.log 2>&1
```

## 13. Diagnostics

На VPS есть диагностический скрипт [scripts/diagnose.sh](scripts/diagnose.sh). Запускать из директории проекта:

```bash
cd /opt/allaibot_v2
./scripts/diagnose.sh
```

Он проверяет состояние Docker-контейнера, последние логи n8n, `getWebhookInfo` для основного и админ-бота, локальный webhook endpoint и `/healthz`.

## Final checklist

- [ ] `docker-compose up -d` запускает n8n на `:5678`.
- [ ] Все 4 workflow импортированы без ошибок.
- [ ] `TELEGRAM_BOT_TOKEN` и, при необходимости, `TELEGRAM_ADMIN_BOT_TOKEN` заполнены.
- [ ] Supabase migrations выполнены по порядку.
- [ ] `documents` содержит embeddings размерности 1536.
- [ ] Вопрос по документу получает ответ.
- [ ] Вопрос вне базы создает тикет.
- [ ] `qa_log` пишет `similarity` и `was_answered`.
- [ ] `/stats` доступен админу.
- [ ] `/reply` отправляет ответ пользователю и меняет статус тикета на `answered`.
- [ ] Telegram webhooks смотрят на production-домен `bot.swagadayz.ru`.
- [ ] Telegram webhooks установлены с `secret_token`.
- [ ] `X-Internal-Token` используется для `/webhook/knowledge-ingestion` и `/webhook/close-ticket`.
- [ ] Rate limiting работает: при флуде бот отвечает "Слишком много запросов, подождите минуту".
