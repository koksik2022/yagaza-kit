# shellcheck shell=bash
# Yagaza Kit — экранное меню: стрелки ↑↓ + Enter, цифры, буквы; рамка-шапка,
# значки статусов, подсветка выбранной строки. Без терминала — ввод номера.

ui_tty() { [ -t 1 ] && [ -r /dev/tty ] && [ -z "${YI_PLAIN:-}" ]; }

UI_W=78
if [ -t 1 ]; then
    C_CY=$'\e[36m'; C_MG=$'\e[35m'; C_SEL=$'\e[1;97;48;5;25m'; C_FR=$'\e[38;5;67m'
else
    C_CY=""; C_MG=""; C_SEL=""; C_FR=""
fi

ui_strip() { printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g'; }
ui_rep() { local s=""; for ((_i = 0; _i < $2; _i++)); do s+="$1"; done; printf '%s' "$s"; }

# ---------- рамка ----------

ui_box_top() {   # ui_box_top <заголовок с цветом>
    local t="$1" v; v=$(ui_strip "$t")
    printf ' %s╭─%s %s %s%s╮%s\n' "$C_FR" "$C_0" "$t" "$C_FR" "$(ui_rep ─ $((UI_W - ${#v} - 5)))" "$C_0"
}
ui_box_line() {  # ui_box_line <левый текст> [правый текст]
    local l="$1" r="${2:-}" vl vr n
    vl=$(ui_strip "$l"); vr=$(ui_strip "$r")
    n=$((UI_W - ${#vl} - ${#vr} - 4)); [ "$n" -lt 1 ] && n=1
    printf ' %s│%s %s%*s%s %s│%s\n' "$C_FR" "$C_0" "$l" "$n" '' "$r" "$C_FR" "$C_0"
}
ui_box_bottom() { printf ' %s╰%s╯%s\n' "$C_FR" "$(ui_rep ─ $((UI_W - 2)))" "$C_0"; }

# ---------- значки и цвета ----------

# ui_fmt <status|check> <текст> → UF_P (без цвета), UF_C (с цветом). Значок + текст.
ui_fmt() {
    local kind="$1" t="$2" ic col
    if [ "$kind" = status ]; then
        case "$t" in
            работает*|настроено*|установлен*) ic="●"; col="$C_G" ;;
            *частично*)                        ic="◐"; col="$C_Y" ;;
            *остановлен*|*"не подключ"*)       ic="■"; col="$C_R" ;;
            *разработке*)                      ic="·"; col="$C_D" ;;
            *)                                 ic="○"; col="$C_D" ;;
        esac
    else
        case "$t" in
            "готов ("*)  ic="!"; col="$C_Y"; t="${t#готов (}"; t="${t%)}" ;;
            готов)       ic="✓"; col="$C_G" ;;
            установлен)  ic="✓"; col="$C_G" ;;
            *"уже есть"*) ic="!"; col="$C_Y" ;;
            —|"")        ic="·"; col="$C_D"; t="" ;;
            *)           ic="✗"; col="$C_R" ;;
        esac
    fi
    UF_P="$ic $t"
    UF_C="$col$ic$C_0 $col$t$C_0"
}

# Совместимость: цвет без значка (для строк вне меню).
ui_color() { ui_fmt status "$1"; printf '%s' "$UF_C"; }

# ---------- клавиатура ----------

# Одна клавиша → UI_KEY: up, down, enter, esc или сам символ.
ui_key() {
    local k k2=""
    IFS= read -rsn1 k </dev/tty || { UI_KEY=q; return; }
    if [ "$k" = $'\e' ]; then
        IFS= read -rsn2 -t 0.05 k2 </dev/tty || k2=""
        case "$k2" in
            '[A'|OA) UI_KEY=up ;;
            '[B'|OB) UI_KEY=down ;;
            *) UI_KEY=esc ;;
        esac
    elif [ -z "$k" ]; then UI_KEY=enter
    else UI_KEY="$k"; fi
}

ui_pause() {
    ui_tty || return 0
    printf '\n  %sEnter — назад%s' "$C_D" "$C_0" >/dev/tty
    IFS= read -rs _ </dev/tty || true
}

# ---------- выбор из списка ----------

# ui_select <функция-шапка>
# Вход: UI_ROWS (с цветом), UI_PLAIN (тот же текст без цвета, для подсветки),
#       UI_KEYS (ключ строки; пусто — строка не выбирается: заголовок или пустая).
# Выход: UI_CHOICE.
ui_select() {
    local head="$1" sel=-1 i n="${#UI_ROWS[@]}" d="" k2="" p
    for ((i = 0; i < n; i++)); do [ -n "${UI_KEYS[$i]}" ] && { sel=$i; break; }; done
    [ "$sel" -ge 0 ] || return 1
    printf '\e[?25l' >/dev/tty
    while :; do
        printf '\e[H\e[2J'
        "$head"
        for ((i = 0; i < n; i++)); do
            if [ "$i" -eq "$sel" ]; then
                p="${UI_PLAIN[$i]}"
                printf ' %s▌ %s%*s%s\n' "$C_SEL" "$p" $(( UI_W - ${#p} - 3 > 0 ? UI_W - ${#p} - 3 : 0 )) '' "$C_0"
            else
                printf '   %s\n' "${UI_ROWS[$i]}"
            fi
        done
        printf '\n  %s↑↓%s выбор   %sEnter%s открыть   %sцифра/буква%s сразу   %sq%s выход\n' \
            "$C_B" "$C_D" "$C_B" "$C_D" "$C_B" "$C_D" "$C_B" "$C_D$C_0"
        printf '%s' "$C_0"
        ui_key
        case "$UI_KEY" in
            up)   i=$sel; while :; do i=$(( (i - 1 + n) % n )); [ -n "${UI_KEYS[$i]}" ] && break; done; sel=$i ;;
            down) i=$sel; while :; do i=$(( (i + 1) % n )); [ -n "${UI_KEYS[$i]}" ] && break; done; sel=$i ;;
            enter) UI_CHOICE="${UI_KEYS[$sel]}"; break ;;
            esc|q|Q) UI_CHOICE=q; break ;;
            [0-9])
                # Две цифры (10, 11…): ждём вторую чуть-чуть.
                d="$UI_KEY"
                if IFS= read -rsn1 -t 0.5 k2 </dev/tty && [[ "$k2" =~ [0-9] ]]; then d="$d$k2"; fi
                for ((i = 0; i < n; i++)); do [ "${UI_KEYS[$i]}" = "$d" ] && { UI_CHOICE="$d"; break 2; }; done ;;
            *)
                for ((i = 0; i < n; i++)); do [ "${UI_KEYS[$i]}" = "${UI_KEY,,}" ] && { UI_CHOICE="${UI_KEY,,}"; break 2; }; done ;;
        esac
    done
    printf '\e[?25h' >/dev/tty
    printf '\e[H\e[2J'
}

# Добавить строку: ui_add <ключ> <цветной текст> <простой текст>
ui_add() { UI_KEYS+=("$1"); UI_ROWS+=("$2"); UI_PLAIN+=("$3"); }
ui_reset() { UI_KEYS=(); UI_ROWS=(); UI_PLAIN=(); }
