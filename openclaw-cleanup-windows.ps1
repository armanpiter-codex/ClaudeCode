#Requires -RunAsAdministrator
<#
.SYNOPSIS
    OpenClaw (Clawdbot/Moltbot) — ПОЛНАЯ ОЧИСТКА для Windows
.DESCRIPTION
    Удаляет все файлы, процессы, Docker-ресурсы и конфиги OpenClaw с Windows-машины.
.USAGE
    Откройте PowerShell от имени администратора:
    Set-ExecutionPolicy Bypass -Scope Process -Force
    .\openclaw-cleanup-windows.ps1
#>

$ErrorActionPreference = "SilentlyContinue"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " OpenClaw — ПОЛНОЕ УДАЛЕНИЕ (Windows)"       -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. Остановка процессов ────────────────────────────────────────────────

Write-Host "[1/7] Останавливаю процессы OpenClaw..." -ForegroundColor Green

$processNames = @("openclaw", "clawdbot", "moltbot", "node")
foreach ($proc in $processNames) {
    $running = Get-Process -Name $proc -ErrorAction SilentlyContinue
    if ($running) {
        $running | Stop-Process -Force
        Write-Host "  Остановлен: $proc" -ForegroundColor Yellow
    }
}

# Убиваем по порту 18789
$portProcess = Get-NetTCPConnection -LocalPort 18789 -ErrorAction SilentlyContinue
if ($portProcess) {
    $portProcess | ForEach-Object {
        Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue
    }
    Write-Host "  Процесс на порту 18789 остановлен" -ForegroundColor Yellow
}

# pm2
$pm2Path = Get-Command pm2 -ErrorAction SilentlyContinue
if ($pm2Path) {
    & pm2 stop openclaw 2>$null
    & pm2 delete openclaw 2>$null
    & pm2 stop clawdbot 2>$null
    & pm2 delete clawdbot 2>$null
    & pm2 stop moltbot 2>$null
    & pm2 delete moltbot 2>$null
    & pm2 save --force 2>$null
    Write-Host "  pm2 процессы остановлены" -ForegroundColor Yellow
}

Write-Host "  Готово." -ForegroundColor Green

# ── 2. Docker — контейнеры, образы, тома ──────────────────────────────────

Write-Host "[2/7] Удаляю Docker-ресурсы OpenClaw..." -ForegroundColor Green

$dockerPath = Get-Command docker -ErrorAction SilentlyContinue
if ($dockerPath) {
    foreach ($pattern in @("openclaw", "clawdbot", "moltbot")) {
        # Контейнеры по имени
        $containers = docker ps -a --filter "name=$pattern" --format "{{.ID}}" 2>$null
        if ($containers) {
            $containers | ForEach-Object { docker stop $_ 2>$null; docker rm -f $_ 2>$null }
            Write-Host "  Контейнеры '$pattern' удалены" -ForegroundColor Yellow
        }
    }

    # docker-compose down в типичных директориях
    $composeDirs = @(
        "$env:USERPROFILE\openclaw",
        "$env:USERPROFILE\clawdbot",
        "$env:USERPROFILE\moltbot",
        "$env:USERPROFILE\Documents\openclaw",
        "$env:USERPROFILE\Desktop\openclaw"
    )
    foreach ($dir in $composeDirs) {
        if (Test-Path "$dir\docker-compose.yml" -or (Test-Path "$dir\docker-compose.yaml") -or (Test-Path "$dir\compose.yml")) {
            Write-Host "  Нашёл compose в $dir, делаю down..." -ForegroundColor Yellow
            Push-Location $dir
            docker compose down -v 2>$null
            Pop-Location
        }
    }

    # Образы
    foreach ($pattern in @("openclaw", "clawdbot", "moltbot")) {
        $images = docker images --filter "reference=*${pattern}*" --format "{{.ID}}" 2>$null
        if ($images) {
            $images | ForEach-Object { docker rmi -f $_ 2>$null }
            Write-Host "  Образы '$pattern' удалены" -ForegroundColor Yellow
        }
    }

    # Тома
    foreach ($pattern in @("openclaw", "clawdbot", "moltbot")) {
        $volumes = docker volume ls --filter "name=$pattern" --format "{{.Name}}" 2>$null
        if ($volumes) {
            $volumes | ForEach-Object { docker volume rm -f $_ 2>$null }
            Write-Host "  Тома '$pattern' удалены" -ForegroundColor Yellow
        }
    }

    # Сети
    foreach ($pattern in @("openclaw", "clawdbot", "moltbot")) {
        $networks = docker network ls --filter "name=$pattern" --format "{{.Name}}" 2>$null
        if ($networks) {
            $networks | ForEach-Object { docker network rm $_ 2>$null }
        }
    }

    docker system prune -f 2>$null
    Write-Host "  Docker cleanup завершён." -ForegroundColor Green
} else {
    Write-Host "  Docker не установлен — пропускаю." -ForegroundColor Yellow
}

