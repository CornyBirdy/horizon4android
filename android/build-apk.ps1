<#
.SYNOPSIS
  Builds Horizon's Android app: dist\horizon-android-debug.apk, signed with the debug key.

.DESCRIPTION
  android\build-apk.ps1 [-Release] [-NoAudio] [-Mods] [-SkipNative] [-Install]

    -Release     full optimisation with thin LTO (slow to build; the default is the quicker
                 'fast' profile, which is optimised too)
    -NoAudio     leave out sound (cpal), if it fails to build or run on the phone
    -Mods        build the WebAssembly mod runtime (wasmtime) in; mods with code are off otherwise
    -SkipNative  reuse the last native library build (only the Java side or resources changed)
    -Install     adb install -r the result on the connected phone

  Needs (ANDROID.md, "Build"): a Rust toolchain with the aarch64-linux-android target, cargo-ndk,
  the Android NDK, the Android SDK (platform 30+ and build-tools) and a JDK (11+: javac, jar,
  keytool). It uses no Gradle: aapt2, javac, d8, zipalign and apksigner, from the SDK, do the
  packaging. The same steps as android/build-apk.sh, for Windows PowerShell 5.1 and PowerShell 7.
#>
param(
  [switch]$Release,
  [switch]$NoAudio,
  [switch]$Mods,
  [switch]$SkipNative,
  [switch]$Install
)
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$root = Split-Path -Parent $here
$build = Join-Path $here 'build'
$dist = Join-Path $root 'dist'

function Die([string]$message) { throw "error: $message" }

# Runs a program and stops when it fails.
function Run([string]$exe, [string[]]$arguments) {
  & $exe @arguments
  if ($LASTEXITCODE -ne 0) { Die "$exe failed with exit code $LASTEXITCODE" }
}

function Need([string]$name, [string]$hint) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { Die "$name not found. $hint" }
}

# ---- tools ---------------------------------------------------------------------------------

$sdk = $env:ANDROID_HOME
if (-not $sdk) { $sdk = $env:ANDROID_SDK_ROOT }
if (-not $sdk) {
  foreach ($candidate in @("$env:LOCALAPPDATA\Android\Sdk", "$env:USERPROFILE\AppData\Local\Android\Sdk")) {
    if ($candidate -and (Test-Path $candidate)) { $sdk = $candidate; break }
  }
}
if (-not $sdk -or -not (Test-Path $sdk)) {
  Die 'Android SDK not found. Install it (Android Studio, or the command-line tools) and set ANDROID_HOME.'
}

