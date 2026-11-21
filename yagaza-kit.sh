#!/usr/bin/env bash
# ykit — однофайловая сборка от 2026-11-21 14:07:56. Исходники: lib/, modules/, ykit.sh
# Запуск на сервере под root:  bash yagaza-kit.sh   (команда навсегда: bash yagaza-kit.sh --self-install)
YI_BUNDLED=1

# ===== lib/common.sh =====
# shellcheck shell=bash
# Yagaza Kit — общие функции: вывод, вопросы, лог, ОС, копии файлов.

YI_VERSION="0.2.0"
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

# ===== lib/state.sh =====
# shellcheck shell=bash
# Yagaza Kit — состояние модулей: $YI_STATE/<модуль>.conf, строки «ключ=значение».

state_file() { printf '%s/%s.conf' "$YI_STATE" "$1"; }

state_get() {   # state_get <модуль> <ключ>
    local f; f=$(state_file "$1")
    [ -r "$f" ] || return 1
    sed -n "s/^$2=//p" "$f" | tail -1
}

state_set() {   # state_set <модуль> <ключ> <значение>
    local f tmp v="${3//$'\n'/ }"
    mkdir -p "$YI_STATE" && chmod 700 "$YI_ETC" "$YI_STATE"
    f=$(state_file "$1")
    tmp=$(mktemp "$YI_STATE/.tmp.XXXXXX") || return 1
    { [ -r "$f" ] && grep -v "^$2=" "$f"; printf '%s=%s\n' "$2" "$v"; } >"$tmp"
    chmod 600 "$tmp" && mv -f "$tmp" "$f"
}

state_del() {   # state_del <модуль> <ключ>
    local f tmp; f=$(state_file "$1")
    [ -r "$f" ] || return 0
    tmp=$(mktemp "$YI_STATE/.tmp.XXXXXX") || return 1
    grep -v "^$2=" "$f" >"$tmp"
    chmod 600 "$tmp" && mv -f "$tmp" "$f"
}

# ===== lib/ports.sh =====
# shellcheck shell=bash
# Yagaza Kit — кто какие порты держит: ss (процессы, в т.ч. контейнеры с network host)
# и опубликованные порты Docker (их может не быть в ss без docker-proxy).

# Строки: «proto port addr владелец», proto = tcp|udp.
ports_collect() {
    ss -Htulnp 2>/dev/null | awk '
        {
            proto = $1; local = $5; proc = "?"
            n = split(local, a, ":"); port = a[n]
            addr = substr(local, 1, length(local) - length(port) - 1)
            if (match($0, /users:\(\("[^"]+"/)) proc = substr($0, RSTART + 9, RLENGTH - 10)
            print proto, port, addr, proc
        }'
    if command -v docker >/dev/null 2>&1; then
        docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null | while IFS='|' read -r name ports; do
            printf '%s\n' "$ports" | tr ',' '\n' |
                sed -n -E 's/^ *(.*):([0-9]+)->[0-9]+\/(tcp|udp).*/\3 \2 \1 docker:'"$name"'/p'
        done
    fi
}

# Адрес только локальный (127.x, ::1, интерфейс lo)?
addr_is_local() {
    case "$1" in
        127.*|\[::1\]|::1|*%lo|\[::ffff:127.*) return 0 ;;
    esac
    return 1
}

# port_owner <tcp|udp> <порт> — владельцы порта через запятую, пусто = свободен.
port_owner() {
    ports_collect | awk -v p="$1" -v n="$2" '$1 == p && $2 == n { print $4 }' | sort -u | paste -sd, -
}

# Публичные порты: «proto port» без дублей (для черновика правил файрвола).
ports_public() {
    local proto port addr owner
    ports_collect | while read -r proto port addr owner; do
        addr_is_local "$addr" || printf '%s %s\n' "$proto" "$port"
    done | sort -u -k1,1 -k2,2n
}

ports_print() {
    hdr "Порты сервера"
    printf '  %s%s%s%s\n' "$(pad "Прот." 7)" "$(pad "Порт" 8)" "$(pad "Где" 18)" "Кто держит"
    # Одна строка на proto+порт: IPv4/IPv6 и docker-proxy + контейнер сводятся вместе.
    local proto port addr owner
    ports_collect | sort -u | while read -r proto port addr owner; do
        if addr_is_local "$addr"; then printf '%s %s local %s\n' "$proto" "$port" "$owner"
        else printf '%s %s public %s\n' "$proto" "$port" "$owner"; fi
    done | awk '
        { k = $1 " " $2; key[k] = 1
          if ($3 == "public") pub[k] = 1
          if (!index(" " own[k] " ", " " $4 " ")) own[k] = own[k] (own[k] ? " " : "") $4 }
        END { for (k in key) {
                o = own[k]
                if (o ~ /docker:/) { gsub(/(^| )docker-proxy( |$)/, " ", o); gsub(/^ +| +$/, "", o) }
                gsub(/ /, ", ", o)
                print k, (pub[k] ? "снаружи" : "локально"), o } }' |
    sort -k1,1 -k2,2n | while read -r proto port where owner; do
        printf '  %s%s%s%s\n' "$(pad "$proto" 7)" "$(pad "$port" 8)" "$(pad "$where" 18)" "$owner"
    done
}

# ===== lib/ui.sh =====
# shellcheck shell=bash
# Yagaza Kit — экранное меню: стрелки ↑↓ + Enter, цифры, буквы; рамка-шапка,
# значки статусов, подсветка выбранной строки. Без терминала — ввод номера.

ui_tty() { [ -t 1 ] && [ -r /dev/tty ] && [ -z "${YI_PLAIN:-}" ]; }

UI_W=78
if [ -t 1 ]; then
    C_CY=$'\e[36m'; C_MG=$'\e[35m'; C_SEL=$'\e[1;97;48;5;25m'; C_FR=$'\e[38;5;67m'
else
    C_CY=""; C_MG=""; C_SEL=""; C_FR=""
fi

ui_strip() { printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g'; }
ui_rep() { local s=""; for ((_i = 0; _i < $2; _i++)); do s+="$1"; done; printf '%s' "$s"; }

# ---------- рамка ----------

ui_box_top() {   # ui_box_top <заголовок с цветом>
    local t="$1" v; v=$(ui_strip "$t")
    printf ' %s╭─%s %s %s%s╮%s\n' "$C_FR" "$C_0" "$t" "$C_FR" "$(ui_rep ─ $((UI_W - ${#v} - 5)))" "$C_0"
}
ui_box_line() {  # ui_box_line <левый текст> [правый текст]
    local l="$1" r="${2:-}" vl vr n
    vl=$(ui_strip "$l"); vr=$(ui_strip "$r")
    n=$((UI_W - ${#vl} - ${#vr} - 4)); [ "$n" -lt 1 ] && n=1
    printf ' %s│%s %s%*s%s %s│%s\n' "$C_FR" "$C_0" "$l" "$n" '' "$r" "$C_FR" "$C_0"
}
ui_box_bottom() { printf ' %s╰%s╯%s\n' "$C_FR" "$(ui_rep ─ $((UI_W - 2)))" "$C_0"; }

# ---------- значки и цвета ----------

# ui_fmt <status|check> <текст> → UF_P (без цвета), UF_C (с цветом). Значок + текст.
ui_fmt() {
    local kind="$1" t="$2" ic col
    if [ "$kind" = status ]; then
        case "$t" in
            работает*|настроено*|установлен*) ic="●"; col="$C_G" ;;
            *частично*)                        ic="◐"; col="$C_Y" ;;
            *остановлен*|*"не подключ"*)       ic="■"; col="$C_R" ;;
            *разработке*)                      ic="·"; col="$C_D" ;;
            *)                                 ic="○"; col="$C_D" ;;
        esac
    else
        case "$t" in
            "готов ("*)  ic="!"; col="$C_Y"; t="${t#готов (}"; t="${t%)}" ;;
            готов)       ic="✓"; col="$C_G" ;;
            установлен)  ic="✓"; col="$C_G" ;;
            *"уже есть"*) ic="!"; col="$C_Y" ;;
            —|"")        ic="·"; col="$C_D"; t="" ;;
            *)           ic="✗"; col="$C_R" ;;
        esac
    fi
    UF_P="$ic $t"
    UF_C="$col$ic$C_0 $col$t$C_0"
}

# Совместимость: цвет без значка (для строк вне меню).
ui_color() { ui_fmt status "$1"; printf '%s' "$UF_C"; }

# ---------- клавиатура ----------

# Одна клавиша → UI_KEY: up, down, enter, esc или сам символ.
ui_key() {
    local k k2=""
    IFS= read -rsn1 k </dev/tty || { UI_KEY=q; return; }
    if [ "$k" = $'\e' ]; then
        IFS= read -rsn2 -t 0.05 k2 </dev/tty || k2=""
        case "$k2" in
            '[A'|OA) UI_KEY=up ;;
            '[B'|OB) UI_KEY=down ;;
            *) UI_KEY=esc ;;
        esac
    elif [ -z "$k" ]; then UI_KEY=enter
    else UI_KEY="$k"; fi
}

ui_pause() {
    ui_tty || return 0
    printf '\n  %sEnter — назад%s' "$C_D" "$C_0" >/dev/tty
    IFS= read -rs _ </dev/tty || true
}

# ---------- выбор из списка ----------

# ui_select <функция-шапка>
# Вход: UI_ROWS (с цветом), UI_PLAIN (тот же текст без цвета, для подсветки),
#       UI_KEYS (ключ строки; пусто — строка не выбирается: заголовок или пустая).
# Выход: UI_CHOICE.
ui_select() {
    local head="$1" sel=-1 i n="${#UI_ROWS[@]}" d="" k2="" p
    for ((i = 0; i < n; i++)); do [ -n "${UI_KEYS[$i]}" ] && { sel=$i; break; }; done
    [ "$sel" -ge 0 ] || return 1
    printf '\e[?25l' >/dev/tty
    while :; do
        printf '\e[H\e[2J'
        "$head"
        for ((i = 0; i < n; i++)); do
            if [ "$i" -eq "$sel" ]; then
                p="${UI_PLAIN[$i]}"
                printf ' %s▌ %s%*s%s\n' "$C_SEL" "$p" $(( UI_W - ${#p} - 3 > 0 ? UI_W - ${#p} - 3 : 0 )) '' "$C_0"
            else
                printf '   %s\n' "${UI_ROWS[$i]}"
            fi
        done
        printf '\n  %s↑↓%s выбор   %sEnter%s открыть   %sцифра/буква%s сразу   %sq%s выход\n' \
            "$C_B" "$C_D" "$C_B" "$C_D" "$C_B" "$C_D" "$C_B" "$C_D$C_0"
        printf '%s' "$C_0"
        ui_key
        case "$UI_KEY" in
            up)   i=$sel; while :; do i=$(( (i - 1 + n) % n )); [ -n "${UI_KEYS[$i]}" ] && break; done; sel=$i ;;
            down) i=$sel; while :; do i=$(( (i + 1) % n )); [ -n "${UI_KEYS[$i]}" ] && break; done; sel=$i ;;
            enter) UI_CHOICE="${UI_KEYS[$sel]}"; break ;;
            esc|q|Q) UI_CHOICE=q; break ;;
            [0-9])
                # Две цифры (10, 11…): ждём вторую чуть-чуть.
                d="$UI_KEY"
                if IFS= read -rsn1 -t 0.5 k2 </dev/tty && [[ "$k2" =~ [0-9] ]]; then d="$d$k2"; fi
                for ((i = 0; i < n; i++)); do [ "${UI_KEYS[$i]}" = "$d" ] && { UI_CHOICE="$d"; break 2; }; done ;;
            *)
                for ((i = 0; i < n; i++)); do [ "${UI_KEYS[$i]}" = "${UI_KEY,,}" ] && { UI_CHOICE="${UI_KEY,,}"; break 2; }; done ;;
        esac
    done
    printf '\e[?25h' >/dev/tty
    printf '\e[H\e[2J'
}

# Добавить строку: ui_add <ключ> <цветной текст> <простой текст>
ui_add() { UI_KEYS+=("$1"); UI_ROWS+=("$2"); UI_PLAIN+=("$3"); }
ui_reset() { UI_KEYS=(); UI_ROWS=(); UI_PLAIN=(); }

# ===== modules/amneziawg.sh =====
# shellcheck shell=bash
# Yagaza Kit — AmneziaWG (https://github.com/amnezia-vpn): модуль ядра + awg/awg-quick
# из PPA Amnezia (ppa:amnezia/ppa), сервер awg0, NAT своей таблицей nftables,
# клиенты с конфигом и QR-кодом.
#
# Источники фактов: README amneziawg-linux-kernel-module (установка Ubuntu/Debian,
# допустимые диапазоны Jc/Jmin/Jmax/S1/S2/H1–H4), Launchpad API (отпечаток ключа
# PPA и собранные серии), amneziawg-tools (путь /etc/amnezia/amneziawg, awg-quick@).
# Используются только «классические» параметры маскировки (Jc, Jmin, Jmax, S1, S2,
# H1–H4): их понимают все версии awg и клиенты AmneziaVPN / AmneziaWG.

AWG_IF="awg0"
AWG_DIR="/etc/amnezia/amneziawg"
AWG_CONF="$AWG_DIR/$AWG_IF.conf"
AWG_CLIENTS="$YI_ETC/awg-clients"
AWG_PPA_FPR="75C9DD72C799870E310542E24166F2C257290828"
AWG_KEYRING="/etc/apt/keyrings/amnezia-ppa.gpg"
AWG_APT_LIST="/etc/apt/sources.list.d/ykit-amnezia.list"
AWG_SYSCTL="/etc/sysctl.d/99-ykit-awg.conf"
AWG_NFT_TABLE="ykit_awg"

amneziawg_title() { printf 'AmneziaWG'; }
amneziawg_installed() { [ -f "$AWG_CONF" ] && command -v awg >/dev/null 2>&1; }
amneziawg_port() { sed -n -E 's/^ListenPort *= *([0-9]+).*/\1/p' "$AWG_CONF" 2>/dev/null | head -1; }
amneziawg_nclients() { find "$AWG_CLIENTS" -maxdepth 1 -name '*.conf' 2>/dev/null | wc -l; }

amneziawg_summary() {
    if ! amneziawg_installed; then printf 'не установлен'; return; fi
    if systemctl is-active --quiet "awg-quick@$AWG_IF" 2>/dev/null; then
        printf 'работает, %s/udp, клиентов %s' "$(amneziawg_port)" "$(amneziawg_nclients)"
    else printf 'установлен, остановлен'; fi
}

# Уже работающая Amnezia в Docker (приложение AmneziaVPN ставит контейнеры amnezia-*).
amneziawg_docker() {
    command -v docker >/dev/null 2>&1 || return 1
    docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^amnezia' | paste -sd, - | grep .
}

amneziawg_check() {
    local d
    if amneziawg_installed; then printf 'установлен'; return 0; fi
    os_supported || { printf 'ОС не из проверенных'; return 1; }
    if d=$(amneziawg_docker); then printf 'готов (уже есть в Docker: %s)' "$d"; return 0; fi
    printf 'готов'
}

# ---------- установка пакетов ----------

# PPA собирается для Ubuntu; для Debian README Amnezia велит брать серию focal.
amneziawg_series() {
    case "$OS_ID" in
        ubuntu) . /etc/os-release && printf '%s' "${VERSION_CODENAME:-}" ;;
        debian) printf 'focal' ;;
        *) return 1 ;;
    esac
}

amneziawg_has_debsrc() {
    grep -rqsE '^[[:space:]]*deb-src[[:space:]]|^Types:.*deb-src' /etc/apt/sources.list /etc/apt/sources.list.d/
}

# Модулю DKMS могут понадобиться исходники ядра — README Amnezia требует deb-src.
amneziawg_enable_debsrc() {
    local f
    amneziawg_has_debsrc && return 0
    warn "Для сборки модуля AmneziaWG нужны репозитории исходников (deb-src), сейчас их нет."
    ask_yn "Включить deb-src для системных репозиториев?" y || return 1
    if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then          # Ubuntu 24.04 (deb822)
        f=/etc/apt/sources.list.d/ubuntu.sources; backup_file "$f"
        sed -i -E 's/^Types:[[:space:]]*deb[[:space:]]*$/Types: deb deb-src/' "$f"
    elif [ -f /etc/apt/sources.list.d/debian.sources ]; then        # Debian (deb822)
        f=/etc/apt/sources.list.d/debian.sources; backup_file "$f"
        sed -i -E 's/^Types:[[:space:]]*deb[[:space:]]*$/Types: deb deb-src/' "$f"
    else                                                             # классический sources.list
        f=/etc/apt/sources.list; backup_file "$f"
        grep -E '^[[:space:]]*deb[[:space:]]' "$f" | sed -E 's/^([[:space:]]*)deb([[:space:]])/\1deb-src\2/' >>"$f"
    fi
    amneziawg_has_debsrc && ok "deb-src включён ($f)." || { err "Не получилось включить deb-src в $f."; return 1; }
}

