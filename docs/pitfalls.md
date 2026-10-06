# Пастки, на які вже наступили (6.10.2026)

| Симптом | Причина | Що робити |
|---|---|---|
| `Restarting the gateway failed: Tip: openclaw gateway install …` після onboard | Майстер перезапускав гейтвей саме тоді, коли той уже перезапускався сам після зміни `gateway.tailscale` | Нічого: гейтвей піднімається сам. Перевір `openclaw gateway status` |
| `Gateway is not running` одразу після перезапуску | Гейтвею потрібно 40–60 с на старт | Зачекати хвилину |
| Control UI: `unauthorized: gateway token missing` | Дашборд відкрито без токена | `openclaw dashboard --json --no-open` → відкрити URL з `#token=…` (фаза 2 у CLAUDE.md) |
| Трей: `Windows node guidance could not be installed: Could not resolve OpenClaw agent workspace path` | Трей бере шлях з `agents.defaults.workspace`, а ключ не заданий | `openclaw config set agents.defaults.workspace /home/openclaw/.openclaw/workspace`, потім повторити крок у треї |
| Hermes: «Hermes couldn't start / stopped right after it started» | Синтаксична помилка YAML у `config.yaml`: блок верхнього рівня вставили посередині `model:` | `hermes config check`; помилку видно в `%LOCALAPPDATA%\hermes\logs\errors.log` |
| Hermes: `Model '…:free' isn't available on Nous Portal` (404) | ID моделі з OpenRouter, а провайдер — Nous | Брати ID з `portal.nousresearch.com/api/nous/recommended-models` |
| Hermes: `Billing or credits exhausted` | Платна модель на безкоштовному акаунті Nous | Лише моделі з `:free` або `stealth/` |
| Hermes у чаті каже «не можу читати файли» | Слабка модель відповіла текстом замість інструмента; довга стара сесія це підсилює | Новий чат + абзац у `SOUL.md` (фаза 3) |
| `wsl.exe -- cmd $VAR` поводиться дивно | Без `-e` аргументи йдуть через shell дистрибутива | Завжди `wsl.exe -d OpenClawGateway -e …` |
| `openclaw agent --message-file /dev/stdin`: EACCES | stdin з wsl.exe не відкривається як файл | `bash -c 'f=$(mktemp); cat > "$f"; openclaw agent … --message-file "$f"'` |
| Після `openclaw models scan` у fallbacks якісь дивні моделі | `scan` сам записує свої 6 «вибраних» (там і медична, і 2.6B) | Перебудувати ланцюжок: `models fallbacks clear` + `add` |
| `scan` каже «No tool call returned» для нормальних моделей | Відмови за 80–250 мс — це rate limit безкоштовного тарифу, а не відсутність інструментів | Повторити пізніше; вірити лише повільним відповідям |
| Hermes на Copilot швидко вичерпується | План Copilot Free: 200 чат-запитів/міс. на всі моделі | Тримати Copilot лише в кінці ланцюжка |
| OpenRouter `:free` перестають відповідати посеред дня | Ліміт 50 запитів/день без покупки кредитів (1000 — після разових $10); OpenClaw робить кілька запитів на одне завдання | Додати ключ NVIDIA Build або Gemini; або разово поповнити OpenRouter на $10 |
| Groq / Cerebras / GitHub Models відхиляють запити агента | Безкоштовні ліміти 8–30K токенів/хв або 8K на запит, а системний промпт агента більший (OpenClaw ~33K) | Не використовувати для агентів |
| Кирилиця в `.ps1` перетворюється на сміття | Windows PowerShell 5.1 читає файл без BOM як ANSI | Зберігати скрипти в UTF-8 **з BOM** |
| OpenClaw не читає файли Windows, поки ти не за ПК | Команди на Windows ідуть через node, і кожну треба схвалити в треї (`askFallback=deny`) | Або бути поруч, або свідомо внести читальні команди в allowlist node |
| Gemini Flash відповідає 40–110 с замість 5–10 | `503 This model is currently experiencing high demand` на безкоштовному тарифі; Hermes за замовчуванням тричі повторює ту саму модель | Основною брати менш завантажену модель (3.5 Flash), в Hermes поставити `agent.api_max_retries: 1`, щоб швидше перейти на запасні |
| Після `hermes config set/unset` з `config.yaml` зникли сотні рядків коментарів | `unset` видаляє ключ разом із прив'язаними до нього коментарями (приклади провайдерів у блоці `model:`) | На роботу не впливає; повна версія лишається в `config.yaml.bak-*` |
| Два агенти на одному Telegram-боті «гублять» повідомлення | Два процеси опитують один токен (409 Conflict) | Окремий бот на кожного агента |
