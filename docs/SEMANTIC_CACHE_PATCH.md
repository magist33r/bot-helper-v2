# Patch: Semantic Cache для telegram_question workflow

## Что добавляется

Между нодой **OpenAI Embeddings** и **Supabase RPC - match_documents** вставляется проверка кеша. Если в `cache_answers` есть запись с similarity ≥ 0.92 — пропускаем поиск в базе знаний и LLM, отдаём готовый ответ напрямую.

Если кеша нет — обычный путь, и **в конце** (после успешного ответа LLM) сохраняем новую пару в кеш.

## Новый поток

```
OpenAI Embeddings
   ↓
[NEW] Supabase RPC - match_cached_answer  ← новая нода
   ↓
[NEW] Normalize Cache Hit                  ← новая нода
   ↓
[NEW] IF - Cache Hit?                      ← новая нода
   ├─ ДА → Supabase RPC - touch_cache_answer → Response - Answer (Cached)
   └─ НЕТ → Supabase RPC - match_documents (как раньше)
                ↓
              ... (старый путь) ...
                ↓
              Response - Answer
                ↓
              [NEW] Supabase Insert cache_answers  ← новая нода после успешного ответа
```

---

## Шаг 1. Применить SQL миграцию

```bash
# В Supabase Dashboard → SQL Editor
# выполнить: 004_semantic_cache.sql
```

## Шаг 2. Добавить в workflow telegram_question 4 новые ноды

### Нода A: `Supabase RPC - match_cached_answer` (HTTP Request)
- **Method:** POST
- **URL:** `={{ $env.SUPABASE_URL + '/rest/v1/rpc/match_cached_answer' }}`
- **Headers:**
  - `apikey: {{ $env.SUPABASE_SERVICE_ROLE_KEY }}`
  - `Authorization: Bearer {{ $env.SUPABASE_SERVICE_ROLE_KEY }}`
  - `Content-Type: application/json`
- **Body (JSON):**
```json
{
  "query_embedding": "={{ $('OpenAI Embeddings').item.json.data[0].embedding }}",
  "match_threshold": 0.92
}
```

### Нода B: `Normalize Cache Hit` (Code)
```js
const inputItems = $input.all();
let rows = [];
if (inputItems.length === 1 && Array.isArray(inputItems[0].json)) {
  rows = inputItems[0].json;
} else {
  rows = inputItems.map(i => i.json).filter(r => r && r.id !== undefined);
}
const hit = rows[0] || null;
return [{
  json: {
    cache_hit: Boolean(hit),
    cache_id: hit?.id ?? null,
    cached_answer: hit?.answer ?? null,
    cache_similarity: hit?.similarity ?? null
  }
}];
```

### Нода C: `IF - Cache Hit?` (IF)
- Condition: `{{ $json.cache_hit }}` === `true` (Boolean)

### Нода D: `Supabase RPC - touch_cache_answer` (HTTP Request)
- **Method:** POST
- **URL:** `={{ $env.SUPABASE_URL + '/rest/v1/rpc/touch_cache_answer' }}`
- **Headers:** те же что выше
- **Body (JSON):**
```json
{
  "cache_id": "={{ $('Normalize Cache Hit').item.json.cache_id }}"
}
```

### Нода E: `Response - Answer (Cached)` (Code)
```js
return [{
  json: {
    method: 'sendMessage',
    chat_id: $('Route Telegram Update').item.json.chat_id,
    text: $('Normalize Cache Hit').item.json.cached_answer
  }
}];
```

### Нода F: `Supabase Insert cache_answers` (HTTP Request)
- **Method:** POST
- **URL:** `={{ $env.SUPABASE_URL + '/rest/v1/cache_answers' }}`
- **Headers:**
  - `apikey: {{ $env.SUPABASE_SERVICE_ROLE_KEY }}`
  - `Authorization: Bearer {{ $env.SUPABASE_SERVICE_ROLE_KEY }}`
  - `Content-Type: application/json`
  - `Prefer: return=minimal`
- **Body (JSON):**
```json
{
  "question": "={{ $('Route Telegram Update').item.json.question }}",
  "answer": "={{ $('OpenAI Chat Completions').item.json.choices[0].message.content }}",
  "embedding": "={{ $('OpenAI Embeddings').item.json.data[0].embedding }}"
}
```

---

## Шаг 3. Перекоммутировать связи

**В n8n UI (drag-and-drop):**

1. Удалить связь: `OpenAI Embeddings` → `Supabase RPC - match_documents`
2. Создать связи:
   - `OpenAI Embeddings` → `Supabase RPC - match_cached_answer`
   - `Supabase RPC - match_cached_answer` → `Normalize Cache Hit`
   - `Normalize Cache Hit` → `IF - Cache Hit?`
   - `IF - Cache Hit?` (true) → `Supabase RPC - touch_cache_answer`
   - `Supabase RPC - touch_cache_answer` → `Response - Answer (Cached)`
   - `IF - Cache Hit?` (false) → `Supabase RPC - match_documents` (продолжается старый путь)

3. После `Supabase Insert qa_log - answered` добавить новую ветку:
   - `Supabase Insert qa_log - answered` → `Supabase Insert cache_answers`
   - `Supabase Insert cache_answers` → ничего (терминальная нода)

   То есть `Response - Answer` должна выполняться **параллельно** или **до** `Supabase Insert cache_answers`. Если в n8n параллельных веток не хочется — поставь Insert после Response.

---

## Шаг 4. Добавить очистку при /reload

В workflow `04 Telegram Admin Commands` найти ноду `HTTP Request - Trigger Ingestion` (срабатывает на `/reload`). **Перед** триггером ingestion добавить ещё один HTTP Request:

### Нода: `Supabase RPC - purge_cache`
- **Method:** POST
- **URL:** `={{ $env.SUPABASE_URL + '/rest/v1/rpc/purge_cache' }}`
- **Headers:** те же стандартные
- **Body (JSON):** `{}`

Связь: `IF - /reload` (true) → `Supabase RPC - purge_cache` → `HTTP Request - Trigger Ingestion` → `Response - Reload`

Логика: при заливке новой базы знаний кеш чистим полностью — старые ответы могут быть неактуальны.

---

## Шаг 5. (Опционально) Cron для эвикции

В Supabase Dashboard → Database → Cron можно поставить:

```sql
select cron.schedule(
  'evict-stale-cache',
  '0 3 * * *',  -- каждый день в 3:00 ночи
  $$ select public.evict_stale_cache(7); $$
);
```

Удаляет записи которые не использовались 7 дней. Не критично — кеш и без этого не разрастётся катастрофически — но чисто.

---

## Что НЕ кешируем

- **Тикеты** (когда ответа в базе знаний нет) — иначе бот перестанет создавать тикеты на новые вопросы
- **Сообщения короче 10 символов** — бессмысленные вопросы типа "?" не должны попадать в кеш
- **Callback queries** — там нет вопроса как такового

Это уже учтено в структуре потока: Insert cache_answers стоит **только** в ветке после успешного ответа LLM, до неё доходят только осмысленные вопросы.

---

## Проверка работы

1. Задай боту вопрос: "Сколько стоит VIP?"
2. В таблице `cache_answers` появится запись
3. Задай тот же вопрос или похожий: "А цена випа какая?"
4. Ответ должен прийти **мгновенно** (без LLM-задержки)
5. В таблице `cache_answers` у этой записи `hit_count = 2`

В Supabase SQL Editor для мониторинга:
```sql
select question, hit_count, last_used_at
from cache_answers
order by hit_count desc
limit 20;
```

Покажет топ вопросов которые экономят тебе деньги.
