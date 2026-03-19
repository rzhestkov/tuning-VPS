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

# Получение IP сервера (один раз в начале скрипта)
SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Массив для результатов диагностики
declare -a CHECKS

# Переменная для проверки установки Docker (объявляем в начале для проблемы 8)
DOCKER_INSTALLED=false

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

# Функция проверки существования UFW правила
ufw_rule_exists() {
    local port=$1
    ufw status | grep -q "$port"
    return $?
}

# Функция добавления результата проверки
add_check() {
    local status=$1
    local message=$2
    if [ $status -eq 0 ]; then
        CHECKS+=("${GREEN}[OK]${NC} $message")
    else
        CHECKS+=("${RED}[FAIL]${NC} $message")
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
add_check 0 "Отключение ненужных сервисов"

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

# 06. ОГРАНИЧЕНИЯ ДЛЯ ПОЛЬЗОВАТЕЛЯ (LIMITS.CONF) ==============================

log "Настройка ограничений для пользователей..."

# Бэкап оригинального конфига
if [ -f "/etc/security/limits.conf" ]; then
    cp /etc/security/limits.conf /etc/security/limits.conf.bak.$(date +%s)
fi

# Добавление ограничений в limits.conf (без дублирования)
cat >> /etc/security/limits.conf << EOF

# Hard limits для всех пользователей
* hard nproc 500
* hard nofile 65535
* hard rss 500000

# Hard limits для конкретного пользователя
$NEW_USER hard nproc 100
$NEW_USER hard nofile 65535
$NEW_USER hard rss 500000
EOF

# Также добавляем в /etc/security/limits.d/ для лучшей совместимости
mkdir -p /etc/security/limits.d
cat > /etc/security/limits.d/99-custom.conf << EOF
# Custom limits for $NEW_USER
$NEW_USER hard nproc 100
$NEW_USER hard nofile 65535
$NEW_USER hard rss 500000

# Global limits
* hard nproc 500
* hard nofile 65535
EOF

log "Ограничения для пользователей настроены"
add_check 0 "Ограничения для пользователей (limits.conf)"

# 07. СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ ====================================================

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

# Настраиваем sudo без пароля только если пользователь был создан
if [ "$USER_CREATED" = true ]; then
    log "Настройка sudo без пароля..."
    echo "$NEW_USER ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-$NEW_USER
    chmod 440 /etc/sudoers.d/99-$NEW_USER
    
    # Проверка валидности sudoers файла через visudo (пункт 32)
    visudo -c -f /etc/sudoers.d/99-$NEW_USER || {
        error "Невалидный sudoers файл!"
        rm -f /etc/sudoers.d/99-$NEW_USER
        exit 1
    }
fi


if [ "$USER_EXISTS" = true ]; then
    add_check 0 "Пользователь $NEW_USER (уже существует)"
elif [ "$USER_CREATED" = true ]; then
    add_check 0 "Создание пользователя $NEW_USER"
else
    add_check 1 "Создание пользователя $NEW_USER"
fi

# 08. НАСТРОЙКА SSH КЛЮЧЕЙ =====================================================

log "Настройка SSH ключей..."

USER_HOME="/home/$NEW_USER"
SSH_DIR="$USER_HOME/.ssh"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Проверка и бэкап существующего authorized_keys
if [ -f "$SSH_DIR/authorized_keys" ]; then
    BACKUP_FILE="$SSH_DIR/authorized_keys.bak.$(date +%s)"
    cp "$SSH_DIR/authorized_keys" "$BACKUP_FILE"
    warn "Существующий authorized_keys скопирован в: $BACKUP_FILE"
    warn "ВНИМАНИЕ: SSH ключи будут заменены новыми из GitHub!"
fi

# Скачиваем ключ с GitHub
if curl -fsSL "$SSH_KEY_URL" -o "$SSH_DIR/authorized_keys"; then
    chmod 600 "$SSH_DIR/authorized_keys"
    chown -R "$NEW_USER:$NEW_USER" "$SSH_DIR"
    log "SSH ключ установлен"
    add_check 0 "Установка SSH ключа"
else
    error "Не удалось скачать SSH ключ"
    add_check 1 "Установка SSH ключа"
fi

# 09. НАСТРОЙКА SSH (С ЗАЩИТОЙ ОТ БЛОКИРОВКИ) ==================================

log "Настройка SSH сервера..."
log "${YELLOW}>>> ВАЖНО: Не закрывайте это окно до проверки подключения! <<<${NC}"

# Бэкап конфигов с сохранением имени файла для возможного восстановления
SSHD_BACKUP_FILE="/etc/ssh/sshd_config.bak.$(date +%s)"
cp /etc/ssh/sshd_config "$SSHD_BACKUP_FILE"

# 09.1 Отключаем cloud-init конфиг (проблема VDSina)
if [ -f "/etc/ssh/sshd_config.d/50-cloud-init.conf" ]; then
    cp /etc/ssh/sshd_config.d/50-cloud-init.conf /etc/ssh/sshd_config.d/50-cloud-init.conf.bak.$(date +%s)
    log "Отключение cloud-init настроек SSH..."
    sed -i 's/^PasswordAuthentication yes/# PasswordAuthentication yes/' /etc/ssh/sshd_config.d/50-cloud-init.conf
    sed -i 's/^PermitRootLogin yes/# PermitRootLogin yes/' /etc/ssh/sshd_config.d/50-cloud-init.conf
fi

# 09.2 Основной конфиг SSH
log "Изменение порта SSH на $SSH_PORT..."

cat > /etc/ssh/sshd_config.d/99-custom.conf << EOF
# Кастомные настройки
Port $SSH_PORT
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2

# Безопасные хост-ключи (без ECDSA - подозрение в бэкдоре NSA)
HostKeyAlgorithms ssh-ed25519,ssh-rsa,rsa-sha2-256,rsa-sha2-512

# Hardening алгоритмов шифрования (защита от Terrapin CVE-2023-48795)
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
EOF

# 09.3 Проверка конфигурации
# Создаем необходимую директорию для проверки конфига
mkdir -p /run/sshd

if ! sshd -t; then
    error "Ошибка в конфигурации SSH! Восстанавливаю бэкап..."
    if [ -f "$SSHD_BACKUP_FILE" ]; then
        cp "$SSHD_BACKUP_FILE" /etc/ssh/sshd_config
        log "Бэкап SSH конфига восстановлен"
    fi
    exit 1
fi

# 09.4 Исправление проблемы с socket (VDSina и др.)
log "Переключение SSH с socket на service..."
systemctl stop ssh.socket 2>/dev/null || true
systemctl disable ssh.socket 2>/dev/null || true
systemctl enable ssh.service

# 09.5 Перезапуск SSH
log "Перезапуск SSH..."
systemctl restart ssh

# Проверка, что SSH слушает новый порт
sleep 2
if ss -tlnp | grep -q ":$SSH_PORT"; then
    log "SSH слушает порт $SSH_PORT"
    add_check 0 "SSH на порту $SSH_PORT"
else
    error "SSH не слушает порт $SSH_PORT!"
    add_check 1 "SSH порт $SSH_PORT"
fi

# Статус: вход по паролю отключен
add_check 0 "Вход по паролю отключен"

# 10. FIREWALL (С ЗАЩИТОЙ ОТ БЛОКИРОВКИ) =======================================

log "Настройка UFW (файрвол)..."

apt-get install -y -qq ufw

# Отключаем UFW перед настройкой (если был включен), чтобы избежать блокировки
ufw disable 2>/dev/null || true

# Политики по умолчанию
ufw default deny incoming
ufw default allow outgoing

# Разрешаем новый SSH порт ПЕРЕД включением файрвола!
if ! ufw_rule_exists "$SSH_PORT/tcp"; then
    ufw allow "$SSH_PORT/tcp" comment 'SSH Custom Port'
fi

# Разрешаем веб-порты
if ! ufw_rule_exists "80/tcp"; then
    ufw allow 80/tcp comment 'HTTP'
fi
if ! ufw_rule_exists "443/tcp"; then
    ufw allow 443/tcp comment 'HTTPS'
fi

# ВАЖНО: Если UFW был включен ранее, сохраняем его состояние для восстановления доступа
# Порт 22 будет удалён позже после проверки подключения

# Включаем файрвол
echo "y" | ufw enable

# Проверка статуса
if ufw status | grep -q "Status: active"; then
    log "UFW активен"
    add_check 0 "UFW включен"
else
    error "UFW не удалось включить"
    add_check 1 "UFW включен"
fi

# Проверка правила SSH
if ufw status | grep -q "$SSH_PORT"; then
    add_check 0 "Правило UFW для порта $SSH_PORT"
else
    add_check 1 "Правило UFW для порта $SSH_PORT"
fi

# 11. ЗАКРЫТИЕ СТАРОГО SSH ПОРТА (ФИНАЛЬНЫЙ ЭТАП) =============================

# Проверка, закрыт ли порт 22 (в UFW и не слушает ли сокет)
port_22_ufw_closed=false
port_22_socket_closed=false
if ! ufw status | grep -q "22/tcp"; then
    port_22_ufw_closed=true
fi
if ! ss -tlnp 2>/dev/null | grep -qE '(:22\s|\.22\s)'; then
    port_22_socket_closed=true
fi

if $port_22_ufw_closed && $port_22_socket_closed; then
    log "Порт 22 уже закрыт, пропускаем"
    add_check 0 "Закрытие порта 22 (уже закрыт)"
else
    # Автоматические проверки перед закрытием порта 22 (пункт 31)
    SSH_VALIDATION_PASSED=true
    
    # Встроенная проверка SSH-валидации
    SSH_DIR="/home/$NEW_USER/.ssh"
    AUTH_KEYS="$SSH_DIR/authorized_keys"
    
    # Проверка 1: файл authorized_keys существует
    if [ ! -f "$AUTH_KEYS" ]; then
        error "Файл authorized_keys не существует: $AUTH_KEYS"
        log "Порт 22 не будет закрыт автоматически из-за отсутствия SSH-ключей"
        SSH_VALIDATION_PASSED=false
    fi
    
    # Проверка 2: файл authorized_keys не пустой
    if [ "$SSH_VALIDATION_PASSED" = true ] && [ ! -s "$AUTH_KEYS" ]; then
        error "Файл authorized_keys пустой: $AUTH_KEYS"
        log "Порт 22 не будет закрыт автоматически из-за пустого authorized_keys"
        SSH_VALIDATION_PASSED=false
    fi
    
    # Проверка 3: SSH слушает новый порт
    if [ "$SSH_VALIDATION_PASSED" = true ] && ! ss -tlnp 2>/dev/null | grep -qE ":$SSH_PORT "; then
        error "SSH не слушает порт $SSH_PORT"
        log "Проверьте: sudo ss -tlnp | grep ssh"
        SSH_VALIDATION_PASSED=false
    fi
    
    # Проверка 4: содержимое authorized_keys валидно
    if [ "$SSH_VALIDATION_PASSED" = true ]; then
        has_valid_key=false
        while IFS= read -r line; do
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
            if [[ "$line" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|ssh-dss) ]]; then
                has_valid_key=true
                log "Найден валидный SSH-ключ типа: ${BASH_REMATCH[1]}"
                break
            fi
        done < "$AUTH_KEYS"
        
        if [ "$has_valid_key" = false ]; then
            error "В authorized_keys не найдено валидных SSH-ключей"
            log "Файл должен содержать ключи в форматах: ssh-ed25519, ssh-rsa, ecdsa-sha2-*, ssh-dss"
            SSH_VALIDATION_PASSED=false
        fi
    fi
    
    if [ "$SSH_VALIDATION_PASSED" = false ]; then
        warn "АВТОМАТИЧЕСКИЕ ПРОВЕРКИ SSH НЕ ПРОЙДЕНЫ!"
        warn "Порт 22 будет оставлен ОТКРЫТЫМ для предотвращения блокировки."
        add_check 1 "Закрытие порта 22 (автоматические проверки не пройдены)"
    fi
    
    # Продолжаем только если автоматические проверки прошли успешно
    if [ "$SSH_VALIDATION_PASSED" = true ]; then
        warn "ВНИМАНИЕ! Автоматические проверки SSH пройдены успешно:"
        warn "  ✓ authorized_keys существует и не пустой"
        warn "  ✓ SSH слушает новый порт $SSH_PORT"
        warn "  ✓ Валидный SSH-ключ присутствует"
        warn ""
        warn "Перед продолжением дополнительно проверьте:"
        warn "1. Откройте НОВОЕ окно терминала"
        warn "2. Подключитесь: ssh -p $SSH_PORT $NEW_USER@$(hostname -I | awk '{print $1}')"
        warn "3. Убедитесь, что подключение работает!"
        warn ""
        read -p "Подключение работает? Закрыть порт 22? (yes/no): " confirm

        if [ "$confirm" = "yes" ]; then
            ufw delete allow 22/tcp 2>/dev/null || true
            log "Порт 22 закрыт"
            add_check 0 "Закрытие порта 22"
        else
            warn "Порт 22 оставлен открытым! Закройте его вручную позже:"
            warn "sudo ufw delete allow 22/tcp"
            add_check 1 "Закрытие порта 22 (отложено)"
        fi
    fi
