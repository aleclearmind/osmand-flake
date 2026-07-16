#!/usr/bin/env bash
# Boot the AVD headless. SwiftShader because there is no GPU/X here — the OpenGL core
# still gets real GLES, just on the CPU.
#
# The SDK is resolved through the flake rather than hardcoded: `nix store gc` collects any
# store path nothing roots, and a dead absolute path here fails in a way that reads like a
# broken emulator rather than a missing dependency. --out-link doubles as the GC root that
# stops it being collected in the first place.
#
# The --override-input flags are not optional even though the emulator SDK has nothing to do with
# the forks: nix resolves every flake input before it evaluates any output, so without them this
# reaches for branches that may not be pushed yet.
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
mapfile -t NIX_OVERRIDES < <("$ROOT/local.sh" --flags)
# mapfile cannot see local.sh's exit status through the process substitution, so without
# this a missing clone would carry on with no overrides and reach for the pinned branch —
# failing as a puzzling GitHub error rather than "you have no clone".
if [ ${#NIX_OVERRIDES[@]} -eq 0 ]; then
	echo "$(basename "$0"): ./local.sh --flags failed; see above" >&2
	exit 1
fi
SDK="$(nix build "${NIX_OVERRIDES[@]}" "$ROOT#emulatorSdk" --out-link "$ROOT/gcroots/emulator-sdk" --print-out-paths)/libexec/android-sdk"

export ANDROID_SDK_ROOT=$SDK ANDROID_HOME=$SDK
export ANDROID_AVD_HOME="$ROOT/.avd"
exec "$SDK/emulator/emulator" -avd osmand \
  -no-window -no-audio -no-boot-anim -no-snapshot \
  -gpu swiftshader_indirect -memory 4096 \
  -accel on -qemu -smp 4
