
ARG NODE_IMAGE=docker.io/library/node:22-bookworm-slim
ARG REPO_URL=https://github.com/fedor2018/FreeDeepseekAPI.git
# Гілка, тег або повний SHA коміту. SHA — відтворювана збірка.
ARG GIT_REF=HEAD

# ── Етап 1: завантаження вихідних файлів ────────────────────────────────
FROM ${NODE_IMAGE} AS source
ARG REPO_URL
ARG GIT_REF
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
# init + fetch + FETCH_HEAD однаково працює для гілки, тегу і SHA.
RUN git init -q . \
 && git remote add origin "${REPO_URL}" \
 && git fetch --depth 1 --quiet origin "${GIT_REF}" \
 && git checkout -q --detach FETCH_HEAD \
 && git rev-parse HEAD > .git-commit \
 && rm -rf .git
# Акаунти й сесії браузера не мають потрапляти в образ навіть якщо їх
# випадково закомітили або зберегли в робочому каталозі.
RUN rm -rf .chrome-profile-deepseek .chrome-for-testing-profile-deepseek* \
 && rm -f deepseek-auth.json auth.json deepseek-accounts.json proxy-api-key.txt

# ── Етап 2: рантайм ─────────────────────────────────────────────────────
FROM ${NODE_IMAGE} AS runtime

ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=9655 \
    NON_INTERACTIVE=1 \
    DEEPSEEK_AUTH_PATH=/data/deepseek-auth.json

WORKDIR /app