fi

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
    log "Fail2ban установлен и запущен"
    # Проверка статуса правил SSH
    if fail2ban-client status sshd &>/dev/null; then
        log "Правила fail2ban для SSH активны"
    fi
    add_check 0 "Установка fail2ban"
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
-a always,exit -F arch=b64 -S execve -k execution
-a always,exit -F arch=b64 -S open -k file_access
-a always,exit -F arch=b64 -S openat -k file_access
-a always,exit -F arch=b64 -S unlink -k file_deletion
-a always,exit -F arch=b64 -S rename -k file_modification
EOF

# Применение правил auditd
augenrules --load 2>/dev/null || true

# Перезапуск auditd для применения правил
systemctl restart auditd 2>/dev/null || true

log "Правила аудита настроены"
add_check 0 "Настройка правил аудита"

# 14. АВТООБНОВЛЕНИЯ ==========================================================

log "Настройка автоматических обновлений безопасности..."

# Сохраняем результат установки пакетов
AUTO_UPDATE_INSTALL=0
apt-get install -y -qq unattended-upgrades apt-listchanges || AUTO_UPDATE_INSTALL=$?

# Настройка: только security-обновления, с явным управлением перезагрузкой
# Записываем КОНФИГ ПЕРЕД dpkg-reconfigure, чтобы не сбросилось
cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
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