# ── 3. npm — глобальное удаление ──────────────────────────────────────────

Write-Host "[3/7] Удаляю npm-пакеты OpenClaw..." -ForegroundColor Green

$npmPath = Get-Command npm -ErrorAction SilentlyContinue
if ($npmPath) {
    & npm uninstall -g openclaw 2>$null
    & npm uninstall -g clawdbot 2>$null
    & npm uninstall -g moltbot 2>$null
    & npm cache clean --force 2>$null
    Write-Host "  npm-пакеты удалены." -ForegroundColor Green
} else {
    Write-Host "  npm не установлен — пропускаю." -ForegroundColor Yellow
}

# ── 4. Удаление ВСЕХ файлов и директорий ──────────────────────────────────

Write-Host "[4/7] Удаляю все файлы и директории OpenClaw..." -ForegroundColor Green

$dirsToRemove = @(
    # Конфиг-директории
    "$env:USERPROFILE\.openclaw",
    "$env:USERPROFILE\.clawdbot",
    "$env:USERPROFILE\.moltbot",
    "$env:USERPROFILE\.molthub",
    "$env:USERPROFILE\molthub-cache",
    # AppData
    "$env:APPDATA\openclaw",
    "$env:APPDATA\clawdbot",
    "$env:APPDATA\moltbot",
    "$env:LOCALAPPDATA\openclaw",
    "$env:LOCALAPPDATA\clawdbot",
    "$env:LOCALAPPDATA\moltbot",
    # Рабочие директории
    "$env:USERPROFILE\openclaw",
    "$env:USERPROFILE\clawdbot",
    "$env:USERPROFILE\moltbot",
    "$env:USERPROFILE\Documents\openclaw",
    "$env:USERPROFILE\Documents\clawdbot",
    "$env:USERPROFILE\Desktop\openclaw",
    # Temp
    "$env:TEMP\openclaw",
    "$env:TEMP\clawdbot"
)

foreach ($dir in $dirsToRemove) {
    if (Test-Path $dir) {
        Remove-Item -Path $dir -Recurse -Force
        Write-Host "  Удалено: $dir" -ForegroundColor Yellow
    }
}

Write-Host "  Файлы удалены." -ForegroundColor Green

# ── 5. Планировщик задач ──────────────────────────────────────────────────

Write-Host "[5/7] Проверяю планировщик задач..." -ForegroundColor Green

$tasks = Get-ScheduledTask | Where-Object { $_.TaskName -match "openclaw|clawdbot|moltbot" }
if ($tasks) {
    $tasks | ForEach-Object {
        Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false
        Write-Host "  Удалена задача: $($_.TaskName)" -ForegroundColor Yellow
    }
}
Write-Host "  Планировщик очищен." -ForegroundColor Green

# ── 6. Переменные окружения ───────────────────────────────────────────────

Write-Host "[6/7] Очищаю переменные окружения..." -ForegroundColor Green

