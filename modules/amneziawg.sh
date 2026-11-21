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
