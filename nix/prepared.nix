# The OsmAnd tree after F-Droid's `rm:` and `prebuild.sh`, and nothing else.
#
# Everything downstream starts from this, so the de-Googling and the version/name
# rewriting happen exactly once. It deliberately does NOT contain the ring-route
# plugin: the plugin is an input to the APK alone, which is what lets a plugin edit
# rebuild the APK without rebuilding Qt.
{
  lib,
  stdenv,
  runtimeShell,
  python3,
  perl,
  gnupatch,
  which,
  versions,
  src,
}:

stdenv.mkDerivation {
  pname = "osmand-prepared";
  version = versions.versionName;

  inherit src;

  nativeBuildInputs = [
    python3
    perl
    gnupatch
    which
  ];

  postPatch = ''
    # prebuild.sh runs `sdkmanager "platforms;android-31"`. androidenv already provides
    # that platform and the sandbox has no network, so stub it rather than editing the
    # script (prebuild.sh stays byte-identical to F-Droid's).
    mkdir -p "$TMPDIR/shims"
    printf '#!${runtimeShell}\nexit 0\n' > "$TMPDIR/shims/sdkmanager"
    chmod +x "$TMPDIR/shims/sdkmanager"
    export PATH="$TMPDIR/shims:$PATH"

    patchShebangs --build .

    # fdroidserver `rm:`
    rm -f  android/OsmAnd-java/libs/*.jar
    rm -f  android/OsmAnd/libs/*.jar
    rm -rf android/OsmAnd-telegram
    rm -rf resources/icons/tools/SVGtoXML/vd-tool
    # fdroidserver `scandelete:`
    rm -rf resources/test-resources

    # fdroidserver `prebuild:` — run from the subdir, as F-Droid does
    ( cd android/OsmAnd && bash ../../prebuild.sh \
        ${versions.versionName} ${versions.versionCode} ${versions.abi} )

    # ...and then take the extra tilde. prebuild.sh hardcodes "OsmAnd~".
    substituteInPlace android/OsmAnd/build.gradle \
      --replace-fail '"OsmAnd~"' '"${versions.appName}"'
  '';

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -a . "$out"
    runHook postInstall
  '';

  dontFixup = true;

  meta.description = "OsmAnd ${versions.versionName} sources, after F-Droid's rm + prebuild.sh";
}
