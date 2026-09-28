#!/bin/bash

# ==============================================================================
# Настройка VPS Ubuntu 24.04 с защитой от блокировки
# ==============================================================================

# --- Настройки (можно изменить) ---
NEW_USER="user1"
SSH_PORT="2332"
TIMEZONE="Europe/Berlin"
GITHUB_USER="rzhestkov"
REPO_NAME="tuning-VPS"
SSH_KEY_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${REPO_NAME}/main/ssh/authorized_keys"

# Интерактивные средства для ручной диагностики и настройки VPS. Они не
# запускают службы в фоне; список установлен явно, чтобы не зависеть от образа
# конкретного хостера и не превращать финальный отчёт в перечень случайных пакетов.
ADMIN_TOOLS=(
    mc tmux nano htop ncdu lsof jq ripgrep dnsutils netcat-openbsd rsync
    curl wget git
)

# Получение IPv4 сервера (один раз в начале скрипта)
SERVER_IP=$(
    curl -4 -fsS --max-time 5 ifconfig.me 2>/dev/null ||
    ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}' ||
    hostname -I | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1
)

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Массив для результатов диагностики
declare -a CHECKS

# Состояния опциональных компонентов
DOCKER_STATE="not-installed"
DOCKER_USER_ACCESS="not-requested"

# Функция логирования
log() {
    echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[ВНИМАНИЕ]${NC} $1"
}

error() {
    echo -e "${RED}[ОШИБКА]${NC} $1"
}

# UFW выводим в C locale: дальнейшие проверки не должны зависеть от языка VPS.
# Функция ищет только IPv4 allow rule, а не похожее IPv6-правило.
ufw_rule_exists() {
    local port=$1
    LC_ALL=C ufw status 2>/dev/null |
        awk -v port="$port" '$1 == port && $2 == "ALLOW" && $0 !~ /\(v6\)/ { found=1 } END { exit !found }'
}

# Базовый сценарий владеет только своим SSH-правилом. Другие allow rules могут
# принадлежать хостеру или приложению, поэтому их нельзя удалять автоматически.
ufw_unexpected_ipv4_allow_rules() {
    LC_ALL=C ufw status 2>/dev/null |
        awk -v ssh_port="$SSH_PORT/tcp" '
            $2 == "ALLOW" && $0 !~ /\(v6\)/ && $1 != ssh_port { print }
        '
}

report_ufw_unexpected_rules() {
    local rules count
    rules=$(ufw_unexpected_ipv4_allow_rules)
    count=$(awk 'NF { count++ } END { print count + 0 }' <<< "$rules")
    if [ "$count" -gt 0 ]; then
        warn "Обнаружены $count внешних IPv4 allow-правил UFW; базовый скрипт их не изменял:"
        printf '%s\n' "$rules"
        add_result "WARN" "UFW" "сохранены $count внешних IPv4 allow-правил"
    else
        add_result "OK" "UFW" "активен; базовое входящее правило только для SSH $SSH_PORT/tcp"
    fi
}

# Docker публикует порты напрямую через firewall backend и может обойти UFW.
# Выводятся только имена контейнеров и опубликованные порты, без логов/секретов.
report_docker_network_exposure() {
    local published count
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        return 0
    fi
    published=$(docker ps --format '{{.Names}} {{.Ports}}' |
        awk '/0\.0\.0\.0:|\[::\]:|:::/ { print }')
    count=$(awk 'NF { count++ } END { print count + 0 }' <<< "$published")
    if [ "$count" -gt 0 ]; then
        warn "Docker публикует порты наружу; UFW может не ограничивать эти подключения:"
        printf '%s\n' "$published"
        add_result "WARN" "Docker network" "$count контейнер(ов) публикуют порты; проверьте bind и DOCKER-USER"
    else
        add_result "OK" "Docker network" "внешние опубликованные порты контейнеров не обнаружены"
    fi
}

# Docker по умолчанию может хранить json-file логи без ограничения. Для новых
# контейнеров задаём local driver с ротацией. Существующий daemon не
# перезапускаем: это могло бы остановить чужие контейнеры во время rerun.
DOCKER_LOGGING_CHANGED=false
DOCKER_LOGGING_CONFLICT=""
DOCKER_LOGGING_CONFIGURED_DURING_INSTALL=false
configure_docker_logging() {
    local config output status
    config=/etc/docker/daemon.json
    DOCKER_LOGGING_CHANGED=false
    DOCKER_LOGGING_CONFLICT=""
    install -d -m 0755 /etc/docker || return 1
    output=$(python3 - "$config" <<'PY'
import json
import os
import sys
import tempfile

path = sys.argv[1]
expected_driver = "local"
expected_opts = {"max-size": "10m", "max-file": "3", "compress": "true"}

if os.path.exists(path):
    try:
        with open(path, encoding="utf-8") as source:
            config = json.load(source)
    except (OSError, ValueError) as error:
        raise SystemExit(f"cannot read valid JSON from daemon.json: {error}")
    if not isinstance(config, dict):
        raise SystemExit("daemon.json must contain a JSON object")
else:
    config = {}

driver = config.get("log-driver")
if driver not in (None, expected_driver):
    raise SystemExit(f"existing log-driver {driver!r} is not {expected_driver!r}")
options = config.get("log-opts", {})
if not isinstance(options, dict):
    raise SystemExit("existing log-opts is not a JSON object")
for key, value in expected_opts.items():
    if key in options and str(options[key]) != value:
        raise SystemExit(f"existing log-opts[{key!r}] differs from {value!r}")

changed = driver != expected_driver or any(options.get(key) != value for key, value in expected_opts.items())
if changed:
    config["log-driver"] = expected_driver
    config["log-opts"] = {**options, **expected_opts}
    fd, temporary = tempfile.mkstemp(prefix=".tuning-vps-daemon.", dir=os.path.dirname(path), text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as destination:
            json.dump(config, destination, indent=2, sort_keys=True)
            destination.write("\n")
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    except BaseException:
        os.unlink(temporary)
        raise
print("changed" if changed else "already-configured")
PY
    )
    status=$?
    if [ "$status" -eq 0 ]; then
        [ "$output" = changed ] && DOCKER_LOGGING_CHANGED=true
        return 0
    fi
    DOCKER_LOGGING_CONFLICT=${output:-"не удалось подготовить /etc/docker/daemon.json"}
    return 1
}

report_docker_logging_policy() {
    local driver
    if ! command -v docker >/dev/null 2>&1; then
        return 0
    fi
    if [ -n "$DOCKER_LOGGING_CONFLICT" ]; then
        add_result "WARN" "Docker logs" "существующая политика не изменена: $DOCKER_LOGGING_CONFLICT"
    elif [ "$DOCKER_LOGGING_CHANGED" = true ]; then
        if docker info >/dev/null 2>&1; then
            add_result "WARN" "Docker logs" "local driver с лимитом 10M × 3 подготовлен; работающий daemon не перезапускался"
        else
            add_result "OK" "Docker logs" "local driver с лимитом 10M × 3 будет применён при следующем запуске daemon"
        fi
    elif [ -f /etc/docker/daemon.json ]; then
        driver=$(docker info --format '{{.LoggingDriver}}' 2>/dev/null || true)
        if [ "$driver" = local ]; then
            add_result "OK" "Docker logs" "ротация local 10M × 3 настроена и активна"
        elif [ -n "$driver" ]; then
            add_result "WARN" "Docker logs" "в daemon.json задан local 10M × 3, но активен $driver; нужен плановый restart Docker"
        else
            add_result "OK" "Docker logs" "local 10M × 3 подготовлен и будет применён при следующем запуске daemon"
        fi
    fi
}

# Функции добавления результатов проверки
add_result() {
    local status=$1
    local component=$2
    local detail=$3
    local color=$NC

    case "$status" in
        OK) color=$GREEN ;;
        WARN|SKIP) color=$YELLOW ;;
        FAIL) color=$RED ;;
    esac

    CHECKS+=("${color}[$status]${NC} $component: $detail")
}

# Совместимость с ранее реализованными блоками.
add_check() {
    local status=$1
    local message=$2
    if [ "$status" -eq 0 ]; then
        add_result "OK" "$message" "проверка пройдена"
    else
        add_result "FAIL" "$message" "проверка не пройдена"
    fi
}

replace_managed_section() {
    local file=$1
    local section=$2
    local content_file=$3
    local begin="# BEGIN tuning-VPS managed section: $section"
    local end="# END tuning-VPS managed section: $section"
    local temp_file

    temp_file=$(mktemp)
    awk -v begin="$begin" -v end="$end" '
        $0 == begin { managed=1; next }
        $0 == end { managed=0; next }
        !managed { print }
    ' "$file" > "$temp_file"

    {
        cat "$temp_file"
        echo ""
        echo "$begin"
        cat "$content_file"
        echo "$end"
    } > "$file"
    rm -f "$temp_file"
}

detect_docker_state() {
    if ! command -v docker &>/dev/null; then
        DOCKER_STATE="not-installed"
    elif docker info &>/dev/null; then
        DOCKER_STATE="installed-running"
    else
        DOCKER_STATE="installed-stopped"
    fi
}

# Функция проверки пакета (всегда возвращает 0 для set -e)
# Использует специальную логику для пакетов с нестандартным выводом версии
check_pkg() {
    local pkg=$1
    local name=${2:-$1}
    if command -v "$pkg" &>/dev/null; then
        local version=""
        
        # Специальная обработка для пакетов с нестандартным выводом версии
        case "$pkg" in
            git)
                version=$($pkg --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
                ;;
            node)
                version=$($pkg --version 2>/dev/null | tr -d 'v')
                ;;
            npm)
                version=$($pkg --version 2>/dev/null)
                ;;
            pip3|pip)
                # pip3 --version: "pip 21.2 from /path (python 3.10)" - версия первое слово
                version=$($pkg --version 2>/dev/null | awk '{print $2}')
                ;;
            docker)
                version=$($pkg --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')
                ;;
            python3|python)
                version=$($pkg --version 2>/dev/null | cut -d' ' -f2)
                ;;
            *)
                # Универсальный метод для остальных пакетов
                version=$($pkg --version 2>/dev/null | head -1 | awk '{print $NF}')
                ;;
        esac
        
        # Если версия пустая, используем "установлен"
        [ -z "$version" ] && version="установлен"
        
        printf "  ${GREEN}✓${NC} %-15s %s\n" "$name" "$version"
        return 0
    else
        printf "  ${RED}✗${NC} %-15s %s\n" "$name" "-"
        return 0
    fi
}

# Функция проверки сервиса (всегда возвращает 0 для set -e)
check_service() {
    local svc=$1
    local name=${2:-$1}
    if systemctl is-active "$svc" &>/dev/null; then
        printf "  ${GREEN}✓${NC} %-15s %s\n" "$name" "(active)"
    elif dpkg -l | grep -q "^ii  $svc"; then
        printf "  ${YELLOW}○${NC} %-15s %s\n" "$name" "(installed, stopped)"
    else
        printf "  ${RED}✗${NC} %-15s %s\n" "$name" "-"
    fi
    return 0
}

file_contains() {
    local file=$1
    local pattern=$2
    grep -qE "$pattern" "$file" 2>/dev/null
}

# 01. ПРОВЕРКИ ПЕРЕД СТАРТОМ ====================================================

log "=== Начало настройки VPS ==="
log "Проверка окружения..."

# Проверка root
if [ "$EUID" -ne 0 ]; then 
    error "Запустите скрипт через sudo или от root"
    exit 1
fi

# Проверка Ubuntu
if ! grep -q "Ubuntu" /etc/os-release; then
    error "Это не Ubuntu. Скрипт рассчитан на Ubuntu"
    exit 1
fi

# Проверка версии Ubuntu 24.04
UBUNTU_VERSION=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2)
if [ "$UBUNTU_VERSION" != "24.04" ]; then
    warn "Внимание: скрипт протестирован на Ubuntu 24.04, у вас $UBUNTU_VERSION"
    warn "Поведение может отличаться (sshd_config.d, cloud-init, ssh.socket)"
fi

# Проверка имени пользователя (пункт 33)
if ! [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    error "Некорректное имя пользователя: $NEW_USER"
    error "Имя должно начинаться с буквы или подчеркивания, содержать только a-z, 0-9, _, - и быть длиной до 32 символов"
    exit 1
fi

# Проверка номера SSH порта (пункт 34)
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1024 ] || [ "$SSH_PORT" -gt 65535 ]; then
    error "Некорректный SSH-порт: $SSH_PORT (допустимый диапазон: 1024–65535)"
    exit 1
fi

# Проверка подключения к GitHub

if ! curl -s --head "$SSH_KEY_URL" | head -n 1 | grep -q "200\|301\|302"; then
    error "Не могу получить доступ к GitHub. Проверьте GITHUB_USER и REPO_NAME"
    error "URL: $SSH_KEY_URL"
    exit 1
fi

# SSH проверяется до обновления пакетов и любых правок: повторный запуск на уже
# защищённом сервере не должен сначала что-то изменить, а потом требовать порт 22.
SSHD_CONFIG=/etc/ssh/sshd_config
SSH_MANAGED_CONFIG=/etc/ssh/tuning-vps.conf
ssh_port_listening() {
    ss -4 -H -ltn 2>/dev/null | awk -v port="$1" '
        { endpoint=$4; sub(/^.*:/, "", endpoint); if (endpoint == port) found=1 }
        END { exit !found }
    '
}
ssh_service_port_listening() {
    # После переключения на ssh.service порт должен принадлежать самому sshd,
    # а не постороннему процессу с тем же номером.
    ss -4 -H -ltnp 2>/dev/null | awk -v port="$1" '
        { endpoint=$4; sub(/^.*:/, "", endpoint); if (endpoint == port && /"sshd"/) found=1 }
        END { exit !found }
    '
}
# Ubuntu may start SSH through ssh.socket. Stopping the socket alone can leave
# its spawned listener alive while an administrator is connected. Kill only
# sshd processes that own a listening socket; established shell processes do
# not appear in this list and therefore keep the current recovery session.
stop_sshd_listeners_on_port() {
    local port=$1 pids pid command
    pids=$(ss -4 -H -ltnp 2>/dev/null | awk -v port="$port" '
        { endpoint=$4; sub(/^.*:/, "", endpoint) }
        endpoint == port && /"sshd",pid=[0-9]+/ {
            match($0, /pid=[0-9]+/)
            print substr($0, RSTART + 4, RLENGTH - 4)
        }
    ' | sort -u)
    for pid in $pids; do
        command=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d '[:space:]')
        [ "$command" = sshd ] || return 1
        kill -TERM "$pid" || return 1
    done
    [ -z "$pids" ] || sleep 1
    ! ssh_port_listening "$port"
}
ssh_unit_is_stopped() {
    local state
    state=$(systemctl is-active "$1" 2>/dev/null || true)
    [ "$state" = inactive ] || [ "$state" = failed ]
}

