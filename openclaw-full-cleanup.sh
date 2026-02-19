#!/usr/bin/env bash
#
# OpenClaw (Clawdbot/Moltbot) — ПОЛНАЯ ОЧИСТКА
# Запускать на КАЖДОЙ машине (локальной и VPS) от root или через sudo.
#
# Использование:
#   chmod +x openclaw-full-cleanup.sh
#   sudo ./openclaw-full-cleanup.sh
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERR]${NC}   $*"; }

echo "============================================"
echo " OpenClaw — ПОЛНОЕ УДАЛЕНИЕ"
echo " Скрипт удалит ВСЕ файлы, контейнеры,"
echo " образы, тома, сервисы и конфиги."
echo "============================================"
echo ""

# ── 1. Остановка процессов ────────────────────────────────────────────────

info "1/8 — Останавливаю процессы OpenClaw..."

# pm2
if command -v pm2 &>/dev/null; then
    pm2 stop openclaw 2>/dev/null || true
    pm2 delete openclaw 2>/dev/null || true
    pm2 stop clawdbot 2>/dev/null || true
    pm2 delete clawdbot 2>/dev/null || true
    pm2 stop moltbot 2>/dev/null || true
    pm2 delete moltbot 2>/dev/null || true
    pm2 save --force 2>/dev/null || true
    info "  pm2 процессы остановлены."
fi

# Убиваем процессы напрямую
pkill -f openclaw 2>/dev/null || true
pkill -f clawdbot 2>/dev/null || true
pkill -f moltbot 2>/dev/null || true

# Порт 18789 (gateway по умолчанию)
if command -v fuser &>/dev/null; then
    fuser -k 18789/tcp 2>/dev/null || true
elif command -v lsof &>/dev/null; then
    lsof -ti:18789 | xargs kill -9 2>/dev/null || true
fi

info "  Процессы остановлены."

# ── 2. Остановка systemd-сервисов ─────────────────────────────────────────

info "2/8 — Останавливаю и удаляю systemd-сервисы..."

for svc in openclaw clawdbot moltbot openclaw-gateway; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        systemctl stop "$svc" 2>/dev/null || true
    fi
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        systemctl disable "$svc" 2>/dev/null || true
    fi
    rm -f "/etc/systemd/system/${svc}.service"
    rm -f "/usr/lib/systemd/system/${svc}.service"
done

# Сервисы пользователя
for home_dir in /root /home/*; do
    [ -d "$home_dir" ] || continue
    for svc in openclaw clawdbot moltbot openclaw-gateway; do
        rm -f "${home_dir}/.config/systemd/user/${svc}.service" 2>/dev/null || true
    done
done

systemctl daemon-reload 2>/dev/null || true
info "  systemd-сервисы удалены."

# ── 3. Docker — контейнеры, образы, тома, сети ────────────────────────────

info "3/8 — Удаляю Docker-ресурсы OpenClaw..."

if command -v docker &>/dev/null; then
    # Ищем и останавливаем все контейнеры, содержащие openclaw/clawdbot/moltbot в имени или образе
    for pattern in openclaw clawdbot moltbot; do
        containers=$(docker ps -a --filter "name=${pattern}" --format '{{.ID}}' 2>/dev/null || true)
        if [ -n "$containers" ]; then
            echo "$containers" | xargs docker stop 2>/dev/null || true
            echo "$containers" | xargs docker rm -f 2>/dev/null || true
            info "  Контейнеры '${pattern}' удалены."
        fi
        # Также ищем по образу
        containers=$(docker ps -a --filter "ancestor=${pattern}" --format '{{.ID}}' 2>/dev/null || true)
        if [ -n "$containers" ]; then
            echo "$containers" | xargs docker stop 2>/dev/null || true
            echo "$containers" | xargs docker rm -f 2>/dev/null || true
        fi
    done

    # docker-compose down (ищем compose-файлы в типичных местах)
    for dir in /root/openclaw /root/clawdbot /root/moltbot \
               /home/*/openclaw /home/*/clawdbot /home/*/moltbot \
               /opt/openclaw /opt/clawdbot /opt/moltbot; do
        if [ -f "${dir}/docker-compose.yml" ] || [ -f "${dir}/docker-compose.yaml" ] || [ -f "${dir}/compose.yml" ]; then
            info "  Нашёл compose в ${dir}, делаю down..."
            (cd "$dir" && docker compose down -v 2>/dev/null || docker-compose down -v 2>/dev/null || true)
        fi
    done

    # Удаление образов
    for pattern in openclaw clawdbot moltbot; do
        images=$(docker images --filter "reference=*${pattern}*" --format '{{.ID}}' 2>/dev/null || true)
        if [ -n "$images" ]; then
            echo "$images" | xargs docker rmi -f 2>/dev/null || true
            info "  Образы '${pattern}' удалены."
        fi
    done

    # Удаление томов, связанных с openclaw
    for pattern in openclaw clawdbot moltbot; do
        volumes=$(docker volume ls --filter "name=${pattern}" --format '{{.Name}}' 2>/dev/null || true)
        if [ -n "$volumes" ]; then
            echo "$volumes" | xargs docker volume rm -f 2>/dev/null || true
            info "  Тома '${pattern}' удалены."
        fi
    done

    # Удаление сетей
    for pattern in openclaw clawdbot moltbot; do
        networks=$(docker network ls --filter "name=${pattern}" --format '{{.Name}}' 2>/dev/null || true)
        if [ -n "$networks" ]; then
            echo "$networks" | xargs docker network rm 2>/dev/null || true
            info "  Сети '${pattern}' удалены."
        fi
    done

    # Общая очистка docker
    docker system prune -f 2>/dev/null || true
    info "  Docker cleanup завершён."
