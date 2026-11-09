# OsmAnd~~

OsmAnd built the way F-Droid builds it, hermetically, from a Nix flake — plus a
**ring route** plugin that plans a closed-loop walk under constraints.

```
nix build .#apk          # OsmAnd~~ 5.4.10, arm64/OpenGL, unsigned APK
nix build .#looproute    # headless ring-route planner (no Android needed)
nix run   .#route        # headless router: road, transit, GPX-approx (Java + native)
nix develop              # the exact toolchain F-Droid uses
```

CI signing and release-key setup are delegated to
[`nix-android-ci`](https://github.com/aleclearmind/nix-android-ci#signing-keys).

## What it builds

The recipe is a faithful port of
[`metadata/net.osmand.plus.yml`](https://gitlab.com/fdroid/fdroiddata/-/blob/master/metadata/net.osmand.plus.yml),
stable 5.4.10 `Builds:` entry:

The pinned release is **5.4.10**, the latest non-beta version distributed and
recommended by F-Droid as of 2026-11-09. The newer 5.4.11 beta is deliberately
excluded.

| | |
|---|---|
| source | `gitlab.com/f-droid-mirrors/OsmAnd-submodules` @ `v5.4.10` (`1576850f57b08a21e8a6c2701eb3901dba7f4aa9`, submodules) |
| …except | `android` → `aleclearmind/OsmAnd`, `core-legacy` → `aleclearmind/OsmAnd-core-legacy` |
| variant | `assembleAndroidFullOpenglArm64Release` (versionCode **541003**) |
| NDK | r28c (`28.2.13676358`) |
| app toolchain | Android API/build-tools 36, AGP 8.10.1, Kotlin 2.1.20, JDK 21 |
| steps | F-Droid's `rm:` → `prebuild.sh` → `build.sh` → `gradle` |

`prebuild.sh` and `build.sh` are run **unmodified**, so all of F-Droid's
de-Googling (billing, play-services, Huawei, ANT+) happens exactly as it does
upstream. The final APK is branded `OsmAnd~~` with application ID
`io.github.aleclearmind.osmand`, rather than F-Droid's `OsmAnd~` /
`net.osmand.plus`. Its provider authorities follow that ID, so both apps can be
installed side-by-side with separate Android data and upgrade histories.

Both native cores are compiled from source: the OpenGL core
(`libOsmAndCoreWithJNI.so` — Qt5, Skia, GDAL, Boost, ICU4C) and the legacy core
(`libosmand.so`, via `ndk-build`).

## Build times

The build is split so that editing Java cannot invalidate Qt. Measured on a
12-core box for 5.3.10, everything cold:

| `nix build .#…` | | |
|---|---|---|
| `prepared` | F-Droid's `rm:` + `prebuild.sh` | 21 s |
| `mpchart` | MPAndroidChart AAR | 37 s |
| `icu4j` | patched, trimmed ICU4J jar | 20 s |
| `coreLegacy` | `libosmand.so` (`ndk-build`, `-j2` upstream) | 4 m 09 s |
| `coreOpengl` | Qt5 + Skia + GDAL + Boost + ICU4C → the two core AARs | 16 m 21 s |
| `apk` | Gradle: the app itself | 4 m 12 s |

An out-of-tree plugin is an input to **`apk` alone**, so adding or editing one rebuilds
only that: **~4 minutes**, not ~26. The APK derivation gets the four artifacts prebuilt —
which is exactly what `build.sh` hands to Gradle — and `prebuilt-core.gradle` disables the
two app tasks (`:OsmAnd:buildOsmAndCore`, `:OsmAnd:copyOsmAndCoreWithJNI`) that would
otherwise rebuild the legacy core inside the Gradle run.

Editing the **android fork** costs more, but only where it must: `nix/default.nix` splices
each fork in only where it is actually read, so a Java change rebuilds the ndk core (which
runs `android/OsmAnd/old-ndk-build.sh`) and the APK — ~8 min — while the OpenGL core,
MPChart and ICU4J take the mirror's tree and do not move. Editing **core-legacy** rebuilds
the two native cores and not the app. Nix keys a derivation on its inputs, so this is the
difference between a one-line change costing 8 minutes and costing 42.
(`:OsmAnd:cleanupDuplicatesInCore` stays enabled: the prebuilt `.so` files need the
same `libc++_shared.so` de-duplication as freshly built ones.)

Nix has no incrementality *within* a derivation: every `nix build` reruns Gradle from
cold in a fresh sandbox, so even a one-line UI change costs the full ~4 minutes. For an
edit-compile-look loop that is the wrong trade, so `./dev.sh` keeps Nix for the
expensive, rarely-changing halves (both native cores, MPChart, ICU4J — still built and
cached by Nix) and lets Gradle do what it is good at over a persistent tree in `dev/`:
incremental compilation with a warm daemon.

```
nix develop -c ./dev.sh     # sync plugin -> gradle -> sign -> adb install
```

First run ~3 min (Gradle populates `~/.gradle`), then **~40 s** per plugin edit. It is
deliberately *not* hermetic — it resolves dependencies from the network and `dev/` is
mutable. Iterate with it; ship what `nix build` produces.

## Hermetic-ness

F-Droid's build is *not* hermetic: it downloads during the build. Each of those had
to be pinned so the sandbox needs no network.

| what F-Droid downloads mid-build | here |
|---|---|
| `core/externals/*/configure.sh` (Qt, Skia, GDAL, Boost, ICU4C, proj…) | 19 FODs, `nix/hashes.json` |
| `core-legacy/externals/*/configure.sh` | 5 more FODs |
| app/CLI Gradle/Maven artifacts | `nix/deps.json`, replayed by `mitm-cache` |
| native-wrapper/MPAndroidChart artifacts | `nix/core-deps.json`, kept stable across app dependency updates |
| `World_basemap_mini_2.obf`, `stars.db.gz` | `fetchurl`, pinned |
| `regions.ocbf` | **vendored** — see below |
| `sdkmanager "platforms;android-31"` | provided by `androidenv` |

Refresh the external hashes and app dependency lock after a version bump:

```
nix run .#update-hashes    # nix/hashes.json
nix run .#update-deps      # nix/deps.json
```

`update-deps` resolves the root tooling configurations, the app, and its Java,
shared Kotlin, and API modules. It
merges the capture with existing entries so dependencies of independent builds
are retained. `nix/core-deps.json` is a separate snapshot for the native wrappers
and MPAndroidChart: changes to the app lock do not rebuild Qt. If a dependency
update also affects those builds, refresh their snapshot with
`cp nix/deps.json nix/core-deps.json` and rebuild the cores and chart library.

`regions.ocbf` is the one input that cannot be pinned by hash: `builder.osmand.net`
regenerates it daily and serves every generation from the same URL, so a `fetchurl`
hash is a pin to a moving target — it holds until the next regeneration, then the flake
stops evaluating for everyone. There is no versioned URL, and upstream's resources repo
ships only a readme pointing back at that URL, so the bytes are carried here instead
(`regions.ocbf`, 7.4 MB). Refresh with
`curl -o regions.ocbf https://builder.osmand.net/basemap/regions.ocbf`.

### Where the sandbox forced a change

Five places where a Debian builder works and a Nix sandbox does not. Each is a
one-liner in `nix/osmand.nix`, and each is a real difference, not a workaround:

- **Qt's `configure` calls `/bin/pwd`** — only `/bin/sh` exists in the sandbox.
- **Qt's `syncqt.pl` never runs.** It is gated on `.git` existing, and the FOD
  strips `.git` (packfiles differ per fetch, which would make the hash unstable).
  An empty `.git` marker restores it; `syncqt.pl` itself never shells out to git.
- **`proj` links the host's `libpthread`.** Its CMakeLists does
  `find_library(PTHREAD_LIBRARY pthread)` for every non-Windows target. Android
  has no such library (Bionic puts pthread in libc), so on Debian the lookup comes
  back empty; under Nix it finds the *host* glibc and the arm64 link dies with
  `libpthread.so is incompatible with aarch64linux`.
- **Boost bootstraps `b2` with the host `clang`**, which F-Droid gets from `apt`.
- **aapt2** is taken from the SDK's build-tools rather than downloaded by AGP
  through a detached configuration that no lockfile can see.

## Where the code lives

Two of OsmAnd's repos are ours, as forks, spliced over the f-droid mirror's checkout by
`nix/default.nix`. Everything else in the tree (the OpenGL core, resources, MPAndroidChart, ICU)
still comes from the mirror at the tag.

| | fork | holds |
|---|---|---|
| `osmand-android` | `aleclearmind/OsmAnd` @ `osmand-flake-5.4.10` | the app, `OsmAnd-java`, the ring-route plugin, the routing CLI |
| `osmand-core-legacy` | `aleclearmind/OsmAnd-core-legacy` @ `osmand-flake-5.4.10` | `libosmand.so` — the native router the app and the CLI both load |

Both branches are cut from the exact commits the mirror pins, so an untouched fork builds the same
bytes F-Droid would — which is what makes "did our fork break it?" a question with an answer.

The ring-route plugin lives in the fork rather than here: it is an OsmAnd feature, written against
OsmAnd's own router, that upstream could take — so it belongs next to the code it extends, and
registers itself like every other plugin.

### Adding a plugin without adding it here

A plugin that upstream would *not* take doesn't belong in the fork, and one you would rather not
publish doesn't belong in this repo either. Those live in their own flake, which pins this one and
calls the two functions it exports:

```nix
{
  inputs.osmand-flake.url = "github:aleclearmind/osmand-flake";   # and no nixpkgs of your own

  outputs = { self, osmand-flake }:
    let osmand = osmand-flake.lib.x86_64-linux; in {
      packages.x86_64-linux = {
        apk = osmand.mkApk {
          appName = "OsmAnd My Plugin";
          applicationId = "io.github.example.osmand.myplugin";
          plugins = [ { src = ./plugin; class = "net.osmand.plus.plugins.mine.MyPlugin"; } ];
        };
        mytool = osmand.mkJavaCli {
          name = "mytool"; mainClass = "net.osmand.mine.MyCli"; pluginSrc = ./plugin;
          description = "...";
        };
      };
    };
}
```

`plugin/` holds `java/` (compiled into OsmAnd-java), `app/` (into the app) and optionally `res/`.
Only the app's gradle step re-runs — the cores, MPChart and ICU4J are unchanged by a plugin and come
straight from this flake's store paths, so Qt never rebuilds. Declaring your own `nixpkgs` is what
breaks that; take this flake's. Give every independently installed variant its own `appName` and
`applicationId`. `dev.sh` covers the same case: set `$PLUGIN_DIR`, `$PLUGIN_CLASS`, `$APP_NAME`, and
`$APPLICATION_ID`, and it registers and brands the plugin exactly as `mkApk` does.

To work on either fork, point the inputs at a local clone — no commit, no push, no `flake.lock`
churn. `./local.sh` is that, spelled once:

```
git clone https://github.com/osmandapp/OsmAnd.git             ../osmand
git clone https://github.com/osmandapp/OsmAnd-core-legacy.git ../osmand-core-legacy

./local.sh build .#route
./local.sh run   .#transit-datetime-test
```

It uses `git+file:`, so nix sees tracked files only — `git add` a new file before it can be built,
but committing is not required. Set `$OSMAND_ANDROID` / `$OSMAND_CORE_LEGACY` to point elsewhere.

## Measuring map redraws

`benchmark-zoom.py` drives the zoom buttons around central Milan (45.4642, 9.1900)
through levels 14–17. Install the Lombardia offline map first and dismiss onboarding.
For native symbol-loading times, enable the `debug_rendering` preference and restart
OsmAnd; without it, the script still records displayed-frame timestamps.

```sh
python3 benchmark-zoom.py --serial emulator-5554 \
  --package io.github.aleclearmind.osmand --output /tmp/milan-public
```

Pass another build's application ID to compare variants.

On a rooted emulator, add `--verify-viewport` to check the actual coordinates and
zoom through the saved app settings before and after the run. The script starts
a fresh activity for the target location and saves a final screenshot.

The output includes raw SurfaceFlinger timestamps, native timing logs, the APK's
package metadata, and JSON measurements. Native `FINISH` measures symbol loading;
it is separate from animation frame intervals and command-to-finish latency.
For the 2D engine, `legacy_renders` records map search and bitmap rendering
durations (rounded to 10 ms in the source logs), separately from frame timing.
The requested levels are surface zoom; the native log records flat camera zoom,
which can differ even when the requested zoom was reached.
Compare runs with the same map, viewport, density, renderer, and idle host. A 60 Hz
screen has a 16.7 ms frame budget. Software graphics measurements do not establish
phone GPU performance.

`run-emulator.sh` lets the emulator select hardware when a GPU device is accessible,
and uses SwiftShader otherwise. Set `OSMAND_GPU_MODE=host` or
`OSMAND_GPU_MODE=swiftshader` to make the backend explicit during comparisons.
KVM accelerates the emulated CPU; graphics acceleration needs a separate GPU
device. On CPU-only emulators, compare **Settings → OsmAnd settings → Map rendering
engine → Version 1** as a 2D fallback. Restart the app after changing the engine.

## The ring-route plugin

OsmAnd routes A → B. It has nothing that comes back to where it started, and
nothing that plans against a *budget* (this long, this much climb, no steeper than
this). `net.osmand.router.LoopRoutePlanner` adds that.

Constraints: target length, max total ascent, max sustained slope, max distance
from the start ("area"), max altitude, and max **retraced** fraction.

It lives in `OsmAnd-java`, which is plain Java — so the same code that runs in the
app runs headless against a local `.obf`:

```
nix run .#looproute -- --obf Italy_piemonte_europe_2.obf \
    --lat 45.76847 --lon 8.01307 \
    --length 12000 --max-ascent 700 --max-slope 25 \
    --radius 5000 --max-retrace 25 --gpx rassa-loop.gpx
```

In the app: enable **Ring route** in Plugins, then the drawer entry asks for the
constraints and plans loops from the map centre. It offers **several options to
scroll through** — the way public transport routing offers several journeys — each
card showing the loop's length, climb, altitude range, and a tick or a cross against
every constraint you set. Tapping one draws it on the map; only *Save* writes it to
the tracks folder.

The planner evaluates a hundred-odd candidates anyway, so keeping the good ones is
free. They are deduplicated by how much road they share (>60% overlap is the same
walk, not an option), because the hill-climb otherwise returns five near-copies of
the leader.

### How it works

The router only does A→B→…→Z, so a ring is built on top of it: place via-points
around a circle of circumference ≈ the target length, route
`start → via₁ → … → viaₙ → start`, measure what came back, and move the via-points.
A bearing sweep with several seed radii explores; a hill-climb refines. Every
candidate is scored on length error, ascent/slope/area/altitude violations, and how
much of it is walked twice.

Two things that look like details but decide whether it works at all:

- **Via-points are snapped to the road network, and a snap further than 400 m is
  rejected.** `findRouteSegment` always answers — it widens its search until it hits
  something. In the mountains that something is a kilometre away, back in the valley,
  so an unfiltered snap collapses every via-point onto the same road and the "ring"
  becomes an out-and-back. Rejecting distant snaps is what detects that a sector has
  no ways in it.
- **Retracing is a constraint, not a preference.** Without it a dead-end valley
  returns an out-and-back that satisfies every other constraint while being the
  opposite of a ring.

Elevation is read from the routing section of the `.obf` (`osmand_ele_start` /
`osmand_ele_asc` / `osmand_ele_desc`), so it needs no DEM, no GeoTIFF and no native
code — a stock OsmAnd map has it. Ascent is computed with OsmAnd's own
`ElevationDiffsCalculator` (threshold-filtered, so it reports climb rather than
accumulating sample noise), and slope over a 60 m window rather than between
adjacent shape points, whose spacing is arbitrary.

### Rassa (VC), 45.76847, 8.01307 — 924 m

Asking for 12 km with ≤700 m of climb returns five genuinely different loops:

| | length | ascent | max slope | retraced | peak |
|---|---|---|---|---|---|
| 1 | 12.99 km | 1180 m | 56% | 10% | 1698 m |
| 2 | 14.30 km | 1195 m | 52% | 16% | 1698 m |
| 3 | 11.94 km | 772 m | 70% | 51% | 1336 m |
| 4 | 5.96 km | **625 m** | 59% | 51% | 1271 m |
| 5 | 11.79 km | 1294 m | 63% | 50% | 1490 m |

Only option 4 gets under the 700 m climb budget, and it does so by being half the
length and doubling back on itself. That trade-off is the answer, and it is exactly
what having options is for.

The flagship, `rassa-loop.gpx` (option 1):

```
length              12.99 km   (target 12.00)
ascent             1180 m      (max 700)  EXCEEDED
max slope            56 %      (max 25)   EXCEEDED
retraced             10 %      (max 25)   ok
radius from start  2.27 km     (max 5.00) ok
altitude          924 → 1698 m
```

A genuine closed ring (start = end to the metre, 10% retraced), but it cannot meet
700 m of ascent or a 25% slope cap — and that is the terrain talking, not the
planner. Rassa sits at 924 m at the head of a dead-end valley: at 1.9 km out there
are 20 ways to the west and 4 to the east, and **none** to the north or south, which
are sheer mountainside. Any loop that is not an out-and-back has to climb out of the
valley, and the mule tracks that do so run at 40–55%. Ask for a gentler loop
(`--length 6000 --max-ascent 250`) and it stays in the valley and honours the climb
budget.

## Routing

OsmAnd's routers all live in `OsmAnd-java` (the plain-Java module) and read a local `.obf`
directly, so — like the ring-route planner — they run headless on any JVM, no device.
`net.osmand.router.RouteCli` exposes the whole of it through one `route` command:

```
nix run .#route -- --obf Italy_piemonte_europe_2.obf --mode car \
    --from 45.0625,7.6785 --to 45.2008,7.6497 --directions

=== java ===
  18.98 km, 33 min, 125 road segments
  directions:
    Go ahead               Corso Vittorio Emanuele II         665 m
    Keep left (+C,TSLR)    Corso Principe Oddone             9414 m
    Turn slightly left     Raccordo Autostradale Torino-Caselle  1966 m
    Take 3 exit            SP10                               226 m
    ...
```

- `--mode car|bicycle|pedestrian|boat|ski|moped|horsebackriding|wheelchair|train` —
  vehicle routing via `RoutePlannerFrontEnd`, A → B with `--via` intermediate points.
- `--mode public_transport` — journeys across trams/buses/metro via `TransportRoutePlanner`.
  `nix run .#transit` is exactly this: `route --mode public_transport`.
- `--approx-gpx IN.gpx` — snap a recorded track onto the road network (GPX approximation).
- `--param key=value` — any `GeneralRouter` knob (`avoid_toll=true`, `avoid_motorway=true`,
  `height_obstacles=true`, `short_way=true`, …), the same switches the app's profiles toggle.
- `--hh` / `--hh-cpp` — the hierarchical-highway router (fast; needs maps with HH data),
  Java or native.
- `--directions` (turn-by-turn) and `--gpx OUT` (write the routed track).
- `--datetime` — for public transport, which moment to route at (see below).
- `--search QUERY` / place names in `--from`/`--to`/`--via` (see below).

### When you travel

Public-transport routes carry `opening_hours`, so "how do I get there" has a different answer at
07:00 than at midday: 220 of the 390 routes around Turin are tagged, and GTT runs a *Feriale* and a
*Festivo* network over the same corridors. `--datetime` drops the ones that are not running:

```
nix run .#transit -- --obf MAP.obf --from 45.03286,7.60400 --to 45.03393,7.67221 \
    --datetime 2026-07-21T06:00        # a Tuesday: bus 34 (Mo-Fr 04:30-07:11) is offered
    --datetime 2026-07-21T10:30        # same day, 3 hours later: it is gone
    --datetime 2026-07-19T06:00        # a Sunday: gone — it is a Feriale line
    --datetime off                     # ignore opening_hours entirely
```

It defaults to `now`, matching the app, where it is **Departure time…** in the route options next to
*Avoid transport types…* — now, a picked date and time, or *Ignore timetables*.

The filter is applied by **both** engines: in `TransportRoutingContext` for Java and in
`transportRoutingContext.cpp` for the native core, with the two config fields carried across JNI by
`java_wrap.cpp`. That is the reason `OsmAnd-core-legacy` is forked at all — the app routes natively
by default, so a filter that only existed in Java would pass every CLI test and do nothing on a
phone. `nix run .#transit-datetime-test` asserts the three cases above on both engines, with
`--datetime off` as the control.

### Looking places up

`--search` runs OsmAnd's own search engine (`SearchUICore` — the one behind the app's search box)
against the map, and `--from`/`--to`/`--via` accept a name anywhere coordinates would go, printing
what they resolved to:

```
nix run .#route -- --obf MAP.obf --search "Porta Nuova" --near 45.06,7.67

 1. Porta Nuova                    POI    45.06252,7.67701
 3. Torino Porta Nuova             POI    45.05658,7.67450

nix run .#transit -- --obf MAP.obf --from "Porta Nuova" --to "Porta Susa"

--from "Porta Nuova" -> Torino Porta Nuova (POI) at 45.05658,7.67450
--to   "Porta Susa"  -> Porta Susa A (POI) at 45.07066,7.66395
```

Ranking is relative to `--near`, defaulting to the centre of the first map.

### Two backends

Every mode runs on either engine, and on a device the app uses the native one by default
(`PT_SAFE_MODE = false`):

- `--backend java` — the pure-Java engine (`RoutePlannerFrontEnd` / `TransportRoutePlanner`).
  Runs on any JVM, no native code. This is the app's *fallback*.
- `--backend native` — the legacy C++ core (`libosmand.so`) through the very JNI entries the
  app calls (`NativeLibrary.nativeRouting` / `runNativePTRouting`). This is the app's *default*.

`--backend both` runs each and diffs them, to catch the two implementations drifting — which
is exactly what you cannot see from the app:

```
nix run .#route-native -- --obf MAP.obf --from LAT,LON --to LAT,LON --backend both

=== java vs native ===
                   java       native
  distance km      18.98        18.98
  time min          33.0         33.0
  backends AGREE (distance within 50 m, time within 1 min)
```

The native backend needs `libosmand.so` built **for the host, not for Android**. The APK's
legacy core is compiled with `ndk-build` against Bionic and will not load in a desktop JVM;
`nix build .#core-legacy-linux` instead drives core-legacy's CMake desktop target (`amd64-linux`
— Skia + GDAL from source, ~18 m) to produce a glibc `libosmand.so`, the same library
OsmAndMapCreator loads. `nix run .#route-native` / `.#transit-native` wire it in through
`$OSMAND_NATIVE_LIB` so `--backend native`/`both` need no flags. Keeping the native core out of
`.#route`'s inputs means the pure-Java tool never pays for that 18-minute build.

Acceptance tests fetch the live Piemonte map, like the ring-route test does: `nix run
.#route-test` plans a car route across Turin, `nix run .#transit-test` a metro trip; `nix run
.#transit-diff-test` runs both backends and asserts they agree; `nix run .#transit-datetime-test`
checks the `opening_hours` filter on both engines. The last two compile the native core.