# Switch from either service or socket activation to ssh.service. A failed
# socket unit is reset explicitly, because systemd otherwise treats it as a
# failed dependency for ssh.service on the next attempt.
stop_socket_activated_ssh_listener() {
    systemctl disable ssh.socket >/dev/null 2>&1 || return 1
    systemctl stop ssh.socket >/dev/null 2>&1 ||
        ssh_unit_is_stopped ssh.socket || return 1
    systemctl stop ssh.service >/dev/null 2>&1 ||
        ssh_unit_is_stopped ssh.service || return 1
    stop_sshd_listeners_on_port "$SSH_ORIGINAL_PORT" || {
        error "Не удалось остановить SSH listener на порту $SSH_ORIGINAL_PORT."
        return 1
    }
    systemctl reset-failed ssh.socket >/dev/null 2>&1 || return 1
}
restore_socket_activated_ssh() {
    systemctl stop ssh.service >/dev/null 2>&1 ||
        ssh_unit_is_stopped ssh.service || return 1
    stop_sshd_listeners_on_port "$SSH_PORT" || return 1
    systemctl reset-failed ssh.socket >/dev/null 2>&1 || return 1
    systemctl start ssh.socket >/dev/null 2>&1
}
ssh_context_value() {
    local user=$1 port=$2 option=$3
    sshd -T -C "user=$user,host=${SSH_CLIENT_ADDR:-127.0.0.1},addr=${SSH_CLIENT_ADDR:-127.0.0.1},lport=$port" 2>/dev/null |
        awk -v option="$option" '$1 == option { print $2; exit }'
}
ssh_effective_port() {
    sshd -T 2>/dev/null | awk -v port="$1" '$1 == "port" && $2 == port { found=1 } END { exit !found }'
}
detect_current_ssh_port() {
    local port pid ppid socket_line
    if [ -n "${SSH_CONNECTION:-}" ]; then
        port=$(awk 'NF >= 4 {print $4}' <<< "$SSH_CONNECTION")
        [[ "$port" =~ ^[0-9]+$ ]] && { printf '%s\n' "$port"; return 0; }
    fi
    if [ -n "${SSH_CLIENT:-}" ]; then
        port=$(awk 'NF >= 3 {print $3}' <<< "$SSH_CLIENT")
        [[ "$port" =~ ^[0-9]+$ ]] && { printf '%s\n' "$port"; return 0; }
    fi
    # sudo/su часто очищает SSH_*; пытаемся найти сокет родительского sshd.
    pid=$$
    while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
        socket_line=$(ss -tnpH 2>/dev/null | awk -v pid="$pid" '$0 ~ ("pid=" pid ",") {print; exit}')
        port=$(awk '{print $4}' <<< "$socket_line" | sed -nE 's/.*:([0-9]+)$/\1/p')
        [[ "$port" =~ ^[0-9]+$ ]] && { printf '%s\n' "$port"; return 0; }
        ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | awk '{print $1}')
        [ -n "$ppid" ] && [ "$ppid" != "$pid" ] || break
        pid=$ppid
    done
    return 1
}

if [ ! -f "$SSHD_CONFIG" ] || ! sshd -t >/dev/null 2>&1; then
    error "Исходная SSH-конфигурация отсутствует или не проходит sshd -t."
    exit 1
