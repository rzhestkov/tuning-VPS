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
MTPROTO_STATE="not-requested"
MTPROTO_IMPLEMENTATION=""

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
        awk -v port="$port" '$1 == port && $2 == "ALLOW" && $3 == "IN" && $0 !~ /\(v6\)/ { found=1 } END { exit !found }'
}

# Базовый сценарий владеет только своим SSH-правилом. Другие allow rules могут
# принадлежать хостеру или приложению, поэтому их нельзя удалять автоматически.
ufw_unexpected_ipv4_allow_rules() {
    LC_ALL=C ufw status 2>/dev/null |
        awk -v ssh_port="$SSH_PORT/tcp" '
            $2 == "ALLOW" && $3 == "IN" && $0 !~ /\(v6\)/ && $1 != ssh_port { print }
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

# Установка mc если не установлен
if ! command -v mc &>/dev/null; then
    log "Установка mc..."
    apt-get install -y -qq mc
fi

add_check $UPDATE_RESULT "Обновление системы"

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

# Бэкап оригинального конфига
if [ -f "/etc/sysctl.conf" ]; then
    cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%s)
fi

# Создание конфига с параметрами безопасности в /etc/sysctl.d/
cat > /etc/sysctl.d/99-hardening.conf << 'EOF'
# Защита от SYN-flood
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2

# Отключение IP forwarding (если не нужен)
net.ipv4.ip_forward = 0

# IPv6 не используется в этой конфигурации: уменьшаем поверхность атаки.
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# Ограничение ICMP
net.ipv4.icmp_echo_ignore_all = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Защита от IP spoofing
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.rp_filter = 1

# Ограничение доступа к kernel logs
kernel.dmesg_restrict = 1

# Защита от symlink attacks
fs.protected_hardlinks = 1
fs.protected_symlinks = 1

# Ограничение использования памяти для root
vm.overcommit_memory = 0

# Защита от оверфлоуров
kernel.randomize_va_space = 2

# Дополнительные параметры безопасности
net.ipv4.tcp_rfc1337 = 1
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Автоматическая перезагрузка при kernel panic
kernel.panic = 10
kernel.panic_on_oops = 1
EOF

# Применение настроек
sysctl --system >/dev/null 2>&1 && log "Параметры ядра применены" || warn "Не удалось применить все параметры ядра"

# Проверка основных параметров
if sysctl -n net.ipv4.tcp_syncookies | grep -q "1"; then
    add_check 0 "Hardening ядра (sysctl)"
else
    add_check 1 "Hardening ядра (sysctl)"
fi

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
            systemctl stop ssh.service >/dev/null 2>&1 || true
            systemctl start ssh.socket >/dev/null 2>&1 || failed=true
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
{
    printf 'Include %s\n' "$SSH_WORK/final-managed"
    awk '$0 != "Include /etc/ssh/tuning-vps.conf" {print}' "$SSHD_CONFIG"
} > "$SSH_WORK/final-main"
{
    printf 'Include %s\n' "$SSH_WORK/temporary-managed"
    awk '$0 != "Include /etc/ssh/tuning-vps.conf" {print}' "$SSHD_CONFIG"
} > "$SSH_WORK/temporary-main"
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

# Точные байты main нужны для идемпотентной проверки. При отсутствии изменений
# повторный запуск не перезапускает SSH и не запрашивает лишнее подтверждение.
{
    printf 'Include %s\n' "$SSH_MANAGED_CONFIG"
    awk '$0 != "Include /etc/ssh/tuning-vps.conf" {print}' "$SSHD_CONFIG"
} > "$SSH_WORK/runtime-main"
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
    {
        printf 'Include %s\n' "$SSH_MANAGED_CONFIG"
        awk '$0 != "Include /etc/ssh/tuning-vps.conf" {print}' "$SSH_WORK/original-main"
    } > "$SSHD_CONFIG"
    sshd -t || exit 1
    SSH_SYSTEMD_TOUCHED=true
    systemctl disable --now ssh.socket >/dev/null 2>&1 || exit 1
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

# 13. НАСТРОЙКА AUDITD (АУДИТ ДЕЙСТВИЙ) =======================================

log "Настройка auditd (аудит действий)..."

# Установка auditd
apt-get install -y -qq auditd audispd-plugins

# Включение и запуск auditd
systemctl enable auditd 2>/dev/null || true
systemctl start auditd 2>/dev/null || true

# Проверка статуса auditd
if systemctl is-active auditd &>/dev/null; then
    log "Auditd установлен и запущен"
    add_check 0 "Установка auditd"
