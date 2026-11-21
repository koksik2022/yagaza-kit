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
