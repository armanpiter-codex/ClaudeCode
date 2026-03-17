#!/usr/bin/env bash
#
# OpenClaw Doctor — ДИАГНОСТИКА ОШИБКИ 500 на десктопном сервере
#
# Использование:
#   chmod +x openclaw-doctor.sh
#   ./openclaw-doctor.sh [путь-к-env]
#
# Проверяет типичные причины "API Error: 500":
#   1. API-ключ не настроен (заглушка)
#   2. Gateway не запущен / не отвечает
#   3. Модель недоступна на OpenRouter
#   4. Порт занят другим процессом
#   5. Docker-контейнеры в нерабочем состоянии
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()    { echo -e "  ${GREEN}✓${NC} $*"; }
fail()  { echo -e "  ${RED}✗${NC} $*"; ERRORS=$((ERRORS + 1)); }
warn()  { echo -e "  ${YELLOW}!${NC} $*"; WARNINGS=$((WARNINGS + 1)); }
info()  { echo -e "  ${CYAN}→${NC} $*"; }

ERRORS=0
WARNINGS=0

echo ""
echo "============================================"
echo " OpenClaw Doctor — Диагностика ошибки 500"
echo "============================================"
echo ""

# ── Определяем путь к .env ──────────────────────────────────────────────────

ENV_FILE="${1:-}"
if [ -z "$ENV_FILE" ]; then
    # Ищем .env в типичных местах
    for candidate in \
        "./env" \
        "./.env" \
        "$HOME/openclaw/.env" \
        "/opt/openclaw/.env"; do
        if [ -f "$candidate" ]; then
            ENV_FILE="$candidate"
            break
        fi
    done
fi

# ── 1. Проверка .env файла ──────────────────────────────────────────────────

echo "[1/6] Проверяю .env конфигурацию..."

if [ -z "$ENV_FILE" ] || [ ! -f "$ENV_FILE" ]; then
    fail ".env файл не найден!"
    info "Создайте .env: sudo ./openclaw-fresh-install.sh"
    info "Или укажите путь: ./openclaw-doctor.sh /path/to/.env"
else
    ok ".env найден: $ENV_FILE"

    # Загружаем переменные (без экспорта)
    # shellcheck disable=SC1090
    set +u
    source "$ENV_FILE" 2>/dev/null || true
    set -u

    # Проверяем API-ключ OpenRouter
    OR_KEY="${OPENROUTER_API_KEY:-}"
    if [ -z "$OR_KEY" ]; then
        # Проверяем прямые ключи
        ANTH_KEY="${ANTHROPIC_API_KEY:-}"
        OAI_KEY="${OPENAI_API_KEY:-}"
        GOOG_KEY="${GOOGLE_API_KEY:-}"
        if [ -z "$ANTH_KEY" ] && [ -z "$OAI_KEY" ] && [ -z "$GOOG_KEY" ]; then
            fail "Ни один API-ключ не настроен!"
            info "Откройте $ENV_FILE и добавьте OPENROUTER_API_KEY=sk-or-v1-ваш-ключ"
        else
            ok "Найдены прямые API-ключи (без OpenRouter)."
        fi
    elif [ "$OR_KEY" = "sk-or-v1-xxx" ] || [ "$OR_KEY" = "sk-or-v1-" ] || [[ "$OR_KEY" == *"xxx"* ]]; then
        fail "OPENROUTER_API_KEY содержит заглушку! Это ГЛАВНАЯ причина ошибки 500."
        info "Получите ключ на https://openrouter.ai/keys"
        info "Затем: nano $ENV_FILE"
    elif [[ "$OR_KEY" != sk-or-v1-* ]]; then
        warn "OPENROUTER_API_KEY не начинается с 'sk-or-v1-' — возможно неверный формат."
    else
        ok "OPENROUTER_API_KEY настроен (sk-or-v1-...${OR_KEY: -4})"
    fi

    # Проверяем модель
    MODEL="${OPENCLAW_DEFAULT_MODEL:-}"
    if [ -z "$MODEL" ]; then
        warn "OPENCLAW_DEFAULT_MODEL не задана — будет использована модель по умолчанию."
    else
        ok "Модель: $MODEL"
    fi
fi

echo ""

# ── 2. Проверка порта Gateway ───────────────────────────────────────────────

echo "[2/6] Проверяю порт Gateway (18789)..."

GW_PORT="${OPENCLAW_PORT:-18789}"
GW_HOST="${OPENCLAW_HOST:-127.0.0.1}"