fi
SSH_CLIENT_ADDR=$(awk 'NF >= 1 {print $1}' <<< "${SSH_CONNECTION:-${SSH_CLIENT:-}}")
[[ "$SSH_CLIENT_ADDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || SSH_CLIENT_ADDR=127.0.0.1
if CURRENT_SSH_PORT=$(detect_current_ssh_port); then
    if [ "$CURRENT_SSH_PORT" != 22 ] && [ "$CURRENT_SSH_PORT" != "$SSH_PORT" ]; then
        error "Текущая SSH-сессия использует порт $CURRENT_SSH_PORT; ожидаются 22 или $SSH_PORT."
        exit 1
    fi
else
    if ssh_port_listening 22 && ssh_port_listening "$SSH_PORT"; then
        error "Порт текущей SSH-сессии не определён при двух активных портах."
        error "Запустите из SSH-сессии с сохранённым SSH_CONNECTION или используйте консоль хостера."
        exit 1
    fi
    warn "Порт текущей SSH-сессии не определён; проверяем единственный IPv4 listener."
fi
if ssh_port_listening 22; then
    SSH_ACCESS_MODE=transition
elif ssh_port_listening "$SSH_PORT" &&
     ssh_effective_port "$SSH_PORT" && ! ssh_effective_port 22 &&
     [ "$(ssh_context_value root "$SSH_PORT" permitrootlogin)" = no ] &&
     [ "$(ssh_context_value "$NEW_USER" "$SSH_PORT" passwordauthentication)" = no ] &&
     [ "$(ssh_context_value "$NEW_USER" "$SSH_PORT" kbdinteractiveauthentication)" = no ] &&
     [ "$(ssh_context_value "$NEW_USER" "$SSH_PORT" pubkeyauthentication)" = yes ]; then
    SSH_ACCESS_MODE=final
else
    error "SSH не находится ни в исходном состоянии с портом 22, ни в проверенном финальном состоянии."
    error "Конфигурация оставлена без изменений; нужна диагностика доступа через консоль хостера."
    exit 1
fi
log "Обнаружено состояние SSH: $SSH_ACCESS_MODE"

# 02. ОБНОВЛЕНИЕ СИСТЕМЫ =======================================================

log "Обновление пакетов..."

# Проверка свободного места на диске перед установкой пакетов (пункт 35)
AVAILABLE_SPACE=$(df / --output=avail -BM | tail -1 | tr -d 'M')
if [ "$AVAILABLE_SPACE" -lt 1024 ]; then
    error "Недостаточно места на диске: ${AVAILABLE_SPACE}MB (нужно минимум 1GB)"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

apt-get upgrade -y -qq
UPDATE_RESULT=$?

# Набор нужен для ручного обслуживания после завершения скрипта. apt сам
# пропускает уже установленные версии, поэтому повторный запуск безопасен.
log "Установка инструментов администрирования..."
if ! apt-get install -y -qq "${ADMIN_TOOLS[@]}"; then
    error "Не удалось установить набор инструментов администрирования"
    exit 1
fi

add_check $UPDATE_RESULT "Обновление системы"
add_result "OK" "Admin tools" "mc, tmux, nano, htop, ncdu, lsof, jq, ripgrep, DNS, TCP и rsync"

# 03. ОТКЛЮЧЕНИЕ НЕНУЖНЫХ СИСТЕМНЫХ СЕРВИСОВ ==================================

log "Отключение ненужных системных сервисов..."

# Массив для отслеживания статуса отключения
SERVICES_DISABLED=0

## 03.1. Отключаем snapd (если не используется)
if systemctl is-enabled snapd &>/dev/null; then
    log "Отключение snapd..."
    systemctl stop snapd 2>/dev/null || true
    systemctl disable snapd 2>/dev/null || true
    SERVICES_DISABLED=$((SERVICES_DISABLED + 1))
fi

## 03.2. Отключаем apport (автоматическая отчетность об ошибках)
if systemctl is-enabled apport &>/dev/null; then
    log "Отключение apport..."
    systemctl stop apport 2>/dev/null || true
    systemctl disable apport 2>/dev/null || true
    SERVICES_DISABLED=$((SERVICES_DISABLED + 1))
fi

## 03.3. Отключаем whoopsie (отправка отчетов об ошибках)
if systemctl is-enabled whoopsie &>/dev/null; then
    log "Отключение whoopsie..."
    systemctl stop whoopsie 2>/dev/null || true
    systemctl disable whoopsie 2>/dev/null || true
    SERVICES_DISABLED=$((SERVICES_DISABLED + 1))
fi

## 03.4. Отключаем lxd (если не используется)
if systemctl is-enabled lxd &>/dev/null; then
    log "Отключение lxd..."
    systemctl stop lxd 2>/dev/null || true
    systemctl disable lxd 2>/dev/null || true
    SERVICES_DISABLED=$((SERVICES_DISABLED + 1))
fi

## 03.5. Отключаем udisks2 (автоматическое монтирование дисков, не нужно на VPS)
if systemctl is-enabled udisks2 &>/dev/null; then
    log "Отключение udisks2..."
    systemctl stop udisks2 2>/dev/null || true
    systemctl disable udisks2 2>/dev/null || true
    SERVICES_DISABLED=$((SERVICES_DISABLED + 1))
fi

log "Отключено $SERVICES_DISABLED ненужных сервисов"
SERVICES_VALIDATION_OK=0
for svc in snapd apport whoopsie lxd udisks2; do
    if systemctl is-enabled "$svc" 2>/dev/null | grep -q "^enabled"; then
        SERVICES_VALIDATION_OK=1
        break
    fi
done
add_check $SERVICES_VALIDATION_OK "Отключение ненужных сервисов"

# 04. НАСТРОЙКА ВРЕМЕННОЙ ЗОНЫ И NTP ===========================================

log "Настройка временной зоны и синхронизации времени..."

# Установка временной зоны (используется TIMEZONE из настроек)
log "Установка временной зоны: $TIMEZONE"
timedatectl set-timezone "$TIMEZONE" 2>/dev/null || true

# Проверка и настройка systemd-timesyncd
if systemctl is-active systemd-timesyncd &>/dev/null; then
    log "systemd-timesyncd активен, проверяем синхронизацию..."
    systemctl enable systemd-timesyncd 2>/dev/null || true
    systemctl start systemd-timesyncd 2>/dev/null || true
    
    # Принудительная синхронизация
    timedatectl set-ntp true 2>/dev/null || true
    
    sleep 2
    
    # Проверка статуса
    if timedatectl status | grep -q "System clock synchronized: yes"; then
        log "Время синхронизировано"
        add_check 0 "Синхронизация времени (NTP)"
    else
        warn "Время не синхронизировано, пробуем принудительно..."
        # Альтернативный метод синхронизации
        if command -v ntpdate &>/dev/null; then
            ntpdate -s time.windows.com 2>/dev/null || ntpdate -s pool.ntp.org 2>/dev/null || true
        fi
        add_check 1 "Синхронизация времени (NTP)"
    fi
else
    warn "systemd-timesyncd не активен, устанавливаем..."
    apt-get install -y -qq systemd-timesyncd
    systemctl enable systemd-timesyncd
    systemctl start systemd-timesyncd
    timedatectl set-ntp true
    add_check 0 "Установка systemd-timesyncd"
fi

# Проверка текущего времени
CURRENT_TIME=$(timedatectl | grep "Local time" | cut -d: -f2- | xargs)
CURRENT_TIMEZONE=$(timedatectl | grep "Time zone" | awk '{print $3}')
log "Текущее время: $CURRENT_TIME ($CURRENT_TIMEZONE)"

# 05. ХАРДЕНИНГ СИСТЕМНЫХ ПАРАМЕТРОВ ЯДРА (SYSCTL) =============================

log "Настройка hardening системных параметров ядра..."

# Базовый скрипт владеет только этим файлом. Он не переписывает sysctl.conf
# хостера и применяет только свои параметры, не загружая чужие sysctl.d-файлы.
SYSCTL_CONFIG=/etc/sysctl.d/99-hardening.conf
SYSCTL_NEW=$(mktemp /etc/sysctl.d/.tuning-vps-hardening.XXXXXXXX) || exit 1
SYSCTL_BACKUP=""
SYSCTL_HAD_CONFIG=false
if [ -e "$SYSCTL_CONFIG" ]; then
    SYSCTL_BACKUP=$(mktemp /etc/sysctl.d/.tuning-vps-hardening-backup.XXXXXXXX) || exit 1
    cp -p "$SYSCTL_CONFIG" "$SYSCTL_BACKUP" || exit 1
    SYSCTL_HAD_CONFIG=true
fi

cat > "$SYSCTL_NEW" << 'EOF'
# Managed by setup_ubuntu_24.04.sh.
# Этот файл не задаёт ip_forward и rp_filter. Forwarding, rp_filter, маршруты
# и NAT принадлежат модулю VPN либо Docker и не должны сбрасываться при rerun.

# Защита от SYN-flood
net.ipv4.tcp_syncookies = 1

# IPv6 не используется в этой конфигурации: уменьшаем поверхность атаки.
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# Ограничение ICMP
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Ограничение доступа к kernel logs
kernel.dmesg_restrict = 1

# Защита от symlink attacks
fs.protected_hardlinks = 1
fs.protected_symlinks = 1

# ASLR
kernel.randomize_va_space = 2

# Маршрутизатор не должен принимать source routes и ICMP redirects, а также
# отправлять redirects между VPN-клиентами и внешней сетью.
net.ipv4.tcp_rfc1337 = 1
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Автоматическая перезагрузка при kernel panic
kernel.panic = 10
kernel.panic_on_oops = 1
EOF

# Сначала заменяем только наш файл, затем применяем именно его. При отказе
# возвращаем прежний файл; удалённые ip_forward/rp_filter не трогаем даже при
# миграции со старой версии, чтобы не угадывать политику уже установленного VPN.
if ! cmp -s "$SYSCTL_NEW" "$SYSCTL_CONFIG"; then
    install -m 0644 "$SYSCTL_NEW" "$SYSCTL_CONFIG" || exit 1
fi
rm -f "$SYSCTL_NEW"

# Проверяем все назначенные значения из нашего файла, а не только один
# показательный параметр. Это не проверяет ip_forward/rp_filter: они намеренно
# исключены из области ответственности базового скрипта.
sysctl_config_is_applied() {
    local key expected actual
    while IFS='=' read -r key expected; do
        actual=$(sysctl -n "$key" 2>/dev/null) || return 1
        [ "$actual" = "$expected" ] || return 1
    done < <(awk -F= '
        /^[[:space:]]*[^#[:space:]][^=]*=/ {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
            print $1 "=" $2
        }
    ' "$SYSCTL_CONFIG")
}

if SYSCTL_APPLY_OUTPUT=$(sysctl -p "$SYSCTL_CONFIG" 2>&1); then
    SYSCTL_APPLY_OK=true
else
    SYSCTL_APPLY_OK=false
fi
if [ "$SYSCTL_APPLY_OK" != true ] ||
   ! sysctl_config_is_applied ||
   grep -qE '^[[:space:]]*net\.ipv4\.(ip_forward|conf\.(all|default)\.rp_filter)[[:space:]]*=' "$SYSCTL_CONFIG"; then
    error "Не удалось применить или проверить управляемые sysctl-параметры."
    if [ "$SYSCTL_APPLY_OK" != true ]; then
        printf '%s\n' "$SYSCTL_APPLY_OUTPUT"
    fi
    if [ "$SYSCTL_HAD_CONFIG" = true ]; then
        # Старый файл мог быть создан предыдущей версией и содержать
        # ip_forward=0/rp_filter=1. Их нельзя вернуть ни на диск, ни runtime.
        SYSCTL_RESTORE=$(mktemp /etc/sysctl.d/.tuning-vps-hardening-restore.XXXXXXXX) || exit 1
        awk '
            !/^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=/ &&
            !/^[[:space:]]*net\.ipv4\.conf\.(all|default)\.rp_filter[[:space:]]*=/ { print }
        ' "$SYSCTL_BACKUP" > "$SYSCTL_RESTORE" || error "Не удалось подготовить безопасное восстановление sysctl."
        if install -m 0644 "$SYSCTL_RESTORE" "$SYSCTL_CONFIG"; then
            sysctl -p "$SYSCTL_RESTORE" >/dev/null 2>&1 ||
                error "Не удалось применить восстановленный sysctl-файл."
        else
            error "Не удалось восстановить sysctl-файл."
        fi
        rm -f "$SYSCTL_RESTORE"
    else
        rm -f "$SYSCTL_CONFIG"
    fi
    add_check 1 "Hardening ядра (sysctl)"
else
    log "Управляемые параметры ядра применены; forwarding и rp_filter не изменялись."
    add_check 0 "Hardening ядра (sysctl)"
fi
rm -f "$SYSCTL_BACKUP"

# 06. СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ ====================================================

log "Создание пользователя $NEW_USER..."

USER_EXISTS=false
USER_CREATED=false

if id "$NEW_USER" &>/dev/null; then
    warn "Пользователь $NEW_USER уже существует, пропускаем создание"
    USER_EXISTS=true
else
    # Создаем пользователя без пароля (вход только по ключу)
    # Сохраняем результат useradd для проверки
    if useradd -m -s /bin/bash "$NEW_USER"; then
        USER_CREATED=true
        usermod -aG sudo "$NEW_USER" || true
        
        # Блокируем пароль для пользователя (вход только по SSH-ключу)
        passwd -l "$NEW_USER" 2>/dev/null || true
        
        log "Пользователь $NEW_USER создан. Вход только по SSH-ключу."
    else
        error "Не удалось создать пользователя $NEW_USER"
        exit 1
    fi
fi

# Администрирование должно работать и при повторном запуске для уже существующего
# пользователя. Непроверенный sudo нельзя оставлять до отключения root-входа.
usermod -aG sudo "$NEW_USER" || { error "Не удалось назначить sudo пользователю $NEW_USER"; exit 1; }
SUDOERS_FILE="/etc/sudoers.d/99-$NEW_USER"
SUDOERS_NEW=$(mktemp)
printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$NEW_USER" > "$SUDOERS_NEW"
chmod 440 "$SUDOERS_NEW"
if ! visudo -c -f "$SUDOERS_NEW" >/dev/null 2>&1; then
    rm -f "$SUDOERS_NEW"
    error "Не прошла проверка sudoers для $NEW_USER"
    exit 1
fi
if ! cmp -s "$SUDOERS_NEW" "$SUDOERS_FILE"; then
    install -m 0440 "$SUDOERS_NEW" "$SUDOERS_FILE" || exit 1
fi
rm -f "$SUDOERS_NEW"


USER_VALIDATION_OK=0
if ! id "$NEW_USER" &>/dev/null; then
    USER_VALIDATION_OK=1
fi
if ! id -nG "$NEW_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "sudo"; then
    USER_VALIDATION_OK=1
fi
if [ -f "/etc/sudoers.d/99-$NEW_USER" ] && ! visudo -c -f /etc/sudoers.d/99-$NEW_USER >/dev/null 2>&1; then
    USER_VALIDATION_OK=1
fi
add_check $USER_VALIDATION_OK "Пользователь $NEW_USER и sudo"
if [ "$USER_VALIDATION_OK" -ne 0 ] || ! su - "$NEW_USER" -c 'sudo -n true' >/dev/null 2>&1; then
    error "Административный доступ $NEW_USER через sudo не подтверждён."
    exit 1
fi

# 07. ОГРАНИЧЕНИЯ ДЛЯ ПОЛЬЗОВАТЕЛЯ (LIMITS.CONF) ==============================

log "Настройка и фактическая проверка ограничений пользователя..."

LIMITS_CONFIG="/etc/security/limits.conf"
LIMITS_BACKUP="${LIMITS_CONFIG}.bak.$(date +%s)"
LIMITS_SECTION=$(mktemp)
LIMITS_CONFIG_EXISTED=false
if [ -f "$LIMITS_CONFIG" ]; then
    LIMITS_CONFIG_EXISTED=true
    cp "$LIMITS_CONFIG" "$LIMITS_BACKUP"
else
    install -m 0644 /dev/null "$LIMITS_CONFIG"
fi

cat > "$LIMITS_SECTION" << EOF
# Ограничения применяются только к управляемому пользователю.
$NEW_USER soft nofile 65535
$NEW_USER hard nofile 65535
$NEW_USER soft nproc 4096
$NEW_USER hard nproc 8192
EOF

replace_managed_section "$LIMITS_CONFIG" "user-limits" "$LIMITS_SECTION"
rm -f "$LIMITS_SECTION"

LIMITS_FAILURE=""
if ! grep -RqsE '^[[:space:]]*session[[:space:]]+required[[:space:]]+pam_limits\.so' /etc/pam.d/sshd /etc/pam.d/login; then
    LIMITS_FAILURE="pam_limits.so не подключён для SSH/login-сессий"
else
    USER_NOFILE=$(su - "$NEW_USER" -c 'ulimit -n' 2>/dev/null || true)
    USER_NPROC=$(su - "$NEW_USER" -c 'ulimit -u' 2>/dev/null || true)
    if [ "$USER_NOFILE" != "65535" ] || [ "$USER_NPROC" != "4096" ]; then
        LIMITS_FAILURE="реальные лимиты user=$NEW_USER: nofile=${USER_NOFILE:-unknown}, nproc=${USER_NPROC:-unknown}"
    fi
fi

if [ -z "$LIMITS_FAILURE" ]; then
    add_result "OK" "Limits" "для $NEW_USER применены nofile=65535 и nproc=4096"
else
    if [ "$LIMITS_CONFIG_EXISTED" = true ]; then
        cp "$LIMITS_BACKUP" "$LIMITS_CONFIG"
    else
        rm -f "$LIMITS_CONFIG"
    fi
    add_result "FAIL" "Limits" "$LIMITS_FAILURE; исходный limits.conf восстановлен"
fi

# 08–11. SSH: ключи, безопасный переход, UFW и подтверждение входа ============

# Провайдерский sshd_config и его Include остаются на месте. Управляемый файл
# подключается первым: sshd берёт первое значение большинства директив. Port
# добавляется к списку, поэтому итог обязательно проверяется через sshd -T.
ssh_effective_has() {
    sshd -T 2>/dev/null | grep -qx "$1"
}
ssh_candidate_value() {
    local config=$1 user=$2 port=$3 option=$4 addr=${5:-$SSH_CLIENT_ADDR}
    sshd -T -f "$config" -C "user=$user,host=$addr,addr=$addr,lport=$port" 2>/dev/null |
        awk -v option="$option" '$1 == option {print $2; exit}'
}
ssh_candidate_port() {
    sshd -T -f "$1" 2>/dev/null |
        awk -v port="$2" '$1 == "port" && $2 == port {found=1} END {exit !found}'
}
# Port is cumulative in OpenSSH, unlike most authentication directives.  A
# stock provider config often has `Port 22` in the main file after Include;
# leaving it there would reopen 22 even though the managed file is first.
# Remove only that global baseline setting when preparing the new main file.
# Ports in provider drop-ins are intentionally left untouched: they are an
# explicit conflict which must stop the automatic transition instead of being
# guessed away.
render_main_with_managed_include() {
    local source=$1 include_file=$2 destination=$3
    {
        printf 'Include %s\n' "$include_file"
        awk '
            $0 == "Include /etc/ssh/tuning-vps.conf" { next }
            !in_match && $0 ~ /^[[:space:]]*[Pp][Oo][Rr][Tt][[:space:]=]/ { next }
            tolower($1) == "match" { in_match=1 }
            { print }
        ' "$source"
    } > "$destination"
}
report_ssh_conflict() {
    local file
    error "Конфликтующие SSH-директивы; проверьте источник ниже:"
    for file in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
        [ -f "$file" ] || continue
        grep -HniE '^[[:space:]]*(Include|Match|Port|ListenAddress|AddressFamily|PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|HostbasedAuthentication|GSSAPIAuthentication|PubkeyAuthentication|PubkeyAcceptedAlgorithms|AuthorizedKeysFile|AuthorizedKeysCommand|AuthenticationMethods|AllowUsers|DenyUsers)([[:space:]]|=)' "$file" || true
    done
}
ssh_unsafe_match_auth() {
    local file findings
    for file in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
        [ -f "$file" ] || continue
        findings=$(awk '
            tolower($1) == "match" { in_match=1; next }
            in_match && tolower($1) ~ /^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|hostbasedauthentication|gssapiauthentication|pubkeyauthentication|pubkeyacceptedalgorithms|authorizedkeysfile|authorizedkeyscommand|authenticationmethods)$/ {
                print FILENAME ":" FNR ":" $0
            }
        ' "$file")
        if [ -n "$findings" ]; then
            error "Провайдерские Match меняют аутентификацию; нужен ручной разбор:"
            printf '%s\n' "$findings"
            return 0
        fi
    done
    return 1
}
ssh_candidate_valid() {
    local config=$1 phase=$2 option before after addr
    sshd -t -f "$config" || return 1
    ssh_candidate_port "$config" "$SSH_PORT" || return 1
    [ "$(ssh_candidate_value "$config" "$NEW_USER" "$SSH_PORT" addressfamily)" = inet ] || return 1
    [ "$(ssh_candidate_value "$config" "$NEW_USER" "$SSH_PORT" pubkeyauthentication)" = yes ] || return 1
    if [ "$phase" = temporary ]; then
        ssh_candidate_port "$config" 22 || return 1
        # Временный конфиг не меняет способы входа root на исходном порту.
        for option in permitrootlogin passwordauthentication kbdinteractiveauthentication pubkeyauthentication authorizedkeysfile authenticationmethods; do
            before=$(ssh_context_value root 22 "$option")
            after=$(ssh_candidate_value "$config" root 22 "$option")
            [ "$before" = "$after" ] || { error "Временный SSH меняет root/$option"; return 1; }
            if ssh_port_listening "$SSH_PORT"; then
                before=$(ssh_context_value "$NEW_USER" "$SSH_PORT" "$option")
                after=$(ssh_candidate_value "$config" "$NEW_USER" "$SSH_PORT" "$option")
                [ "$before" = "$after" ] || { error "Временный SSH меняет $NEW_USER/$option"; return 1; }
            fi
        done
    else
        ! ssh_candidate_port "$config" 22 || return 1
        for addr in "$SSH_CLIENT_ADDR" 127.0.0.1 0.0.0.0; do
            for option in passwordauthentication kbdinteractiveauthentication hostbasedauthentication gssapiauthentication permitemptypasswords; do
                [ "$(ssh_candidate_value "$config" "$NEW_USER" "$SSH_PORT" "$option" "$addr")" = no ] || return 1
            done
            [ "$(ssh_candidate_value "$config" root "$SSH_PORT" permitrootlogin "$addr")" = no ] || return 1
            [ "$(ssh_candidate_value "$config" "$NEW_USER" "$SSH_PORT" authorizedkeysfile "$addr")" = .ssh/authorized_keys ] || return 1
            [ "$(ssh_candidate_value "$config" "$NEW_USER" "$SSH_PORT" authorizedkeyscommand "$addr")" = none ] || return 1
            [ "$(ssh_candidate_value "$config" "$NEW_USER" "$SSH_PORT" pubkeyacceptedalgorithms "$addr")" = ssh-ed25519 ] || return 1
            case "$(ssh_candidate_value "$config" "$NEW_USER" "$SSH_PORT" authenticationmethods "$addr")" in
                any|publickey) ;;
                *) return 1 ;;
            esac
        done
    fi
}

# Каждую активную строку проверяет OpenSSH; неизвестные опции и типы ключей
# не должны попасть в authorized_keys. Комментарии и пустые строки допустимы.
validate_ed25519_keys() {
    local source=$1 line keyfile
    keyfile="$SSH_WORK/keycheck"
    [ -s "$source" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^ssh-ed25519[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]] || return 1
        printf '%s\n' "$line" > "$keyfile"
        ssh-keygen -lf "$keyfile" 2>/dev/null | grep -q '(ED25519)' || return 1
    done < "$source"
    grep -qE '^ssh-ed25519[[:space:]]+' "$source"
}

SSH_HOME=$(getent passwd "$NEW_USER" | cut -d: -f6)
case "$SSH_HOME" in
    /*) ;;
    *) error "У пользователя $NEW_USER нет абсолютного домашнего каталога"; exit 1 ;;
esac
if [ "$SSH_HOME" = / ] || [ ! -d "$SSH_HOME" ] || [ -L "$SSH_HOME" ]; then
    error "Домашний каталог $NEW_USER отсутствует или небезопасен: $SSH_HOME"
    exit 1
fi
SSH_HOME_MODE=$(stat -c '%a' "$SSH_HOME") || exit 1
if (( (8#$SSH_HOME_MODE & 022) != 0 )); then
    error "Домашний каталог $SSH_HOME доступен для записи группе или всем."
    exit 1
fi
SSH_WORK=$(mktemp -d /etc/ssh/.tuning-vps.XXXXXXXX) || exit 1
chmod 700 "$SSH_WORK"
SSH_DIR=$SSH_HOME/.ssh
SSH_KEYS=$SSH_DIR/authorized_keys
SSH_PRIMARY_GROUP=$(id -gn "$NEW_USER") || exit 1
SSH_CHANGED=false
SSH_COMMITTED=false
SSH_ROLLBACK_NEEDED=false
SSH_CONFIG_TOUCHED=false
SSH_KEYS_TOUCHED=false
SSH_SYSTEMD_TOUCHED=false
SSH_ROOT_TOUCHED=false
SSH_ORIGINAL_KEYS=false
SSH_ORIGINAL_DIR=false
SSH_ORIGINAL_MANAGED=false
SSH_ORIGINAL_UFW=false
SSH_ORIGINAL_UFW_DEFAULT=false
SSH_ORIGINAL_UFW_RULES=false
SSH_ORIGINAL_UFW6_RULES=false
UFW_TEMP_RULE_CREATED=false
UFW_22_RULE_PREEXISTED=false

# На ошибке возвращаем исходные файлы, состояние firewall и systemd. Если
# проверка восстановления не прошла, сохраняем копии для консоли хостера.
restore_ssh_state() {
    local failed=false
    warn "Откат SSH/UFW к состоянию до запуска. Не закрывайте текущую сессию."
    if [ "$SSH_CONFIG_TOUCHED" = true ]; then
        cp -p "$SSH_WORK/original-main" "$SSHD_CONFIG" || failed=true
        if [ "$SSH_ORIGINAL_MANAGED" = true ]; then
            cp -p "$SSH_WORK/original-managed" "$SSH_MANAGED_CONFIG" || failed=true
        else
            rm -f "$SSH_MANAGED_CONFIG" || failed=true
        fi
    fi
    if [ "$SSH_KEYS_TOUCHED" = true ]; then
        if [ "$SSH_ORIGINAL_KEYS" = true ]; then
            cp -p "$SSH_WORK/original-keys" "$SSH_KEYS" || failed=true
        else
            rm -f "$SSH_KEYS" || failed=true
        fi
        if [ "$SSH_ORIGINAL_DIR" = true ]; then
            chown "$SSH_DIR_UID:$SSH_DIR_GID" "$SSH_DIR" || failed=true
            chmod "$SSH_DIR_MODE" "$SSH_DIR" || failed=true
        else
            rmdir "$SSH_DIR" 2>/dev/null || true
        fi
    fi
    if [ "$SSH_ORIGINAL_UFW" = true ]; then
        [ "$SSH_ORIGINAL_UFW_DEFAULT" != true ] || cp -p "$SSH_WORK/original-ufw-default" /etc/default/ufw || failed=true
        [ "$SSH_ORIGINAL_UFW_RULES" != true ] || cp -p "$SSH_WORK/original-ufw-rules" /etc/ufw/user.rules || failed=true
        [ "$SSH_ORIGINAL_UFW6_RULES" != true ] || cp -p "$SSH_WORK/original-ufw6-rules" /etc/ufw/user6.rules || failed=true
        if [ "$SSH_UFW_WAS_ACTIVE" = active ]; then
            ufw reload >/dev/null 2>&1 || failed=true
        else
            ufw --force disable >/dev/null 2>&1 || failed=true
        fi
    fi
    if [ "$SSH_ROOT_TOUCHED" = true ] && [ -n "$SSH_ROOT_HASH_BEFORE" ]; then
        printf 'root:%s\n' "$SSH_ROOT_HASH_BEFORE" | chpasswd -e >/dev/null 2>&1 || failed=true
    fi
    sshd -t >/dev/null 2>&1 || failed=true
    if [ "$SSH_SYSTEMD_TOUCHED" = true ]; then
        if [ "$SSH_SOCKET_WAS_ENABLED" = enabled ]; then
            systemctl enable ssh.socket >/dev/null 2>&1 || failed=true
        elif [ "$SSH_SOCKET_WAS_ENABLED" = disabled ]; then
            systemctl disable ssh.socket >/dev/null 2>&1 || failed=true
        fi
        if [ "$SSH_SERVICE_WAS_ENABLED" = enabled ]; then
            systemctl enable ssh.service >/dev/null 2>&1 || failed=true
        elif [ "$SSH_SERVICE_WAS_ENABLED" = disabled ]; then
            systemctl disable ssh.service >/dev/null 2>&1 || failed=true
        fi
    if [ "$SSH_SOCKET_WAS_ACTIVE" = active ]; then
            restore_socket_activated_ssh || failed=true
        else
            systemctl stop ssh.socket >/dev/null 2>&1 || true
            systemctl restart ssh.service >/dev/null 2>&1 || failed=true
        fi
    fi
    sleep 2
    ssh_port_listening "$SSH_ORIGINAL_PORT" || failed=true
    if [ "$failed" = true ]; then
        error "Автоматический откат не подтверждён; копии сохранены в $SSH_WORK"
        return 1
    fi
    log "Исходный SSH-порт $SSH_ORIGINAL_PORT снова слушается."
}
ssh_exit_handler() {
    local status=$1
    trap - EXIT INT TERM
    if [ "$SSH_ROLLBACK_NEEDED" = true ] && [ "$SSH_COMMITTED" != true ]; then
        if restore_ssh_state; then
            rm -rf -- "$SSH_WORK"
        else
            status=1
        fi
    else
        rm -rf -- "$SSH_WORK"
    fi
    exit "$status"
}
trap 'ssh_exit_handler $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Сначала скачиваем и валидируем весь новый набор ключей. При повторном
# запуске прежние ключи временно сохраняют доступ до проверки нового набора.
curl -4 -fsSL --max-time 20 "$SSH_KEY_URL" -o "$SSH_WORK/desired-keys" ||
    { error "Не удалось скачать SSH-ключи"; exit 1; }
validate_ed25519_keys "$SSH_WORK/desired-keys" ||
    { error "В ssh/authorized_keys нужны только действительные ssh-ed25519 ключи"; exit 1; }
if [ -L "$SSH_DIR" ] || [ -L "$SSH_KEYS" ]; then
    error "Символические ссылки в .ssh/authorized_keys не поддерживаются."
    exit 1
fi
if [ -d "$SSH_DIR" ]; then
    SSH_ORIGINAL_DIR=true
    SSH_DIR_UID=$(stat -c '%u' "$SSH_DIR") || exit 1
    SSH_DIR_GID=$(stat -c '%g' "$SSH_DIR") || exit 1
    SSH_DIR_MODE=$(stat -c '%a' "$SSH_DIR") || exit 1
fi
if [ -e "$SSH_KEYS" ]; then
    cp -p "$SSH_KEYS" "$SSH_WORK/original-keys" || exit 1
    SSH_ORIGINAL_KEYS=true
    validate_ed25519_keys "$SSH_KEYS" ||
        { error "Существующий authorized_keys содержит неподдерживаемые ключи"; exit 1; }
fi
if [ "$SSH_ORIGINAL_KEYS" = true ]; then
    cat "$SSH_WORK/original-keys" "$SSH_WORK/desired-keys" |
        awk '!seen[$0]++' > "$SSH_WORK/staged-keys"
else
    cp "$SSH_WORK/desired-keys" "$SSH_WORK/staged-keys"
fi
if [ "$SSH_ORIGINAL_KEYS" != true ] ||
   ! cmp -s "$SSH_WORK/desired-keys" "$SSH_KEYS" ||
   [ "$(stat -c '%U:%G %a' "$SSH_KEYS" 2>/dev/null)" != "$NEW_USER:$SSH_PRIMARY_GROUP 600" ] ||
   [ "$(stat -c '%U:%G %a' "$SSH_DIR" 2>/dev/null)" != "$NEW_USER:$SSH_PRIMARY_GROUP 700" ]; then
    SSH_CHANGED=true
fi

# Готовим оба варианта конфигурации до изменения работающего sshd. Неизвестные
# провайдерские Port/Match могут конфликтовать; тогда останавливаемся заранее.
cp -p "$SSHD_CONFIG" "$SSH_WORK/original-main" || exit 1
if [ -e "$SSH_MANAGED_CONFIG" ]; then
    cp -p "$SSH_MANAGED_CONFIG" "$SSH_WORK/original-managed" || exit 1
    SSH_ORIGINAL_MANAGED=true
fi
SSH_ORIGINAL_PORT=${CURRENT_SSH_PORT:-22}
[ "$SSH_ACCESS_MODE" != final ] || SSH_ORIGINAL_PORT=$SSH_PORT
SSH_ROOT_HASH_BEFORE=$(getent shadow root | cut -d: -f2)
SSH_SOCKET_WAS_ACTIVE=$(systemctl is-active ssh.socket 2>/dev/null || true)
SSH_SOCKET_WAS_ENABLED=$(systemctl is-enabled ssh.socket 2>/dev/null || true)
SSH_SERVICE_WAS_ENABLED=$(systemctl is-enabled ssh.service 2>/dev/null || true)

# Удаляем только собственную строку Include, если она уже была установлена.
# Остальная конфигурация провайдера переносится в кандидат без изменений.
render_main_with_managed_include "$SSHD_CONFIG" "$SSH_WORK/final-managed" "$SSH_WORK/final-main"
render_main_with_managed_include "$SSHD_CONFIG" "$SSH_WORK/temporary-managed" "$SSH_WORK/temporary-main"
cat > "$SSH_WORK/temporary-managed" << EOF
# Временный доступ: новый порт добавлен, старый вход root сохранён.
Port 22
Port $SSH_PORT
AddressFamily inet
EOF
cat > "$SSH_WORK/final-managed" << EOF
# Управляется setup_ubuntu_24.04.sh. Порт 22 закрывается после проверки ключа.
Port $SSH_PORT
AddressFamily inet
PasswordAuthentication no
KbdInteractiveAuthentication no
HostbasedAuthentication no
GSSAPIAuthentication no
PubkeyAuthentication yes
PubkeyAcceptedAlgorithms ssh-ed25519
AuthorizedKeysFile .ssh/authorized_keys
AuthorizedKeysCommand none
PermitRootLogin no
PermitEmptyPasswords no
EOF
if ssh_unsafe_match_auth; then
    error "Автоматическое применение SSH-политики остановлено до изменения доступа."
    exit 1
fi
if ! ssh_candidate_valid "$SSH_WORK/final-main" final; then
    error "Финальный SSH-кандидат конфликтует с настройками провайдера (Include/Match/Port)."
    report_ssh_conflict
    exit 1
fi
if [ "$SSH_ACCESS_MODE" = transition ] &&
   ! ssh_candidate_valid "$SSH_WORK/temporary-main" temporary; then
    error "Временный SSH-кандидат не сохраняет исходный вход root на порту 22."
    report_ssh_conflict
    exit 1
fi

# Точные байты main нужны для идемпотентной проверки. Одновременно удаляется
# только глобальный Port из базового main: final managed-файл остаётся
# единственным владельцем listener. При отсутствии изменений SSH не
# перезапускается и не запрашивает лишнее подтверждение.
render_main_with_managed_include "$SSHD_CONFIG" "$SSH_MANAGED_CONFIG" "$SSH_WORK/runtime-main"
SSH_CONFIG_CHANGED=false
if ! cmp -s "$SSH_WORK/runtime-main" "$SSHD_CONFIG" ||
   ! cmp -s "$SSH_WORK/final-managed" "$SSH_MANAGED_CONFIG"; then
    SSH_CONFIG_CHANGED=true
fi
if [ "$SSH_SOCKET_WAS_ACTIVE" = active ] || [ "$SSH_SOCKET_WAS_ENABLED" = enabled ]; then
    # Даже при тех же директивах socket может вернуть старый listener при reboot.
    SSH_CONFIG_CHANGED=true
fi
if [ "$SSH_ACCESS_MODE" = transition ]; then
    warn "Оставьте текущую административную сессию открытой до окончания контрольного входа."
fi

# Firewall готовим перед перезапуском SSH. Базовый сценарий добавляет только
# SSH, не отключает UFW и не меняет сторонние правила хостера/приложений.
if ! command -v ufw >/dev/null 2>&1; then
    apt-get install -y -qq ufw || { error "Не удалось установить UFW"; exit 1; }
fi
SSH_UFW_WAS_ACTIVE=$(LC_ALL=C ufw status 2>/dev/null | awk '/^Status:/ {print $2; exit}')
if [ "$SSH_UFW_WAS_ACTIVE" != active ] && [ "$SSH_UFW_WAS_ACTIVE" != inactive ]; then
    error "Не удалось определить исходное состояние UFW."
    exit 1
fi
SSH_ORIGINAL_UFW=true
if [ -e /etc/default/ufw ]; then
    cp -p /etc/default/ufw "$SSH_WORK/original-ufw-default" || exit 1
    SSH_ORIGINAL_UFW_DEFAULT=true
fi
if [ -e /etc/ufw/user.rules ]; then
    cp -p /etc/ufw/user.rules "$SSH_WORK/original-ufw-rules" || exit 1
    SSH_ORIGINAL_UFW_RULES=true
fi
if [ -e /etc/ufw/user6.rules ]; then
    cp -p /etc/ufw/user6.rules "$SSH_WORK/original-ufw6-rules" || exit 1
    SSH_ORIGINAL_UFW6_RULES=true
fi
SSH_ROLLBACK_NEEDED=true
if [ -f /etc/default/ufw ]; then
    if grep -q '^IPV6=' /etc/default/ufw; then
        sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw || exit 1
    else
        printf '\nIPV6=no\n' >> /etc/default/ufw
    fi
fi
# Запоминаем владельца правила до добавления: на повторном запуске нельзя
# считать совпадающее правило своим и позже удалить настройку хостера.
if ufw_rule_exists "$SSH_PORT/tcp"; then
    warn "Правило UFW для $SSH_PORT/tcp уже существовало; оставляем его без изменений."
else
    ufw allow "$SSH_PORT/tcp" comment 'tuning-VPS SSH' || exit 1
fi
if [ "$SSH_ACCESS_MODE" = transition ]; then
    if ufw_rule_exists '22/tcp'; then
        UFW_22_RULE_PREEXISTED=true
        warn "Правило UFW для 22/tcp уже существовало; оно не будет удалено скриптом."
    else
        ufw allow 22/tcp comment 'tuning-VPS temporary SSH' || exit 1
        UFW_TEMP_RULE_CREATED=true
    fi
fi
ufw default deny incoming || exit 1
ufw --force enable || exit 1
ufw reload >/dev/null || exit 1
LC_ALL=C ufw status | grep -q '^Status: active' || exit 1
ufw_rule_exists "$SSH_PORT/tcp" ||
    { error "UFW не открыл новый SSH-порт"; exit 1; }
if [ "$SSH_ACCESS_MODE" = transition ]; then
    ufw_rule_exists '22/tcp' ||
        { error "UFW не сохранил исходный SSH-порт"; exit 1; }
fi

# Временный перезапуск добавляет новый порт, сохраняя исходный способ входа.
# При ssh.socket переключаемся на ssh.service: socket может удерживать порт 22
# независимо от sshd_config. Любая ошибка вызывает trap и полный откат.
if [ "$SSH_ACCESS_MODE" = transition ] || [ "$SSH_CHANGED" = true ]; then
    SSH_KEYS_TOUCHED=true
    install -d -m 700 -o "$NEW_USER" -g "$SSH_PRIMARY_GROUP" "$SSH_DIR" || exit 1
    install -m 600 -o "$NEW_USER" -g "$SSH_PRIMARY_GROUP" "$SSH_WORK/staged-keys" "$SSH_KEYS" || exit 1
fi
if [ "$SSH_ACCESS_MODE" = transition ]; then
    SSH_CONFIG_TOUCHED=true
    install -m 600 "$SSH_WORK/temporary-managed" "$SSH_MANAGED_CONFIG" || exit 1
    render_main_with_managed_include "$SSH_WORK/original-main" "$SSH_MANAGED_CONFIG" "$SSHD_CONFIG"
    sshd -t || exit 1
    SSH_SYSTEMD_TOUCHED=true
    # Do this even if ssh.socket is currently failed: it may have left a
    # listener behind after an earlier interrupted migration.
    stop_socket_activated_ssh_listener || exit 1
    systemctl enable ssh.service >/dev/null 2>&1 || exit 1
    systemctl restart ssh.service || exit 1
    sleep 2
    ssh_service_port_listening 22 && ssh_service_port_listening "$SSH_PORT" ||
        { error "После временного перехода оба SSH-порта не слушаются"; exit 1; }
    ssh_candidate_valid "$SSHD_CONFIG" temporary ||
        { error "Временная конфигурация SSH не прошла повторную проверку"; exit 1; }
fi

# Ручная проверка проводится до закрытия 22/root. На повторном запуске уже
# защищённого сервера она нужна только при изменении ключей или конфига.
if [ "$SSH_ACCESS_MODE" = transition ] ||
   [ "$SSH_CHANGED" = true ] ||
   [ "$SSH_CONFIG_CHANGED" = true ]; then
    warn "В НОВОМ окне выполните: ssh -4 -p $SSH_PORT $NEW_USER@$SERVER_IP"
    warn "Проверьте также sudo -n true; текущую сессию не закрывайте."
    answer=''
    if [ -r /dev/tty ]; then
        IFS= read -r -p 'Вход по новому ключу и sudo работают? (y/N): ' answer </dev/tty || answer=''
    fi
    case "$answer" in y|Y|yes) ;; *)
        error "Контрольный вход не подтверждён. Остальные блоки остановлены."
        exit 1 ;;
    esac
fi

# Теперь оставляем только новый порт и ровно опубликованный набор ключей.
# Если набор ключей изменился, подтверждаем повторный вход уже после удаления
# старых ключей, пока текущая сессия ещё доступна для отката.
if ! cmp -s "$SSH_WORK/final-managed" "$SSH_MANAGED_CONFIG"; then
    SSH_CONFIG_TOUCHED=true
    install -m 600 "$SSH_WORK/final-managed" "$SSH_MANAGED_CONFIG" || exit 1
fi
if ! cmp -s "$SSH_WORK/runtime-main" "$SSHD_CONFIG"; then
    SSH_CONFIG_TOUCHED=true
    cp "$SSH_WORK/runtime-main" "$SSHD_CONFIG" || exit 1
fi
if [ "$SSH_ACCESS_MODE" = transition ] || [ "$SSH_CHANGED" = true ]; then
    SSH_KEYS_TOUCHED=true
    install -m 600 -o "$NEW_USER" -g "$SSH_PRIMARY_GROUP" "$SSH_WORK/desired-keys" "$SSH_KEYS" || exit 1
fi
sshd -t || exit 1
if [ "$SSH_ACCESS_MODE" = transition ] || [ "$SSH_CONFIG_CHANGED" = true ]; then
    SSH_SYSTEMD_TOUCHED=true
    systemctl disable --now ssh.socket >/dev/null 2>&1 || exit 1
    systemctl enable ssh.service >/dev/null 2>&1 || exit 1
    systemctl restart ssh.service || exit 1
fi
sleep 2
ssh_service_port_listening "$SSH_PORT" && ! ssh_port_listening 22 ||
    { error "Финальное состояние SSH listener не подтверждено"; exit 1; }
ssh_candidate_valid "$SSHD_CONFIG" final ||
    { error "Финальная конфигурация SSH не прошла проверку"; exit 1; }
if [ "$SSH_ACCESS_MODE" = transition ] ||
   [ "$SSH_CHANGED" = true ] ||
   [ "$SSH_CONFIG_CHANGED" = true ]; then
    warn "Откройте ЕЩЁ ОДНУ сессию после финальной политики и точного набора ключей."
    answer=''
    if [ -r /dev/tty ]; then
        IFS= read -r -p 'Повторный вход и sudo работают? (y/N): ' answer </dev/tty || answer=''
    fi
    case "$answer" in y|Y|yes) ;; *)
        error "Повторный вход не подтверждён. Выполняется откат."
        exit 1 ;;
    esac
fi

# Блокировка пароля root выполняется последней. Удаляем только временное
# правило 22, созданное этим запуском; правило, существовавшее раньше, остаётся
# и будет явно показано в отчёте как внешнее.
if ! passwd -S root 2>/dev/null | awk '{print $2}' | grep -q '^L'; then
    SSH_ROOT_TOUCHED=true
    passwd -l root >/dev/null 2>&1 || exit 1
fi
passwd -S root 2>/dev/null | awk '{print $2}' | grep -q '^L' || exit 1
if [ "$UFW_TEMP_RULE_CREATED" = true ]; then
    ufw --force delete allow 22/tcp >/dev/null || exit 1
    if ufw_rule_exists '22/tcp'; then
        error "Не удалось удалить временное правило UFW для порта 22."
        exit 1
    fi
elif [ "$UFW_22_RULE_PREEXISTED" = true ]; then
    warn "Внешнее правило UFW для 22/tcp сохранено; SSH на этом порту уже не слушает."
fi
LC_ALL=C ufw status | grep -q '^Status: active' && ufw_rule_exists "$SSH_PORT/tcp" ||
    { error "Финальное состояние UFW не подтверждено"; exit 1; }
report_ufw_unexpected_rules
SSH_COMMITTED=true
SSH_ROLLBACK_NEEDED=false
trap - EXIT INT TERM
rm -rf -- "$SSH_WORK"
add_check 0 "Финальная SSH-конфигурация и ключи"

# 12. НАСТРОЙКА FAIL2BAN (ЗАЩИTA SSH ОТ БРУТФОРСА) ============================

log "Настройка fail2ban..."

# Установка fail2ban
apt-get install -y -qq fail2ban

# Создание кастомного конфига для SSH с прогрессивным баном
# Используем systemd backend для Ubuntu 24.04 (journald)
cat > /etc/fail2ban/jail.d/99-ssh-custom.conf << EOF
[sshd]
enabled = true
port = $SSH_PORT
backend = systemd
maxretry = 3
bantime = 86400
bantime.increment = true
bantime.multiplier = 2
bantime.maxtime = 604800
findtime = 600
ignoreip = 127.0.0.1/8 ::1
EOF

# Перезапуск fail2ban для применения настроек
systemctl restart fail2ban 2>/dev/null || true
systemctl enable fail2ban 2>/dev/null || true

# Проверка статуса fail2ban
if systemctl is-active fail2ban &>/dev/null; then
    FAIL2BAN_VALIDATION_OK=0
    log "Fail2ban установлен и запущен"
    # Проверка статуса правил SSH
    if fail2ban-client status sshd &>/dev/null; then
        log "Правила fail2ban для SSH активны"
    else
        FAIL2BAN_VALIDATION_OK=1
    fi
    add_check $FAIL2BAN_VALIDATION_OK "Установка fail2ban"
else
    warn "Не удалось запустить fail2ban"
    add_check 1 "Установка fail2ban"
fi

# 13. AUDITD: ТОЛЬКО ИЗМЕНЕНИЯ КОНФИГУРАЦИИ ==================================

log "Настройка приватного auditd..."

# Auditd оставляем для признаков изменения критичных конфигураций. Он не должен
# фиксировать соединения VPN, DNS, аргументы команд или каждую запись auth.log:
# такие события раскрывают активность пользователей и быстро расходуют диск.
AUDIT_RULES_CONFIG=/etc/audit/rules.d/99-tuning-vps-privacy.rules
AUDIT_RULES_NEW=""
AUDIT_RULES_BACKUP=""
AUDIT_RULES_EXISTED=false
AUDIT_FAILURE=""

# Убираем только известный файл старой версии проекта. Чужие rules.d-файлы не
# изменяем; если они содержат аудит трафика, это будет явно видно в отчёте.
migrate_legacy_tuning_audit_rules() {
    local legacy backup_dir destination
    legacy=/etc/audit/rules.d/99-custom.rules
    [ -f "$legacy" ] || return 0
    if ! grep -qE '(^|[[:space:]])-k[[:space:]]+(network_connect|bash_execution|privileged_execution)([[:space:]]|$)' "$legacy"; then
        return 0
    fi
    backup_dir=/var/backups/tuning-vps/audit
    install -d -m 0700 "$backup_dir" || return 1
    destination="$backup_dir/99-custom.rules.legacy"
    if [ -e "$destination" ]; then
        cmp -s "$legacy" "$destination" && { rm -f "$legacy"; return; }
        destination="${destination}.$(date +%s)"
    fi
    cp -p "$legacy" "$destination" && rm -f "$legacy"
}

if ! migrate_legacy_tuning_audit_rules; then
    AUDIT_FAILURE="не удалось перенести устаревшие правила auditd проекта"
fi
if [ -z "$AUDIT_FAILURE" ] && ! apt-get install -y -qq auditd; then
    AUDIT_FAILURE="не удалось установить auditd"
fi
if [ -z "$AUDIT_FAILURE" ] && ! install -d -m 0750 /etc/audit/rules.d; then
    AUDIT_FAILURE="не удалось создать каталог правил auditd"
fi
if [ -z "$AUDIT_FAILURE" ]; then
    AUDIT_RULES_NEW=$(mktemp /etc/audit/rules.d/.tuning-vps-privacy.XXXXXXXX) ||
        AUDIT_FAILURE="не удалось подготовить временный файл правил auditd"
fi
if [ -z "$AUDIT_FAILURE" ] && [ -f "$AUDIT_RULES_CONFIG" ]; then
    AUDIT_RULES_BACKUP=$(mktemp /etc/audit/rules.d/.tuning-vps-privacy-backup.XXXXXXXX) ||
        AUDIT_FAILURE="не удалось подготовить резервную копию правил auditd"
    if [ -z "$AUDIT_FAILURE" ]; then
        if cp -p "$AUDIT_RULES_CONFIG" "$AUDIT_RULES_BACKUP"; then
            AUDIT_RULES_EXISTED=true
        else
            AUDIT_FAILURE="не удалось сохранить прежние правила auditd"
        fi
    fi
fi
if [ -z "$AUDIT_FAILURE" ] && ! systemctl enable --now auditd >/dev/null 2>&1; then
    AUDIT_FAILURE="не удалось включить auditd"
fi

if [ -z "$AUDIT_FAILURE" ]; then
cat > "$AUDIT_RULES_NEW" << 'EOF'
# Managed by setup_ubuntu_24.04.sh.
# Только изменения административной конфигурации; без сетевых событий и execve.
-w /etc/passwd -p wa -k tuning_vps_identity
-w /etc/group -p wa -k tuning_vps_identity
-w /etc/shadow -p wa -k tuning_vps_identity
-w /etc/sudoers -p wa -k tuning_vps_sudo
-w /etc/sudoers.d/ -p wa -k tuning_vps_sudo
-w /etc/ssh/sshd_config -p wa -k tuning_vps_ssh
-w /etc/ssh/sshd_config.d/ -p wa -k tuning_vps_ssh
-w /etc/apt/apt.conf.d/ -p wa -k tuning_vps_apt
-w /etc/systemd/system/ -p wa -k tuning_vps_systemd
-w /etc/cron.d/ -p wa -k tuning_vps_cron
-w /etc/crontab -p wa -k tuning_vps_cron
EOF
fi

if [ -z "$AUDIT_FAILURE" ] && ! cmp -s "$AUDIT_RULES_NEW" "$AUDIT_RULES_CONFIG"; then
    install -m 0640 "$AUDIT_RULES_NEW" "$AUDIT_RULES_CONFIG" ||
        AUDIT_FAILURE="не удалось установить правила auditd"
fi
rm -f "$AUDIT_RULES_NEW"
if [ -z "$AUDIT_FAILURE" ] && ! augenrules --load >/dev/null 2>&1; then
    AUDIT_FAILURE="augenrules не применил правила auditd"
fi
if [ -z "$AUDIT_FAILURE" ] &&
   { ! systemctl is-active --quiet auditd ||
     ! auditctl -l 2>/dev/null | grep -q 'tuning_vps_ssh'; }; then
    AUDIT_FAILURE="auditd не активен или управляемые правила не загружены"
fi

if [ -n "$AUDIT_FAILURE" ]; then
    if [ "$AUDIT_RULES_EXISTED" = true ]; then
        cp -p "$AUDIT_RULES_BACKUP" "$AUDIT_RULES_CONFIG" ||
            error "Не удалось восстановить прежние правила auditd."
    else
        rm -f "$AUDIT_RULES_CONFIG"
    fi
    augenrules --load >/dev/null 2>&1 || true
    add_result "FAIL" "Auditd privacy" "$AUDIT_FAILURE"
else
    add_result "OK" "Auditd privacy" "аудитируются только изменения административной конфигурации"
fi
rm -f "$AUDIT_RULES_BACKUP"

# Внешние правила не трогаем, но предупреждаем, если они всё ещё пишут сетевую
# активность. Это позволяет владельцу осознанно удалить их вне базового скрипта.
AUDIT_NETWORK_RULES=$(auditctl -l 2>/dev/null | grep -E -- '(^|[[:space:]])-S[[:space:]]+(connect|accept)([[:space:]]|$)' || true)
if [ -n "$AUDIT_NETWORK_RULES" ]; then
    warn "Обнаружены внешние auditd-правила соединений; базовый скрипт их не удалял."
    add_result "WARN" "Auditd privacy" "внешние правила продолжают аудит connect/accept"
fi

# 14. АВТООБНОВЛЕНИЯ ==========================================================

log "Настройка автоматических обновлений безопасности..."

# Пакетный 50unattended-upgrades принадлежит Ubuntu и может меняться при
# обновлении пакета. Политика проекта живёт в отдельном файле с более поздним
# номером: она переживает обновления и не стирает настройки дистрибутива.
UNATTENDED_CONFIG="/etc/apt/apt.conf.d/99-tuning-vps-auto-upgrades"
UNATTENDED_NEW=$(mktemp /etc/apt/apt.conf.d/.tuning-vps-auto-upgrades.XXXXXXXX) || exit 1
UNATTENDED_BACKUP=""
UNATTENDED_CONFIG_EXISTED=false
AUTO_UPDATE_FAILURE=""
AUTO_UPDATE_RUN_EVIDENCE=""
APT_DAILY_ENABLED_BEFORE=$(systemctl is-enabled apt-daily.timer 2>/dev/null || true)
APT_DAILY_UPGRADE_ENABLED_BEFORE=$(systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null || true)
APT_DAILY_ACTIVE_BEFORE=$(systemctl is-active apt-daily.timer 2>/dev/null || true)
APT_DAILY_UPGRADE_ACTIVE_BEFORE=$(systemctl is-active apt-daily-upgrade.timer 2>/dev/null || true)

if [ -f "$UNATTENDED_CONFIG" ]; then
    UNATTENDED_BACKUP=$(mktemp /etc/apt/apt.conf.d/.tuning-vps-auto-upgrades-backup.XXXXXXXX) || exit 1
    UNATTENDED_CONFIG_EXISTED=true
    cp -p "$UNATTENDED_CONFIG" "$UNATTENDED_BACKUP" || exit 1
fi

restore_apt_timer_state() {
    local unit enabled active
    while [ "$#" -gt 0 ]; do
        unit=$1 enabled=$2 active=$3
        shift 3
        case "$enabled" in
            enabled) systemctl enable "$unit" >/dev/null 2>&1 || return 1 ;;
            disabled) systemctl disable "$unit" >/dev/null 2>&1 || return 1 ;;
        esac
        case "$active" in
            active) systemctl start "$unit" >/dev/null 2>&1 || return 1 ;;
            inactive|failed) systemctl stop "$unit" >/dev/null 2>&1 || return 1 ;;
        esac
    done
}

# Ранние версии скрипта оставляли свои timestamp-backup рядом с APT-конфигами.
# APT игнорирует их, но печатает предупреждение при каждом запуске. Переносим
# только строго этот исторический шаблон в обычный root-only каталог бэкапов.
migrate_legacy_unattended_backups() {
    local legacy backup_dir destination
    backup_dir=/var/backups/tuning-vps
    for legacy in /etc/apt/apt.conf.d/50unattended-upgrades.bak.[0-9]*; do
        [ -f "$legacy" ] || continue
        [[ "${legacy##*/}" =~ ^50unattended-upgrades\.bak\.[0-9]+$ ]] || continue
        install -d -m 0700 "$backup_dir" || return 1
        destination="$backup_dir/${legacy##*/}"
        if [ -e "$destination" ]; then
            if cmp -s "$legacy" "$destination"; then
                rm -f "$legacy" || return 1
                continue
            fi
            destination="${destination}.migrated.$(date +%s)"
        fi
        cp -p "$legacy" "$destination" && rm -f "$legacy" || return 1
    done
}