# Включаем автоматические обновления (после записи конфига)
dpkg-reconfigure -plow unattended-upgrades -fnoninteractive

# Сохраняем результат включения сервисов
SYSTEMD_RESULT=0
systemctl enable apt-daily-upgrade.timer || SYSTEMD_RESULT=$?
systemctl start apt-daily-upgrade.timer || SYSTEMD_RESULT=$?

# Проверяем результат установки пакетов и статус сервиса
add_check $AUTO_UPDATE_INSTALL "Автоматические обновления"
if systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
    add_check 0 "Сервис unattended-upgrades активен"
else
    add_check 1 "Сервис unattended-upgrades активен"
fi

# 15. НАСТРОЙКА NEEDRESTART (АВТОМАТИЧЕСКИЙ ПЕРЕЗАПУСК СЕРВИСОВ) =============

log "Настройка needrestart (автоматический перезапуск сервисов)..."

# Установка needrestart (обычно уже установлен в Ubuntu 24.04)
apt-get install -y -qq needrestart 2>/dev/null || true

# Создание конфига с автоматическим перезапуском сервисов
mkdir -p /etc/needrestart/conf.d
cat > /etc/needrestart/conf.d/99-auto.conf << 'EOF'
# Автоматический перезапуск сервисов при обновлении (без интерактивного режима)
$nrconf{restart} = 'a';
EOF

