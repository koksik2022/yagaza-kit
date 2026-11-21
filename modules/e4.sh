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
