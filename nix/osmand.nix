# The APK.
#
# The four expensive artifacts — the OpenGL core, the legacy core, MPAndroidChart, ICU4J —
# arrive prebuilt from their own derivations, which is exactly what build.sh produces before
# handing over to gradle:
#
#   build.sh:  MPAndroidChart -> OsmAnd core -> ICU4J   (all copied into OsmAnd/libs)
#   gradle:    assembleAndroidFullOpenglArm64Release     (in subdir android/OsmAnd)
#
# `plugins` layers out-of-tree plugins in: each is { src, class }, where src has java/, app/ and
# optionally res/, and class is the fully-qualified OsmandPlugin to register. Nothing in this repo
# passes any — the ring route is in-tree in the android fork and registers itself — but a flake
# layering a private plugin on top does, which is why this is a list and not a hardcoded name. It
# is also the only input a plugin edit invalidates, so it cannot reach the cores.
{
  lib,
  stdenv,
  gradle,
  jdk21,
  androidSdk,
  sdkRoot,
  ndkRoot,
  versions,
  appName,
  applicationId,
  prepared,
  plugins ? [ ],
  coreOpengl,
  coreLegacy,
  mpchart,
  icu4j,
  regionsOcbf,
  worldBasemapMini,
  starsDb,
  androidEnv,
  gradleProps,
}:

stdenv.mkDerivation (
  finalAttrs:
  {
    pname = "osmand";
    version = versions.versionName;

    src = prepared;

    nativeBuildInputs = [
      gradle
      jdk21
      androidSdk
    ];

    mitmCache = gradle.fetchDeps {
      pkg = finalAttrs.finalPackage;
      data = ./deps.json;
    };

    dontUseGradleBuild = true;
    dontUseGradleCheck = true;

    gradleFlags = [
      "--init-script"
      "${./tolerant-deps.gradle}"
      "--init-script"
      "${./prebuilt-core.gradle}"
    ];

    postPatch = ''
      # The Java namespace remains net.osmand.plus, but Android installation identity
      # is the Gradle applicationId. The provider authority must follow it as well or
      # Android rejects side-by-side installation because provider authorities are
      # globally unique on a device.
      substituteInPlace android/OsmAnd/build.gradle \
        --replace-fail 'applicationId "net.osmand.plus"' 'applicationId "${applicationId}"'
      ${lib.optionalString (appName != versions.appName) ''
        substituteInPlace android/OsmAnd/build.gradle \
          --replace-fail '"${versions.appName}"' '"${appName}"'
      ''}
      substituteInPlace android/OsmAnd/AndroidManifest.xml \
        --replace-fail 'android:authorities="net.osmand.plus.fileprovider"' \
          'android:authorities="${applicationId}.fileprovider"'
    ''
    + lib.concatMapStrings (p: ''
      cp -r ${p.src}/java/. android/OsmAnd-java/src/main/java/
      cp -r ${p.src}/app/.  android/OsmAnd/src/
      if [ -d "${p.src}/res" ]; then cp -r ${p.src}/res/. android/OsmAnd/res/; fi
    '') plugins
    + lib.optionalString (plugins != [ ]) ''
      # Plugins are a hardcoded list. Fully-qualify the names so no import has to be threaded
      # into the file, and anchor on the in-tree ring route so they land in the drawer right
      # after it. --replace-fail, so an anchor that moves upstream is a build failure rather
      # than a silently missing plugin.
      substituteInPlace android/OsmAnd/src/net/osmand/plus/plugins/PluginsHelper.java \
        --replace-fail 'allPlugins.add(new LoopRoutePlugin(app));' \
          'allPlugins.add(new LoopRoutePlugin(app));${
            lib.concatMapStrings (p: "\n\t\tallPlugins.add(new ${p.class}(app));") plugins
          }'
    '';

    preBuild = ''
      # Everything build.sh would have copied into place, prebuilt.
      install -Dm644 ${mpchart}/MPChartLib-release.aar        android/OsmAnd/libs/MPChartLib-release.aar
      install -Dm644 ${coreOpengl}/OsmAndCore_android-release.aar \
        android/OsmAnd/libs/OsmAndCore_android-release.aar
      install -Dm644 ${coreOpengl}/OsmAndCore_androidNativeRelease-release.aar \
        android/OsmAnd/libs/OsmAndCore_androidNativeRelease-release.aar
      install -Dm644 ${icu4j}/icu4j.jar                       android/OsmAnd/libs/icu4j.jar
      install -Dm644 ${icu4j}/icu4j.jar                       android/OsmAnd-java/libs/icu4j.jar

      # The legacy core's .so files, where :OsmAnd:buildOsmAndCore would have left them.
      # (That task and copyOsmAndCoreWithJNI are disabled in prebuilt-core.gradle;
      # cleanupDuplicatesInCore still runs and still moves libc++_shared.so out of libs/.)
      cp -a --reflink=auto ${coreLegacy}/. android/OsmAnd/libs/
      chmod -R u+w android/OsmAnd/libs

      # Three gradle Download tasks fetch from builder.osmand.net at *build* time, so they
      # can never be part of the dependency lockfile. Vendor their outputs and disable the
      # tasks themselves (see tolerant-deps.gradle). The two asset files land in
      # build/generated/osmand/assets, which build-common.gradle already declares as an
      # assets srcDir, so they get packaged exactly as before.
      install -Dm644 ${regionsOcbf} \
        android/OsmAnd-java/src/main/resources/net/osmand/map/regions.ocbf
      install -Dm644 ${worldBasemapMini} \
        android/OsmAnd/build/generated/osmand/assets/World_basemap_mini.obf
      mkdir -p android/OsmAnd/build/generated/osmand/assets/astro
      gzip -dc ${starsDb} > android/OsmAnd/build/generated/osmand/assets/astro/stars.db

      ${gradleProps}

      # Gradle otherwise gives its build daemon only the small default heap. That is
      # marginal for Zipflinger when the x86 flavour packages both x86 and x86_64, and
      # has failed nondeterministically in CI even with plenty of system RAM available.
      # Keep this APK-only: putting it in gradleProps would also invalidate the native
      # core and MPAndroidChart derivations.
      echo "org.gradle.jvmargs=-Xmx2g -Dfile.encoding=UTF-8" \
        >> "$GRADLE_USER_HOME/gradle.properties"
    '';

    buildPhase = ''
      runHook preBuild

      # fdroidserver `gradle:` — run in subdir android/OsmAnd
      # Preserve the nested AGP/Zipflinger exception in CI if packaging ever fails again.
      ( cd android/OsmAnd && gradle --stacktrace ${versions.gradleTask} )

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p "$out"
      find android/OsmAnd/build/outputs/apk -name '*.apk' -print -exec cp {} "$out/" \;

      if [ -z "$(ls -A "$out")" ]; then
        echo "no APK produced" >&2
        exit 1
      fi

      runHook postInstall
    '';

    dontStrip = true;
    dontFixup = true;

    meta = {
      description = "${appName} — OsmAnd ${versions.versionName}, built the F-Droid way";
      homepage = "https://osmand.net";
      license = lib.licenses.gpl3Only;
      platforms = [ "x86_64-linux" ];
    };
  }
  // androidEnv
)
