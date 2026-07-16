#!/usr/bin/env bash
# tap.sh "TEXT" — find a node by text/content-desc in the UI dump and tap its centre.
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
export PATH="$SDK/platform-tools:$PATH"
# Delete the dump before making a new one. `uiautomator dump` fails whenever the screen is
# animating ("could not get idle state") and leaves the *previous* dump behind, so reading
# it without clearing first silently hands you the last screen — and you tap coordinates
# from a view that is no longer there.
adb shell rm -f /sdcard/ui.xml >/dev/null 2>&1
adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
adb pull /sdcard/ui.xml /tmp/ui.xml >/dev/null 2>&1 || { echo "no UI dump (screen busy)" >&2; exit 1; }
python3 - "$1" <<'PY'
import re,sys,subprocess
want=sys.argv[1].lower()
xml=open('/tmp/ui.xml',encoding='utf-8').read()
for m in re.finditer(r'<node[^>]*>', xml):
    tag=m.group(0)
    text=(re.search(r'text="([^"]*)"',tag) or [None,''])[1]
    desc=(re.search(r'content-desc="([^"]*)"',tag) or [None,''])[1]
    if want in text.lower() or want in desc.lower():
        b=re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"',tag)
        x=(int(b.group(1))+int(b.group(3)))//2; y=(int(b.group(2))+int(b.group(4)))//2
        print(f"tap '{text or desc}' at {x},{y}")
        subprocess.run(['adb','shell','input','tap',str(x),str(y)])
        sys.exit(0)
print(f"NOT FOUND: {want}"); sys.exit(1)
PY
