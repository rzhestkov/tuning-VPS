#!/bin/bash

# ==============================================================================
# Настройка VPS Ubuntu 24.04 с защитой от блокировки
# ==============================================================================

set -e  # Остановка при ошибке

# --- Настройки (можно изменить) ---
NEW_USER="user1"
SSH_PORT="2332"
GITHUB_USER="rzhestkov"
REPO_NAME="tuning-VPS"
SSH_KEY_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${REPO_NAME}/main/ssh/authorized_keys"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Массив для результатов диагностики
declare -a CHECKS

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

# Функция проверки закрыт ли порт 22
is_port_22_closed() {
    ! ufw status | grep -q "22/tcp"
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

# ==============================================================================
# 1. ПРОВЕРКИ ПЕРЕД СТАРТОМ
# ==============================================================================

log "=== Начало настройки VPS ==="
log "Проверка окружения..."

# Проверка root
if [ "$EUID" -ne 0 ]; then 
    error "Запустите скрипт через sudo или от root"
    exit 1
fi

# Проверка Ubuntu
if ! grep -q "Ubuntu" /etc/os-release; then
    warn "Это не Ubuntu. Скрипт рассчитан на Ubuntu 24.04"
fi

# Проверка подключения к GitHub
if ! curl -s --head "$SSH_KEY_URL" | head -n 1 | grep -q "200\|301\|302"; then
    error "Не могу получить доступ к GitHub. Проверьте GITHUB_USER и REPO_NAME"
    error "URL: $SSH_KEY_URL"
    exit 1
fi

# ==============================================================================
# 2. ОБНОВЛЕНИЕ СИСТЕМЫ
# ==============================================================================

log "Обновление пакетов..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq

# Установка mc если не установлен
if ! command -v mc &>/dev/null; then
    log "Установка mc..."
    apt-get install -y -qq mc
fi

add_check $? "Обновление системы"

# ==============================================================================
# 3. СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ
# ==============================================================================

log "Создание пользователя $NEW_USER..."

if id "$NEW_USER" &>/dev/null; then
    warn "Пользователь $NEW_USER уже существует"
else
    # Создаем пользователя без пароля (вход только по ключу)
    useradd -m -s /bin/bash "$NEW_USER"
    usermod -aG sudo "$NEW_USER"
    
    # Блокируем пароль для пользователя (вход только по SSH-ключу)
    passwd -l "$NEW_USER" 2>/dev/null || true
    
    log "Пользователь $NEW_USER создан. Вход только по SSH-ключу."
fi

# Настраиваем sudo без пароля (т.к. вход только по SSH-ключу) - всегда
log "Настройка sudo без пароля..."
echo "$NEW_USER ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-$NEW_USER
chmod 440 /etc/sudoers.d/99-$NEW_USER

add_check $(id "$NEW_USER" &>/dev/null; echo $?) "Создание пользователя $NEW_USER"

# ==============================================================================
# 4. НАСТРОЙКА SSH КЛЮЧЕЙ
# ==============================================================================

log "Настройка SSH ключей..."

USER_HOME="/home/$NEW_USER"
SSH_DIR="$USER_HOME/.ssh"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

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

# ==============================================================================
# 5. НАСТРОЙКА SSH (С ЗАЩИТОЙ ОТ БЛОКИРОВКИ)
# ==============================================================================

log "Настройка SSH сервера..."
log "${YELLOW}>>> ВАЖНО: Не закрывайте это окно до проверки подключения! <<<${NC}"

# Бэкап конфигов с сохранением имени файла для возможного восстановления
SSHD_BACKUP_FILE="/etc/ssh/sshd_config.bak.$(date +%s)"
cp /etc/ssh/sshd_config "$SSHD_BACKUP_FILE"
cp /etc/ssh/sshd_config.d/50-cloud-init.conf /etc/ssh/sshd_config.d/50-cloud-init.conf.bak.$(date +%s) 2>/dev/null || true

# 5.1 Отключаем cloud-init конфиг (проблема VDSina)
if [ -f "/etc/ssh/sshd_config.d/50-cloud-init.conf" ]; then
    log "Отключение cloud-init настроек SSH..."
    sed -i 's/^PasswordAuthentication yes/# PasswordAuthentication yes/' /etc/ssh/sshd_config.d/50-cloud-init.conf
    sed -i 's/^PermitRootLogin yes/# PermitRootLogin yes/' /etc/ssh/sshd_config.d/50-cloud-init.conf
fi

# 5.2 Основной конфиг SSH
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
EOF

# 5.3 Проверка конфигурации
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

# 5.4 Исправление проблемы с socket (VDSina и др.)
log "Переключение SSH с socket на service..."
systemctl stop ssh.socket 2>/dev/null || true
systemctl disable ssh.socket 2>/dev/null || true
systemctl enable ssh.service

# 5.5 Перезапуск SSH
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

# ==============================================================================
# 6. FIREWALL (С ЗАЩИТОЙ ОТ БЛОКИРОВКИ)
# ==============================================================================

log "Настройка UFW (файрвол)..."

apt-get install -y -qq ufw

# Отключаем UFW перед настройкой (если был включен), чтобы избежать блокировки
ufw disable 2>/dev/null || true

# Политики по умолчанию
ufw default deny incoming
ufw default allow outgoing

# Удаляем только стандартное SSH правило для порта 22, оставляем остальные
ufw delete allow 22/tcp 2>/dev/null || true

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

# ==============================================================================
# 7. АВТООБНОВЛЕНИЯ
# ==============================================================================

log "Настройка автоматических обновлений безопасности..."

apt-get install -y -qq unattended-upgrades apt-listchanges

# Включаем автоматические обновления
dpkg-reconfigure -plow unattended-upgrades -fnoninteractive

# Настройка: только security-обновления, без перезагрузки сервисов
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
EOF

systemctl enable apt-daily-upgrade.timer
systemctl start apt-daily-upgrade.timer

add_check $? "Автоматические обновления"

# ==============================================================================
# 9. ЗАКРЫТИЕ СТАРОГО SSH ПОРТА (ФИНАЛЬНЫЙ ЭТАП)
# ==============================================================================

if is_port_22_closed; then
    log "Порт 22 уже закрыт, пропускаем"
    add_check 0 "Закрытие порта 22 (уже закрыт)"
else
    warn "=========================================="
    warn "ВНИМАНИЕ! Сейчас будет закрыт порт 22."
    warn "=========================================="
    warn "Перед продолжением:"
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

# ==============================================================================
# 10. ДИАГНОСТИКА И ОТЧЕТ
# ==============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                  ОТЧЕТ О НАСТРОЙКЕ                         ║"
echo "╚════════════════════════════════════════════════════════════╝"
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
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                     ВАЖНЫЕ ДАННЫЕ                          ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo -e "  IP сервера:      ${GREEN}$(curl -s ifconfig.me || hostname -I | awk '{print $1}')${NC}"
echo -e "  SSH порт:        ${GREEN}$SSH_PORT${NC}"
echo -e "  Пользователь:    ${GREEN}$NEW_USER${NC}"
echo ""
echo "Команда для подключения:"
echo -e "${YELLOW}  ssh -p $SSH_PORT $NEW_USER@$(curl -s ifconfig.me || echo 'YOUR_SERVER_IP')${NC}"
echo ""
echo "Если что-то не работает:"
echo "  1. Проверьте статус SSH: sudo systemctl status ssh"
echo "  2. Проверьте порты: sudo ss -tlnp | grep ssh"
echo "  3. Проверьте UFW: sudo ufw status verbose"
echo "  4. Логи SSH: sudo journalctl -u ssh -n 50"
echo ""
log "Настройка завершена!"

# ==============================================================================
# ФУНКЦИИ ПРОВЕРКИ ПАКЕТОВ
# ==============================================================================

# Функция проверки пакета (всегда возвращает 0 для set -e)
check_pkg() {
    local pkg=$1
    local name=${2:-$1}
    if command -v "$pkg" &>/dev/null; then
        local version=$($pkg --version 2>/dev/null | head -1 | awk '{print $NF}' || echo "установлен")
        printf "  ${GREEN}✓${NC} %-15s %s\n" "$name" "$version"
        return 0
    else
        printf "  ${RED}✗${NC} %-15s %s\n" "$name" "-"
        return 0
    fi
}

# Функция проверки наличия пакета (для условий, возвращает 0/1)
is_pkg_installed() {
    command -v "$1" &>/dev/null
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

# Проверка Docker отдельно
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║         ПРОВЕРКА ПРЕДУСТАНОВЛЕННЫХ ПАКЕТОВ                ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

echo "Python & Dev:"
check_pkg "python3"
check_pkg "pip3"
echo ""

echo "Docker:"
    DOCKER_INSTALLED=false
    if is_pkg_installed "docker"; then
        check_pkg "docker"
        DOCKER_INSTALLED=true
    else
        check_pkg "docker"
    fi
    check_pkg "docker-compose"
echo ""

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

# ==============================================================================
# УСТАНОВКА DOCKER (ОПЦИОНАЛЬНО)
# ==============================================================================

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
