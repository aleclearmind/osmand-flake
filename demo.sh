#!/usr/bin/env bash
# Drives the emulator through both ways into the plugin, recording as it goes.
#
# screenrecord caps a clip at 3 minutes and the demo runs longer than that (the routing
# itself takes ~1.5 min from a tapped point, and ~3 min when it has to find the trailheads
# first), so it records in chunks and stitches them afterwards.
#
# Every UI step retries rather than asserting: the emulator is a soft-rendered device under
# load, and a tap that lands 200 ms before the view is laid out simply misses. A missed tap
# used to abort the run *and* take the chunk-pulling with it, so nine minutes of recording
# were thrown away over one early tap.
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="$(readlink -f "$ROOT/gcroots/emulator-sdk")/libexec/android-sdk"
export PATH="$SDK/platform-tools:$PATH"
OUT="$ROOT/shots/rec"
rm -rf "$OUT"; mkdir -p "$OUT"

# Whatever happens, salvage what was filmed.
finish() {
	kill %1 2>/dev/null || true
	adb shell 'pkill -INT screenrecord' 2>/dev/null || true
	sleep 3
	for n in $(seq 1 6); do
		adb pull "/sdcard/rec_$n.mp4" "$OUT/rec_$n.mp4" >/dev/null 2>&1 || true
	done
	find "$OUT" -size -100k -delete 2>/dev/null || true   # chunks that filmed a still screen
	ls -l "$OUT"
}
trap finish EXIT

# Clear the dump before taking a new one: `uiautomator dump` fails whenever the screen is
# animating and leaves the *previous* dump in place, so a naive read silently returns the
# last screen. That is how "is the drawer open?" answered yes off a stale snapshot, skipped
# the hamburger tap, and left the swipes panning the map.
ui() {
	adb shell rm -f /sdcard/ui.xml >/dev/null 2>&1
	adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
	adb shell cat /sdcard/ui.xml 2>/dev/null
}

# tap TEXT [tries] — retry, because one missed tap is not a reason to lose the take.
tap() {
	for _ in $(seq 1 "${2:-6}"); do
		"$ROOT/tap.sh" "$1" 2>/dev/null && { sleep 2; return 0; }
		sleep 2
	done
	echo "!! could not tap '$1'" >&2
	return 1
}

# Wait for the options pager: routing is CPU-bound and its duration is the point, not noise.
await_pager() {
	for _ in $(seq 1 60); do
		sleep 5
		ui | grep -q ViewPager && { sleep 3; return 0; }
	done
	echo "!! pager never appeared" >&2
	return 1
}

swipe_options() { for _ in 1 2 3 4; do adb shell input swipe 260 470 60 470 300; sleep 4; done; }

# BACK on the map screen finishes MapActivity, so "press BACK until the dialogs are gone"
# quietly drops you on the launcher and every later tap lands on the home screen. Assert
# the map is actually resumed instead of counting keystrokes.
ensure_map() {
	for _ in $(seq 1 5); do
		adb shell dumpsys activity activities 2>/dev/null \
			| grep -q "topResumedActivity.*net\.osmand\.plus" && return 0
		adb shell monkey -p net.osmand.plus -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
		sleep 8
	done
	echo "!! could not get back to the map" >&2
	return 1
}

# Open the drawer and scroll to "Ring route", retrying the whole thing if it does not appear.
#
# The success marker has to be "Ring route" itself. The obvious one — some drawer item like
# "Configure map" — is in the dump even when the drawer is *shut* (DrawerLayout lays its
# contents out either way, and the top items survive recycling), so checking for it always
# answers "already open": the hamburger never gets tapped, the swipes pan the map instead of
# scrolling the drawer, and the whole thing reads as "the plugin is missing from the drawer".
# "Ring route" is far enough down the list that it only exists once the drawer is really
# open and really scrolled, which is exactly the state we need.
open_drawer() {
	for _ in $(seq 1 4); do
		adb shell input tap 33 607           # hamburger
		sleep 5
		for _ in $(seq 1 6); do              # "Ring route" sits below the fold
			ui | grep -q "Ring route" && return 0
			adb shell input swipe 130 550 130 200 300
			sleep 2
		done
		adb shell input keyevent KEYCODE_BACK   # close it and start over
		sleep 2
	done
	echo "!! never found Ring route in the drawer" >&2
	return 1
}

# Start the map from a known-clean state. `geo:` is how you aim it at Rassa, but the intent
# also *opens the context menu* on the point it lands on — and that card covers the bottom
# bar, so a later hamburger tap hits the card instead of the drawer. Part 1 wants the pin;
# part 2 wants the bottom bar, and gets the restored view (still Rassa) instead.
open_map() {
	adb shell am force-stop net.osmand.plus
	adb shell monkey -p net.osmand.plus -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
	sleep 14
	if [ "${1:-}" = pin ]; then
		adb shell am start -a android.intent.action.VIEW -d "geo:45.76847,8.01307?z=14" >/dev/null 2>&1
		sleep 8
	fi
	ensure_map
}

MODE=${1:-all}

adb shell 'rm -f /sdcard/rec_*.mp4'
for n in $(seq 1 6); do
	adb shell screenrecord --time-limit 175 --bit-rate 6M --size 320x640 "/sdcard/rec_$n.mp4" || true
done &
sleep 2

# --- 1. from a point you picked: long-press -> Actions -> Find trekking ring ---------
if [ "$MODE" = all ] || [ "$MODE" = point ]; then
	open_map pin
	adb shell input swipe 160 320 160 320 900   # long-press the map at Rassa
	sleep 4
	tap "Actions"
	tap "Find trekking"
	sleep 3                                     # let the form be read
	tap "CALCULATE"
	await_pager
	swipe_options                               # dots follow, map redraws under the card
	tap "Close"
fi

# --- 2. from nowhere in particular: the drawer finds the trailheads itself -----------
# From a clean app, not from wherever part 1 left off: the card sits on top of the context
# menu, which covers the bottom bar, so the hamburger tap lands on the card instead of the
# drawer. Backing out of that is a guessing game (one BACK is too few, three finishes
# MapActivity and drops you on the launcher) — relaunching is deterministic.
if [ "$MODE" = all ] || [ "$MODE" = drawer ]; then
	open_map
	open_drawer
	tap "Ring route"
	sleep 4                                  # the min-start-altitude field is the point
	tap "CALCULATE"
	await_pager
	swipe_options                            # each option names the car park it starts from

	tap "Save"                               # ends on the saved-GPX toast
	sleep 4
fi
