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
