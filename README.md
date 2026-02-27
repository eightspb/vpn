# VPN Схема: СПб → VPS1 (Москва) → VPS2 (США, Бруклин)

## Архитектура

```
[Ты в СПб]
    ↓ AmneziaWG (Junk пакеты, UDP обфускация) порт 51820
[VPS #1: Яндекс 89.169.179.233 Москва]  — awg1: 10.9.0.1
    ↓ AmneziaWG туннель (зашифрованный) порт 51821→51820
[VPS #2: foxcloud 38.135.122.81 США, Бруклин] — awg0: 10.8.0.2
    ↓ AdGuard Home (DNS блокировка рекламы, порт 53)
    ↓ NAT → выход в интернет с IP 38.135.122.81
[ChatGPT ✅ Claude ✅ YouTube без рекламы ✅]
```

## Сети

| Сеть | Назначение |
|------|-----------|
| 10.8.0.0/24 | Туннель VPS1↔VPS2 |
| 10.9.0.0/24 | Клиентская сеть |
| 10.8.0.1 | VPS1 в туннеле |
| 10.8.0.2 | VPS2 в туннеле (AdGuard DNS) |
| 10.9.0.1 | VPS1 клиентский шлюз |
| 10.9.0.2 | Клиент СПб |

## Ключи

Не храните приватные ключи и пароли в `README.md`.

- Приватные ключи и секреты: только локально в `vpn-output/keys.env` (файл в `.gitignore`)
- Публичные ключи можно хранить в рабочей документации при необходимости
- При подозрении на утечку сразу пересоздайте пары ключей на `VPS1`/`VPS2`

## Установка клиента (Windows)

1. Скачать **AmneziaVPN** с https://amnezia.org/ru/downloads
2. Импортировать файл `vpn-output/client.conf` (или переименованный локальный файл)
3. Подключиться

## AdGuard Home

- Web UI: http://38.135.122.81:3000
- Логин: `admin`
- Пароль: задавайте через `--adguard-pass` или переменные окружения (см. `.env.example`)

## SSH доступ

```bash
# VPS1 (Яндекс Москва)
ssh -i ~/.ssh/<your_key> <user>@89.169.179.233

# VPS2 (foxcloud США, Бруклин)
ssh -i ~/.ssh/<your_key> <user>@38.135.122.81
```

## Конфиги на серверах

- VPS1: `/etc/amnezia/amneziawg/awg0.conf` (туннель к VPS2)
- VPS1: `/etc/amnezia/amneziawg/awg1.conf` (клиентский интерфейс)
- VPS2: `/etc/amnezia/amneziawg/awg0.conf` (туннель от VPS1)

## Гигиена секретов

- Скопируйте шаблон: `cp .env.example .env` и заполните своими данными.
- Не коммитьте `.env` и `vpn-output/*` (это уже добавлено в `.gitignore`).
- Если секреты раньше были в `README.md`, считайте их скомпрометированными и ротируйте.

## Деплой (полный и по отдельности)

- Все деплой-скрипты (`deploy.sh`, `deploy-vps1.sh`, `deploy-vps2.sh`) автоматически запускают security-обновления (`dpkg --configure -a`, `upgrade`, `dist-upgrade`, `autoremove`) через `security-update.sh`.
- **Полный деплой обоих VPS:** `bash deploy.sh --vps1-ip ... --vps1-key ... --vps2-ip ... --vps2-key ...`
- **Только VPS1 (точка входа):** `bash deploy-vps1.sh --vps1-ip ... --vps1-key ... --vps2-ip ...`  
  Создаёт ключи, настраивает AmneziaWG на VPS1, сохраняет `vpn-output/keys.env` и `vpn-output/client.conf`.
- **Только VPS2 (точка выхода):** сначала запустите `deploy-vps1.sh`, затем  
  `bash deploy-vps2.sh --vps2-ip ... --vps2-key ... --keys-file ./vpn-output/keys.env`
  > `deploy-vps2.sh` корректно читает и `LF`, и `CRLF` формат `keys.env`.

## Отдельный запуск security-обновлений

```bash
sudo bash security-update.sh
```

## Обновления без интерактива

Если на сервере всплывают вопросы по `cloud.cfg`/`dpkg`, используйте:

```bash
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a UCF_FORCE_CONFFOLD=1
dpkg --force-confdef --force-confold --configure -a
apt-get update
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" dist-upgrade
apt-get -y autoremove --purge
```

## Управление

```bash
# Статус туннелей
sudo awg show all

# Перезапуск
sudo systemctl restart awg-quick@awg0
sudo systemctl restart awg-quick@awg1

# Логи
sudo journalctl -u awg-quick@awg0 -f
```
