{
  pkgs,
  androidSrc,
  coreLegacySrc,
}:

let
  inherit (pkgs) lib;

  versions = import ./versions.nix;
  hashes = builtins.fromJSON (builtins.readFile ./hashes.json);

  # F-Droid ships one APK per ABI. The x86 flavour carries x86 *and* x86_64
  # (build-common.gradle abiFilters), so it runs natively on an x86_64 emulator —
  # no ARM translation.
  variants = {
    arm64 = versions;
    x86 = versions // {
      abi = "x86";
      versionCode = "${lib.removeSuffix "3" versions.versionCode}2";
      gradleTask = "assembleAndroidFullOpenglX86Release";
    };
  };

  # The tree exactly as F-Droid checks it out: the submodule mirror at the tag, which pins
  # every OsmAnd repo to one commit.
  srcMirror = pkgs.callPackage ./source.nix {
    inherit versions;
    hash = hashes.src;
  };

  # ...with the submodules we maintain swapped for our forks:
  #
  #   android      the app, OsmAnd-java, the ring-route plugin and the routing CLI
  #   core-legacy  the native router — the libosmand.so both the app and the CLI's
  #                native backend load
  #
  # Everything else (the OpenGL core, resources, MPAndroidChart, ICU) still comes from the
  # mirror at the tag, so this is F-Droid's tree apart from the two repos we own. The forks
  # are branched off the very commits the mirror pins, so with no local changes this splice
  # is a content no-op — which is what makes "did our fork break it?" answerable.
  #
  # Splice in only what a consumer actually reads. Nix keys a derivation on its inputs, so a
  # tree carrying both forks makes *every* artifact downstream depend on both: with one such
  # tree, editing a line of Java rebuilt Qt (16 min) and Skia (18 min), because `prepared` and
  # `coreLegacyLinux` both hang off it. That is the invariant prepared.nix and core-legacy.nix
  # are built around — it used to hold because the plugin entered at the leaves, and moving the
  # plugin in-tree is exactly what would have quietly broken it.
  spliceForks =
    name: forks:
    pkgs.runCommandLocal "osmand-src-${name}-${versions.versionName}" { } (
      ''
        cp -a --reflink=auto ${srcMirror} "$out"
        chmod -R u+w "$out"
      ''
      + lib.concatStrings (
        lib.mapAttrsToList (path: fork: ''
          rm -rf "$out/${path}"
          cp -a --reflink=auto ${fork} "$out/${path}"
          chmod -R u+w "$out/${path}"
        '') forks
      )
    );

  # Everything we own: what the app, the CLI and the ndk core are built from.
  src = spliceForks "full" {
    "android" = androidSrc;
    "core-legacy" = coreLegacySrc;
  };

  # The native router alone. core-legacy-linux.nix only ever enters core-legacy/, so this keeps
  # its ~18-minute CMake build off the android fork — a Java edit must not rebuild Skia.
  srcCoreLegacy = spliceForks "core-legacy" { "core-legacy" = coreLegacySrc; };

  # core/externals is the mirror's, core-legacy/externals is ours; neither reads android/.
  externals = pkgs.callPackage ./externals.nix {
    src = srcCoreLegacy;
    inherit versions;
    hashes = hashes.externals;
  };

  isExternalFor = prefix: drv: lib.isDerivation drv && lib.hasPrefix "${prefix}/" drv.targetPath;
  coreExternals = lib.filter (isExternalFor "core/externals") (lib.attrValues externals);
  legacyExternals = lib.filter (isExternalFor "core-legacy/externals") (lib.attrValues externals);

  androidComposition = pkgs.androidenv.composeAndroidPackages {
    platformVersions = [ versions.compileSdk ] ++ versions.extraPlatforms;
    buildToolsVersions = [ versions.buildToolsVersion ] ++ versions.extraBuildTools;
    ndkVersions = [ versions.ndkVersion ];
    includeNDK = true;
    includeEmulator = false;
    includeSystemImages = false;
    includeSources = false;
  };

  androidSdk = androidComposition.androidsdk;
  sdkRoot = "${androidSdk}/libexec/android-sdk";
  ndkRoot = "${sdkRoot}/ndk/${versions.ndkVersion}";

  # Maven resolution includes shared Android modules, which still target API 35.
  # Supply their SDK components too, without a native compiler or emulator.
  dependencySdk =
    (pkgs.androidenv.composeAndroidPackages {
      platformVersions = [ versions.compileSdk ] ++ versions.extraPlatforms;
      buildToolsVersions = [ versions.buildToolsVersion ] ++ versions.extraBuildTools;
      includeNDK = false;
      includeCmake = false;
      toolsVersion = null;
    }).androidsdk;

  # Shared by every derivation that shells out to OsmAnd's own build scripts.
  androidEnv = {
    ANDROID_HOME = sdkRoot;
    ANDROID_SDK_ROOT = sdkRoot;
    # core/externals/qtbase-android/build.sh checks $ANDROID_SDK specifically, and
    # CMake's execute_process just inherits our environment.
    ANDROID_SDK = sdkRoot;
    ANDROID_NDK = ndkRoot;
    ANDROID_NDK_HOME = ndkRoot;
    ANDROID_NDK_ROOT = ndkRoot;
    ANDROID_SDK_BUILD_TOOLS_REVISION = versions.buildToolsVersion;
    JAVA_HOME = "${pkgs.jdk21}";
  };

  # OsmAnd's scripts call `gradle` in their own bash processes, so they never see the
  # gradleFlagsArray the nixpkgs hook assembles. Put the settings where every JVM will
  # find them instead.
  #
  # aapt2: AGP normally downloads a matching aapt2 from Maven through a detached
  # configuration created at task-execution time, which nixDownloadDeps cannot see and so
  # never lands in deps.json. The SDK's build-tools already ship the binary — point AGP at
  # it and the download disappears entirely.
  mkGradleProps = sdkRoot: ''
    # AGP creates analytics/preferences state even for offline builds. The Nix
    # builder's home is read-only; keep Android's state in this build directory.
    export ANDROID_USER_HOME="$TMPDIR/android-user-home"
    mkdir -p "$ANDROID_USER_HOME"

    {
      echo "org.gradle.daemon=false"
      echo "org.gradle.console=plain"
      echo "android.aapt2FromMavenOverride=${sdkRoot}/build-tools/${versions.buildToolsVersion}/aapt2"
    } >> "$GRADLE_USER_HOME/gradle.properties"

    if [ -n "''${MITM_CACHE_CA-}" ]; then
      {
        echo "systemProp.http.proxyHost=$MITM_CACHE_HOST"
        echo "systemProp.http.proxyPort=$MITM_CACHE_PORT"
        echo "systemProp.https.proxyHost=$MITM_CACHE_HOST"
        echo "systemProp.https.proxyPort=$MITM_CACHE_PORT"
        echo "systemProp.javax.net.ssl.trustStore=$MITM_CACHE_KEYSTORE"
        echo "systemProp.javax.net.ssl.trustStorePassword=$MITM_CACHE_KS_PWD"
      } >> "$GRADLE_USER_HOME/gradle.properties"
    fi
  '';

  gradleProps = mkGradleProps sdkRoot;
  dependencyGradleProps = mkGradleProps "${dependencySdk}/libexec/android-sdk";

  # Everything that depends on the ABI, built per variant.
  #
  # Two prepared trees, because what a consumer reads decides what can invalidate it. Only the
  # ndk core and the APK enter android/; the OpenGL core (core/wrappers/android), MPAndroidChart
  # and ICU4J never do, so they take the mirror's tree and no edit to either fork can rebuild
  # them. That is what keeps a one-line Java change off the 16-minute Qt build.
  mkVariant = versions: rec {
    prepared = pkgs.callPackage ./prepared.nix { inherit versions src; };
    preparedMirror = pkgs.callPackage ./prepared.nix {
      inherit versions;
      src = srcMirror;
    };

    coreOpengl = pkgs.callPackage ./core-opengl.nix {
      inherit
        versions
        coreExternals
        androidSdk
        sdkRoot
        ndkRoot
        androidEnv
        gradleProps
        ;
      prepared = preparedMirror;
      jdk21 = pkgs.jdk21;
    };

    coreLegacy = pkgs.callPackage ./core-legacy.nix {
      inherit
        versions
        prepared
        legacyExternals
        androidSdk
        sdkRoot
        ndkRoot
        androidEnv
        ;
    };

    mpchart = pkgs.callPackage ./mpchart.nix {
      inherit
        versions
        androidSdk
        sdkRoot
        androidEnv
        gradleProps
        ;
      prepared = preparedMirror;
      jdk21 = pkgs.jdk21;
    };

    icu4j = pkgs.callPackage ./icu4j.nix {
      inherit versions;
      prepared = preparedMirror;
      jdk21 = pkgs.jdk21;
    };

    # The APK, as a function of the plugins layered on. This repo builds it with none — the ring
    # route is in-tree in the android fork and registers itself — but it is exported (lib.mkApk)
    # so a flake carrying its own plugin can re-run just this gradle step. Everything expensive
    # above is unchanged by a plugin, so those flakes get the cores from the store.
    mkApk =
      {
        plugins ? [ ],
        appName ? versions.appName,
        applicationId ? versions.applicationId,
      }:
      pkgs.callPackage ./osmand.nix {
        inherit
          versions
          prepared
          plugins
          appName
          applicationId
          coreOpengl
          coreLegacy
          mpchart
          icu4j
          androidSdk
          dependencySdk
          dependencyGradleProps
          sdkRoot
          ndkRoot
          regionsOcbf
          worldBasemapMini
          starsDb
          androidEnv
          gradleProps
          ;
        jdk21 = pkgs.jdk21;
      };

    apk = mkApk { };
  };

  arm64 = mkVariant variants.arm64;
  x86 = mkVariant variants.x86;

  # OsmAnd-java's :collectRegionsInfoResources is a gradle Download task, i.e. it fetches
  # at *build* time rather than through dependency resolution — so nixDownloadDeps never
  # sees it and it can't come from deps.json.
  #
  # It has to be *vendored*, not fetched: builder.osmand.net regenerates regions.ocbf
  # daily and serves every generation from the same URL, so a fetchurl hash pin here is a
  # pin to a moving target — it holds only until the next rebuild, then the flake stops
  # evaluating for everyone. There is no versioned URL and no copy in git upstream (the
  # resources repo ships only a readme pointing back at that URL), so the only way to make
  # this input immutable is to carry the bytes ourselves. To refresh:
  #   curl -o regions.ocbf https://builder.osmand.net/basemap/regions.ocbf
  regionsOcbf = ../regions.ocbf;

  # Same story for the app's two other Download tasks, whose outputs are packaged as
  # assets (build-common.gradle wires build/generated/osmand/assets as an assets srcDir).
  worldBasemapMini = pkgs.fetchurl {
    url = "https://builder.osmand.net/basemap/release/2026-06/World_basemap_mini_2.obf";
    hash = "sha256-EWbmd4N65zlv+PTorFMmK0t6OeQgUj9zN8G1XsZQMnQ=";
  };

  starsDb = pkgs.fetchurl {
    url = "https://builder.osmand.net/basemap/astro/stars.db.gz";
    hash = "sha256-1KbhSp+pBLvY1KrMLNGQAuH+/q0kM1CbJuP1Zb4HHSo=";
  };

  # A second SDK composition, purely to run the thing: the emulator plus an x86_64
  # system image. Kept separate from the build SDK so the build never depends on a
  # 1.5 GB system image it has no use for.
  emulatorComposition = pkgs.androidenv.composeAndroidPackages {
    platformVersions = [ "34" ];
    buildToolsVersions = [ versions.buildToolsVersion ];
    abiVersions = [ "x86_64" ];
    systemImageTypes = [ "default" ]; # AOSP: no Play services, matching an F-Droid build
    includeEmulator = true;
    includeSystemImages = true;
    includeNDK = false;
    includeSources = false;
  };
  emulatorSdk = emulatorComposition.androidsdk;

  # Every headless tool over OsmAnd-java is the same derivation bar a name and a main class, so
  # there is one of it. Exported as the flake's lib.mkJavaCli, which is how a flake layering a
  # private plugin builds its own CLI without a second copy of all this.
  mkJavaCli =
    args:
    pkgs.callPackage ./cli.nix (
      {
        inherit
          versions
          src
          androidSdk
          sdkRoot
          regionsOcbf
          gradleProps
          ;
        jdk21 = pkgs.jdk21;
      }
      // args
    );

  looproute = mkJavaCli {
    name = "looproute";
    mainClass = "net.osmand.router.LoopRouteCli";
    heap = "4g";
    description = "Plan a constrained ring (loop) walking route on an OsmAnd .obf map";
  };

  route = mkJavaCli {
    name = "route";
    mainClass = "net.osmand.router.RouteCli";
    description = "Plan OsmAnd routes from the command line — road, transit or GPX approximation, pure-Java or native backend";
  };

  # The legacy native core, built for x86_64-linux/glibc instead of Android — the same
  # libosmand.so OsmAndMapCreator loads on the desktop. This is what lets the route CLI's native
  # backend (NativeLibrary.nativeRouting / runNativePTRouting) run in a plain JVM.
  coreLegacyLinux = pkgs.callPackage ./core-legacy-linux.nix {
    inherit versions legacyExternals;
    src = srcCoreLegacy;
  };

  # These four are thin makeWrapper wrappers around the (already-built) route jar — not
  # route.override, which would rebuild the whole gradle derivation each time. `-native` points
  # $OSMAND_NATIVE_LIB at the built core so `--backend native`/`both` need no flags; `transit` is
  # the same tool pinned to --mode public_transport, so the public-transport command still exists.
  mkWrapper =
    name: bin: env: flags:
    pkgs.runCommandLocal "osmand-${name}-${versions.versionName}"
      {
        nativeBuildInputs = [ pkgs.makeWrapper ];
        meta.mainProgram = bin;
      }
      ''
        makeWrapper ${route}/bin/route "$out/bin/${bin}" ${env} ${flags}
      '';

  routeNative = mkWrapper "route-native" "route" "--set OSMAND_NATIVE_LIB ${coreLegacyLinux}/lib" "";
  transit = mkWrapper "transit" "transit" "" "--add-flags '--mode public_transport'";
  transitNative =
    mkWrapper "transit-native" "transit" "--set OSMAND_NATIVE_LIB ${coreLegacyLinux}/lib"
      "--add-flags '--mode public_transport'";

  # The toolchain F-Droid installs with apt, pinned by nix instead:
  #   ant g++ cmake clang build-essential swig python-is-python3 zip
  shell = pkgs.mkShell {
    packages = with pkgs; [
      gradle
      jdk21
      androidSdk
      cmake
      gnumake
      clang
      swig
      ant
      python3
      zip
      unzip
      git
      perl
      jq
    ];

    inherit (androidEnv)
      ANDROID_HOME
      ANDROID_SDK_ROOT
      ANDROID_SDK
      ANDROID_NDK
      ANDROID_NDK_HOME
      ANDROID_NDK_ROOT
      ANDROID_SDK_BUILD_TOOLS_REVISION
      JAVA_HOME
      ;

    shellHook = ''
      echo "${versions.appName} — OsmAnd ${versions.versionName} (${versions.abi}), F-Droid toolchain"
      echo "  ANDROID_HOME = $ANDROID_HOME"
      echo "  ANDROID_NDK  = $ANDROID_NDK"
    '';
  };

  updateHashes = pkgs.writeShellApplication {
    name = "update-external-hashes";
    runtimeInputs = [
      pkgs.jq
      pkgs.nix
    ];
    text = ''
      # Rebuild each FOD with a bogus hash and record the one nix reports.
      json="''${1:-nix/hashes.json}"
      targets=(src ${
        lib.concatStringsSep " " (builtins.attrNames (lib.filterAttrs (_: lib.isDerivation) externals))
      })

      for t in "''${targets[@]}"; do
        current=$(jq -r --arg t "$t" '
          if $t == "src" then .src else .externals[$t] end' "$json")
        if [ "$current" != "${lib.fakeHash}" ]; then
          echo "$t: already pinned"
          continue
        fi
        echo "$t: fetching..."
        got=$(nix build --no-link ".#$t" 2>&1 | grep -oP 'got:\s+\K sha256-\S+' | tr -d ' ' || true)
        if [ -z "$got" ]; then
          echo "$t: could not determine hash" >&2
          continue
        fi
        if [ "$t" = src ]; then
          jq --arg h "$got" '.src = $h' "$json" > "$json.tmp"
        else
          jq --arg n "$t" --arg h "$got" '.externals[$n] = $h' "$json" > "$json.tmp"
        fi
        mv "$json.tmp" "$json"
        echo "$t: $got"
      done
    '';
  };

  # Every acceptance test below needs a real map, and a nix build sandbox has no network to fetch
  # one; a fixed-output derivation could, but pinning a hash to OsmAnd's rolling map only ever rots.
  # So they run in your shell, and each fetches the current Piemonte map — cached, so only the first
  # run of the first test pays for it.
  #
  # $cache is deliberately shared between all of them, which is exactly why this is written once:
  # five copies of a path that must agree would go on agreeing right up until one of them didn't,
  # and the only symptom would be a test quietly re-downloading 288 MB.
  fetchPiemonteMap = ''
    cache="''${XDG_CACHE_HOME:-$HOME/.cache}/osmand-looproute-test"
    obf="$cache/Italy_piemonte_europe_2.obf"
    url="https://download.osmand.net/download?standard=yes&file=Italy_piemonte_europe_2.obf.zip"

    if [ ! -f "$obf" ]; then
      echo "fetching the Piemonte map (~288 MB, once) ..."
      mkdir -p "$cache"
      curl -fL --retry 3 -o "$cache/map.zip" "$url"
      unzip -o "$cache/map.zip" -d "$cache"
      rm -f "$cache/map.zip"
    fi

    fail() { echo "TEST FAILED: $1"; exit 1; }
  '';

  mapTestInputs = [
    pkgs.curl
    pkgs.unzip
    pkgs.coreutils
  ];

  # The planner's acceptance test, as something you run rather than something the build bakes in.
  #
  # `nix run .#test` plans the canonical walk: from Rassa, the round up the Val Sorba to Alpe del
  # Prato and back down the Val Gronda. It asserts that ~20 km / ~1500 m ring is offered and ranked
  # first. Loose bounds on purpose — the assertion is "the walk over the Gronda pass is still
  # found", not a fingerprint of one map version's metres.
  looprouteTest = pkgs.writeShellApplication {
    name = "looproute-test";
    runtimeInputs = mapTestInputs ++ [
      looproute
      pkgs.gawk
    ];
    text = fetchPiemonteMap + ''
      echo "planning the Rassa round ..."
      report=$(looproute --obf "$obf" --lat 45.7684 --lon 8.0131 --length 20000 --ascent 1500 2>&1)

      echo "$report" | grep -q "Gronda" \
        || fail "the ring over the Val Gronda was not among the options"

      # Option 1 is the best-ranked ring; it should be the Rassa round.
      len=$(echo "$report" | awk '/\[ option 1 \]/{f=1} f&&/^  length/{print $2; exit}')
      asc=$(echo "$report" | awk '/\[ option 1 \]/{f=1} f&&/^  ascent /{print $2; exit}')
      [ -n "$len" ] && [ -n "$asc" ] || fail "could not read option 1 (planner returned nothing?)"
      awk -v l="$len" 'BEGIN{exit !(l>=16 && l<=22)}' \
        || fail "option 1 is $len km, not the ~20 km Rassa round"
      awk -v a="$asc" 'BEGIN{exit !(a>=1200 && a<=1800)}' \
        || fail "option 1 climbs $asc m, not the ~1500 m of the Rassa round"

      echo "TEST PASSED: option 1 is the Rassa round, $len km / $asc m, over the Val Gronda"
    '';
  };

  # The transit router's acceptance test, mirroring looprouteTest: it fetches the current Piemonte
  # map (shared with that test's cache, so usually already on disk) and plans a public-transport
  # trip across central Turin — Porta Nuova to Porta Susa — asserting the best option is the M1
  # metro that actually connects them. Pure-Java backend, so it needs no native core. Loose on
  # purpose: the assertion is "the metro between these two stations is still found", not a
  # fingerprint of one map version.
  transitTest = pkgs.writeShellApplication {
    name = "transit-test";
    runtimeInputs = mapTestInputs ++ [
      transit
      pkgs.gawk
    ];
    text = fetchPiemonteMap + ''
      echo "planning a Turin transit trip: Porta Nuova -> Porta Susa ..."
      # Pinned to a Tuesday midday, when everything runs. --datetime defaults to `now`, which would
      # make this assertion depend on the clock: the M1 does not run at 03:00, and a test that fails
      # overnight is testing the hour, not the router.
      report=$(transit --obf "$obf" --from 45.0625,7.6785 --to 45.0721,7.6663 \
        --datetime 2026-07-21T10:30 --backend java 2>/dev/null)
      echo "$report"

      echo "$report" | grep -qE "=== java: [1-9][0-9]* routes? ===" \
        || fail "no public-transport route was found"

      # Option 1 is the best-ranked itinerary; between these two stations it is the M1 metro.
      opt1=$(echo "$report" | awk '/\[ java option 1 \]/{f=1;next} /\[ java option [0-9]+ \]/{f=0} f')
      echo "$opt1" | grep -q "M1"         || fail "option 1 is not the M1 metro"
      echo "$opt1" | grep -q "Porta Susa" || fail "option 1 does not reach Porta Susa"

      echo "TEST PASSED: option 1 is the M1 metro from Porta Nuova to Porta Susa"
    '';
  };

  # The differential test — the reason both backends exist. It plans the same Turin trip with
  # --backend both (native core wired in via transitNative) and asserts the pure-Java engine and
  # the native C++ core agree on the best route. Heavier than transitTest: building it compiles
  # the legacy core (core-legacy-linux). This is what catches the two implementations drifting.
  transitDiffTest = pkgs.writeShellApplication {
    name = "transit-diff-test";
    runtimeInputs = mapTestInputs ++ [ transitNative ];
    text = fetchPiemonteMap + ''
      echo "planning Porta Nuova -> Porta Susa with BOTH backends ..."
      # Pinned for the same reason as transitTest: --datetime defaults to `now`, and this should
      # answer "do the two engines agree", not "what time is it".
      report=$(transit --obf "$obf" --from 45.0625,7.6785 --to 45.0721,7.6663 \
        --datetime 2026-07-21T10:30 --backend both 2>/dev/null)
      echo "$report"

      echo "$report" | grep -qE "=== java: [1-9]"   || fail "java backend found no route"
      echo "$report" | grep -qE "=== native: [1-9]" || fail "native backend found no route"
      echo "$report" | grep -q "backends AGREE" \
        || fail "the java and native backends disagree on the best route"

      echo "TEST PASSED: the java and native backends agree on the Turin trip"
    '';
  };

  # The opening_hours filter's acceptance test, and the reason the C++ core is forked.
  #
  # Turin's GTT splits its network into Feriale (working-day) and Festivo (holiday) lines and tags
  # opening_hours on both — 220 of the 390 routes around the city carry it. Bus 34 "Beinasco, Strada
  # Torino - Feriale" runs "Mo-Fr 04:30-07:11,18:21-01:01; Sa 04:30-07:10,18:34-01:01; PH off", so on
  # its own corridor (Cimitero Parco -> Via Ventimiglia) it is a clean three-way probe: offered on a
  # Tuesday at 06:00, gone at 10:30 the same day (right day, wrong hour), gone on a Sunday at 06:00
  # (right hour, wrong day). The instants are fixed, so this does not depend on when it is run.
  #
  # It runs --backend both because that is the whole point: the app routes with the native core by
  # default (PT_SAFE_MODE=false), so a filter that only existed in java would pass a java-only test
  # and do nothing in anyone's hands. Building this compiles the legacy core.
  #
  # The --datetime off case is the control. It runs first: if the data ever stops carrying these
  # tags, that assertion fails and says so, instead of the three filtered cases all quietly passing
  # for the wrong reason — a filter that finds nothing looks exactly like a filter that works.
  transitDatetimeTest = pkgs.writeShellApplication {
    name = "transit-datetime-test";
    runtimeInputs = mapTestInputs ++ [
      transitNative
      pkgs.gawk
    ];
    text = fetchPiemonteMap + ''
      # Bus 34's own corridor, in southern Turin.
      from=45.03286,7.60400
      to=45.03393,7.67221

      # One --backend both run answers for both engines, so ask once per moment and read the
      # report twice. Each run re-opens a 512 MB map and re-runs the search; asking per engine
      # would double that for no extra coverage.
      plan() { # $1 = datetime
        transit --obf "$obf" --from "$from" --to "$to" --datetime "$1" --backend both 2>/dev/null
      }

      # Does an itinerary in this report board bus 34, on the given backend's side of it?
      uses34() { # $1 = report, $2 = java|native
        printf '%s\n' "$1" | awk -v b="$2" '
            $0 ~ "^=== " b ": " {f = 1; next}
            /^=== (java|native): / {f = 0}
            f && /^ [0-9]+\. 34 / {found = 1}
            END {exit !found}'
      }

      echo "control: with --datetime off, bus 34 must be offered at all ..."
      unfiltered=$(plan off)
      for backend in java native; do
        uses34 "$unfiltered" "$backend" \
          || fail "$backend: bus 34 is not offered even unfiltered — the map's routes changed, not the filter"
      done

      # Tuesday 06:00 is inside "Mo-Fr 04:30-07:11"; 10:30 is not; Sunday is not in the tag at all.
      running=$(plan 2026-07-21T06:00)
      wrongHour=$(plan 2026-07-21T10:30)
      wrongDay=$(plan 2026-07-19T06:00)

      for backend in java native; do
        echo "$backend: Tue 06:00 (running) ..."
        uses34 "$running" "$backend" \
          || fail "$backend: bus 34 was dropped at Tue 06:00, but it runs Mo-Fr 04:30-07:11"
        echo "$backend: Tue 10:30 (right day, wrong hour) ..."
        ! uses34 "$wrongHour" "$backend" \
          || fail "$backend: bus 34 was offered at Tue 10:30, outside 04:30-07:11 and 18:21-01:01"
        echo "$backend: Sun 06:00 (right hour, wrong day) ..."
        ! uses34 "$wrongDay" "$backend" \
          || fail "$backend: bus 34 was offered on a Sunday, and it is a Feriale line"
      done

      echo "$running" | grep -q "backends AGREE" \
        || fail "java and native disagree on the best route with the filter on"

      echo "TEST PASSED: both backends run bus 34 on a Tuesday at 06:00, and drop it at 10:30 and on Sunday"
    '';
  };

  # Road-routing acceptance test: plan a car route across Turin on the live Piemonte map and assert
  # a sane distance comes back. Pure-Java, like transitTest — the differential check is exercised by
  # transit-diff-test. Loose bounds on purpose: "a plausible drive is still found", not a fingerprint.
  routeTest = pkgs.writeShellApplication {
    name = "route-test";
    runtimeInputs = mapTestInputs ++ [
      route
      pkgs.gawk
    ];
    text = fetchPiemonteMap + ''
      echo "planning a car route across Turin: Porta Nuova -> Caselle airport ..."
      report=$(route --obf "$obf" --mode car \
        --from 45.0625,7.6785 --to 45.2008,7.6497 --backend java 2>/dev/null)
      echo "$report"

      km=$(echo "$report" | awk '/^=== java ===/{f=1} f&&/ km,/{print $1; exit}')
      [ -n "$km" ] || fail "no car route was found"
      awk -v k="$km" 'BEGIN{exit !(k>=10 && k<=35)}' \
        || fail "car route is $km km, not the expected ~15-20 km across Turin"

      echo "TEST PASSED: the car route Porta Nuova -> Caselle airport is $km km"
    '';
  };
in
{
  inherit (arm64)
    apk
    prepared
    coreOpengl
    coreLegacy
    mpchart
    icu4j
    ;

  apk-x86 = x86.apk;

  # The seams, for flakes layering a plugin of their own (see flake.nix's lib output).
  mkApk = arm64.mkApk;
  mkApkX86 = x86.mkApk;

  # Exposed so the expensive x86 artifacts can be given GC roots too — otherwise a store
  # collection throws away 45 minutes of core compilation.
  prepared-x86 = x86.prepared;
  coreOpengl-x86 = x86.coreOpengl;
  coreLegacy-x86 = x86.coreLegacy;
  mpchart-x86 = x86.mpchart;
  icu4j-x86 = x86.icu4j;

  inherit
    mkJavaCli
    looproute
    route
    routeNative
    transit
    transitNative
    coreLegacyLinux
    src
    worldBasemapMini
    starsDb
    externals
    androidSdk
    emulatorSdk
    shell
    updateHashes
    looprouteTest
    routeTest
    transitTest
    transitDiffTest
    transitDatetimeTest
    versions
    ;
}
