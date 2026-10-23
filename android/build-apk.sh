#!/usr/bin/env bash
# Builds Horizon's Android app: dist/horizon-android-debug.apk, signed with the debug key.
#
#   android/build-apk.sh [--release] [--no-audio] [--mods] [--skip-native] [--install]
#
#   --release      full optimisation with thin LTO (slow to build; the default is the quicker
#                  `fast` profile, which is optimised too)
#   --no-audio     leave out sound (cpal), if it fails to build or run on the phone
#   --mods         build the WebAssembly mod runtime (wasmtime) in; mods with code are off otherwise
#   --skip-native  reuse the last native library build (only the Java side or resources changed)
#   --install      adb install -r the result on the connected phone
#
# Needs (ANDROID.md, "Build"): a Rust toolchain with the aarch64-linux-android target, cargo-ndk,
# the Android NDK, the Android SDK (platform 30+ and build-tools) and a JDK (11+, javac and jar).
# It uses no Gradle: aapt2, javac, d8, zipalign and apksigner, from the SDK, do the packaging.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
build="$here/build"
dist="$root/dist"

profile=fast
no_default=0
mods=0
skip_native=0
install=0
for arg in "$@"; do
  case "$arg" in
    --release) profile=release ;;
    --no-audio) no_default=1 ;;
    --mods) mods=1 ;;
    --skip-native) skip_native=1 ;;
    --install) install=1 ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown option $arg (--help lists them)" >&2; exit 2 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 not found. $2"; }

# ---- tools ---------------------------------------------------------------------------------

sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$sdk" ]; then
  for candidate in "$HOME/Android/Sdk" "$HOME/Library/Android/sdk" "${LOCALAPPDATA:-/nonexistent}/Android/Sdk"; do
    [ -d "$candidate" ] && sdk="$candidate" && break
  done
fi
[ -n "$sdk" ] && [ -d "$sdk" ] || die "Android SDK not found. Install it (Android Studio, or the command-line tools) and set ANDROID_HOME."

# The newest platform and build-tools installed (platform 30 or newer: the app targets 34).
platform="$(ls -1 "$sdk/platforms" 2>/dev/null | sed -n 's/^android-\([0-9][0-9]*\)$/\1/p' | sort -n | tail -n 1)"
[ -n "$platform" ] && [ "$platform" -ge 30 ] || die "no SDK platform 30+ in $sdk/platforms. sdkmanager \"platforms;android-34\""
android_jar="$sdk/platforms/android-$platform/android.jar"
tools_version="$(ls -1 "$sdk/build-tools" 2>/dev/null | sort -V | tail -n 1)"
[ -n "$tools_version" ] || die "no build-tools in $sdk/build-tools. sdkmanager \"build-tools;34.0.0\""
tools="$sdk/build-tools/$tools_version"
for tool in aapt2 d8 zipalign apksigner; do
  [ -e "$tools/$tool" ] || [ -e "$tools/$tool.exe" ] || [ -e "$tools/$tool.bat" ] || die "$tool is not in $tools"
done
aapt2="$tools/aapt2"; d8="$tools/d8"; zipalign="$tools/zipalign"; apksigner="$tools/apksigner"

need javac "Install a JDK (11 or newer)."
need jar "Install a JDK (11 or newer)."
need keytool "Install a JDK (11 or newer)."
need cargo "Install Rust (rustup)."
if [ "$skip_native" = 0 ]; then
  cargo ndk --version >/dev/null 2>&1 || die "cargo-ndk not found. cargo install cargo-ndk"
  rustup target list --installed 2>/dev/null | grep -q '^aarch64-linux-android$' \
    || die "the Rust target is missing. rustup target add aarch64-linux-android"
fi
echo "SDK $sdk (platform $platform, build-tools $tools_version), profile $profile"

# ---- the native library --------------------------------------------------------------------

lib_dir="$build/jniLibs"
if [ "$skip_native" = 0 ]; then
  # A lock file of its own, seeded from the desktop one so every dependency keeps the version
  # the desktop client is built with. Cargo adds the few Android-only crates itself.
  if [ ! -f "$here/native/Cargo.lock" ]; then
    cp "$root/Cargo.lock" "$here/native/Cargo.lock"
  fi
  mkdir -p "$lib_dir"
  cargo_args=(--profile "$profile")
  [ "$profile" = release ] && cargo_args=(--release)
  [ "$no_default" = 1 ] && cargo_args+=(--no-default-features)
  [ "$mods" = 1 ] && cargo_args+=(--features mods)
  (cd "$here/native" && cargo ndk -t arm64-v8a --platform 30 -o "$lib_dir" build "${cargo_args[@]}")