if ! migrate_legacy_unattended_backups; then
    warn "Не удалось убрать старые резервные копии 50unattended-upgrades из каталога APT."
fi

if ! apt-get install -y -qq unattended-upgrades; then
    AUTO_UPDATE_FAILURE="не удалось установить unattended-upgrades"
else
    cat > "$UNATTENDED_NEW" << 'EOF'
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;

# Устанавливаются обычные и security-обновления Ubuntu. Сторонние репозитории
# не входят в этот список и требуют отдельной осознанной политики приложения.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::Remove-New-Unused-Dependencies "false";
# Сервер обслуживается без постоянного участия администратора. Когда пакет
# требует reboot, он выполняется ночью по времени, установленному выше.
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
EOF

    if ! cmp -s "$UNATTENDED_NEW" "$UNATTENDED_CONFIG"; then
        install -m 0644 "$UNATTENDED_NEW" "$UNATTENDED_CONFIG" ||
            AUTO_UPDATE_FAILURE="не удалось установить управляемую APT-конфигурацию"
    fi

    if [ -z "$AUTO_UPDATE_FAILURE" ] &&
       ! systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1; then
        AUTO_UPDATE_FAILURE="не удалось включить таймеры apt-daily и apt-daily-upgrade"
    fi

    if [ -z "$AUTO_UPDATE_FAILURE" ]; then
        APT_EFFECTIVE_CONFIG=$(apt-config dump 2>/dev/null) ||
            AUTO_UPDATE_FAILURE="не удалось прочитать итоговую APT-конфигурацию"
    fi
    if [ -z "$AUTO_UPDATE_FAILURE" ] &&
       { ! grep -Fqx 'APT::Periodic::Update-Package-Lists "1";' <<< "$APT_EFFECTIVE_CONFIG" ||
         ! grep -Fqx 'APT::Periodic::Unattended-Upgrade "1";' <<< "$APT_EFFECTIVE_CONFIG"; }; then
        AUTO_UPDATE_FAILURE="ежедневные APT::Periodic параметры отсутствуют в итоговой конфигурации"
    elif [ -z "$AUTO_UPDATE_FAILURE" ] &&
         { ! grep -Fqx 'Unattended-Upgrade::Allowed-Origins:: "${distro_id}:${distro_codename}";' <<< "$APT_EFFECTIVE_CONFIG" ||
           ! grep -Fqx 'Unattended-Upgrade::Allowed-Origins:: "${distro_id}:${distro_codename}-security";' <<< "$APT_EFFECTIVE_CONFIG" ||
           [ "$(grep -Fc 'Unattended-Upgrade::Allowed-Origins::' <<< "$APT_EFFECTIVE_CONFIG")" -ne 2 ] ||
           grep -Fq 'Unattended-Upgrade::Origins-Pattern::' <<< "$APT_EFFECTIVE_CONFIG"; }; then
        AUTO_UPDATE_FAILURE="итоговая политика unattended-upgrades не ограничена обычными и security-обновлениями Ubuntu"
    elif [ -z "$AUTO_UPDATE_FAILURE" ] &&
         { ! grep -Fqx 'Unattended-Upgrade::Automatic-Reboot "true";' <<< "$APT_EFFECTIVE_CONFIG" ||
           ! grep -Fqx 'Unattended-Upgrade::Automatic-Reboot-Time "03:00";' <<< "$APT_EFFECTIVE_CONFIG" ||
           ! grep -Fqx 'Unattended-Upgrade::Automatic-Reboot-WithUsers "true";' <<< "$APT_EFFECTIVE_CONFIG" ||
           ! grep -Fqx 'Unattended-Upgrade::Remove-Unused-Dependencies "false";' <<< "$APT_EFFECTIVE_CONFIG" ||
           ! grep -Fqx 'Unattended-Upgrade::Remove-New-Unused-Dependencies "false";' <<< "$APT_EFFECTIVE_CONFIG"; }; then
        AUTO_UPDATE_FAILURE="итоговая политика unattended-upgrades отличается от безопасной базовой"
    elif [ -z "$AUTO_UPDATE_FAILURE" ] &&
         { ! systemctl is-enabled --quiet apt-daily.timer apt-daily-upgrade.timer ||
           ! systemctl is-active --quiet apt-daily.timer apt-daily-upgrade.timer; }; then
        AUTO_UPDATE_FAILURE="таймеры apt-daily и apt-daily-upgrade не включены или не активны"
    fi
