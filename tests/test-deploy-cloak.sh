#!/usr/bin/env bash
# tests/test-deploy-cloak.sh — проверка скрипта и конфигов Cloak TLS-маскировки
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PASS=0; FAIL=0
ok()   { echo "  ✓ $*"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

echo ""
echo "=== Тест: Cloak TLS-маскировка VPN-трафика ==="
echo ""

# ── 1. Скрипт deploy-cloak.sh существует и исполняемый ────────────────────
if [[ -f scripts/deploy/deploy-cloak.sh ]]; then
  ok "deploy-cloak.sh существует"
else
  fail "deploy-cloak.sh не найден"
fi

if [[ -x scripts/deploy/deploy-cloak.sh ]]; then
  ok "deploy-cloak.sh исполняемый"
else
  fail "deploy-cloak.sh не исполняемый"
fi

# ── 2. Скрипт проходит syntax check ───────────────────────────────────────
if bash -n scripts/deploy/deploy-cloak.sh 2>/dev/null; then
  ok "deploy-cloak.sh: bash syntax OK"
else
  fail "deploy-cloak.sh: синтаксическая ошибка"
fi

# ── 3. Скрипт подключает lib/common.sh ────────────────────────────────────
if grep -q 'source.*lib/common.sh' scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: подключает lib/common.sh"
else
  fail "deploy-cloak.sh: не подключает lib/common.sh"
fi

# ── 4. Поддержка --help ───────────────────────────────────────────────────
if grep -q '\-\-help' scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: поддерживает --help"
else
  fail "deploy-cloak.sh: нет --help"
fi

# ── 5. Параметры по умолчанию ─────────────────────────────────────────────
if grep -q 'FAKE_DOMAIN="yandex.ru"' scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: домен по умолчанию — yandex.ru"
else
  fail "deploy-cloak.sh: неверный домен по умолчанию"
fi

if grep -q 'CLOAK_PORT=443' scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: порт по умолчанию — 443"
else
  fail "deploy-cloak.sh: неверный порт по умолчанию"
fi

# ── 6. Генерация ключей Cloak ─────────────────────────────────────────────
if grep -q 'ck-server -key' scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: генерирует ключи через ck-server -key"
else
  fail "deploy-cloak.sh: нет генерации ключей"
fi

if grep -q 'ck-server -uid' scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: генерирует UID через ck-server -uid"
else
  fail "deploy-cloak.sh: нет генерации UID"
fi

# ── 6b. Парсинг вывода ck-server v2.7+ ────────────────────────────────────
# ck-server -key выводит: "Your PUBLIC key is:  <base64>" / "Your PRIVATE key is (keep it secret):  <base64>"
# ck-server -uid выводит: "Your UID is: <base64>"
# Скрипт должен использовать awk '{print $NF}', а не grep -oP '(?<=priv=)'
if grep -q "grep.*'(?<=priv=)" scripts/deploy/deploy-cloak.sh; then
  fail "deploy-cloak.sh: использует устаревший парсинг ck-server (priv=...)"
else
  ok "deploy-cloak.sh: парсинг ck-server НЕ использует устаревший формат priv=..."
fi

if grep -q "awk.*print.*NF" scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: парсит ключи через awk '{print \$NF}' (формат v2.7+)"
else
  fail "deploy-cloak.sh: нет парсинга через awk NF"
fi

# Проверяем что UID тоже парсится через awk, а не tr -d '[:space:]'
if grep -q "ck-server -uid.*tr -d" scripts/deploy/deploy-cloak.sh; then
  fail "deploy-cloak.sh: UID парсится через tr -d (склеивает 'YourUIDis:value')"
else
  ok "deploy-cloak.sh: UID НЕ парсится через tr -d (корректно)"
fi

# ── 7. Конфигурация сервера ───────────────────────────────────────────────
if grep -q 'ckserver.json' scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: создаёт ckserver.json"
else
  fail "deploy-cloak.sh: нет ckserver.json"
fi

if grep -q 'ProxyBook' scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: конфиг содержит ProxyBook (проброс в awg)"
else
  fail "deploy-cloak.sh: нет ProxyBook"
fi

if grep -q 'RedirAddr' scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: конфиг содержит RedirAddr (маскировочный домен)"
else
  fail "deploy-cloak.sh: нет RedirAddr"
fi

# ── 8. Systemd сервис ────────────────────────────────────────────────────
if grep -q 'cloak-server.service' scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: создаёт systemd сервис"
else
  fail "deploy-cloak.sh: нет systemd сервиса"
fi

if grep -q 'Restart=always' scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: сервис с автоперезапуском"
else
  fail "deploy-cloak.sh: нет Restart=always"
fi

if grep -q 'After=.*awg-quick@awg1' scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: сервис стартует после awg1"
else
  fail "deploy-cloak.sh: нет зависимости от awg1"
fi

# ── 8b. Освобождение порта при конфликте (nginx и т.п.) ──────────────────
if grep -q 'PORT_CONFLICT\|BLOCKING_PROC\|ss -tlnp.*CLOAK_PORT' scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: обрабатывает конфликт порта (nginx на 443)"
else
  fail "deploy-cloak.sh: нет обработки конфликта порта"
fi

# ── 9. Iptables — открытие порта ─────────────────────────────────────────
if grep -q 'iptables.*INPUT.*tcp.*CLOAK_PORT.*ACCEPT' scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: открывает TCP порт в iptables"
else
  fail "deploy-cloak.sh: нет правила iptables для TCP порта"
fi

# ── 10. Идемпотентность iptables ─────────────────────────────────────────
if grep -q 'iptables -C INPUT.*2>/dev/null' scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: iptables идемпотентный (проверяет перед добавлением)"
else
  fail "deploy-cloak.sh: iptables не идемпотентный"
fi

# ── 11. Генерация клиентского конфига ────────────────────────────────────
if grep -q 'ck-client.json' scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: генерирует ck-client.json"
else
  fail "deploy-cloak.sh: нет генерации клиентского конфига"
fi

if grep -q 'ServerName' scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: клиентский конфиг содержит ServerName (SNI)"
else
  fail "deploy-cloak.sh: нет ServerName в клиентском конфиге"
fi

if grep -q 'BrowserSig' scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: клиентский конфиг содержит BrowserSig"
else
  fail "deploy-cloak.sh: нет BrowserSig"
fi

# ── 12. Генерация client-cloak.conf ─────────────────────────────────────
if grep -q 'client-cloak.conf' scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: генерирует client-cloak.conf (модифицированный WG конфиг)"
else
  fail "deploy-cloak.sh: нет client-cloak.conf"
fi

if grep -q 'Endpoint.*127.0.0.1:1984' scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: endpoint меняется на localhost:1984"
else
  fail "deploy-cloak.sh: endpoint не меняется на localhost"
fi

# ── 13. Сохранение ключей ────────────────────────────────────────────────
if grep -q 'cloak-keys.env' scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: сохраняет ключи в cloak-keys.env"
else
  fail "deploy-cloak.sh: нет сохранения ключей"
fi

if grep -q 'chmod 600.*cloak-keys.env\|chmod 600.*CK_KEYS_FILE' scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: ключи с правами 600"
else
  fail "deploy-cloak.sh: ключи без ограничений прав"
fi

# ── 14. Инструкция для клиента ───────────────────────────────────────────
if grep -q 'cloak-setup.md' scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: генерирует инструкцию cloak-setup.md"
else
  fail "deploy-cloak.sh: нет инструкции"
fi

# ── 15. Верификация после деплоя ─────────────────────────────────────────
if grep -q 'ss -tlnp.*CLOAK_PORT\|ss.*grep.*CLOAK_PORT' scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: проверяет что порт слушается"
else
  fail "deploy-cloak.sh: нет проверки порта"
fi

if grep -q 'systemctl is-active.*cloak-server' scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: проверяет статус сервиса"
else
  fail "deploy-cloak.sh: нет проверки статуса"
fi

# ── 16. Поддержка WSL/Windows путей ──────────────────────────────────────
if grep -q 'prepare_key_for_ssh\|_path_for_native_ssh' scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: поддерживает WSL/Windows пути"
else
  fail "deploy-cloak.sh: нет поддержки WSL/Windows путей"
fi

# ── 17. deploy.sh поддерживает --with-cloak ──────────────────────────────
if grep -q '\-\-with-cloak' scripts/deploy/deploy.sh; then
  ok "deploy.sh: поддерживает --with-cloak"
else
  fail "deploy.sh: нет поддержки --with-cloak"
fi

if grep -q '\-\-fake-domain' scripts/deploy/deploy.sh; then
  ok "deploy.sh: поддерживает --fake-domain"
else
  fail "deploy.sh: нет поддержки --fake-domain"
fi

# ── 18. deploy.sh вызывает deploy-cloak.sh ───────────────────────────────
if grep -q 'deploy-cloak.sh' scripts/deploy/deploy.sh; then
  ok "deploy.sh: вызывает deploy-cloak.sh при --with-cloak"
else
  fail "deploy.sh: нет вызова deploy-cloak.sh"
fi

# ── 19. deploy.sh syntax check ──────────────────────────────────────────
if bash -n scripts/deploy/deploy.sh 2>/dev/null; then
  ok "deploy.sh: bash syntax OK после изменений"
else
  fail "deploy.sh: синтаксическая ошибка после изменений"
fi

# ── 20. Документация в CLAUDE.md обновлена ───────────────────────────────
if grep -qi 'cloak\|маскировк' CLAUDE.md; then
  ok "CLAUDE.md: содержит информацию о Cloak"
else
  fail "CLAUDE.md: нет информации о Cloak"
fi

echo ""
echo "=== Тест: Авторотация доменов Cloak ==="
echo ""

# ── 21. Серверный скрипт ротации существует ──────────────────────────────
if [[ -f scripts/deploy/cloak-rotate-domain.sh ]]; then
  ok "cloak-rotate-domain.sh существует"
else
  fail "cloak-rotate-domain.sh не найден"
fi

if [[ -x scripts/deploy/cloak-rotate-domain.sh ]]; then
  ok "cloak-rotate-domain.sh исполняемый"
else
  fail "cloak-rotate-domain.sh не исполняемый"
fi

if bash -n scripts/deploy/cloak-rotate-domain.sh 2>/dev/null; then
  ok "cloak-rotate-domain.sh: bash syntax OK"
else
  fail "cloak-rotate-domain.sh: синтаксическая ошибка"
fi

# ── 22. Клиентский скрипт ротации существует ─────────────────────────────
if [[ -f scripts/deploy/cloak-rotate-client.sh ]]; then
  ok "cloak-rotate-client.sh существует"
else
  fail "cloak-rotate-client.sh не найден"
fi

if [[ -x scripts/deploy/cloak-rotate-client.sh ]]; then
  ok "cloak-rotate-client.sh исполняемый"
else
  fail "cloak-rotate-client.sh не исполняемый"
fi

if bash -n scripts/deploy/cloak-rotate-client.sh 2>/dev/null; then
  ok "cloak-rotate-client.sh: bash syntax OK"
else
  fail "cloak-rotate-client.sh: синтаксическая ошибка"
fi

# ── 23. Список доменов содержит популярные сайты ─────────────────────────
for domain in yandex.ru mail.ru vk.com ok.ru dzen.ru avito.ru ozon.ru; do
  if grep -q "$domain" scripts/deploy/cloak-rotate-domain.sh; then
    ok "Серверная ротация содержит $domain"
  else
    fail "Серверная ротация не содержит $domain"
  fi
done

# ── 24. Списки доменов совпадают (сервер и клиент) ───────────────────────
server_domains=$(grep -oP '^\s+"[a-z0-9.-]+\.[a-z]+"' scripts/deploy/cloak-rotate-domain.sh | sort)
client_domains=$(grep -oP '^\s+"[a-z0-9.-]+\.[a-z]+"' scripts/deploy/cloak-rotate-client.sh | sort)
if [[ "$server_domains" == "$client_domains" ]]; then
  ok "Списки доменов сервера и клиента совпадают"
else
  fail "Списки доменов сервера и клиента НЕ совпадают"
fi

# ── 25. Серверный скрипт обновляет RedirAddr ─────────────────────────────
if grep -q 'RedirAddr' scripts/deploy/cloak-rotate-domain.sh; then
  ok "cloak-rotate-domain.sh: обновляет RedirAddr"
else
  fail "cloak-rotate-domain.sh: нет обновления RedirAddr"
fi

# ── 26. Клиентский скрипт обновляет ServerName ───────────────────────────
if grep -q 'ServerName' scripts/deploy/cloak-rotate-client.sh; then
  ok "cloak-rotate-client.sh: обновляет ServerName"
else
  fail "cloak-rotate-client.sh: нет обновления ServerName"
fi

# ── 27. Серверный скрипт перезапускает ck-server ─────────────────────────
if grep -q 'systemctl restart.*cloak-server\|CK_SERVICE' scripts/deploy/cloak-rotate-domain.sh; then
  ok "cloak-rotate-domain.sh: перезапускает ck-server"
else
  fail "cloak-rotate-domain.sh: нет перезапуска ck-server"
fi

# ── 28. Серверный скрипт делает откат при ошибке ─────────────────────────
if grep -q 'откат\|rollback\|Откат' scripts/deploy/cloak-rotate-domain.sh; then
  ok "cloak-rotate-domain.sh: откат при ошибке запуска"
else
  fail "cloak-rotate-domain.sh: нет отката при ошибке"
fi

# ── 29. Серверный скрипт выбирает домен, отличный от текущего ────────────
if grep -q 'current\|attempts' scripts/deploy/cloak-rotate-domain.sh; then
  ok "cloak-rotate-domain.sh: избегает повторения текущего домена"
else
  fail "cloak-rotate-domain.sh: может выбрать тот же домен"
fi

# ── 30. Атомарная замена конфига (через tmpfile + mv) ────────────────────
if grep -q 'mktemp.*CK_CONFIG\|mktemp.*ckserver' scripts/deploy/cloak-rotate-domain.sh; then
  ok "cloak-rotate-domain.sh: атомарная замена конфига (tmpfile+mv)"
else
  fail "cloak-rotate-domain.sh: нет атомарной замены"
fi

# ── 31. deploy-cloak.sh устанавливает cron для ротации ───────────────────
if grep -q 'crontab\|cron' scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: устанавливает cron для ротации"
else
  fail "deploy-cloak.sh: нет установки cron"
fi

# ── 32. deploy-cloak.sh загружает скрипт ротации на VPS1 ────────────────
if grep -q 'cloak-rotate-domain.sh' scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: загружает скрипт ротации на VPS1"
else
  fail "deploy-cloak.sh: не загружает скрипт ротации"
fi

# ── 33. Поддержка --list, --current, --set ───────────────────────────────
for flag in "--list" "--current" "--set"; do
  if grep -q -- "$flag" scripts/deploy/cloak-rotate-domain.sh; then
    ok "cloak-rotate-domain.sh: поддерживает $flag"
  else
    fail "cloak-rotate-domain.sh: нет поддержки $flag"
  fi
done

# ── 34. Клиентский скрипт поддерживает --config ──────────────────────────
if grep -q '\-\-config' scripts/deploy/cloak-rotate-client.sh; then
  ok "cloak-rotate-client.sh: поддерживает --config"
else
  fail "cloak-rotate-client.sh: нет --config"
fi

# ── 35. Cron идемпотентный (grep -v + echo) ─────────────────────────────
if grep -q 'grep -v.*cloak-rotate' scripts/deploy/deploy-cloak.sh; then
  ok "deploy-cloak.sh: cron идемпотентный (удаляет старую запись)"
else
  fail "deploy-cloak.sh: cron не идемпотентный"
fi

echo ""
echo "=== Тест: Безопасный деплой ротации (deploy-cloak-rotation.sh) ==="
echo ""

# ── 36. Скрипт существует и исполняемый ──────────────────────────────────
if [[ -f scripts/deploy/deploy-cloak-rotation.sh ]]; then
  ok "deploy-cloak-rotation.sh существует"
else
  fail "deploy-cloak-rotation.sh не найден"
fi

if [[ -x scripts/deploy/deploy-cloak-rotation.sh ]]; then
  ok "deploy-cloak-rotation.sh исполняемый"
else
  fail "deploy-cloak-rotation.sh не исполняемый"
fi

if bash -n scripts/deploy/deploy-cloak-rotation.sh 2>/dev/null; then
  ok "deploy-cloak-rotation.sh: bash syntax OK"
else
  fail "deploy-cloak-rotation.sh: синтаксическая ошибка"
fi

# ── 37. НЕ генерирует ключи (безопасность) ──────────────────────────────
if ! grep -q 'ck-server -key' scripts/deploy/deploy-cloak-rotation.sh; then
  ok "deploy-cloak-rotation.sh: НЕ генерирует ключи (безопасно)"
else
  fail "deploy-cloak-rotation.sh: генерирует ключи — ОПАСНО для существующих клиентов"
fi

if ! grep -q 'ck-server -uid' scripts/deploy/deploy-cloak-rotation.sh; then
  ok "deploy-cloak-rotation.sh: НЕ генерирует UID (безопасно)"
else
  fail "deploy-cloak-rotation.sh: генерирует UID — ОПАСНО"
fi

# ── 38. НЕ перезаписывает ckserver.json ──────────────────────────────────
if ! grep -q 'cat > /etc/cloak/ckserver.json\|cat >.*ckserver.json' scripts/deploy/deploy-cloak-rotation.sh; then
  ok "deploy-cloak-rotation.sh: НЕ перезаписывает ckserver.json (безопасно)"
else
  fail "deploy-cloak-rotation.sh: перезаписывает ckserver.json — ОПАСНО"
fi

# ── 39. Pre-check: проверяет что Cloak уже работает ──────────────────────
if grep -q 'systemctl is-active.*cloak-server\|CK_ACTIVE' scripts/deploy/deploy-cloak-rotation.sh; then
  ok "deploy-cloak-rotation.sh: pre-check — проверяет что Cloak работает"
else
  fail "deploy-cloak-rotation.sh: нет pre-check"
fi

if grep -q 'ckserver.json' scripts/deploy/deploy-cloak-rotation.sh; then
  ok "deploy-cloak-rotation.sh: pre-check — проверяет наличие конфига"
else
  fail "deploy-cloak-rotation.sh: нет проверки конфига"
fi

# ── 40. Поддерживает --rotate-now ────────────────────────────────────────
if grep -q '\-\-rotate-now' scripts/deploy/deploy-cloak-rotation.sh; then
  ok "deploy-cloak-rotation.sh: поддерживает --rotate-now"
else
  fail "deploy-cloak-rotation.sh: нет --rotate-now"
fi

# ── 41. Поддерживает --interval ──────────────────────────────────────────
if grep -q '\-\-interval' scripts/deploy/deploy-cloak-rotation.sh; then
  ok "deploy-cloak-rotation.sh: поддерживает --interval"
else
  fail "deploy-cloak-rotation.sh: нет --interval"
fi

# ── 42. Подключает lib/common.sh ────────────────────────────────────────
if grep -q 'source.*lib/common.sh' scripts/deploy/deploy-cloak-rotation.sh; then
  ok "deploy-cloak-rotation.sh: подключает lib/common.sh"
else
  fail "deploy-cloak-rotation.sh: не подключает lib/common.sh"
fi

echo ""
echo "Результат: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] && echo "OK — все проверки прошли" && exit 0
echo "FAIL — есть ошибки" && exit 1
