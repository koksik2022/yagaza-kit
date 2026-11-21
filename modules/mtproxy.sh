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