fi
rm -f "$UNATTENDED_NEW"

if [ -z "$AUTO_UPDATE_FAILURE" ]; then
    # Само наличие активного таймера не доказывает, что worker уже выполнялся.
    # Ищем только служебный факт запуска, без разбора пакетов или адресов.
    AUTO_UPDATE_LAST_RUN=$(grep -F 'Starting unattended upgrades script' \
        /var/log/unattended-upgrades/unattended-upgrades.log 2>/dev/null | tail -n 1 || true)
    AUTO_UPDATE_CONFIG_MTIME=$(stat -c '%Y' "$UNATTENDED_CONFIG" 2>/dev/null || true)
    AUTO_UPDATE_LAST_RUN_EPOCH=""
    if [ -n "$AUTO_UPDATE_LAST_RUN" ]; then
        AUTO_UPDATE_LAST_RUN_EPOCH=$(date -d "${AUTO_UPDATE_LAST_RUN%%,*}" +%s 2>/dev/null || true)
    fi
    if [[ "$AUTO_UPDATE_LAST_RUN_EPOCH" =~ ^[0-9]+$ ]] &&
       [[ "$AUTO_UPDATE_CONFIG_MTIME" =~ ^[0-9]+$ ]] &&
       [ "$AUTO_UPDATE_LAST_RUN_EPOCH" -ge "$AUTO_UPDATE_CONFIG_MTIME" ]; then
        AUTO_UPDATE_RUN_EVIDENCE="worker запускался после применения текущей политики"
    else
        # apt.systemd.daily не запускает worker повторно в тот же период. Такой
        # успешный service-run доказывает работу таймера, но не новую установку
        # обновлений; это нужно отличать от полностью отсутствующего запуска.
        AUTO_UPDATE_SERVICE_RUN=$(journalctl --since "@${AUTO_UPDATE_CONFIG_MTIME:-0}" \
            -u apt-daily-upgrade.service --no-pager -o cat 2>/dev/null |
            grep -F 'Finished apt-daily-upgrade.service' | tail -n 1 || true)
        if [ -n "$AUTO_UPDATE_SERVICE_RUN" ]; then
            AUTO_UPDATE_RUN_EVIDENCE="apt-daily-upgrade.service завершился после политики; worker ожидает следующего периода"
        elif [ -n "$AUTO_UPDATE_LAST_RUN" ]; then
            AUTO_UPDATE_RUN_EVIDENCE="последний worker был до текущей политики; проверьте журнал после ближайшего запуска таймера"
        else
            AUTO_UPDATE_RUN_EVIDENCE="нет записи о выполнении worker; проверьте журнал после ближайшего запуска таймера"
        fi
    fi
    add_result "OK" "Unattended-upgrades" "ежедневные обновления Ubuntu включены; reboot при необходимости в 03:00; $AUTO_UPDATE_RUN_EVIDENCE"
