# shellcheck shell=bash
# Yagaza Kit — кто какие порты держит: ss (процессы, в т.ч. контейнеры с network host)
# и опубликованные порты Docker (их может не быть в ss без docker-proxy).

# Строки: «proto port addr владелец», proto = tcp|udp.
ports_collect() {
    ss -Htulnp 2>/dev/null | awk '
        {
            proto = $1; local = $5; proc = "?"
            n = split(local, a, ":"); port = a[n]
            addr = substr(local, 1, length(local) - length(port) - 1)
            if (match($0, /users:\(\("[^"]+"/)) proc = substr($0, RSTART + 9, RLENGTH - 10)
            print proto, port, addr, proc
        }'
    if command -v docker >/dev/null 2>&1; then
        docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null | while IFS='|' read -r name ports; do
            printf '%s\n' "$ports" | tr ',' '\n' |
                sed -n -E 's/^ *(.*):([0-9]+)->[0-9]+\/(tcp|udp).*/\3 \2 \1 docker:'"$name"'/p'
        done
    fi
}

# Адрес только локальный (127.x, ::1, интерфейс lo)?
addr_is_local() {
    case "$1" in
        127.*|\[::1\]|::1|*%lo|\[::ffff:127.*) return 0 ;;
    esac
    return 1
}

# port_owner <tcp|udp> <порт> — владельцы порта через запятую, пусто = свободен.
port_owner() {
    ports_collect | awk -v p="$1" -v n="$2" '$1 == p && $2 == n { print $4 }' | sort -u | paste -sd, -
}

# Публичные порты: «proto port» без дублей (для черновика правил файрвола).
ports_public() {
    local proto port addr owner
    ports_collect | while read -r proto port addr owner; do
        addr_is_local "$addr" || printf '%s %s\n' "$proto" "$port"
    done | sort -u -k1,1 -k2,2n
}

ports_print() {
    hdr "Порты сервера"
    printf '  %s%s%s%s\n' "$(pad "Прот." 7)" "$(pad "Порт" 8)" "$(pad "Где" 18)" "Кто держит"
    # Одна строка на proto+порт: IPv4/IPv6 и docker-proxy + контейнер сводятся вместе.
    local proto port addr owner
    ports_collect | sort -u | while read -r proto port addr owner; do
        if addr_is_local "$addr"; then printf '%s %s local %s\n' "$proto" "$port" "$owner"
        else printf '%s %s public %s\n' "$proto" "$port" "$owner"; fi
    done | awk '
        { k = $1 " " $2; key[k] = 1
          if ($3 == "public") pub[k] = 1
          if (!index(" " own[k] " ", " " $4 " ")) own[k] = own[k] (own[k] ? " " : "") $4 }
        END { for (k in key) {
                o = own[k]
                if (o ~ /docker:/) { gsub(/(^| )docker-proxy( |$)/, " ", o); gsub(/^ +| +$/, "", o) }
                gsub(/ /, ", ", o)
                print k, (pub[k] ? "снаружи" : "локально"), o } }' |
    sort -k1,1 -k2,2n | while read -r proto port where owner; do
        printf '  %s%s%s%s\n' "$(pad "$proto" 7)" "$(pad "$port" 8)" "$(pad "$where" 18)" "$owner"
    done
}