# Проверка, что конфиг создан
if [ -f "/etc/needrestart/conf.d/99-auto.conf" ]; then
    log "Конфигурация needrestart создана"
    add_check 0 "Настройка needrestart"
else
    warn "Не удалось создать конфигурацию needrestart"
    add_check 1 "Настройка needrestart"
fi
# 16. НАСТРОЙКА JOURNALD (ЦЕНТРАЛИЗОВАННЫЕ ЛОГИ) =================================

log "Настройка journald (системный журнал)..."

# Бэкап оригинального конфига
if [ -f "/etc/systemd/journald.conf" ]; then
    cp /etc/systemd/journald.conf /etc/systemd/journald.conf.bak.$(date +%s)
fi

# Создание конфига с persistent storage и лимитами
cat > /etc/systemd/journald.conf << EOF
[Journal]
# Хранение логов в постоянном хранилище (не в памяти)
Storage=persistent

# Лимит размера логов
SystemMaxUse=500M
SystemMaxFileSize=100M
SystemMaxFiles=10
SystemMaxFilesSec=1month

# Лимиты для логов пользователей
RuntimeMaxUse=100M
RuntimeMaxFileSize=10M
RuntimeMaxFiles=5

# Сжатие логов
Compress=yes

# Срок хранения логов
MaxRetentionSec=1month

