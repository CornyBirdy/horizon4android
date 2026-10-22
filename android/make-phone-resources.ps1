<#
.SYNOPSIS
  Packs the resources the Horizon launcher prepared into one zip for the phone.

.DESCRIPTION
  Press Prepare in the Horizon launcher first. Then run this (or double-click
  make-phone-resources.bat): it finds the prepared folder by itself, writes
  horizon-resources.zip to your Desktop, and opens the Desktop so you can send the zip to the
  phone (USB cable, Google Drive, anything). On the phone: open Horizon, tap
  "Import resources from a zip", pick the file.

    -Resources DIR   a prepared folder to pack (the one holding horizon-resources.json), when it
                     is not the launcher's
    -Out FILE        where to write the zip (default: Desktop\horizon-resources.zip)

  Nothing is downloaded and nothing of Minecraft's is stored in this repository: the zip is made
  from your own prepared copy and stays on your own computers.
#>
param(
  [string]$Resources,
  [string]$Out
)
$ErrorActionPreference = 'Stop'
function Die([string]$message) { Write-Host ''; Write-Host "Problem: $message" -ForegroundColor Red; exit 1 }

if (-not $Resources) {
  $roots = @($env:APPDATA, $env:LOCALAPPDATA) | Where-Object { $_ } |
    ForEach-Object { Join-Path $_ 'horizon-launcher\versions' } | Where-Object { Test-Path $_ }
  $found = @()
  foreach ($root in $roots) {
    $found += Get-ChildItem -Path $root -Recurse -Depth 5 -Filter 'horizon-resources.json' -ErrorAction SilentlyContinue
  }
  if (-not $found) {
    Die "Could not find prepared resources. Open the Horizon launcher, select the version and press Prepare, wait for 'Prepared for Minecraft 26.3', then run this again."
  }
  $Resources = ($found | Sort-Object LastWriteTime -Descending | Select-Object -First 1).DirectoryName
}
if (-not (Test-Path (Join-Path $Resources 'horizon-resources.json'))) {
  Die "$Resources has no horizon-resources.json."
}
if (-not $Out) { $Out = Join-Path ([Environment]::GetFolderPath('Desktop')) 'horizon-resources.zip' }

$tar = Get-Command tar.exe -ErrorAction SilentlyContinue
if (-not $tar) { Die 'tar.exe was not found (it ships with Windows 10 and 11).' }

Write-Host "Packing $Resources"
Write-Host "  -> $Out   (this can take a few minutes)"
if (Test-Path $Out) { Remove-Item $Out -Force }
& tar.exe -a -c -f $Out -C $Resources .
if ($LASTEXITCODE -ne 0) { Die "tar failed with exit code $LASTEXITCODE" }

$size = [math]::Round((Get-Item $Out).Length / 1MB)
Write-Host ''
Write-Host "Done: $Out ($size MB)" -ForegroundColor Green
Write-Host 'Now send it to the phone (USB cable into its Download folder, Google Drive, ...).'
Write-Host 'On the phone: open Horizon, tap "Import resources from a zip", pick horizon-resources.zip.'
Start-Process explorer.exe -ArgumentList "/select,`"$Out`""