else
    if [ "$UNATTENDED_CONFIG_EXISTED" = true ]; then
        cp -p "$UNATTENDED_BACKUP" "$UNATTENDED_CONFIG" ||
            error "Не удалось восстановить прежний управляемый APT-файл."
    else
        rm -f "$UNATTENDED_CONFIG"
    fi
    restore_apt_timer_state \
        apt-daily.timer "$APT_DAILY_ENABLED_BEFORE" "$APT_DAILY_ACTIVE_BEFORE" \
        apt-daily-upgrade.timer "$APT_DAILY_UPGRADE_ENABLED_BEFORE" "$APT_DAILY_UPGRADE_ACTIVE_BEFORE" ||
        error "Не удалось полностью восстановить исходное состояние APT-таймеров."
    add_result "FAIL" "Unattended-upgrades" "$AUTO_UPDATE_FAILURE"
fi
rm -f "$UNATTENDED_BACKUP"

# 15. НАСТРОЙКА NEEDRESTART (АВТОМАТИЧЕСКИЙ ПЕРЕЗАПУСК СЕРВИСОВ) =============

log "Настройка needrestart (автоматический перезапуск сервисов)..."

NEEDRESTART_CONFIG="/etc/needrestart/needrestart.conf"
NEEDRESTART_BACKUP="${NEEDRESTART_CONFIG}.bak.$(date +%s)"
NEEDRESTART_SECTION=$(mktemp)
NEEDRESTART_FAILURE=""

if ! apt-get install -y -qq needrestart >/dev/null 2>&1; then
    NEEDRESTART_FAILURE="не удалось установить пакет"