else
    warn "  Docker не установлен — пропускаю."
fi

# ── 4. npm / npx — глобальное удаление ────────────────────────────────────

info "4/8 — Удаляю npm-пакеты OpenClaw..."

if command -v npm &>/dev/null; then
    npm uninstall -g openclaw 2>/dev/null || true
    npm uninstall -g clawdbot 2>/dev/null || true
    npm uninstall -g moltbot 2>/dev/null || true
    # Очистка кэша npx
    npm cache clean --force 2>/dev/null || true
    info "  npm-пакеты удалены."
else
    warn "  npm не установлен — пропускаю."
fi

# ── 5. Удаление ВСЕХ файлов и директорий ──────────────────────────────────

info "5/8 — Удаляю все файлы и директории OpenClaw..."

# Список всех возможных директорий (включая legacy-имена)
DIRS_TO_REMOVE=(
    # Конфиг-директории в домашних каталогах
    "$HOME/.openclaw"
    "$HOME/.clawdbot"
    "$HOME/.moltbot"
    "$HOME/.molthub"
    "$HOME/molthub-cache"
    "$HOME/.local/share/openclaw"
    "$HOME/.local/share/clawdbot"
    "$HOME/.local/share/moltbot"
    "$HOME/.config/openclaw"
    "$HOME/.config/clawdbot"
    "$HOME/.config/moltbot"
    "$HOME/.cache/openclaw"
    "$HOME/.cache/clawdbot"
    # Рабочие директории проекта
    "$HOME/openclaw"
    "$HOME/clawdbot"
    "$HOME/moltbot"
    # Глобальные пути
    "/opt/openclaw"
    "/opt/clawdbot"
    "/opt/moltbot"
    "/var/lib/openclaw"
    "/var/log/openclaw"
    "/tmp/openclaw*"
)

for dir in "${DIRS_TO_REMOVE[@]}"; do
    # Используем eval для подстановки glob-паттернов (например /tmp/openclaw*)
    for resolved in $dir; do
        if [ -e "$resolved" ]; then
            rm -rf "$resolved"
            info "  Удалено: $resolved"
        fi
    done
done

