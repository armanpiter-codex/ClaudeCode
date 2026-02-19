#!/usr/bin/env bash
#
# OpenClaw — ЧИСТАЯ УСТАНОВКА на VPS (Ubuntu/Debian)
# Запускать ПОСЛЕ openclaw-full-cleanup.sh
#
# Использование:
#   chmod +x openclaw-fresh-install.sh
#   sudo ./openclaw-fresh-install.sh
#
# Перед запуском убедитесь, что:
#   1. Скрипт очистки (openclaw-full-cleanup.sh) был выполнен
#   2. Сервер перезагружен (рекомендуется)
#   3. У вас есть API-ключ (Anthropic/OpenAI/другой)
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
echo " OpenClaw — ЧИСТАЯ УСТАНОВКА"
echo "============================================"
echo ""

# ── Предварительная проверка ──────────────────────────────────────────────

info "Проверяю, что старый OpenClaw полностью удалён..."

LEFTOVERS=false
if command -v openclaw &>/dev/null; then
    error "openclaw всё ещё установлен! Сначала запустите openclaw-full-cleanup.sh"
    LEFTOVERS=true
fi
if [ -d "$HOME/.openclaw" ] || [ -d "$HOME/.clawdbot" ] || [ -d "$HOME/.moltbot" ]; then
    error "Найдены конфиг-директории OpenClaw! Сначала запустите очистку."
    LEFTOVERS=true
fi
if command -v docker &>/dev/null; then
    if docker ps -a 2>/dev/null | grep -qi "openclaw\|clawdbot\|moltbot"; then
        error "Найдены Docker-контейнеры OpenClaw! Сначала запустите очистку."
        LEFTOVERS=true
    fi
fi

if [ "$LEFTOVERS" = true ]; then
    echo ""
    error "Обнаружены остатки предыдущей установки."
    error "Запустите: sudo ./openclaw-full-cleanup.sh"
    exit 1
fi

info "Чисто! Продолжаю установку."
echo ""

# ── 1. Обновление системы и установка зависимостей ────────────────────────

info "1/5 — Обновляю систему и устанавливаю зависимости..."

apt-get update -y
apt-get upgrade -y
apt-get install -y \
    curl \
    git \
    ca-certificates \
    gnupg \
    lsb-release \
    ufw \
    fail2ban

info "  Системные пакеты установлены."

# ── 2. Установка Docker (если не установлен) ──────────────────────────────

info "2/5 — Проверяю Docker..."

if ! command -v docker &>/dev/null; then
    info "  Docker не найден, устанавливаю..."

    # Удаляем старые версии если есть
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    # Устанавливаем Docker из официального репозитория
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || true
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    systemctl enable docker
    systemctl start docker

    info "  Docker установлен."
else
    info "  Docker уже установлен: $(docker --version)"
fi

# Проверяем Docker Compose v2
if ! docker compose version &>/dev/null; then
    error "Docker Compose v2 не установлен! Установите docker-compose-plugin."
    exit 1
fi
info "  Docker Compose: $(docker compose version)"

# ── 3. Настройка безопасности ─────────────────────────────────────────────

info "3/5 — Настраиваю firewall..."

ufw allow ssh 2>/dev/null || true
# НЕ открываем порт 18789 наружу — только через localhost
ufw --force enable 2>/dev/null || true

info "  UFW настроен (порт OpenClaw НЕ открыт наружу)."

# ── 4. Клонирование и установка OpenClaw ──────────────────────────────────

info "4/5 — Клонирую и устанавливаю OpenClaw..."

INSTALL_DIR="$HOME/openclaw"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# Клонируем репозиторий
git clone https://github.com/openclaw/openclaw.git .

info "  Репозиторий склонирован в $INSTALL_DIR"
echo ""

# ── 5. Настройка .env файла ───────────────────────────────────────────────

info "5/5 — Создаю конфигурацию..."

# Генерируем случайный токен для Gateway
GATEWAY_TOKEN=$(openssl rand -hex 32 2>/dev/null || head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n')

cat > "$INSTALL_DIR/.env" << ENVEOF
# ===== OpenClaw Configuration =====
# Сгенерированный токен для Gateway API
OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}

# === API КЛЮЧИ — ЗАПОЛНИТЕ СВОИ ===
# Раскомментируйте нужный провайдер:
#ANTHROPIC_API_KEY=sk-ant-xxx
#OPENAI_API_KEY=sk-xxx
#GOOGLE_API_KEY=xxx

# === Безопасность ===
# Привязка порта только к localhost (не открывать наружу!)
OPENCLAW_HOST=127.0.0.1
OPENCLAW_PORT=18789

# === Дополнительно ===
#OPENCLAW_EXTRA_MOUNTS=
#OPENCLAW_HOME_VOLUME=openclaw_home
ENVEOF

info "  .env файл создан в $INSTALL_DIR/.env"
echo ""

echo "============================================"
echo -e " ${GREEN}УСТАНОВКА ЗАВЕРШЕНА!${NC}"
echo "============================================"
echo ""
echo "СЛЕДУЮЩИЕ ШАГИ:"
echo ""
echo "  1. Отредактируйте .env файл и добавьте свой API-ключ:"
echo "     nano $INSTALL_DIR/.env"
echo ""
echo "  2. Запустите Docker setup:"
echo "     cd $INSTALL_DIR"
echo "     chmod +x docker-setup.sh"
echo "     ./docker-setup.sh"
echo ""
echo "  3. Или запустите через docker compose:"
echo "     cd $INSTALL_DIR"
echo "     docker compose up -d"
echo ""
echo "  4. Проверьте что всё работает:"
echo "     docker compose logs -f"
echo ""
echo "  Gateway токен: ${GATEWAY_TOKEN}"
echo "  (сохраните его — он нужен для подключения клиентов)"
echo ""
echo "  ВАЖНО: Порт 18789 привязан к localhost."
echo "  Для внешнего доступа используйте reverse proxy (nginx/caddy)."
echo ""