if command -v ss &>/dev/null; then
    PORT_INFO=$(ss -tlnp 2>/dev/null | grep ":${GW_PORT}" || true)
    if [ -n "$PORT_INFO" ]; then
        ok "Порт $GW_PORT слушается"
        # Показываем какой процесс держит порт
        PROC=$(echo "$PORT_INFO" | grep -oP 'users:\(\("\K[^"]+' || echo "неизвестно")
        info "Процесс: $PROC"
    else
        fail "Порт $GW_PORT НЕ слушается! Gateway не запущен."
        info "Запустите: cd ~/openclaw && docker compose up -d"
    fi
elif command -v lsof &>/dev/null; then
    if lsof -i ":${GW_PORT}" &>/dev/null; then
        ok "Порт $GW_PORT слушается"
    else
        fail "Порт $GW_PORT НЕ слушается! Gateway не запущен."
    fi
else
    warn "Нет утилит ss/lsof — не могу проверить порт."
fi

echo ""

# ── 3. Проверка HTTP-ответа Gateway ────────────────────────────────────────

echo "[3/6] Проверяю HTTP-ответ Gateway..."

if command -v curl &>/dev/null; then
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 5 --max-time 10 \
        "http://${GW_HOST}:${GW_PORT}/health" 2>/dev/null || echo "000")

    case "$HTTP_CODE" in
        200|204)
            ok "Gateway отвечает: HTTP $HTTP_CODE"
            ;;
        000)
            fail "Gateway не отвечает (connection refused / timeout)"
            info "Gateway не запущен или слушает другой адрес."
            ;;
        401|403)
            warn "Gateway отвечает HTTP $HTTP_CODE — требуется аутентификация."
            info "Проверьте OPENCLAW_GATEWAY_TOKEN в .env"
            ;;
        500)
            fail "Gateway отвечает HTTP 500! Внутренняя ошибка сервера."
            info "Проверьте логи: docker compose logs --tail=50"
            ;;
        502|503)
            fail "Gateway отвечает HTTP $HTTP_CODE — бэкенд недоступен."
            info "Проверьте, что все контейнеры запущены: docker compose ps"
            ;;
        *)
            warn "Gateway отвечает HTTP $HTTP_CODE — неожиданный статус."
            ;;
    esac

    # Пробуем ещё корень
    HTTP_ROOT=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 5 --max-time 10 \
        "http://${GW_HOST}:${GW_PORT}/" 2>/dev/null || echo "000")
    if [ "$HTTP_ROOT" != "$HTTP_CODE" ] && [ "$HTTP_ROOT" != "000" ]; then
        info "Корневой URL отвечает: HTTP $HTTP_ROOT"
    fi
else
    warn "curl не установлен — не могу проверить HTTP."
fi

echo ""

# ── 4. Проверка Docker-контейнеров ──────────────────────────────────────────

echo "[4/6] Проверяю Docker-контейнеры..."

