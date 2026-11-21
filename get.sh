#!/bin/bash
# Yagaza Kit — установка одной командой (на сервере, от root):
#   curl -fsSL https://raw.githubusercontent.com/koksik2022/yagaza-kit/main/get.sh | sudo bash
#   wget -qO- https://raw.githubusercontent.com/koksik2022/yagaza-kit/main/get.sh | sudo bash
# Скачивает Yagaza Kit версии 0.2.1 по закреплённому коммиту, сверяет SHA-256,
# ставит команду `yagaza` и открывает меню. `--no-menu` — только поставить/обновить.
main() {
  set -euo pipefail
  local VER="0.2.1" SHA="9ad3bfafc389c934e74b2a0c52347f157493e62808eb53eab3e37901101f6f83" NAME="yagaza-kit.sh" MENU=1
  local SOURCES=(
    "https://raw.githubusercontent.com/koksik2022/yagaza-kit/02848372931c2345822382f9505d7dbd39da3fe1/$NAME"
    "https://github.com/koksik2022/yagaza-kit/releases/download/v0.2.1/$NAME"
  )
  [ "${1:-}" = "--no-menu" ] && MENU=0
  [ -n "${YK_SOURCE:-}" ] && SOURCES=("$YK_SOURCE")
  if [ "$(id -u)" -ne 0 ]; then echo "Нужны права root: добавьте sudo перед bash" >&2; exit 1; fi

  fetch() {   # fetch URL FILE
    if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 2 --connect-timeout 15 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then wget -q -T 15 -t 2 -O "$2" "$1"
    else return 127; fi
  }
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    echo "› Ставлю curl..."; (apt-get update -qq && apt-get install -y -qq curl) >/dev/null 2>&1 || { echo "Не удалось установить curl" >&2; exit 1; }
  fi

  YK_TMP=$(mktemp -d); trap 'rm -rf "${YK_TMP:-}"' EXIT
  local f="$YK_TMP/$NAME" src got=""
  for src in "${SOURCES[@]}"; do
    echo "› Скачиваю Yagaza Kit $VER"
    if fetch "$src" "$f" && [ -s "$f" ]; then
      if echo "$SHA  $f" | sha256sum -c --status; then got=1; break; fi
      echo "! Контрольная сумма не совпала — пробую следующий источник" >&2
    else
      echo "! Источник недоступен — пробую следующий" >&2
    fi
  done
  [ -n "$got" ] || { echo "✖ Не удалось скачать Yagaza Kit ни из одного источника" >&2; exit 1; }
  echo "✔ Файл проверен (SHA-256)"
  install -m 755 -o root -g root "$f" /usr/local/bin/yagaza
  echo "✔ Yagaza Kit $VER установлен — команда: yagaza"
  if [ "$MENU" = 1 ] && [ -r /dev/tty ]; then exec /usr/local/bin/yagaza </dev/tty; fi
}
main "$@"
