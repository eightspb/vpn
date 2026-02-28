#!/usr/bin/env bash
# Настройка remote origin для GitHub и push.
# Репозиторий: https://github.com/eightspb/vpn
# Запуск: bash scripts/git-push-github.sh

set -e
cd "$(dirname "$0")/.."
GITHUB_URL="https://github.com/eightspb/vpn.git"
REMOTE="origin"
BRANCH="main"

if ! git remote | grep -qxF "$REMOTE"; then
  echo "Добавляю remote '$REMOTE' -> $GITHUB_URL"
  git remote add "$REMOTE" "$GITHUB_URL"
else
  current=$(git remote get-url "$REMOTE" 2>/dev/null || true)
  if [ "$current" != "$GITHUB_URL" ]; then
    echo "Обновляю URL remote '$REMOTE' на $GITHUB_URL"
    git remote set-url "$REMOTE" "$GITHUB_URL"
  fi
fi

echo "Пуш в $REMOTE $BRANCH ..."
git push -u "$REMOTE" "$BRANCH"
echo "Готово."