amneziawg_add_repo() {
    local series tmp got
    series=$(amneziawg_series) || { err "ОС $OS_NAME не поддерживается модулем."; return 1; }
    [ -n "$series" ] || { err "Не определил кодовое имя Ubuntu."; return 1; }
    apt_install ca-certificates curl gnupg || return 1
    if [ ! -s "$AWG_KEYRING" ]; then
        tmp=$(mktemp) || return 1
        curl -fsSL --max-time 60 "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$AWG_PPA_FPR" -o "$tmp" ||
            { err "Не скачал ключ PPA Amnezia с keyserver.ubuntu.com."; rm -f "$tmp"; return 1; }
        got=$(gpg --show-keys --with-colons "$tmp" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
        if [ "$got" != "$AWG_PPA_FPR" ]; then
            err "Отпечаток ключа PPA не совпал (получен: ${got:-пусто}) — не добавляю репозиторий."; rm -f "$tmp"; return 1
        fi
        mkdir -p "$(dirname "$AWG_KEYRING")"
        gpg --dearmor <"$tmp" >"$AWG_KEYRING" && chmod 644 "$AWG_KEYRING"
        rm -f "$tmp"
        ok "Ключ PPA Amnezia добавлен, отпечаток сверен."
    fi
    printf 'deb [signed-by=%s] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu %s main\ndeb-src [signed-by=%s] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu %s main\n' \
        "$AWG_KEYRING" "$series" "$AWG_KEYRING" "$series" >"$AWG_APT_LIST"
    run env DEBIAN_FRONTEND=noninteractive apt-get update -q || { err "apt-get update с PPA Amnezia не прошёл."; return 1; }
}

amneziawg_packages() {
    local hdrs="linux-headers-$(uname -r)"
    say "Ставлю $hdrs и amneziawg (сборка модуля ядра через DKMS, 1–5 минут)…"
    if ! run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$hdrs"; then
        err "Нет пакета $hdrs. Возможно, у VPS своё ядро (OpenVZ/LXC или ядро провайдера) — модуль не собрать."
        return 1
    fi
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q amneziawg qrencode ||
        { err "Не поставился amneziawg, подробности: $YI_LOG"; return 1; }
    if ! run modprobe amneziawg; then
        err "Модуль ядра amneziawg не загрузился. Если ядро только что обновилось — перезагрузите сервер и повторите."
        return 1
    fi
    command -v awg >/dev/null && command -v awg-quick >/dev/null || { err "Нет awg/awg-quick после установки."; return 1; }
    ok "AmneziaWG установлен, модуль ядра загружен."
}

# ---------- параметры и конфиги ----------

rnd() { printf '%s' $(( $1 + ( (RANDOM << 15 | RANDOM) % ($2 - $1 + 1) ) )); }   # rnd <min> <max>
rnd31() { printf '%s' $(( 5 + ( (RANDOM << 30 | RANDOM << 15 | RANDOM) % 2147483643 ) )); }

# Параметры маскировки в рекомендованных диапазонах README Amnezia.
amneziawg_gen_obf() {
    local s1 s2 h1 h2 h3 h4
    s1=$(rnd 15 150)
    while :; do s2=$(rnd 15 150); [ $((s1 + 56)) -ne "$s2" ] && break; done
    while :; do
        h1=$(rnd31); h2=$(rnd31); h3=$(rnd31); h4=$(rnd31)
        [ "$(printf '%s\n' "$h1" "$h2" "$h3" "$h4" | sort -u | wc -l)" -eq 4 ] && break
    done
    printf 'Jc = %s\nJmin = 8\nJmax = 80\nS1 = %s\nS2 = %s\nH1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\n' \
        "$(rnd 4 12)" "$s1" "$s2" "$h1" "$h2" "$h3" "$h4"
}

amneziawg_free_udp() {
    local p
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        p=$(rnd 30000 60000)
        [ -z "$(port_owner udp "$p")" ] && { printf '%s' "$p"; return 0; }
    done
    printf '51820'
}

amneziawg_write_hooks() {   # amneziawg_write_hooks <подсеть> <внешний интерфейс>
    local net="$1" wan="$2"
    cat >"$AWG_DIR/$AWG_IF-up.sh" <<EOF
#!/bin/sh
# Yagaza Kit: NAT и пропуск трафика $AWG_IF (своя таблица nftables).
nft -f - <<'NFT'
table inet $AWG_NFT_TABLE
delete table inet $AWG_NFT_TABLE
table inet $AWG_NFT_TABLE {
    chain forward {
        type filter hook forward priority filter; policy accept;
        iifname "$AWG_IF" accept
        oifname "$AWG_IF" ct state established,related accept
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr $net oifname "$wan" masquerade
    }
}
NFT
# Docker ставит политику DROP в iptables FORWARD — пропускаем awg через DOCKER-USER.
if iptables -nL DOCKER-USER >/dev/null 2>&1; then
    iptables -C DOCKER-USER -i $AWG_IF -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER -i $AWG_IF -j ACCEPT
    iptables -C DOCKER-USER -o $AWG_IF -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null ||
        iptables -I DOCKER-USER -o $AWG_IF -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
fi
EOF
    cat >"$AWG_DIR/$AWG_IF-down.sh" <<EOF
#!/bin/sh
nft delete table inet $AWG_NFT_TABLE 2>/dev/null
if iptables -nL DOCKER-USER >/dev/null 2>&1; then
    iptables -D DOCKER-USER -i $AWG_IF -j ACCEPT 2>/dev/null
    iptables -D DOCKER-USER -o $AWG_IF -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
fi
exit 0
EOF
    chmod 700 "$AWG_DIR/$AWG_IF-up.sh" "$AWG_DIR/$AWG_IF-down.sh"
}

amneziawg_server_setup() {
    local port net wan priv
    port=$(amneziawg_free_udp)
    ask_val port "UDP-порт AmneziaWG (случайный — хуже для блокировок по порту)" "$port"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { err "Порт — число 1–65535."; return 1; }
    [ -z "$(port_owner udp "$port")" ] || { err "Порт $port/udp занят: $(port_owner udp "$port")"; return 1; }

    ask_val net "Подсеть клиентов (/24)" "10.66.66.0/24"
    [[ "$net" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.0/24$ ]] || { err "Нужна подсеть вида 10.66.66.0/24."; return 1; }
    if ip -4 route show | grep -q "^${net%/24}"; then err "Подсеть $net уже есть в маршрутах сервера."; return 1; fi

    wan=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
    [ -n "$wan" ] || { err "Не определил внешний интерфейс."; return 1; }

    mkdir -p "$AWG_DIR" "$AWG_CLIENTS"; chmod 700 "$AWG_DIR" "$AWG_CLIENTS"
    priv=$(awg genkey)
    amneziawg_write_hooks "$net" "$wan"
    {
        echo "# ykit: сервер AmneziaWG. Клиенты: ykit → AmneziaWG"
        echo "[Interface]"
        echo "PrivateKey = $priv"
        echo "Address = ${net%.0/24}.1/24"
        echo "ListenPort = $port"
        amneziawg_gen_obf
        echo "PostUp = $AWG_DIR/$AWG_IF-up.sh"
        echo "PostDown = $AWG_DIR/$AWG_IF-down.sh"
    } >"$AWG_CONF"
    chmod 600 "$AWG_CONF"

    printf 'net.ipv4.ip_forward = 1\n' >"$AWG_SYSCTL"
    run sysctl -p "$AWG_SYSCTL"
    run systemctl enable --now "awg-quick@$AWG_IF" || { err "awg-quick@$AWG_IF не запустился: journalctl -u awg-quick@$AWG_IF"; return 1; }
    declare -F base_fw_on >/dev/null && base_fw_on && base_fw_allow udp "$port"
    state_set amneziawg port "$port"; state_set amneziawg net "$net"
    ok "Сервер AmneziaWG запущен: $AWG_IF, $port/udp, подсеть $net."
}

# ---------- клиенты ----------

amneziawg_next_ip() {
    local base n
    base=$(sed -n -E 's/^Address *= *([0-9]+\.[0-9]+\.[0-9]+)\.1\/24.*/\1/p' "$AWG_CONF" | head -1)
    for n in $(seq 2 254); do
        grep -q "AllowedIPs = $base.$n/32" "$AWG_CONF" || { printf '%s.%s' "$base" "$n"; return 0; }
    done
    return 1
}

amneziawg_apply() {
    awg syncconf "$AWG_IF" <(awg-quick strip "$AWG_IF") 2>>"$YI_LOG"
}

amneziawg_client_add() {
    local name dns
    ask_val name "Имя клиента (латиница, цифры, - _)" "phone$(( $(amneziawg_nclients) + 1 ))"
    ask_val dns "DNS для клиента" "1.1.1.1, 8.8.8.8"
    amneziawg_client_new "$name" "$dns" && amneziawg_client_show "$name"
    return 0
}

# Без вопросов (для меню и бота). Код 0 — клиент добавлен и применён.
amneziawg_client_new() {
    local name="$1" dns="${2:-1.1.1.1, 8.8.8.8}" ip priv pub psk spub endpoint cf
    [[ "$name" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || { err "Имя: латиница, цифры, - _, до 32 символов."; return 1; }
    cf="$AWG_CLIENTS/$name.conf"
    [ -e "$cf" ] && { err "Клиент $name уже есть."; return 1; }
    ip=$(amneziawg_next_ip) || { err "В подсети нет свободных адресов."; return 1; }

    priv=$(awg genkey); pub=$(printf '%s' "$priv" | awg pubkey); psk=$(awg genpsk)
    spub=$(sed -n -E 's/^PrivateKey *= *(.+)$/\1/p' "$AWG_CONF" | head -1 | awg pubkey)
    endpoint="$(server_ip):$(amneziawg_port)"

    backup_file "$AWG_CONF"
    printf '\n# client: %s\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s/32\n' \
        "$name" "$pub" "$psk" "$ip" >>"$AWG_CONF"
    {
        echo "[Interface]"
        echo "PrivateKey = $priv"
        echo "Address = $ip/32"
        echo "DNS = $dns"
        # Параметры маскировки должны совпадать с сервером (Jc/Jmin/Jmax могут отличаться).
        grep -E '^(Jc|Jmin|Jmax|S1|S2|H1|H2|H3|H4) *=' "$AWG_CONF"
        echo
        echo "[Peer]"
        echo "PublicKey = $spub"
        echo "PresharedKey = $psk"
        echo "Endpoint = $endpoint"
        echo "AllowedIPs = 0.0.0.0/0"
        echo "PersistentKeepalive = 25"
    } >"$cf"
    chmod 600 "$cf"
    if amneziawg_apply; then ok "Клиент $name добавлен ($ip)." >&2
    else err "Клиент записан, но awg syncconf не применил — перезапустите: systemctl restart awg-quick@$AWG_IF"; fi
    return 0
}

amneziawg_client_remove() {   # без вопросов
    local name="$1" tmp
    [[ "$name" =~ ^[A-Za-z0-9_-]{1,32}$ ]] && [ -f "$AWG_CLIENTS/$name.conf" ] || { err "Нет клиента $name."; return 1; }
    backup_file "$AWG_CONF"
    tmp=$(mktemp) || return 1
    # Блок клиента: строка «# client: имя» и следующие 4 строки [Peer].
    awk -v n="# client: $name" '$0 == n { skip = 5 } skip > 0 { skip--; next } { print }' "$AWG_CONF" >"$tmp"
    cat "$tmp" >"$AWG_CONF"; rm -f "$tmp"
    rm -f "$AWG_CLIENTS/$name.conf"
    amneziawg_apply || { err "Удалён из файла, но awg syncconf не применил."; return 1; }
}

amneziawg_client_show() {
    local name="$1" cf="$AWG_CLIENTS/$1.conf"
    [ -r "$cf" ] || { err "Нет клиента $name."; return 0; }
    hdr "Клиент $name — импортируйте в AmneziaVPN или AmneziaWG (это ключ доступа, не публикуйте)"
    if command -v qrencode >/dev/null; then qrencode -t ansiutf8 <"$cf"; fi
    say "Файл: $cf"
    cat "$cf"
}

amneziawg_client_list() {
    local f
    hdr "Клиенты AmneziaWG"
    for f in "$AWG_CLIENTS"/*.conf; do
        [ -e "$f" ] || { say "  Пока нет."; return 0; }
        printf '  %s  %s\n' "$(pad "$(basename "$f" .conf)" 20)" "$(sed -n -E 's/^Address *= *(.+)$/\1/p' "$f")"
    done
}

amneziawg_client_del() {
    local name pub tmp
    amneziawg_client_list
    ask_val name "Кого удалить" ""
    [[ "$name" =~ ^[A-Za-z0-9_-]{1,32}$ ]] && [ -f "$AWG_CLIENTS/$name.conf" ] || { err "Нет клиента $name."; return 0; }
    ask_yn "Удалить клиента $name? Его конфиг перестанет работать." n || return 0
    amneziawg_client_remove "$name" && ok "Клиент $name удалён."
    return 0
}

# ---------- входы модуля ----------

amneziawg_install() {
    local a
    if amneziawg_installed; then
        while :; do
            hdr "AmneziaWG — $(amneziawg_summary)"
            printf '  1  Добавить клиента\n  2  Список клиентов\n  3  Показать клиента (конфиг и QR)\n  4  Удалить клиента\n  0  Назад\n'
            tty_read a " Выбор: "
            case "$a" in
                1) amneziawg_client_add ;;
                2) amneziawg_client_list ;;
                3) amneziawg_client_list; tty_read a "Имя клиента: "; amneziawg_client_show "$a" ;;
                4) amneziawg_client_del ;;
                0|q|"") return 0 ;;
                *) warn "Нет такого пункта." ;;
            esac
        done
    fi

    hdr "AmneziaWG — установка"
    os_supported || warn "ОС $OS_NAME не из проверенных (Ubuntu 22.04/24.04, Debian 12)."
    if a=$(amneziawg_docker); then
        warn "На сервере уже работает Amnezia в Docker: $a. Второй сервер AmneziaWG будет работать параллельно на своём порту."
        ask_yn "Всё равно ставить свой?" n || return 0
    fi
    say "Будет: PPA Amnezia (ключ сверяется по отпечатку), заголовки ядра, модуль amneziawg (DKMS),"
    say "сервер $AWG_IF с NAT, включение ip_forward. Ядро VPS должно быть обычным (KVM), не OpenVZ/LXC."
    ask_yn "Продолжить?" y || return 0
    amneziawg_enable_debsrc || return 0
    amneziawg_add_repo || return 0
    amneziawg_packages || return 0
    amneziawg_server_setup || return 0
    ask_yn "Создать первого клиента?" y && amneziawg_client_add
}

amneziawg_status() {
    hdr "AmneziaWG — состояние"
    if ! amneziawg_installed; then say "  Не установлен."; return 0; fi
    printf '  Служба  : awg-quick@%s (%s)\n' "$AWG_IF" "$(systemctl is-active "awg-quick@$AWG_IF" 2>/dev/null)"
    printf '  Порт    : %s/udp\n' "$(amneziawg_port)"
    printf '  Подсеть : %s\n' "$(state_get amneziawg net 2>/dev/null || echo '?')"
    printf '  Клиенты : %s (%s)\n' "$(amneziawg_nclients)" "$AWG_CLIENTS"
    awg show "$AWG_IF" 2>/dev/null | grep -E 'peer|latest handshake|transfer' | sed 's/^/    /'
}

amneziawg_remove() {
    amneziawg_installed || { ok "AmneziaWG не установлен."; return 0; }
    ask_yn "Удалить сервер AmneziaWG и всех клиентов? (копии — в $YI_BACKUP)" n || return 0
    run systemctl disable --now "awg-quick@$AWG_IF" || true
    backup_file "$AWG_CONF"
    mkdir -p "$YI_BACKUP" && tar -czf "$YI_BACKUP/awg-clients.$(date +%Y%m%d-%H%M%S).tgz" -C "$YI_ETC" awg-clients 2>/dev/null
    rm -rf "$AWG_CLIENTS" "$AWG_CONF" "$AWG_DIR/$AWG_IF-up.sh" "$AWG_DIR/$AWG_IF-down.sh" "$AWG_SYSCTL"
    state_del amneziawg port; state_del amneziawg net
    if ask_yn "Удалить и пакеты amneziawg (модуль ядра, awg) и PPA?" n; then
        local pk
        pk=$(dpkg-query -W -f='${Package}\n' 'amneziawg*' 2>/dev/null | paste -sd' ' -)
        [ -n "$pk" ] && run env DEBIAN_FRONTEND=noninteractive apt-get purge -y -q $pk
        rm -f "$AWG_APT_LIST" "$AWG_KEYRING"
    fi
    ok "AmneziaWG удалён. ip_forward вернётся к системному после перезагрузки."
}

# ===== modules/base.sh =====
# shellcheck shell=bash
# Yagaza Kit — модуль «Базовая настройка VPS»: пакеты, часовой пояс, swap, BBR,
# SSH (только ключи, смена порта) и файрвол nftables. Каждый шаг — по вопросу.
#
# Защита от потери доступа:
#  - SSH: сначала слушаем старый И новый порт, вы входите в новой сессии,
#    только потом старый порт убирается. Таймер откатывает всё через 5 минут,
#    если подтверждения не было.
#  - Файрвол: своя таблица inet ykit (чужие правила, Docker и Xray не трогаем),
#    таймер удаляет её через 2 минуты без подтверждения.

# sshd берёт ПЕРВОЕ значение, файлы читаются по алфавиту: «00-00-» раньше любых
# «00-hardening.conf», «50-cloud-init.conf» и т.п.
BASE_SSH_DROPIN="/etc/ssh/sshd_config.d/00-00-ykit.conf"
BASE_SSH_REVERT_UNIT="ykit-ssh-revert"
BASE_FW_FILE="$YI_ETC/fw.nft"
BASE_FW_UNIT="/etc/systemd/system/ykit-fw.service"
BASE_FW_REVERT_UNIT="ykit-fw-revert"
BASE_BBR_FILE="/etc/sysctl.d/99-ykit-bbr.conf"

base_title() { printf 'Базовая настройка'; }

# ---------- состояние ----------

base_ssh_ports() {
    sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' | sort -un | paste -sd' ' -
}
base_ssh_passauth() { sshd -T 2>/dev/null | awk '$1 == "passwordauthentication" { print $2 }'; }
base_bbr_on() { [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = bbr ]; }
base_swap_on() { [ -n "$(swapon --noheadings --show=NAME 2>/dev/null)" ]; }
base_fw_on() { nft list table inet ykit >/dev/null 2>&1; }

base_summary() {
    local parts=()
    [ "$(base_ssh_passauth)" = no ] && parts+=("SSH")
    base_bbr_on && parts+=("BBR")
    base_swap_on && parts+=("swap")
    base_fw_on && parts+=("FW")
    case "${#parts[@]}" in
        0) printf 'не настроено' ;;
        4) printf 'настроено' ;;
        *) printf 'частично: %s' "${parts[*]}" ;;
    esac
}

base_check() { printf 'готов'; return 0; }

base_status() {
    hdr "Базовая настройка — состояние"
    printf '  Обновление пакетов : %s\n' "$(state_get base apt_upgraded 2>/dev/null || echo 'не запускалось Yagaza Kit')"
    printf '  Часовой пояс       : %s\n' "$(timedatectl show -p Timezone --value 2>/dev/null || echo '?')"
    printf '  Swap               : %s\n' "$(swapon --noheadings --show=NAME,SIZE 2>/dev/null | paste -sd';' - | sed 's/^$/нет/')"
    printf '  Алгоритм TCP       : %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    printf '  SSH порт(ы)        : %s\n' "$(base_ssh_ports)"
    printf '  SSH по паролю      : %s\n' "$(base_ssh_passauth)"
    if base_fw_on; then printf '  Файрвол Yagaza Kit  : включён (%s)\n' "$BASE_FW_FILE"
    else printf '  Файрвол Yagaza Kit  : нет\n'; fi
}

# ---------- шаги ----------

base_step_apt() {
    ask_yn "Обновить пакеты (apt upgrade)?" y || return 0
    say "Обновляю пакеты, это может занять несколько минут…"
    if run env DEBIAN_FRONTEND=noninteractive apt-get update -q &&
       run env DEBIAN_FRONTEND=noninteractive apt-get -y -q \
           -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade; then
        state_set base apt_upgraded "$(date '+%F %T')"
        ok "Пакеты обновлены."
        [ -f /var/run/reboot-required ] && warn "Системе нужна перезагрузка (новое ядро или библиотеки). Перезагрузите сервер, когда будет удобно."
    else
        err "apt завершился с ошибкой, подробности: $YI_LOG"
    fi
}

base_step_tz() {
    local cur tz
    cur=$(timedatectl show -p Timezone --value 2>/dev/null)
    ask_yn "Часовой пояс сейчас ${cur:-?}. Изменить?" n || return 0
    ask_val tz "Часовой пояс" "Europe/Moscow"
    if ! timedatectl list-timezones 2>/dev/null | grep -qx "$tz"; then
        err "Нет такого часового пояса: $tz"; return 0
    fi
    run timedatectl set-timezone "$tz" && ok "Часовой пояс: $tz" || err "Не удалось сменить часовой пояс."
}

base_step_swap() {
    local size
    if base_swap_on; then ok "Swap уже есть — пропускаю."; return 0; fi
    if [ "$(findmnt -no FSTYPE / 2>/dev/null)" = btrfs ]; then
        warn "Корень на btrfs: swap-файл так не создать, пропускаю."; return 0
    fi
    ask_yn "Swap нет. Создать swap-файл?" y || return 0
    ask_val size "Размер (например 1G, 2G)" "1G"
    [[ "$size" =~ ^[0-9]+[MG]$ ]] || { err "Размер в формате 512M или 2G."; return 0; }
    if [ -e /swapfile ]; then err "/swapfile уже существует, но не включён — разберитесь вручную."; return 0; fi
    local mb="${size%?}"
    [ "${size: -1}" = G ] && mb=$(( mb * 1024 ))
    if { run fallocate -l "$size" /swapfile || run dd if=/dev/zero of=/swapfile bs=1M count="$mb"; } &&
       run chmod 600 /swapfile && run mkswap /swapfile && run swapon /swapfile; then
        grep -q '^/swapfile ' /etc/fstab || { backup_file /etc/fstab; printf '/swapfile none swap sw 0 0\n' >>/etc/fstab; }
        ok "Swap $size включён и прописан в /etc/fstab."
    else
        err "Swap создать не удалось, подробности: $YI_LOG"; rm -f /swapfile
    fi
}

base_step_bbr() {
    if base_bbr_on; then ok "BBR уже включён."; return 0; fi
    ask_yn "Включить BBR (ускоряет TCP на загруженных каналах)?" y || return 0
    run modprobe tcp_bbr || true
    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        err "Ядро не поддерживает BBR — пропускаю."; return 0
    fi
    printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' >"$BASE_BBR_FILE"
    run sysctl -p "$BASE_BBR_FILE" && base_bbr_on && ok "BBR включён." || err "Не удалось включить BBR."
}

# ----- SSH -----

base_ssh_restart() {
    run sshd -t || { err "sshd -t: конфиг SSH с ошибкой, ничего не применяю."; return 1; }
    run systemctl daemon-reload
    # Ubuntu 22.10+: порт держит ssh.socket, порт берётся из sshd_config генератором.
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        run systemctl restart ssh.socket || return 1
    fi
    if systemctl is-active --quiet ssh 2>/dev/null; then run systemctl restart ssh
    elif systemctl is-active --quiet sshd 2>/dev/null; then run systemctl restart sshd
    fi
    return 0
}

# Скрипт отката SSH: вернуть прежний drop-in (или удалить наш) и перезапустить.
base_ssh_revert_script() {
    local s="$YI_ETC/ssh-revert.sh"
    cat >"$s" <<EOF
#!/bin/sh
if [ -f "$YI_ETC/ssh-dropin.prev" ]; then mv -f "$YI_ETC/ssh-dropin.prev" "$BASE_SSH_DROPIN"; else rm -f "$BASE_SSH_DROPIN"; fi
systemctl daemon-reload
systemctl is-active --quiet ssh.socket && systemctl restart ssh.socket
systemctl is-active --quiet ssh && systemctl restart ssh
systemctl is-active --quiet sshd && systemctl restart sshd
echo "\$(date '+%F %T') WARN SSH откатён таймером" >>"$YI_LOG"
EOF
    chmod 700 "$s"
    printf '%s' "$s"
}

base_ssh_write() {   # base_ssh_write <порты через пробел> <yes|no — пароль>
    local p
    {
        echo "# ykit: базовая настройка SSH. Откат: yagaza --rollback base.ssh"
        for p in $1; do echo "Port $p"; done
        echo "PermitRootLogin prohibit-password"
        echo "PasswordAuthentication $2"
        echo "KbdInteractiveAuthentication no"
        echo "PubkeyAuthentication yes"
    } >"$BASE_SSH_DROPIN"
    chmod 644 "$BASE_SSH_DROPIN"
}

base_step_ssh() {
    local cur newport pass="no" owner script ip
    cur=$(base_ssh_ports)
    ask_yn "SSH: вход только по ключу и/или смена порта (сейчас: порт ${cur:-?}, вход по паролю: $(base_ssh_passauth))?" n || return 0

    if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
        err "В /etc/ssh/sshd_config нет строки Include /etc/ssh/sshd_config.d/*.conf — пропускаю SSH."; return 0
    fi
    if ! grep -Eqs '^(ssh|ecdsa|sk-)' /root/.ssh/authorized_keys; then
        err "В /root/.ssh/authorized_keys нет ключей. Сначала добавьте ключ (ssh-copy-id), иначе потеряете доступ."; return 0
    fi
    if ! ask_yn "Отключить вход по паролю (только ключи)?" y; then pass="yes"; fi

    ask_val newport "Новый порт SSH (Enter — оставить ${cur%% *})" "${cur%% *}"
    [[ "$newport" =~ ^[0-9]+$ ]] && [ "$newport" -ge 1 ] && [ "$newport" -le 65535 ] || { err "Порт — число 1–65535."; return 0; }
    if [[ " $cur " != *" $newport "* ]]; then
        owner=$(port_owner tcp "$newport")
        [ -n "$owner" ] && { err "Порт $newport/tcp занят: $owner"; return 0; }
    fi

    # Этап 1: старые порты + новый, таймер отката 5 минут.
    [ -f "$BASE_SSH_DROPIN" ] && cp -a "$BASE_SSH_DROPIN" "$YI_ETC/ssh-dropin.prev" || rm -f "$YI_ETC/ssh-dropin.prev"
    script=$(base_ssh_revert_script)
    run systemctl stop "$BASE_SSH_REVERT_UNIT.timer" 2>/dev/null || true
    run systemd-run --unit="$BASE_SSH_REVERT_UNIT" --on-active=300 /bin/sh "$script" ||
        { err "Не удалось поставить таймер отката — SSH не трогаю."; return 0; }

    base_ssh_write "$(printf '%s\n' $cur "$newport" | sort -un | paste -sd' ' -)" "$pass"
    # Сверка: sshd -T показывает итог с учётом всех файлов. Не тот — значит, другой файл перебивает.
    if [[ " $(base_ssh_ports) " != *" $newport "* ]] || [ "$(base_ssh_passauth)" != "$pass" ]; then
        err "Настройки не применились (порт: $(base_ssh_ports), пароль: $(base_ssh_passauth)) — их перебивает другой файл SSH:"
        grep -lE '^[[:space:]]*(Port|PasswordAuthentication)[[:space:]]' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | sed 's/^/    /' >&2
        run /bin/sh "$script"; run systemctl stop "$BASE_SSH_REVERT_UNIT.timer"; return 0
    fi
    if ! base_ssh_restart; then run /bin/sh "$script"; run systemctl stop "$BASE_SSH_REVERT_UNIT.timer"; return 0; fi
    base_fw_on && base_fw_allow tcp "$newport"

    ip=$(server_ip)
    warn "Не закрывайте эту сессию! Откройте НОВОЕ окно и войдите:"
    say  "    ssh -p $newport root@${ip:-<IP сервера>}"
    say  "  Без подтверждения через 5 минут настройки SSH откатятся сами."
    if ! ask_yn "Вошли в новой сессии?" n; then
        run /bin/sh "$script"; run systemctl stop "$BASE_SSH_REVERT_UNIT.timer"
        warn "SSH откатён к прежним настройкам."; return 0
    fi

    # Этап 2: оставить только новый порт.
    base_ssh_write "$newport" "$pass"
    if base_ssh_restart; then
        run systemctl stop "$BASE_SSH_REVERT_UNIT.timer"
        rm -f "$YI_ETC/ssh-dropin.prev"
        state_set base ssh_port "$newport"
        ok "SSH: порт $newport, вход по паролю: $pass."
        [ "$newport" != "${cur%% *}" ] && base_fw_on && say "  Старый порт в файрволе можно убрать: yagaza --install base → файрвол."
    else
        run /bin/sh "$script"; run systemctl stop "$BASE_SSH_REVERT_UNIT.timer"
        err "Не удалось применить, SSH откатён."
    fi
}

base_ssh_rollback() {
    if [ ! -f "$BASE_SSH_DROPIN" ]; then ok "Настроек SSH от Yagaza Kit нет."; return 0; fi
    backup_file "$BASE_SSH_DROPIN"
    rm -f "$BASE_SSH_DROPIN" "$YI_ETC/ssh-dropin.prev"
    base_ssh_restart && ok "SSH возвращён к настройкам системы (порт: $(base_ssh_ports))."
    state_del base ssh_port
}

# ----- Файрвол -----

base_fw_render() {   # base_fw_render <tcp-порты> <udp-порты>
    local t u
    t=$(printf '%s' "$1" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -un | paste -sd, -)
    u=$(printf '%s' "$2" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -un | paste -sd, -)
    cat <<EOF
# Yagaza Kit: входящий файрвол. Своя таблица, чужие правила (Docker, Xray) не трогает.
# Откат: yagaza --rollback base.fw
table inet ykit
delete table inet ykit
table inet ykit {
    chain input {
        type filter hook input priority filter; policy drop;
        ct state established,related accept
        ct state invalid drop
        iif "lo" accept
        iifname "docker0" accept
        iifname "br-*" accept
        meta l4proto { icmp, ipv6-icmp } accept
$( [ -n "$t" ] && printf '        tcp dport { %s } accept\n' "$t" )
$( [ -n "$u" ] && printf '        udp dport { %s } accept\n' "$u" )
    }
}
EOF
}

base_fw_load_unit() {
    local nft; nft=$(command -v nft)
    cat >"$BASE_FW_UNIT" <<EOF
[Unit]
Description=Yagaza Kit: входящий файрвол (таблица inet ykit)
Wants=network-pre.target
Before=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$nft -f $BASE_FW_FILE
ExecStop=$nft delete table inet ykit

[Install]
WantedBy=multi-user.target
EOF
    run systemctl daemon-reload && run systemctl enable ykit-fw.service
}

# Добавить порт в действующие правила и в файл (для других модулей).
base_fw_allow() {   # base_fw_allow <tcp|udp> <порт>
    local tcp udp
    [ -f "$BASE_FW_FILE" ] || return 0
    tcp=$(state_get base fw_tcp); udp=$(state_get base fw_udp)
    if [ "$1" = tcp ]; then tcp="$tcp $2"; else udp="$udp $2"; fi
    base_fw_render "$tcp" "$udp" >"$BASE_FW_FILE"
    run nft -f "$BASE_FW_FILE" && { state_set base fw_tcp "$tcp"; state_set base fw_udp "$udp"; ok "Файрвол: открыт $2/$1."; }
}

base_step_fw() {
    local tcp="" udp="" proto port t2 u2
    if systemctl is-active --quiet ufw 2>/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
        warn "Включён ufw — свой файрвол не ставлю, чтобы правила не конфликтовали."; return 0
    fi
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        warn "Включён firewalld — свой файрвол не ставлю."; return 0
    fi
    ask_yn "Файрвол: закрыть все входящие, кроме нужных портов (nftables)?" n || return 0
    apt_install nftables || { err "Не удалось поставить nftables."; return 0; }

    # Черновик: всё, что сейчас слушает снаружи, + порты SSH.
    while read -r proto port; do
        [ "$proto" = tcp ] && tcp="$tcp $port"
        [ "$proto" = udp ] && udp="$udp $port"
    done < <(ports_public)
    tcp="$tcp $(base_ssh_ports)"
    tcp=$(printf '%s' "$tcp" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -un | paste -sd' ' -)
    udp=$(printf '%s' "$udp" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -un | paste -sd' ' -)

    say "Сейчас снаружи слушают (их и предлагаю оставить открытыми):"
    ask_val t2 "  TCP-порты через пробел" "$tcp"
    ask_val u2 "  UDP-порты через пробел (пусто — «-»)" "${udp:--}"
    [ "$u2" = "-" ] && u2=""
    for port in $(base_ssh_ports); do
        [[ " $t2 " == *" $port "* ]] || { warn "Порт SSH $port добавлен принудительно."; t2="$t2 $port"; }
    done

    mkdir -p "$YI_ETC"
    base_fw_render "$t2" "$u2" >"$BASE_FW_FILE"
    run nft -c -f "$BASE_FW_FILE" || { err "Правила с ошибкой (nft -c), ничего не применено. Файл: $BASE_FW_FILE"; return 0; }

    run systemctl stop "$BASE_FW_REVERT_UNIT.timer" 2>/dev/null || true
    run systemd-run --unit="$BASE_FW_REVERT_UNIT" --on-active=120 "$(command -v nft)" delete table inet ykit ||
        { err "Не удалось поставить таймер отката — файрвол не включаю."; return 0; }
    run nft -f "$BASE_FW_FILE" || { err "nft не применил правила."; run systemctl stop "$BASE_FW_REVERT_UNIT.timer"; return 0; }

    warn "Правила включены. Проверьте в НОВОМ окне, что SSH открывается, и что сервисы работают."
    say  "  Без подтверждения через 2 минуты файрвол снимется сам."
    if ask_yn "Всё работает?" n; then
        run systemctl stop "$BASE_FW_REVERT_UNIT.timer"
        base_fw_load_unit
        state_set base fw_tcp "$t2"; state_set base fw_udp "$u2"
        ok "Файрвол включён и переживёт перезагрузку. TCP: $t2 | UDP: ${u2:-нет}"
    else
        run nft delete table inet ykit
        run systemctl stop "$BASE_FW_REVERT_UNIT.timer"
        warn "Файрвол снят."
    fi
}

base_fw_rollback() {
    run systemctl disable --now ykit-fw.service 2>/dev/null || true
    rm -f "$BASE_FW_UNIT"; run systemctl daemon-reload
    nft delete table inet ykit 2>/dev/null || true
    state_del base fw_tcp; state_del base fw_udp
    ok "Файрвол Yagaza Kitснят (файл правил оставлен: $BASE_FW_FILE)."
}

# ---------- входы модуля ----------

base_install() {
    hdr "Базовая настройка VPS"
    say "Каждый шаг спросит разрешения. Лог: $YI_LOG"
    base_step_apt
    base_step_tz
    base_step_swap
    base_step_bbr
    base_step_ssh
    base_step_fw
    hdr "Готово."
    base_status
}

base_rollback() {   # base_rollback <ssh|fw|bbr>
    case "$1" in
        ssh) base_ssh_rollback ;;
        fw)  base_fw_rollback ;;
        bbr) rm -f "$BASE_BBR_FILE"; ok "Файл BBR удалён; вернётся к системному после перезагрузки." ;;
        *)   err "Что откатить: ssh, fw или bbr."; return 1 ;;
    esac
}

# ===== modules/bot.sh =====
# shellcheck shell=bash
# Yagaza Kit — Telegram-бот владельца: статус сервера, порты, ключи VLESS / AmneziaWG /
# MTProxy кнопками. Код бота — bot/ykit-bot.py (Python 3, только стандартная
# библиотека), действия — через `yagaza --api`. Служба ykit-bot, long polling.
#
# Токен хранится в /etc/ykit/bot.conf (600) и не попадает в лог: запросы к Bot API
# с токеном в URL здесь не проходят через run() (он пишет команду в лог).

BOT_DIR="/opt/ykit-bot"
BOT_PY="$BOT_DIR/ykit-bot.py"
BOT_CONF="$YI_ETC/bot.conf"
BOT_UNIT="ykit-bot"
BOT_UNIT_FILE="/etc/systemd/system/$BOT_UNIT.service"

bot_title() { printf 'Telegram-бот'; }
bot_installed() { [ -f "$BOT_PY" ] && [ -f "$BOT_CONF" ]; }

bot_summary() {
    if ! bot_installed; then printf 'не установлен'; return; fi
    if systemctl is-active --quiet "$BOT_UNIT" 2>/dev/null; then printf 'работает'; else printf 'установлен, остановлен'; fi
}

bot_check() {
    if bot_installed; then printf 'установлен'; return 0; fi
    command -v python3 >/dev/null 2>&1 || { printf 'нет python3'; return 1; }
    printf 'готов'
}

# Исходник бота: в однофайловой сборке он вшит функцией ykit_bot_py.
bot_source() {
    if declare -F ykit_bot_py >/dev/null; then ykit_bot_py
    elif [ -r "$YI_HOME/bot/ykit-bot.py" ]; then cat "$YI_HOME/bot/ykit-bot.py"
    else return 1; fi
}

bot_api() {   # bot_api <токен> <метод> [json] — без записи в лог
    curl -fsS --max-time 70 -H 'Content-Type: application/json' -d "${3:-{\}}" "https://api.telegram.org/bot$1/$2" 2>/dev/null
}

bot_write_unit() {
    cat >"$BOT_UNIT_FILE" <<EOF
[Unit]
Description=Yagaza Kit: Telegram-бот владельца
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$(command -v python3) $BOT_PY
Environment=PYTHONUNBUFFERED=1
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
}

bot_install() {
    local token me uname upd ids admin name
    hdr "Telegram-бот Yagaza Kit"
    if bot_installed; then
        say "Установлен: $(bot_summary). Админы: $(sed -n 's/^ADMINS=//p' "$BOT_CONF")"
        ask_yn "Обновить код бота до версии из этого Yagaza Kit?" y || return 0
        bot_source >"$BOT_PY" && chmod 700 "$BOT_PY" && run systemctl restart "$BOT_UNIT" && ok "Бот обновлён и перезапущен."
        return 0
    fi
    command -v python3 >/dev/null 2>&1 || apt_install python3 || { err "Нет python3."; return 0; }
    apt_install qrencode curl || true
    bot_source >/dev/null || { err "Не найден код бота (bot/ykit-bot.py)."; return 0; }

    say "1) В Telegram откройте @BotFather → /newbot → получите токен."
    say "   Нужен ОТДЕЛЬНЫЙ бот: один токен может опрашивать только одна программа."
    printf 'Токен бота (ввод скрыт): ' >/dev/tty
    IFS= read -rs token </dev/tty || token=""; printf '\n' >/dev/tty
    token=$(printf '%s' "$token" | tr -d '[:space:]')
    [[ "$token" =~ ^[0-9]{5,}:[A-Za-z0-9_-]{30,}$ ]] || { err "Не похоже на токен вида 123456:ABC…"; return 0; }
    me=$(bot_api "$token" getMe) || { err "Telegram не принял токен (или нет доступа к api.telegram.org)."; return 0; }
    uname=$(printf '%s' "$me" | sed -n 's/.*"username":"\([^"]*\)".*/\1/p')
    ok "Бот найден: @$uname"
    if printf '%s' "$(bot_api "$token" getWebhookInfo)" | grep -q '"url":"[^"]'; then
        err "У этого бота настроен вебхук — им пользуется другая программа. Создайте отдельного бота."; return 0
    fi

    say "2) Откройте в Telegram ${C_B}@$uname${C_0} и отправьте ему ${C_B}/start${C_0} — так я узнаю ваш ID."
    say "   Жду до 2 минут…"
    admin=""
    for _ in 1 2 3 4; do
        upd=$(bot_api "$token" getUpdates '{"timeout":30,"allowed_updates":["message"]}') || upd=""
        ids=$(printf '%s' "$upd" | grep -o '"from":{"id":[0-9]*' | grep -o '[0-9]*$' | sort -u)
        if [ -n "$ids" ]; then admin=$(printf '%s\n' "$ids" | tail -1); break; fi
    done
    if [ -z "$admin" ]; then
        warn "Сообщение не пришло. Свой ID можно узнать у @userinfobot."
        ask_val admin "Ваш Telegram ID (число)" ""
    else
        name=$(printf '%s' "$upd" | sed -n 's/.*"from":{"id":'"$admin"',[^}]*"first_name":"\([^"]*\)".*/\1/p' | head -1)
        ask_yn "Владелец бота — ${name:-пользователь} (ID $admin). Верно?" y || ask_val admin "Ваш Telegram ID (число)" ""
    fi
    [[ "$admin" =~ ^[0-9]{3,}$ ]] || { err "ID — число."; return 0; }

    mkdir -p "$YI_ETC" "$BOT_DIR"; chmod 700 "$YI_ETC" "$BOT_DIR"
    ( umask 077; printf '# Yagaza Kit: Telegram-бот. Доступ — только ADMINS (через запятую).\nTOKEN=%s\nADMINS=%s\n' "$token" "$admin" >"$BOT_CONF" )
    bot_source >"$BOT_PY"; chmod 700 "$BOT_PY"
    bot_write_unit
    run systemctl daemon-reload; run systemctl enable --now "$BOT_UNIT"
    sleep 3
    if systemctl is-active --quiet "$BOT_UNIT"; then
        ok "Бот @$uname работает. Напишите ему /start — придёт меню сервера."
        say "  BotFather (по желанию): /setjoingroups → Disable, чтобы бота нельзя было добавить в группы."
    else
        err "Служба $BOT_UNIT не запустилась: journalctl -u $BOT_UNIT -n 30"
    fi
}

bot_status() {
    hdr "Telegram-бот — состояние"
    if ! bot_installed; then say "  Не установлен."; return 0; fi
    printf '  Служба : %s (%s)\n' "$BOT_UNIT" "$(systemctl is-active "$BOT_UNIT" 2>/dev/null)"
    printf '  Админы : %s\n' "$(sed -n 's/^ADMINS=//p' "$BOT_CONF")"
    say "  Последние записи:"
    journalctl -u "$BOT_UNIT" -n 8 --no-pager -o cat 2>/dev/null | sed 's/^/    /'
}

bot_remove() {
    bot_installed || [ -f "$BOT_UNIT_FILE" ] || { ok "Бот не установлен."; return 0; }
    ask_yn "Удалить Telegram-бота (служба, код, токен)?" n || return 0
    run systemctl disable --now "$BOT_UNIT" || true
    rm -f "$BOT_UNIT_FILE"; run systemctl daemon-reload
    rm -rf "$BOT_DIR" "$BOT_CONF" "$YI_ETC/bot.offset"
    ok "Бот удалён. Самого бота в Telegram удалите у @BotFather (/deletebot) или отзовите токен (/revoke)."
}

# ===== modules/dns.sh =====
# shellcheck shell=bash
# Yagaza Kit — свой DNS-сервер на AdGuard Home (https://github.com/AdguardTeam/AdGuardHome,
# GPLv3): DoT/DoH, фильтры рекламы, веб-панель.
#
# Безопасность: веб-панель и мастер первого запуска слушают ТОЛЬКО 127.0.0.1:3000
# (флаг --web-addr сохраняется в службе) — открывать через SSH-туннель. Обычный DNS
# (53) наружу не открываем: открытый резолвер используют для DDoS-усиления.
#
# Источники: релизы GitHub (AdGuardHome_linux_<arch>.tar.gz + checksums.txt),
# Configuration.md проекта (--web-addr, -s install|uninstall|status|reload,
# «-s reload перечитывает сертификат», аргументы -s install сохраняются в службе).

AGH_VERSION="${AGH_VERSION:-1.0.0}"
AGH_DIR="/opt/AdGuardHome"
AGH_BIN="$AGH_DIR/AdGuardHome"
AGH_WEB="127.0.0.1:3000"

dns_title() { printf 'DNS (AdGuard Home)'; }
dns_installed() { [ -x "$AGH_BIN" ]; }
dns_running() { systemctl is-active --quiet AdGuardHome 2>/dev/null; }
dns_configured() { [ -f "$AGH_DIR/AdGuardHome.yaml" ]; }

dns_summary() {
    if ! dns_installed; then printf 'не установлен'; return; fi
    if ! dns_running; then printf 'установлен, остановлен'; return; fi
    if dns_configured; then printf 'работает'; else printf 'работает, ждёт мастер настройки'; fi
}

dns_check() {
    local o
    if dns_installed; then printf 'установлен'; return 0; fi
    o=$(port_owner tcp 853)
    [ -n "$o" ] && { printf '853/tcp занят: %s' "$o"; return 1; }
    o=$(port_owner tcp 3000)
    [ -n "$o" ] && { printf '3000/tcp занят: %s' "$o"; return 1; }
    printf 'готов'
}

dns_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'amd64' ;;
        aarch64|arm64) printf 'arm64' ;;
        *) return 1 ;;
    esac
}

