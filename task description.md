2026-03-16 13:10
Tags: #VPS #linux 

# Настройка новой VPS с Ubuntu
## Предварительные моменты
1. Смена временного пароля root: `passwd`
2. Обновление:
```bash
apt update && apt upgrade -y
```
3. Создание нового пользователя
```bash
useradd -m -s /bin/bash user1
usermod -aG sudo user1
passwd user1
```
- установить пароль для user1
4. Зайти в новом окне с user1 и новым его паролем. Проверить, что все получилось: `sudo whoami`
		должно вывести: root
5. Делаем папку для хранения ssh ключей
```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
```
6. Кладем ssh ключ в домашнюю папку пользователя и переименовываем его в `~/.ssh/authorized_keys`. Это файл со списком ключей, но у нас пока один ключ
7. Закрываем доступ для других
```bash
chmod 600 ~/.ssh/authorized_keys
```
8. Редактируем sshd_config, чтобы закрыть доступ по паролю
```bash
sudo nano /etc/ssh/sshd_config
```
9. Добавляем или раскомментируем строки:
```
PasswordAuthentication no
PubkeyAuthentication yes
```
10. Перезапускаем ssh сервер: `sudo systemctl restart ssh` . На Debian он скорее всего будет: **sshd**
11. Настраиваем клиент и проверяем подключение с ssh ключом
12. На VDSina получил проблему, что конфиг ssh при перезагрузке ssh не применялся. Делал примерно следующее:
```bash
sudo systemctl stop ssh.socket
sudo systemctl disable ssh.socket
sudo systemctl enable ssh
sudo systemctl restart ssh
sudo nano /etc/ssh/sshd_config.d/50-cloud-init.conf # исправил и закомментировал строку с входом по паролю
```
Проверить, что ssh слушает нужные порты:
```bash
sudo ss -tlnp | grep ssh
```
Проверяем подключение на 2332 по ключу.
13. Можно перезагрузить сервер:
```bash
sudo reboot --force
```
и убедиться, что ssh работает и он на нужном порту.

> [!note] Итого:
>- SSH на другом порту (2332) (можно любой высокий порт)
>- разрешено подключение только по ключу
>- разрешены пользователи root и user1
> 

14. Настраиваем и включаем firewall:
```bash
sudo ufw allow 2332/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw status
```
14. Если он disable, то вспоминаем еще раз на каком порту у нас ssh и 
```bash
sudo ufw enable
```
15. Смотрим
```bash
sudo ufw status
```
удаляем нежные порты командой, например:
```bash
sudo ufw delete allow 22/tcp
```
15. Устанавливаем автоматические обновления:
```bash
sudo apt update
sudo apt install unattended-upgrades -y
sudo dpkg-reconfigure -plow unattended-upgrades
# включаем таймер
sudo systemctl enable apt-daily-upgrade.timer
sudo systemctl start apt-daily-upgrade.timer
```
Проверяем:
```bash
systemctl list-timers apt-daily-upgrade.timer
cat /var/log/unattended-upgrades/unattended-upgrades.log | tail -20
```
> [!note] Итого:
>- firewall настроен
>- автообновления настроены и включены
> 


## Дополнительные слова для поиска
- хостинг 
## Вышестоящие ссылки
- 
## Links
- 