else
    warn "Не удалось запустить auditd"
    add_check 1 "Установка auditd"
fi

# Настройка правил аудита для важных событий
cat > /etc/audit/rules.d/99-custom.rules << 'EOF'
# Аудит изменений в системных файлах
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k identity

# Аудит изменений в SSH конфигурации
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /etc/ssh/sshd_config.d/ -p wa -k sshd_config

# Аудит входов в систему
-w /var/log/auth.log -p wa -k auth_log

# Аудит выполнения команд
-w /bin/bash -p x -k bash_execution
-w /usr/bin/bash -p x -k bash_execution

# Аудит изменений в cron
-w /etc/cron.d -p wa -k cron
-w /etc/cron.daily -p wa -k cron
-w /etc/cron.hourly -p wa -k cron
-w /etc/cron.monthly -p wa -k cron
-w /etc/cron.weekly -p wa -k cron
-w /etc/crontab -p wa -k cron

# Аудит загрузки системы
-w /etc/init.d -p wa -k init
-w /etc/rc.local -p wa -k init

# Аудит сетевых подключений
-a always,exit -F arch=b64 -S connect -k network_connect
-a always,exit -F arch=b64 -S accept -k network_connect

# Аудит важных системных вызовов
-a always,exit -F arch=b64 -S execve -F euid=0 -k privileged_execution
-a always,exit -F arch=b64 -S chmod,fchmod,fchmodat,chown,fchown,fchownat,lchown -F euid=0 -k file_perm_mod
-a always,exit -F arch=b64 -S sethostname,setdomainname -k system_locale
EOF

# Применение правил auditd
AUGENRULES_RESULT=0
augenrules --load >/dev/null 2>&1 || AUGENRULES_RESULT=$?

# Перезапуск auditd для применения правил
systemctl restart auditd 2>/dev/null || true

log "Правила аудита настроены"
AUDIT_RULES_VALIDATION_OK=$AUGENRULES_RESULT
if ! auditctl -l 2>/dev/null | grep -q "sshd_config"; then
    AUDIT_RULES_VALIDATION_OK=1
fi
add_check $AUDIT_RULES_VALIDATION_OK "Настройка правил аудита"

# 14. АВТООБНОВЛЕНИЯ ==========================================================

log "Настройка автоматических обновлений безопасности..."

UNATTENDED_CONFIG="/etc/apt/apt.conf.d/50unattended-upgrades"
UNATTENDED_BACKUP="${UNATTENDED_CONFIG}.bak.$(date +%s)"
UNATTENDED_CONFIG_EXISTED=false
AUTO_UPDATE_FAILURE=""

if [ -f "$UNATTENDED_CONFIG" ]; then
    UNATTENDED_CONFIG_EXISTED=true
    cp "$UNATTENDED_CONFIG" "$UNATTENDED_BACKUP"
fi

if ! apt-get install -y -qq unattended-upgrades apt-listchanges; then
    AUTO_UPDATE_FAILURE="не удалось установить unattended-upgrades"
else
    dpkg-reconfigure -plow unattended-upgrades -fnoninteractive >/dev/null 2>&1 || true

    cat > "$UNATTENDED_CONFIG" << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::SyslogEnable "true";
# Отключаем автоматическую перезагрузку (управление перезагрузкой вручную)
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOF

    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true

    APT_EFFECTIVE_CONFIG=$(apt-config dump 2>/dev/null)
    if ! grep -Fq 'Unattended-Upgrade::Allowed-Origins:: "${distro_id}:${distro_codename}-security";' <<< "$APT_EFFECTIVE_CONFIG"; then
        AUTO_UPDATE_FAILURE="security origin отсутствует в итоговой APT-конфигурации"
    elif ! grep -Fq 'Unattended-Upgrade::Automatic-Reboot "false";' <<< "$APT_EFFECTIVE_CONFIG"; then
        AUTO_UPDATE_FAILURE="автоматическая перезагрузка не отключена"
    elif ! systemctl is-enabled --quiet apt-daily.timer apt-daily-upgrade.timer || \
         ! systemctl is-active --quiet apt-daily.timer apt-daily-upgrade.timer; then
        AUTO_UPDATE_FAILURE="таймеры apt-daily и apt-daily-upgrade не включены или не активны"
    fi
fi

if [ -z "$AUTO_UPDATE_FAILURE" ]; then
    add_result "OK" "Unattended-upgrades" "security-обновления активны, автоматическая перезагрузка отключена"