dns_fetch() {
    local arch name base tmp sum
    arch=$(dns_arch) || { err "Архитектура $(uname -m) не поддерживается модулем."; return 1; }
    name="AdGuardHome_linux_$arch.tar.gz"
    base="https://github.com/AdguardTeam/AdGuardHome/releases/download/v$AGH_VERSION"
    tmp=$(mktemp -d) || return 1
    say "Скачиваю AdGuard Home $AGH_VERSION ($arch) с GitHub…"
    if ! curl -fsSL --max-time 180 -o "$tmp/$name" "$base/$name" ||
       ! curl -fsSL --max-time 60 -o "$tmp/checksums.txt" "$base/checksums.txt"; then
        err "Не удалось скачать AdGuard Home."; rm -rf "$tmp"; return 1
    fi
    sum=$(awk -v n="./$name" '$2 == n || $2 == substr(n, 3) { print $1 }' "$tmp/checksums.txt" | head -1)
    if [ -z "$sum" ] || [ "$(sha256sum "$tmp/$name" | cut -d' ' -f1)" != "$sum" ]; then
        err "Контрольная сумма AdGuard Home не совпала — не ставлю."; rm -rf "$tmp"; return 1
    fi
    tar -xzf "$tmp/$name" -C "$tmp" || { err "Архив повреждён."; rm -rf "$tmp"; return 1; }
    mkdir -p "$AGH_DIR"
    install -m 755 -o root -g root "$tmp/AdGuardHome/AdGuardHome" "$AGH_BIN"
    rm -rf "$tmp"
    log "AdGuard Home $AGH_VERSION установлен, sha256 архива $sum"
    ok "AdGuard Home $AGH_VERSION скачан, sha256 сверен."
}

dns_tunnel_hint() {
    local ip; ip=$(server_ip)
    say "  Панель AdGuard Home открыта только на этом сервере ($AGH_WEB). С ПК — через SSH-туннель:"
    say "    ${C_B}ssh -L 3000:127.0.0.1:3000 root@${ip:-<IP>}${C_0}   (порт SSH — свой, если меняли: -p <порт>)"
    say "  и в браузере на ПК: ${C_B}http://127.0.0.1:3000${C_0}"
}

