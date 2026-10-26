#!/bin/sh
# Єдина точка входу образу free-deepseek-api.
#
# Логіка:
#   1. /data/deepseek-auth.json валідний (token + cookie) → одразу проксі.
#   2. Немає → Xvfb + openbox + x11vnc + Chromium (вхід вручну через VNC).
#      DEEPSEEK_AUTO_AUTH=1 прибирає потребу натискати ENTER: скрипт сам
#      опитує браузер до появи token+cookie (патч застосовується під час
#      збірки, див. Dockerfile). TTY не потрібен, працює detached.
#   3. auth ok → wait 5s → закрити Chromium і X-стек → вихід: Docker
#      перезапускає контейнер (restart: unless-stopped), і Phase 0 одразу
#      йде в проксі з чистим станом.
#
# Всі логи — в /data (на хості ./data): xvfb.log, openbox.log, x11vnc.log,
# chrome.log. Порт 9334 (CDP) назовні не публікується.
set -e

AUTH_FILE="${DEEPSEEK_AUTH_PATH:-/data/deepseek-auth.json}"

auth_valid() {
    [ -s "$1" ] || return 1
    node -e '
        try {
            const c = require(process.argv[1]);
            if (c && c.token && c.cookie) process.exit(0);
        } catch {}
        process.exit(1);
    ' "$1"
}

# ── Phase 0: gate ─────────────────────────────────────────────────────
if auth_valid "$AUTH_FILE"; then
    echo "auth знайдено ($AUTH_FILE), запускаю проксі"
    exec node server.js
fi
echo "auth відсутній або неповний ($AUTH_FILE) — запускаю Chromium для входу..."

# ── VNC guard ─────────────────────────────────────────────────────────
# Без VNC_PASSWORD сервер стартує БЕЗ пароля — зручно для локального
# використання, але в мережі (порти відкрито без 127.0.0.1) це ризик:
# будь-хто в LAN зможе дивитися і клікати у вікні браузера з живою сесією.
if [ -z "$VNC_PASSWORD" ]; then
    echo "увага: VNC_PASSWORD не задано — VNC буде БЕЗ пароля." >&2
    VNC_AUTH_ARGS=""
else
    x11vnc -storepasswd "$VNC_PASSWORD" /tmp/vnc.pass
    VNC_AUTH_ARGS="-rfbauth /tmp/vnc.pass"
fi
mkdir -p /data/home /data/chrome-profile

# ── Phase 1: преflight ────────────────────────────────────────────────
# Chromium запускається з stdio: 'ignore', тому будь-яка його помилка
# доходить лише через 20 с у вигляді "Chrome DevTools endpoint did not
# start". Тому перевіряємо оточення заздалегідь і друкуємо в лог.
echo "=== Преflight ==="
echo "DISPLAY=${DISPLAY:-<НЕ ЗАДАНО>}"
echo "HOME=${HOME:-<НЕ ЗАДАНО>}"
echo "AUTO_AUTH=${DEEPSEEK_AUTO_AUTH:-<вимкнено>}"
found=""
for b in /usr/lib/chromium/chromium /usr/bin/chromium /usr/lib/chromium-browser/chromium-browser; do
    [ -x "$b" ] && found="$b"
done
if [ -n "$found" ]; then
    echo "chromium: $found"
else
    echo "!!! chromium НЕ ЗНАЙДЕНО — пакет не встановлено або інший шлях" >&2
fi
# Найчастіша причина на slim-образі: бракує бібліотек, встановлених
# через Recommends. ldd покаже їх без запуску Chromium.
if command -v ldd >/dev/null 2>&1 && [ -n "$found" ]; then
    missing=$(ldd "$found" 2>/dev/null | grep 'not found' || true)
    if [ -n "$missing" ]; then
        echo "!!! ВІДСУТНІ БІБЛІОТЕКИ (Chromium не запуститься):" >&2
        echo "$missing" >&2
    else
        echo "бібліотеки: усі знайдені"
    fi
fi
echo "==================="

# ── Phase 2: розблокування профілю ────────────────────────────────────
# Chromium не відкриє профіль, якщо в ньому лишився SingletonLock від
# попереднього процесу, вбитого разом із контейнером (Ctrl+C).
# Прибирання в auth-скрипті не допомагає: killExistingTestingChrome()
# має `if (process.platform !== 'darwin') return;`, тобто на Linux нічого
# не виконується. Контейнер щоразу свіжий — застарілих процесів у ньому
# бути не може, отже Singleton* завжди артефакт.
# rm не зачіпає Cookies/Local Storage/History — сесія авторизації лишається.
if ls /data/chrome-profile/Singleton* >/dev/null 2>&1; then
    echo "знайдено застарілі lock-файли профілю — буде очищено:" >&2
    ls -la /data/chrome-profile/Singleton* >&2
