# План розгортання для Claude Code

Мета: на Windows 11 розгорнути OpenClaw (WSL) і Hermes (Windows) на безкоштовних моделях, підключити
до них Telegram-ботів і MCP-мости в Claude Code. Користувач робить лише кроки з розділу «Що робиш ти»
в [README.md](README.md). Решта на тобі.

## Правила

- **Користувача залучай тільки для:** UAC/перезавантаження, входу в браузері (Nous Portal, GitHub, Claude),
  кліків у майстрі/діалогах трею OpenClaw, створення ботів у @BotFather, заповнення `keys.env`.
  Решту роби сам. Перед кожним таким кроком коротко скажи, що саме натиснути, і чекай.
- **Секрети:** ніколи не проси вставити ключ чи токен у чат. Ключі йдуть лише через `keys.env` і
  скрипти з `scripts/`. Не виводь значення ключів і не читай сховища облікових даних агентів
  (SQLite OpenClaw, `auth.json` Hermes). Імена змінних показувати можна.
- **WSL:** у дистрибутив заходь тільки як `wsl.exe -d OpenClawGateway -e <команда>`. Без `-e` аргументи
  проходять через shell дистрибутива, і змінні `$X` розкриваються не там, де треба.
- Після кожної фази виконуй її перевірку. Якщо перевірка не пройшла, спершу дивись [docs/pitfalls.md](docs/pitfalls.md).
- Нічого не пуш у git з `keys.env`, `reports/` чи `*.bak-*` (вони в `.gitignore`, але все одно перевір `git status`).

## Фаза 0. Середовище

```powershell
wsl --status; winget list --id Anthropic.ClaudeCode; gh auth status; node --version; git --version
```

Потрібно: WSL 2 доступний, Node ≥ 22, `gh` залогінений. Якщо WSL не ввімкнено, це крок 1 з README (адмін + перезавантаження), попроси користувача.

## Фаза 1. OpenClaw Companion і гейтвей

```powershell
winget install -e --id OpenClaw.OpenClawCompanion
```

Запусти трей (`%LOCALAPPDATA%\OpenClawTray\OpenClaw.Tray.WinUI.exe`, якщо не стартував сам) і попроси користувача
пройти майстер у вікні трею. Майстер створює дистрибутив `OpenClawGateway` (юзер `openclaw`, systemd, порт 18789).

Перевірка (гейтвею після старту потрібно 40–60 с):

```powershell
wsl -l -v                                                             # OpenClawGateway  Running  2
wsl.exe -d OpenClawGateway -e /usr/local/bin/openclaw gateway status  # Runtime: running; Connectivity probe: ok
```

## Фаза 2. OpenClaw: робоча тека, моделі, Control UI

1. Робоча тека. Без цього ключа трей падає з «Windows node guidance could not be installed»:
   ```powershell
   wsl.exe -d OpenClawGateway -e /usr/local/bin/openclaw config set agents.defaults.workspace /home/openclaw/.openclaw/workspace
   ```
2. Ключ OpenRouter. Попроси користувача вписати `OPENROUTER_API_KEY` у `keys.env` (див. фазу 5) і запусти
   `scripts/apply-free-llm-keys.ps1`. Скрипт сам зробить `paste-api-key` в OpenClaw і пропише ключ у Hermes.
   Якщо onboard у треї вже додав OpenRouter, цей крок лише продублює профіль, і це безпечно.
3. Безкоштовна основна модель і ланцюжок. Порядок перевірено 6.10.2026. Актуальність перевір:
   `openclaw models list --all --plain | grep ':free$'`.
   ```powershell
   wsl.exe -d OpenClawGateway -e /usr/local/bin/openclaw models set openrouter/nvidia/nemotron-3-super-120b-a12b:free
   wsl.exe -d OpenClawGateway -e bash -c 'for m in "$@"; do /usr/local/bin/openclaw models fallbacks add "$m"; done' _ openrouter/poolside/laguna-s-2.1:free openrouter/google/gemma-4-31b-it:free openrouter/nvidia/nemotron-3.5-lightning:free openrouter/nvidia/nemotron-3-ultra-550b-a55b:free openrouter/poolside/laguna-xs-2.1:free openrouter/cohere/north-mini-code:free openrouter/dots-studio/dots-3-note-preview:free openrouter/free
   ```
   **Не запускай `openclaw models scan` без потреби.** Він перезаписує fallbacks своїми 6 «вибраними» моделями,
   серед яких медична й 2.6B. Після нього ланцюжок треба перебудувати.