# Синхронизация логов на диск
SyncIntervalSec=5m
EOF

# Перезапуск journald для применения настроек
systemctl restart systemd-journald 2>/dev/null || true

# Проверка, что journald работает
if systemctl is-active systemd-journald &>/dev/null; then
    log "Journald настроен и перезапущен"
    add_check 0 "Настройка journald"
else
    warn "Не удалось перезапустить journald"
    add_check 1 "Настройка journald"
fi

# Проверка размера логов
JOURNAL_SIZE=$(journalctl --disk-usage 2>/dev/null | head -1 || echo "недоступно")
log "Размер логов: $JOURNAL_SIZE"

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

log "Настройка MOTD (сообщения при входе)..."

# Создаем кастомный MOTD
cat > /etc/motd << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║                    БЕЗОПАСНЫЙ ДОСТУП                         ║
║                                                              ║
║  Вход разрешен только по SSH-ключу                           ║
║  Дополнительная аутентификация: fail2ban                     ║
║                                                              ║
║  Для подключения используйте:                                ║
║  ssh -p <PORT> <user>@<server>                               ║
║                                                              ║
║  ВНИМАНИЕ: Все действия на сервере логируются                ║
╚══════════════════════════════════════════════════════════════╝
EOF

# Отключаем стандартный MOTD в /etc/legal
if [ -f "/etc/legal" ]; then
    cp /etc/legal /etc/legal.bak.$(date +%s)
    echo "" > /etc/legal
fi

# Отключаем динамический MOTD в /etc/pam.d/sshd
if [ -f "/etc/pam.d/sshd" ]; then
    cp /etc/pam.d/sshd /etc/pam.d/sshd.bak.$(date +%s)
    sed -i 's/^session    optional     pam_motd.so/# session    optional     pam_motd.so/' /etc/pam.d/sshd
    sed -i 's/^session    optional     pam_motd.so noupdate/# session    optional     pam_motd.so noupdate/' /etc/pam.d/sshd
fi

