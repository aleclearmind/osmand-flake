# One headless CLI over OsmAnd-java.
#
# OsmAnd's routers and the ring-route planner are plain Java living in OsmAnd-java, and read a local
# .obf directly — so they run on any JVM with no Android and no device. Each one wants the same
# derivation: build that one module, collect its runtime classpath, wrap a main class. Only the
# name, the class and the heap differ, so this is a function rather than a file per tool.
#
# It still needs prebuild.sh: that is what rewires OsmAnd-java off the self-hosted ivy repo and its
# prebuilt jars (gnu-trove, icu4j) and onto Maven + the ICU4J built from source.
#
# pluginSrc compiles an out-of-tree plugin's java into OsmAnd-java first. Nothing here needs it —
# the ring route and the routing CLI are in-tree in the android fork — but a flake layering its own
# plugin on top does, which is why this is exported as lib.mkJavaCli.
{
  lib,
  stdenv,
  runtimeShell,
  makeWrapper,
  gradle,
  jdk21,
  androidSdk,
  sdkRoot,
  ant,
  zip,
  unzip,
  python3,
  perl,
  gnupatch,
  which,
  versions,
  src,
  regionsOcbf,

  # What makes this tool this tool:
  name,
  mainClass,
  description,
  heap ? "2g",
  pluginSrc ? null,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "osmand-${name}";
  version = versions.versionName;

  inherit src;

  nativeBuildInputs = [
    gradle
    jdk21
    androidSdk
    ant
    zip
    unzip
    python3
    perl
    gnupatch
    which
    makeWrapper
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
    "${./collect-classpath.gradle}"
  ];

  ANDROID_HOME = sdkRoot;
  ANDROID_SDK_ROOT = sdkRoot;
  ANDROID_SDK = sdkRoot;
  ANDROID_SDK_BUILD_TOOLS_REVISION = versions.buildToolsVersion;
  JAVA_HOME = "${jdk21}";

  postPatch = ''
    mkdir -p "$TMPDIR/shims"
    printf '#!${runtimeShell}\nexit 0\n' > "$TMPDIR/shims/sdkmanager"
    chmod +x "$TMPDIR/shims/sdkmanager"
    export PATH="$TMPDIR/shims:$PATH"

    patchShebangs --build .

    rm -f  android/OsmAnd-java/libs/*.jar
    rm -f  android/OsmAnd/libs/*.jar
    rm -rf android/OsmAnd-telegram
    rm -rf resources/icons/tools/SVGtoXML/vd-tool
    rm -rf resources/test-resources

    ( cd android/OsmAnd && bash ../../prebuild.sh \
        ${versions.versionName} ${versions.versionCode} ${versions.abi} )
  ''
  + lib.optionalString (pluginSrc != null) ''
    cp -r ${pluginSrc}/java/. android/OsmAnd-java/src/main/java/
  '';

  preBuild = ''
    install -Dm644 ${regionsOcbf} \
      android/OsmAnd-java/src/main/resources/net/osmand/map/regions.ocbf

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

  buildPhase = ''
    runHook preBuild

    # prebuild.sh points OsmAnd-java at libs/icu4j.jar; build.sh is what produces it.
    # Only that slice of build.sh matters here — the rest is the native core.
    ( cd icu-release-50-2-1-patched-mirror/icu4j
      ant jar
      for d in brkitr coll curr lang rbnf region translit zone; do
        zip -d icu4j.jar "com/ibm/icu/impl/data/icudt50b/$d/*" || true
      done
      cp icu4j.jar ../../android/OsmAnd-java/libs/ )

    ( cd android && gradle :OsmAnd-java:nixCollectRuntime )

    runHook postBuild
  '';

  # No build-time check: these tools need a real map to work on, and a nix build sandbox has no
  # network to fetch one (only a fixed-output derivation could, and pinning a hash to OsmAnd's
  # rolling map only ever rots). The acceptance tests run in your shell instead — `nix run .#test`,
  # `.#route-test`, `.#transit-test` — and fetch the current map. See nix/default.nix.

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/lib"
    cp android/nix-runtime-libs/*.jar "$out/lib/"

    makeWrapper ${jdk21}/bin/java "$out/bin/${name}" \
      --add-flags "-Xmx${heap} -cp '$out/lib/*' ${mainClass}"

    runHook postInstall
  '';

  meta = {
    inherit description;
    mainProgram = name;
    license = lib.licenses.gpl3Only;
    platforms = [ "x86_64-linux" ];
  };
})