# Стек для сервісу авторизації: Xvfb (віртуальний дисплей), x11vnc (VNC-доступ
# ззовнішнього клієнта), openbox (фокус вікна), chromium (вхід у chat.deepseek.com).
# UI DeepSeek китайською — без CJK-шрифту форма логіну не читається.
# fonts-wqy-zenhei обрано замість fonts-noto-cjk: ~15 МБ проти ~200 МБ.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      chromium \
      xvfb \
      x11vnc \
      openbox \
      procps \
      fonts-liberation \
      fonts-wqy-zenhei \
 && rm -rf /var/lib/apt/lists/*

# scripts/deepseek_chrome_auth.js запускає Chrome із хардкодованим набором
# аргументів, тому додати прапорці ззовні неможливо — тільки через обгортку.
# --disable-dev-shm-usage обовʼязковий: /dev/shm у Docker за замовчуванням 64 МБ.
# --no-sandbox відмикає ізоляцію рендерера; альтернатива (SUID-sandbox) не
# працює разом із no-new-privileges/cap_drop, які застосовуються до контейнера.
# Обгортка створюється під час збірки, бо код береться з GitHub, а не з контексту.
# --user-data-dir тут навмисно НЕ задається: його й так передає auth-скрипт
# у власному argv, інакше прапорці дублювалися б.
# Одинакові лапки потрібні, щоб "$@" записався у файл як є і розгорнувся
# вже під час роботи обгортки.
RUN printf '%s\n' \
 '#!/bin/sh' \
 '# Обгортка Chromium для контейнера. Прапорці передати через оточення не можна:' \
 '# auth-скрипт формує argv самостійно.' \
 '#' \
 '# Дві важливі речі:' \
 '#  1) шлях до бінарника шукається, бо він відрізняється між пакетами;' \
 '#  2) stdout/stderr пишуться в /data/chrome.log. Без цього помилки Chromium' \
 '#     губилися б: auth-скрипт запускає його з stdio: "ignore" (рядок 443),' \
 '#     тому падіння браузера виглядало б як тиша, а через 20 секунд' \
 '#     "Chrome DevTools endpoint did not start".' \
 'LOG=/data/chrome.log' \
 'mkdir -p /data && touch "$LOG" && chmod 0666 "$LOG" || LOG=/dev/null' \
 'for candidate in /usr/lib/chromium/chromium /usr/bin/chromium /usr/lib/chromium-browser/chromium-browser; do' \
 '  [ -x "$candidate" ] && break' \
 'done' \
 'if [ ! -x "$candidate" ]; then' \
 '  echo "chromium not found in image" >> "$LOG"' \
 '  ls -la /usr/lib/chromium /usr/bin/chromium* >> "$LOG" 2>&1' \
 '  exit 127' \
 'fi' \
 'exec "$candidate" --no-sandbox --disable-dev-shm-usage --disable-gpu --window-size=1400,900 "$@" >>"$LOG" 2>&1' \
 > /usr/local/bin/chromium-wrapper \
 && chmod 0755 /usr/local/bin/chromium-wrapper

# FreeDeepseekAPI не має npm-залежностей. Копіюємо лише те, що потрібно
# проксі та скрипту авторизації.
# entrypoint.sh береться з build-контексту (локальний checkout), а не з
# git clone: це наша логіка запуску, її немає в upstream-репозиторії.
COPY --from=source --chown=1000:1000 /src/package.json /src/server.js ./
COPY --from=source --chown=1000:1000 /src/lib/pow.js ./lib/pow.js
COPY --from=source --chown=1000:1000 /src/scripts/deepseek_chrome_auth.js ./scripts/
COPY --from=source --chown=1000:1000 /src/lib/pow.js /src/lib/env.js ./lib/
COPY --chown=1000:1000 entrypoint.sh ./entrypoint.sh

# Варіант A: автоматичний режим без ENTER. За DEEPSEEK_AUTO_AUTH=1 блок
# await ask(...) замінюється опитуванням readPageAuth(cdp) до появи
# token+cookie (180 × 5 с ≈ 15 хв). Збір даних (token/cookie/hif) не змінюється.
# Збірка впаде, якщо якір не знайдено — значить upstream змінив скрипт.
RUN node <<'EOF'
const fs = require('fs');
const f = 'scripts/deepseek_chrome_auth.js';
const s = fs.readFileSync(f, 'utf8');
if (s.includes('DEEPSEEK_AUTO_AUTH')) {
    console.log('AUTO patch: already present, skipping');
    process.exit(0);
}
const anchor = `    await ask(
        '[auth] Когда залогинился и отправил тестовое сообщение — нажми ENTER здесь: ',
    );`;
if (!s.includes(anchor)) {
    console.error('AUTO patch: anchor not found, upstream script changed');
    process.exit(1);
}
const repl = `    if (/^(1|true|yes|on)$/i.test(process.env.DEEPSEEK_AUTO_AUTH || '')) {
        console.log('[auth] AUTO mode: waiting for login without ENTER (up to ~15 min)...');
        for (let autoI = 0; autoI < 180; autoI++) {
            try {
                const probe = await readPageAuth(cdp);
                if (probe.token && probe.cookie) break;
            } catch {}
            await sleep(5000);
        }
    } else {
        await ask(
            '[auth] Когда залогинился и отправил тестовое сообщение — нажми ENTER здесь: ',
        );
    }`;
fs.writeFileSync(f, s.replace(anchor, repl));
console.log('AUTO patch applied');
EOF

# Каталог для auth-файлів, доступний non-root користувачу (volume у compose).
RUN mkdir -p /data && chown 1000:1000 /data \
 && chmod 0755 /app/entrypoint.sh

USER 1000:1000

# Один порт 9655 на дві послідовні фази: VNC під час входу, проксі після.
EXPOSE 9655

# /health перевіряє, чи живий процес; curl/wget в образі відсутні.
# Під час фази авторизації проксі ще не запущено, тому healthcheck показує
# unhealthy — це правильний стан, а не помилка.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["node", "-e", "const http=require('http');const req=http.get({host:'127.0.0.1',port:process.env.PORT||9655,path:'/health'},res=>{res.resume();process.exit(res.statusCode===200?0:1)});req.on('error',()=>process.exit(1));req.setTimeout(4000,()=>{req.destroy();process.exit(1)})"]

ENTRYPOINT ["/app/entrypoint.sh"]