fi
so="$lib_dir/arm64-v8a/libhorizon_android.so"
[ -f "$so" ] || die "$so was not built"

# A C++ runtime the library links must travel in the APK; the game's dependencies are meant not to need one.
needed=""
command -v readelf >/dev/null 2>&1 && needed="$(readelf -d "$so" 2>/dev/null || true)"
if printf '%s' "$needed" | grep -q 'libc++_shared.so'; then
  ndk="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
  [ -z "$ndk" ] && ndk="$(ls -d "$sdk"/ndk/* 2>/dev/null | sort -V | tail -n 1)"
  cxx="$(find "$ndk/toolchains/llvm/prebuilt" -path '*aarch64-linux-android/libc++_shared.so' 2>/dev/null | head -n 1)"
  [ -n "$cxx" ] || die "the library needs libc++_shared.so and the NDK's copy was not found"
  cp "$cxx" "$lib_dir/arm64-v8a/"
fi

# ---- the app: resources, Java, dex ---------------------------------------------------------

rm -rf "$build/res" "$build/classes" "$build/dex" "$build/stage" "$build"/*.apk "$build/res.zip" "$build/classes.jar"
mkdir -p "$build/res/drawable-xxxhdpi" "$build/classes" "$build/dex" "$build/stage"
# The game's own icon.
cp "$root/packaging/icons/hicolor/256x256/apps/horizon.png" "$build/res/drawable-xxxhdpi/ic_launcher.png"

"$aapt2" compile --dir "$build/res" -o "$build/res.zip"
"$aapt2" link -o "$build/base.apk" -I "$android_jar" --manifest "$here/app/AndroidManifest.xml" \
  --min-sdk-version 30 --target-sdk-version 34 --version-code 1 --version-name 0.1.0 "$build/res.zip"

javac --release 11 -Xlint:-options -classpath "$android_jar" -d "$build/classes" "$here"/app/java/dev/horizon/android/*.java
jar --create --file "$build/classes.jar" -C "$build/classes" .
"$d8" --release --min-api 30 --lib "$android_jar" --output "$build/dex" "$build/classes.jar"

# ---- the APK -------------------------------------------------------------------------------

cp "$build/dex/classes.dex" "$build/stage/classes.dex"
mkdir -p "$build/stage/lib/arm64-v8a"
cp "$lib_dir"/arm64-v8a/*.so "$build/stage/lib/arm64-v8a/"
cp "$build/base.apk" "$build/unsigned.apk"
(cd "$build/stage" && jar --update --no-manifest --file "$build/unsigned.apk" classes.dex lib)
"$zipalign" -p -f 4 "$build/unsigned.apk" "$build/aligned.apk"

# The project's debug key (android/horizon-debug.keystore, password "android"). It is public on
# purpose: this is a debug build, and one fixed key is what lets a new build install over the
# last one without uninstalling (a key made fresh on each machine or CI run makes Android
# refuse the update). HORIZON_ANDROID_KEYSTORE overrides it; one is made when the file is missing.
keystore="${HORIZON_ANDROID_KEYSTORE:-$here/horizon-debug.keystore}"
if [ ! -f "$keystore" ]; then
  mkdir -p "$(dirname "$keystore")"
  keytool -genkeypair -keystore "$keystore" -storepass android -keypass android \
    -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=Android Debug,O=Android,C=US"
fi
mkdir -p "$dist"
out="$dist/horizon-android-debug.apk"
rm -f "$out"
"$apksigner" sign --ks "$keystore" --ks-pass pass:android --key-pass pass:android \
  --ks-key-alias androiddebugkey --out "$out" "$build/aligned.apk"
"$apksigner" verify "$out"
echo
echo "Built $out ($(du -h "$out" | cut -f1))"
if [ "$install" = 1 ]; then
  need adb "Install the Android platform-tools."
  adb install -r "$out"
else
  echo "Install it with: adb install -r $out"
fi
