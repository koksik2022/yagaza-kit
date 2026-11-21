#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Yagaza Kit — Telegram-бот владельца сервера.

Только стандартная библиотека Python 3, Bot API напрямую по HTTPS, long polling.
Сверено с Bot API 10.4 (9 ноября 2026): getUpdates, sendMessage, editMessageText,
answerCallbackQuery, sendPhoto, sendDocument, setMyCommands; InlineKeyboardButton
(callback_data 1–64 байта, поле style — 10.x).

Доступ: только Telegram ID из ADMINS и только в личном чате. Все действия —
через `yagaza --api ...`: бот не знает устройство модулей и не правит файлы сам.
Токен не пишется в лог (URL с токеном нигде не печатается).
"""

import html
import json
import os
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

CONF = os.environ.get("YKIT_BOT_CONF", "/etc/ykit/bot.conf")
OFFSET_FILE = os.environ.get("YKIT_BOT_OFFSET", "/etc/ykit/bot.offset")
YAGAZA = os.environ.get("YKIT_BIN", "/usr/local/bin/yagaza")

RUNNING = True
PENDING = {}  # user_id -> "v" | "a": ждём имя нового клиента


def log(msg):
    print(time.strftime("%F %T"), msg, flush=True)


def load_conf():
    conf = {}
    with open(CONF, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                conf[k.strip()] = v.strip()
    token = conf.get("TOKEN", "")
    admins = {int(x) for x in conf.get("ADMINS", "").replace(" ", "").split(",") if x.isdigit()}
    if not token or not admins:
        sys.exit("В %s нужны TOKEN=... и ADMINS=<ваш Telegram ID>" % CONF)
    return token, admins


TOKEN, ADMINS = load_conf()


class TgError(Exception):
    pass


def call(method, params=None, files=None, timeout=70):
    """Вызов Bot API. 429 — ждём ровно retry_after и повторяем."""
    url = "https://api.telegram.org/bot%s/%s" % (TOKEN, method)
    params = params or {}
    for _ in range(5):
        if files:
            boundary = uuid.uuid4().hex
            body = b""
            for k, v in params.items():
                if isinstance(v, (dict, list)):
                    v = json.dumps(v)
                body += ("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n" % (boundary, k, v)).encode()
            for k, (fname, data, ctype) in files.items():
                body += ("--%s\r\nContent-Disposition: form-data; name=\"%s\"; filename=\"%s\"\r\nContent-Type: %s\r\n\r\n"
                         % (boundary, k, fname, ctype)).encode() + data + b"\r\n"
            body += ("--%s--\r\n" % boundary).encode()
            req = urllib.request.Request(url, data=body, headers={"Content-Type": "multipart/form-data; boundary=" + boundary})
        else:
            req = urllib.request.Request(url, data=json.dumps(params).encode(), headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                res = json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            try:
                res = json.loads(e.read().decode())
            except Exception:
                raise TgError("%s: HTTP %s" % (method, e.code))
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            raise TgError("%s: сеть: %s" % (method, getattr(e, "reason", e)))
        if res.get("ok"):
            return res.get("result")
        if res.get("error_code") == 429:
            time.sleep(int(res.get("parameters", {}).get("retry_after", 5)) + 1)
            continue
        raise TgError("%s: %s %s" % (method, res.get("error_code"), res.get("description")))
    raise TgError("%s: слишком много повторов (429)" % method)


def yg(*args, timeout=300):
    """Вызов `yagaza --api ...` → (код, stdout, stderr)."""
    env = dict(os.environ, YI_PLAIN="1", TERM="dumb")
    try:
        p = subprocess.run([YAGAZA, "--api", *args], capture_output=True, text=True, timeout=timeout, env=env)
        err = "\n".join(l[2:] if l[:2] in ("✗ ", "! ") else l for l in p.stderr.strip().splitlines())
        return p.returncode, p.stdout.strip(), err
    except subprocess.TimeoutExpired:
        return 1, "", "yagaza не ответил за %s с" % timeout
    except FileNotFoundError:
        return 1, "", "нет %s" % YAGAZA


def esc(s):
    return html.escape(s or "", quote=False)


def qr_png(data):
    try:
        p = subprocess.run(["qrencode", "-t", "PNG", "-s", "8", "-o", "-", data], capture_output=True, timeout=20)
        return p.stdout if p.returncode == 0 and p.stdout else None
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None


# ---------- экраны ----------

def kb(rows):
    return {"inline_keyboard": [[{"text": t, "callback_data": d, **({"style": s} if s else {})} for t, d, s in row] for row in rows]}


BACK = [("‹ Меню", "m:main", None)]


def screen_main():
    rc, out, err = yg("status")
    lines = out.splitlines()
    head = esc(lines[0].strip()) if lines else "Yagaza Kit"
    body = []
    for ln in lines[1:]:
        if "|" in ln:
            t, s = ln.split("|", 1)
            icon = "🟢" if s.startswith(("работает", "настроено", "установлен")) else ("🟡" if "частично" in s else "⚪️")
            body.append("%s <b>%s</b> — %s" % (icon, esc(t), esc(s)))
    text = "<b>Yagaza Kit</b>\n<i>%s</i>\n\n%s" % (head, "\n".join(body) or esc(err))
    return text, kb([
        [("🔑 VLESS", "v:list", "primary"), ("🛡 AmneziaWG", "a:list", "primary")],
        [("🔀 Каскад", "k:list", None), ("☁️ WARP", "w:show", None)],
        [("📨 MTProxy", "t:links", None), ("🌐 Порты", "m:ports", None)],
        [("🔄 Обновить", "m:main", None)],
    ])


# ---------- Каскад ----------

def kaskad_rules():
    rc, out, err = yg("kaskad-list")
    rules = []
    for ln in out.splitlines():
        p = ln.split("|")
        if len(p) == 5:
            rules.append({"n": p[0], "proto": p[1], "lport": p[2], "host": p[3], "tport": p[4]})
    return rules


def rule_text(r):
    return "%s/%s → %s:%s" % (r["lport"], r["proto"], r["host"], r["tport"])


def screen_kaskad():
    rules = kaskad_rules()
    rows = [[("🔀 " + rule_text(r), "k:show:%s:%s" % (r["n"], r["lport"]), None)] for r in rules[:40]]
    rows.append([("➕ Добавить переброс", "k:add", "success")])
    rows.append(BACK)
    text = ("<b>Каскад</b> · перебросов: %d\nВходящий порт этого сервера → другой сервер.\n"
            "Нажмите на переброс, чтобы удалить." % len(rules))
    return text, kb(rows)


def kaskad_find(n, lport):
    for r in kaskad_rules():
        if r["n"] == n and r["lport"] == lport:
            return r
    return None


def screen_kaskad_rule(n, lport):
    r = kaskad_find(n, lport)
    if not r:
        return screen_kaskad()
    return ("<b>Переброс</b>\n<code>%s</code>" % esc(rule_text(r)),
            kb([[("🗑 Удалить", "k:del:%s:%s" % (n, lport), "danger")], [("‹ Назад", "k:list", None)]]))


KASKAD_HELP = ("Пришлите одной строкой: <b>протокол порт куда порт</b>\n"
               "Например: <code>tcp 443 1.2.3.4 443</code> или <code>both 51820 nl.example.com 51820</code>\n"
               "Протокол: tcp, udp или both. Порт SSH и занятые программами порты бот не перебрасывает.")


# ---------- WARP ----------

def warp_state():
    rc, out, err = yg("warp-state")
    lines = out.splitlines()
    if not lines or lines[0] == "none":
        return None
    st = lines[0].split("|") + ["", "", "", ""]
    return {"on": st[0] == "on", "ip": st[1], "colo": st[2], "port": st[3], "vless": "vless_via_warp" in lines}


def screen_warp(note=""):
    s = warp_state()
    if s is None:
        return ("<b>☁️ WARP</b>\n\nНе установлен. Поставьте в меню сервера: <code>yagaza</code> → WARP.", kb([BACK]))
    if s["on"]:
        text = ("<b>☁️ WARP</b> — 🟢 включён\nВыход: <code>%s</code> (%s)\nSOCKS5: 127.0.0.1:%s"
                % (esc(s["ip"]), esc(s["colo"]), esc(s["port"])))
        btn = ("⏹ Выключить", "w:off", "danger")
    else:
        text = "<b>☁️ WARP</b> — ⚪️ выключен\nSOCKS5: 127.0.0.1:%s" % esc(s["port"])
        btn = ("▶️ Включить", "w:on", "success")
    if s["vless"]:
        text += "\n\n⚠️ VLESS выпускает клиентов через WARP: без WARP у них пропадёт интернет."
    if note:
        text += "\n\n" + note
    return text, kb([[btn], [("🔄 Проверить", "w:show", None)], BACK])


def screen_ports():
    rc, out, err = yg("ports")
    return "<b>Порты сервера</b>\n<pre>%s</pre>" % esc((out or err)[:3800]), kb([BACK])


def screen_list(kind):
    title = "VLESS Reality" if kind == "v" else "AmneziaWG"
    rc, out, err = yg("vless-list" if kind == "v" else "awg-list")
    if rc != 0:
        return "<b>%s</b>\n\n%s\n\nУстановите в меню сервера: <code>yagaza</code>" % (title, esc(err)), kb([BACK])
    names = [n for n in out.splitlines() if n.strip()]
    rows = [[("👤 " + n, "%s:show:%s" % (kind, n), None)] for n in names[:40]]
    rows.append([("➕ Добавить", kind + ":add", "success")])
    rows.append(BACK)
    return "<b>%s</b> · клиентов: %d\nНажмите на клиента — пришлю ключ и QR." % (title, len(names)), kb(rows)


def screen_client(kind, name):
    return ("<b>%s</b>: %s" % ("VLESS" if kind == "v" else "AmneziaWG", esc(name)),
            kb([[("📤 Прислать ключ", "%s:send:%s" % (kind, name), "primary")],
                [("🗑 Удалить", "%s:del:%s" % (kind, name), "danger")],
                [("‹ Назад", kind + ":list", None)]]))


def screen_confirm_del(kind, name):
    return ("Удалить клиента <b>%s</b>? Его ключ перестанет работать." % esc(name),
            kb([[("Да, удалить", "%s:delok:%s" % (kind, name), "danger"), ("Отмена", "%s:show:%s" % (kind, name), None)]]))


# ---------- отправка ключей ----------

def send_key(chat_id, kind, name):
    if kind == "v":
        rc, link, err = yg("vless-link", name)
        if rc != 0:
            return call("sendMessage", {"chat_id": chat_id, "text": "⚠️ " + (err or "ошибка")})
        cap = "🔑 <b>%s</b> — VLESS Reality\n<code>%s</code>\n\nИмпорт: Happ, v2rayN, Hiddify, Streisand." % (esc(name), esc(link))
        png = qr_png(link)
        if png and len(cap) <= 1024:
            call("sendPhoto", {"chat_id": chat_id, "caption": cap, "parse_mode": "HTML", "protect_content": True},
                 files={"photo": ("qr.png", png, "image/png")})
        else:
            call("sendMessage", {"chat_id": chat_id, "text": cap, "parse_mode": "HTML", "protect_content": True})
    else:
        rc, path, err = yg("awg-file", name)
        if rc != 0:
            return call("sendMessage", {"chat_id": chat_id, "text": "⚠️ " + (err or "ошибка")})
        with open(path, "rb") as f:
            data = f.read()
        call("sendDocument", {"chat_id": chat_id, "caption": "🛡 %s — AmneziaWG. Импорт в AmneziaVPN / AmneziaWG." % name,
                              "protect_content": True}, files={"document": (name + ".conf", data, "text/plain")})
        png = qr_png(data.decode())
        if png:
            call("sendPhoto", {"chat_id": chat_id, "caption": "QR для %s" % name, "protect_content": True},
                 files={"photo": ("qr.png", png, "image/png")})


def send_mtproxy(chat_id):
    rc, out, err = yg("mtproxy-links")
    if rc != 0:
        text = "📨 MTProxy\n\n%s" % esc(err)
    else:
        text = "📨 <b>MTProxy</b>\n" + "\n".join("<code>%s</code>" % esc(l) for l in out.splitlines() if l.strip())
    call("sendMessage", {"chat_id": chat_id, "text": text, "parse_mode": "HTML", "protect_content": True})


# ---------- обработка ----------

def show(chat_id, msg_id, text_markup):
    text, markup = text_markup
    params = {"chat_id": chat_id, "text": text, "parse_mode": "HTML", "reply_markup": markup,
              "link_preview_options": {"is_disabled": True}}
    if msg_id:
        try:
            call("editMessageText", dict(params, message_id=msg_id))
            return
        except TgError as e:
            if "not modified" in str(e):
                return
    call("sendMessage", params)


def on_message(m):
    chat, user = m.get("chat", {}), m.get("from", {})
    uid, cid = user.get("id"), chat.get("id")
    if uid not in ADMINS or chat.get("type") != "private":
        if chat.get("type") == "private":
            call("sendMessage", {"chat_id": cid, "text": "⛔ Нет доступа."})
        return
    text = (m.get("text") or "").strip()
    if uid in PENDING and text and not text.startswith("/") and PENDING[uid] == "k":
        PENDING.pop(uid)
        args = text.split()
        if len(args) != 4:
            call("sendMessage", {"chat_id": cid, "text": "Нужно 4 значения через пробел.\n\n" + KASKAD_HELP, "parse_mode": "HTML"})
            PENDING[uid] = "k"
            return
        call("sendMessage", {"chat_id": cid, "text": "⏳ Добавляю переброс…"})
        rc, out, err = yg("kaskad-add", args[0].lower(), args[1], args[2], args[3])
        if rc != 0:
            call("sendMessage", {"chat_id": cid, "text": "⚠️ Не добавил: %s" % (err or "ошибка")})
        else:
            warn = "\n".join(l[6:] for l in out.splitlines() if l.startswith("warn: "))
            call("sendMessage", {"chat_id": cid, "text": "✅ Переброс добавлен." + ("\n⚠️ " + warn if warn else "")})
        show(cid, None, screen_kaskad())
        return
    if uid in PENDING and text and not text.startswith("/"):
        kind = PENDING.pop(uid)
        call("sendMessage", {"chat_id": cid, "text": "⏳ Добавляю %s…" % text})
        rc, out, err = yg("vless-add" if kind == "v" else "awg-add", text)
        if rc != 0:
            call("sendMessage", {"chat_id": cid, "text": "⚠️ Не добавил: %s" % (err or "ошибка")})
        else:
            send_key(cid, kind, text)
        show(cid, None, screen_list(kind))
        return
    PENDING.pop(uid, None)
    show(cid, None, screen_main())


def on_callback(q):
    uid = q.get("from", {}).get("id")
    msg = q.get("message") or {}
    cid, mid = msg.get("chat", {}).get("id"), msg.get("message_id")
    if uid not in ADMINS or msg.get("chat", {}).get("type") != "private":
        call("answerCallbackQuery", {"callback_query_id": q["id"], "text": "Нет доступа", "show_alert": True})
        return
    data = q.get("data") or ""
    parts = data.split(":", 2)
    kind, act, name = (parts + ["", "", ""])[:3]
    note = None
    answered = False

    def answer_now(text):  # долгие действия: ответить на нажатие сразу, иначе запрос устареет
        nonlocal answered
        call("answerCallbackQuery", {"callback_query_id": q["id"], "text": text})
        answered = True

    try:
        if kind == "k":
            if act == "list":
                show(cid, mid, screen_kaskad())
            elif act == "add":
                PENDING[uid] = "k"
                call("sendMessage", {"chat_id": cid, "text": KASKAD_HELP, "parse_mode": "HTML"})
            elif act in ("show", "del", "delok") and ":" in name:
                n, lport = name.split(":", 1)
                r = kaskad_find(n, lport)
                if not r:
                    note = "Этого переброса уже нет"
                    show(cid, mid, screen_kaskad())
                elif act == "show":
                    show(cid, mid, screen_kaskad_rule(n, lport))
                elif act == "del":
                    show(cid, mid, ("Удалить переброс <code>%s</code>?" % esc(rule_text(r)),
                                    kb([[("Да, удалить", "k:delok:%s:%s" % (n, lport), "danger"),
                                         ("Отмена", "k:show:%s:%s" % (n, lport), None)]])))
                else:
                    answer_now("⏳ Удаляю…")
                    rc, out, err = yg("kaskad-del", n)
                    show(cid, mid, screen_kaskad())
                    if rc != 0:
                        call("sendMessage", {"chat_id": cid, "text": "⚠️ " + (err or "ошибка")})
            return
        if kind == "w":
            if act == "show":
                show(cid, mid, screen_warp())
            elif act == "on":
                answer_now("⏳ Включаю WARP…")
                rc, out, err = yg("warp-on", timeout=90)
                show(cid, mid, screen_warp("" if rc == 0 else "⚠️ " + esc(err or "ошибка")))
            elif act == "off":
                s = warp_state()
                if s and s["vless"]:
                    show(cid, mid, ("Выключить WARP? У клиентов VLESS пропадёт интернет, пока WARP не включат.",
                                    kb([[("Да, выключить", "w:offok", "danger"), ("Отмена", "w:show", None)]])))
                else:
                    answer_now("⏳ Выключаю…")
                    rc, out, err = yg("warp-off", timeout=60)
                    show(cid, mid, screen_warp("" if rc == 0 else "⚠️ " + esc(err or "ошибка")))
            elif act == "offok":
                answer_now("⏳ Выключаю…")
                rc, out, err = yg("warp-off", timeout=60)
                show(cid, mid, screen_warp("" if rc == 0 else "⚠️ " + esc(err or "ошибка")))
            return
        if data == "m:main":
            show(cid, mid, screen_main())
        elif data == "m:ports":
            show(cid, mid, screen_ports())
        elif data == "t:links":
            send_mtproxy(cid)
        elif kind in ("v", "a") and act == "list":
            show(cid, mid, screen_list(kind))
        elif kind in ("v", "a") and act == "add":
            PENDING[uid] = kind
            call("sendMessage", {"chat_id": cid, "text": "Пришлите имя нового клиента (латиница, цифры, - _), например: phone2"})
        elif kind in ("v", "a") and act == "show" and name:
            show(cid, mid, screen_client(kind, name))
        elif kind in ("v", "a") and act == "send" and name:
            send_key(cid, kind, name)
        elif kind in ("v", "a") and act == "del" and name:
            show(cid, mid, screen_confirm_del(kind, name))
        elif kind in ("v", "a") and act == "delok" and name:
            answer_now("⏳ Удаляю…")
            rc, out, err = yg("vless-del" if kind == "v" else "awg-del", name)
            show(cid, mid, screen_list(kind))
            if rc != 0:
                call("sendMessage", {"chat_id": cid, "text": "⚠️ " + (err or "ошибка")})
    finally:
        if not answered:
            call("answerCallbackQuery", {"callback_query_id": q["id"], **({"text": note} if note else {})})


def read_offset():
    try:
        with open(OFFSET_FILE) as f:
            return int(f.read().strip() or 0)
    except (OSError, ValueError):
        return 0


def write_offset(n):
    tmp = OFFSET_FILE + ".tmp"
    with open(tmp, "w") as f:
        f.write(str(n))
    os.replace(tmp, OFFSET_FILE)


def stop(*_):
    global RUNNING
    RUNNING = False


def main():
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        me = call("getMe")
        log("бот @%s запущен, админов: %d" % (me.get("username"), len(ADMINS)))
        call("setMyCommands", {"commands": [{"command": "start", "description": "Меню сервера"}]})
    except TgError as e:
        log("старт: %s" % e)
    offset = read_offset()
    while RUNNING:
        try:
            updates = call("getUpdates", {"offset": offset, "timeout": 50,
                                          "allowed_updates": ["message", "callback_query"]}, timeout=70)
        except TgError as e:
            msg = str(e)
            if " 409 " in msg:
                log("409: этот токен уже опрашивает другая программа или задан вебхук — нужен отдельный бот. Жду 60 с.")
                time.sleep(60)
            else:
                log("getUpdates: %s" % msg)
                time.sleep(5)
            continue
        for u in updates or []:
            uid = u.get("update_id", 0)
            if uid < offset:
                continue
            try:
                if "message" in u:
                    on_message(u["message"])
                elif "callback_query" in u:
                    on_callback(u["callback_query"])
            except Exception as e:  # одно сломанное обновление не должно останавливать бота
                log("обновление %s: %s" % (uid, e))
            offset = uid + 1
            write_offset(offset)
    log("остановлен")


if __name__ == "__main__":
    main()
