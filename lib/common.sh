# shellcheck shell=bash
# Yagaza Kit — общие функции: вывод, вопросы, лог, ОС, копии файлов.

YI_VERSION="0.1.0"
YI_ETC="${YI_ETC:-/etc/ykit}"
YI_STATE="$YI_ETC/state"
YI_BACKUP="$YI_ETC/backup"
YI_LOG="${YI_LOG:-/var/log/ykit.log}"

# Ширина колонок считается в символах только в UTF-8-локали.
case "${LC_ALL:-${LANG:-}}" in
    *UTF-8*|*utf8*) ;;
    *) export LC_ALL=C.UTF-8 ;;
esac

# pad <текст> <ширина> — дополнить пробелами до ширины в символах (не байтах).
pad() {
    local s="$1" n=$(( $2 - ${#1} ))
    [ "$n" -lt 1 ] && n=1
    printf '%s%*s' "$s" "$n" ''
}

if [ -t 1 ]; then
    C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[1m'; C_D=$'\e[2m'; C_0=$'\e[0m'
else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_D=""; C_0=""
fi

log()  { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$YI_LOG" 2>/dev/null || true; }
say()  { printf '%s\n' "$*"; log "INFO $*"; }
ok()   { printf '%s✓%s %s\n' "$C_G" "$C_0" "$*"; log "OK   $*"; }
warn() { printf '%s!%s %s\n' "$C_Y" "$C_0" "$*" >&2; log "WARN $*"; }
err()  { printf '%s✗%s %s\n' "$C_R" "$C_0" "$*" >&2; log "ERR  $*"; }
die()  { err "$*"; exit 1; }
hdr()  { printf '\n%s%s%s\n' "$C_B" "$*" "$C_0"; }

# Команда с выводом в лог. Код возврата — как у команды.
run() {
    log "RUN  $*"
    "$@" >>"$YI_LOG" 2>&1
}

# Ввод всегда с терминала: при запуске через `bash <(curl …)` stdin занят.
# tty_read <переменная> <приглашение>
tty_read() {
    local __v=""
    if [ -r /dev/tty ]; then
        printf '%s' "$2" >/dev/tty
        IFS= read -r __v </dev/tty || __v=""
    fi
    printf -v "$1" '%s' "$__v"
}

# ask_yn <вопрос> <y|n — ответ по умолчанию>. 0 = да.
ask_yn() {
    local q="$1" def="${2:-n}" a hint
    [ "$def" = y ] && hint="[Д/н]" || hint="[д/Н]"
    while :; do
        tty_read a "$q $hint "
        a="${a,,}"
        [ -z "$a" ] && a="$def"
        case "$a" in
            y|yes|д|да) return 0 ;;
            n|no|н|нет) return 1 ;;
        esac
        warn "Ответьте «д» или «н»."
    done
}

# ask_val <переменная> <вопрос> <значение по умолчанию>
ask_val() {
    local __a
    tty_read __a "$2 [${3}]: "
    [ -z "$__a" ] && __a="$3"
    printf -v "$1" '%s' "$__a"
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Нужен root: запустите через sudo или под root."
}

# OS_ID, OS_VER, OS_NAME из /etc/os-release.
os_detect() {
    OS_ID=""; OS_VER=""; OS_NAME="неизвестная ОС"
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        OS_ID=$(. /etc/os-release && printf '%s' "${ID:-}")
        OS_VER=$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")
        OS_NAME=$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-$ID $VERSION_ID}")
    fi
}

os_supported() {
    case "$OS_ID:$OS_VER" in
        ubuntu:22.04|ubuntu:24.04|debian:12) return 0 ;;
    esac
    return 1
}

# Копия файла перед правкой: $YI_BACKUP/<путь через _>.<время>
backup_file() {
    local f="$1" dst
    [ -e "$f" ] || return 0
    mkdir -p "$YI_BACKUP" && chmod 700 "$YI_BACKUP"
    dst="$YI_BACKUP/$(printf '%s' "$f" | tr '/' '_').$(date +%Y%m%d-%H%M%S)"
    cp -a "$f" "$dst" && log "BACKUP $f -> $dst"
}

apt_install() {
    local missing=() p
    for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
    [ "${#missing[@]}" -eq 0 ] && return 0
    say "Ставлю пакеты: ${missing[*]}"
    run env DEBIAN_FRONTEND=noninteractive apt-get update -q &&
        run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}"
}

server_ip() {
    ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1
}