else
    if [ ! -f "$NEEDRESTART_CONFIG" ]; then
        NEEDRESTART_FAILURE="основной конфиг после установки пакета не найден"
    else
        cp "$NEEDRESTART_CONFIG" "$NEEDRESTART_BACKUP"
        cat > "$NEEDRESTART_SECTION" << 'EOF'
# Автоматический перезапуск сервисов после обновлений.
$nrconf{restart} = 'a';
EOF
        replace_managed_section "$NEEDRESTART_CONFIG" "needrestart" "$NEEDRESTART_SECTION"
    fi
    rm -f "$NEEDRESTART_SECTION"

    if [ -z "$NEEDRESTART_FAILURE" ] && ! perl -c "$NEEDRESTART_CONFIG" >/dev/null 2>&1; then
        NEEDRESTART_FAILURE="основной Perl-конфиг не прошёл синтаксическую проверку"
    elif [ -z "$NEEDRESTART_FAILURE" ] && ! perl -e 'our %nrconf; do "/etc/needrestart/needrestart.conf"; exit (($nrconf{restart} // "") eq "a" ? 0 : 1);'; then
        NEEDRESTART_FAILURE="итоговое значение restart не равно a"
    fi
fi

if [ -z "$NEEDRESTART_FAILURE" ]; then
    add_result "OK" "Needrestart" "автоматический перезапуск сервисов включён"
else
    [ -f "$NEEDRESTART_BACKUP" ] && cp "$NEEDRESTART_BACKUP" "$NEEDRESTART_CONFIG"
    add_result "FAIL" "Needrestart" "$NEEDRESTART_FAILURE"
fi

# 16. JOURNALD: КОРОТКОЕ ХРАНЕНИЕ И ВРЕМЕННАЯ ДИАГНОСТИКА =====================

log "Настройка приватного journald..."

# Конфигурация проекта хранится в drop-in, поэтому пакетный и провайдерский
# journald.conf остаются нетронутыми. Семь дней и 50 MiB достаточны для SSH,
# обновлений и диагностики ОС, но ограничивают последствия утечки диска.
JOURNALD_CONFIG_DIR=/etc/systemd/journald.conf.d
JOURNALD_CONFIG="$JOURNALD_CONFIG_DIR/99-tuning-vps-privacy.conf"
JOURNALD_DEBUG_CONFIG="$JOURNALD_CONFIG_DIR/99-tuning-vps-debug.conf"
JOURNALD_DEBUG_HELPER=/usr/local/sbin/tuning-vps-debug-logging
JOURNALD_NEW=$(mktemp /etc/systemd/.tuning-vps-journald.XXXXXXXX) || exit 1
JOURNALD_BACKUP=""
JOURNALD_CONFIG_EXISTED=false
JOURNALD_FAILURE=""
JOURNALD_CHECK_SINCE=$(date --iso-8601=seconds)

if [ -f "$JOURNALD_CONFIG" ]; then
    JOURNALD_BACKUP=$(mktemp /etc/systemd/.tuning-vps-journald-backup.XXXXXXXX) || exit 1
    cp -p "$JOURNALD_CONFIG" "$JOURNALD_BACKUP" || exit 1
    JOURNALD_CONFIG_EXISTED=true
fi

cat > "$JOURNALD_NEW" << 'EOF'
[Journal]
# Сохраняем системную диагностику, но не месяцы сетевой активности клиентов.
Storage=persistent
Compress=yes
Seal=yes
SystemMaxUse=50M
SystemMaxFileSize=8M
SystemMaxFiles=7
SystemKeepFree=200M
RuntimeMaxUse=20M
RuntimeMaxFileSize=4M
RuntimeMaxFiles=5
MaxRetentionSec=7day
# В обычном режиме отбрасываем debug-сообщения приложений.
MaxLevelStore=info
MaxLevelSyslog=info
EOF

if ! install -d -m 0755 "$JOURNALD_CONFIG_DIR"; then
    JOURNALD_FAILURE="не удалось создать каталог drop-in journald"
elif ! cmp -s "$JOURNALD_NEW" "$JOURNALD_CONFIG"; then
    install -m 0644 "$JOURNALD_NEW" "$JOURNALD_CONFIG" ||
        JOURNALD_FAILURE="не удалось установить управляемый drop-in journald"
fi
rm -f "$JOURNALD_NEW"

# Временный debug-режим включается одной командой и сам отключается максимум
# через два часа. Базовый режим при этом сохраняет те же лимиты места и срока.
if [ -z "$JOURNALD_FAILURE" ]; then
    cat > "$JOURNALD_DEBUG_HELPER" << 'EOF'
#!/usr/bin/env bash
set -u

config_dir=/etc/systemd/journald.conf.d
debug_config="$config_dir/99-tuning-vps-debug.conf"
expire_unit=tuning-vps-debug-logging-expire

restart_journald() {
    systemctl restart systemd-journald
}

case "${1:-status}" in
    enable)
        duration=${2:-30m}
        case "$duration" in 5m|15m|30m|1h|2h) ;; *)
            echo "Допустимая длительность: 5m, 15m, 30m, 1h или 2h" >&2
            exit 2 ;;
        esac
        install -d -m 0755 "$config_dir"
        cat > "$debug_config" <<'DEBUG_EOF'
[Journal]
MaxLevelStore=debug
MaxLevelSyslog=debug
DEBUG_EOF
        if ! restart_journald; then
            echo "Не удалось перезапустить systemd-journald; debug-режим не включён." >&2
            rm -f "$debug_config"
            exit 1
        fi
        systemctl stop "${expire_unit}.timer" >/dev/null 2>&1 || true
        if ! systemd-run --quiet --collect --unit="$expire_unit" --on-active="$duration" \
            /usr/local/sbin/tuning-vps-debug-logging disable; then
            rm -f "$debug_config"
            restart_journald || true
            echo "Не удалось запланировать отключение debug-режима." >&2
            exit 1
        fi
        echo "Подробные системные логи включены на $duration."
        ;;
    disable)
        rm -f "$debug_config"
        systemctl stop "${expire_unit}.timer" >/dev/null 2>&1 || true
        if ! restart_journald; then
            echo "Не удалось перезапустить systemd-journald после отключения debug-режима." >&2
            exit 1
        fi
        echo "Подробные системные логи отключены."
        ;;
    status)
        if [ -f "$debug_config" ]; then
            echo "Подробные системные логи включены; проверьте ${expire_unit}.timer."
        else
            echo "Обычный приватный режим журналов активен."
        fi
        ;;
    *)
        echo "Использование: $0 {enable [5m|15m|30m|1h|2h]|disable|status}" >&2
        exit 2 ;;
esac
EOF
    chmod 0750 "$JOURNALD_DEBUG_HELPER" || JOURNALD_FAILURE="не удалось установить helper debug-логов"
fi

mkdir -p /var/log/journal
if [ -z "$JOURNALD_FAILURE" ] && ! systemctl restart systemd-journald; then
    JOURNALD_FAILURE="не удалось перезапустить systemd-journald"
elif [ -z "$JOURNALD_FAILURE" ] && ! systemctl is-active --quiet systemd-journald; then
    JOURNALD_FAILURE="systemd-journald не активен после перезапуска"
elif [ -z "$JOURNALD_FAILURE" ] && [ ! -d /var/log/journal ]; then
    JOURNALD_FAILURE="persistent storage /var/log/journal отсутствует"
elif [ -z "$JOURNALD_FAILURE" ] &&
     journalctl -u systemd-journald --since "$JOURNALD_CHECK_SINCE" --no-pager 2>/dev/null | grep -qiE 'unknown key|invalid|failed|error'; then
    JOURNALD_FAILURE="journald сообщил об ошибке или неизвестной директиве"
elif [ -z "$JOURNALD_FAILURE" ]; then
    JOURNALD_EFFECTIVE=$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null)
    if ! grep -qx 'Storage=persistent' <<< "$JOURNALD_EFFECTIVE" || \
       ! grep -qx 'SystemMaxUse=50M' <<< "$JOURNALD_EFFECTIVE" || \
       ! grep -qx 'MaxRetentionSec=7day' <<< "$JOURNALD_EFFECTIVE" || \
       ! grep -qx 'MaxLevelStore=info' <<< "$JOURNALD_EFFECTIVE"; then
        JOURNALD_FAILURE="итоговая конфигурация не содержит ожидаемых значений"
    fi
fi

if [ -z "$JOURNALD_FAILURE" ]; then
    journalctl --vacuum-time=7d --vacuum-size=50M >/dev/null 2>&1 ||
        warn "Не удалось немедленно сократить старые журналы journald."
    JOURNAL_SIZE=$(journalctl --disk-usage 2>/dev/null | head -1 || echo "размер недоступен")
    add_result "OK" "Journald privacy" "хранение до 7 дней и 50M; $JOURNAL_SIZE; debug: sudo tuning-vps-debug-logging enable 30m"
else
    if [ "$JOURNALD_CONFIG_EXISTED" = true ]; then
        cp -p "$JOURNALD_BACKUP" "$JOURNALD_CONFIG" ||
            error "Не удалось восстановить прежний drop-in journald."
    else
        rm -f "$JOURNALD_CONFIG"
    fi
    systemctl restart systemd-journald >/dev/null 2>&1 || true
    add_result "FAIL" "Journald privacy" "$JOURNALD_FAILURE; управляемый drop-in восстановлен"
fi
rm -f "$JOURNALD_BACKUP"

# 17. НАСТРОЙКА ЛОГРОТАЦИИ =====================================================

log "Настройка logrotate..."

# Установка logrotate (обычно уже установлен)
apt-get install -y -qq logrotate 2>/dev/null || true

# Создание кастомного конфига для системных логов
cat > /etc/logrotate.d/custom-system << 'EOF'
# Кастомная настройка ротации системных логов
/var/log/auth.log
/var/log/kern.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    su root adm
    create 0640 root adm
    sharedscripts
    postrotate
        systemctl kill -s HUP rsyslog 2>/dev/null || true
    endscript
}

# Логи nginx (если установлен)
/var/log/nginx/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    su www-data adm
    create 0640 www-data adm
    sharedscripts
    postrotate
        [ -f /var/run/nginx.pid ] && kill -USR1 `cat /var/run/nginx.pid`
    endscript
}
EOF

# Проверка конфигурации logrotate с диагностикой
log "Проверка конфигурации logrotate..."
LOGROTATE_DEBUG=$(logrotate -d /etc/logrotate.d/custom-system 2>&1)
LOGROTATE_EXIT=$?

if [ $LOGROTATE_EXIT -eq 0 ]; then
    log "Конфигурация logrotate создана"
    add_check 0 "Настройка logrotate"
else
    warn "Ошибка в конфигурации logrotate (код: $LOGROTATE_EXIT)"
    echo ""
    echo "===ДИАГНОСТИКА LOGROTATE==="
    echo "$LOGROTATE_DEBUG"
    echo "==========================="
    echo ""
    add_check 1 "Настройка logrotate"
fi

# 18. НАСТРОЙКА MOTD ===========================================================

log "Настройка статического MOTD..."

MOTD_FILE="/etc/motd"
PAM_SSHD_FILE="/etc/pam.d/sshd"
MOTD_BACKUP="${MOTD_FILE}.bak.$(date +%s)"
PAM_SSHD_BACKUP="${PAM_SSHD_FILE}.bak.$(date +%s)"
MOTD_FAILURE=""
MOTD_FILE_EXISTED=false

if [ -e "$MOTD_FILE" ]; then
    MOTD_FILE_EXISTED=true
    cp -a "$MOTD_FILE" "$MOTD_BACKUP"
fi
[ -e "$PAM_SSHD_FILE" ] && cp -a "$PAM_SSHD_FILE" "$PAM_SSHD_BACKUP"

cat > "$MOTD_FILE" << 'EOF'
БЕЗОПАСНЫЙ ДОСТУП

Вход по SSH разрешен только по ключу.
Действия на сервере могут регистрироваться в системном журнале.
EOF

if [ -f "$PAM_SSHD_FILE" ]; then
    MOTD_PAM_TEMP=$(mktemp)
    awk '
        /^[[:space:]]*#/ { print; next }
        /^[[:space:]]*session[[:space:]]+optional[[:space:]]+pam_motd\.so[[:space:]]+noupdate([[:space:]]|$)/ { next }
        /pam_motd\.so/ { print "# disabled by tuning-VPS: " $0; next }
        { print }
        END { print "session optional pam_motd.so noupdate" }
    ' "$PAM_SSHD_FILE" > "$MOTD_PAM_TEMP"
    install -m 0644 "$MOTD_PAM_TEMP" "$PAM_SSHD_FILE"
    rm -f "$MOTD_PAM_TEMP"
else
    MOTD_FAILURE="/etc/pam.d/sshd не найден"
fi

if [ -z "$MOTD_FAILURE" ] && [ ! -s "$MOTD_FILE" ]; then
    MOTD_FAILURE="/etc/motd пуст"
fi
if [ -z "$MOTD_FAILURE" ] && grep -Eq '^[[:space:]]*session[[:space:]]+.*pam_motd\.so.*motd=/run/motd\.dynamic' "$PAM_SSHD_FILE"; then
    MOTD_FAILURE="динамический MOTD остался активен в PAM"
fi
if [ -z "$MOTD_FAILURE" ] && [ "$(grep -Ec '^[[:space:]]*session[[:space:]]+.*pam_motd\.so[[:space:]]+noupdate([[:space:]]|$)' "$PAM_SSHD_FILE")" -ne 1 ]; then
    MOTD_FAILURE="статический MOTD не подключен в PAM ровно один раз"
fi
if [ -z "$MOTD_FAILURE" ] && ! sshd -T 2>/dev/null | grep -qx 'printmotd no'; then
    MOTD_FAILURE="эффективная настройка SSH PrintMotd отличается от no"
fi

if [ -z "$MOTD_FAILURE" ]; then
    add_result "OK" "MOTD" "статический /etc/motd подключен через PAM, динамический MOTD отключен"
else
    if [ "$MOTD_FILE_EXISTED" = true ]; then
        cp -a "$MOTD_BACKUP" "$MOTD_FILE"
    else
        rm -f "$MOTD_FILE"
    fi
    [ -e "$PAM_SSHD_BACKUP" ] && cp -a "$PAM_SSHD_BACKUP" "$PAM_SSHD_FILE"
    add_result "FAIL" "MOTD" "$MOTD_FAILURE; исходные файлы восстановлены"