else
    if [ "$UNATTENDED_CONFIG_EXISTED" = true ]; then
        cp "$UNATTENDED_BACKUP" "$UNATTENDED_CONFIG"
    else
        rm -f "$UNATTENDED_CONFIG"
    fi
    add_result "FAIL" "Unattended-upgrades" "$AUTO_UPDATE_FAILURE"
fi

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

# 16. НАСТРОЙКА JOURNALD (ЦЕНТРАЛИЗОВАННЫЕ ЛОГИ) =================================

log "Настройка journald (системный журнал)..."

JOURNALD_CONFIG="/etc/systemd/journald.conf"
JOURNALD_BACKUP="${JOURNALD_CONFIG}.bak.$(date +%s)"
JOURNALD_FAILURE=""
JOURNALD_CHECK_SINCE=$(date --iso-8601=seconds)
JOURNALD_CONFIG_EXISTED=false
if [ -f "$JOURNALD_CONFIG" ]; then
    JOURNALD_CONFIG_EXISTED=true
    cp "$JOURNALD_CONFIG" "$JOURNALD_BACKUP"
fi

cat > "$JOURNALD_CONFIG" << 'EOF'
[Journal]
Storage=persistent
SystemMaxUse=500M
SystemMaxFileSize=100M
SystemMaxFiles=10
RuntimeMaxUse=100M
RuntimeMaxFileSize=10M
RuntimeMaxFiles=5
Compress=yes
MaxRetentionSec=1month
SyncIntervalSec=5m
EOF

mkdir -p /var/log/journal
systemd-tmpfiles --create --prefix /var/log/journal >/dev/null 2>&1 || true

if ! systemctl restart systemd-journald; then
    JOURNALD_FAILURE="не удалось перезапустить systemd-journald"
elif ! systemctl is-active --quiet systemd-journald; then
    JOURNALD_FAILURE="systemd-journald не активен после перезапуска"
elif [ ! -d /var/log/journal ]; then
    JOURNALD_FAILURE="persistent storage /var/log/journal отсутствует"
elif journalctl -u systemd-journald --since "$JOURNALD_CHECK_SINCE" --no-pager 2>/dev/null | grep -qiE 'unknown key|invalid|failed|error'; then
    JOURNALD_FAILURE="journald сообщил об ошибке или неизвестной директиве"
else
    JOURNALD_EFFECTIVE=$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null)
    if ! grep -qx 'Storage=persistent' <<< "$JOURNALD_EFFECTIVE" || \
       ! grep -qx 'SystemMaxUse=500M' <<< "$JOURNALD_EFFECTIVE"; then
        JOURNALD_FAILURE="итоговая конфигурация не содержит ожидаемых значений"
    fi
fi

if [ -z "$JOURNALD_FAILURE" ]; then
    JOURNAL_SIZE=$(journalctl --disk-usage 2>/dev/null | head -1 || echo "размер недоступен")
    add_result "OK" "Journald" "persistent storage активен, лимит 500M; $JOURNAL_SIZE"
else
    if [ "$JOURNALD_CONFIG_EXISTED" = true ]; then
        cp "$JOURNALD_BACKUP" "$JOURNALD_CONFIG"
    else
        rm -f "$JOURNALD_CONFIG"
    fi
    systemctl restart systemd-journald >/dev/null 2>&1 || true
    add_result "FAIL" "Journald" "$JOURNALD_FAILURE; исходный конфиг восстановлен"
fi

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

# Проверка предустановленных пакетов
echo ""
echo "===ПРОВЕРКА ПРЕДУСТАНОВЛЕННЫХ ПАКЕТОВ==="
echo ""

echo "Python & Dev:"
check_pkg "python3"
check_pkg "pip3"
echo ""

echo "Docker:"
check_pkg "docker"
detect_docker_state
echo "  Состояние: $DOCKER_STATE"

echo "Веб-серверы:"
check_service "nginx" "nginx"
check_service "apache2" "apache"
echo ""

echo "Базы данных:"
check_service "mysql" "mysql"
check_service "postgresql" "postgresql"
check_service "redis-server" "redis"
echo ""

echo "Инструменты:"
check_pkg "git"
check_pkg "curl"
check_pkg "wget"
check_pkg "node" "nodejs"
check_pkg "npm"
check_pkg "nano"
check_pkg "vim"
check_pkg "htop"
check_pkg "mc"
echo ""