# The newest platform (30 or newer: the app targets 34) and build-tools installed.
$platform = 0
if (Test-Path "$sdk\platforms") {
  foreach ($dir in Get-ChildItem "$sdk\platforms" -Directory) {
    if ($dir.Name -match '^android-(\d+)$') {
      $level = [int]$Matches[1]
      if ($level -gt $platform) { $platform = $level }
    }
  }
}
if ($platform -lt 30) { Die "no SDK platform 30+ in $sdk\platforms. sdkmanager `"platforms;android-34`"" }
$androidJar = "$sdk\platforms\android-$platform\android.jar"

$toolsVersion = $null
if (Test-Path "$sdk\build-tools") {
  $versions = @(Get-ChildItem "$sdk\build-tools" -Directory | Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
    Sort-Object { [version]$_.Name })
  if ($versions.Count -gt 0) { $toolsVersion = $versions[-1].Name }
}
if (-not $toolsVersion) { Die "no build-tools in $sdk\build-tools. sdkmanager `"build-tools;34.0.0`"" }
$tools = "$sdk\build-tools\$toolsVersion"

function Tool([string]$name) {
  foreach ($ext in @('.exe', '.bat', '.cmd', '')) {
    $path = "$tools\$name$ext"
    if (Test-Path $path -PathType Leaf) { return $path }
  }
  Die "$name is not in $tools"
}
$aapt2 = Tool 'aapt2'
$d8 = Tool 'd8'
$zipalign = Tool 'zipalign'
$apksigner = Tool 'apksigner'

# A JDK from JAVA_HOME when set, else the PATH.
function Java([string]$name) {
  if ($env:JAVA_HOME -and (Test-Path "$env:JAVA_HOME\bin\$name.exe")) { return "$env:JAVA_HOME\bin\$name.exe" }
  $found = Get-Command $name -ErrorAction SilentlyContinue
  if ($found) { return $found.Source }
  Die "$name not found. Install a JDK (11 or newer) or set JAVA_HOME."
}
$javac = Java 'javac'
$jar = Java 'jar'
$keytool = Java 'keytool'

Need 'cargo' 'Install Rust (rustup).'
if (-not $SkipNative) {
  $haveNdk = $true
  try {
    & cargo ndk --version *> $null
    if ($LASTEXITCODE -ne 0) { $haveNdk = $false }
  } catch { $haveNdk = $false }
  if (-not $haveNdk) { Die 'cargo-ndk not found. cargo install cargo-ndk' }
  $targets = & rustup target list --installed
  if (-not ($targets -contains 'aarch64-linux-android')) {
    Die 'the Rust target is missing. rustup target add aarch64-linux-android'
  }
}
$cargoProfile = 'fast'
if ($Release) { $cargoProfile = 'release' }
Write-Host "SDK $sdk (platform $platform, build-tools $toolsVersion), profile $cargoProfile"

# ---- the native library --------------------------------------------------------------------

$libDir = Join-Path $build 'jniLibs'
if (-not $SkipNative) {
  # A lock file of its own, seeded from the desktop one so every dependency keeps the version
  # the desktop client is built with. Cargo adds the few Android-only crates itself.
  if (-not (Test-Path "$here\native\Cargo.lock")) {
    Copy-Item "$root\Cargo.lock" "$here\native\Cargo.lock"
  }
  New-Item -ItemType Directory -Force $libDir | Out-Null
  $cargoArgs = @('ndk', '-t', 'arm64-v8a', '--platform', '30', '-o', $libDir, 'build')
  if ($Release) { $cargoArgs += '--release' } else { $cargoArgs += @('--profile', 'fast') }
  if ($NoAudio) { $cargoArgs += '--no-default-features' }
  if ($Mods) { $cargoArgs += @('--features', 'mods') }
  Push-Location "$here\native"
  try { Run 'cargo' $cargoArgs } finally { Pop-Location }
}
$so = "$libDir\arm64-v8a\libhorizon_android.so"
if (-not (Test-Path $so)) { Die "$so was not built" }

# ---- the app: resources, Java, dex ---------------------------------------------------------

foreach ($path in @('res', 'classes', 'dex', 'stage')) {
  if (Test-Path "$build\$path") { Remove-Item "$build\$path" -Recurse -Force }
}
foreach ($file in @('res.zip', 'classes.jar', 'base.apk', 'unsigned.apk', 'aligned.apk')) {
  if (Test-Path "$build\$file") { Remove-Item "$build\$file" -Force }
}
New-Item -ItemType Directory -Force "$build\res\drawable-xxxhdpi", "$build\classes", "$build\dex", "$build\stage" | Out-Null
# The game's own icon.
Copy-Item "$root\packaging\icons\hicolor\256x256\apps\horizon.png" "$build\res\drawable-xxxhdpi\ic_launcher.png"

Run $aapt2 @('compile', '--dir', "$build\res", '-o', "$build\res.zip")
Run $aapt2 @('link', '-o', "$build\base.apk", '-I', $androidJar, '--manifest', "$here\app\AndroidManifest.xml",
  '--min-sdk-version', '30', '--target-sdk-version', '34', '--version-code', '1', '--version-name', '0.1.0',
  "$build\res.zip")

$sources = @(Get-ChildItem "$here\app\java\dev\horizon\android" -Filter *.java | ForEach-Object { $_.FullName })
Run $javac (@('--release', '11', '-Xlint:-options', '-classpath', $androidJar, '-d', "$build\classes") + $sources)
Run $jar @('--create', '--file', "$build\classes.jar", '-C', "$build\classes", '.')
Run $d8 @('--release', '--min-api', '30', '--lib', $androidJar, '--output', "$build\dex", "$build\classes.jar")

# ---- the APK -------------------------------------------------------------------------------

Copy-Item "$build\dex\classes.dex" "$build\stage\classes.dex"
New-Item -ItemType Directory -Force "$build\stage\lib\arm64-v8a" | Out-Null
Copy-Item "$libDir\arm64-v8a\*.so" "$build\stage\lib\arm64-v8a\"
Copy-Item "$build\base.apk" "$build\unsigned.apk"
Push-Location "$build\stage"
try { Run $jar @('--update', '--no-manifest', '--file', "$build\unsigned.apk", 'classes.dex', 'lib') } finally { Pop-Location }
Run $zipalign @('-p', '-f', '4', "$build\unsigned.apk", "$build\aligned.apk")

# The debug key Android Studio makes; made here when there is none, so that a rebuilt app
# installs over the last one.
$keystore = $env:HORIZON_ANDROID_KEYSTORE
if (-not $keystore) { $keystore = "$env:USERPROFILE\.android\debug.keystore" }
if (-not (Test-Path $keystore)) {
  New-Item -ItemType Directory -Force (Split-Path -Parent $keystore) | Out-Null
  Run $keytool @('-genkeypair', '-keystore', $keystore, '-storepass', 'android', '-keypass', 'android',
    '-alias', 'androiddebugkey', '-keyalg', 'RSA', '-keysize', '2048', '-validity', '10000',
    '-dname', 'CN=Android Debug,O=Android,C=US')
}
New-Item -ItemType Directory -Force $dist | Out-Null
$out = "$dist\horizon-android-debug.apk"
if (Test-Path $out) { Remove-Item $out -Force }
Run $apksigner @('sign', '--ks', $keystore, '--ks-pass', 'pass:android', '--key-pass', 'pass:android',
  '--ks-key-alias', 'androiddebugkey', '--out', $out, "$build\aligned.apk")
Run $apksigner @('verify', $out)
$size = [math]::Round((Get-Item $out).Length / 1MB, 1)
Write-Host ''
Write-Host "Built $out ($size MB)"
if ($Install) {
  Need 'adb' 'Install the Android platform-tools.'
  Run 'adb' @('install', '-r', $out)
} else {
  Write-Host "Install it with: adb install -r $out"
}
