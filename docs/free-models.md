# Безкоштовні моделі: що налаштовано і як воно відпрацювало

Знімок станом на **6.10.2026**. Безкоштовні моделі з'являються й зникають без попередження. Тому перед зміною ланцюжків
перевір актуальні списки:

- OpenRouter — `openclaw models list --all --plain | grep ':free$'`;
- Nous — `https://portal.nousresearch.com/api/nous/recommended-models`.

## Ланцюжки після налаштування

Без ключа Gemini (лише Nous / OpenRouter / Copilot):

| Агент | Основна | Запасні (по черзі) |
|---|---|---|
| Hermes | `nous / poolside/laguna-s-2.1:free` | nous: `stepfun/step-3.7-flash:free`, `poolside/laguna-xs-2.1:free`, `meituan/longcat-2.5-preview:free` → copilot: `gpt-5-mini`, `gpt-4.1` |
| OpenClaw | `openrouter/nvidia/nemotron-3-super-120b-a12b:free` | `laguna-s-2.1`, `gemma-4-31b-it`, `nemotron-3.5-lightning`, `nemotron-3-ultra-550b`, `laguna-xs-2.1`, `north-mini-code`, `dots-3-note-preview` (усі `:free` на OpenRouter), `openrouter/free` |

З ключем Google AI Studio (остаточно налаштовано 6.10.2026). Gemini — **лише запасна**:

| Агент | Основна | Запасні (по черзі) |
|---|---|---|
| Hermes | `nous / poolside/laguna-s-2.1:free` | gemini 3.5 Flash → copilot gpt-5-mini → nous step-3.7-flash → gemini 3.8 Flash → nous laguna-xs → copilot gpt-4.1 → gemini 2.5 Pro → nous longcat. Плюс `agent.api_max_retries: 1` |
| OpenClaw | `openrouter/nvidia/nemotron-3-super-120b-a12b:free` | `google/gemini-3.5-flash` → `laguna-s-2.1` → `google/gemini-3.8-flash` → решта OpenRouter `:free` |

Чому Gemini не основна:
- Безкоштовну квоту ключа AI Studio вичерпали приблизно 20 запитів за день: далі `429 You exceeded your current quota` на обидві Flash-моделі. Hermes сам пише про це: «free tier is exhausted in a handful of messages and cannot sustain an agent session».
- 3.8 Flash ще й часто відповідає `503 high demand` (40–109 с на відповідь). 3.5 Flash у тих самих пробах відмов не дала.
- `google/gemini-2.5-pro` OpenClaw у своєму каталозі не знайшов (`NOT_FOUND`), у Hermes працює.

**Чергування провайдерів.** На 429 і Hermes, і OpenClaw ставлять паузу всьому провайдеру, а не одній моделі
(у Nous бачили 34 хв). Тому в ланцюжку провайдери чергуються. Ліміт OpenRouter до того ж спільний для всіх його `:free`-моделей.
Перевірено: коли Gemini віддав 429, OpenClaw за 2.7 с перейшов на `nemotron-3-super:free`, і задача з `exec` пройшла.

Платний `openrouter/auto` в OpenClaw лишився аліасом `OpenRouter` для ручного перемикання. Він коштує ≈ $0.002–0.01 за запит.

## Ліміти безкоштовних тарифів

| Джерело | Ліміт | Примітка |
|---|---|---|
| Nous Portal (`:free`, `stealth/`) | fair-share, буває 429 з `retry_after` ≈ 20 с | Hermes сам повторює запит і переходить на запасні |
| OpenRouter `:free` | 20 запитів/хв; 50/день, або 1000/день після разової покупки $10 | Ліміт спільний для всіх `:free`-моделей акаунта |
| GitHub Copilot Free | 200 чат-запитів/міс. | Квота оновлюється 1-го числа |
| NVIDIA Build | 40 запитів/хв на ключ, без денного ліміту | Найкращий кандидат в основні після додавання ключа |
| Google AI Studio | ліміти видно в AI Studio | Запити йдуть на навчання |

## Результати тестів

### Сценарій перевірки мостів, швидкий прогін (6.10, 12:50)

| Кейс | Агент | Що перевіряє | Результат | Час | Вартість |
|---|---|---|---|---|---|
| S-H1 | Hermes | статус, модель, провайдер | PASS | 19 с | 0 |
| S-O1 | OpenClaw | статус гейтвея | PASS | 15 с | 0 |
| S-O2 | OpenClaw | Windows node спарений і підключений | PASS | 34 с | 0 |
| F1 | Hermes | прошивка: знайти параметри VTX у коді (з пасткою) | PASS | 82 с | 0 |
| U1 | Hermes | уроки: шлях з кирилицею, підрахунок, `<title>` | PASS | 128 с | 0 |
| D1 | OpenClaw | SDR-журнал: які прогони впали, тривалість | PASS | 20 с | $0.0051* |
| W1 | OpenClaw | прочитати файл Windows через node | PASS (після ручного дозволу в треї) | 22 с | $0.0017* |

\* Під час прогону OpenClaw ще працював на платному `openrouter/auto`. Зараз основна модель безкоштовна.

### Живі виклики моделей під час налаштування

| Агент | Модель | Викликів | Успішно | Час відповіді | Примітка |
|---|---|---|---|---|---|
| Hermes | nous `laguna-s-2.1:free` | 7 | 7 | 12–59 с | у тому числі з інструментами (читання файлів) |
| Hermes | nous `step-3.7-flash:free` | 2 | 2 | 30–48 с | у тому числі з інструментами |
| Hermes | copilot: `gpt-5-mini`, `gpt-4.1`, `gpt-5.4-mini`, `claude-haiku-4.5`, `gemini-3.8-flash`, `kimi-k3` | 6 | 6 | 28–33 с | витрачають 200/міс. |
| Hermes | nous `nemotron-3-super:free`, `stealth/space-bunny-alpha` | 2 | 0 | — | цих моделей на Nous немає (404) |
| OpenClaw | `nemotron-3-super-120b:free` | 2 | 2 | 8 с | з викликом `exec`, $0 |
| OpenClaw | `openrouter/auto` (платна) | 2 | 2 | 6–10 с | $0.002–0.01 |
| OpenClaw | `openclaw models scan`: проби 20 безкоштовних моделей OpenRouter, два прогони | 25 | 12 | 0.1–9 с | швидкі відмови — rate limit, не відсутність інструментів |

### Висновок про стабільність

- **Самі мости жодного разу не впали.** Помилки моделей повертаються як помилки, таймаути обробляються. Процес Hermes
  при таймауті вбивається разом з дочірніми.
- **Hermes на Nous стабільний, але повільний:** 1–2 хв на задачу з файлами. На 429 він сам чекає і повторює запит, далі
  в ланцюжку ще 3 моделі Nous і 2 Copilot.
- **OpenClaw на OpenRouter `:free` найвразливіший.** Під навантаженням майже половина проб безкоштовних моделей отримала
  відмову, а денний ліміт 50 запитів вичерпується за кілька задач. Ланцюжок з 9 моделей згладжує відмови, але не обходить
  денний ліміт. Найбільше стабільності додадуть ключ **NVIDIA Build** (без денного ліміту) або разове поповнення OpenRouter на $10.
