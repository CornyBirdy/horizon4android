#!/usr/bin/env bash
# Prepares Horizon's resources on this computer from your own Minecraft Java Edition (with
# horizon-prepare) and copies them to the phone over adb.
#
#   android/push-resources.sh [--resources DIR] [--prepare --server-jar JAR [--minecraft-dir DIR]]
#                             [--no-sounds] [--serial SERIAL] [--tar]
#
#   --resources DIR   the prepared folder to copy (default .local/horizon-client/26.3 in this
#                     checkout, where horizon-prepare puts it)
#   --prepare         run horizon-prepare first (needs --server-jar: the pinned 26.3 server jar
#                     you downloaded yourself; and a JDK, and Minecraft played once from the
#                     official launcher). Not needed if the folder is already prepared, for
#                     instance by the launcher: pass its folder with --resources.
#   --no-sounds       do not run `horizon-prepare sounds` (about 380 MB; the game is silent without)
#   --serial SERIAL   which device, when several are connected (adb -s)
#   --tar             stream a tar archive instead of pushing file by file: much faster for the
#                     many small files, but only where the shell is binary-safe (Linux, macOS)
#
# Nothing is downloaded and nothing of Minecraft's is stored in this repository: the folder is
# prepared from your own install and goes straight to your own phone.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
package=dev.horizon.android
resources="$root/.local/horizon-client/26.3"
prepare=0
sounds=1
serial=""
tar_mode=0
server_jar=""
minecraft_dir=""

while [ $# -gt 0 ]; do
  case "$1" in
    --resources) resources="$2"; shift 2 ;;
    --prepare) prepare=1; shift ;;
    --server-jar) server_jar="$2"; shift 2 ;;
    --minecraft-dir) minecraft_dir="$2"; shift 2 ;;
    --no-sounds) sounds=0; shift ;;
    --serial) serial="$2"; shift 2 ;;
    --tar) tar_mode=1; shift ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown option $1 (--help lists them)" >&2; exit 2 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
command -v adb >/dev/null 2>&1 || die "adb not found. Install the Android platform-tools."
adb_cmd=(adb)
[ -n "$serial" ] && adb_cmd=(adb -s "$serial")

if [ "$prepare" = 1 ]; then
  command -v cargo >/dev/null 2>&1 || die "cargo not found. Install Rust (rustup)."
  prepare_args=(--prepare)
  [ -n "$server_jar" ] && prepare_args+=(--server-jar "$server_jar")
  [ -n "$minecraft_dir" ] && prepare_args+=(--minecraft-dir "$minecraft_dir")
  (cd "$root" && cargo run --release -p horizon-prepare -- "${prepare_args[@]}")
  if [ "$sounds" = 1 ]; then
    sound_args=(sounds)
    [ -n "$minecraft_dir" ] && sound_args+=(--minecraft-dir "$minecraft_dir")
    (cd "$root" && cargo run --release -p horizon-prepare -- "${sound_args[@]}") \
      || echo "warning: the sounds were not copied; the game will be silent" >&2
  fi
fi

[ -f "$resources/horizon-resources.json" ] \
  || die "$resources has no horizon-resources.json. Prepare the resources first: android/push-resources.sh --prepare --server-jar <server.jar> (ANDROID.md, \"Resources\")"

state="$("${adb_cmd[@]}" get-state 2>/dev/null || true)"
[ "$state" = device ] || die "no phone connected over adb (adb devices). Turn on USB debugging and accept the prompt on the phone."

dest="/sdcard/Android/data/$package/files/resources"
echo "Copying $resources to the phone: $dest"
"${adb_cmd[@]}" shell mkdir -p "$dest"
if [ "$tar_mode" = 1 ]; then
  tar -C "$resources" -cf - . | "${adb_cmd[@]}" shell "tar -xf - -C '$dest'"
else
  "${adb_cmd[@]}" push "$resources/." "$dest/"
fi
"${adb_cmd[@]}" shell ls "$dest/horizon-resources.json" >/dev/null \
  || die "the copy did not leave horizon-resources.json in $dest"
echo
echo "Done. Open Horizon on the phone and tap Start."