echo "Безопасность:"
check_service "ufw" "ufw"
check_service "fail2ban" "fail2ban"
check_pkg "certbot"
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

        # Добавляем пользователя в группу docker
        usermod -aG docker "$NEW_USER" || DOCKER_INSTALL_OK=false

        # Запускаем Docker (с обработкой ошибок)
        log "Запуск Docker сервиса..."
        if [ "$DOCKER_INSTALL_OK" = true ] && systemctl enable docker 2>/dev/null && systemctl start docker 2>/dev/null; then
            sleep 2
            detect_docker_state
            if [ "$DOCKER_STATE" = "installed-running" ]; then
                log "Docker установлен: $(docker --version)"
                add_result "OK" "Docker" "установлен и запущен"
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

# UFW видит обычные процессы, но Docker может добавлять собственные firewall
# правила. Перед установкой приложений показываем только факт публикации портов.
if [ "$DOCKER_STATE" = "installed-running" ]; then
    report_docker_network_exposure
fi

# 22. УСТАНОВКА MTPROTO PROXY (ОПЦИОНАЛЬНО)

# MTProto можно устанавливать только через проверенный работающий Docker daemon.
if [ "$DOCKER_STATE" != "skipped" ] && [ "$DOCKER_STATE" != "installation-failed" ]; then
    detect_docker_state