$envVarsToCheck = @(
    "OPENCLAW_GATEWAY_TOKEN",
    "OPENCLAW_HOST",
    "OPENCLAW_PORT",
    "OPENCLAW_HOME_VOLUME",
    "OPENCLAW_EXTRA_MOUNTS",
    "CLAWDBOT_TOKEN",
    "MOLTBOT_TOKEN"
)

foreach ($var in $envVarsToCheck) {
    $userVal = [Environment]::GetEnvironmentVariable($var, "User")
    $machineVal = [Environment]::GetEnvironmentVariable($var, "Machine")
    if ($userVal) {
        [Environment]::SetEnvironmentVariable($var, $null, "User")
        Write-Host "  Удалена переменная (User): $var" -ForegroundColor Yellow
    }
    if ($machineVal) {
        [Environment]::SetEnvironmentVariable($var, $null, "Machine")
        Write-Host "  Удалена переменная (Machine): $var" -ForegroundColor Yellow
    }
}

# Проверяем PATH — убираем пути с openclaw
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -match "openclaw|clawdbot|moltbot") {
    $cleanPath = ($userPath -split ";" | Where-Object { $_ -notmatch "openclaw|clawdbot|moltbot" }) -join ";"
    [Environment]::SetEnvironmentVariable("Path", $cleanPath, "User")
    Write-Host "  PATH очищен от openclaw" -ForegroundColor Yellow
}

Write-Host "  Переменные очищены." -ForegroundColor Green

# ── 7. Финальная проверка ─────────────────────────────────────────────────

Write-Host "[7/7] Финальная проверка..." -ForegroundColor Green
Write-Host ""

$clean = $true

# Процессы
if (Get-Process -Name "openclaw","clawdbot","moltbot" -ErrorAction SilentlyContinue) {
    Write-Host "  ОШИБКА: Найдены запущенные процессы!" -ForegroundColor Red
    $clean = $false
}

# Docker
if ($dockerPath) {
    $leftover = docker ps -a 2>$null | Select-String "openclaw|clawdbot|moltbot"
    if ($leftover) {
        Write-Host "  ОШИБКА: Найдены Docker-контейнеры!" -ForegroundColor Red
        $clean = $false
    }
}

# npm
if ($npmPath) {
    $npmLeftover = & npm list -g 2>$null | Select-String "openclaw|clawdbot|moltbot"
    if ($npmLeftover) {
        Write-Host "  ОШИБКА: Найдены npm-пакеты!" -ForegroundColor Red
        $clean = $false
    }
}

# Бинарник
if (Get-Command openclaw -ErrorAction SilentlyContinue) {
    Write-Host "  ОШИБКА: openclaw всё ещё в PATH!" -ForegroundColor Red
    $clean = $false
}

# Директории
foreach ($dir in @("$env:USERPROFILE\.openclaw", "$env:USERPROFILE\.clawdbot", "$env:USERPROFILE\.moltbot")) {
    if (Test-Path $dir) {
        Write-Host "  ОШИБКА: Остался каталог $dir!" -ForegroundColor Red
        $clean = $false
    }
}

Write-Host ""
if ($clean) {
    Write-Host "============================================" -ForegroundColor Green
    Write-Host " ГОТОВО! OpenClaw полностью удалён."         -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
} else {
    Write-Host "============================================" -ForegroundColor Yellow
    Write-Host " Есть остатки — проверьте ошибки выше."      -ForegroundColor Yellow
    Write-Host "============================================" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "ВАЖНО: Не забудьте отозвать OAuth-токены вручную:" -ForegroundColor Cyan
Write-Host "  - Google:   https://myaccount.google.com/permissions"
Write-Host "  - Discord:  Server Settings > Integrations"
Write-Host "  - Telegram: через @BotFather — /deletebot"
Write-Host "  - Slack:    Workspace App Management"
Write-Host "  - API:      Anthropic, OpenAI и др. дашборды"
Write-Host ""