4. Control UI. Відкрий дашборд з токеном, не показуючи токен у виводі:
   ```powershell
   $raw = (wsl -d OpenClawGateway -- bash -lc 'openclaw dashboard --json --no-open 2>/dev/null') -join "`n"
   $m = [regex]::Match($raw, 'https?://127\.0\.0\.1:18789/[^"\s]*'); if ($m.Success) { Start-Process $m.Value }
   ```

Перевірка: `openclaw models status`, де Default — `:free`-модель. Далі один хід агента з викликом інструмента:

```powershell
"Reply OPENCLAW-OK, then use a tool to run: uname -sr" | wsl.exe -d OpenClawGateway -e bash -c 'f=$(mktemp); cat > "$f"; /usr/local/bin/openclaw agent --agent main --session-key agent:main:setup-check --message-file "$f" --json --timeout 300; rm -f "$f"'
```

У JSON очікуй `"status": "ok"`, `successfulToolNames` з `exec`, `cost` 0. `--message-file /dev/stdin` під wsl.exe дає EACCES, тому через тимчасовий файл.

5. Правила роботи OpenClaw. Робоча тека `/home/openclaw/.openclaw/workspace`. Зроби копії й запиши правила через stdin:
   ```powershell
   wsl.exe -d OpenClawGateway -e bash -c 'cd ~/.openclaw/workspace && cp AGENTS.md AGENTS.md.bak && cp USER.md USER.md.bak'
   $OutputEncoding = New-Object Text.UTF8Encoding $false   # інакше PowerShell 5.1 передасть кирилицю як '?'
   (Get-Content rules\openclaw-AGENTS-append.md -Raw -Encoding UTF8) | wsl.exe -d OpenClawGateway -e bash -c 'tr -d \\015 >> ~/.openclaw/workspace/AGENTS.md'
   ```
   `USER.md` заміни на [rules/openclaw-USER.md](rules/openclaw-USER.md): підстав ім'я власника і сьогоднішню дату замість
   `YYYY-MM-DD`. У файлі з плейсхолдером директиву не можна лишати `active`. Застереження про чутливі дані — як для Hermes, у фазі 3.
   Перевірка: спитай агента, де йому можна класти файли на Windows і що потрібно перед командою на Windows.

## Фаза 3. Hermes

1. Встановлення (нативний Windows, без WSL):
   ```powershell
   iex (irm https://hermes-agent.nousresearch.com/install.ps1)
   ```
   Інший варіант — десктоп-інсталятор з https://hermes-agent.nousresearch.com. Бінарник: `%LOCALAPPDATA%\hermes\bin\hermes.exe`.
2. Вхід у Nous Portal (користувач логіниться в браузері): `hermes auth add nous`.
   Copilot як останній запасний варіант: Hermes зазвичай сам підхоплює токен `gh`. Перевір `hermes status`
   (рядок Providers). Якщо GitHub Copilot там немає, виконай `hermes auth add copilot`.
3. Основна модель — безкоштовна модель Nous. Актуальний список:
   `https://portal.nousresearch.com/api/nous/recommended-models` → `freeRecommendedModels`.
   ```powershell
   hermes config set model.provider nous
   hermes config set model.default poolside/laguna-s-2.1:free
   ```
   **ID моделей OpenRouter на Nous Portal не працюють** (404). Беріть лише ID з `freeRecommendedModels`.
4. Ланцюжок запасних моделей. Додай у `%LOCALAPPDATA%\hermes\config.yaml` **окремим блоком верхнього рівня**,
   після кінця блоку `model:`, перед `# Named provider overrides`. Якщо вставити посередині `model:`,
   Hermes перестане стартувати.
   **Провайдери в ланцюжку мають чергуватися.** На 429 Hermes ставить паузу всьому провайдеру (у Nous бачили 34 хв),
   тож дві моделі одного провайдера поспіль марні. Без ключа Gemini:
   ```yaml
   fallback_providers:
     - provider: "copilot"
       model: "gpt-5-mini"
     - provider: "nous"
       model: "stepfun/step-3.7-flash:free"
     - provider: "copilot"
       model: "gpt-4.1"
     - provider: "nous"
       model: "poolside/laguna-xs-2.1:free"
   ```
   Після фази 5 з ключем Gemini скрипт додасть моделі `gemini` на початок. Розстав їх через одну між `copilot` і `nous`,
   як у [docs/free-models.md](docs/free-models.md).
   Ще в секції `agent:` того ж файлу постав `api_max_retries: 1`: інакше Hermes тричі повторює модель, що відповідає 429/503,
   замість того щоб одразу перейти на запасну.
5. Правила роботи й доступ до файлів. Допиши вміст [rules/hermes-SOUL-append.md](rules/hermes-SOUL-append.md) у кінець
   `%LOCALAPPDATA%\hermes\SOUL.md`. Перший абзац обов'язковий: без нього слабкі безкоштовні моделі кажуть «не можу читати файли».
   Спитай власника, які теки й проєкти дописати на місці коментаря `<!-- … -->`. IP-адреси серверів, токени, ID в Telegram
   у правила не вписуй: системний промпт іде на безкоштовні моделі, які можуть зберігати запити й навчатися на них.

Перевірка:

```powershell
hermes config check
"Can you read files on this pc? Prove it: list the names of 3 folders in $env:USERPROFILE\Desktop." | hermes chat --query-file - -Q --source tool --max-turns 6
```

Перевірка правил: на питання «якою мовою відповідаєш і куди кладеш допоміжні файли» Hermes має назвати українську і теки `_CLAUDE`.

## Фаза 4. MCP-мости в Claude Code

```powershell
$dst = "$env:USERPROFILE\.claude\mcp-servers"
foreach ($n in 'hermes-mcp','openclaw-mcp') {
  New-Item -ItemType Directory -Force "$dst\$n" | Out-Null
  Copy-Item "mcp-servers\$n\*" "$dst\$n\" -Force
  Push-Location "$dst\$n"; npm install --no-audit --no-fund; Pop-Location
}
claude mcp add --scope user hermes   -- node "$dst\hermes-mcp\index.mjs"
claude mcp add --scope user openclaw -- node "$dst\openclaw-mcp\index.mjs"
node "$dst\hermes-mcp\e2e.mjs"; node "$dst\openclaw-mcp\e2e.mjs"
```

Перевірка: обидва e2e закінчуються `*-MCP-OK` з `isError=false`, а рядок `[hermes: model=…]` / `[openclaw: model=…]`
показує безкоштовну модель. Нові інструменти з'являться в Claude Code після перезапуску сесії або `/mcp`.

**Правило делегування для Claude.** Саме воно дає економію підписки: Claude віддає рутину Hermes і OpenClaw, а сам вирішує й перевіряє.
Покажи власнику [rules/claude-CLAUDE-append.md](rules/claude-CLAUDE-append.md), отримай згоду і допиши файл у кінець
`%USERPROFILE%\.claude\CLAUDE.md` (немає — створи). Якщо розділ «Делегування Hermes і OpenClaw» там уже є, не дублюй.

```powershell
$g = "$env:USERPROFILE\.claude\CLAUDE.md"
if (-not (Test-Path $g) -or -not (Select-String -Path $g -Pattern 'Делегування Hermes і OpenClaw' -Quiet)) {
  Add-Content -Path $g -Value (Get-Content rules\claude-CLAUDE-append.md -Raw -Encoding UTF8) -Encoding UTF8
}
```

## Фаза 5. Ключі LLM (за бажанням користувача, але OpenRouter — бажано)

Попроси скопіювати `keys.env.example` → `keys.env` і вписати ключі. Посилання на реєстрацію є у файлі.

```powershell
powershell -ExecutionPolicy Bypass -File scripts\apply-free-llm-keys.ps1 -DryRun   # лише перевірка ключів
powershell -ExecutionPolicy Bypass -File scripts\apply-free-llm-keys.ps1
```

Скрипт робить резервні копії конфігурацій і живу перевірку кожної моделі в кожному агенті. Основною він ставить найсильнішу модель,
що пройшла перевірку (NVIDIA → Gemini → Z.ai), стирає застосовані ключі з `keys.env` і пише звіт у `reports\`. Покажи користувачу
таблицю зі звіту.

## Фаза 6. Telegram-боти

Попроси створити двох ботів у @BotFather і вписати в `keys.env` `OPENCLAW_TELEGRAM_BOT_TOKEN`, `HERMES_TELEGRAM_BOT_TOKEN`,
`TELEGRAM_OWNER_ID`. Потім:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup-telegram-bots.ps1 -DryRun   # getMe: імена ботів
powershell -ExecutionPolicy Bypass -File scripts\setup-telegram-bots.ps1
```

Перевірка: користувач пише `/start` обом ботам і отримує відповідь. Якщо бот OpenClaw надсилає код pairing:

```powershell
wsl.exe -d OpenClawGateway -e /usr/local/bin/openclaw pairing list telegram
wsl.exe -d OpenClawGateway -e /usr/local/bin/openclaw pairing approve telegram <код>
```

Стан: `openclaw channels status` (WSL) і `hermes gateway status` (Windows).

## Фаза 7. Підсумок для користувача

Покажи таблицю: компонент | стан | модель | що лишилось зробити користувачу. Назви, які моделі безкоштовні й з якими лімітами
(див. [docs/free-models.md](docs/free-models.md)). Окремо нагадай про безпеку з README.

## Відкат

- Hermes: `%LOCALAPPDATA%\hermes\config.yaml.bak-<час>` і `.env.bak-<час>` (створюють скрипти).
- OpenClaw: `~/.openclaw/openclaw.json.bak-<час>` у WSL; ключі: `openclaw models auth list` / `logout`.
- MCP: `claude mcp remove hermes -s user`, `claude mcp remove openclaw -s user`.
