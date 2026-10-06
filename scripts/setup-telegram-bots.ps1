<#
.SYNOPSIS
  Підключає двох Telegram-ботів: один до OpenClaw (гейтвей у WSL), другий до Hermes (Windows).
  Писати ботам може лише власник (TELEGRAM_OWNER_ID). Токени й ID беруться з keys.env.

  Один бот = один агент: якщо обидва агенти опитуватимуть один токен, Telegram віддаватиме
  оновлення то одному, то іншому (409 Conflict). Тому скрипт вимагає два різні токени.

.PARAMETER DryRun   Лише перевірити токени (getMe) і показати план.
.PARAMETER KeepKeys Не стирати токени з keys.env після застосування.
#>
param(
  [string]$KeysFile = (Join-Path (Split-Path $PSScriptRoot) 'keys.env'),
  [switch]$DryRun, [switch]$KeepKeys, [switch]$SkipHermes, [switch]$SkipOpenClaw
)
$ErrorActionPreference = 'Stop'

$HermesExe = Join-Path $env:LOCALAPPDATA 'hermes\bin\hermes.exe'
$HermesEnv = Join-Path $env:LOCALAPPDATA 'hermes\.env'
$Distro    = 'OpenClawGateway'
$OcBin     = '/usr/local/bin/openclaw'
$Stamp     = Get-Date -Format 'yyyy-MM-dd-HHmm'
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Write-Step($m) { Write-Host "`n== $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "   OK   $m" -ForegroundColor Green }
function Write-Bad($m)  { Write-Host "   FAIL $m" -ForegroundColor Yellow }

function Join-Args([string[]]$argv) {
  ($argv | ForEach-Object {
    if ($_ -eq '') { '""' }
    elseif ($_ -match '[\s"]') { '"' + (($_ -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
    else { $_ }
  }) -join ' '
}
function Invoke-Proc([string]$file, [string[]]$argv, [int]$timeoutSec = 120) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $file; $psi.Arguments = Join-Args $argv
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
  $psi.EnvironmentVariables['NO_COLOR'] = '1'; $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
  $p = [Diagnostics.Process]::Start($psi)
  $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit($timeoutSec * 1000)) { & taskkill /PID $p.Id /T /F 2>$null | Out-Null; return @{ code = -1; out = ''; err = 'timeout' } }
  return @{ code = $p.ExitCode; out = $o.Result; err = $e.Result }
}
function Invoke-OC([string[]]$argv, [int]$timeoutSec = 120) { Invoke-Proc 'wsl.exe' (@('-d', $Distro, '-e', $OcBin) + $argv) $timeoutSec }

function Read-Keys($path) {
  $k = @{}
  foreach ($line in [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) {
    if ($line -match '^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$') { $v = $Matches[2].Trim('"').Trim("'"); if ($v) { $k[$Matches[1]] = $v } }
  }
  return $k
}
function Set-EnvLine($path, $name, $value) {
  $text = if (Test-Path $path) { [IO.File]::ReadAllText($path) } else { '' }
  $pattern = "(?m)^$name=.*$"; $line = "$name=$value"
  if ($text -match $pattern) { $text = [regex]::Replace($text, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($m) $line }) }
  else { if ($text -and -not $text.EndsWith("`n")) { $text += "`r`n" }; $text += "$line`r`n" }
  [IO.File]::WriteAllText($path, $text, $Utf8NoBom)
}
function Get-BotName($token) {
  try { $r = Invoke-RestMethod "https://api.telegram.org/bot$token/getMe" -TimeoutSec 20; if ($r.ok) { return $r.result.username } } catch {}
  return $null
}

# ---------- перевірки ----------
if (-not (Test-Path $KeysFile)) { throw "Немає файлу $KeysFile (скопіюй keys.env.example -> keys.env і заповни)." }
$k = Read-Keys $KeysFile
$owner = $k['TELEGRAM_OWNER_ID']
if (-not $owner -or $owner -notmatch '^\d+$') { throw 'TELEGRAM_OWNER_ID не заданий або не число. Свій ID покаже бот @userinfobot.' }
$ocTok = $k['OPENCLAW_TELEGRAM_BOT_TOKEN']; $hTok = $k['HERMES_TELEGRAM_BOT_TOKEN']
if ($SkipOpenClaw) { $ocTok = $null }; if ($SkipHermes) { $hTok = $null }
if (-not $ocTok -and -not $hTok) { Write-Host 'У keys.env немає токенів ботів. Нічого робити.' -ForegroundColor Yellow; return }
if ($ocTok -and $hTok -and $ocTok -eq $hTok) { throw 'OpenClaw і Hermes мають отримати РІЗНИХ ботів: один токен не можна опитувати з двох місць.' }

Write-Step 'Перевірка токенів (getMe)'
$ocBot = $null; $hBot = $null
if ($ocTok) { $ocBot = Get-BotName $ocTok; if ($ocBot) { Write-Ok "OpenClaw -> @$ocBot" } else { Write-Bad 'токен OpenClaw відхилено Telegram'; $ocTok = $null } }
if ($hTok)  { $hBot  = Get-BotName $hTok;  if ($hBot)  { Write-Ok "Hermes   -> @$hBot" }  else { Write-Bad 'токен Hermes відхилено Telegram';  $hTok = $null } }
if ($DryRun) { Write-Host "`nDryRun: нічого не змінено. Власник: $owner" -ForegroundColor Cyan; return }
$done = New-Object System.Collections.Generic.List[string]

# ---------- OpenClaw ----------
if ($ocTok) {
  Write-Step "OpenClaw: канал Telegram (@$ocBot)"
  Invoke-Proc 'wsl.exe' @('-d',$Distro,'-e','cp','/home/openclaw/.openclaw/openclaw.json',"/home/openclaw/.openclaw/openclaw.json.bak-$Stamp") | Out-Null
  $r1 = Invoke-OC @('channels','add','--channel','telegram','--token',$ocTok)
  $r2 = Invoke-OC @('config','set','channels.telegram.allowFrom',"[$owner]",'--strict-json')
  if ($r1.code -ne 0 -or $r2.code -ne 0) { Write-Bad "не вдалося: $($r1.err.Trim()) $($r2.err.Trim())" }
  else {
    if (($r1.out + $r2.out) -match 'Restart the gateway') {
      Invoke-OC @('gateway','restart') | Out-Null
      for ($i = 0; $i -lt 24; $i++) { if ((Invoke-OC @('gateway','status') 60).out -match 'Connectivity probe: ok') { break }; Start-Sleep 5 }
    }
    $st = Invoke-OC @('channels','status') 90
    Write-Host ($st.out.Trim() -split "`n" | Select-String -Pattern 'telegram' | Select-Object -First 3 | Out-String).TrimEnd()
    Write-Ok "OpenClaw: бот @$ocBot, писати може лише $owner (інші отримають код pairing)"
    $done.Add('OPENCLAW_TELEGRAM_BOT_TOKEN')
  }
}

# ---------- Hermes ----------
if ($hTok) {
  Write-Step "Hermes: гейтвей Telegram (@$hBot)"
  if (Test-Path $HermesEnv) { Copy-Item $HermesEnv "$HermesEnv.bak-$Stamp" }
  Set-EnvLine $HermesEnv 'TELEGRAM_BOT_TOKEN' $hTok
  Set-EnvLine $HermesEnv 'TELEGRAM_ALLOWED_USERS' $owner
  # gateway install = завдання Планувальника Windows (без прав адміністратора), далі start і перевірка.
  $i1 = Invoke-Proc $HermesExe @('gateway','install') 180
  $i2 = Invoke-Proc $HermesExe @('gateway','start') 120
  Start-Sleep 10
  $s = Invoke-Proc $HermesExe @('gateway','status') 60
  Write-Host ($s.out.Trim() -split "`n" | Select-Object -First 8 | Out-String).TrimEnd()
  if ($s.out -match '(?i)running|active') { Write-Ok "Hermes: бот @$hBot, писати може лише $owner"; $done.Add('HERMES_TELEGRAM_BOT_TOKEN') }
  else { Write-Bad "гейтвей Hermes не запустився: $($i1.err.Trim()) $($i2.err.Trim())" }
}

# ---------- прибирання ----------
if (-not $KeepKeys -and $done.Count) {
  $text = [IO.File]::ReadAllText($KeysFile, [Text.Encoding]::UTF8)
  foreach ($n in $done) { $text = [regex]::Replace($text, "(?m)^$n=.*$", "$n=") }
  [IO.File]::WriteAllText($KeysFile, $text, $Utf8NoBom)
}
Write-Host "`nДалі: з акаунта $owner напиши /start ботам $(@($ocBot, $hBot) | Where-Object { $_ } | ForEach-Object { "@$_" })" -ForegroundColor Cyan
