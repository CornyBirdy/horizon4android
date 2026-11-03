<#
.SYNOPSIS
  Writes the Microsoft account session the phone needs to join online-mode servers.

.DESCRIPTION
  The Android app has no Horizon launcher to sign in with, so the account comes from the computer
  where you use the launcher. Sign in there first (the launcher's Settings, Accounts). Then run this
  (or double-click make-phone-session.bat): it asks the launcher for a fresh session of that
  account and writes horizon-session.json to your Desktop. Send the file to the phone
  (USB cable, Google Drive, anything) and import it on the app's start screen: "Import a Microsoft
  account". The session lasts about a day; run this again when the app says it ran out.

    -Account NAME   the account's name or UUID (default: asks, after listing the signed-in accounts)
    -Launcher FILE  horizon-launcher.exe, when this cannot find it
    -Out FILE       where to write the file (default: Desktop\horizon-session.json)

  The file holds your login token: anyone who has it can play as you until it runs out. Delete it
  from the computer and the phone's Download folder once it is imported. Nothing is uploaded.
#>
param(
  [string]$Account,
  [string]$Launcher,
  [string]$Out
)
$ErrorActionPreference = 'Stop'
function Die([string]$message) { Write-Host ''; Write-Host "Problem: $message" -ForegroundColor Red; exit 1 }

if (-not $Launcher) {
  $cmd = Get-Command 'horizon-launcher.exe' -ErrorAction SilentlyContinue
  if ($cmd) { $Launcher = $cmd.Source }
}
if (-not $Launcher) {
  $roots = @(
    (Join-Path $env:LOCALAPPDATA 'Horizon'),
    (Join-Path $env:LOCALAPPDATA 'Horizon Launcher'),
    (Join-Path $env:LOCALAPPDATA 'Programs'),
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)},
    (Join-Path $env:APPDATA 'horizon-launcher'),
    (Join-Path $env:LOCALAPPDATA 'horizon-launcher')
  ) | Where-Object { $_ -and (Test-Path $_) }
  foreach ($root in $roots) {
    $hit = Get-ChildItem -Path $root -Recurse -Depth 3 -Filter 'horizon-launcher.exe' -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($hit) { $Launcher = $hit.FullName; break }
  }
}
if (-not $Launcher -or -not (Test-Path $Launcher)) {
  Die "Could not find horizon-launcher.exe. Run this with -Launcher 'C:\path\to\horizon-launcher.exe' (right-click the launcher's shortcut, Open file location)."
}
Write-Host "Launcher: $Launcher"

if (-not $Account) {
  Write-Host ''
  Write-Host 'Signed-in accounts:'
  & $Launcher account list
  Write-Host ''
  $Account = Read-Host 'Which account (name or UUID) joins the servers'
}
if (-not $Account) { Die 'No account given.' }

$raw = & $Launcher account session $Account --json 2>&1
if ($LASTEXITCODE -ne 0 -and -not $raw) { Die "The launcher failed with exit code $LASTEXITCODE." }
$text = ($raw | Out-String).Trim()
try { $answer = $text | ConvertFrom-Json } catch { Die "The launcher did not answer with JSON:`n$text" }

if (-not $answer.session_file) {
  $why = if ($answer.authentication) { ($answer.authentication | ConvertTo-Json -Compress) } else { $text }
  Die "The launcher could not give a session for '$Account': $why`nOpen the launcher, sign this account in again (Settings, Accounts), then run this again."
}
if (-not (Test-Path $answer.session_file)) { Die "The launcher named $($answer.session_file) but it does not exist." }

if (-not $Out) { $Out = Join-Path ([Environment]::GetFolderPath('Desktop')) 'horizon-session.json' }
Copy-Item -Path $answer.session_file -Destination $Out -Force
# The launcher's copy is for one game to read once; this one is for the phone.
Remove-Item -Path $answer.session_file -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "Done: $Out" -ForegroundColor Green
Write-Host 'It holds your login token for about a day: send it to the phone, import it, then delete it.'
Write-Host 'On the phone: open Horizon, tap "Import a Microsoft account", pick horizon-session.json.'
Start-Process explorer.exe -ArgumentList "/select,`"$Out`""
