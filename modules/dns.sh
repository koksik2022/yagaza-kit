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
