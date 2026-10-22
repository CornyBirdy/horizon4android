<#
.SYNOPSIS
  Prepares Horizon's resources on this computer from your own Minecraft Java Edition (with
  horizon-prepare) and copies them to the phone over adb.

.DESCRIPTION
  android\push-resources.ps1 [-Resources DIR] [-Prepare -ServerJar JAR [-MinecraftDir DIR]]
                             [-NoSounds] [-Serial SERIAL]

    -Resources DIR   the prepared folder to copy (default .local\horizon-client\26.3 in this
                     checkout, where horizon-prepare puts it)
    -Prepare         run horizon-prepare first (needs -ServerJar: the pinned 26.3 server jar you
                     downloaded yourself; and a JDK, and Minecraft played once from the official
                     launcher). Not needed if the folder is already prepared, for instance by
                     the launcher: pass its folder with -Resources.
    -NoSounds        do not run 'horizon-prepare sounds' (about 380 MB; the game is silent without)
    -Serial SERIAL   which device, when several are connected (adb -s)

  Nothing is downloaded and nothing of Minecraft's is stored in this repository: the folder is
  prepared from your own install and goes straight to your own phone.
#>
param(
  [string]$Resources,
  [switch]$Prepare,
  [string]$ServerJar,
  [string]$MinecraftDir,
  [switch]$NoSounds,
  [string]$Serial
)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$package = 'dev.horizon.android'
if (-not $Resources) {
  $Resources = Join-Path $root '.local\horizon-client\26.3'
  # Not prepared in this checkout: use what the Horizon launcher prepared.
  if (-not (Test-Path (Join-Path $Resources 'horizon-resources.json'))) {
    $launcher = Join-Path $env:APPDATA 'horizon-launcher\versions'
    if (Test-Path $launcher) {
      $hit = Get-ChildItem -Path $launcher -Recurse -Depth 5 -Filter 'horizon-resources.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
      if ($hit) { $Resources = $hit.DirectoryName; Write-Host "Using the launcher's prepared folder: $Resources" }
    }
  }
}

function Die([string]$message) { throw "error: $message" }
function Run([string]$exe, [string[]]$arguments) {
  & $exe @arguments
  if ($LASTEXITCODE -ne 0) { Die "$exe failed with exit code $LASTEXITCODE" }
}

if (-not (Get-Command adb -ErrorAction SilentlyContinue)) { Die 'adb not found. Install the Android platform-tools.' }
$adb = @()
if ($Serial) { $adb = @('-s', $Serial) }

if ($Prepare) {
  if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) { Die 'cargo not found. Install Rust (rustup).' }
  $prepareArgs = @('run', '--release', '-p', 'horizon-prepare', '--', '--prepare')
  if ($ServerJar) { $prepareArgs += @('--server-jar', $ServerJar) }
  if ($MinecraftDir) { $prepareArgs += @('--minecraft-dir', $MinecraftDir) }
  Push-Location $root
  try {
    Run 'cargo' $prepareArgs
    if (-not $NoSounds) {
      $soundArgs = @('run', '--release', '-p', 'horizon-prepare', '--', 'sounds')
      if ($MinecraftDir) { $soundArgs += @('--minecraft-dir', $MinecraftDir) }
      try { Run 'cargo' $soundArgs } catch { Write-Warning 'the sounds were not copied; the game will be silent' }
    }
  } finally { Pop-Location }
}

if (-not (Test-Path (Join-Path $Resources 'horizon-resources.json'))) {
  Die "$Resources has no horizon-resources.json. Prepare the resources first: android\push-resources.ps1 -Prepare -ServerJar <server.jar> (ANDROID.md, `"Resources`")"
}

$state = ''
try { $state = ((& adb @adb get-state 2>$null) | Out-String).Trim() } catch { $state = '' }
if ($state -ne 'device') {
  Die 'no phone connected over adb (adb devices). Turn on USB debugging and accept the prompt on the phone.'
}

$dest = "/sdcard/Android/data/$package/files/resources"
Write-Host "Copying $Resources to the phone: $dest"
Run 'adb' ($adb + @('shell', 'mkdir', '-p', $dest))
# 'dir\.' copies the folder's contents into the destination.
Run 'adb' ($adb + @('push', ((Resolve-Path $Resources).Path + '\.'), "$dest/"))
Run 'adb' ($adb + @('shell', 'ls', "$dest/horizon-resources.json"))
Write-Host ''
Write-Host 'Done. Open Horizon on the phone and tap Start.'
