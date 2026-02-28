# VPN Схема: СПб → VPS1 (Москва) → VPS2 (США, Бруклин)

## Архитектура

```
[Устройства: iOS / Android / Windows]
    ↓ AmneziaWG (Junk пакеты, UDP обфускация) порт 51820
[VPS #1: Яндекс 130.193.41.13 Москва]  — awg1: 10.9.0.1
    ↓ AmneziaWG туннель (зашифрованный) порт 51821→51820
[VPS #2: foxcloud 38.135.122.81 США, Бруклин] — awg0: 10.8.0.2
    ↓ youtube-proxy (DNS блокировка + HTTPS фильтр рекламы YouTube)
    ↓ NAT → выход в интернет с IP 38.135.122.81
[ChatGPT ✅ Claude ✅ YouTube без рекламы ✅]
```

## Сети

| Сеть | Назначение |
|------|-----------|
| 10.8.0.0/24 | Туннель VPS1↔VPS2 |
| 10.9.0.0/24 | Клиентская сеть |
| 10.8.0.1 | VPS1 в туннеле |
| 10.8.0.2 | VPS2 в туннеле (youtube-proxy DNS) |
| 10.9.0.1 | VPS1 клиентский шлюз |
| 10.9.0.2 | Клиент СПб |

## Ключи

Не храните приватные ключи и пароли в `README.md`.

- Приватные ключи и секреты: только локально в `vpn-output/keys.env` (файл в `.gitignore`)
- Публичные ключи можно хранить в рабочей документации при необходимости
- При подозрении на утечку сразу пересоздайте пары ключей на `VPS1`/`VPS2`

## Подключение устройств — пошаговая инструкция

### Шаг 1. Получить конфиг-файл

После деплоя конфиги сохраняются локально в папке `vpn-output/`:

```
vpn-output/
  client.conf                     ← первое устройство (создаётся автоматически при deploy)
  peer_phone_10_9_0_3.conf        ← телефон (add-peer)
  peer_tablet_10_9_0_4.conf       ← планшет (add-peer)
  ...
```

**Для первого устройства** — файл `vpn-output/client.conf` уже готов после `bash manage.sh deploy`.

**Для каждого следующего устройства** — генерируется отдельный конфиг:
```bash
bash manage.sh add-peer --peer-name myphone
# → сохранит vpn-output/peer_myphone_10_9_0_X.conf
```

### Шаг 2. Передать конфиг на устройство

Конфиги лежат на этом компьютере в папке `c:\WORK_MICS\vpn\vpn-output\`.

> Конфиг содержит приватный ключ — отправляйте только себе, не в публичные чаты.

---

#### Способ А — Telegram (себе в «Избранное»)

1. Открыть Telegram → найти чат **«Избранное»** (Saved Messages) — это личный чат с собой
2. Нажать скрепку → **Файл** → выбрать `vpn-output\client.conf` (или `peer_*.conf`)
3. Отправить
4. На телефоне открыть Telegram → Избранное → нажать на файл → **Открыть в AmneziaVPN**

---

#### Способ Б — Email себе

1. Открыть почту (Gmail, Яндекс и т.д.) → написать письмо себе
2. Прикрепить файл `vpn-output\client.conf`
3. Отправить
4. На телефоне открыть письмо → нажать на вложение → **Открыть в AmneziaVPN**

---

#### Способ В — QR-код (сканировать с экрана)

Самый удобный способ — не нужно передавать файл, просто показать QR на экране компьютера и отсканировать телефоном.

**Установить утилиту для генерации QR (один раз):**
```bash
# В WSL / Git Bash
pip install qrcode[pil] 2>/dev/null || pip3 install qrcode[pil]

# Или через winget (Windows)
winget install qrencode
```

**Сгенерировать QR для конфига:**
```bash
# В WSL — показывает QR прямо в терминале
cat vpn-output/client.conf | qr

