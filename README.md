# Yagaza Kit (команда `yagaza`)

Установщик для своего VPS: одно меню, в котором ставятся VPN, прокси, DNS и полезные
сервисы. Перед каждой установкой Yagaza Kit проверяет порты и говорит прямо, что встанет,
что нет и почему. Каждый шаг — по вопросу, опасные изменения (SSH, файрвол, WARP)
откатываются сами, если вы не подтвердили, что доступ остался.

> ⚠️ **Бета.** Меню, проверки и конфиги проверены, но не каждый модуль прошёл полную
> установку на чистом сервере. Ставьте сначала на тестовый VPS, не на рабочий.

## Установка

На сервере, от root (Ubuntu 22.04 / 24.04 или Debian 12, KVM — не OpenVZ/LXC):

```bash
curl -fsSL https://raw.githubusercontent.com/koksik2022/yagaza-kit/main/get.sh | sudo bash
```

Дальше просто `yagaza`. Обновление — пункт «Обновить Yagaza Kit» в меню или `yagaza --self-update`.

Файл `get.sh` скачивает Yagaza Kit по закреплённому коммиту и сверяет SHA-256 — подменить
установщик по дороге нельзя.

## Что внутри

| # | Модуль | Что это | Нужно |
|---|---|---|---|
| 1 | Базовая настройка | обновления, часовой пояс, swap, BBR, SSH только по ключу и смена порта, файрвол | SSH-ключ в root |
| 2 | MTProxy (mtg) | прокси для Telegram с маскировкой под HTTPS-сайт | — |
| 3 | AmneziaWG | VPN, устойчивый к блокировкам; клиенты с QR-кодом | обычное ядро (KVM) |
| 4 | WARP | выход в интернет через Cloudflare (локальный SOCKS5) | — |
| 5 | Каскад | переброс портов на другой сервер | второй сервер |
| 6 | DNS (AdGuard Home) | свой DNS с DoH/DoT и фильтром рекламы | домен |
| 7 | VLESS Reality | VPN на Xray, ссылки vless:// и QR | — |
| 8 | Telegram-бот | ключи и статус сервера кнопками, только владельцу | бот от @BotFather |
| 9 | Evgen4ik TV | редактор IPTV-плейлистов (koksik2022/evgen4ik-tv) | домен — по желанию |
| 10 | WEB-прокси | WEB-прокси для Telegram (koksik2022/evgen4ik-proxy) | свободные 80/443, домен |

Программы ставятся из официальных источников: релизы Xray-core, mtg и AdGuard Home — со
сверкой контрольных сумм; AmneziaWG и Cloudflare WARP — из их репозиториев пакетов с
проверкой ключа.

## Всё на одном сервере

Многие модули хотят порт 443 — порядок важен, меню само подсказывает:

1. **WEB-прокси** — первым (ему нужны именно 80 и 443);
2. **VLESS, MTProxy, DNS** — на другие порты (установщик предложит 8443 и т.п.);
3. **Evgen4ik TV** — без домена (8090/8091);
4. **AmneziaWG, WARP, Каскад, бот** — с портами не конфликтуют.

## Без меню

```bash
yagaza --status              # сводка
yagaza --ports               # кто какие порты держит
yagaza --check vless         # проверка без установки
yagaza --install mtproxy     # установка (с вопросами)
yagaza --remove warp         # удаление
yagaza --rollback base.ssh   # вернуть настройки SSH
```

## Где что лежит

| Путь | Что |
|---|---|
| `/usr/local/bin/yagaza` | сам Yagaza Kit (один файл) |
| `/etc/ykit/` (только root) | настройки, состояние, копии изменённых файлов (`backup/`) |
| `/var/log/ykit.log` | лог |

## Для разработки

Исходники: `ykit.sh` (меню), `lib/`, `modules/`, `bot/`. Сборка в один файл и публикация:

```bash
bash tools/bundle.sh                              # → dist/yagaza-kit.sh
cp dist/yagaza-kit.sh yagaza-kit.sh && git add yagaza-kit.sh && git commit -m "yagaza-kit X.Y.Z"
bash tools/make-get.sh "$(git rev-parse HEAD)"    # get.sh с этим коммитом и SHA-256
git add get.sh && git commit -m "get.sh → X.Y.Z" && git push
```

Перед выпуском поднимите `YI_VERSION` в `lib/common.sh`.