if command -v docker &>/dev/null; then
    if ! docker info &>/dev/null; then
        fail "Docker daemon не запущен!"
        info "Запустите: sudo systemctl start docker"
    else
        ok "Docker daemon работает."

        # Ищем контейнеры openclaw
        CONTAINERS=$(docker ps -a --filter "name=openclaw" --format "{{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true)
        if [ -z "$CONTAINERS" ]; then
            warn "Контейнеры OpenClaw не найдены."
            info "Запустите: cd ~/openclaw && docker compose up -d"
        else
            echo "$CONTAINERS" | while IFS=$'\t' read -r name status ports; do
                if [[ "$status" == *"Up"* ]]; then
                    ok "$name — $status"
                    [ -n "$ports" ] && info "  Порты: $ports"
                else
                    fail "$name — $status (НЕ ЗАПУЩЕН!)"
                    info "  Перезапустите: docker compose restart $name"
                fi
            done
        fi

        # Проверяем docker compose
        OPENCLAW_DIR="$HOME/openclaw"
        if [ -d "$OPENCLAW_DIR" ]; then
            UNHEALTHY=$(cd "$OPENCLAW_DIR" && docker compose ps 2>/dev/null | grep -i "unhealthy\|exit\|dead" || true)
            if [ -n "$UNHEALTHY" ]; then
                fail "Есть нездоровые контейнеры:"
                echo "$UNHEALTHY" | while read -r line; do
                    info "  $line"
                done
            fi
        fi
    fi
else
    warn "Docker не установлен."
fi

echo ""

# ── 5. Проверка доступности OpenRouter API ──────────────────────────────────

echo "[5/6] Проверяю доступность OpenRouter API..."

if command -v curl &>/dev/null; then
    OR_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 10 --max-time 15 \
        "https://openrouter.ai/api/v1/models" 2>/dev/null || echo "000")

    case "$OR_STATUS" in
        200)
            ok "OpenRouter API доступен (HTTP 200)"
            ;;
        000)
            fail "Не удалось подключиться к OpenRouter! Проверьте интернет."
            info "ping openrouter.ai"
            ;;
        *)
            warn "OpenRouter отвечает HTTP $OR_STATUS"
            ;;
    esac

    # Проверяем конкретную модель (если есть ключ)
    OR_KEY="${OPENROUTER_API_KEY:-}"
    MODEL="${OPENCLAW_DEFAULT_MODEL:-openrouter/google/gemini-3-flash-preview}"
    # Извлекаем ID модели без префикса openrouter/
    MODEL_ID="${MODEL#openrouter/}"

    if [ -n "$OR_KEY" ] && [ "$OR_KEY" != "sk-or-v1-xxx" ] && [[ "$OR_KEY" != *"xxx"* ]]; then
        # Проверяем модель через API
        MODEL_CHECK=$(curl -s --connect-timeout 10 --max-time 15 \
            "https://openrouter.ai/api/v1/models" 2>/dev/null || echo "")
        if [ -n "$MODEL_CHECK" ]; then
            if echo "$MODEL_CHECK" | grep -q "$MODEL_ID"; then
                ok "Модель $MODEL_ID доступна на OpenRouter"
            else
                warn "Модель $MODEL_ID не найдена в списке OpenRouter!"
                info "Проверьте название модели в .env"
                info "Список моделей: https://openrouter.ai/models"
            fi
        fi
    fi
else
    warn "curl не установлен."
fi

echo ""

# ── 6. Проверка логов на ошибки ─────────────────────────────────────────────

echo "[6/6] Проверяю логи на ошибки..."

OPENCLAW_DIR="$HOME/openclaw"
if [ -d "$OPENCLAW_DIR" ] && command -v docker &>/dev/null; then
    RECENT_ERRORS=$(cd "$OPENCLAW_DIR" && docker compose logs --tail=30 2>/dev/null | \
        grep -iE "error|fatal|panic|500|exception|failed|refused" | tail -10 || true)
    if [ -n "$RECENT_ERRORS" ]; then
        fail "Найдены ошибки в логах:"
        echo "$RECENT_ERRORS" | while read -r line; do
            info "  $line"
        done
    else
        ok "Свежих ошибок в логах нет (или логи пусты)."
    fi
else
    warn "Каталог $OPENCLAW_DIR не найден или Docker не доступен."
fi

echo ""

# ── Итог ────────────────────────────────────────────────────────────────────

echo "============================================"
if [ $ERRORS -gt 0 ]; then
    echo -e " ${RED}Найдено проблем: $ERRORS, предупреждений: $WARNINGS${NC}"
    echo "============================================"
    echo ""
    echo "ТИПИЧНЫЕ РЕШЕНИЯ ошибки 500:"
    echo ""
    echo "  1. API-ключ (самая частая причина!):"
    echo "     nano ~/openclaw/.env"
    echo "     → Замените OPENROUTER_API_KEY=sk-or-v1-xxx на реальный ключ"
    echo "     → Получить: https://openrouter.ai/keys"
    echo ""
    echo "  2. Перезапуск Gateway:"
    echo "     cd ~/openclaw && docker compose restart"
    echo ""
    echo "  3. Полный перезапуск:"
    echo "     cd ~/openclaw && docker compose down && docker compose up -d"
    echo ""
    echo "  4. Проверка логов:"
    echo "     cd ~/openclaw && docker compose logs -f --tail=100"
    echo ""
    echo "  5. Смена модели (если текущая недоступна):"
    echo "     В .env замените OPENCLAW_DEFAULT_MODEL на:"
    echo "     openrouter/openai/gpt-4o-mini"
    echo "     openrouter/deepseek/deepseek-r1"
    echo ""
elif [ $WARNINGS -gt 0 ]; then
    echo -e " ${YELLOW}Критических проблем нет, предупреждений: $WARNINGS${NC}"
    echo "============================================"
else
    echo -e " ${GREEN}Всё в порядке! Проблем не обнаружено.${NC}"
    echo "============================================"
fi
echo ""
