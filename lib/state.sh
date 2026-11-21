# shellcheck shell=bash
# Yagaza Kit — состояние модулей: $YI_STATE/<модуль>.conf, строки «ключ=значение».

state_file() { printf '%s/%s.conf' "$YI_STATE" "$1"; }

state_get() {   # state_get <модуль> <ключ>
    local f; f=$(state_file "$1")
    [ -r "$f" ] || return 1
    sed -n "s/^$2=//p" "$f" | tail -1
}

state_set() {   # state_set <модуль> <ключ> <значение>
    local f tmp v="${3//$'\n'/ }"
    mkdir -p "$YI_STATE" && chmod 700 "$YI_ETC" "$YI_STATE"
    f=$(state_file "$1")
    tmp=$(mktemp "$YI_STATE/.tmp.XXXXXX") || return 1
    { [ -r "$f" ] && grep -v "^$2=" "$f"; printf '%s=%s\n' "$2" "$v"; } >"$tmp"
    chmod 600 "$tmp" && mv -f "$tmp" "$f"
}

state_del() {   # state_del <модуль> <ключ>
    local f tmp; f=$(state_file "$1")
    [ -r "$f" ] || return 0
    tmp=$(mktemp "$YI_STATE/.tmp.XXXXXX") || return 1
    grep -v "^$2=" "$f" >"$tmp"
    chmod 600 "$tmp" && mv -f "$tmp" "$f"
}