# Для конкретного пира
cat vpn-output/peer_myphone_10_9_0_3.conf | qr
```

**На телефоне:**
- Открыть **AmneziaVPN** → `+` → **Сканировать QR-код** → навести камеру на экран компьютера

> AmneziaVPN поддерживает импорт конфига через QR — это официальная функция приложения.

### Шаг 3. Установить AmneziaVPN и импортировать конфиг

| Платформа | Приложение | Ссылка |
|-----------|-----------|--------|
| Windows | AmneziaVPN | https://amnezia.org/ru/downloads |
| Android | AmneziaVPN | Google Play / https://amnezia.org/ru/downloads |
| iOS | AmneziaVPN | App Store / https://amnezia.org/ru/downloads |
| macOS | AmneziaVPN | https://amnezia.org/ru/downloads |

**Импорт конфига:**
- Открыть AmneziaVPN → `+` → **Импортировать конфиг** → выбрать `.conf` файл
- Нажать **Подключиться**

### Шаг 4. Установить Root CA (опционально — только для MITM-фильтрации JSON в браузере)

> **Примечание:** Этот шаг **необязателен**. YouTube-приложение на iOS/Android работает нормально без CA-сертификата — DNS-блокировка рекламных доменов работает автоматически. CA-сертификат нужен только если вы хотите включить MITM-фильтрацию рекламных блоков из JSON-ответов YouTube в браузере (Chrome, Firefox, Safari на macOS/Windows).

Сначала подключиться к VPN, затем установить сертификат:

- **Windows (автоматически):**
  ```powershell
  powershell -ExecutionPolicy Bypass -File install-ca.ps1
  ```
  Запускать от имени администратора. Скрипт сам проверит VPN и установит сертификат.

- **Windows (вручную):** открыть `http://10.8.0.2:8080` → скачать `ca.crt` → двойной клик → Установить → Локальный компьютер → Доверенные корневые центры сертификации → перезапустить браузер

- **iOS:** Safari → `http://10.8.0.2:8080` → скачать → `Настройки → Загружен профиль → Установить` → `Основные → Об устройстве → Доверие сертификатам → включить`

- **Android:** скачать `ca.crt` с `http://10.8.0.2:8080` → `Настройки → Безопасность → Установить сертификат → Сертификат ЦС`

### Просмотр всех подключённых устройств

```bash
# Список пиров и их последний handshake (на VPS1)
ssh -i ~/.ssh/ssh-key-1772056840349 slava@130.193.41.13 "sudo awg show awg1"
```

Вывод покажет каждый пир: публичный ключ, IP, время последнего соединения и трафик.

## YouTube Ad Proxy

Заменяет AdGuard Home. Работает на VPS2 как системный сервис.

| Компонент | Адрес | Назначение |
|---|---|---|
| DNS-сервер | `10.8.0.2:53` | Блокировка рекламных/трекинг/malware доменов, кэш ответов по TTL; слушает только на VPN-интерфейсе |
| HTTPS-прокси | `10.8.0.2:443` | Опциональный MITM-перехват `youtubei.googleapis.com` для фильтрации рекламы из JSON; слушает только на VPN-интерфейсе |
| CA-сервер | `http://10.8.0.2:8080` | Скачать Root CA сертификат (только через VPN-туннель, только для MITM-режима) |

**Основной метод блокировки — DNS.** DNS-сервер блокирует рекламные домены на уровне резолвинга — это работает и в браузере, и в YouTube-приложении на iOS/Android без каких-либо дополнительных настроек на устройстве.

**MITM-перехват отключён по умолчанию.** YouTube-приложение на iOS/Android использует certificate pinning и не принимает подменные сертификаты, поэтому MITM-фильтрация JSON включается только опционально — для браузеров, где CA-сертификат установлен вручную.

> **YouTube-приложение на iOS/Android работает без установки CA-сертификата** — DNS-блокировка рекламных доменов достаточна для базовой фильтрации.

**Безопасность CA-сервера:** порт 8080 слушает только на VPN-интерфейсе `10.8.0.2` и заблокирован для публичного интернета через iptables. Скачать сертификат можно только после подключения к VPN.

### Установка Root CA на устройства (опционально, только для MITM-фильтрации в браузере)

> **Примечание:** CA-сертификат нужен только если вы хотите включить MITM-фильтрацию JSON в браузере (Chrome, Firefox, Safari на macOS/Windows). YouTube-приложение на iOS/Android работает нормально без CA-сертификата — DNS-блокировка рекламных доменов работает автоматически.

Подключись к VPN, затем установи сертификат:

- **Windows (автоматически):** `powershell -ExecutionPolicy Bypass -File install-ca.ps1`
- **Windows (вручную):** открыть `http://10.8.0.2:8080` → скачать `ca.crt` → двойной клик → Установить → Локальный компьютер → Доверенные корневые центры сертификации → перезапустить браузер
- **iOS:** Safari → `http://10.8.0.2:8080` → скачать → `Настройки → Загружен профиль → Установить` → `Основные → Об устройстве → Доверие сертификатам → включить`
- **Android:** скачать `ca.crt` с `http://10.8.0.2:8080` → `Настройки → Безопасность → Установить сертификат → Сертификат ЦС`

