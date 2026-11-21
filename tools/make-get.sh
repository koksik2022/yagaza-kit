#!/usr/bin/env bash
# Собрать get.sh из get.sh.in: закрепить коммит, в котором лежит yagaza-kit.sh, и его SHA-256.
#   bash tools/make-get.sh <коммит> [путь к yagaza-kit.sh в репозитории]
# Порядок публикации: bundle → коммит yagaza-kit.sh → make-get.sh <этот коммит> → коммит get.sh → push.

set -euo pipefail
cd "$(dirname "$0")/.."
REF="${1:?Нужен хеш коммита, в котором лежит yagaza-kit.sh}"
FILE="${2:-yagaza-kit.sh}"
GH_REPO="${GH_REPO:-koksik2022/yagaza-kit}"
[[ "$REF" =~ ^[0-9a-f]{40}$ ]] || { echo "Нужен полный хеш коммита (40 символов)" >&2; exit 1; }
[ -f "$FILE" ] || { echo "Нет $FILE" >&2; exit 1; }
VER=$(sed -n 's/^YI_VERSION="\(.*\)"/\1/p' "$FILE" | head -1)
SHA=$(sha256sum "$FILE" | cut -d' ' -f1)
sed -e "s|@GH_REPO@|$GH_REPO|g" -e "s|@REF@|$REF|g" -e "s|@VER@|$VER|g" -e "s|@SHA@|$SHA|g" get.sh.in >get.sh
bash -n get.sh
echo "get.sh: версия $VER, коммит $REF, sha256 $SHA"
