#!/usr/bin/env bash
# Fast plugin iteration, for use inside `nix develop`.
#
# `nix build .#apk-x86` is the hermetic artifact: it copies the source into a fresh
# sandbox, resolves every dependency through the mitm cache and runs gradle from cold —
# ~5 minutes, every time, even for a one-line UI change. That is the right trade for a
# release build and the wrong one for an edit-compile-look loop.
#
# So: keep nix for the expensive, rarely-changing halves (the two native cores, MPChart,
# ICU4J — all still built and cached by nix), and let gradle do what it is good at over a
# persistent tree: incremental compilation with a warm daemon. First run ~3 min (gradle
# populates ~/.gradle), then ~40 s per plugin edit.
#
# What it is NOT: hermetic. It resolves dependencies from the network into your ~/.gradle,
# and the tree in dev/ is mutable. Ship what `nix build` produces, iterate with this.
#
# Out-of-tree plugins come from $PLUGIN_DIR, in the same shape nix/osmand.nix's `plugins` takes:
# java/, app/, optionally res/, plus $PLUGIN_CLASS to register. Unset, this builds plain OsmAnd~~
# with the in-tree ring route, which is what you want when working on the forks themselves. A flake
# layering its own plugin calls this with both set — one dev loop, and it registers a plugin the
# same way mkApk does, so the two cannot drift.
#
#   nix develop -c ./dev.sh          # build, sign, install on the running emulator
#   nix develop -c ./dev.sh --setup  # re-materialise dev/ from scratch (after a nix bump)
#   PLUGIN_DIR=../my-plugin/plugin PLUGIN_CLASS=net.osmand.plus.plugins.mine.MyPlugin \
#     nix develop -c ./dev.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DEV="$ROOT/dev"
TASK="assembleAndroidFullOpenglX86Release"
PKG="net.osmand.plus"
KEYSTORE="$ROOT/.keys/debug.jks"
PLUGIN_DIR="${PLUGIN_DIR:-}"
PLUGIN_CLASS="${PLUGIN_CLASS:-}"

if [ -n "$PLUGIN_DIR" ] && [ -z "$PLUGIN_CLASS" ]; then
	echo "dev.sh: \$PLUGIN_DIR is set but \$PLUGIN_CLASS is not — I would copy the plugin in and" >&2
	echo "  never register it, and you would get a build with no plugin and no error." >&2
	exit 1
fi

