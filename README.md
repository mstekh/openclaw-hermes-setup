# OpenClaw + Hermes на Windows: від WSL до Telegram-ботів

Цей репозиторій розгортає на Windows 11 двох AI-агентів:

- **OpenClaw** працює в WSL. Його ставить трей-застосунок OpenClaw Companion, з Windows він спілкується через спарений Windows node.
- **Hermes Agent** (Nous Research) працює нативно на Windows і має доступ до файлів ПК.

Обидва агенти працюють на **безкоштовних моделях** із запасними ланцюжками. До кожного підключається окремий **Telegram-бот**, і обидва стають доступні з **Claude Code** через інструменти `ask_hermes` / `ask_openclaw` (MCP).

Роботу поділено так: **ти робиш лише те, що вимагає людини** (права адміністратора, вхід у браузері, створення ботів, ключі). Усе інше робить Claude Code за файлом [CLAUDE.md](CLAUDE.md).

---

## Що робиш ти (≈ 20 хвилин активних дій)

### 1. Увімкнути WSL (PowerShell **від адміністратора**, потім перезавантаження)

```powershell
wsl --install --no-distribution
```

Після команди перезавантаж ПК. Дистрибутив Linux ставити не треба, його створить OpenClaw Companion.

### 2. Поставити інструменти (звичайний PowerShell)

```powershell
winget install -e --id Anthropic.ClaudeCode; winget install -e --id Git.Git; winget install -e --id GitHub.cli; winget install -e --id OpenJS.NodeJS
```

Закрий і знову відкрий PowerShell, щоб підхопились нові шляхи.

### 3. Увійти в акаунти (відкриється браузер)

```powershell
gh auth login      # GitHub.com -> HTTPS -> Login with a web browser
claude             # перший запуск попросить увійти в акаунт Claude; потім /exit
```

### 4. Забрати репозиторій і віддати роботу Claude

```powershell
gh repo clone mstekh/openclaw-hermes-setup; cd openclaw-hermes-setup; claude
```

У Claude Code напиши: **«Налаштуй усе за CLAUDE.md»**.

### 5. Під час роботи Claude попросить тебе про кілька речей

| Коли | Що зробити | Навіщо |
|---|---|---|
| Після встановлення OpenClaw Companion | У вікні майстра в треї пройти кроки встановлення (Next / Install) | Майстер створює WSL-дистрибутив `OpenClawGateway` і спарює Windows node |
| Під час встановлення Hermes | Увійти в **Nous Portal** у браузері | Безкоштовні моделі Hermes ідуть через Nous Portal |
| Коли дійде до ключів | Скопіювати `keys.env.example` → `keys.env` і вписати ключі за посиланнями у файлі | Мінімум — `OPENROUTER_API_KEY`; решта (NVIDIA, Gemini, Z.ai…) додає моделей і стабільності |
| Коли дійде до ботів | У [@BotFather](https://t.me/BotFather) створити **двох** ботів (`/newbot`), вписати токени й свій ID (від [@userinfobot](https://t.me/userinfobot)) у `keys.env` | Один бот для OpenClaw, другий для Hermes |
| Наприкінці | Написати `/start` обом ботам | Перевірка, що боти відповідають саме тобі |
| Коли OpenClaw читає файли Windows | Натиснути «Дозволити» в діалозі трею | Кожну команду на Windows через node підтверджує людина |

**Ключі й токени не вставляй у чат.** Вписуй їх лише в `keys.env`. Файл не потрапляє в git, а після застосування скрипти стирають з нього записане.

---

## Що робить Claude

1. Ставить OpenClaw Companion і чекає, поки запуститься гейтвей.
2. Налаштовує OpenClaw:
   - безкоштовна основна модель і ланцюжок запасних;
   - робоча тека агента;
   - Control UI з токеном.
3. Ставить Hermes і налаштовує його:
   - безкоштовні моделі Nous із запасними;
   - GitHub Copilot як останній запасний варіант;
   - доступ до файлів ПК (`SOUL.md`).
4. Встановлює MCP-мости `hermes-mcp` і `openclaw-mcp` у Claude Code та проганяє їхні e2e-тести.
5. Запускає `scripts/apply-free-llm-keys.ps1`. Скрипт розкладає ключі в обидва агенти, перевіряє кожну модель живим запитом і перебудовує ланцюжки.
6. Запускає `scripts/setup-telegram-bots.ps1`. Скрипт підключає ботів і дозволяє писати їм лише тобі.
7. Перевіряє все наприкінці й показує таблицю стану.

## Структура

```
CLAUDE.md                     покроковий план для Claude Code (команди, перевірки, відкат)
keys.env.example              шаблон ключів LLM і токенів ботів (копія keys.env — у .gitignore)
scripts/
  apply-free-llm-keys.ps1     ключі LLM -> Hermes + OpenClaw, живі перевірки, ланцюжки моделей
  setup-telegram-bots.ps1     два Telegram-боти: OpenClaw і Hermes, доступ лише власнику
mcp-servers/
  hermes-mcp/                 MCP-міст: ask_hermes, hermes_status
  openclaw-mcp/               MCP-міст: ask_openclaw, openclaw_status
docs/
  free-models.md              які безкоштовні моделі працюють і результати тестів
  pitfalls.md                 пастки, на які вже наступили, і як їх обійти
```

## Безпека

- **OpenClaw у WSL виконує команди без підтвердження** (`security=full`, `ask=off`). Там же лежать його конфігурація й токени. Не давай йому доступ до чужих людей у Telegram: `allowFrom` містить лише твій ID.
- Файли **Windows** OpenClaw читає тільки через Windows node, і кожну команду ти підтверджуєш у треї. Якщо за ПК нікого немає, запит відхиляється.
- Безкоштовні тарифи Google AI Studio, Mistral Experiment і частини моделей OpenRouter/OpenCode **використовують запити для навчання**. Не відправляй через них конфіденційне.
- Hermes без явного `yolo` не виконує небезпечні команди автоматично.