# Сертификат Let's Encrypt (certbot standalone, нужен свободный 80/tcp и A-запись домена).
dns_cert() {
    local domain o ip dip
    ask_yn "Выпустить сертификат Let's Encrypt для DoT/DoH (нужен домен с A-записью на этот сервер)?" y || return 0
    ask_val domain "Домен (например dns.example.com)" ""
    [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$ ]] || { err "Нужен домен вида dns.example.com."; return 0; }
    ip=$(server_ip); dip=$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR == 1 { print $1 }')
    if [ "$dip" != "$ip" ]; then
        warn "$domain указывает на ${dip:-ничего}, а IP сервера $ip. Сертификат не выпустится, пока A-запись не исправлена."
        ask_yn "Всё равно попробовать?" n || return 0
    fi
    o=$(port_owner tcp 80)
    if [ -n "$o" ]; then
        err "80/tcp занят ($o) — certbot standalone не сможет пройти проверку."
        say "  Варианты: выпустить сертификат тем, кто держит 80 (например Caddy), или освободить 80 на время."
        return 0
    fi
    apt_install certbot || { err "Не поставился certbot."; return 0; }
    declare -F base_fw_on >/dev/null && base_fw_on && base_fw_allow tcp 80
    if run certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email \
            -d "$domain" --deploy-hook "$AGH_BIN -s reload"; then
        state_set dns domain "$domain"
        ok "Сертификат выпущен. Продление — автоматически (таймер certbot), после продления AdGuard Home перечитает его сам."
        say "  В панели: Настройки → Настройки шифрования:"
        say "    Доменное имя:         ${C_B}$domain${C_0}"
        say "    Путь к сертификату:   ${C_B}/etc/letsencrypt/live/$domain/fullchain.pem${C_0}"
        say "    Путь к ключу:         ${C_B}/etc/letsencrypt/live/$domain/privkey.pem${C_0}"
    else
        err "certbot не выпустил сертификат, подробности: $YI_LOG"
    fi
}

dns_install() {
    local p443 o
    hdr "DNS — AdGuard Home $AGH_VERSION"
    if dns_installed; then
        say "Установлен: $(dns_summary)."
        dns_tunnel_hint
        dns_cert
        return 0
    fi
    say "Будет: AdGuard Home в $AGH_DIR (служба AdGuardHome), панель только на $AGH_WEB."
    say "Дальше — мастер настройки в браузере через SSH-туннель и (по желанию) сертификат для DoT/DoH."
    ask_yn "Продолжить?" y || return 0

    dns_fetch || return 0
    run "$AGH_BIN" -s install --web-addr "$AGH_WEB" --no-check-update ||
        { err "Служба AdGuard Home не установилась, см. $YI_LOG"; return 0; }
    sleep 2
    dns_running && ok "AdGuard Home запущен, ждёт мастер настройки." || warn "Служба не запустилась: systemctl status AdGuardHome"
    state_set dns version "$AGH_VERSION"

    hdr "Шаг 2 — мастер настройки (в браузере)"
    dns_tunnel_hint
    say "  В мастере:"
    say "   • Веб-интерфейс: оставьте ${C_B}127.0.0.1 : 3000${C_0} (наружу панель не открываем)."
    if [ -n "$(port_owner udp 53)$(port_owner tcp 53)" ]; then
        say "   • DNS-сервер: интерфейс ${C_B}127.0.0.1${C_0}, порт 53 (systemd-resolved слушает 127.0.0.53 — не мешает)."
        say "     Если мастер скажет «порт занят» — порт ${C_B}5353${C_0}."
    else
        say "   • DNS-сервер: интерфейс ${C_B}127.0.0.1${C_0}, порт 53 — обычный DNS наружу не открываем."
    fi
    say "   • Логин и надёжный пароль — сохраните в KeePassXC."

    hdr "Шаг 3 — шифрование (DoT/DoH)"
    o=$(port_owner tcp 443)
    p443=443; [ -n "$o" ] && { p443=8443; say "  443/tcp занят ($o) — для DoH берите порт ${C_B}8443${C_0}."; }
    say "  Клиентам открываются: DoT ${C_B}853/tcp${C_0} и DoH ${C_B}$p443/tcp${C_0} (https://<домен>:$p443/dns-query)."
    say "  Учтите: на HTTPS-порту AdGuard Home может отдавать и панель (с логином) — пароль должен быть надёжным."
    dns_cert
    if declare -F base_fw_on >/dev/null && base_fw_on; then
        ask_yn "Открыть в файрволе Yagaza Kit 853/tcp и $p443/tcp?" y && { base_fw_allow tcp 853; base_fw_allow tcp "$p443"; }
    fi
    state_set dns doh_port "$p443"
}

dns_status() {
    hdr "DNS — состояние"
    if ! dns_installed; then say "  Не установлен."; return 0; fi
    printf '  Версия   : %s\n' "$("$AGH_BIN" --version 2>/dev/null | head -1)"
    printf '  Служба   : AdGuardHome (%s)\n' "$(systemctl is-active AdGuardHome 2>/dev/null)"
    printf '  Настроен : %s\n' "$(dns_configured && echo 'да (мастер пройден)' || echo 'нет — пройдите мастер')"
    printf '  Домен    : %s\n' "$(state_get dns domain 2>/dev/null || echo '—')"
    printf '  Слушает  :\n'
    ports_collect | awk '$4 ~ /AdGuard/ { printf "    %s %s %s\n", $1, $3, $2 }' | sort -u
    dns_tunnel_hint
}

dns_remove() {
    dns_installed || { ok "AdGuard Home не установлен."; return 0; }
    ask_yn "Удалить AdGuard Home (службу; настройки и статистику — по отдельному вопросу)?" n || return 0
    run "$AGH_BIN" -s uninstall || true
    if ask_yn "Удалить и папку $AGH_DIR с настройками и статистикой?" n; then
        [ -f "$AGH_DIR/AdGuardHome.yaml" ] && backup_file "$AGH_DIR/AdGuardHome.yaml"
        rm -rf "$AGH_DIR"
    fi
    state_del dns version
    ok "AdGuard Home удалён. Сертификат Let's Encrypt оставлен (certbot delete --cert-name <домен>, если не нужен)."
}

# ===== modules/e4.sh =====
# shellcheck shell=bash
# Yagaza Kit — ваши проекты Evgen4ik: Evgen4ik TV и WEB-прокси (из Evgen4ik Proxy).
# Установщики — ваши публичные репозитории koksik2022/*, скачиваются по ЗАКРЕПЛЁННОМУ
# коммиту и сверяются по SHA-256; дальше работает сам установщик (вопросы — его).
#
# Обновить версию: поменять E4TV_* / E4PX_* ниже (коммит + sha256 опубликованного файла).

E4TV_VER="3.17"
E4TV_URL="https://raw.githubusercontent.com/koksik2022/evgen4ik-tv/d2383f25961e277594908770da87803e7c5ffdf3/evgen4ik-tv-install.sh"
E4TV_SHA="1a2dd6c1ae35ccb8da5575f1a64b8ce52fcd78382c3e9634cf3ed8210fb44417"

E4PX_VER="1.0"
E4PX_URL="https://raw.githubusercontent.com/koksik2022/evgen4ik-proxy/97a512bfa78d213e883808c65d4fc5b69d77f640/evgen4ik-proxy-install.sh"
E4PX_SHA="7db5b9f385a4655d8c4ae6e6f7ce437709d6cb72326eef952eefe9966a34b26b"

E4_WORK="/opt/ykit-e4"

# e4_fetch <url> <sha256> <файл> — скачать и сверить.
e4_fetch() {
    mkdir -p "$E4_WORK" && chmod 700 "$E4_WORK"
    curl -fsSL --retry 2 --max-time 180 -o "$3" "$1" || { err "Не скачал $(basename "$3")."; return 1; }
    if [ "$(sha256sum "$3" | cut -d' ' -f1)" != "$2" ]; then
        err "Контрольная сумма $(basename "$3") не совпала — не запускаю."; rm -f "$3"; return 1
    fi
    chmod 700 "$3"; ok "$(basename "$3") скачан, SHA-256 сверен."
}

e4_handoff() {   # e4_handoff <название> <команда…>
    local name="$1" rc; shift
    printf '\n%s──── Дальше работает установщик %s ────%s\n\n' "$C_B" "$name" "$C_0"
    "$@" </dev/tty; rc=$?
    printf '\n%s──── Снова Yagaza Kit ────%s\n' "$C_B" "$C_0"
    return "$rc"
}

# ===================== совет по портам =====================

# Кто держит порт — понятными словами.
e4_who() {
    local o; o=$(port_owner tcp "$1")
    [ -n "$o" ] || return 1
    case "$o" in
        *rw-core*|*rw-node*) printf 'Xray (нода Remnawave)' ;;
        *caddy*)  if webproxy_installed; then printf 'Caddy (ваш WEB-прокси)'
                  elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^caddy-remnawave$'; then printf 'Caddy (Remnawave)'
                  else printf 'Caddy'; fi ;;
        *nginx*)  if e4tv_installed; then printf 'nginx (Evgen4ik TV)'; else printf 'nginx'; fi ;;
        *xray*)   printf 'Xray (%s)' "$o" ;;
        *)        printf '%s' "$o" ;;
    esac
}

e4_free_from() {   # первый свободный TCP-порт начиная с $1, кроме $2
    local p="$1"
    while [ "$p" -lt 65000 ]; do
        [ "$p" != "${2:-}" ] && [ -z "$(port_owner tcp "$p")" ] && { printf '%s' "$p"; return 0; }
        p=$((p + 1))
    done
    return 1
}

e4_ram_mb() { awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo 2>/dev/null; }

# Прогноз портов Evgen4ik TV — та же логика, что resolve_ports() в установщике TV 3.17:
# домен только при свободных 80 и 443; без домена плейлисты на 80, иначе с 8090;
# редактор (режим «через сервер») на 8080, иначе со следующего за плейлистами (8091).
e4tv_plan() {
    TV_DOMAIN_OK=1
    e4_who 80 >/dev/null && TV_DOMAIN_OK=0
    e4_who 443 >/dev/null && TV_DOMAIN_OK=0
    if [ -z "$(port_owner tcp 80)" ]; then TV_HTTP=80; else TV_HTTP=$(e4_free_from 8090); fi
    if [ -z "$(port_owner tcp 8080)" ] && [ "$TV_HTTP" != 8080 ]; then TV_EDIT=8080
    else TV_EDIT=$(e4_free_from $([ "$TV_HTTP" = 80 ] && echo 8091 || echo $((TV_HTTP + 1))) "$TV_HTTP"); fi
}

e4tv_advice() {
    local ip w80 w443 ram
    e4tv_plan; ip=$(server_ip)
    w80=$(e4_who 80) || w80="свободен"; w443=$(e4_who 443) || w443="свободен"
    hdr "Как лучше поставить Evgen4ik TV на этот сервер"
    say "  Порт 80:  $w80"
    say "  Порт 443: $w443"
    if [ "$TV_DOMAIN_OK" = 1 ]; then
        ok "Можно С ДОМЕНОМ (HTTPS) — рекомендую: адрес вида https://tv.ваш-домен, работает во всех плеерах."
        say "  Нужна A-запись домена на ${ip:-этот сервер}. Без домена — плейлисты по http на порту 80."
    else
        warn "С доменом на этом сервере НЕ получится: порты 80/443 заняты."
        say  "  Будет БЕЗ ДОМЕНА (http, по IP):"
        say  "    плейлисты:  ${C_B}http://${ip:-IP}:$TV_HTTP/${C_0}"
        say  "    редактор:   ${C_B}http://${ip:-IP}:$TV_EDIT${C_0}  (в режиме «через сервер»)"
        say  "  Варианты:"
        say  "    1) так и поставить — всё работает, но без https и с портом в адресе;"
        say  "    2) поставить на отдельный сервер со свободными 80/443 — будет домен и https;"
        say  "    3) освободить 80/443 на этом сервере (если там не нужное)."
        if [[ "$w443" == *Remnawave* ]]; then
            say "  ${C_D}Здесь нода Remnawave — 443 ей нужен, лучше вариант 1 или 2.${C_0}"
        fi
    fi
    ram=$(e4_ram_mb)
    if [ -n "$ram" ] && [ "$ram" -lt 1900 ]; then
        warn "Памяти $ram МБ: режим «через сервер» (HLS Proxy) лучше от 2 ГБ. Если провайдер ТВ не требует — выбирайте «напрямую»."
    fi
}

# ===================== Evgen4ik TV =====================

e4tv_title() { printf 'Evgen4ik TV'; }
e4tv_installed() { [ -x /usr/local/bin/e4tv ]; }

e4tv_summary() {
    if ! e4tv_installed; then printf 'не установлен'; return; fi
    if systemctl is-active --quiet e4tv-editor.service 2>/dev/null; then printf 'работает'; else printf 'установлен, остановлен'; fi
}

e4tv_check() {
    if e4tv_installed; then printf 'установлен'; return 0; fi
    e4tv_plan
    if [ "$TV_DOMAIN_OK" = 1 ]; then printf 'готов'
    else printf 'готов (без домена: %s/%s — 80/443 заняты)' "$TV_HTTP" "$TV_EDIT"; fi
}

e4tv_install() {
    local f="$E4_WORK/evgen4ik-tv-install.sh" a args=()
    hdr "Evgen4ik TV $E4TV_VER"
    if e4tv_installed; then
        say "Установлен: $(e4tv_summary)."
        printf '  1  Обновить до %s (настройки сохраняются)\n  2  Перенастроить\n  3  Подключить домен (HTTPS)\n  0  Назад\n' "$E4TV_VER"
        tty_read a " Выбор: "
        case "$a" in
            1) args=(--update) ;;
            2) args=(--reconfigure) ;;
            3) e4tv_plan
               if [ "$TV_DOMAIN_OK" != 1 ]; then
                   err "Домен не подключить: заняты 80/443 ($(e4_who 80 || echo '—'), $(e4_who 443 || echo '—'))."; return 0
               fi
               tty_read a "Домен: "; [[ "$a" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { err "Нужен домен."; return 0; }; args=(--set-domain "$a") ;;
            *) return 0 ;;
        esac
    else
        say "Ставится: Evgen4ik TV (редактор плейлистов), nginx; в режиме «через сервер» — ещё HLS Proxy."
        e4tv_advice
        if [ "$TV_DOMAIN_OK" = 1 ]; then
            ask_yn "Скачать установщик Evgen4ik TV $E4TV_VER и запустить? (домен он спросит сам)" y || return 0
        else
            ask_yn "Ставить БЕЗ домена на этот сервер (плейлисты :$TV_HTTP, редактор :$TV_EDIT)?" y || return 0
        fi
    fi
    e4_fetch "$E4TV_URL" "$E4TV_SHA" "$f" || return 0
    e4_handoff "Evgen4ik TV" bash "$f" "${args[@]}"
    e4tv_installed && ok "Evgen4ik TV: $(e4tv_summary). Команды: e4tv info · e4tv status · e4tv passwd" ||
        warn "Evgen4ik TV не обнаружен после установщика."
    state_set e4tv last_run "$(date '+%F %T')"
}

e4tv_status() {
    hdr "Evgen4ik TV — состояние"
    if ! e4tv_installed; then say "  Не установлен."; return 0; fi
    /usr/local/bin/e4tv status 2>&1 | sed 's/^/  /' | head -30
}

# ===================== WEB-прокси (Evgen4ik Proxy) =====================

webproxy_title() { printf 'WEB-прокси'; }
webproxy_installed() { [ -f /etc/systemd/system/tproxy-server.service ] || [ -f /opt/tgwebproxy/info.env ]; }

webproxy_summary() {
    if ! webproxy_installed; then printf 'не установлен'; return; fi
    if systemctl is-active --quiet tproxy-server 2>/dev/null && systemctl is-active --quiet caddy 2>/dev/null; then printf 'работает'
    else printf 'установлен, остановлен'; fi
}

webproxy_check() {
    local o80 o443 b=""
    if webproxy_installed; then printf 'установлен'; return 0; fi
    [ "$(uname -m)" = x86_64 ] || { printf 'только x86_64'; return 1; }
    o80=$(port_owner tcp 80); o443=$(port_owner tcp 443)
    [ -n "$o80" ] && [ "$o80" != caddy ] && b="80/tcp занят: $o80"
    [ -n "$o443" ] && [ "$o443" != caddy ] && b="${b:+$b; }443/tcp занят: $o443"
    [ -n "$b" ] && { printf '%s' "$b"; return 1; }
    printf 'готов'
}

# Почему не встанет и что делать.
webproxy_advice() {
    local w80 w443
    w80=$(e4_who 80) || w80="свободен"; w443=$(e4_who 443) || w443="свободен"
    hdr "WEB-прокси на этот сервер не встанет"
    say "  WEB-прокси нужны оба порта 80 и 443 (Caddy) и свой домен без CDN."
    say "  Порт 80:  $w80"
    say "  Порт 443: $w443"
    say "  Что можно сделать:"
    if [[ "$w80$w443" == *"Evgen4ik TV"* ]]; then
        say "    • Evgen4ik TV занимает 80/443 (с доменом). Переставьте TV без домена:"
        say "      пункт «Evgen4ik TV» → Перенастроить → без домена. Тогда WEB-прокси встанет здесь."
    fi
    if [[ "$w443" == *Remnawave* || "$w443" == Xray* ]]; then
        say "    • На 443 работает Xray — он нужен клиентам VPN. Ставьте WEB-прокси на отдельный сервер."
    fi
    say "    • Отдельный небольшой VPS со свободными 80/443 и поддоменом (например web.ваш-домен) — самый простой путь."
    say "    • Или освободить 80/443 здесь, если то, что их держит, не нужно."
}

webproxy_install() {
    local f="$E4_WORK/evgen4ik-proxy-install.sh" v
    hdr "WEB-прокси (Evgen4ik Proxy $E4PX_VER)"
    if ! webproxy_installed; then
        if ! v=$(webproxy_check); then
            webproxy_advice; return 0
        fi
        say "Ставится: tg-webproxy (Caddy на 80/443, tproxy-server) — WEB-прокси для Telegram, до 16 клиентов."
        say "Нужен свой домен (A-запись на этот сервер, без CDN). Бот управления установщик предложит сам."
        if e4tv_installed; then
            say "${C_D}Evgen4ik TV на этом сервере уже работает без 80/443 — мешать не будет.${C_0}"
        else
            say "${C_D}После WEB-прокси Evgen4ik TV на этом сервере встанет только без домена (порты 8090/8091).${C_0}"
        fi
    else
        say "Установлен: $(webproxy_summary). Повторный запуск безопасен: клиенты и настройки сохраняются."
    fi
    ask_yn "Скачать установщик Evgen4ik Proxy $E4PX_VER (только WEB-прокси) и запустить?" y || return 0
    e4_fetch "$E4PX_URL" "$E4PX_SHA" "$f" || return 0
    e4_handoff "Evgen4ik Proxy" env PROXY=web bash "$f"
    webproxy_installed && ok "WEB-прокси: $(webproxy_summary)." || warn "WEB-прокси не обнаружен после установщика."
    state_set webproxy last_run "$(date '+%F %T')"
}

webproxy_status() {
    hdr "WEB-прокси — состояние"
    if ! webproxy_installed; then say "  Не установлен."; return 0; fi
    local s
    for s in caddy tproxy-server mtproxy tgwp-clients.socket mtproto-bot; do
        systemctl cat "$s" >/dev/null 2>&1 && printf '  %s %s\n' "$(pad "$s" 22)" "$(systemctl is-active "$s" 2>/dev/null)"
    done
    [ -x /usr/local/sbin/tgwp-clients ] && { say "  Клиенты:"; /usr/local/sbin/tgwp-clients list 2>/dev/null | sed 's/^/    /' | head -20; }
}

# ===== modules/kaskad.sh =====
# shellcheck shell=bash
# Yagaza Kit — Каскад: переброс входящих портов этого сервера на другой сервер
# (например, РФ-VPS → зарубежная нода). nftables: DNAT на внешнем интерфейсе +
# masquerade только для перенаправленных соединений. Своя таблица ip ykit_kaskad,
# правила Docker/Xray не трогаются. Docker (политика DROP в FORWARD) учтён через DOCKER-USER.
#
# Важно: DNAT перехватывает порт ДО локальных программ. Если на порту что-то слушает
# (Xray, nginx…), его внешний трафик уйдёт на цель — поэтому такие порты не берём без спроса.

KASKAD_RULES="$YI_ETC/kaskad.rules"            # строки: proto lport host tport
KASKAD_APPLY="$YI_ETC/kaskad-apply.sh"
KASKAD_UNIT="/etc/systemd/system/ykit-kaskad.service"
KASKAD_SYSCTL="/etc/sysctl.d/99-ykit-kaskad.conf"
KASKAD_TABLE="ykit_kaskad"

kaskad_title() { printf 'Каскад (переброс)'; }
kaskad_installed() { [ -s "$KASKAD_RULES" ]; }
kaskad_count() { local c; c=$(grep -cvE '^\s*(#|$)' "$KASKAD_RULES" 2>/dev/null); printf '%s' "${c:-0}"; }
kaskad_active() { nft list table ip "$KASKAD_TABLE" >/dev/null 2>&1; }

kaskad_summary() {
    if ! kaskad_installed; then printf 'не настроен'; return; fi
    if kaskad_active; then printf 'работает, правил %s' "$(kaskad_count)"; else printf 'правила есть, остановлен'; fi
}

kaskad_check() {
    command -v nft >/dev/null 2>&1 || { printf 'готов (поставлю nftables)'; return 0; }
    printf 'готов'
}

kaskad_wan() { ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1; }