# Также проверяем ВСЕ домашние каталоги (не только текущего пользователя)
for home_dir in /root /home/*; do
    [ -d "$home_dir" ] || continue
    for name in .openclaw .clawdbot .moltbot .molthub molthub-cache openclaw clawdbot moltbot; do
        target="${home_dir}/${name}"
        if [ -e "$target" ]; then
            rm -rf "$target"
            info "  Удалено: $target"
        fi
    done
    # .local/share и .config
    for subdir in .local/share .config .cache; do
        for name in openclaw clawdbot moltbot; do
            target="${home_dir}/${subdir}/${name}"
            if [ -e "$target" ]; then
                rm -rf "$target"
                info "  Удалено: $target"
            fi
        done
    done
done

info "  Файлы и директории удалены."

# ── 6. Crontab — очистка ──────────────────────────────────────────────────

info "6/8 — Очищаю crontab от записей OpenClaw..."

for user_name in $(cut -d: -f1 /etc/passwd 2>/dev/null); do
    crontab_content=$(crontab -l -u "$user_name" 2>/dev/null || true)
    if echo "$crontab_content" | grep -qi "openclaw\|clawdbot\|moltbot"; then
        echo "$crontab_content" | grep -vi "openclaw\|clawdbot\|moltbot" | crontab -u "$user_name" - 2>/dev/null || true
        info "  Очищен crontab для пользователя: $user_name"
    fi
done

info "  Crontab очищен."

# ── 7. Очистка shell-профилей ─────────────────────────────────────────────

info "7/8 — Очищаю shell-профили от переменных OpenClaw..."

SHELL_FILES=(
    ".bashrc"
    ".bash_profile"
    ".profile"
    ".zshrc"
    ".zprofile"
)

for home_dir in /root /home/*; do
    [ -d "$home_dir" ] || continue
    for shell_file in "${SHELL_FILES[@]}"; do
        target="${home_dir}/${shell_file}"
        if [ -f "$target" ]; then
            # Удаляем строки с переменными openclaw/clawdbot/moltbot
            if grep -qi "openclaw\|clawdbot\|moltbot\|OPENCLAW\|CLAWDBOT\|MOLTBOT" "$target" 2>/dev/null; then
                sed -i '/[Oo]pen[Cc]law\|[Cc]lawdbot\|[Mm]oltbot\|OPENCLAW\|CLAWDBOT\|MOLTBOT/d' "$target" 2>/dev/null || true
                info "  Очищен: $target"
            fi
        fi
    done
done

info "  Shell-профили очищены."

# ── 8. Финальная проверка ─────────────────────────────────────────────────

info "8/8 — Финальная проверка..."
echo ""

CLEAN=true

# Проверка процессов
if pgrep -f "openclaw|clawdbot|moltbot" &>/dev/null; then
    error "  Найдены запущенные процессы openclaw!"
    CLEAN=false
fi

# Проверка Docker
if command -v docker &>/dev/null; then
    if docker ps -a 2>/dev/null | grep -qi "openclaw\|clawdbot\|moltbot"; then
        error "  Найдены Docker-контейнеры openclaw!"
        CLEAN=false
    fi
fi

# Проверка npm
if command -v npm &>/dev/null; then
    if npm list -g 2>/dev/null | grep -qi "openclaw\|clawdbot\|moltbot"; then
        error "  Найдены npm-пакеты openclaw!"
        CLEAN=false
    fi
fi

# Проверка бинарника
if command -v openclaw &>/dev/null || command -v clawdbot &>/dev/null || command -v moltbot &>/dev/null; then
    error "  Бинарник openclaw всё ещё доступен в PATH!"
    CLEAN=false
fi

# Проверка порта
if command -v ss &>/dev/null; then
    if ss -tlnp 2>/dev/null | grep -q ":18789"; then
        error "  Порт 18789 всё ещё занят!"
        CLEAN=false
    fi
fi

echo ""
if [ "$CLEAN" = true ]; then
    echo "============================================"
    echo -e " ${GREEN}ГОТОВО! OpenClaw полностью удалён.${NC}"
    echo "============================================"
else
    echo "============================================"
    echo -e " ${YELLOW}Есть остатки — проверьте ошибки выше.${NC}"
    echo "============================================"
fi

echo ""
echo "ВАЖНО: Не забудьте отозвать OAuth-токены вручную:"
echo "  - Google: https://myaccount.google.com/permissions"
echo "  - Discord: Server Settings > Integrations"
echo "  - Telegram: через @BotFather — /deletebot"
echo "  - Slack: Workspace App Management"
echo "  - Проверьте API-ключи: Anthropic, OpenAI и др."
echo ""