fi
rm -f /data/chrome-profile/SingletonLock \
      /data/chrome-profile/SingletonCookie \
      /data/chrome-profile/SingletonSocket

# ── Phase 3: X-стек ───────────────────────────────────────────────────
# /tmp/.X11-unix НЕ створюється в контейнері: його зазвичай створює
# systemd-tmpfiles, якого тут немає. Без нього Xvfb падає, DISPLAY :99
# недійсний, Chromium стартує й одразу виходить.
mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix
Xvfb :99 -screen 0 1400x900x24 -nolisten tcp > /data/xvfb.log 2>&1 &
# Чекаємо на реальний сокет дисплея, а не sleep: інакше openbox і
# Chromium стартують раніше, ніж X-сервер піднявся.
i=0
while [ ! -e /tmp/.X11-unix/X99 ] && [ "$i" -lt 40 ]; do
    i=$((i + 1)); sleep 0.25
done
if [ ! -e /tmp/.X11-unix/X99 ]; then
    echo "Xvfb не піднявся. /data/xvfb.log:" >&2
    cat /data/xvfb.log >&2 2>/dev/null || true
    exit 1
fi
echo "Xvfb: дисплей :99 готовий"
openbox > /data/openbox.log 2>&1 &
# -nolisten tcp тут НЕ вживається: це опція X-сервера, не x11vnc.
# Обмеження досягнення робить публікація порту на стороні хоста.
# -rfbport 9655: VNC слухає той самий порт, що й проксі. Конфлікту немає,
# бо фази послідовні — X-стек гаситься до exec node server.js, а перед
# стартом проксі чекаємо звільнення порту (див. нижче).
# shellcheck disable=SC2086: VNC_AUTH_ARGS навмисно без лапок — порожнє
# значення має зникнути, а не передатися як порожній аргумент.
x11vnc -display :99 -forever -shared -rfbport 9655 $VNC_AUTH_ARGS > /data/x11vnc.log 2>&1 &
echo "Підключіться VNC-клієнтом до 9655 і увійдіть у DeepSeek."
echo "ENTER натискати не треба: вхід виявиться автоматично."
echo "Помилки Chromium: ./data/chrome.log на хості"

# ── Phase 4: auth без ENTER ───────────────────────────────────────────
# DEEPSEEK_AUTO_AUTH=1 перемикає скрипт в авто-режим (патч під час збірки):
# замість await ask() — опитування readPageAuth(cdp) до token+cookie.
if node scripts/deepseek_chrome_auth.js; then
    echo "auth завершився успішно."
else
    {
        echo ""
        echo "=== auth-скрипт завершився помилкою. Діагностика ==="
        for f in /data/chrome.log /data/xvfb.log /data/x11vnc.log /data/openbox.log; do
            if [ -s "$f" ]; then
                echo "--- $f ---"
                tail -n 40 "$f"
            else
                echo "--- $f: порожній або відсутній ---"
            fi
        done
        echo "================================================"
    } >&2
    exit 1
fi

# ── Phase 5: перевірка результату ─────────────────────────────────────
if ! auth_valid "$AUTH_FILE"; then
    echo "auth-файл не створено або неповний ($AUTH_FILE)." >&2
    echo "Увійдіть у DeepSeek у вікні VNC, надішліть ok і перезапустіть контейнер." >&2
    exit 1
fi

# ── Phase 6: закрити браузер, звільнити ресурси, продовжити ───────────
# pkill -x (точне імʼя процесу), а не -f: підрядковий пошук по командному
# рядку міг би зачепити сторонній shell, у чиєму виклику є таке слово.
echo "auth ok, чекаю 5 с перед закриттям браузера..."
sleep 5
echo "закриваю Chromium і X-стек..."
pkill -x chromium || true
pkill -x x11vnc || true
pkill -x openbox || true
pkill -x Xvfb || true
# Замість exec node server.js — вихід: Docker перезапустить контейнер
# (restart: unless-stopped), і Phase 0 одразу піде в проксі з чистим станом:
# без залишків X-процесів, з вільним портом 9655 і свіжим healthcheck.
# Цикл очікування порту більше не потрібен — слухача в цьому процесі вже
# не буде, а новий контейнер стартує з нуля.
echo "авторизацію завершено — виходжу для перезапуску контейнера..."
exit 0