# Адрес цели → IPv4 (домен резолвится при каждом применении правил).
kaskad_resolve() {
    if [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then printf '%s' "$1"; return 0; fi
    getent ahostsv4 "$1" 2>/dev/null | awk 'NR == 1 { print $1 }' | grep .
}

# Собрать скрипт применения из файла правил. Код 1 — цель не резолвится.
kaskad_render() {
    local wan proto lport host tport ip p bad=0
    wan=$(kaskad_wan); [ -n "$wan" ] || { err "Не определил внешний интерфейс."; return 1; }
    {
        echo '#!/bin/sh'
        echo "# Yagaza Kit: каскад. Сгенерировано из $KASKAD_RULES — правьте через меню, не руками."
        echo "nft -f - <<'NFT'"
        echo "table ip $KASKAD_TABLE"
        echo "delete table ip $KASKAD_TABLE"
        echo "table ip $KASKAD_TABLE {"
        echo "    chain prerouting {"
        echo "        type nat hook prerouting priority dstnat; policy accept;"
        while read -r proto lport host tport; do
            [[ -z "$proto" || "$proto" == \#* ]] && continue
            ip=$(kaskad_resolve "$host") || { bad=1; continue; }
            for p in $( [ "$proto" = both ] && echo tcp udp || echo "$proto" ); do
                echo "        iifname \"$wan\" $p dport $lport dnat to $ip:$tport"
            done
        done <"$KASKAD_RULES"
        echo "    }"
        echo "    chain postrouting {"
        echo "        type nat hook postrouting priority srcnat; policy accept;"
        echo "        ct status dnat oifname \"$wan\" masquerade"
        echo "    }"
        echo "    chain forward {"
        echo "        type filter hook forward priority filter; policy accept;"
        echo "        ct status dnat accept"
        echo "    }"
        echo "}"
        echo "NFT"
        echo "# Docker: политика DROP в iptables FORWARD — пропустить перенаправленное."
        echo "if iptables -nL DOCKER-USER >/dev/null 2>&1; then"
        echo "    iptables -C DOCKER-USER -m conntrack --ctstate DNAT -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER -m conntrack --ctstate DNAT -j ACCEPT"
        echo "fi"
    } >"$KASKAD_APPLY.new"
    chmod 700 "$KASKAD_APPLY.new"
    [ "$bad" -eq 0 ] || warn "Часть целей не резолвится — их правила пропущены."
    return 0
}

kaskad_down_cmds() {
    nft delete table ip "$KASKAD_TABLE" 2>/dev/null
    iptables -D DOCKER-USER -m conntrack --ctstate DNAT -j ACCEPT 2>/dev/null
    return 0
}

kaskad_write_unit() {
    cat >"$KASKAD_UNIT" <<EOF
[Unit]
Description=Yagaza Kit: каскад (переброс портов, таблица ip $KASKAD_TABLE)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh $KASKAD_APPLY
ExecStop=$(command -v nft) delete table ip $KASKAD_TABLE

[Install]
WantedBy=multi-user.target
EOF
}

# Применить правила; без правил — снять таблицу.
kaskad_apply() {
    if [ "$(kaskad_count)" -eq 0 ]; then
        run systemctl disable --now ykit-kaskad.service 2>/dev/null || true
        kaskad_down_cmds; ok "Правил нет — каскад снят."; return 0
    fi
    kaskad_render || return 1
    # Проверка синтаксиса nft без применения: вытащить блок из скрипта.
    if ! sed -n "/^nft -f - <<'NFT'$/,/^NFT$/p" "$KASKAD_APPLY.new" | sed '1d;$d' | nft -c -f - 2>>"$YI_LOG"; then
        err "nft -c: правила с ошибкой, ничего не применено (файл $KASKAD_APPLY.new)."; return 1
    fi
    mv -f "$KASKAD_APPLY.new" "$KASKAD_APPLY"
    printf 'net.ipv4.ip_forward = 1\n' >"$KASKAD_SYSCTL"; run sysctl -p "$KASKAD_SYSCTL"
    run /bin/sh "$KASKAD_APPLY" || { err "Правила не применились, см. $YI_LOG"; return 1; }
    kaskad_write_unit; run systemctl daemon-reload; run systemctl enable ykit-kaskad.service
    ok "Каскад применён: правил $(kaskad_count), переживёт перезагрузку."
}

kaskad_list() {
    local n=0 proto lport host tport ip
    hdr "Правила каскада (внешний интерфейс: $(kaskad_wan))"
    [ -s "$KASKAD_RULES" ] || { say "  Пока нет."; return 0; }
    while read -r proto lport host tport; do
        [[ -z "$proto" || "$proto" == \#* ]] && continue
        n=$((n + 1)); ip=$(kaskad_resolve "$host") || ip="не резолвится"
        printf '  %s %s/%s  →  %s:%s%s\n' "$(pad "$n." 4)" "$lport" "$proto" "$host" "$tport" \
            "$( [ "$host" != "$ip" ] && printf '  %s(%s)%s' "$C_D" "$ip" "$C_0")"
    done <"$KASKAD_RULES"
}

kaskad_add() {
    local proto lport host tport ip owner
    ask_val proto "Протокол: tcp, udp или both" "tcp"
    case "$proto" in tcp|udp|both) ;; *) err "Только tcp, udp или both."; return 0 ;; esac
    ask_val lport "Входящий порт на ЭТОМ сервере" ""
    [[ "$lport" =~ ^[0-9]+$ ]] && [ "$lport" -ge 1 ] && [ "$lport" -le 65535 ] || { err "Порт — число 1–65535."; return 0; }
    if [[ " $(base_ssh_ports 2>/dev/null) " == *" $lport "* ]]; then err "Порт $lport — это SSH. Перехватывать его нельзя."; return 0; fi
    if grep -qE "^(tcp|udp|both) $lport " "$KASKAD_RULES" 2>/dev/null; then err "Порт $lport уже перебрасывается."; return 0; fi
    for p in $( [ "$proto" = both ] && echo tcp udp || echo "$proto" ); do
        owner=$(port_owner "$p" "$lport")
        if [ -n "$owner" ]; then
            warn "$lport/$p слушает $owner: после переброса его ВНЕШНИЙ трафик уйдёт на цель."
            ask_yn "Всё равно перебрасывать $lport/$p?" n || return 0
        fi
    done
    ask_val host "Куда: IP или домен целевого сервера" ""
    [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || { err "Нужен IP или домен."; return 0; }
    ip=$(kaskad_resolve "$host") || { err "$host не резолвится в IPv4."; return 0; }
    [ "$ip" = "$(server_ip)" ] && { err "Цель — этот же сервер."; return 0; }
    ask_val tport "Порт на целевом сервере" "$lport"
    [[ "$tport" =~ ^[0-9]+$ ]] && [ "$tport" -ge 1 ] && [ "$tport" -le 65535 ] || { err "Порт — число 1–65535."; return 0; }

    if [ "$proto" != udp ]; then
        if timeout 5 bash -c "</dev/tcp/$ip/$tport" 2>/dev/null; then ok "$ip:$tport/tcp отвечает."
        else warn "$ip:$tport/tcp не отвечает с этого сервера (выключен, закрыт файрволом или фильтр по пути)."
             ask_yn "Добавить правило всё равно?" n || return 0; fi
    fi
    ask_yn "Перебрасывать $lport/$proto → $host:$tport?" y || return 0
    mkdir -p "$YI_ETC"; [ -f "$KASKAD_RULES" ] && backup_file "$KASKAD_RULES"
    printf '%s %s %s %s\n' "$proto" "$lport" "$host" "$tport" >>"$KASKAD_RULES"; chmod 600 "$KASKAD_RULES"
    kaskad_apply
}

kaskad_del() {
    local n
    kaskad_list; [ -s "$KASKAD_RULES" ] || return 0
    ask_val n "Номер правила для удаления" ""
    kaskad_rule_remove "$n" && ok "Правило $n удалено."
    return 0
}

# ---------- без вопросов (для бота) ----------

# kaskad_rule_new <proto> <lport> <host> <tport> — строгие проверки, занятый
# локальной программой порт НЕ берём (в меню это можно подтвердить вручную).
kaskad_rule_new() {
    local proto="$1" lport="$2" host="$3" tport="$4" ip p
    case "$proto" in tcp|udp|both) ;; *) err "Протокол: tcp, udp или both."; return 1 ;; esac
    [[ "$lport" =~ ^[0-9]+$ ]] && [ "$lport" -ge 1 ] && [ "$lport" -le 65535 ] || { err "Входящий порт — число 1–65535."; return 1; }
    [[ "$tport" =~ ^[0-9]+$ ]] && [ "$tport" -ge 1 ] && [ "$tport" -le 65535 ] || { err "Порт цели — число 1–65535."; return 1; }
    [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || { err "Нужен IP или домен."; return 1; }
    [[ " $(base_ssh_ports 2>/dev/null) " == *" $lport "* ]] && { err "Порт $lport — это SSH."; return 1; }
    grep -qE "^(tcp|udp|both) $lport " "$KASKAD_RULES" 2>/dev/null && { err "Порт $lport уже перебрасывается."; return 1; }
    for p in $( [ "$proto" = both ] && echo tcp udp || echo "$proto" ); do
        [ -z "$(port_owner "$p" "$lport")" ] || { err "$lport/$p занят: $(port_owner "$p" "$lport"). Такой переброс — только из меню сервера."; return 1; }
    done
    ip=$(kaskad_resolve "$host") || { err "$host не резолвится в IPv4."; return 1; }
    [ "$ip" = "$(server_ip)" ] && { err "Цель — этот же сервер."; return 1; }
    command -v nft >/dev/null 2>&1 || apt_install nftables >/dev/null || { err "Нет nftables."; return 1; }
    mkdir -p "$YI_ETC"; [ -f "$KASKAD_RULES" ] && backup_file "$KASKAD_RULES"
    printf '%s %s %s %s\n' "$proto" "$lport" "$host" "$tport" >>"$KASKAD_RULES"; chmod 600 "$KASKAD_RULES"
    kaskad_apply >/dev/null || { sed -i "/^$proto $lport $host $tport\$/d" "$KASKAD_RULES"; kaskad_apply >/dev/null; return 1; }
    if [ "$proto" != udp ] && ! timeout 5 bash -c "</dev/tcp/$ip/$tport" 2>/dev/null; then
        echo "warn: $ip:$tport/tcp сейчас не отвечает с этого сервера"
    fi
    return 0
}

kaskad_rule_remove() {   # kaskad_rule_remove <номер>
    local n="$1" tmp
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$(kaskad_count)" ] || { err "Нет правила номер $n."; return 1; }
    backup_file "$KASKAD_RULES"
    tmp=$(mktemp) || return 1
    awk -v n="$n" '/^[[:space:]]*(#|$)/ { print; next } { if (++i != n) print }' "$KASKAD_RULES" >"$tmp"
    cat "$tmp" >"$KASKAD_RULES"; rm -f "$tmp"
    kaskad_apply >/dev/null
}

# Строки «номер|proto|lport|host|tport» для бота.
kaskad_rules_lines() {
    [ -s "$KASKAD_RULES" ] || return 0
    awk '/^[[:space:]]*(#|$)/ { next } { printf "%d|%s|%s|%s|%s\n", ++i, $1, $2, $3, $4 }' "$KASKAD_RULES"
}

kaskad_install() {
    local a
    command -v nft >/dev/null 2>&1 || apt_install nftables || { err "Нет nftables."; return 0; }
    while :; do
        kaskad_list
        printf '\n  1  Добавить переброс\n  2  Удалить переброс\n  3  Применить заново (после смены IP домена)\n  0  Назад\n'
        tty_read a " Выбор: "
        case "$a" in
            1) kaskad_add ;;
            2) kaskad_del ;;
            3) kaskad_apply ;;
            0|q|"") return 0 ;;
            *) warn "Нет такого пункта." ;;
        esac
    done
}

kaskad_status() {
    kaskad_list
    printf '\n  Таблица nft : %s\n' "$(kaskad_active && echo "ip $KASKAD_TABLE — активна" || echo "нет")"
    printf '  Служба      : ykit-kaskad (%s)\n' "$(systemctl is-enabled ykit-kaskad.service 2>/dev/null || echo 'нет')"
    printf '  ip_forward  : %s\n' "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
}

kaskad_remove() {
    kaskad_installed || kaskad_active || { ok "Каскад не настроен."; return 0; }
    ask_yn "Снять все перебросы и удалить правила каскада?" n || return 0
    run systemctl disable --now ykit-kaskad.service 2>/dev/null || true
    kaskad_down_cmds
    [ -f "$KASKAD_RULES" ] && backup_file "$KASKAD_RULES"
    rm -f "$KASKAD_RULES" "$KASKAD_APPLY" "$KASKAD_UNIT" "$KASKAD_SYSCTL"; run systemctl daemon-reload
    ok "Каскад снят (копия правил — в $YI_BACKUP). ip_forward вернётся к системному после перезагрузки."
}

# ===== modules/mtproxy.sh =====
# shellcheck shell=bash
# Yagaza Kit — MTProxy для Telegram на mtg v2 (https://github.com/9seconds/mtg, лицензия MIT).
# Ставится официальный релиз mtg с проверкой sha256 по файлу сумм релиза,
# режим FakeTLS (секрет «ee…» с доменом маскировки), служба systemd от отдельного
# пользователя, порт и ссылки — из `mtg access`.

MTG_VERSION="${MTG_VERSION:-2.3.0}"
MTG_BIN="/usr/local/bin/mtg"
MTG_DIR="/etc/mtg"
MTG_CONF="$MTG_DIR/mtg.toml"
MTG_USER="mtg"
MTG_UNIT="ykit-mtg"
MTG_UNIT_FILE="/etc/systemd/system/$MTG_UNIT.service"

mtproxy_title() { printf 'MTProxy (mtg)'; }

mtproxy_installed() { [ -x "$MTG_BIN" ] && [ -f "$MTG_CONF" ]; }
mtproxy_port() { sed -n -E 's/^bind-to *= *"[^"]*:([0-9]+)".*/\1/p' "$MTG_CONF" 2>/dev/null | head -1; }

mtproxy_summary() {
    if ! mtproxy_installed; then printf 'не установлен'; return; fi
    if systemctl is-active --quiet "$MTG_UNIT" 2>/dev/null; then printf 'работает, порт %s' "$(mtproxy_port)"
    else printf 'установлен, остановлен'; fi
}

mtproxy_check() {
    local o
    if mtproxy_installed; then printf 'установлен'; return 0; fi
    o=$(port_owner tcp 443)
    if [ -n "$o" ]; then printf 'готов (443 занят: %s — возьмём другой)' "$o"; else printf 'готов'; fi
}

mtproxy_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'amd64' ;;
        aarch64|arm64) printf 'arm64' ;;
        *) return 1 ;;
    esac
}

# Скачать релиз mtg, сверить sha256 по файлу сумм релиза, поставить в $MTG_BIN.
mtproxy_fetch() {
    local arch name base tmp sum
    arch=$(mtproxy_arch) || { err "Архитектура $(uname -m) не поддерживается модулем."; return 1; }
    name="mtg-$MTG_VERSION-linux-$arch"
    base="https://github.com/9seconds/mtg/releases/download/v$MTG_VERSION"
    tmp=$(mktemp -d) || return 1
    say "Скачиваю mtg $MTG_VERSION ($arch) с GitHub…"
    if ! curl -fsSL --max-time 120 -o "$tmp/$name.tar.gz" "$base/$name.tar.gz" ||
       ! curl -fsSL --max-time 60 -o "$tmp/sums.txt" "$base/mtg-$MTG_VERSION-checksums.txt"; then
        err "Не удалось скачать mtg."; rm -rf "$tmp"; return 1
    fi
    sum=$(awk -v n="$name.tar.gz" '$2 == n { print $1 }' "$tmp/sums.txt")
    if [ -z "$sum" ] || [ "$(sha256sum "$tmp/$name.tar.gz" | cut -d' ' -f1)" != "$sum" ]; then
        err "Контрольная сумма mtg не совпала — не ставлю."; rm -rf "$tmp"; return 1
    fi
    tar -xzf "$tmp/$name.tar.gz" -C "$tmp" "$name/mtg" || { err "Архив mtg повреждён."; rm -rf "$tmp"; return 1; }
    install -m 755 -o root -g root "$tmp/$name/mtg" "$MTG_BIN"
    rm -rf "$tmp"
    log "mtg $MTG_VERSION установлен, sha256 архива $sum"
    ok "mtg $MTG_VERSION установлен ($MTG_BIN), sha256 сверен."
}

mtproxy_write_unit() {
    cat >"$MTG_UNIT_FILE" <<EOF
[Unit]
Description=Yagaza Kit: MTProxy (mtg)
Documentation=https://github.com/9seconds/mtg
After=network-online.target
Wants=network-online.target

[Service]
User=$MTG_USER
Group=$MTG_USER
ExecStart=$MTG_BIN run $MTG_CONF
Restart=always
RestartSec=3
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
}

mtproxy_links() {
    local out
    out=$("$MTG_BIN" access "$MTG_CONF" 2>/dev/null) || return 1
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$out" | jq -r '.ipv4.tg_url // empty, .ipv4.tme_url // empty'
    else
        printf '%s' "$out" | sed -n -E 's/.*"(tg_url|tme_url)": *"([^"]+)".*/\2/p' | head -2
    fi
}

mtproxy_install() {
    local port def domain secret ip owner
    hdr "MTProxy (mtg $MTG_VERSION)"
    if mtproxy_installed; then
        warn "Уже установлен: $(mtproxy_summary)."
        ask_yn "Переустановить (новый секрет — старые ссылки перестанут работать)?" n || { mtproxy_status; return 0; }
    fi

    # Порт: 443 выглядит естественнее всего для FakeTLS, но на нодах его держит Xray.
    def=443
    owner=$(port_owner tcp 443)
    if [ -n "$owner" ] && ! { mtproxy_installed && [ "$(mtproxy_port)" = 443 ]; }; then
        warn "443/tcp занят: $owner. Предлагаю 8443 (или любой свободный)."
        def=8443
    fi
    ask_val port "Порт MTProxy" "$def"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { err "Порт — число 1–65535."; return 0; }
    owner=$(port_owner tcp "$port")
    if [ -n "$owner" ] && ! { mtproxy_installed && [ "$(mtproxy_port)" = "$port" ]; }; then
        err "Порт $port/tcp занят: $owner"; return 0
    fi

    say "Домен маскировки (FakeTLS): трафик выглядит как HTTPS к этому сайту."
    say "Лучше всего — ваш домен, указывающий на этот сервер; иначе — крупный сайт с TLS 1.3."
    ask_val domain "Домен" ""
    [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$ ]] || { err "Нужен домен вида example.com."; return 0; }

    ask_yn "Ставлю mtg на $port/tcp с маскировкой под $domain. Продолжить?" y || return 0

    mtproxy_fetch || return 0
    secret=$("$MTG_BIN" generate-secret --hex "$domain" 2>>"$YI_LOG") || { err "mtg не сгенерировал секрет."; return 0; }
    [[ "$secret" =~ ^ee[0-9a-f]+$ ]] || { err "Странный секрет от mtg: не начинается с ee."; return 0; }

    id "$MTG_USER" >/dev/null 2>&1 || run useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$MTG_USER"
    mkdir -p "$MTG_DIR"
    [ -f "$MTG_CONF" ] && backup_file "$MTG_CONF"
    ip=$(server_ip)
    {
        echo "# ykit: MTProxy (mtg $MTG_VERSION). Пример всех настроек: mtg-$MTG_VERSION/example.config.toml"
        echo "secret = \"$secret\""
        echo "bind-to = \"0.0.0.0:$port\""
        # Без public-ipv4 `mtg access` сам спрашивает свой IP у ifconfig.co.
        [ -n "$ip" ] && echo "public-ipv4 = \"$ip\""
    } >"$MTG_CONF"
    chown root:"$MTG_USER" "$MTG_DIR" "$MTG_CONF"
    chmod 750 "$MTG_DIR"; chmod 640 "$MTG_CONF"

    mtproxy_write_unit
    run systemctl daemon-reload
    run systemctl enable "$MTG_UNIT"
    run systemctl restart "$MTG_UNIT"
    sleep 2
    if ! systemctl is-active --quiet "$MTG_UNIT"; then
        err "Служба $MTG_UNIT не запустилась. Смотрите: journalctl -u $MTG_UNIT -n 50"; return 0
    fi
    declare -F base_fw_on >/dev/null && base_fw_on && base_fw_allow tcp "$port"
    state_set mtproxy version "$MTG_VERSION"; state_set mtproxy port "$port"; state_set mtproxy domain "$domain"
    ok "MTProxy работает на $port/tcp."
    mtproxy_status
}

mtproxy_status() {
    hdr "MTProxy — состояние"
    if ! mtproxy_installed; then say "  Не установлен."; return 0; fi
    printf '  Версия mtg : %s\n' "$(state_get mtproxy version 2>/dev/null || echo '?')"
    printf '  Служба     : %s (%s)\n' "$MTG_UNIT" "$(systemctl is-active "$MTG_UNIT" 2>/dev/null)"
    printf '  Порт       : %s/tcp\n' "$(mtproxy_port)"
    printf '  Домен      : %s\n' "$(state_get mtproxy domain 2>/dev/null || echo '?')"
    printf '  Конфиг     : %s\n' "$MTG_CONF"
    say "  Ссылки для Telegram (это и есть пароль — не публикуйте):"
    mtproxy_links | sed 's/^/    /' || warn "mtg access не ответил."
}

mtproxy_remove() {
    mtproxy_installed || [ -f "$MTG_UNIT_FILE" ] || { ok "MTProxy не установлен."; return 0; }
    ask_yn "Удалить MTProxy (службу, mtg и конфиг)?" n || return 0
    run systemctl disable --now "$MTG_UNIT" || true
    rm -f "$MTG_UNIT_FILE"; run systemctl daemon-reload
    [ -f "$MTG_CONF" ] && backup_file "$MTG_CONF"
    rm -rf "$MTG_DIR" "$MTG_BIN"
    id "$MTG_USER" >/dev/null 2>&1 && run userdel "$MTG_USER"
    state_del mtproxy version; state_del mtproxy port; state_del mtproxy domain
    ok "MTProxy удалён (копия конфига — в $YI_BACKUP). Порт в файрволе Yagaza Kit закройте вручную, если открывали."
}

# ===== modules/vless.sh =====
# shellcheck shell=bash
# Yagaza Kit — свой VLESS + REALITY (xtls-rprx-vision) на Xray-core
# (https://github.com/XTLS/Xray-core, MPL-2.0). Без панелей: свой Xray в /opt/ykit-xray,
# служба ykit-xray, клиенты со ссылкой vless:// и QR-кодом. Чужой Xray (Remnawave,
# 3x-ui) не трогается: другой путь, другое имя службы.
#
# Источники: релизы GitHub (Xray-linux-64.zip + .dgst с SHA2-256), исходник
# main/commands/all/curve25519.go (вывод `xray x25519`). Конфиг перед запуском
# проверяется самим xray: `xray run -test -c`.

