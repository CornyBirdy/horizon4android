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

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$base = (Resolve-Path $Resources).Path.TrimEnd('\', '/')
$files = @(Get-ChildItem -LiteralPath $base -Recurse -File -Force)
if ($files.Count -eq 0) { Die "$Resources holds no files." }
Write-Host "Packing $base"
Write-Host "  $($files.Count) files -> $Out   (this can take a few minutes)"
if (Test-Path $Out) { Remove-Item $Out -Force }

# Entry names are written by hand with forward slashes: tar.exe and Compress-Archive make zips
# that Explorer shows empty or that the phone unpacks wrongly.
$zip = [System.IO.Compression.ZipFile]::Open($Out, [System.IO.Compression.ZipArchiveMode]::Create)
try {
  $done = 0
  foreach ($file in $files) {
    $name = $file.FullName.Substring($base.Length).TrimStart('\', '/').Replace('\', '/')
    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
      $zip, $file.FullName, $name, [System.IO.Compression.CompressionLevel]::Fastest)
    $done++
    if ($done % 500 -eq 0) { Write-Host "  $done / $($files.Count)" }
  }
} finally { $zip.Dispose() }

# A zip that Windows itself cannot read back is not worth sending.
$check = [System.IO.Compression.ZipFile]::OpenRead($Out)
try {
  $entries = $check.Entries.Count
  $manifest = $check.Entries | Where-Object { $_.FullName -eq 'horizon-resources.json' }
} finally { $check.Dispose() }
if (-not $manifest) { Die 'The zip was written without horizon-resources.json at its top level.' }
Write-Host "  $entries files in the zip, horizon-resources.json at the top level."

$size = [math]::Round((Get-Item $Out).Length / 1MB)
Write-Host ''
Write-Host "Done: $Out ($size MB)" -ForegroundColor Green
Write-Host 'Now send it to the phone (USB cable into its Download folder, Google Drive, ...).'
Write-Host 'On the phone: open Horizon, tap "Import resources from a zip", pick horizon-resources.zip.'
Start-Process explorer.exe -ArgumentList "/select,`"$Out`""
