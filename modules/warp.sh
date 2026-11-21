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