XRAY_VERSION="${XRAY_VERSION:-26.11.9}"
XRAY_DIR="/opt/ykit-xray"
XRAY_BIN="$XRAY_DIR/xray"
XRAY_CONF_DIR="$YI_ETC/xray"
XRAY_CONF="$XRAY_CONF_DIR/config.json"
XRAY_CLIENTS="$XRAY_CONF_DIR/clients"          # строки: имя uuid
XRAY_USER="ykit-xray"
XRAY_UNIT="ykit-xray"
XRAY_UNIT_FILE="/etc/systemd/system/$XRAY_UNIT.service"

vless_title() { printf 'VLESS Reality'; }
vless_installed() { [ -x "$XRAY_BIN" ] && [ -f "$XRAY_CONF" ]; }
vless_nclients() { grep -c . "$XRAY_CLIENTS" 2>/dev/null || true; }

vless_summary() {
    if ! vless_installed; then printf 'не установлен'; return; fi
    if systemctl is-active --quiet "$XRAY_UNIT" 2>/dev/null; then
        printf 'работает, %s/tcp, клиентов %s' "$(state_get vless port)" "$(vless_nclients)"
    else printf 'установлен, остановлен'; fi
}

vless_check() {
    local o
    if vless_installed; then printf 'установлен'; return 0; fi
    o=$(port_owner tcp 443)
    if [ -n "$o" ]; then printf 'готов (443 занят: %s — возьмём другой)' "$o"; else printf 'готов'; fi
}

vless_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf '64' ;;
        aarch64|arm64) printf 'arm64-v8a' ;;
        *) return 1 ;;
    esac
}

vless_fetch() {
    local arch name base tmp want got
    arch=$(vless_arch) || { err "Архитектура $(uname -m) не поддерживается модулем."; return 1; }
    name="Xray-linux-$arch.zip"
    base="https://github.com/XTLS/Xray-core/releases/download/v$XRAY_VERSION"
    apt_install unzip || return 1
    tmp=$(mktemp -d) || return 1
    say "Скачиваю Xray $XRAY_VERSION ($arch) с GitHub…"
    if ! curl -fsSL --max-time 180 -o "$tmp/$name" "$base/$name" ||
       ! curl -fsSL --max-time 60 -o "$tmp/$name.dgst" "$base/$name.dgst"; then
        err "Не удалось скачать Xray."; rm -rf "$tmp"; return 1
    fi
    want=$(sed -n 's/^SHA2-256= *//p' "$tmp/$name.dgst" | tr -d '[:space:]')
    got=$(sha256sum "$tmp/$name" | cut -d' ' -f1)
    if [ -z "$want" ] || [ "$want" != "$got" ]; then err "Контрольная сумма Xray не совпала — не ставлю."; rm -rf "$tmp"; return 1; fi
    mkdir -p "$XRAY_DIR"
    unzip -qo "$tmp/$name" xray geoip.dat geosite.dat -d "$XRAY_DIR" || { err "Архив Xray повреждён."; rm -rf "$tmp"; return 1; }
    chown -R root:root "$XRAY_DIR"; chmod 755 "$XRAY_DIR" "$XRAY_BIN"; chmod 644 "$XRAY_DIR"/*.dat
    rm -rf "$tmp"
    log "Xray $XRAY_VERSION установлен в $XRAY_DIR, sha256 $got"
    ok "Xray $XRAY_VERSION установлен ($XRAY_DIR), sha256 сверен."
}

# Ключи Reality: вывод `xray x25519` — «PrivateKey: …» и «Password (PublicKey): …»
# (в старых версиях «Private key: …» / «Public key: …»).
vless_keys() {
    local out
    out=$("$XRAY_BIN" x25519 2>/dev/null) || return 1
    VLESS_PRIV=$(printf '%s\n' "$out" | sed -n -E 's/^Private ?[Kk]ey: *//p' | head -1)
    VLESS_PUB=$(printf '%s\n' "$out" | sed -n -E 's/^(Password \(PublicKey\)|Public ?[Kk]ey): *//p' | head -1)
    [ -n "$VLESS_PRIV" ] && [ -n "$VLESS_PUB" ]
}

vless_render() {   # собрать config.json из состояния и списка клиентов
    local port sni priv sid warp clients="" name uuid first=1 out
    port=$(state_get vless port); sni=$(state_get vless sni); priv=$(state_get vless priv)
    sid=$(state_get vless sid); warp=$(state_get vless warp_port 2>/dev/null || true)
    while read -r name uuid; do
        [ -n "$uuid" ] || continue
        [ "$first" -eq 1 ] || clients+=","
        clients+=$(printf '\n          { "id": "%s", "flow": "xtls-rprx-vision", "email": "%s" }' "$uuid" "$name")
        first=0
    done <"$XRAY_CLIENTS"
    if [ -n "$warp" ]; then
        out=$(printf '{ "tag": "warp", "protocol": "socks", "settings": { "servers": [ { "address": "127.0.0.1", "port": %s } ] } },\n    { "tag": "direct", "protocol": "freedom" }' "$warp")
    else
        out='{ "tag": "direct", "protocol": "freedom" }'
    fi
    cat <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [$clients
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$sni:443",
          "xver": 0,
          "serverNames": [ "$sni" ],
          "privateKey": "$priv",
          "shortIds": [ "$sid" ]
        }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ] }
    }
  ],
  "outbounds": [
    $out,
    { "tag": "block", "protocol": "blackhole" }
  ]
}
EOF
}

# Записать конфиг, проверить самим xray, перезапустить службу.
vless_apply() {
    local tmp
    tmp=$(mktemp "$XRAY_CONF_DIR/.cfg.XXXXXX") || return 1
    vless_render >"$tmp"
    if ! "$XRAY_BIN" run -test -c "$tmp" >>"$YI_LOG" 2>&1; then
        err "xray -test: конфиг с ошибкой, не применяю (файл $tmp, подробности в $YI_LOG)."; return 1
    fi
    [ -f "$XRAY_CONF" ] && backup_file "$XRAY_CONF"
    mv -f "$tmp" "$XRAY_CONF"
    chown root:"$XRAY_USER" "$XRAY_CONF"; chmod 640 "$XRAY_CONF"
    run systemctl restart "$XRAY_UNIT" && sleep 1 && systemctl is-active --quiet "$XRAY_UNIT" ||
        { err "Служба $XRAY_UNIT не запустилась: journalctl -u $XRAY_UNIT -n 50"; return 1; }
}

vless_write_unit() {
    cat >"$XRAY_UNIT_FILE" <<EOF
[Unit]
Description=Yagaza Kit: VLESS Reality (Xray $XRAY_VERSION)
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target
Wants=network-online.target

[Service]
User=$XRAY_USER
Group=$XRAY_USER
Environment=XRAY_LOCATION_ASSET=$XRAY_DIR
ExecStart=$XRAY_BIN run -c $XRAY_CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
}

vless_link() {   # vless_link <имя>
    local name="$1" uuid port sni pub sid ip
    uuid=$(awk -v n="$name" '$1 == n { print $2 }' "$XRAY_CLIENTS")
    [ -n "$uuid" ] || return 1
    port=$(state_get vless port); sni=$(state_get vless sni); pub=$(state_get vless pub); sid=$(state_get vless sid)
    ip=$(server_ip)
    printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' \
        "$uuid" "$ip" "$port" "$sni" "$pub" "$sid" "$name"
}

vless_client_show() {
    local l
    l=$(vless_link "$1") || { err "Нет клиента $1."; return 0; }
    hdr "Клиент $1 — импорт в Happ, v2rayN, Hiddify, Streisand (это ключ доступа, не публикуйте)"
    command -v qrencode >/dev/null && qrencode -t ansiutf8 "$l"
    printf '%s\n' "$l"
}

# Без вопросов (для меню и бота): добавить клиента и применить. Код 0 — добавлен.
vless_client_new() {
    local name="$1" uuid
    [[ "$name" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || { err "Имя: латиница, цифры, - _, до 32 символов."; return 1; }
    awk -v n="$name" '$1 == n { f = 1 } END { exit !f }' "$XRAY_CLIENTS" 2>/dev/null && { err "Клиент $name уже есть."; return 1; }
    uuid=$("$XRAY_BIN" uuid 2>/dev/null) || uuid=$(cat /proc/sys/kernel/random/uuid)
    printf '%s %s\n' "$name" "$uuid" >>"$XRAY_CLIENTS"
    vless_apply >/dev/null || { sed -i "/^$name /d" "$XRAY_CLIENTS"; return 1; }
}

vless_client_remove() {   # без вопросов
    local name="$1"
    awk -v n="$name" '$1 == n { f = 1 } END { exit !f }' "$XRAY_CLIENTS" 2>/dev/null || { err "Нет клиента $name."; return 1; }
    [ "$(vless_nclients)" -le 1 ] && { err "Это последний клиент — Xray без клиентов не запустится."; return 1; }
    cp -a "$XRAY_CLIENTS" "$XRAY_CLIENTS.bak"
    awk -v n="$name" '$1 != n' "$XRAY_CLIENTS.bak" >"$XRAY_CLIENTS"
    if vless_apply >/dev/null; then rm -f "$XRAY_CLIENTS.bak"; else cp -a "$XRAY_CLIENTS.bak" "$XRAY_CLIENTS"; rm -f "$XRAY_CLIENTS.bak"; return 1; fi
}

vless_client_add() {
    local name
    ask_val name "Имя клиента (латиница, цифры, - _)" "user$(( $(vless_nclients) + 1 ))"
    vless_client_new "$name" && { ok "Клиент $name добавлен."; vless_client_show "$name"; }
    return 0
}

vless_client_list() {
    hdr "Клиенты VLESS"
    [ -s "$XRAY_CLIENTS" ] || { say "  Пока нет."; return 0; }
    awk '{ printf "  %s\n", $1 }' "$XRAY_CLIENTS"
}

vless_client_del() {
    local name
    vless_client_list
    ask_val name "Кого удалить" ""
    awk -v n="$name" '$1 == n { f = 1 } END { exit !f }' "$XRAY_CLIENTS" 2>/dev/null || { err "Нет клиента $name."; return 0; }
    ask_yn "Удалить $name? Его ссылка перестанет работать." n || return 0
    vless_client_remove "$name" && ok "Клиент $name удалён."
    return 0
}

# Сайт для маскировки должен отвечать по TLS 1.3 (и желательно h2) с этого сервера.
vless_sni_ok() {
    curl -sS -o /dev/null --max-time 10 --tlsv1.3 --http2 "https://$1/" 2>>"$YI_LOG"
}

vless_install() {
    local a port def owner sni sid wp
    if vless_installed; then
        while :; do
            hdr "VLESS Reality — $(vless_summary)"
            printf '  1  Добавить клиента\n  2  Список клиентов\n  3  Показать ссылку и QR\n  4  Удалить клиента\n  0  Назад\n'
            tty_read a " Выбор: "
            case "$a" in
                1) vless_client_add ;;
                2) vless_client_list ;;
                3) vless_client_list; tty_read a "Имя клиента: "; vless_client_show "$a" ;;
                4) vless_client_del ;;
                0|q|"") return 0 ;;
                *) warn "Нет такого пункта." ;;
            esac
        done
    fi

    hdr "VLESS + REALITY (Xray $XRAY_VERSION)"
    say "Будет: свой Xray в $XRAY_DIR (служба $XRAY_UNIT), VLESS + REALITY + xtls-rprx-vision."
    say "Другой Xray на сервере (Remnawave, 3x-ui) не трогается, но порт должен быть свободен."

    def=443; owner=$(port_owner tcp 443)
    [ -n "$owner" ] && { warn "443/tcp занят: $owner. Предлагаю 8443."; def=8443; }
    ask_val port "Порт VLESS" "$def"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { err "Порт — число 1–65535."; return 0; }
    owner=$(port_owner tcp "$port"); [ -z "$owner" ] || { err "Порт $port/tcp занят: $owner"; return 0; }

    say "Сайт для маскировки (REALITY выдаёт себя за него): зарубежный, с TLS 1.3 и HTTP/2, не за Cloudflare."
    ask_val sni "Домен сайта" "www.microsoft.com"
    [[ "$sni" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$ ]] || { err "Нужен домен вида www.example.com."; return 0; }
    if vless_sni_ok "$sni"; then ok "$sni отвечает по TLS 1.3 + HTTP/2."
    else warn "$sni не ответил по TLS 1.3 + HTTP/2 с этого сервера — маскировка может не работать."
         ask_yn "Всё равно использовать $sni?" n || return 0; fi

    ask_yn "Ставлю VLESS на $port/tcp с маскировкой под $sni. Продолжить?" y || return 0
    vless_fetch || return 0
    vless_keys || { err "xray x25519 не выдал ключи."; return 0; }
    sid=$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')

    mkdir -p "$XRAY_CONF_DIR"; chmod 750 "$XRAY_CONF_DIR"
    id "$XRAY_USER" >/dev/null 2>&1 || run useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$XRAY_USER"
    chown root:"$XRAY_USER" "$XRAY_CONF_DIR"
    state_set vless port "$port"; state_set vless sni "$sni"; state_set vless sid "$sid"
    state_set vless priv "$VLESS_PRIV"; state_set vless pub "$VLESS_PUB"; state_set vless version "$XRAY_VERSION"

    if declare -F warp_ok >/dev/null && warp_ok 2>/dev/null; then
        if ask_yn "WARP работает (SOCKS5 :$(warp_port)). Выпускать трафик клиентов через WARP?" n; then
            wp=$(warp_port); state_set vless warp_port "$wp"
        fi
    fi

    : >"$XRAY_CLIENTS"; chmod 600 "$XRAY_CLIENTS"
    printf 'user1 %s\n' "$("$XRAY_BIN" uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)" >>"$XRAY_CLIENTS"
    vless_write_unit; run systemctl daemon-reload; run systemctl enable "$XRAY_UNIT"
    vless_apply || return 0
    declare -F base_fw_on >/dev/null && base_fw_on && base_fw_allow tcp "$port"
    apt_install qrencode >/dev/null 2>&1 || true
    ok "VLESS Reality работает на $port/tcp."
    vless_client_show user1
}

vless_status() {
    hdr "VLESS Reality — состояние"
    if ! vless_installed; then say "  Не установлен."; return 0; fi
    printf '  Xray      : %s\n' "$("$XRAY_BIN" version 2>/dev/null | head -1)"
    printf '  Служба    : %s (%s)\n' "$XRAY_UNIT" "$(systemctl is-active "$XRAY_UNIT" 2>/dev/null)"
    printf '  Порт      : %s/tcp\n' "$(state_get vless port)"
    printf '  Маскировка: %s\n' "$(state_get vless sni)"
    printf '  Выход     : %s\n' "$( [ -n "$(state_get vless warp_port 2>/dev/null)" ] && echo 'через WARP' || echo 'напрямую')"
    printf '  Клиенты   : %s\n' "$(vless_nclients)"
}

vless_remove() {
    vless_installed || [ -f "$XRAY_UNIT_FILE" ] || { ok "VLESS не установлен."; return 0; }
    ask_yn "Удалить свой VLESS (служба, Xray в $XRAY_DIR, конфиг и клиенты)?" n || return 0
    run systemctl disable --now "$XRAY_UNIT" || true
    rm -f "$XRAY_UNIT_FILE"; run systemctl daemon-reload
    mkdir -p "$YI_BACKUP" && tar -czf "$YI_BACKUP/vless.$(date +%Y%m%d-%H%M%S).tgz" -C "$YI_ETC" xray state/vless.conf 2>/dev/null
    rm -rf "$XRAY_DIR" "$XRAY_CONF_DIR"
    id "$XRAY_USER" >/dev/null 2>&1 && run userdel "$XRAY_USER"
    rm -f "$(state_file vless)"
    ok "VLESS удалён (копия конфига и клиентов — в $YI_BACKUP)."
}

# ===== modules/warp.sh =====
# shellcheck shell=bash
# Yagaza Kit — Cloudflare WARP (официальный клиент cloudflare-warp, warp-cli) в режиме
# локального прокси: SOCKS5 на 127.0.0.1:<порт>. Через него Xray/mtg/что угодно
# могут выпускать трафик с IP Cloudflare. Маршруты сервера НЕ меняются.
#
# Источники: https://pkg.cloudflareclient.com/ (ключ, строка репозитория, Jammy/Noble/
# Bookworm), https://developers.cloudflare.com/warp-client/get-started/linux/
# (registration new, connect). Команды режима прокси сверяются с `warp-cli --help`
# на сервере, итог — по https://www.cloudflare.com/cdn-cgi/trace (warp=on).
#
# ОПАСНО: в обычном режиме (warp) клиент заворачивает ВЕСЬ трафик сервера в туннель —
# можно потерять SSH. Поэтому режим proxy ставится ДО connect, а таймер через
# 2 минуты отключает WARP, если вы не подтвердили, что доступ есть.

WARP_KEYRING="/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg"
WARP_LIST="/etc/apt/sources.list.d/cloudflare-client.list"
WARP_REVERT_UNIT="ykit-warp-revert"
WARP_TRACE="https://www.cloudflare.com/cdn-cgi/trace"

warp_title() { printf 'WARP (warp-cli)'; }
warp_installed() { command -v warp-cli >/dev/null 2>&1; }
warp_port() { state_get warp port 2>/dev/null || printf '40000'; }

warp_cli() { warp-cli --accept-tos "$@"; }

# Работает ли прокси: trace через SOCKS5 должен сказать warp=on (или plus).
warp_trace() {
    curl -fsS --max-time 15 -x "socks5h://127.0.0.1:$(warp_port)" "$WARP_TRACE" 2>/dev/null
}
warp_ok() { warp_trace | grep -qE '^warp=(on|plus)$'; }

# ---------- без вопросов (для бота) ----------
# Включение — только в режиме proxy: сначала mode proxy и порт, потом connect,
# иначе WARP завернёт весь трафик сервера.
warp_on() {
    warp_installed || { err "WARP не установлен."; return 1; }
    [ -n "$(state_get warp port 2>/dev/null)" ] || { err "WARP ставился не через Yagaza Kit — включите из меню сервера."; return 1; }
    warp_cli mode proxy >>"$YI_LOG" 2>&1 || { err "warp-cli mode proxy не сработал — не включаю."; return 1; }
    warp_cli proxy port "$(warp_port)" >>"$YI_LOG" 2>&1 || { err "warp-cli proxy port не сработал — не включаю."; return 1; }
    warp_cli connect >>"$YI_LOG" 2>&1 || { err "warp-cli connect не сработал."; return 1; }
    for _ in 1 2 3 4 5 6 7 8 9 10; do warp_ok && return 0; sleep 2; done
    err "Подключено, но проверка не показывает warp=on."; return 1
}

warp_off() {
    warp_installed || { err "WARP не установлен."; return 1; }
    warp_cli disconnect >>"$YI_LOG" 2>&1 || { err "warp-cli disconnect не сработал."; return 1; }
}

# Для бота: on|off, IP выхода, используется ли выходом VLESS.
warp_state_line() {
    local t
    warp_installed || { echo "none"; return 0; }
    t=$(warp_trace)
    if printf '%s' "$t" | grep -qE '^warp=(on|plus)$'; then
        printf 'on|%s|%s|%s\n' "$(printf '%s' "$t" | sed -n 's/^ip=//p')" "$(printf '%s' "$t" | sed -n 's/^colo=//p')" "$(warp_port)"
    else
        printf 'off|||%s\n' "$(warp_port)"
    fi
    [ -n "$(state_get vless warp_port 2>/dev/null)" ] && echo "vless_via_warp"
    return 0
}

warp_summary() {
    if ! warp_installed; then printf 'не установлен'; return; fi
    if warp_ok; then printf 'работает, SOCKS5 :%s' "$(warp_port)"; else printf 'установлен, не подключён'; fi
}

warp_check() {
    local o
    if warp_installed; then printf 'установлен'; return 0; fi
    case "$OS_ID:$OS_VER" in
        ubuntu:22.04|ubuntu:24.04|debian:12) ;;
        *) printf 'ОС не поддерживается репозиторием'; return 1 ;;
    esac
    [ "$(uname -m)" = x86_64 ] || [ "$(uname -m)" = aarch64 ] || { printf 'архитектура %s?' "$(uname -m)"; return 1; }
    o=$(port_owner tcp 40000)
    if [ -n "$o" ]; then printf 'готов (40000 занят: %s — возьмём другой)' "$o"; else printf 'готов'; fi
}

warp_add_repo() {
    local codename tmp
    codename=$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")
    case "$codename" in jammy|noble|bookworm) ;; *) err "Репозиторий Cloudflare не собирается для '$codename'."; return 1 ;; esac
    apt_install ca-certificates curl gnupg || return 1
    tmp=$(mktemp) || return 1
    curl -fsSL --max-time 60 https://pkg.cloudflareclient.com/pubkey.gpg -o "$tmp" ||
        { err "Не скачал ключ pkg.cloudflareclient.com."; rm -f "$tmp"; return 1; }
    gpg --yes --dearmor --output "$WARP_KEYRING" "$tmp" && chmod 644 "$WARP_KEYRING"
    rm -f "$tmp"
    printf 'deb [signed-by=%s] https://pkg.cloudflareclient.com/ %s main\n' "$WARP_KEYRING" "$codename" >"$WARP_LIST"
    run env DEBIAN_FRONTEND=noninteractive apt-get update -q || { err "apt-get update с репозиторием Cloudflare не прошёл."; return 1; }
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q cloudflare-warp || { err "Не поставился cloudflare-warp, см. $YI_LOG"; return 1; }
    warp_installed || { err "После установки нет warp-cli."; return 1; }
    run systemctl enable --now warp-svc 2>/dev/null || true
    ok "cloudflare-warp установлен."
}

