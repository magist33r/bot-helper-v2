#!/usr/bin/env bash
set -euo pipefail

if [ -f .env ]; then
  set -a
  # Accept .env files copied from Windows with CRLF line endings.
  # shellcheck disable=SC1091
  . <(sed 's/\r$//' .env)
  set +a
fi

echo "=== Docker container state ==="
docker inspect allaibot_v2-n8n-1 \
  --format 'Status={{.State.Status}} Restarts={{.RestartCount}} Health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'

echo ""
echo "=== Last 20 container log lines ==="
docker logs allaibot_v2-n8n-1 --tail 20 2>&1

echo ""
echo "=== Telegram main bot webhook info ==="
curl -4 -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getWebhookInfo" \
  | python3 -m json.tool 2>/dev/null || cat

echo ""
echo "=== Telegram admin bot webhook info ==="
curl -4 -s "https://api.telegram.org/bot${TELEGRAM_ADMIN_BOT_TOKEN}/getWebhookInfo" \
  | python3 -m json.tool 2>/dev/null || cat

echo ""
echo "=== Webhook endpoint local health ==="
curl -si -X POST http://localhost:5678/webhook/telegram-question \
  -H "Content-Type: application/json" \
  -H "X-Telegram-Bot-Api-Secret-Token: ${TG_WEBHOOK_SECRET:-}" \
  -d '{"message":{"text":"/start","chat":{"id":1},"from":{"id":1,"username":"test"},"message_id":1}}' \
  | head -5

echo ""
echo "=== n8n healthz ==="
curl -si http://localhost:5678/healthz | head -3
