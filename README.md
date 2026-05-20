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
docs/
  PROMPTS.md
  SEMANTIC_CACHE_PATCH.md
```

## 1. Подготовка .env

```bash
cp .env.example .env
```

Заполните минимум:

```env
N8N_ENCRYPTION_KEY=long-random-string
OPENAI_API_KEY=sk-...
SUPABASE_URL=https://YOUR_PROJECT.supabase.co
SUPABASE_SERVICE_ROLE_KEY=...
TELEGRAM_BOT_TOKEN=...
TELEGRAM_ADMIN_BOT_TOKEN=...
ADMIN_TELEGRAM_IDS=123456789,987654321
```

Для production Telegram Trigger нужен публичный HTTPS `WEBHOOK_URL`, например через reverse proxy, Cloudflare Tunnel или ngrok:

```env
N8N_HOST=n8n.example.com
N8N_PROTOCOL=https
WEBHOOK_URL=https://n8n.example.com/
```

## 2. Запуск n8n

```bash
docker-compose up -d
```

UI будет доступен на `http://localhost:5678` или на вашем публичном URL.

Проверка контейнера:

```bash
docker-compose ps
```

## 3. Supabase migrations

Откройте Supabase Dashboard -> SQL Editor и выполните файлы по порядку:

1. `supabase/migrations/001_init.sql`
2. `supabase/migrations/002_pgvector.sql`
3. `supabase/migrations/003_functions.sql`
4. `supabase/migrations/004_semantic_cache.sql`

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
https://n8n.example.com/webhook/admin-commands
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
https://n8n.example.com/webhook/knowledge-ingestion
```

Пример POST:

```bash
curl -X POST "$KNOWLEDGE_INGESTION_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d '{
    "text": "Текст документа базы знаний...",
    "metadata": { "source": "manual-test", "title": "Test KB" }
  }'
```

Для URL-документа:

```bash
curl -X POST "$KNOWLEDGE_INGESTION_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
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
7. Бот должен создать тикет и ответить `Создан тикет #...`.
8. Проверьте таблицу `qa_log` в Supabase.

## 8. Закрытие тикета

Webhook endpoint:

```text
POST /webhook/close-ticket
```

Пример:

```bash
curl -X POST "https://n8n.example.com/webhook/close-ticket" \
  -H "Content-Type: application/json" \
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
/reload
```

`/stats` показывает:

- открытые тикеты;
- закрытые тикеты;
- answered тикеты;
- всего вопросов;
- процент отвеченных;
- среднюю similarity.

`/tickets` показывает последние 10 открытых тикетов.

`/reload` вызывает `KNOWLEDGE_INGESTION_WEBHOOK_URL` и отправляет туда `KNOWLEDGE_SEED_TEXT`. Для больших seed-файлов лучше вызывать ingestion webhook напрямую из CI/script и передавать текст в body.

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
- Для production используйте HTTPS `WEBHOOK_URL`, иначе Telegram Trigger не сможет стабильно зарегистрировать webhook.

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