### Управление сервисом

```bash
ssh root@38.135.122.81

# Статус
systemctl status youtube-proxy

# Логи (в т.ч. строки "Filtered /youtubei/v1/player: X → Y bytes")
journalctl -u youtube-proxy -f

# Перезапуск
systemctl restart youtube-proxy

# Конфиг (блок-листы, фильтруемые ключи)
nano /opt/youtube-proxy/config.yaml
systemctl restart youtube-proxy
```

## SSH доступ

```bash
# VPS1 (Яндекс Москва)
ssh -i ~/.ssh/ssh-key-1772056840349 slava@130.193.41.13

# VPS2 (foxcloud США, Бруклин)
ssh -i ~/.ssh/<your_key> <user>@38.135.122.81
```

## Конфиги на серверах

- VPS1: `/etc/amnezia/amneziawg/awg0.conf` (туннель к VPS2, MTU 1320)
- VPS1: `/etc/amnezia/amneziawg/awg1.conf` (клиентский интерфейс, MTU 1280)
- VPS2: `/etc/amnezia/amneziawg/awg0.conf` (туннель от VPS1, MTU 1280)

## Публикация на GitHub

Репозиторий: [https://github.com/eightspb/vpn](https://github.com/eightspb/vpn).

При первом пуше нужно один раз настроить remote и отправить код:

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File scripts/git-push-github.ps1
```

```bash
# WSL / Git Bash
bash scripts/git-push-github.sh
```

Скрипт добавляет `origin` → `https://github.com/eightspb/vpn.git` и выполняет `git push -u origin main`. Дальнейшие пуши: `git push`.

## Гигиена секретов

- Скопируйте шаблон: `cp .env.example .env` и заполните своими данными.
- Не коммитьте `.env` и `vpn-output/*` (это уже добавлено в `.gitignore`).
- Если секреты раньше были в `README.md`, считайте их скомпрометированными и ротируйте.

## Управление через manage.sh (Фаза 5)

Единая точка входа для всех операций:

```bash
bash manage.sh <команда> [опции]
```

| Команда | Описание |
|---------|----------|
| `deploy` | Полный деплой VPN (оба сервера) |
| `deploy --vps1` | Только VPS1 |
| `deploy --vps2` | Только VPS2 |
| `deploy --proxy` | Только YouTube Ad Proxy |
| `monitor` | Реалтайм-монитор в терминале |
| `monitor --web` | Веб-дашборд на http://localhost:8080 |
| `peers add` | Добавить пира (с выбором типа, режима, QR) |
| `peers batch` | Массовое создание пиров (из CSV или по шаблону) |
| `peers list` | Показать все пиры с трафиком и handshake |
| `peers remove` | Удалить пира по имени или IP |
| `peers export` | Экспортировать конфиг / QR-код |
| `peers info` | Лимиты и статистика подсети |
| `add-peer` | Добавить пир (legacy, см. `peers add`) |
| `check` | Проверить связность VPN-цепочки |
| `help` | Справка |

Дополнительные скрипты (запускаются напрямую):

| Скрипт | Описание |
|--------|----------|
| `bash scripts/tools/optimize-vpn.sh` | Применить оптимизации производительности на серверах |
| `bash scripts/tools/benchmark.sh` | Замер ping, скорости, MTU, handshake, задержки туннеля |
| `bash scripts/tools/load-test.sh` | Нагрузочное тестирование: соединения, bandwidth, CPU/RAM |

```bash
# Полный деплой
bash manage.sh deploy \
  --vps1-ip 130.193.41.13 --vps1-user slava --vps1-key ~/.ssh/ssh-key-1772056840349 \
  --vps2-ip 38.135.122.81 --vps2-key ~/.ssh/ssh-key-1772056840349 \
  --with-proxy --remove-adguard

# Мониторинг (читает настройки из .env)
bash manage.sh monitor
bash manage.sh monitor --web

# Добавить пир (новый способ)
bash manage.sh peers add --name tablet --type tablet --qr

# Массовое создание 50 пиров
bash manage.sh peers batch --prefix user --count 50

# Список пиров
bash manage.sh peers list

# Проверить связность
bash manage.sh check

# Справка по команде
bash manage.sh deploy --help
```

## Деплой (полный и по отдельности)

Все деплой-скрипты автоматически запускают security-обновления (`security-update.sh`) и hardening (`security-harden.sh`).

**Полный деплой (VPN + YouTube Ad Proxy):**
```bash
bash manage.sh deploy \
  --vps1-ip 130.193.41.13 --vps1-user slava --vps1-key ~/.ssh/ssh-key-1772056840349 \
  --vps2-ip 38.135.122.81 --vps2-user root  --vps2-key ~/.ssh/ssh-key-1772056840349 \
  --with-proxy --remove-adguard
```

**Флаги:**
- `--with-proxy` — задеплоить `youtube-proxy` на VPS2 (DNS + HTTPS фильтр)
- `--remove-adguard` — удалить AdGuard Home (используется вместе с `--with-proxy`)

**Только YouTube Ad Proxy (без переустановки VPN):**
```bash
bash manage.sh deploy --proxy \
  --vps2-ip 38.135.122.81 --vps2-key ~/.ssh/ssh-key-1772056840349 \
  --remove-adguard
```

**Только VPS1:**
```bash
bash manage.sh deploy --vps1 --vps1-ip ... --vps1-key ... --vps2-ip ...
```

**Только VPS2:**
```bash
# Сначала deploy-vps1.sh, затем:
bash manage.sh deploy --vps2 --vps2-ip ... --vps2-key ... --keys-file ./vpn-output/keys.env
```

## Управление пирами (устройствами)

### Быстрое добавление одного устройства

```bash
# Добавить телефон (автоопределение IP, MTU=1280)
bash manage.sh peers add --name myphone --type phone

# Добавить ноутбук с QR-кодом в терминале (MTU=1360)
bash manage.sh peers add --name laptop --type pc --qr

# Добавить роутер с конкретным IP (MTU=1400)
bash manage.sh peers add --name router-home --type router --ip 10.9.0.100

# Добавить с split tunnel (RU напрямую)
bash manage.sh peers add --name work-pc --type pc --mode split

# Создать оба конфига (full + split)
bash manage.sh peers add --name ipad --type tablet --mode both --qr-png
```

### Массовое создание пиров

```bash
# 50 устройств с префиксом "user" (user-001, user-002, ...)
bash manage.sh peers batch --prefix user --count 50 --type phone

# 100 устройств с QR-кодами в PNG
bash manage.sh peers batch --prefix employee --count 100 --type phone --qr-png

# Из CSV-файла
bash manage.sh peers batch --file devices.csv
```

Формат CSV:
```
name,type,mode,ip
laptop-anna,pc,full,
phone-boris,phone,split,
router-office,router,full,10.9.0.100
```

### Просмотр и управление

```bash
# Список всех пиров с трафиком и handshake
bash manage.sh peers list

# Подробный список (полные ключи)
bash manage.sh peers list --verbose

# Информация о подсети и лимитах
bash manage.sh peers info

# Удалить пира
bash manage.sh peers remove --name laptop
bash manage.sh peers remove --ip 10.9.0.5 --force

# Экспортировать конфиг / QR
bash manage.sh peers export --name myphone --qr
bash manage.sh peers export --name myphone --mode split --qr-png
```

### Типы устройств

| Тип | MTU | Примеры |
|-----|-----|---------|
| `pc`, `desktop`, `laptop`, `computer` | 1360 | Windows, macOS, Linux |
| `phone`, `mobile`, `tablet`, `ios`, `android` | 1280 | iPhone, Android, iPad |
| `router`, `mikrotik`, `openwrt` | 1400 | Домашний роутер |

### Лимиты подключений

- **Текущая подсеть:** `10.9.0.0/24` — до **252 устройств** (IP .3 — .254)
- **Расширение:** при необходимости подсеть можно расширить до `/16` (65 534 устройства)
- WireGuard/AmneziaWG не имеет жёсткого лимита на количество пиров
- Все конфиги и ключи хранятся в `vpn-output/peers.json`

### Legacy: add-peer (старый способ)

```bash
bash manage.sh add-peer
bash manage.sh add-peer --peer-name tablet --peer-ip 10.9.0.5
```

## Мониторинг

```bash
# Через manage.sh (рекомендуется)
bash manage.sh monitor          # реалтайм в терминале
bash manage.sh monitor --web    # веб-дашборд http://localhost:8080/dashboard.html

# Напрямую
bash scripts/monitor/monitor-realtime.sh
bash scripts/monitor/monitor-web.sh

# Параметры передаются через .env или CLI:
#   VPS1_IP, VPS1_USER, VPS1_KEY, VPS2_IP, VPS2_USER, VPS2_KEY
```

> **Примечание:** `monitor-web.sh` запускает HTTP-сервер на `127.0.0.1:8080` и автоматически
> определяет, доступен ли VPS1 по внутреннему IP `10.9.0.1` (клиентский шлюз VPN).
> VPS2 всегда опрашивается по публичному IP — туннельный адрес `10.8.0.2` является
> интерфейсом VPS1↔VPS2 и SSH там не слушает.
> Индикатор `Active VPN` в веб-дашборде считает только активные peer'ы `awg1` с
> `latest handshake <= 180s` (а не общее число всех peer'ов в конфиге).
> Для запуска мониторинга нужен Python рантайм: подходит `python3`, `python` или `py -3`.
> Данные обновляются каждые 5 секунд через SSH-подключение к серверам.

## Тесты

Проверка изменений Фазы 2 (производительность: DNS-кэш, стриминг, MTU в deploy):

```bash
# Windows
powershell -File tests/test-phase2.ps1

# Linux / WSL
bash tests/test-phase2.sh
```

Проверка изменений Фазы 3 (безопасность: eval убран, хардкод убран, add_phone_peer параметризован, CA-сервер ограничен):

```bash
# Windows
powershell -File tests/test-phase3.ps1

# Linux / WSL
bash tests/test-phase3.sh
```

Проверка изменений Фазы 4 (чистка: устаревшие скрипты удалены, мусорные файлы удалены, .gitignore обновлён, deploy-скрипты валидны):

```bash
# Windows
powershell -File tests/test-phase4.ps1

# Linux / WSL
bash tests/test-phase4.sh
```

Проверка изменений Фазы 5 (рефакторинг: lib/common.sh с общим кодом SSH/парсинга, manage.sh с подкомандами):

```bash
# Linux / WSL
bash tests/test-phase5.sh
```

Проверка monitor-web.sh и dashboard.html (исправления SSH, ping, путей к данным):

```bash
# Linux / WSL
bash tests/test-monitor-web.sh
```

Проверка скрипта ремонта локальных конфигов (`client.conf` + `phone.conf`):

```bash
# Windows
powershell -File tests/test-repair-local-configs.ps1
```

Проверка изменений youtube-proxy (фикс стабильности: привязка к 10.8.0.2, отключение MITM, расширение блоклистов):

```bash
# Linux / WSL
bash tests/test-proxy-fix.sh
```

Проверка скрипта нагрузочного тестирования (load-test.sh: синтаксис, функции, метрики, флаги):

```bash
# Linux / WSL
bash tests/test-load-test.sh
```

Проверка скрипта управления пирами (manage-peers.sh: команды, парсинг, шаблоны, DB, CSV, типы устройств):

```bash
# Linux / WSL
bash tests/test-manage-peers.sh
```

Проверка security hardening (fail2ban, SSH hardening, iptables DROP, rkhunter, CPU watchdog, пароли):

```bash
# Linux / WSL
bash tests/test-security-harden.sh
```

Проверка настройки GitHub remote (git-push-github):

```powershell
# Windows
powershell -File tests/test-git-push-github.ps1
```

```bash
# Linux / WSL
bash tests/test-git-push-github.sh
```

## Оптимизация производительности

### Скрипт оптимизации

```bash
# Применить все оптимизации на серверах
bash scripts/tools/optimize-vpn.sh

# Только замер метрик (без изменений)
bash scripts/tools/optimize-vpn.sh --benchmark-only

# Только VPS1 или VPS2
bash scripts/tools/optimize-vpn.sh --vps1-only
bash scripts/tools/optimize-vpn.sh --vps2-only
```

Скрипт применяет на обоих серверах:
- Расширенные sysctl-параметры (TCP/UDP буферы 64 MB, BBR, TCP Fast Open, conntrack 524288)
- MTU: туннель VPS1↔VPS2 — 1420, клиентский интерфейс — 1360
- MSS clamp: 1320 (устраняет фрагментацию TCP)
- Junk-параметры AmneziaWG: Jc=2, Jmin=20, Jmax=200, S1=15, S2=20 (снижен overhead обфускации)
- PersistentKeepalive туннеля: 60 с (был 25 с)
- Замер метрик до и после с отчётом

### Замер производительности

```bash
bash scripts/tools/benchmark.sh
```

Показывает: ping к 8.8.8.8 (avg/min/max/jitter), скорость загрузки через Cloudflare, MTU интерфейсов, возраст WireGuard handshake, задержку туннеля VPS1↔VPS2.

### Нагрузочное тестирование

```bash
# Полный нагрузочный тест (оба сервера)
bash scripts/tools/load-test.sh

# Быстрый режим (100 соединений, шаг 25, 5 сек на шаг)
bash scripts/tools/load-test.sh --quick

# Только VPS1 или VPS2
bash scripts/tools/load-test.sh --vps1-only
bash scripts/tools/load-test.sh --vps2-only

# Только тест пропускной способности
bash scripts/tools/load-test.sh --bandwidth-only

# Только тест соединений
bash scripts/tools/load-test.sh --connections-only

# Настройка параметров
bash scripts/tools/load-test.sh --max-connections 1000 --step 100 --duration 15

# Сохранить отчёт в файл
bash scripts/tools/load-test.sh --quick --output report.txt
```

Скрипт выполняет:
- **Системные метрики** — CPU (ядра, load average, usage %), RAM (total/used/available), swap, диск, uptime
- **Пропускная способность** — скорость загрузки/отдачи через Cloudflare (1 и 4 потока)
- **Масштабирование соединений** — пошаговое наращивание параллельных соединений (через Apache Bench) с замером RPS, latency, CPU, RAM, conntrack на каждом шаге; определяет точку деградации (latency > 2x)
- **Conntrack** — текущее/максимальное число записей, hashsize, TCP established/time-wait
- **Задержка туннеля** — ping VPS1→VPS2 без нагрузки и под нагрузкой, разница avg latency
- **WireGuard throughput** — RX/TX трафик по каждому пиру
- **Метрики до/после** — сравнение состояния серверов до и после нагрузочного теста

### Split tunneling (раздельное туннелирование)

**Режим "Россия напрямую, остальное через VPN"** — российские IP-адреса идут без VPN, весь остальной интернет через туннель:

```
vpn-output/client-split.conf   ← первое устройство
vpn-output/phone-split.conf    ← телефон
```

Конфиги содержат ~21 000 CIDR-блоков в `AllowedIPs` — это весь публичный IPv4-интернет за вычетом 8 569 российских диапазонов (данные RIPE NCC) и RFC1918-сетей.

**Обновить список российских IP** (рекомендуется раз в несколько месяцев):

```bash
# Скачать актуальный список и пересоздать split-конфиги
python3 scripts/tools/generate-split-config.py

# Или использовать уже скачанный файл ru-ips.txt
python3 scripts/tools/generate-split-config.py --ru-list ru-ips.txt

# Только вывести AllowedIPs без записи файлов
python3 scripts/tools/generate-split-config.py --print-only
```

Источник IP-диапазонов: [ipv4.fetus.jp/ru.txt](https://ipv4.fetus.jp/ru.txt) (обновляется ежедневно из RIPE NCC).

> Файл `ru-ips.txt` добавлен в `.gitignore` — он автоматически скачивается скриптом.

### Применённые оптимизации

| Параметр | Было | Стало | Эффект |
|----------|------|-------|--------|
| MTU клиент | 1280 | 1360 | +6% пропускная способность |
| MTU туннель | 1320 | 1420 | меньше фрагментации |
| MSS clamp | 1200 | 1320 | устранение фрагментации TCP |
| Junk Jmax | 1000 | 200 | снижение jitter на ~15ms |
| Junk Jc | 5 | 2 | меньше overhead обфускации |
| TCP/UDP буферы | 25 MB | 64 MB | стабильность на длинных линках |
| conntrack max | 131072 | 524288 | больше одновременных соединений |
| tcp_slow_start_after_idle | 1 | 0 | нет просадки скорости после паузы |
| DNS upstream | 8.8.8.8 | 1.1.1.1 | ближе к VPS2 (Бруклин) |
| DNS кэш TTL | 5 мин | 15 мин | меньше DNS-запросов |
| DNS кэш размер | 10 000 | 50 000 | больше кэшированных доменов |
| HTTP/2 upstream | выкл | вкл | мультиплексирование YouTube API |
| PersistentKeepalive туннель | 25 с | 60 с | меньше фонового трафика |

## Диагностика и ремонт

При проблемах с VPN (YouTube не работает, телефон без интернета, дашборд не отвечает):

```bash
# Только диагностика — показывает состояние серверов (безопасно, ничего не меняет)
bash scripts/tools/diagnose.sh

# Диагностика + автоматический ремонт
bash scripts/tools/diagnose.sh --fix
```

Скрипт проверяет и при `--fix` исправляет:
- Состояние `awg0`/`awg1` на обоих серверах
- Работу `youtube-proxy` (DNS порт 53, HTTPS порт 443)
- Конфликт с AdGuard Home (останавливает его)
- NAT MASQUERADE (без него телефон без интернета)
- Firewall правила для TCP 443 (без них YouTube не работает)
- `/etc/resolv.conf` на VPS2 (должен указывать на `127.0.0.1`)

Если локальные `vpn-output/client.conf` и `vpn-output/phone.conf` устарели (неверный `Endpoint`, `PublicKey` или отсутствует peer на VPS1), используйте:

```powershell
powershell -ExecutionPolicy Bypass -File repair-local-configs.ps1
```

Скрипт:
- считывает актуальные параметры `awg1` с VPS1;
- проверяет наличие peer'ов для `10.9.0.2` и `10.9.0.3` (при необходимости добавляет);
- пересобирает локальные `client.conf` и `phone.conf` под текущий сервер;
- делает финальную валидацию через `awg show awg1 allowed-ips`.


## Безопасность

### Автоматический hardening при деплое

Все deploy-скрипты автоматически запускают `security-harden.sh`, который настраивает:

| Компонент | Что делает |
|-----------|-----------|
| **fail2ban** | Блокирует IP после 3 неудачных SSH-попыток на 1 час |
| **unattended-upgrades** | Ежедневные автоматические security-обновления |
| **SSH hardening** | `PermitRootLogin prohibit-password`, `PasswordAuthentication no`, `MaxAuthTries 3` |
| **iptables default DROP** | Политика DROP для INPUT/FORWARD, только явно разрешённые порты |
| **iptables-persistent** | Правила файрвола сохраняются после перезагрузки |
| **rkhunter** | Ежедневный скан на руткиты и майнеры |
| **CPU watchdog** | Каждые 5 мин проверяет CPU >80% и логирует подозрительные процессы |
| **Kernel hardening** | SYN flood protection, ICMP redirect blocking, martian packet logging |
| **DROP logging** | Отброшенные пакеты логируются с префиксом `IPT_DROP:` |
| **SSH rate limiting** | iptables блокирует >6 новых SSH-подключений за 60 сек |

### SSH host key verification

Все SSH-подключения используют `StrictHostKeyChecking=accept-new` — ключ сервера принимается при первом подключении и сохраняется. При изменении ключа (MITM-атака) подключение будет отклонено.

### AdGuard Home

AdGuard Home Web UI слушает только на VPN-интерфейсе (`10.8.0.2:3000`), недоступен из публичного интернета. Пароль по умолчанию отсутствует — обязательно указывать `--adguard-pass` при деплое.

### Ручной запуск hardening

```bash
# На сервере (VPS1)
sudo bash /tmp/security-harden.sh --role vps1 --vpn-port 51820

# На сервере (VPS2)
sudo bash /tmp/security-harden.sh --role vps2 --vpn-port 51820 --adguard-bind 10.8.0.2
```

### Проверка безопасности

```bash
# Статус fail2ban
sudo fail2ban-client status sshd

# Заблокированные IP
sudo fail2ban-client status sshd | grep "Banned IP"

# Логи отброшенных пакетов
sudo journalctl -k | grep IPT_DROP | tail -20

# Логи CPU watchdog
cat /var/log/cpu-watchdog.log

# Результаты rkhunter
cat /var/log/rkhunter-daily.log | grep Warning

# Статус автообновлений
sudo systemctl status unattended-upgrades
```

### Тесты безопасности

```bash
bash tests/test-security-harden.sh
```

## Отдельный запуск security-обновлений

```bash
sudo bash scripts/deploy/security-update.sh
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

## Управление VPN-туннелями

```bash
# Статус туннелей
sudo awg show all

# Перезапуск
sudo systemctl restart awg-quick@awg0
sudo systemctl restart awg-quick@awg1

# Логи
sudo journalctl -u awg-quick@awg0 -f
```