fi
if [ "$DOCKER_STATE" = "installed-running" ]; then
    echo ""
    MTPROTO_IMPLEMENTATION=""
    read -p "Установить сервис MTProto? (y/N): " install_mtproto

    if [ "$install_mtproto" = "y" ] || [ "$install_mtproto" = "Y" ]; then
        echo ""
        echo "Выберите реализацию MTProto:"
        echo "  1. MTProto от 9seconds [9seconds/mtg](https://github.com/9seconds/mtg)"
        echo "  2. MTProto от seriyps [seriyps/mtproto_proxy](https://github.com/seriyps/mtproto_proxy)"
        echo "  0. Отказаться"
        read -p "Ваш выбор [0-2]: " mtproto_choice

        case "$mtproto_choice" in
            1) MTPROTO_IMPLEMENTATION="9seconds/mtg" ;;
            2) MTPROTO_IMPLEMENTATION="seriyps/mtproto_proxy" ;;
            *) MTPROTO_STATE="skipped" ;;
        esac
    else
        MTPROTO_STATE="skipped"
    fi

    if [ -n "$MTPROTO_IMPLEMENTATION" ]; then
        log "Настройка MTProto Proxy ($MTPROTO_IMPLEMENTATION)..."

        # SNI должен выглядеть правдоподобно для страны, в которой расположен сервер.
        while true; do
            read -p "Какой SNI использовать для маскировки? Укажите HTTPS-домен, соответствующий стране сервера: " domain
            domain=$(echo "$domain" | tr '[:upper:]' '[:lower:]' | xargs)
            if [[ "$domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
                break
            fi
            warn "Введите только доменное имя без https://, порта и пути (например: www.example.de)."
        done

        if [ "$MTPROTO_IMPLEMENTATION" = "9seconds/mtg" ]; then
            log "Генерация секретного ключа 9seconds/mtg (SNI: $domain)..."
            SECRET=$(docker run --rm nineseconds/mtg:2 generate-secret --hex "$domain" 2>/dev/null | tr -d '\r\n')

            if [ -z "$SECRET" ]; then
                error "Не удалось сгенерировать секрет. Пробуем еще раз..."
                SECRET=$(docker run --rm nineseconds/mtg:2 generate-secret --hex "$domain" 2>/dev/null | tr -d '\r\n')
            fi
        else
            log "Генерация секретного ключа seriyps/mtproto_proxy (SNI: $domain)..."
            BASE_SECRET=$(openssl rand -hex 16 2>/dev/null)
            DOMAIN_HEX=$(printf '%s' "$domain" | od -An -tx1 | tr -d ' \n')
            MTPROTO_TAG="00000000000000000000000000000000"
            if [[ "$BASE_SECRET" =~ ^[a-f0-9]{32}$ ]] && [ -n "$DOMAIN_HEX" ]; then
                SECRET="ee${BASE_SECRET}${DOMAIN_HEX}"
            else
                SECRET=""
            fi
        fi

        if [ -n "$SECRET" ]; then
            log "Секрет сгенерирован: $SECRET"

            # Сохраняем секрет и реализацию для финального отчёта.
            echo "$SECRET" > /tmp/mtproto_secret.txt
            echo "$MTPROTO_IMPLEMENTATION" > /tmp/mtproto_implementation.txt

            # Единое имя контейнера и порт исключают одновременную работу двух реализаций.
            docker stop mtproto-proxy &>/dev/null || true
            docker rm mtproto-proxy &>/dev/null || true

            log "Запуск MTProto Proxy ($MTPROTO_IMPLEMENTATION) на порту 443..."
            if [ "$MTPROTO_IMPLEMENTATION" = "9seconds/mtg" ]; then
                docker run -d \
                  --name mtproto-proxy \
                  --restart unless-stopped \
                  -p 443:443 \
                  nineseconds/mtg:2 \
                  simple-run -n 1.1.1.1 -i prefer-ipv4 0.0.0.0:443 "$SECRET"
            else
                docker run -d \
                  --name mtproto-proxy \
                  --restart unless-stopped \
                  --network host \
                  seriyps/mtproto-proxy:latest \
                  -p 443 -s "$BASE_SECRET" -t "$MTPROTO_TAG" -a tls
            fi

            sleep 3

            # Проверяем, что контейнер запущен.
            if docker ps --format '{{.Names}}' | grep -qx mtproto-proxy; then
                log "MTProto Proxy успешно запущен!"

                echo ""
                echo "===MTPROTO PROXY НАСТРОЕН==="
                echo ""
                echo "  Реализация: $MTPROTO_IMPLEMENTATION"
                echo "  Сервер: $SERVER_IP"
                echo "  Порт: 443"
                echo "  Секрет: $SECRET"
                echo "  SNI маскировки: $domain"
                echo ""
                echo "  Ссылка для подключения:"
                echo -e "${YELLOW}tg://proxy?server=$SERVER_IP&port=443&secret=$SECRET${NC}"
                echo ""
                echo "  Проверка логов: docker logs -f mtproto-proxy"
                echo "  Остановка: docker stop mtproto-proxy"
                echo "  Удаление: docker rm -f mtproto-proxy"
                echo ""

                MTPROTO_STATE="running"
                add_result "OK" "MTProto Proxy" "$MTPROTO_IMPLEMENTATION запущен на порту 443"
            else
                error "Контейнер MTProto не запустился. Проверьте логи: docker logs mtproto-proxy"
                MTPROTO_STATE="failed"
                add_result "FAIL" "MTProto Proxy" "$MTPROTO_IMPLEMENTATION: контейнер не запустился"
            fi
        else
            error "Не удалось сгенерировать секретный ключ"
            MTPROTO_STATE="failed"
            add_result "FAIL" "MTProto Proxy" "$MTPROTO_IMPLEMENTATION: не удалось сгенерировать секрет"
        fi
    else
        log "Установка MTProto Proxy пропущена"
        add_result "SKIP" "MTProto Proxy" "пользователь отказался от установки"
    fi
else
    MTPROTO_STATE="unavailable"
    warn "Docker недоступен, пропускаем установку MTProto Proxy"
    add_result "SKIP" "MTProto Proxy" "Docker daemon недоступен"
fi

# ФИНАЛЬНЫЙ ОТЧЕТ С MTPROTO

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
echo "  MTProto: $MTPROTO_STATE${MTPROTO_IMPLEMENTATION:+ ($MTPROTO_IMPLEMENTATION)}"
# Информация о MTProto в финальном отчете
if [ "$DOCKER_STATE" = "installed-running" ] && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx mtproto-proxy; then
    # Пытаемся получить секрет из сохранённого файла или из логов
    MTPROTO_SECRET=""
    if [ -f /tmp/mtproto_secret.txt ]; then
        MTPROTO_SECRET=$(cat /tmp/mtproto_secret.txt)
    fi
    
    # Если файл пустой, пробуем извлечь из логов Docker
    if [ -z "$MTPROTO_SECRET" ]; then
        MTPROTO_SECRET=$(docker logs mtproto-proxy 2>&1 | grep -oP '[a-f0-9]{64}' | head -1)
    fi
    
    echo ""
    echo "MTProto Proxy активен:"
    echo "----------------------"
    echo -e "  Статус: ${GREEN}запущен${NC}"
    if [ -f /tmp/mtproto_implementation.txt ]; then
        echo "  Реализация: $(cat /tmp/mtproto_implementation.txt)"
    fi
    echo "  Порт: 443"
    echo "  IP: $SERVER_IP"
    if [ -n "$MTPROTO_SECRET" ]; then
        echo "  Секрет: $MTPROTO_SECRET"
        echo ""
        echo "  Поделиться ссылкой:"
        echo -e "  ${YELLOW}https://t.me/proxy?server=$SERVER_IP&port=443&secret=$MTPROTO_SECRET${NC}"
    else
        echo ""
        echo "  Секрет: (не удалось получить автоматически)"
        echo "  Получите секрет вручную: docker logs mtproto-proxy"
    fi
fi
echo ""
echo "===НАСТРОЙКА ЗАВЕРШЕНА==="
echo ""