# Build the forks from your local clones, exactly as ./local.sh does — otherwise these reach
# for the pinned github branches instead of the tree you are editing.
mapfile -t NIX_OVERRIDES < <("$ROOT/local.sh" --flags)
# mapfile cannot see local.sh's exit status through the process substitution, so without
# this a missing clone would carry on with no overrides and reach for the pinned branch —
# failing as a puzzling GitHub error rather than "you have no clone".
if [ ${#NIX_OVERRIDES[@]} -eq 0 ]; then
	echo "$(basename "$0"): ./local.sh --flags failed; see above" >&2
	exit 1
fi

if [ "${1:-}" = "--setup" ]; then
	rm -rf "$DEV"
fi

if [ ! -d "$DEV" ]; then
	echo "==> materialising dev/ (one-off)"
	# The same four prebuilt artifacts nix/osmand.nix consumes, and the same patched tree.
	prepared=$(nix build "${NIX_OVERRIDES[@]}" "$ROOT#prepared-x86"   --no-link --print-out-paths)
	opengl=$(nix build   "${NIX_OVERRIDES[@]}" "$ROOT#coreOpengl-x86" --no-link --print-out-paths)
	legacy=$(nix build   "${NIX_OVERRIDES[@]}" "$ROOT#coreLegacy-x86" --no-link --print-out-paths)
	mpchart=$(nix build  "${NIX_OVERRIDES[@]}" "$ROOT#mpchart-x86"    --no-link --print-out-paths)
	icu4j=$(nix build    "${NIX_OVERRIDES[@]}" "$ROOT#icu4j-x86"      --no-link --print-out-paths)

	mkdir -p "$DEV"
	cp -r --no-preserve=mode,ownership "$prepared"/. "$DEV"/

	# Plugins are a hardcoded list. The ring route registers itself in-tree now, so only an
	# out-of-tree one has to be spliced in, on the same anchor nix/osmand.nix uses.
	if [ -n "$PLUGIN_CLASS" ]; then
		helper="$DEV/android/OsmAnd/src/net/osmand/plus/plugins/PluginsHelper.java"
		grep -q "$PLUGIN_CLASS" "$helper" || sed -i \
			"s|allPlugins.add(new LoopRoutePlugin(app));|\&\\n\\t\\tallPlugins.add(new $PLUGIN_CLASS(app));|" \
			"$helper"
		grep -q "$PLUGIN_CLASS" "$helper" \
			|| { echo "could not register $PLUGIN_CLASS: the in-tree LoopRoutePlugin anchor is gone" >&2; exit 1; }
	fi

	install -Dm644 "$mpchart/MPChartLib-release.aar" "$DEV/android/OsmAnd/libs/MPChartLib-release.aar"
	install -Dm644 "$opengl/OsmAndCore_android-release.aar" "$DEV/android/OsmAnd/libs/OsmAndCore_android-release.aar"
	install -Dm644 "$opengl/OsmAndCore_androidNativeRelease-release.aar" \
		"$DEV/android/OsmAnd/libs/OsmAndCore_androidNativeRelease-release.aar"
	install -Dm644 "$icu4j/icu4j.jar" "$DEV/android/OsmAnd/libs/icu4j.jar"
	install -Dm644 "$icu4j/icu4j.jar" "$DEV/android/OsmAnd-java/libs/icu4j.jar"
	cp -a --reflink=auto "$legacy"/. "$DEV/android/OsmAnd/libs/"
	chmod -R u+w "$DEV/android/OsmAnd/libs"

	# The three build-time downloads, vendored — the init script disables the tasks.
	install -Dm644 "$ROOT/regions.ocbf" \
		"$DEV/android/OsmAnd-java/src/main/resources/net/osmand/map/regions.ocbf"
	basemap=$(nix build "${NIX_OVERRIDES[@]}" "$ROOT#worldBasemapMini" --no-link --print-out-paths 2>/dev/null || true)
	stars=$(nix build "${NIX_OVERRIDES[@]}" "$ROOT#starsDb" --no-link --print-out-paths 2>/dev/null || true)
	if [ -n "$basemap" ]; then
		install -Dm644 "$basemap" "$DEV/android/OsmAnd/build/generated/osmand/assets/World_basemap_mini.obf"
	fi
	if [ -n "$stars" ]; then
		mkdir -p "$DEV/android/OsmAnd/build/generated/osmand/assets/astro"
		gzip -dc "$stars" > "$DEV/android/OsmAnd/build/generated/osmand/assets/astro/stars.db"
	fi
fi

# The plugin is the only thing that changes; re-copy it on every run. Gradle notices the
# changed timestamps and recompiles just those classes. With no $PLUGIN_DIR there is nothing to
# sync — the fork's own sources arrive through the nix inputs, so an edit there needs --setup.
if [ -n "$PLUGIN_DIR" ]; then
	echo "==> syncing plugin sources from $PLUGIN_DIR"
	cp -r "$PLUGIN_DIR/java/." "$DEV/android/OsmAnd-java/src/main/java/"
	cp -r "$PLUGIN_DIR/app/."  "$DEV/android/OsmAnd/src/"
	[ -d "$PLUGIN_DIR/res" ] && cp -r "$PLUGIN_DIR/res/." "$DEV/android/OsmAnd/res/"
fi

echo "==> gradle $TASK"
start=$(date +%s)
# lintVital is skipped, and only here. It fails on OsmAnd's own code (a RecyclerView
# setHasFixedSize warning in SegmentsCard), which is upstream's lint debt and nothing this
# plugin can fix or should be blocked by. `nix build` stays the release path.
( cd "$DEV/android/OsmAnd" && gradle "$TASK" \
	-x "lintVital${TASK#assemble}" \
	--init-script "$ROOT/nix/prebuilt-core.gradle" \
	--init-script "$ROOT/nix/tolerant-deps.gradle" )
echo "==> built in $(( $(date +%s) - start ))s"

apk=$(find "$DEV/android/OsmAnd/build/outputs/apk" -name '*.apk' | head -1)
[ -n "$apk" ] || { echo "no APK produced" >&2; exit 1; }

# A release build is unsigned; the emulator will not install that.
if [ ! -f "$KEYSTORE" ]; then
	keytool -genkeypair -keystore "$KEYSTORE" -alias debug -storepass android -keypass android \
		-keyalg RSA -keysize 2048 -validity 10000 -dname "CN=OsmAnd~~ dev"
fi
build_tools=$(ls -d "$ANDROID_SDK_ROOT"/build-tools/* | sort -V | tail -1)
signed="$ROOT/osmand-x86-signed.apk"
"$build_tools/apksigner" sign --ks "$KEYSTORE" --ks-pass pass:android --key-pass pass:android \
	--out "$signed" "$apk"

echo "==> installing on the emulator"
adb install -r -d "$signed"
echo "==> done: $signed"
