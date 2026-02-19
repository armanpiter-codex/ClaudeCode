#!/usr/bin/env bash
#
# OpenClaw — ЧИСТАЯ УСТАНОВКА на OVHcloud VPS (Ubuntu/Debian)
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
echo " OpenClaw — ЧИСТАЯ УСТАНОВКА (OVHcloud VPS)"
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
# Проверяем порт
if command -v ss &>/dev/null; then
    if ss -tlnp 2>/dev/null | grep -q ":18789"; then
        error "Порт 18789 занят! Возможно OpenClaw ещё работает."
        LEFTOVERS=true
    fi
fi

if [ "$LEFTOVERS" = true ]; then
    echo ""
    error "Обнаружены остатки предыдущей установки."
    error "Запустите: sudo ./openclaw-full-cleanup.sh"
    error "Затем перезагрузите: sudo reboot"
    exit 1
fi

info "Чисто! Продолжаю установку."
echo ""

# ── 1. Обновление системы и установка зависимостей ────────────────────────

info "1/6 — Обновляю систему и устанавливаю зависимости..."

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y \
    curl \
    wget \
    git \
    ca-certificates \
    gnupg \
    lsb-release \
    ufw \
    fail2ban \
    unattended-upgrades

# Включаем автообновления безопасности
dpkg-reconfigure -plow unattended-upgrades 2>/dev/null || true

info "  Системные пакеты установлены."

# ── 2. Установка Docker (если не установлен) ──────────────────────────────

info "2/6 — Проверяю Docker..."

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

# Проверяем Docker Compose v2 (ВАЖНО: v1 = сломанный деплой)
if ! docker compose version &>/dev/null; then
    error "Docker Compose v2 не установлен! Установите docker-compose-plugin."
    error "  apt-get install -y docker-compose-plugin"
    exit 1
fi
info "  Docker Compose: $(docker compose version)"

# Добавляем текущего пользователя в группу docker (если не root)
ACTUAL_USER="${SUDO_USER:-$USER}"
if [ "$ACTUAL_USER" != "root" ]; then
    usermod -aG docker "$ACTUAL_USER" 2>/dev/null || true
    info "  Пользователь $ACTUAL_USER добавлен в группу docker."
fi

# ── 3. Настройка безопасности (OVHcloud best practices) ───────────────────

info "3/6 — Настраиваю firewall и безопасность..."

ufw allow OpenSSH 2>/dev/null || true
ufw allow 443/tcp 2>/dev/null || true
# НЕ открываем порт 18789 наружу — только через SSH-туннель
ufw --force enable 2>/dev/null || true

# Настраиваем fail2ban
if systemctl is-active --quiet fail2ban 2>/dev/null; then
    info "  fail2ban уже работает."
else
    systemctl enable fail2ban 2>/dev/null || true
    systemctl start fail2ban 2>/dev/null || true
    info "  fail2ban запущен."
fi

info "  UFW настроен. Порт 18789 НЕ открыт наружу (доступ через SSH-туннель)."

# ── 4. Клонирование OpenClaw ──────────────────────────────────────────────

info "4/6 — Клонирую OpenClaw..."

INSTALL_DIR="$HOME/openclaw"

if [ -d "$INSTALL_DIR" ]; then
    warn "  Директория $INSTALL_DIR уже существует — удаляю..."
    rm -rf "$INSTALL_DIR"
fi

git clone https://github.com/openclaw/openclaw.git "$INSTALL_DIR"
cd "$INSTALL_DIR"

info "  Репозиторий склонирован в $INSTALL_DIR"

# ── 5. Настройка .env файла ───────────────────────────────────────────────

info "5/6 — Создаю конфигурацию..."

# Генерируем случайный токен для Gateway
GATEWAY_TOKEN=$(openssl rand -hex 32 2>/dev/null || head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n')

cat > "$INSTALL_DIR/.env" << ENVEOF
# ===== OpenClaw Configuration (OVHcloud VPS) =====

# Сгенерированный токен для Gateway API
OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}

# === API КЛЮЧИ — ЗАПОЛНИТЕ СВОЙ ===
# Раскомментируйте нужный провайдер и вставьте ключ:
#ANTHROPIC_API_KEY=sk-ant-xxx
#OPENAI_API_KEY=sk-xxx
#GOOGLE_API_KEY=xxx

# === Безопасность ===
# Привязка порта только к localhost (доступ через SSH-туннель)
OPENCLAW_HOST=127.0.0.1
OPENCLAW_PORT=18789

# === Дополнительно ===
#OPENCLAW_EXTRA_MOUNTS=
#OPENCLAW_HOME_VOLUME=openclaw_home
ENVEOF

# Защищаем .env
chmod 600 "$INSTALL_DIR/.env"

info "  .env создан и защищён (chmod 600)."

# ── 6. Запуск Docker setup ────────────────────────────────────────────────

info "6/6 — Запускаю Docker setup..."

cd "$INSTALL_DIR"
if [ -f "docker-setup.sh" ]; then
    chmod +x docker-setup.sh
    info "  docker-setup.sh готов к запуску."
    echo ""
    echo "============================================"
    echo -e " ${GREEN}УСТАНОВКА ЗАВЕРШЕНА!${NC}"
    echo "============================================"
    echo ""
    echo "СЛЕДУЮЩИЕ ШАГИ (выполните вручную):"
    echo ""
    echo "  1. Добавьте API-ключ в .env:"
    echo "     nano $INSTALL_DIR/.env"
    echo ""
    echo "  2. Запустите OpenClaw:"
    echo "     cd $INSTALL_DIR && ./docker-setup.sh"
    echo ""
    echo "  3. Проверьте логи:"
    echo "     docker compose logs -f"
    echo ""
    echo "  4. Подключитесь с Windows через SSH-туннель:"
    echo "     ssh -L 18789:127.0.0.1:18789 ubuntu@vps-83602260"
    echo "     Затем откройте: http://localhost:18789"
    echo ""
    echo "  5. Или установите Gateway:"
    echo "     openclaw gateway install"
    echo "     openclaw doctor --generate-gateway-token"
    echo ""
else
    warn "  docker-setup.sh не найден в репозитории."
    echo ""
    echo "  Запустите вручную:"
    echo "     cd $INSTALL_DIR && docker compose up -d"
fi

echo ""
echo "  Gateway токен: ${GATEWAY_TOKEN}"
echo "  (СОХРАНИТЕ — нужен для подключения клиентов)"
echo ""
echo "  IP вашего VPS: $(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
echo ""
