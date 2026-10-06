<#
.SYNOPSIS
  Розкладає ключі безкоштовних LLM-провайдерів з keys.env (корінь репозиторію) у Hermes (Windows) і OpenClaw
  (WSL-дистрибутив OpenClawGateway), перевіряє кожну модель живим запитом і перебудовує ланцюжки
  запасних моделей. Основною ставить найсильнішу модель, що пройшла перевірку (NVIDIA -> Z.ai).
  Gemini основною не ставиться: безкоштовна квота AI Studio (~20 запитів/день на модель) закінчується за кілька задач агента.

.PARAMETER DryRun     Лише перевірити ключі (GET /models у провайдера) і показати план. Нічого не змінює.
.PARAMETER KeepKeys   Не стирати застосовані ключі з файлу ключів.
.PARAMETER SkipHermes / SkipOpenClaw   Не чіпати відповідного агента.

  Резервні копії: %LOCALAPPDATA%\hermes\config.yaml.bak-<час>, .env.bak-<час>,
                  ~/.openclaw/openclaw.json.bak-<час> у WSL. Звіт: reports\<час>-free-llm-keys-apply.md
#>
param(
  [string]$KeysFile = (Join-Path (Split-Path $PSScriptRoot) 'keys.env'),
  [switch]$DryRun, [switch]$KeepKeys, [switch]$SkipHermes, [switch]$SkipOpenClaw
)
$ErrorActionPreference = 'Stop'

$HermesHome = Join-Path $env:LOCALAPPDATA 'hermes'
$HermesExe  = Join-Path $HermesHome 'bin\hermes.exe'
$HermesEnv  = Join-Path $HermesHome '.env'
$HermesCfg  = Join-Path $HermesHome 'config.yaml'
$Distro     = 'OpenClawGateway'
$OcBin      = '/usr/local/bin/openclaw'
$Stamp      = Get-Date -Format 'yyyy-MM-dd-HHmm'
$ReportDir  = Join-Path (Split-Path $PSScriptRoot) 'reports'; New-Item -ItemType Directory -Force $ReportDir | Out-Null
$ReportPath = Join-Path $ReportDir "$Stamp-free-llm-keys-apply.md"
$Utf8NoBom  = New-Object System.Text.UTF8Encoding $false

# Порядок = пріоритет. primary=$true: модель цього провайдера може стати основною.
# want: бажані моделі; '*' — шаблон по списку /models провайдера. Береться не більше $maxModels.
$Catalog = @(
  @{ env='NVIDIA_API_KEY'; name='NVIDIA Build'; base='https://integrate.api.nvidia.com/v1'; primary=$true; maxModels=3
     want=@('moonshotai/kimi-k2.5','z-ai/glm-5.1','deepseek-ai/deepseek-v3.2','qwen/qwen3.5*')
     hermes='nvidia'; ocMode='plugin'; ocProvider='nvidia' },
  @{ env='GEMINI_API_KEY'; name='Google AI Studio'; base='https://generativelanguage.googleapis.com/v1beta/openai'; primary=$false; maxModels=3
     want=@('gemini-3.5-flash','gemini-3.8-flash','gemini-2.5-pro','gemini-3.5-flash-lite')
     hermes='gemini'; ocMode='plugin'; ocProvider='google' },
  @{ env='ZAI_API_KEY'; name='Z.ai'; base='https://api.z.ai/api/paas/v4'; primary=$true; maxModels=2
     want=@('glm-4.7-flash','glm-4.5-flash')
     hermes='zai'; ocMode='plugin'; ocProvider='zai' },
  @{ env='MISTRAL_API_KEY'; name='Mistral'; base='https://api.mistral.ai/v1'; primary=$false; maxModels=2
     want=@('mistral-large-latest','devstral-latest','mistral-medium-latest','mistral-small-latest')
     hermes='mistral'; ocMode='plugin'; ocProvider='mistral' },
  @{ env='OPENCODE_ZEN_API_KEY'; name='OpenCode Zen'; base='https://opencode.ai/zen/v1'; primary=$false; maxModels=3
     want=@('big-pickle','*free*')
     hermes='opencode-zen'; ocMode='plugin'; ocProvider='opencode' },
  @{ env='OLLAMA_API_KEY'; name='Ollama Cloud'; base='https://ollama.com/v1'; primary=$false; maxModels=2
     want=@('gpt-oss:120b','gemma4:31b','qwen3.8:27b')
     hermes='ollama-cloud'; ocMode='custom'; ocProvider='ollama-cloud'; ctx=128000 },
  @{ env='OPENROUTER_API_KEY'; name='OpenRouter'; base='https://openrouter.ai/api/v1'; primary=$false; maxModels=3
     want=@('nvidia/nemotron-3-super-120b-a12b:free','nvidia/nemotron-3-ultra-550b-a55b:free','google/gemma-4-31b-it:free')
     hermes='openrouter'; ocMode='plugin'; ocProvider='openrouter' }
)

