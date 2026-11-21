#!/usr/bin/env bash
# Собрать ykit в один файл: dist/yagaza-kit.sh (библиотеки + модули + меню).
# Запуск из папки ykit:  bash tools/bundle.sh

set -euo pipefail
cd "$(dirname "$0")/.."

out="dist/yagaza-kit.sh"
mkdir -p dist
{
    echo '#!/usr/bin/env bash'
    echo "# ykit — однофайловая сборка от $(date '+%F %T'). Исходники: lib/, modules/, ykit.sh"
    echo '# Запуск на сервере под root:  bash yagaza-kit.sh   (команда навсегда: bash yagaza-kit.sh --self-install)'
    echo 'YI_BUNDLED=1'
    for f in lib/common.sh lib/state.sh lib/ports.sh lib/ui.sh modules/*.sh; do
        printf '\n# ===== %s =====\n' "$f"
        cat "$f"
    done
    printf '\n# ===== bot/ykit-bot.py (вшит) =====\nykit_bot_py() {\ncat <<'"'"'YKITBOTPY'"'"'\n'
    cat bot/ykit-bot.py
    printf 'YKITBOTPY\n}\n'
    printf '\n# ===== ykit.sh =====\n'
    tail -n +2 ykit.sh
} | sed 's/\r$//' >"$out"
chmod 755 "$out"
bash -n "$out"
echo "Собрано: $out ($(wc -l <"$out") строк), sha256: $(sha256sum "$out" | cut -d' ' -f1)"