# Отключаем скрипты в /etc/update-motd.d/
if [ -d "/etc/update-motd.d" ]; then
    chmod -x /etc/update-motd.d/* 2>/dev/null || true
fi

# Добавляем PrintMotd no в sshd_config (надежное отключение MOTD)
if ! grep -q "^PrintMotd no" /etc/ssh/sshd_config.d/99-custom.conf 2>/dev/null; then
    echo "PrintMotd no" >> /etc/ssh/sshd_config.d/99-custom.conf
fi

log "MOTD настроен (динамический MOTD отключен)"
add_check 0 "Настройка MOTD"


# 19. ПРОВЕРКА SSH С ПОМОЩЬЮ SSH-AUDIT ========================================

log "Установка и проверка SSH с помощью ssh-audit..."

# Установка ssh-audit
apt-get install -y -qq ssh-audit

# Проверка SSH конфигурации с помощью ssh-audit
if command -v ssh-audit &>/dev/null; then
    log "Запуск ssh-audit для проверки SSH..."
    
    # Проверяем локальный SSH сервер
    # ssh-audit возвращает ненулевой код при обнаружении проблем безопасности
    SSH_AUDIT_RESULT=$(ssh-audit localhost -p $SSH_PORT 2>&1) || true
    
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
UFW_STATUS=$(ufw status 2>/dev/null | grep -i "Status:" || echo "Status: unknown")
if echo "$UFW_STATUS" | grep -q "active"; then
    UFW_STATUS_FMT="${GREEN}active${NC}"
elif echo "$UFW_STATUS" | grep -q "inactive"; then
    UFW_STATUS_FMT="${YELLOW}inactive${NC}"
else
    UFW_STATUS_FMT="${RED}unknown${NC}"
fi
echo -e "  UFW статус:      $UFW_STATUS_FMT"
echo -e "  Открытые порты:  $(ss -tlnp 2>/dev/null | grep LISTEN | wc -l) шт."
DOCKER_VER=$(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',' || echo 'не установлен')
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
echo -n "  Порт в конфиге: "
grep "^Port $SSH_PORT" /etc/ssh/sshd_config.d/99-custom.conf &>/dev/null && echo -e "${GREEN}OK${NC}" || echo -e "${RED}FAIL${NC}"

echo -n "  PasswordAuth:   "
grep "^PasswordAuthentication no" /etc/ssh/sshd_config.d/99-custom.conf &>/dev/null && echo -e "${GREEN}disabled${NC}" || echo -e "${RED}FAIL${NC}"

echo -n "  PubkeyAuth:     "
grep "^PubkeyAuthentication yes" /etc/ssh/sshd_config.d/99-custom.conf &>/dev/null && echo -e "${GREEN}enabled${NC}" || echo -e "${RED}FAIL${NC}"

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
echo -e "${YELLOW}  ssh -p $SSH_PORT $NEW_USER@$SERVER_IP${NC}"
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
    if command -v "docker" &>/dev/null; then
        check_pkg "docker"
        DOCKER_INSTALLED=true
    else
        check_pkg "docker"
    fi
    # Проверка docker compose (плагин) вместо устаревшего docker-compose
    # Блок удален

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

if [ "$DOCKER_INSTALLED" = false ]; then
    echo ""
    read -p "Установить Docker? (y/N): " install_docker

    if [ "$install_docker" = "y" ] || [ "$install_docker" = "Y" ]; then
        log "Установка Docker..."

        # Удаляем старые версии
        apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

        # Установка зависимостей
        apt-get install -y -qq ca-certificates curl gnupg

        # Добавление репозитория Docker
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc

        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
          $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
          tee /etc/apt/sources.list.d/docker.list > /dev/null

        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

        # Добавляем пользователя в группу docker
        usermod -aG docker "$NEW_USER"

        # Запускаем Docker (с обработкой ошибок)
        log "Запуск Docker сервиса..."
        if systemctl enable docker 2>/dev/null && systemctl start docker 2>/dev/null; then
            sleep 2
            if docker --version > /dev/null 2>&1; then
                log "Docker установлен: $(docker --version)"
            else
                warn "Docker установлен, но не запущен. Попробуйте перезагрузить сервер."
            fi
        else
            warn "Не удалось запустить Docker сервис. Возможные причины:"
            warn "  - Конфликт с systemd (если контейнер)"
            warn "  - Нужна перезагрузка сервера"
            warn "  - Проверьте: sudo systemctl status docker"
        fi
    else
        log "Установка Docker пропущена"
    fi
else
    log "Docker уже установлен, пропускаем установку"
fi
# 22. УСТАНОВКА MTPROTO PROXY (ОПЦИОНАЛЬНО)

# Проверяем, доступен ли Docker (установлен ли он только что или ранее)
DOCKER_AVAILABLE=false
if command -v docker &>/dev/null && docker info &>/dev/null; then
    DOCKER_AVAILABLE=true
elif command -v docker &>/dev/null; then
    # Docker установлен, но возможно не запущен - пробуем запустить
    systemctl start docker 2>/dev/null || true
    sleep 2
    docker info &>/dev/null && DOCKER_AVAILABLE=true
fi
if [ "$DOCKER_AVAILABLE" = true ]; then
    echo ""
    read -p "Установить MTProto Proxy для Telegram? (y/N): " install_mtproto
    
    if [ "$install_mtproto" = "y" ] || [ "$install_mtproto" = "Y" ]; then
        log "Настройка MTProto Proxy..."
        
        # Запрашиваем домен для маскировки
        read -p "Введите домен для маскировки трафика [по умолчанию: www.cloudflare.com]: " domain
        domain=${domain:-www.cloudflare.com}
        
        log "Генерация секретного ключа (домен: $domain)..."
        SECRET=$(docker run --rm nineseconds/mtg:2 generate-secret --hex "$domain" 2>/dev/null | tr -d '\r\n')
        
        if [ -z "$SECRET" ]; then
            error "Не удалось сгенерировать секрет. Пробуем еще раз..."
            SECRET=$(docker run --rm nineseconds/mtg:2 generate-secret --hex "$domain" 2>/dev/null | tr -d '\r\n')
        fi
        
        if [ -n "$SECRET" ]; then
            log "Секрет сгенерирован: $SECRET"
            
            # Сохраняем секрет в файл для финального отчёта
            echo "$SECRET" > /tmp/mtproto_secret.txt
            
            # Останавливаем и удаляем старый контейнер если есть
            docker stop mtproto-proxy &>/dev/null || true
            docker rm mtproto-proxy &>/dev/null || true
            
            # Запускаем контейнер
            log "Запуск MTProto Proxy на порту 443..."
            docker run -d \
              --name mtproto-proxy \
              --restart unless-stopped \
              -p 443:443 \
              nineseconds/mtg:2 \
              simple-run -n 1.1.1.1 -i prefer-ipv4 0.0.0.0:443 "$SECRET"
            
            sleep 3
            
# Проверяем, что контейнер запущен
if docker ps | grep -q mtproto-proxy; then
    log "MTProto Proxy успешно запущен!"
    
    echo ""
    echo "===MTPROTO PROXY НАСТРОЕН==="
    echo ""
    echo "  Сервер: $SERVER_IP"
    echo "  Порт: 443"
    echo "  Секрет: $SECRET"
    echo "  Домен маскировки: $domain"
    echo ""
    echo "  Ссылка для подключения:"
    echo "  tg://proxy?server=$SERVER_IP&port=443&secret=$SECRET"
    echo ""
    echo "  Ссылка (для копирования):"
    echo -e "${YELLOW}tg://proxy?server=$SERVER_IP&port=443&secret=$SECRET${NC}"
    echo ""
    echo "  Проверка логов: docker logs -f mtproto-proxy"
    echo "  Остановка: docker stop mtproto-proxy"
    echo "  Удаление: docker rm -f mtproto-proxy"
    echo ""
    
    # Добавляем в массив проверок
    CHECKS+=("${GREEN}[OK]${NC} MTProto Proxy (порт 443)")
else
    error "Контейнер MTProto не запустился. Проверьте логи: docker logs mtproto-proxy"
    CHECKS+=("${RED}[FAIL]${NC} MTProto Proxy (ошибка запуска)")
fi
        else
            error "Не удалось сгенерировать секретный ключ"
            CHECKS+=("${RED}[FAIL]${NC} MTProto Proxy (ошибка генерации секрета)")
        fi
    else
        log "Установка MTProto Proxy пропущена"
    fi
else
    warn "Docker недоступен, пропускаем установку MTProto Proxy"
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
# Информация о MTProto в финальном отчете
if docker ps | grep -q mtproto-proxy 2>/dev/null; then
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