# ---------- helpers ----------
function Write-Step($msg) { Write-Host "`n== $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "   OK   $msg" -ForegroundColor Green }
function Write-Bad($msg)  { Write-Host "   FAIL $msg" -ForegroundColor Yellow }

# Windows command-line quoting (MSVCRT rules) for ProcessStartInfo.Arguments.
function Join-Args([string[]]$argv) {
  ($argv | ForEach-Object {
    if ($_ -eq '') { '""' }
    elseif ($_ -match '[\s"]') { '"' + (($_ -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
    else { $_ }
  }) -join ' '
}

function Invoke-Proc([string]$file, [string[]]$argv, [string]$stdin = $null, [int]$timeoutSec = 180) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $file; $psi.Arguments = Join-Args $argv
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
  $psi.EnvironmentVariables['NO_COLOR'] = '1'; $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
  $p = [Diagnostics.Process]::Start($psi)
  if ($stdin) { $p.StandardInput.Write($stdin) }
  $p.StandardInput.Close()
  $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit($timeoutSec * 1000)) {
    & taskkill /PID $p.Id /T /F 2>$null | Out-Null
    return @{ code = -1; out = ''; err = "timeout after ${timeoutSec}s" }
  }
  return @{ code = $p.ExitCode; out = $o.Result; err = $e.Result }
}

function Invoke-OC([string[]]$argv, [string]$stdin = $null, [int]$timeoutSec = 120) {
  Invoke-Proc 'wsl.exe' (@('-d', $Distro, '-e', $OcBin) + $argv) $stdin $timeoutSec
}

function Read-KeysFile($path) {
  $keys = [ordered]@{}
  foreach ($line in [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) {
    if ($line -match '^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$') {
      $v = $Matches[2].Trim('"').Trim("'")
      if ($v) { $keys[$Matches[1]] = $v }
    }
  }
  return $keys
}

function Get-ProviderModels($entry, $key) {
  try {
    $r = Invoke-RestMethod -Uri "$($entry.base)/models" -Headers @{ Authorization = "Bearer $key" } -TimeoutSec 30
    $ids = @($r.data | ForEach-Object { ($_.id -replace '^models/', '') })
    return @{ ok = $true; ids = $ids }
  } catch {
    $status = $null
    try { $status = [int]$_.Exception.Response.StatusCode } catch {}
    return @{ ok = $false; status = $status; error = $_.Exception.Message }
  }
}

function Select-Models($entry, $available) {
  $picked = New-Object System.Collections.Generic.List[string]
  foreach ($w in $entry.want) {
    if ($available) {
      foreach ($id in $available) { if ($id -like $w -and -not $picked.Contains($id)) { $picked.Add($id) } }
    } elseif ($w -notmatch '\*') { $picked.Add($w) }
    if ($picked.Count -ge $entry.maxModels) { break }
  }
  return @($picked | Select-Object -First $entry.maxModels)
}

function Set-EnvLine($path, $name, $value) {
  $text = if (Test-Path $path) { [IO.File]::ReadAllText($path) } else { '' }
  $pattern = "(?m)^$name=.*$"
  $line = "$name=$value"
  # MatchEvaluator, бо '$' у значенні ключа інакше читався б як посилання на групу.
  if ($text -match $pattern) { $text = [regex]::Replace($text, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($m) $line }) }
  else { if ($text -and -not $text.EndsWith("`n")) { $text += "`r`n" }; $text += "$name=$value`r`n" }
  [IO.File]::WriteAllText($path, $text, $Utf8NoBom)
}

function Test-HermesModel($provider, $model) {
  $r = Invoke-Proc $HermesExe @('chat','--query-file','-','-Q','--source','tool','--max-turns','2','--provider',$provider,'-m',$model) 'Reply with exactly: OK' 150
  return @{ ok = ($r.code -eq 0 -and $r.out -match '\bOK\b'); detail = (($r.out + ' ' + $r.err).Trim() -replace '\s+', ' ') }
}

function Test-OpenClawModel($ref) {
  $r = Invoke-OC @('agent','--agent','main','--session-key',"agent:main:keytest-$Stamp",'--model',$ref,'--message','Reply with exactly: OK','--json','--timeout','180') $null 240
  $eff = [regex]::Match($r.out, '"effective"\s*:\s*\{[^}]*?"model"\s*:\s*"([^"]+)"').Groups[1].Value
  $rerouted = $r.out -match '"rerouted"\s*:\s*true'
  $ok = ($r.out -match '"status"\s*:\s*"ok"') -and -not $rerouted -and $eff -and ($ref.EndsWith($eff) -or $eff.EndsWith(($ref -split '/', 2)[1]))
  $msg = [regex]::Match($r.out, '"message"\s*:\s*"([^"]{0,200})').Groups[1].Value
  return @{ ok = $ok; detail = "effective=$eff rerouted=$rerouted $msg $($r.err.Trim())".Trim() }
}

function Wait-Gateway {
  for ($i = 0; $i -lt 24; $i++) {
    $s = Invoke-OC @('gateway','status') $null 60
    if ($s.out -match 'Connectivity probe: ok') { return $true }
    Start-Sleep -Seconds 5
  }
  return $false
}

# ---------- main ----------
if (-not (Test-Path $KeysFile)) { throw "Keys file not found: $KeysFile" }
$keys = Read-KeysFile $KeysFile
$entries = @($Catalog | Where-Object { $keys.Contains($_.env) })
if (-not $entries) { Write-Host "У $KeysFile немає жодного заповненого ключа. Нічого робити." -ForegroundColor Yellow; return }

$report = New-Object System.Collections.Generic.List[string]
$report.Add("# Застосування ключів безкоштовних LLM — $Stamp"); $report.Add('')
if ($DryRun) { $report.Add('Режим: **DryRun** (нічого не змінено).'); $report.Add('') }

# 1. Перевірка ключів і вибір моделей
$plan = @()
foreach ($e in $entries) {
  Write-Step "$($e.name): перевірка ключа"
  $list = Get-ProviderModels $e $keys[$e.env]
  # Google на невалідний ключ відповідає 400, решта — 401/403.
  if (-not $list.ok -and ($list.status -eq 400 -or $list.status -eq 401 -or $list.status -eq 403)) {
    Write-Bad "ключ відхилено (HTTP $($list.status)) — пропускаю"
    $plan += @{ e = $e; models = @(); keyOk = $false; note = "ключ відхилено (HTTP $($list.status))" }; continue
  }
  $avail = $null; if ($list.ok) { $avail = $list.ids }
  $models = Select-Models $e $avail
  if ($list.ok) { Write-Ok "ключ прийнято, моделей у провайдера: $($avail.Count)" } else { Write-Bad "список моделей недоступний ($($list.error)) — беру бажані моделі як є" }
  Write-Host "   моделі для перевірки: $($models -join ', ')"
  $plan += @{ e = $e; models = $models; keyOk = $true; note = $(if ($list.ok) { '' } else { 'ключ не перевірено: список моделей недоступний' }) }
}
if ($DryRun) {
  foreach ($p in $plan) {
    $status = if (-not $p.keyOk) { $p.note } elseif ($p.note) { "$($p.note); моделі: $($p.models -join ', ')" } else { "ключ OK; моделі: $($p.models -join ', ')" }
    $report.Add("- **$($p.e.name)**: $status")
  }
  [IO.File]::WriteAllText($ReportPath, ($report -join "`r`n"), $Utf8NoBom); Write-Host "`nЗвіт: $ReportPath"; return
}

# 2. Резервні копії
if (-not $SkipHermes) {
  Copy-Item $HermesCfg "$HermesCfg.bak-$Stamp"; if (Test-Path $HermesEnv) { Copy-Item $HermesEnv "$HermesEnv.bak-$Stamp" }
}
if (-not $SkipOpenClaw) { Invoke-Proc 'wsl.exe' @('-d',$Distro,'-e','cp','/home/openclaw/.openclaw/openclaw.json',"/home/openclaw/.openclaw/openclaw.json.bak-$Stamp") | Out-Null }

# 3. Запис ключів і живі перевірки
$hermesPassed = New-Object System.Collections.Generic.List[object]   # @{provider; model; primary}
$ocPassed     = New-Object System.Collections.Generic.List[object]   # @{ref; primary}
$applied      = New-Object System.Collections.Generic.List[string]
$needRestart  = $false

if (-not $SkipOpenClaw) {
  foreach ($p in ($plan | Where-Object { $_.keyOk -and $_.e.ocMode -ne 'none' })) {
    $e = $p.e
    if ($e.ocMode -eq 'plugin') {
      $r = Invoke-OC @('models','auth','paste-api-key','--provider',$e.ocProvider) $keys[$e.env] 90
      if ($r.code -ne 0) { Write-Bad "OpenClaw: не вдалося зберегти ключ $($e.name): $($r.err.Trim())" }
    } else {
      $r1 = Invoke-OC @('config','set',"env.vars.$($e.env)",$keys[$e.env]) $null 90
      $modelsJson = ($p.models | ForEach-Object { '{"id":"' + $_ + '","name":"' + $_ + '","input":["text"],"contextWindow":' + $e.ctx + ',"maxTokens":8192}' }) -join ','
      $provJson = '{"baseUrl":"' + $e.base + '","apiKey":"${' + $e.env + '}","api":"openai-completions","models":[' + $modelsJson + ']}'
      $r2 = Invoke-OC @('config','set',"models.providers.$($e.ocProvider)",$provJson,'--strict-json') $null 90
      if (($r1.out + $r2.out) -match 'Restart the gateway') { $needRestart = $true }
      if ($r2.code -ne 0) { Write-Bad "OpenClaw: не вдалося додати провайдера $($e.ocProvider): $($r2.err.Trim())" }
    }
  }
  if ($needRestart) {
    Write-Step 'OpenClaw: перезапуск гейтвея для нових змінних середовища'
    Invoke-OC @('gateway','restart') $null 120 | Out-Null
    if (-not (Wait-Gateway)) { Write-Bad 'гейтвей не піднявся за 2 хв — перевірки OpenClaw можуть впасти' }
  }
}

foreach ($p in ($plan | Where-Object { $_.keyOk })) {
  $e = $p.e; $any = $false
  Write-Step "$($e.name): живі перевірки"
  if (-not $SkipHermes) {
    Set-EnvLine $HermesEnv $e.env $keys[$e.env]
    foreach ($m in $p.models) {
      $t = Test-HermesModel $e.hermes $m
      if ($t.ok) { Write-Ok "Hermes   $($e.hermes)/$m"; $hermesPassed.Add(@{ provider = $e.hermes; model = $m; primary = $e.primary }); $any = $true }
      else { Write-Bad "Hermes   $($e.hermes)/$m :: $($t.detail.Substring(0, [Math]::Min(160, $t.detail.Length)))" }
      $p["h_$m"] = $t.ok
    }
  }
  if (-not $SkipOpenClaw -and $e.ocMode -ne 'none') {
    foreach ($m in $p.models) {
      $ref = "$($e.ocProvider)/$m"
      $t = Test-OpenClawModel $ref
      if ($t.ok) { Write-Ok "OpenClaw $ref"; $ocPassed.Add(@{ ref = $ref; primary = $e.primary }); $any = $true }
      else { Write-Bad "OpenClaw $ref :: $($t.detail.Substring(0, [Math]::Min(160, $t.detail.Length)))" }
      $p["o_$m"] = $t.ok
    }
  }
  if ($any) { $applied.Add($e.env) }
}

# 4. Ланцюжки: OpenClaw
if (-not $SkipOpenClaw -and $ocPassed.Count -gt 0) {
  Write-Step 'OpenClaw: перебудова основної моделі й ланцюжка'
  $st = Invoke-OC @('models','status') $null 90
  $oldPrimary = [regex]::Match($st.out, '(?m)^Default\s*:\s*(\S+)').Groups[1].Value
  $oldFallbacks = @([regex]::Matches((Invoke-OC @('models','fallbacks','list') $null 90).out, '(?m)^- (\S+)') | ForEach-Object { $_.Groups[1].Value })
  $newPrimary = ($ocPassed | Where-Object { $_.primary } | Select-Object -First 1)
  $chain = New-Object System.Collections.Generic.List[string]
  foreach ($x in $ocPassed) { if (-not $newPrimary -or $x.ref -ne $newPrimary.ref) { $chain.Add($x.ref) } }
  if ($newPrimary -and $oldPrimary -and $oldPrimary -ne $newPrimary.ref -and $oldPrimary -notmatch '/auto$') { $chain.Add($oldPrimary) }
  foreach ($f in $oldFallbacks) { if (-not $chain.Contains($f) -and (-not $newPrimary -or $f -ne $newPrimary.ref)) { $chain.Add($f) } }
  if ($newPrimary) { Invoke-OC @('models','set',$newPrimary.ref) $null 90 | Out-Null; Write-Ok "основна: $($newPrimary.ref)" }
  Invoke-OC @('models','fallbacks','clear') $null 90 | Out-Null
  foreach ($f in $chain) { Invoke-OC @('models','fallbacks','add',$f) $null 90 | Out-Null }
  Write-Ok "запасних: $($chain.Count)"
}

# 5. Ланцюжки: Hermes (основна через `hermes config set`, ланцюжок — заміна блоку fallback_providers)
if (-not $SkipHermes -and $hermesPassed.Count -gt 0) {
  Write-Step 'Hermes: перебудова основної моделі й ланцюжка'
  $cfg = [IO.File]::ReadAllText($HermesCfg)
  # Блок model: — від 'model:' до наступного ключа верхнього рівня; ланцюжок — рядки з відступом під 'fallback_providers:'.
  $modelBlock = [regex]::Match($cfg, '(?ms)^model:\r?\n.*?(?=^[a-z_]+:)').Value
  $oldProv  = [regex]::Match($modelBlock, '(?m)^  provider:\s*"?([^"\r\n]+)"?').Groups[1].Value.Trim()
  $oldModel = [regex]::Match($modelBlock, '(?m)^  default:\s*"?([^"\r\n]+)"?').Groups[1].Value.Trim()
  $fbRegex  = '(?m)^fallback_providers:[ \t]*\r?\n(?:  .*\r?\n)*'
  $oldBlock = [regex]::Match($cfg, $fbRegex).Value
  $oldChain = @([regex]::Matches($oldBlock, '(?m)^  - provider:\s*"([^"]+)"\r?\n\s+model:\s*"([^"]+)"') | ForEach-Object { @{ provider = $_.Groups[1].Value; model = $_.Groups[2].Value } })
  $newPrimary = ($hermesPassed | Where-Object { $_.primary } | Select-Object -First 1)

  $chain = New-Object System.Collections.Generic.List[object]
  $seen = @{}
  $add = { param($x) $k = "$($x.provider)|$($x.model)"; if (-not $seen.ContainsKey($k)) { $seen[$k] = 1; $chain.Add($x) } }
  if ($newPrimary) { $seen["$($newPrimary.provider)|$($newPrimary.model)"] = 1 }
  foreach ($x in $hermesPassed) { & $add $x }
  if ($newPrimary -and $oldModel) { & $add @{ provider = $oldProv; model = $oldModel } }
  foreach ($x in $oldChain) { & $add $x }

  $block = "fallback_providers:`r`n" + (($chain | ForEach-Object { "  - provider: `"$($_.provider)`"`r`n    model: `"$($_.model)`"" }) -join "`r`n") + "`r`n"
  if ($oldBlock) { $cfg = [regex]::Replace($cfg, $fbRegex, [Text.RegularExpressions.MatchEvaluator]{ param($m) $block }) }
  else { $cfg = $cfg.TrimEnd() + "`r`n`r`n" + $block }
  [IO.File]::WriteAllText($HermesCfg, $cfg, $Utf8NoBom)
  $cfgWithChain = $cfg
  Write-Ok "запасних: $($chain.Count)"

  if ($newPrimary) {
    Invoke-Proc $HermesExe @('config','set','model.provider',$newPrimary.provider) | Out-Null
    Invoke-Proc $HermesExe @('config','set','model.default',$newPrimary.model) | Out-Null
    Invoke-Proc $HermesExe @('config','unset','model.base_url') | Out-Null
    Invoke-Proc $HermesExe @('config','unset','model.api_mode') | Out-Null
    $chk = Invoke-Proc $HermesExe @('chat','--query-file','-','-Q','--source','tool','--max-turns','2') 'Reply with exactly: OK' 150
    if ($chk.code -eq 0 -and $chk.out -match '\bOK\b') { Write-Ok "основна: $($newPrimary.provider)/$($newPrimary.model)" }
    else {
      Write-Bad "основна $($newPrimary.provider)/$($newPrimary.model) не відповіла без явних параметрів — лишаю попередню основну, новий ланцюжок зберігаю"
      [IO.File]::WriteAllText($HermesCfg, $cfgWithChain, $Utf8NoBom)
      $newPrimary = $null
    }
  }
}

# 6. Стерти застосовані ключі з файлу
if (-not $KeepKeys -and $applied.Count -gt 0) {
  $text = [IO.File]::ReadAllText($KeysFile, [Text.Encoding]::UTF8)
  foreach ($n in $applied) { $text = [regex]::Replace($text, "(?m)^$n=.*$", "$n=") }
  [IO.File]::WriteAllText($KeysFile, $text, $Utf8NoBom)
}

# 7. Звіт
$report.Add('| Провайдер | Ключ | Hermes | OpenClaw |'); $report.Add('|---|---|---|---|')
foreach ($p in $plan) {
  $h = ($p.models | ForEach-Object { if ($p.ContainsKey("h_$_")) { if ($p["h_$_"]) { "✅ $_" } else { "❌ $_" } } }) -join '<br>'
  $o = ($p.models | ForEach-Object { if ($p.ContainsKey("o_$_")) { if ($p["o_$_"]) { "✅ $_" } else { "❌ $_" } } }) -join '<br>'
  $report.Add("| $($p.e.name) | $(if ($p.keyOk) { 'OK' } else { $p.note }) | $h | $o |")
}
$report.Add('')
$report.Add("Ключі, записані в агенти й стерті з файлу: $(if ($applied.Count) { $applied -join ', ' } else { 'немає' })")
$report.Add('')
$report.Add('## Як відкотити')
$report.Add("- Hermes: скопіювати ``$HermesCfg.bak-$Stamp`` → ``config.yaml`` і ``$HermesEnv.bak-$Stamp`` → ``.env``.")
$report.Add("- OpenClaw (у WSL $Distro): ``cp ~/.openclaw/openclaw.json.bak-$Stamp ~/.openclaw/openclaw.json``; ключі плагінів: ``openclaw models auth list`` / ``logout``.")
[IO.File]::WriteAllText($ReportPath, ($report -join "`r`n"), $Utf8NoBom)
Write-Host "`nЗвіт: $ReportPath" -ForegroundColor Cyan
