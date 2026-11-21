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
