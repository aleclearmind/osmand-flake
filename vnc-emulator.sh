#!/usr/bin/env bash
# Boot the AVD with a *window*, on a virtual X display, and export that display over VNC —
# so you can drive the emulator by hand from the far end of an SSH connection.
#
# run-emulator.sh runs it headless (-no-window) because this box has no GPU and no X; that is
# right for scripted runs and useless for looking at. Here: Xvfb gives the emulator a display
# to draw into, x11vnc serves that display, and you tunnel to it. SwiftShader still does the
# GLES on the CPU, so the OpenGL core renders exactly as it does headless — just visibly.
#
#   on this box:     ./vnc-emulator.sh
#   on your laptop:  ssh -L 5900:localhost:5900 <this-box>
#                    vncviewer localhost:5900      (or Remmina, TigerVNC, macOS Screen Sharing)
#
# x11vnc listens on localhost only and with no password: the SSH tunnel is the authentication,
# and an open VNC port on a shared box is not.
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
DISPLAY_NUM=${DISPLAY_NUM:-1}
VNC_PORT=${VNC_PORT:-5900}

# The x86_64 emulator refuses to start without KVM, and a shell that was opened *before* the
# user was added to the kvm group does not have the group even though /etc/group says it does
# — group membership is fixed at login. The emulator's own diagnosis for this is "x86_64
# emulation currently requires hardware acceleration", which sends you looking for a BIOS
# setting rather than at your own session. Re-exec under the group instead.
if [ ! -w /dev/kvm ] && [ -z "${VNC_EMULATOR_KVM_REEXEC:-}" ]; then
	echo "==> no kvm in this session's groups; re-execing under sg kvm"
	export VNC_EMULATOR_KVM_REEXEC=1
	exec sg kvm -c "$(printf '%q ' "$0" "$@")"
fi

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

# One emulator at a time: two processes on the same AVD corrupt its qcow2.
if pgrep -f "qemu-system-x86_64.*osmand" >/dev/null; then
	echo "An emulator is already running on this AVD. Stop it first:" >&2
	echo "  pkill -f qemu-system-x86_64" >&2
	exit 1
fi

cleanup() { kill "${XVFB_PID:-}" "${VNC_PID:-}" 2>/dev/null || true; }
trap cleanup EXIT

# Resolve the binaries rather than `nix run` them: the xvfb package's main program is `X`,
# which it does not ship — the binary is `Xvfb`. `nix run nixpkgs#xvfb` therefore fails with
# "unable to execute .../bin/X", which reads like a broken X server rather than a wrong name.
XVFB="$(nix build nixpkgs#xvfb --no-link --print-out-paths)/bin/Xvfb"
X11VNC="$(nix build nixpkgs#x11vnc --no-link --print-out-paths)/bin/x11vnc"

echo "==> virtual display :$DISPLAY_NUM"
"$XVFB" ":$DISPLAY_NUM" -screen 0 1600x1200x24 &
XVFB_PID=$!
for _ in $(seq 1 20); do
	[ -e "/tmp/.X11-unix/X$DISPLAY_NUM" ] && break
	sleep 0.5
done

echo "==> vnc server on localhost:$VNC_PORT"
"$X11VNC" -display ":$DISPLAY_NUM" -rfbport "$VNC_PORT" \
	-localhost -nopw -forever -shared -quiet &
VNC_PID=$!
sleep 2

cat <<EOF

    Tunnel in from your laptop:

      ssh -L $VNC_PORT:localhost:$VNC_PORT $(whoami)@$(hostname)
      vncviewer localhost:$VNC_PORT

EOF

echo "==> emulator (windowed, on :$DISPLAY_NUM)"
DISPLAY=":$DISPLAY_NUM" exec "$SDK/emulator/emulator" -avd osmand \
	-no-audio -no-boot-anim -no-snapshot \
	-gpu swiftshader_indirect -memory 4096 \
	-accel on -qemu -smp 4
