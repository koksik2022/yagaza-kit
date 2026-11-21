#!/usr/bin/env bash
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
