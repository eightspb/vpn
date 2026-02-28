#!/usr/bin/env bash
# Тест: скрипт git-push-github и наличие remote origin.
# Проверяет, что remote origin настроен на https://github.com/eightspb/vpn.git
# Запуск: bash tests/test-git-push-github.sh

set -e
cd "$(dirname "$0")/.."
expected_url="https://github.com/eightspb/vpn.git"
remote_name="origin"
script_path="scripts/git-push-github.sh"

# 1) Скрипт существует
[ -f "$script_path" ] || { echo "FAIL: Скрипт не найден: $script_path"; exit 1; }
echo "OK: Скрипт существует"

# 2) Если origin есть — URL должен совпадать
if git remote | grep -qxF "$remote_name"; then
  url=$(git remote get-url "$remote_name" 2>/dev/null || true)
  if [ "$url" = "$expected_url" ]; then
    echo "OK: remote '$remote_name' указывает на $expected_url"
  else
    echo "FAIL: remote '$remote_name' URL = '$url', ожидалось '$expected_url'"
    exit 1
  fi
else
  echo "OK: remote '$remote_name' ещё не добавлен (скрипт добавит при первом запуске)"
fi

echo "Все проверки пройдены."