fi


# 19. ПРОВЕРКА SSH С ПОМОЩЬЮ SSH-AUDIT ========================================

log "Установка и проверка SSH с помощью ssh-audit..."

# Установка ssh-audit
apt-get install -y -qq ssh-audit

# Проверка SSH конфигурации с помощью ssh-audit
if command -v ssh-audit &>/dev/null; then
    log "Запуск ssh-audit для проверки SSH..."
    
    # Проверяем локальный SSH сервер
    # ssh-audit возвращает ненулевой код при обнаружении проблем безопасности
    SSH_AUDIT_RESULT=$(ssh-audit 127.0.0.1 -p "$SSH_PORT" 2>&1) || true
    
    # Анализируем результат на наличие критических проблем
    if echo "$SSH_AUDIT_RESULT" | grep -qiE "(fail|critical|vulnerable)"; then
        warn "SSH аудит обнаружил критические проблемы"
        add_check 1 "SSH аудит (ssh-audit)"
        
        # Выводим детали проблем
        echo ""
        echo "===КРИТИЧЕСКИЕ ПРОБЛЕМЫ SSH АУДИТА==="
        echo "$SSH_AUDIT_RESULT" | grep -iE "(fail|critical|vulnerable)" | head -20
        echo ""
    else
        log "SSH аудит завершен (предупреждения не являются критическими)"
        add_check 0 "SSH аудит (ssh-audit)"
        
        # Выводим краткий результат аудита
        echo ""
        echo "===РЕЗУЛЬТАТ SSH АУДИТА==="
        echo "$SSH_AUDIT_RESULT" | grep -E "(algorithm|security|recommendation)" | head -20
        echo ""
    fi
else
    warn "ssh-audit не установлен"
    add_check 1 "SSH аудит (ssh-audit)"
fi

# 20. ДИАГНОСТИКА И ОТЧЕТ =====================================================

echo ""
echo "===ОТЧЕТ О НАСТРОЙКЕ==="
echo ""

# Проверки
echo "Статус компонентов:"
echo "-------------------"
for check in "${CHECKS[@]}"; do
    echo -e "  $check"
done

echo ""
echo "Текущие настройки:"
echo "------------------"
SSHD_TEST=$(sshd -t 2>&1 && echo -e "${GREEN}OK${NC}" || echo -e "${RED}ERROR${NC}")
echo -e "  SSH порт:        ${GREEN}$SSH_PORT${NC} (sshd -t: $SSHD_TEST)"
SSH_STATUS=$(systemctl is-active ssh 2>/dev/null || echo "unknown")
if [ "$SSH_STATUS" = "active" ]; then
    SSH_STATUS_FMT="${GREEN}$SSH_STATUS${NC}"
else
    SSH_STATUS_FMT="${RED}$SSH_STATUS${NC}"
fi
echo -e "  SSH статус:      $SSH_STATUS_FMT"
UFW_STATUS=$(LC_ALL=C ufw status 2>/dev/null | grep '^Status:' || echo "Status: unknown")
if [ "$UFW_STATUS" = "Status: active" ]; then
    UFW_STATUS_FMT="${GREEN}active${NC}"
elif [ "$UFW_STATUS" = "Status: inactive" ]; then
    UFW_STATUS_FMT="${YELLOW}inactive${NC}"
else
    UFW_STATUS_FMT="${RED}unknown${NC}"
fi
echo -e "  UFW статус:      $UFW_STATUS_FMT"
echo -e "  Открытые порты:  $(ss -tlnp 2>/dev/null | grep LISTEN | wc -l) шт."
if command -v docker &>/dev/null; then
    DOCKER_VER=$(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')
else
    DOCKER_VER="не установлен"
fi
echo -e "  Docker:          $DOCKER_VER"

echo ""
echo "Пользователи с sudo:"
echo "--------------------"
getent group sudo | cut -d: -f4 | tr ',' '\n' | while read -r user; do
    if [ -n "$user" ]; then
        echo "  - $user"
    fi
done

echo ""
echo "Проверка SSH конфигурации:"
echo "--------------------------"
echo -n "  Управляемый SSH: "
if [ -f "$SSH_MANAGED_CONFIG" ] &&
   grep -Fxq "Include $SSH_MANAGED_CONFIG" "$SSHD_CONFIG"; then
    echo -e "${GREEN}enabled${NC}"
else
    echo -e "${RED}FAIL${NC}"
fi

echo -n "  Порт применён:  "
ssh_effective_has "port $SSH_PORT" && echo -e "${GREEN}OK${NC}" || echo -e "${RED}FAIL${NC}"

echo -n "  PasswordAuth:   "
ssh_effective_has "passwordauthentication no" && echo -e "${GREEN}disabled${NC}" || echo -e "${RED}FAIL${NC}"

echo -n "  PubkeyAuth:     "
ssh_effective_has "pubkeyauthentication yes" && echo -e "${GREEN}enabled${NC}" || echo -e "${RED}FAIL${NC}"

echo -n "  Root SSH login: "
ssh_effective_has "permitrootlogin no" && echo -e "${GREEN}disabled${NC}" || echo -e "${YELLOW}temporary${NC}"

echo -n "  Root password:  "
passwd -S root 2>/dev/null | awk '{print $2}' | grep -q '^L' && echo -e "${GREEN}locked${NC}" || echo -e "${YELLOW}temporary unlocked${NC}"

echo ""
echo "Сетевые интерфейсы:"
echo "-------------------"
ip -4 addr show | grep inet | awk '{print "  " $2 " on " $NF}'

echo ""
echo "===ВАЖНЫЕ ДАННЫЕ==="
echo -e "  IP сервера:      ${GREEN}$SERVER_IP${NC}"
echo -e "  SSH порт:        ${GREEN}$SSH_PORT${NC}"
echo -e "  Пользователь:    ${GREEN}$NEW_USER${NC}"
echo ""
echo "Команда для подключения:"
echo -e "${YELLOW}  ssh -4 -p $SSH_PORT $NEW_USER@$SERVER_IP${NC}"
echo ""
echo "Если что-то не работает:"
echo "  1. Проверьте статус SSH: sudo systemctl status ssh"
echo "  2. Проверьте порты: sudo ss -tlnp | grep ssh"
echo "  3. Проверьте UFW: sudo ufw status verbose"
echo "  4. Логи SSH: sudo journalctl -u ssh -n 50"
echo ""
log "Настройка завершена!"

# Проверка компонентов, которыми управляет базовый сценарий. Не показываем
# веб-серверы, базы и runtime приложений: их установка принадлежит модулям.
echo ""
echo "===ПРОВЕРКА БАЗОВЫХ КОМПОНЕНТОВ==="
echo ""

echo "Зависимости сценария:"
check_pkg "python3"
echo ""

echo "Docker:"
check_pkg "docker"
detect_docker_state
echo "  Состояние: $DOCKER_STATE"

echo "Инструменты администрирования:"
check_pkg "mc"
check_pkg "tmux"
check_pkg "nano"
check_pkg "htop"
check_pkg "ncdu"
check_pkg "lsof"
check_pkg "jq"
check_pkg "rg" "ripgrep"
check_pkg "dig" "dnsutils"
check_pkg "nc" "netcat-openbsd"
check_pkg "rsync"
check_pkg "git"
check_pkg "curl"
check_pkg "wget"
echo ""

echo "Безопасность:"
check_service "ufw" "ufw"
check_service "fail2ban" "fail2ban"
echo ""

echo "Система:"
echo "  Диск:"
df -h / | tail -1 | awk '{printf "    Всего: %s, Свободно: %s (%.0f%%)\n", $2, $4, $5}'
echo ""
echo "  Память:"
free -h | grep "Mem:" | awk '{printf "    Всего: %s, Свободно: %s, Использовано: %s\n", $2, $4, $3}'
echo ""

# 21. УСТАНОВКА DOCKER (ОПЦИОНАЛЬНО)

detect_docker_state
if [ "$DOCKER_STATE" = "not-installed" ]; then
    echo ""
    read -p "Установить Docker? (y/N): " install_docker

    if [ "$install_docker" = "y" ] || [ "$install_docker" = "Y" ]; then
        log "Установка Docker..."
        DOCKER_INSTALL_OK=true

        # Не удаляем пакеты Docker/containerd автоматически: они могут
        # принадлежать уже работающему приложению. Конфликт установки должен
        # завершиться явной ошибкой, а не скрытой миграцией.
        apt-get install -y -qq ca-certificates curl gnupg || DOCKER_INSTALL_OK=false

        # Добавление репозитория Docker
        install -m 0755 -d /etc/apt/keyrings || DOCKER_INSTALL_OK=false
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc || DOCKER_INSTALL_OK=false
        chmod a+r /etc/apt/keyrings/docker.asc || DOCKER_INSTALL_OK=false

        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
          $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
          tee /etc/apt/sources.list.d/docker.list > /dev/null || DOCKER_INSTALL_OK=false

        apt-get update -qq || DOCKER_INSTALL_OK=false
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || DOCKER_INSTALL_OK=false

        # Лимит задаётся до первого запуска Docker, поэтому новые контейнеры
        # сразу получают bounded local logs. Чужой daemon здесь ещё не работает.
        if [ "$DOCKER_INSTALL_OK" = true ] && ! configure_docker_logging; then
            DOCKER_INSTALL_OK=false
            warn "Не удалось настроить ограничение Docker-логов: $DOCKER_LOGGING_CONFLICT"
        elif [ "$DOCKER_INSTALL_OK" = true ]; then
            DOCKER_LOGGING_CONFIGURED_DURING_INSTALL=true
        fi

        # Группа docker даёт эквивалент root-доступа через Docker socket. Не
        # выдаём её автоматически: владелец должен явно решить, нужен ли
        # user1 локальный Docker без sudo для будущих модулей приложений.
        if [ "$DOCKER_INSTALL_OK" = true ]; then
            read -r -p "Разрешить $NEW_USER управлять Docker без sudo? Это даёт права уровня root. (y/N): " docker_user_access
            if [ "$docker_user_access" = "y" ] || [ "$docker_user_access" = "Y" ]; then
                if usermod -aG docker "$NEW_USER"; then
                    DOCKER_USER_ACCESS="granted"
                else
                    DOCKER_INSTALL_OK=false
                    DOCKER_USER_ACCESS="failed"
                fi
            else
                DOCKER_USER_ACCESS="not-granted"
            fi
        fi

        # Пакет мог запустить daemon ещё до записи daemon.json. При первой
        # установке контейнеров ещё нет, поэтому restart безопасно применяет
        # политику логов до первого пользовательского контейнера.
        log "Запуск Docker сервиса..."
        if [ "$DOCKER_INSTALL_OK" = true ] && systemctl enable docker 2>/dev/null && systemctl restart docker 2>/dev/null; then
            sleep 2
            detect_docker_state
            if [ "$DOCKER_STATE" = "installed-running" ]; then
                DOCKER_LOGGING_CHANGED=false
                log "Docker установлен: $(docker --version)"
                add_result "OK" "Docker" "установлен и запущен"
                if [ "$DOCKER_USER_ACCESS" = "granted" ]; then
                    add_result "WARN" "Docker access" "$NEW_USER добавлен в группу docker; новый login получит права уровня root"
                elif [ "$DOCKER_USER_ACCESS" = "not-granted" ]; then
                    add_result "OK" "Docker access" "$NEW_USER не добавлен в группу docker; используйте sudo для Docker"
                fi
            else
                warn "Docker установлен, но не запущен. Попробуйте перезагрузить сервер."
                add_result "WARN" "Docker" "установлен, но daemon недоступен"
            fi
        else
            DOCKER_STATE="installation-failed"
            warn "Не удалось запустить Docker сервис. Возможные причины:"
            warn "  - Конфликт с systemd (если контейнер)"
            warn "  - Нужна перезагрузка сервера"
            warn "  - Проверьте: sudo systemctl status docker"
            add_result "FAIL" "Docker" "установка завершилась ошибкой или сервис не запустился"
        fi
    else
        DOCKER_STATE="skipped"
        log "Установка Docker пропущена"
        add_result "SKIP" "Docker" "пользователь отказался от установки"
    fi
else
    if [ "$DOCKER_STATE" = "installed-stopped" ]; then
        warn "Docker установлен, но daemon остановлен; не запускаем его без явного запроса."
        add_result "WARN" "Docker" "установлен, но daemon остановлен"
    elif [ "$DOCKER_STATE" = "installed-running" ]; then
        log "Docker уже установлен и запущен"
        add_result "OK" "Docker" "уже был установлен и доступен"
    else
        warn "Docker установлен, но daemon недоступен"
        add_result "WARN" "Docker" "установлен, но daemon недоступен"
    fi
fi

# На существующей установке меняем только совместимую политику. Docker намеренно
# не перезапускается при повторном запуске базы: это может остановить контейнеры.
if [ "$DOCKER_STATE" = "installed-running" ] || [ "$DOCKER_STATE" = "installed-stopped" ]; then
    if [ "$DOCKER_LOGGING_CONFIGURED_DURING_INSTALL" != true ] && ! configure_docker_logging; then
        warn "Ограничение Docker-логов не изменено: $DOCKER_LOGGING_CONFLICT"
    fi
    report_docker_logging_policy
fi

# UFW видит обычные процессы, но Docker может добавлять собственные firewall
# правила. Перед установкой приложений показываем только факт публикации портов.
if [ "$DOCKER_STATE" = "installed-running" ]; then
    report_docker_network_exposure
fi

echo ""
echo "===ФИНАЛЬНЫЙ ОТЧЕТ О НАСТРОЙКЕ==="
echo ""
# Выводим все проверки еще раз для наглядности
echo "Итоговый статус:"
echo "----------------"
for check in "${CHECKS[@]}"; do
    echo -e "  $check"
done
echo ""
echo "Опциональные компоненты:"
echo "  Docker: $DOCKER_STATE"
echo ""
echo "===НАСТРОЙКА ЗАВЕРШЕНА==="
echo ""