warp_install() {
    local port o help
    hdr "Cloudflare WARP — локальный SOCKS5-прокси"
    if warp_installed && warp_ok; then warn "Уже работает: $(warp_summary)."; warp_status; return 0; fi

    say "Будет: репозиторий pkg.cloudflareclient.com, пакет cloudflare-warp, регистрация бесплатного"
    say "аккаунта WARP, режим proxy (SOCKS5 только на 127.0.0.1). Маршруты сервера не меняются."
    say "Условия Cloudflare: https://www.cloudflare.com/application/terms/"
    ask_yn "Принимаете условия Cloudflare WARP и продолжаете?" n || return 0

    port=40000
    o=$(port_owner tcp 40000)
    [ -n "$o" ] && { warn "40000/tcp занят: $o."; port=40001; }
    ask_val port "Порт SOCKS5 (только 127.0.0.1)" "$port"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ] || { err "Порт — число 1024–65535."; return 0; }
    [ -z "$(port_owner tcp "$port")" ] || { err "Порт $port/tcp занят: $(port_owner tcp "$port")"; return 0; }

    warp_installed || warp_add_repo || return 0

    help=$(warp-cli --help 2>&1; warp-cli mode --help 2>&1; warp-cli proxy --help 2>&1)
    if ! printf '%s' "$help" | grep -qw proxy; then
        err "Эта версия warp-cli не показывает режим proxy в --help — не включаю (иначе WARP завернёт весь трафик сервера)."
        return 0
    fi

    if ! warp_cli registration show >/dev/null 2>&1; then
        run warp_cli registration new || { err "Регистрация WARP не прошла, см. $YI_LOG"; return 0; }
    fi
    # Порядок важен: сначала режим proxy и порт, только потом connect.
    run warp_cli mode proxy        || { err "warp-cli mode proxy не сработал — не подключаю."; return 0; }
    run warp_cli proxy port "$port" || { err "warp-cli proxy port не сработал — не подключаю."; return 0; }
    state_set warp port "$port"

    run systemctl stop "$WARP_REVERT_UNIT.timer" 2>/dev/null || true
    run systemd-run --unit="$WARP_REVERT_UNIT" --on-active=120 "$(command -v warp-cli)" --accept-tos disconnect ||
        { err "Не удалось поставить таймер отката — не подключаю."; return 0; }
    run warp_cli connect || { err "warp-cli connect не сработал."; run systemctl stop "$WARP_REVERT_UNIT.timer"; return 0; }

    say "Подключаюсь, проверяю через $WARP_TRACE …"
    for _ in 1 2 3 4 5 6 7 8 9 10; do warp_ok && break; sleep 2; done
    warn "Проверьте в НОВОМ окне, что SSH к серверу открывается. Без подтверждения через 2 минуты WARP отключится сам."
    if ! ask_yn "SSH открывается?" n; then
        run warp_cli disconnect; run systemctl stop "$WARP_REVERT_UNIT.timer"
        warn "WARP отключён."; return 0
    fi
    run systemctl stop "$WARP_REVERT_UNIT.timer"
    if warp_ok; then ok "WARP работает: SOCKS5 127.0.0.1:$port, выход через Cloudflare."
    else warn "Подключено, но trace не показывает warp=on. Смотрите: warp-cli status"; fi
    warp_status
}

warp_status() {
    local t
    hdr "WARP — состояние"
    if ! warp_installed; then say "  Не установлен."; return 0; fi
    printf '  warp-cli  : %s\n' "$(warp_cli status 2>/dev/null | head -1)"
    printf '  SOCKS5    : 127.0.0.1:%s\n' "$(warp_port)"
    t=$(warp_trace)
    printf '  Через WARP: %s, IP %s, %s\n' \
        "$(printf '%s' "$t" | sed -n 's/^warp=//p')" "$(printf '%s' "$t" | sed -n 's/^ip=//p')" "$(printf '%s' "$t" | sed -n 's/^colo=//p')"
    say "  Как использовать:"
    say "    проверка:  curl -x socks5h://127.0.0.1:$(warp_port) $WARP_TRACE"
    say "    Xray:      outbound socks → 127.0.0.1:$(warp_port)"
    say "    mtg:       в /etc/mtg/mtg.toml, раздел [network]: proxies = [\"socks5://127.0.0.1:$(warp_port)\"]"
}

warp_remove() {
    warp_installed || { ok "WARP не установлен."; return 0; }
    ask_yn "Отключить WARP и удалить cloudflare-warp?" n || return 0
    local port; port=$(warp_port)
    run warp_cli disconnect || true
    run warp_cli registration delete || true
    run env DEBIAN_FRONTEND=noninteractive apt-get purge -y -q cloudflare-warp
    rm -f "$WARP_LIST" "$WARP_KEYRING"
    state_del warp port
    ok "WARP удалён. Если Xray или mtg ходили через SOCKS5 :$port — уберите это из их настроек."
}

