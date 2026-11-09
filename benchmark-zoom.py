#!/usr/bin/env python3
"""Record Milan zoom detail-loading times and actual map-surface presentations.

Requires adb, an installed OsmAnd APK, and an offline Lombardia map. Enable
debug_rendering before starting the app for native START/FINISH timings.
SurfaceFlinger intervals include late tile updates: only the first 250 ms after
the first presentation are reported as animation intervals. Keep raw samples.
"""

import argparse
import json
import re
import shlex
import statistics
import subprocess
import time
import xml.etree.ElementTree as ET
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--serial", default="emulator-5554")
    parser.add_argument("--package", default="net.osmand.plus")
    parser.add_argument("--cycles", type=int, default=3)
    parser.add_argument("--settle", type=float, default=5)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--verify-viewport", action="store_true",
                        help="Verify stored coordinates/zoom via private preferences (requires adb root)")
    args = parser.parse_args()
    if args.cycles < 1 or args.settle <= 0:
        parser.error("--cycles and --settle must be positive")
    args.output.mkdir(parents=True, exist_ok=True)

    def adb(*command):
        return subprocess.check_output(
            [args.adb, "-s", args.serial, *command], text=True
        )

    def shell(*command):
        return adb("shell", shlex.join(command))

    # OsmAnd ignores a requested zoom when the link has the current center.
    # Visit a different center first so every run really begins at zoom 15.
    shell("am", "force-stop", args.package)
    for index, location in enumerate(("45.4500/9.1800", "45.4642/9.1900")):
        shell("am", "start", "-W", "-n",
              args.package + "/net.osmand.plus.activities.MapActivity",
              "-a", "android.intent.action.VIEW",
              "-d", "https://osmand.net/map#15/" + location)
        time.sleep(args.settle)
        if index == 0:
            # Persist the offset, then deliver the real target to a fresh activity.
            # Reusing an activity can leave a pending location unapplied.
            shell("input", "keyevent", "KEYCODE_HOME")
            time.sleep(1)
            shell("am", "force-stop", args.package)

    def verify_viewport():
        if not args.verify_viewport:
            return None
        shell("input", "keyevent", "KEYCODE_HOME")
        time.sleep(1)  # onPause writes SharedPreferences asynchronously
        prefs = ET.fromstring(shell("cat", "/data/data/" + args.package +
                                    "/shared_prefs/net.osmand.settings.xml"))
        values = {n.get("name"): n.get("value", n.text) for n in prefs}
        viewport = {key: float(values["last_known_map_" + key])
                    for key in ("lat", "lon", "zoom", "zoom_float_part")}
        if (abs(viewport["lat"] - 45.4642) > 0.0001 or
                abs(viewport["lon"] - 9.1900) > 0.0001 or
                viewport["zoom"] != 15 or abs(viewport["zoom_float_part"]) > 0.001):
            raise RuntimeError(f"Unexpected viewport: {viewport}; expected Milan at zoom 15")
        shell("am", "start", "-W", "-n",
              args.package + "/net.osmand.plus.activities.MapActivity")
        time.sleep(args.settle)
        return viewport

    initial_viewport = verify_viewport()
    shell("uiautomator", "dump", "/sdcard/osmand-zoom-window.xml")
    nodes = ET.fromstring(shell("cat", "/sdcard/osmand-zoom-window.xml"))
    buttons = {}
    for node in nodes.iter("node"):
        for direction in ("in", "out"):
            if (node.get("resource-id", "").endswith("/map_zoom_" + direction + "_button")
                    and node.get("clickable") == "true"):
                x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.get("bounds")))
                buttons[direction] = (str((x1 + x2) // 2), str((y1 + y2) // 2))
    if set(buttons) != {"in", "out"}:
        raise RuntimeError("Cannot find both map zoom buttons; dismiss dialogs first")
    layers = shell("dumpsys", "SurfaceFlinger", "--list").splitlines()
    layers = [s for s in layers if s.startswith("SurfaceView[")
              and args.package in s and "(BLAST)" in s]
    if len(layers) != 1:
        raise RuntimeError(f"Expected one map surface, got {layers}")
    layer = layers[0]
    pid = shell("pidof", args.package).strip()
    startup_log = shell("logcat", "-d", "--pid=" + pid)
    (args.output / "startup.log").write_text(startup_log)
    unreadable_maps = [line for line in startup_log.splitlines()
                       if ".obf" in line.lower() and
                       ("could not be read" in line or "Failed to open OBF" in line)]
    if unreadable_maps:
        raise RuntimeError("Map files are unreadable; check their ownership: " + unreadable_maps[0])
    result = {
        "package": args.package,
        "device": shell("getprop", "ro.product.model").strip(),
        "cpu_count": int(shell("nproc")),
        "graphics": [line.strip() for line in shell("dumpsys", "SurfaceFlinger").splitlines()
                     if "GLES:" in line],
        "screen": shell("wm", "size").strip(),
        "density": shell("wm", "density").strip(),
        "surface": layer,
        "initial_verified_viewport": initial_viewport,
        "zoom_buttons": buttons,
        "settle_seconds": args.settle,
        "animation_window_ms": 250,
        "zoom_labels": "from/to_zoom are requested surface zoom; native_finishes.zoom is flat camera zoom and can differ",
        "samples": [],
    }
    (args.output / "package.txt").write_text(shell("dumpsys", "package", args.package))
    zoom = 15
    for cycle in range(args.cycles):
        for direction in ("in", "in", "out", "out", "out", "in"):
            target = zoom + (1 if direction == "in" else -1)
            stem = f"{cycle + 1}-{zoom}-{target}"
            shell("logcat", "-c")
            shell("dumpsys", "SurfaceFlinger", "--latency-clear", layer)
            before = int(shell("date", "+%s%N"))
            shell("input", "tap", *buttons[direction])
            after = int(shell("date", "+%s%N"))
            # Poll during loading: SF only retains 128 presentations.
            frames = set()
            deadline = time.monotonic() + args.settle
            refresh = None
            while time.monotonic() < deadline:
                lines = shell("dumpsys", "SurfaceFlinger", "--latency", layer).splitlines()
                if lines:
                    refresh = int(lines[0])
                for line in lines[1:]:
                    fields = tuple(map(int, line.split()))
                    if len(fields) == 3 and 0 < fields[1] < 2**63 - 1:
                        frames.add(fields)
                time.sleep(0.2)
            log = shell("logcat", "-d", "--pid=" + pid)
            (args.output / (stem + ".log")).write_text(log)
            presentations = sorted({row[1] for row in frames})
            if not presentations:
                raise RuntimeError(f"No presented map frames for {stem}; check the renderer and surface")
            active = [t for t in presentations if t - presentations[0] <= 250_000_000]
            intervals = [(b - a) / 1e6 for a, b in zip(active, active[1:])]
            finishes = re.findall(r">>>> (\d+) FINISH ([\d.]+): (\d+)z (.*)", log)
            finishes = [{"epoch_ms": int(t), "loading_ms": float(duration) * 1000,
                         "zoom": int(z), "stages": stages}
                        for t, duration, z, stages in finishes]
            legacy_renders = [
                {"search_ms": float(search) * 1000, "render_ms": float(render) * 1000,
                 "text_ms": float(text) * 1000,
                 "search_plus_render_ms": (float(search) + float(render)) * 1000}
                for search, render, text in re.findall(
                    r"MapRenderRepositories > ([\d.]+) / ([\d.]+) \(([\d.]+)\)s - search / render", log)
            ]
            for finish in finishes:
                # Bracket input dispatch; do not confuse native loading duration
                # with latency from the user's zoom command.
                finish["input_to_symbols_finish_ms_bounds"] = [
                    finish["epoch_ms"] - after / 1e6,
                    finish["epoch_ms"] - before / 1e6,
                ]
            sample = {
                "cycle": cycle + 1, "from_zoom": zoom, "to_zoom": target,
                "input_command_epoch_ns": [before, after],
                "refresh_period_ns": refresh,
                "surface_frames_ns": sorted(frames),
                "animation_intervals_ms": intervals,
                "animation_median_ms": statistics.median(intervals) if intervals else None,
                "animation_max_ms": max(intervals) if intervals else None,
                "native_finishes": finishes,
                "legacy_renders": legacy_renders,
            }
            result["samples"].append(sample)
            (args.output / "results.json").write_text(json.dumps(result, indent=2) + "\n")
            # Native FINISH logs getState().zoomLevel (flat zoom), while the UI
            # uses getZoomLevel()/surfaceZoomLevel. They need not be equal.
            print(stem, "animation intervals:", intervals, "native finish:", finishes, "legacy render:", legacy_renders, flush=True)
            zoom = target

    result["final_verified_viewport"] = verify_viewport()
    (args.output / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    screenshot = subprocess.check_output([args.adb, "-s", args.serial, "exec-out", "screencap", "-p"])
    (args.output / "final.png").write_bytes(screenshot)


if __name__ == "__main__":
    main()
