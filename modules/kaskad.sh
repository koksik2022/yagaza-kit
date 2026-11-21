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
    local n tmp
    kaskad_list; [ -s "$KASKAD_RULES" ] || return 0
    ask_val n "Номер правила для удаления" ""
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$(kaskad_count)" ] || { err "Нет такого номера."; return 0; }
    backup_file "$KASKAD_RULES"
    tmp=$(mktemp) || return 0
    awk -v n="$n" '/^[[:space:]]*(#|$)/ { print; next } { if (++i != n) print }' "$KASKAD_RULES" >"$tmp"
    cat "$tmp" >"$KASKAD_RULES"; rm -f "$tmp"
    ok "Правило $n удалено."
    kaskad_apply
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