# ===== bot/ykit-bot.py (вшит) =====
ykit_bot_py() {
cat <<'YKITBOTPY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Yagaza Kit — Telegram-бот владельца сервера.

Только стандартная библиотека Python 3, Bot API напрямую по HTTPS, long polling.
Сверено с Bot API 10.4 (9 ноября 2026): getUpdates, sendMessage, editMessageText,
answerCallbackQuery, sendPhoto, sendDocument, setMyCommands; InlineKeyboardButton
(callback_data 1–64 байта, поле style — 10.x).

Доступ: только Telegram ID из ADMINS и только в личном чате. Все действия —
через `yagaza --api ...`: бот не знает устройство модулей и не правит файлы сам.
Токен не пишется в лог (URL с токеном нигде не печатается).
"""

import html
import json
import os
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

CONF = os.environ.get("YKIT_BOT_CONF", "/etc/ykit/bot.conf")
OFFSET_FILE = os.environ.get("YKIT_BOT_OFFSET", "/etc/ykit/bot.offset")
YAGAZA = os.environ.get("YKIT_BIN", "/usr/local/bin/yagaza")

RUNNING = True
PENDING = {}  # user_id -> "v" | "a": ждём имя нового клиента


def log(msg):
    print(time.strftime("%F %T"), msg, flush=True)


def load_conf():
    conf = {}
    with open(CONF, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                conf[k.strip()] = v.strip()
    token = conf.get("TOKEN", "")
    admins = {int(x) for x in conf.get("ADMINS", "").replace(" ", "").split(",") if x.isdigit()}
    if not token or not admins:
        sys.exit("В %s нужны TOKEN=... и ADMINS=<ваш Telegram ID>" % CONF)
    return token, admins


TOKEN, ADMINS = load_conf()


class TgError(Exception):
    pass


def call(method, params=None, files=None, timeout=70):
    """Вызов Bot API. 429 — ждём ровно retry_after и повторяем."""
    url = "https://api.telegram.org/bot%s/%s" % (TOKEN, method)
    params = params or {}
    for _ in range(5):
        if files:
            boundary = uuid.uuid4().hex
            body = b""
            for k, v in params.items():
                if isinstance(v, (dict, list)):
                    v = json.dumps(v)
                body += ("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n" % (boundary, k, v)).encode()
            for k, (fname, data, ctype) in files.items():
                body += ("--%s\r\nContent-Disposition: form-data; name=\"%s\"; filename=\"%s\"\r\nContent-Type: %s\r\n\r\n"
                         % (boundary, k, fname, ctype)).encode() + data + b"\r\n"
            body += ("--%s--\r\n" % boundary).encode()
            req = urllib.request.Request(url, data=body, headers={"Content-Type": "multipart/form-data; boundary=" + boundary})
        else:
            req = urllib.request.Request(url, data=json.dumps(params).encode(), headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                res = json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            try:
                res = json.loads(e.read().decode())
            except Exception:
                raise TgError("%s: HTTP %s" % (method, e.code))
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            raise TgError("%s: сеть: %s" % (method, getattr(e, "reason", e)))
        if res.get("ok"):
            return res.get("result")
        if res.get("error_code") == 429:
            time.sleep(int(res.get("parameters", {}).get("retry_after", 5)) + 1)
            continue
        raise TgError("%s: %s %s" % (method, res.get("error_code"), res.get("description")))
    raise TgError("%s: слишком много повторов (429)" % method)


def yg(*args, timeout=300):
    """Вызов `yagaza --api ...` → (код, stdout, stderr)."""
    env = dict(os.environ, YI_PLAIN="1", TERM="dumb")
    try:
        p = subprocess.run([YAGAZA, "--api", *args], capture_output=True, text=True, timeout=timeout, env=env)
        err = "\n".join(l[2:] if l[:2] in ("✗ ", "! ") else l for l in p.stderr.strip().splitlines())
        return p.returncode, p.stdout.strip(), err
    except subprocess.TimeoutExpired:
        return 1, "", "yagaza не ответил за %s с" % timeout
    except FileNotFoundError:
        return 1, "", "нет %s" % YAGAZA


def esc(s):
    return html.escape(s or "", quote=False)


def qr_png(data):
    try:
        p = subprocess.run(["qrencode", "-t", "PNG", "-s", "8", "-o", "-", data], capture_output=True, timeout=20)
        return p.stdout if p.returncode == 0 and p.stdout else None
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None


# ---------- экраны ----------

def kb(rows):
    return {"inline_keyboard": [[{"text": t, "callback_data": d, **({"style": s} if s else {})} for t, d, s in row] for row in rows]}


BACK = [("‹ Меню", "m:main", None)]


def screen_main():
    rc, out, err = yg("status")
    lines = out.splitlines()
    head = esc(lines[0].strip()) if lines else "Yagaza Kit"
    body = []
    for ln in lines[1:]:
        if "|" in ln:
            t, s = ln.split("|", 1)
            icon = "🟢" if s.startswith(("работает", "настроено", "установлен")) else ("🟡" if "частично" in s else "⚪️")
            body.append("%s <b>%s</b> — %s" % (icon, esc(t), esc(s)))
    text = "<b>Yagaza Kit</b>\n<i>%s</i>\n\n%s" % (head, "\n".join(body) or esc(err))
    return text, kb([
        [("🔑 VLESS", "v:list", "primary"), ("🛡 AmneziaWG", "a:list", "primary")],
        [("🔀 Каскад", "k:list", None), ("☁️ WARP", "w:show", None)],
        [("📨 MTProxy", "t:links", None), ("🌐 Порты", "m:ports", None)],
        [("🔄 Обновить", "m:main", None)],
    ])


# ---------- Каскад ----------

def kaskad_rules():
    rc, out, err = yg("kaskad-list")
    rules = []
    for ln in out.splitlines():
        p = ln.split("|")
        if len(p) == 5:
            rules.append({"n": p[0], "proto": p[1], "lport": p[2], "host": p[3], "tport": p[4]})
    return rules


def rule_text(r):
    return "%s/%s → %s:%s" % (r["lport"], r["proto"], r["host"], r["tport"])


def screen_kaskad():
    rules = kaskad_rules()
    rows = [[("🔀 " + rule_text(r), "k:show:%s:%s" % (r["n"], r["lport"]), None)] for r in rules[:40]]
    rows.append([("➕ Добавить переброс", "k:add", "success")])
    rows.append(BACK)
    text = ("<b>Каскад</b> · перебросов: %d\nВходящий порт этого сервера → другой сервер.\n"
            "Нажмите на переброс, чтобы удалить." % len(rules))
    return text, kb(rows)


def kaskad_find(n, lport):
    for r in kaskad_rules():
        if r["n"] == n and r["lport"] == lport:
            return r
    return None


def screen_kaskad_rule(n, lport):
    r = kaskad_find(n, lport)
    if not r:
        return screen_kaskad()
    return ("<b>Переброс</b>\n<code>%s</code>" % esc(rule_text(r)),
            kb([[("🗑 Удалить", "k:del:%s:%s" % (n, lport), "danger")], [("‹ Назад", "k:list", None)]]))


KASKAD_HELP = ("Пришлите одной строкой: <b>протокол порт куда порт</b>\n"
               "Например: <code>tcp 443 1.2.3.4 443</code> или <code>both 51820 nl.example.com 51820</code>\n"
               "Протокол: tcp, udp или both. Порт SSH и занятые программами порты бот не перебрасывает.")


# ---------- WARP ----------

def warp_state():
    rc, out, err = yg("warp-state")
    lines = out.splitlines()
    if not lines or lines[0] == "none":
        return None
    st = lines[0].split("|") + ["", "", "", ""]
    return {"on": st[0] == "on", "ip": st[1], "colo": st[2], "port": st[3], "vless": "vless_via_warp" in lines}


def screen_warp(note=""):
    s = warp_state()
    if s is None:
        return ("<b>☁️ WARP</b>\n\nНе установлен. Поставьте в меню сервера: <code>yagaza</code> → WARP.", kb([BACK]))
    if s["on"]:
        text = ("<b>☁️ WARP</b> — 🟢 включён\nВыход: <code>%s</code> (%s)\nSOCKS5: 127.0.0.1:%s"
                % (esc(s["ip"]), esc(s["colo"]), esc(s["port"])))
        btn = ("⏹ Выключить", "w:off", "danger")
    else:
        text = "<b>☁️ WARP</b> — ⚪️ выключен\nSOCKS5: 127.0.0.1:%s" % esc(s["port"])
        btn = ("▶️ Включить", "w:on", "success")
    if s["vless"]:
        text += "\n\n⚠️ VLESS выпускает клиентов через WARP: без WARP у них пропадёт интернет."
    if note:
        text += "\n\n" + note
    return text, kb([[btn], [("🔄 Проверить", "w:show", None)], BACK])


def screen_ports():
    rc, out, err = yg("ports")
    return "<b>Порты сервера</b>\n<pre>%s</pre>" % esc((out or err)[:3800]), kb([BACK])


def screen_list(kind):
    title = "VLESS Reality" if kind == "v" else "AmneziaWG"
    rc, out, err = yg("vless-list" if kind == "v" else "awg-list")
    if rc != 0:
        return "<b>%s</b>\n\n%s\n\nУстановите в меню сервера: <code>yagaza</code>" % (title, esc(err)), kb([BACK])
    names = [n for n in out.splitlines() if n.strip()]
    rows = [[("👤 " + n, "%s:show:%s" % (kind, n), None)] for n in names[:40]]
    rows.append([("➕ Добавить", kind + ":add", "success")])
    rows.append(BACK)
    return "<b>%s</b> · клиентов: %d\nНажмите на клиента — пришлю ключ и QR." % (title, len(names)), kb(rows)


def screen_client(kind, name):
    return ("<b>%s</b>: %s" % ("VLESS" if kind == "v" else "AmneziaWG", esc(name)),
            kb([[("📤 Прислать ключ", "%s:send:%s" % (kind, name), "primary")],
                [("🗑 Удалить", "%s:del:%s" % (kind, name), "danger")],
                [("‹ Назад", kind + ":list", None)]]))


def screen_confirm_del(kind, name):
    return ("Удалить клиента <b>%s</b>? Его ключ перестанет работать." % esc(name),
            kb([[("Да, удалить", "%s:delok:%s" % (kind, name), "danger"), ("Отмена", "%s:show:%s" % (kind, name), None)]]))


# ---------- отправка ключей ----------

def send_key(chat_id, kind, name):
    if kind == "v":
        rc, link, err = yg("vless-link", name)
        if rc != 0:
            return call("sendMessage", {"chat_id": chat_id, "text": "⚠️ " + (err or "ошибка")})
        cap = "🔑 <b>%s</b> — VLESS Reality\n<code>%s</code>\n\nИмпорт: Happ, v2rayN, Hiddify, Streisand." % (esc(name), esc(link))
        png = qr_png(link)
        if png and len(cap) <= 1024:
            call("sendPhoto", {"chat_id": chat_id, "caption": cap, "parse_mode": "HTML", "protect_content": True},
                 files={"photo": ("qr.png", png, "image/png")})
        else:
            call("sendMessage", {"chat_id": chat_id, "text": cap, "parse_mode": "HTML", "protect_content": True})
    else:
        rc, path, err = yg("awg-file", name)
        if rc != 0:
            return call("sendMessage", {"chat_id": chat_id, "text": "⚠️ " + (err or "ошибка")})
        with open(path, "rb") as f:
            data = f.read()
        call("sendDocument", {"chat_id": chat_id, "caption": "🛡 %s — AmneziaWG. Импорт в AmneziaVPN / AmneziaWG." % name,
                              "protect_content": True}, files={"document": (name + ".conf", data, "text/plain")})
        png = qr_png(data.decode())
        if png:
            call("sendPhoto", {"chat_id": chat_id, "caption": "QR для %s" % name, "protect_content": True},
                 files={"photo": ("qr.png", png, "image/png")})


def send_mtproxy(chat_id):
    rc, out, err = yg("mtproxy-links")
    if rc != 0:
        text = "📨 MTProxy\n\n%s" % esc(err)
    else:
        text = "📨 <b>MTProxy</b>\n" + "\n".join("<code>%s</code>" % esc(l) for l in out.splitlines() if l.strip())
    call("sendMessage", {"chat_id": chat_id, "text": text, "parse_mode": "HTML", "protect_content": True})


# ---------- обработка ----------

def show(chat_id, msg_id, text_markup):
    text, markup = text_markup
    params = {"chat_id": chat_id, "text": text, "parse_mode": "HTML", "reply_markup": markup,
              "link_preview_options": {"is_disabled": True}}
    if msg_id:
        try:
            call("editMessageText", dict(params, message_id=msg_id))
            return
        except TgError as e:
            if "not modified" in str(e):
                return
    call("sendMessage", params)


def on_message(m):
    chat, user = m.get("chat", {}), m.get("from", {})
    uid, cid = user.get("id"), chat.get("id")
    if uid not in ADMINS or chat.get("type") != "private":
        if chat.get("type") == "private":
            call("sendMessage", {"chat_id": cid, "text": "⛔ Нет доступа."})
        return
    text = (m.get("text") or "").strip()
    if uid in PENDING and text and not text.startswith("/") and PENDING[uid] == "k":
        PENDING.pop(uid)
        args = text.split()
        if len(args) != 4:
            call("sendMessage", {"chat_id": cid, "text": "Нужно 4 значения через пробел.\n\n" + KASKAD_HELP, "parse_mode": "HTML"})
            PENDING[uid] = "k"
            return
        call("sendMessage", {"chat_id": cid, "text": "⏳ Добавляю переброс…"})
        rc, out, err = yg("kaskad-add", args[0].lower(), args[1], args[2], args[3])
        if rc != 0:
            call("sendMessage", {"chat_id": cid, "text": "⚠️ Не добавил: %s" % (err or "ошибка")})
        else:
            warn = "\n".join(l[6:] for l in out.splitlines() if l.startswith("warn: "))
            call("sendMessage", {"chat_id": cid, "text": "✅ Переброс добавлен." + ("\n⚠️ " + warn if warn else "")})
        show(cid, None, screen_kaskad())
        return
    if uid in PENDING and text and not text.startswith("/"):
        kind = PENDING.pop(uid)
        call("sendMessage", {"chat_id": cid, "text": "⏳ Добавляю %s…" % text})
        rc, out, err = yg("vless-add" if kind == "v" else "awg-add", text)
        if rc != 0:
            call("sendMessage", {"chat_id": cid, "text": "⚠️ Не добавил: %s" % (err or "ошибка")})
        else:
            send_key(cid, kind, text)
        show(cid, None, screen_list(kind))
        return
    PENDING.pop(uid, None)
    show(cid, None, screen_main())


def on_callback(q):
    uid = q.get("from", {}).get("id")
    msg = q.get("message") or {}
    cid, mid = msg.get("chat", {}).get("id"), msg.get("message_id")
    if uid not in ADMINS or msg.get("chat", {}).get("type") != "private":
        call("answerCallbackQuery", {"callback_query_id": q["id"], "text": "Нет доступа", "show_alert": True})
        return
    data = q.get("data") or ""
    parts = data.split(":", 2)
    kind, act, name = (parts + ["", "", ""])[:3]
    note = None
    answered = False

    def answer_now(text):  # долгие действия: ответить на нажатие сразу, иначе запрос устареет
        nonlocal answered
        call("answerCallbackQuery", {"callback_query_id": q["id"], "text": text})
        answered = True

    try:
        if kind == "k":
            if act == "list":
                show(cid, mid, screen_kaskad())
            elif act == "add":
                PENDING[uid] = "k"
                call("sendMessage", {"chat_id": cid, "text": KASKAD_HELP, "parse_mode": "HTML"})
            elif act in ("show", "del", "delok") and ":" in name:
                n, lport = name.split(":", 1)
                r = kaskad_find(n, lport)
                if not r:
                    note = "Этого переброса уже нет"
                    show(cid, mid, screen_kaskad())
                elif act == "show":
                    show(cid, mid, screen_kaskad_rule(n, lport))
                elif act == "del":
                    show(cid, mid, ("Удалить переброс <code>%s</code>?" % esc(rule_text(r)),
                                    kb([[("Да, удалить", "k:delok:%s:%s" % (n, lport), "danger"),
                                         ("Отмена", "k:show:%s:%s" % (n, lport), None)]])))
                else:
                    answer_now("⏳ Удаляю…")
                    rc, out, err = yg("kaskad-del", n)
                    show(cid, mid, screen_kaskad())
                    if rc != 0:
                        call("sendMessage", {"chat_id": cid, "text": "⚠️ " + (err or "ошибка")})
            return
        if kind == "w":
            if act == "show":
                show(cid, mid, screen_warp())
            elif act == "on":
                answer_now("⏳ Включаю WARP…")
                rc, out, err = yg("warp-on", timeout=90)
                show(cid, mid, screen_warp("" if rc == 0 else "⚠️ " + esc(err or "ошибка")))
            elif act == "off":
                s = warp_state()
                if s and s["vless"]:
                    show(cid, mid, ("Выключить WARP? У клиентов VLESS пропадёт интернет, пока WARP не включат.",
                                    kb([[("Да, выключить", "w:offok", "danger"), ("Отмена", "w:show", None)]])))
                else:
                    answer_now("⏳ Выключаю…")
                    rc, out, err = yg("warp-off", timeout=60)
                    show(cid, mid, screen_warp("" if rc == 0 else "⚠️ " + esc(err or "ошибка")))
            elif act == "offok":
                answer_now("⏳ Выключаю…")
                rc, out, err = yg("warp-off", timeout=60)
                show(cid, mid, screen_warp("" if rc == 0 else "⚠️ " + esc(err or "ошибка")))
            return
        if data == "m:main":
            show(cid, mid, screen_main())
        elif data == "m:ports":
            show(cid, mid, screen_ports())
        elif data == "t:links":
            send_mtproxy(cid)
        elif kind in ("v", "a") and act == "list":
            show(cid, mid, screen_list(kind))
        elif kind in ("v", "a") and act == "add":
            PENDING[uid] = kind
            call("sendMessage", {"chat_id": cid, "text": "Пришлите имя нового клиента (латиница, цифры, - _), например: phone2"})
        elif kind in ("v", "a") and act == "show" and name:
            show(cid, mid, screen_client(kind, name))
        elif kind in ("v", "a") and act == "send" and name:
            send_key(cid, kind, name)
        elif kind in ("v", "a") and act == "del" and name:
            show(cid, mid, screen_confirm_del(kind, name))
        elif kind in ("v", "a") and act == "delok" and name:
            answer_now("⏳ Удаляю…")
            rc, out, err = yg("vless-del" if kind == "v" else "awg-del", name)
            show(cid, mid, screen_list(kind))
            if rc != 0:
                call("sendMessage", {"chat_id": cid, "text": "⚠️ " + (err or "ошибка")})
    finally:
        if not answered:
            call("answerCallbackQuery", {"callback_query_id": q["id"], **({"text": note} if note else {})})


def read_offset():
    try:
        with open(OFFSET_FILE) as f:
            return int(f.read().strip() or 0)
    except (OSError, ValueError):
        return 0


def write_offset(n):
    tmp = OFFSET_FILE + ".tmp"
    with open(tmp, "w") as f:
        f.write(str(n))
    os.replace(tmp, OFFSET_FILE)


def stop(*_):
    global RUNNING
    RUNNING = False


def main():
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        me = call("getMe")
        log("бот @%s запущен, админов: %d" % (me.get("username"), len(ADMINS)))
        call("setMyCommands", {"commands": [{"command": "start", "description": "Меню сервера"}]})
    except TgError as e:
        log("старт: %s" % e)
    offset = read_offset()
    while RUNNING:
        try:
            updates = call("getUpdates", {"offset": offset, "timeout": 50,
                                          "allowed_updates": ["message", "callback_query"]}, timeout=70)
        except TgError as e:
            msg = str(e)
            if " 409 " in msg:
                log("409: этот токен уже опрашивает другая программа или задан вебхук — нужен отдельный бот. Жду 60 с.")
                time.sleep(60)
            else:
                log("getUpdates: %s" % msg)
                time.sleep(5)
            continue
        for u in updates or []:
            uid = u.get("update_id", 0)
            if uid < offset:
                continue
            try:
                if "message" in u:
                    on_message(u["message"])
                elif "callback_query" in u:
                    on_callback(u["callback_query"])
            except Exception as e:  # одно сломанное обновление не должно останавливать бота
                log("обновление %s: %s" % (uid, e))
            offset = uid + 1
            write_offset(offset)
    log("остановлен")


if __name__ == "__main__":
    main()
YKITBOTPY
}

# ===== ykit.sh =====
# Yagaza Kit — установщик компонентов для VPS: меню, проверка портов до установки,
# состояние, откат. Первая установка — через bootstrap.sh (см. README.md).

set -o pipefail

YI_HOME="${YI_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)}"

# В однофайловой сборке (tools/bundle.sh) библиотеки и модули уже вставлены выше.
if [ -z "${YI_BUNDLED:-}" ]; then
    if [ ! -r "$YI_HOME/lib/common.sh" ]; then
        echo "Не найдены файлы установщика рядом с $0. Ставьте через bootstrap.sh (см. README.md)." >&2
        exit 1
    fi
    # shellcheck source=lib/common.sh
    . "$YI_HOME/lib/common.sh"
    # shellcheck source=lib/state.sh
    . "$YI_HOME/lib/state.sh"
    # shellcheck source=lib/ports.sh
    . "$YI_HOME/lib/ports.sh"
    # shellcheck source=lib/ui.sh
    . "$YI_HOME/lib/ui.sh"
    for _m in "$YI_HOME"/modules/*.sh; do
        # shellcheck disable=SC1090
        [ -r "$_m" ] && . "$_m"
    done
    unset _m
fi

# Порядок в меню. Модули без файла показываются как «в разработке».
# Первые YI_OWN — свои модули, дальше — продукты клуба (modules/club.sh).
MODULES=(base mtproxy amneziawg warp kaskad dns vless bot e4tv webproxy)
YI_OWN=10

mod_title() {
    if declare -F "${1}_title" >/dev/null; then "${1}_title"; return; fi
    case "$1" in
        mtproxy)   printf 'MTProxy (mtg)' ;;
        amneziawg) printf 'AmneziaWG' ;;
        warp)      printf 'WARP (warp-cli)' ;;
        *)         printf '%s' "$1" ;;
    esac
}
mod_ready()   { declare -F "${1}_install" >/dev/null; }
mod_summary() { if mod_ready "$1"; then "${1}_summary"; else printf 'в разработке'; fi; }
mod_check()   { if mod_ready "$1"; then "${1}_check"; else printf '—'; fi; }
mod_valid()   { local m; for m in "${MODULES[@]}"; do [ "$m" = "$1" ] && return 0; done; return 1; }

server_line() {
    local cpu ram disk ip
    cpu=$(nproc 2>/dev/null || echo '?')
    ram=$(free -m 2>/dev/null | awk '/^Mem:/ { printf "%.1f ГБ", $2 / 1024 }')
    disk=$(df -h / 2>/dev/null | awk 'NR == 2 { print $2 }' | sed 's/G$/ ГБ/; s/T$/ ТБ/; s/M$/ МБ/')
    ip=$(server_ip)
    printf ' %sYagaza Kit %s%s · %s · %s · %s CPU / %s / %s диск · IP %s\n' \
        "$C_B" "$YI_VERSION" "$C_0" "$(hostname -s)" "$OS_NAME" "$cpu" "${ram:-?}" "${disk:-?}" "${ip:-?}"
}

summary_screen() {
    local i=1 m line
    line=$(printf '%.0s─' {1..70})
    printf '\n'; server_line
    os_supported || printf ' %s! ОС не из проверенных (Ubuntu 22.04/24.04, Debian 12)%s\n' "$C_Y" "$C_0"
    printf '%s\n' "$line"
    printf '  %s%s%s%s\n' "$(pad "#" 4)" "$(pad "Компонент" 20)" "$(pad "Состояние" 26)" "Проверка"
    printf '%s\n' "$line"
    for m in "${MODULES[@]}"; do
        [ "$i" -eq $((YI_OWN + 1)) ] && printf '  %sПродукты клуба (их установщики, ключ клуба)%s\n' "$C_D" "$C_0"
        printf '  %s%s%s%s\n' "$(pad "$i" 4)" "$(pad "$(mod_title "$m")" 20)" "$(pad "$(mod_summary "$m")" 26)" "$(mod_check "$m")"
        i=$((i + 1))
    done
    printf '%s\n' "$line"
    printf '  p  Порты сервера    l  Лог    u  Обновить установщик    q  Выход\n'
}

module_screen() {
    local m="$1" a
    if ! mod_ready "$m"; then warn "$(mod_title "$m") — модуль ещё в разработке."; return; fi
    while :; do
        hdr "$(mod_title "$m") — $(mod_summary "$m")"
        printf '  1  Установить / настроить\n  2  Состояние\n'
        declare -F "${m}_remove" >/dev/null && printf '  3  Удалить\n'
        printf '  0  Назад\n'
        tty_read a " Выбор: "
        case "$a" in
            1) "${m}_install" ;;
            2) "${m}_status" ;;
            3) if declare -F "${m}_remove" >/dev/null; then "${m}_remove"; else warn "Нет такого пункта."; fi ;;
            0|q|"") return ;;
            *) warn "Нет такого пункта." ;;
        esac
    done
}

# ---------- экранное меню (стрелки) ----------

ui_server_box() {   # ui_server_box <подзаголовок>
    local ram disk ip used dpct
    ram=$(free -m 2>/dev/null | awk '/^Mem:/ { printf "%.1f ГБ", $2 / 1024 }')
    used=$(free -m 2>/dev/null | awk '/^Mem:/ { if ($2) printf "%d%%", $3 * 100 / $2 }')
    disk=$(df -h / 2>/dev/null | awk 'NR == 2 { print $2 }' | sed 's/G$/ ГБ/; s/T$/ ТБ/; s/M$/ МБ/')
    dpct=$(df -h / 2>/dev/null | awk 'NR == 2 { print $5 }')
    ip=$(server_ip)
    printf '\n'
    ui_box_top "${C_B}${C_CY}YAGAZA KIT${C_0} ${C_D}v$YI_VERSION${C_0}${1:+ ${C_FR}·${C_0} ${C_B}$1${C_0}}"
    ui_box_line "${C_B}$(hostname -s)${C_0}  ${C_MG}${ip:-?}${C_0}" "${C_D}$OS_NAME${C_0}"
    ui_box_line "${C_D}CPU${C_0} $(nproc 2>/dev/null || echo '?')   ${C_D}RAM${C_0} ${ram:-?} ${C_D}(${used:-?})${C_0}   ${C_D}диск${C_0} ${disk:-?} ${C_D}(${dpct:-?})${C_0}" \
        "$(os_supported && printf '%s✓ ОС проверена%s' "$C_G" "$C_0" || printf '%s! ОС не из проверенных%s' "$C_Y" "$C_0")"
    ui_box_bottom
}

ui_head_main() {
    ui_server_box ""
    printf '\n   %s%s%s%s%s\n' "$C_D" "$(pad "#" 4)" "$(pad "Компонент" 20)" "$(pad "Состояние" 28)" "Проверка$C_0"
}

ui_section() {   # ui_section <название> <пояснение>
    ui_add "" "${C_B}${2:-$C_CY}$1${C_0}${3:+  ${C_D}$3${C_0}}" ""
}

ui_main_rows() {
    local i=1 m title sp sc cp cc
    ui_reset
    ui_section "СВОИ МОДУЛИ" "$C_CY" "код ваш, от подписки не зависит"
    for m in "${MODULES[@]}"; do
        if [ "$m" = e4tv ]; then
            ui_add "" "" ""
            ui_section "ПРОЕКТЫ EVGEN4IK" "$C_G" "ваши установщики с GitHub koksik2022"
        fi
        if [ "$i" -eq $((YI_OWN + 1)) ]; then
            ui_add "" "" ""
            ui_section "ПРОДУКТЫ КЛУБА" "$C_MG" "установщики автора, нужен ключ клуба"
        fi
        title=$(mod_title "$m")
        ui_fmt status "$(mod_summary "$m")"; sp="$UF_P"; sc="$UF_C"
        ui_fmt check "$(mod_check "$m")"; cp="$UF_P"; cc="$UF_C"
        ui_add "$i" \
            "${C_B}$(pad "$i" 4)${C_0}$(pad "$title" 20)${sc}$(pad "" $((28 - ${#sp})))${cc}" \
            "$(pad "$i" 4)$(pad "$title" 20)$(pad "$sp" 28)$cp"
        i=$((i + 1))
    done
    ui_add "" "" ""
    ui_section "СЕРВИС" "$C_FR"
    ui_add p "${C_B}$(pad p 4)${C_0}Порты сервера"        "$(pad p 4)Порты сервера"
    ui_add l "${C_B}$(pad l 4)${C_0}Лог"                  "$(pad l 4)Лог"
    ui_add u "${C_B}$(pad u 4)${C_0}Обновить Yagaza Kit"  "$(pad u 4)Обновить Yagaza Kit"
    ui_add q "${C_B}$(pad q 4)${C_0}Выход"                "$(pad q 4)Выход"
}

ui_module() {
    local m="$1"
    if ! mod_ready "$m"; then warn "$(mod_title "$m") — модуль ещё в разработке."; ui_pause; return; fi
    while :; do
        UI_MOD="$m"
        ui_reset
        ui_add 1 "${C_B}$(pad 1 4)${C_0}Установить / настроить" "$(pad 1 4)Установить / настроить"
        ui_add 2 "${C_B}$(pad 2 4)${C_0}Состояние"              "$(pad 2 4)Состояние"
        if declare -F "${m}_remove" >/dev/null; then
            ui_add 3 "${C_B}$(pad 3 4)${C_0}${C_R}Удалить${C_0}" "$(pad 3 4)Удалить"
        fi
        ui_add "" "" ""
        ui_add 0 "${C_B}$(pad 0 4)${C_0}Назад" "$(pad 0 4)Назад"
        ui_select ui_head_module || return
        case "$UI_CHOICE" in
            1) "${m}_install"; ui_pause ;;
            2) "${m}_status"; ui_pause ;;
            3) "${m}_remove"; ui_pause ;;
            0|q) return ;;
        esac
    done
}
ui_head_module() {
    local m="$UI_MOD"
    ui_server_box "$(mod_title "$m")"
    ui_fmt status "$(mod_summary "$m")"; printf '\n   %sСостояние:%s %s\n' "$C_D" "$C_0" "$UF_C"
    ui_fmt check "$(mod_check "$m")";    printf '   %sПроверка: %s %s\n\n' "$C_D" "$C_0" "$UF_C"
}

menu_ui() {
    trap 'printf "\e[?25h"' EXIT
    while :; do
        ui_main_rows
        ui_select ui_head_main || exit 0
        case "$UI_CHOICE" in
            [0-9]|[0-9][0-9]) ui_module "${MODULES[$((UI_CHOICE - 1))]}" ;;
            p) ports_print; ui_pause ;;
            l) hdr "Последние строки $YI_LOG"; tail -n 40 "$YI_LOG" 2>/dev/null || say "Лог пуст."; ui_pause ;;
            u) self_update; ui_pause ;;
            q) exit 0 ;;
        esac
    done
}

menu() {
    local a
    if ui_tty; then menu_ui; return; fi
    while :; do
        summary_screen
        tty_read a " Выбор: "
        case "$a" in
            [1-9]|[1-9][0-9])
                   if [ "$a" -le "${#MODULES[@]}" ]; then module_screen "${MODULES[$((a - 1))]}"
                   else warn "Нет такого пункта."; fi ;;
            p|P) ports_print ;;
            l|L) hdr "Последние строки $YI_LOG"; tail -n 40 "$YI_LOG" 2>/dev/null || say "Лог пуст." ;;
            u|U) self_update ;;
            q|Q|0) exit 0 ;;
            *) warn "Нет такого пункта." ;;
        esac
    done
}

# Однофайловая сборка: поставить себя командой yagaza.
self_install_file() {
    local src
    src=$(readlink -f "$0")
    [ -f "$src" ] || die "Запустите из файла: bash yagaza-kit.sh --self-install"
    install -m 755 -o root -g root "$src" /usr/local/bin/yagaza && ok "Установлено: /usr/local/bin/yagaza — дальше просто команда yagaza."
}

self_update() {
    if [ -n "${YI_BUNDLED:-}" ]; then
        # Публичная сборка: get.sh из ветки main сам скачивает закреплённую версию и сверяет SHA-256.
        local url="${YI_GET_URL:-https://raw.githubusercontent.com/koksik2022/yagaza-kit/main/get.sh}" tmp
        tmp=$(mktemp) || return 1
        say "Проверяю обновление: $url"
        if ! curl -fsSL --max-time 60 -o "$tmp" "$url"; then err "Не скачал get.sh — нет сети или репозитория."; rm -f "$tmp"; return 1; fi
        local new; new=$(sed -n 's/.*local VER="\([^"]*\)".*/\1/p' "$tmp" | head -1)
        if [ "$new" = "$YI_VERSION" ]; then ok "Уже последняя версия: $YI_VERSION"; rm -f "$tmp"; return 0; fi
        ask_yn "Обновить Yagaza Kit $YI_VERSION → ${new:-?}?" y || { rm -f "$tmp"; return 0; }
        bash "$tmp" --no-menu && ok "Обновлено. Перезапустите: yagaza"
        rm -f "$tmp"; return 0
    fi
    if [ -x "$YI_HOME/bootstrap.sh" ] || [ -r "$YI_HOME/bootstrap.sh" ]; then
        bash "$YI_HOME/bootstrap.sh" --update
    else
        err "Нет $YI_HOME/bootstrap.sh — обновление недоступно."
    fi
}

usage() {
    cat <<EOF
Yagaza Kit $YI_VERSION — установщик компонентов VPS

  yagaza                       меню
  yagaza --status              сводка по всем компонентам
  yagaza --ports               кто какие порты держит
  yagaza --check <модуль>      проверка без установки
  yagaza --install <модуль>    установка / настройка (с вопросами)
  yagaza --remove <модуль>     удалить компонент (где поддерживается)
  yagaza --rollback base.ssh|base.fw|base.bbr
  yagaza --self-update         обновиться до последнего релиза
  yagaza --version
  bash yagaza-kit.sh --self-install   однофайловая сборка → команда yagaza

Модули: ${MODULES[*]}
EOF
}

# ---------- API для Telegram-бота: без вопросов, простой вывод ----------
# Результат — в stdout, ошибки — в stderr, код 0/1. Цвета отключены (не терминал).
api_cmd() {
    local a="${1:-}" n="${2:-}" m
    case "$a" in
        status)
            server_line
            for m in "${MODULES[@]:0:$YI_OWN}"; do printf '%s|%s\n' "$(mod_title "$m")" "$(mod_summary "$m")"; done ;;
        ports)        ports_print ;;
        vless-list)   vless_installed || { echo "VLESS не установлен" >&2; return 1; }; awk '{ print $1 }' "$XRAY_CLIENTS" ;;
        vless-add)    vless_installed || { echo "VLESS не установлен" >&2; return 1; }; vless_client_new "$n" && vless_link "$n" ;;
        vless-link)   vless_link "$n" || { echo "Нет клиента $n" >&2; return 1; } ;;
        vless-del)    vless_client_remove "$n" ;;
        awg-list)     amneziawg_installed || { echo "AmneziaWG не установлен" >&2; return 1; }
                      for m in "$AWG_CLIENTS"/*.conf; do [ -e "$m" ] && basename "$m" .conf; done; return 0 ;;
        awg-add)      amneziawg_installed || { echo "AmneziaWG не установлен" >&2; return 1; }
                      amneziawg_client_new "$n" >/dev/null && printf '%s\n' "$AWG_CLIENTS/$n.conf" ;;
        awg-file)     if [[ "$n" =~ ^[A-Za-z0-9_-]{1,32}$ ]] && [ -r "$AWG_CLIENTS/$n.conf" ]; then printf '%s\n' "$AWG_CLIENTS/$n.conf"
                      else echo "Нет клиента $n" >&2; return 1; fi ;;
        awg-del)      amneziawg_client_remove "$n" ;;
        mtproxy-links) mtproxy_installed || { echo "MTProxy не установлен" >&2; return 1; }; mtproxy_links ;;
        kaskad-list)  kaskad_rules_lines ;;
        kaskad-add)   kaskad_rule_new "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
        kaskad-del)   kaskad_rule_remove "$n" ;;
        warp-state)   warp_state_line ;;
        warp-on)      warp_on ;;
        warp-off)     warp_off ;;
        *) echo "api: status|ports|vless-list|vless-add N|vless-link N|vless-del N|awg-list|awg-add N|awg-file N|awg-del N|mtproxy-links|kaskad-list|kaskad-add P L H T|kaskad-del N|warp-state|warp-on|warp-off" >&2; return 64 ;;
    esac
}

main() {
    case "${1:-}" in
        -h|--help)  usage; exit 0 ;;
        --version)  echo "$YI_VERSION"; exit 0 ;;
    esac
    require_root
    mkdir -p "$YI_ETC" && chmod 700 "$YI_ETC"
    touch "$YI_LOG" 2>/dev/null && chmod 600 "$YI_LOG" 2>/dev/null
    os_detect

    case "${1:-}" in
        "")          menu ;;
        --status)    server_line; local m; for m in "${MODULES[@]}"; do printf '  %s%s\n' "$(pad "$(mod_title "$m")" 20)" "$(mod_summary "$m")"; done ;;
        --ports)     ports_print ;;
        --check)     mod_valid "${2:-}" || { usage; exit 64; }
                     printf '%s: %s\n' "$(mod_title "$2")" "$(mod_check "$2")" ;;
        --install)   mod_valid "${2:-}" || { usage; exit 64; }
                     mod_ready "$2" || die "$(mod_title "$2") — модуль ещё в разработке."
                     "${2}_install" ;;
        --remove)    mod_valid "${2:-}" || { usage; exit 64; }
                     declare -F "${2}_remove" >/dev/null || die "У модуля $2 нет удаления."
                     "${2}_remove" ;;
        --rollback)  case "${2:-}" in
                         base.*) base_rollback "${2#base.}" ;;
                         *) usage; exit 64 ;;
                     esac ;;
        --self-update) self_update ;;
        --self-install) self_install_file ;;
        --api)       shift; api_cmd "$@"; exit $? ;;
        *)           usage; exit 64 ;;
    esac
}

main "$@"
