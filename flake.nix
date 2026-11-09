{
  description = "OsmAnd~~ — OsmAnd built the F-Droid way, with a ring-route trekking plugin";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # The two OsmAnd submodules we maintain, as forks. Everything else in the tree still
    # comes from the f-droid submodule mirror at the tag (nix/source.nix); nix/default.nix
    # splices these two over it. Both branches are cut from the exact commits the mirror
    # pins, so an untouched fork builds the same bytes F-Droid would.
    #
    # To work on them, point the inputs at your local clones — no commit, no push, no
    # flake.lock churn:
    #
    #   nix build .#route \
    #     --override-input osmand-android     git+file:///home/you/ale/osmand \
    #     --override-input osmand-core-legacy git+file:///home/you/ale/osmand-core-legacy
    #
    # ./local.sh wraps exactly that: `./local.sh build .#route`, `./local.sh run .#transit -- ...`
    osmand-android = {
      url = "github:aleclearmind/OsmAnd/osmand-flake-5.4.11";
      flake = false;
    };
    osmand-core-legacy = {
      url = "github:aleclearmind/OsmAnd-core-legacy/osmand-flake-5.4.11";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      osmand-android,
      osmand-core-legacy,
    }:
    let
      system = "x86_64-linux";

      pkgs = import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true; # Android SDK/NDK are unfree
          android_sdk.accept_license = true;
        };
      };

      osmand = pkgs.callPackage ./nix {
        androidSrc = osmand-android;
        coreLegacySrc = osmand-core-legacy;
      };

      ciApk =
        abi: package:
        pkgs.runCommand "osmand-${osmand.versions.versionName}-${abi}.apk"
          {
            __structuredAttrs = true;
            passthru = { inherit (package) mitmCache; };
            ci = [
              { action = "sign-apk"; }
              { action = "release"; }
              { action = "publish-fdroid"; }
            ];
          }
          ''
            mapfile -t apks < <(find ${package} -maxdepth 1 -type f -name '*.apk' -print)
            if [ "''${#apks[@]}" -ne 1 ]; then
              echo "expected exactly one APK in ${package}, found ''${#apks[@]}" >&2
              printf '  %s\n' "''${apks[@]}" >&2
              exit 1
            fi
            cp "''${apks[0]}" "$out"
          '';

      ciRun =
        package:
        package.overrideAttrs (_: {
          __structuredAttrs = true;
          ci = [ { action = "run"; } ];
        });

      apk = ciApk "arm64-v8a" osmand.apk;
      apk-x86 = ciApk "x86_64" osmand.apk-x86;
      routeTest = ciRun osmand.routeTest;
      transitTest = ciRun osmand.transitTest;
    in
    {
      packages.${system} = {
        default = apk;
        inherit
          apk
          apk-x86
          routeTest
          transitTest
          ;
        "route-test" = routeTest;
        "transit-test" = transitTest;
        inherit (osmand)
          prepared-x86
          coreOpengl-x86
          coreLegacy-x86
          mpchart-x86
          icu4j-x86
          looproute
          route
          routeNative
          transit
          transitNative
          coreLegacyLinux
          src
          prepared
          coreOpengl
          coreLegacy
          mpchart
          icu4j
          androidSdk
          emulatorSdk
          worldBasemapMini
          starsDb
          ;
        # hyphenated aliases, matching how they're referred to on the command line
        "core-legacy-linux" = osmand.coreLegacyLinux;
        "route-native" = osmand.routeNative;
        "transit-native" = osmand.transitNative;
      }
      # Expose each vendored external as an ordinary package: nix build .#skia.
      # (callPackage tacks an `override` function onto the set; keep only derivations)
      // pkgs.lib.filterAttrs (_: pkgs.lib.isDerivation) osmand.externals;

      # The seam for flakes that add a plugin of their own — OsmAnd~~ plus something we would not
      # ship here. Adding a plugin means re-running the app's gradle step over different sources,
      # so what they need is these functions, not a built APK; everything expensive underneath
      # (the two cores, MPChart, ICU4J) is unchanged by a plugin and comes straight from this
      # flake's store paths, so they never rebuild Qt.
      #
      #   osmand-flake.lib.x86_64-linux.mkApk {
      #     appName = "OsmAnd~~~";
      #     applicationId = "io.github.example.osmand.myplugin";
      #     plugins = [ { src = ./plugin; class = "net.osmand.plus.plugins.mine.MyPlugin"; } ];
      #   }
      #
      # Consume this flake's nixpkgs (do not declare your own, or none of the above is cached).
      lib.${system} = {
        inherit (osmand) mkApk mkApkX86 mkJavaCli;
      };

      devShells.${system}.default = osmand.shell;

      apps.${system} = {
        # Preserve existing lock entries while recording the app and its shared
        # modules. The native wrappers use a separate, stable core-deps.json.
        update-deps = {
          type = "app";
          program = "${
            pkgs.writeShellApplication {
              name = "update-osmand-deps";
              runtimeInputs = [
                pkgs.coreutils
                pkgs.jq
              ];
              text = ''
                backup=$(mktemp)
                merged=$(mktemp)
                cp nix/deps.json "$backup"
                complete=0
                cleanup() {
                  if [ "$complete" -eq 0 ]; then cp "$backup" nix/deps.json; fi
                  rm -f "$backup" "$merged"
                }
                trap cleanup EXIT
                ${apk.mitmCache.updateScript}
                jq --sort-keys --indent 1 --slurp '.[0] * .[1]' "$backup" nix/deps.json > "$merged"
                mv "$merged" nix/deps.json
                complete=1
              '';
            }
          }/bin/update-osmand-deps";
        };

        # Regenerate nix/externals-hashes.json after bumping OsmAnd
        update-hashes = {
          type = "app";
          program = "${osmand.updateHashes}/bin/update-external-hashes";
        };

        # Plan the Rassa round on a freshly fetched map and check it is still found: `nix run .#test`
        test = {
          type = "app";
          program = "${osmand.looprouteTest}/bin/looproute-test";
        };

        # The routing CLI — road/vehicle, transit, or GPX approximation, pure-Java backend:
        #   nix run .#route -- --obf MAP.obf --mode car --from LAT,LON --to LAT,LON --directions
        route = {
          type = "app";
          program = "${osmand.route}/bin/route";
        };

        # Same CLI with $OSMAND_NATIVE_LIB wired to the amd64-linux legacy core, so
        # `--backend native`/`both` work with no flags. Building this compiles the native core.
        #   nix run .#route-native -- --obf MAP.obf --mode car --from LAT,LON --to LAT,LON --backend both
        route-native = {
          type = "app";
          program = "${osmand.routeNative}/bin/route";
        };

        # Road-routing acceptance test (fetches the Piemonte map): `nix run .#route-test`
        route-test = {
          type = "app";
          program = "${routeTest}/bin/route-test";
        };

        # `transit` is the routing CLI pinned to --mode public_transport (so the command still exists):
        #   nix run .#transit -- --obf MAP.obf --from LAT,LON --to LAT,LON
        transit = {
          type = "app";
          program = "${osmand.transit}/bin/transit";
        };

        # transit with the native core wired in, for `--backend native`/`both`. Compiles the core.
        #   nix run .#transit-native -- --obf MAP.obf --from LAT,LON --to LAT,LON --backend both
        transit-native = {
          type = "app";
          program = "${osmand.transitNative}/bin/transit";
        };

        # Fetch the current Piemonte map and plan a Turin transit trip (pure-Java): `nix run .#transit-test`
        transit-test = {
          type = "app";
          program = "${transitTest}/bin/transit-test";
        };

        # The differential check: plan the same trip with both engines and assert they agree.
        # Compiles the native core. `nix run .#transit-diff-test`
        transit-diff-test = {
          type = "app";
          program = "${osmand.transitDiffTest}/bin/transit-diff-test";
        };

        # The opening_hours filter: a Turin Feriale bus is offered on a Tuesday morning and gone
        # both at midday and on a Sunday — on *both* engines. Compiles the native core.
        #   nix run .#transit-datetime-test
        transit-datetime-test = {
          type = "app";
          program = "${osmand.transitDatetimeTest}/bin/transit-datetime-test";
        };
      };
    };
}
