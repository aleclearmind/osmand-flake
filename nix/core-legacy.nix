# The legacy core: libosmand.so, built with ndk-build.
#
# The app's :OsmAnd:buildOsmAndCore task normally runs old-ndk-build.sh inline, in the
# middle of the Gradle build — which means a one-line Java change recompiles it. Pulled
# out here it is built once and cached, and the APK derivation drops the .so files
# straight into android/OsmAnd/libs/<abi>/ (already a jniLibs srcDir) with that Gradle
# task disabled.
#
# Note upstream hardcodes `ndk-build -j2`, so this does not get faster with more cores.
{
  lib,
  stdenv,
  androidSdk,
  sdkRoot,
  ndkRoot,
  gnumake,
  python3,
  which,
  versions,
  prepared,
  legacyExternals,
  androidEnv,
}:

let
  # jni/Application.mk picks APP_ABI off these; without one it builds all four.
  abiSelector = {
    armv7 = "ARMV7_ONLY";
    arm64 = "ARM64_ONLY";
    x86 = "X86_ONLY"; # x86 + x86_64, matching the app's abiFilters
  }.${versions.abi};
in
stdenv.mkDerivation (
  {
    pname = "osmand-core-legacy";
    version = versions.versionName;

    src = prepared;

    nativeBuildInputs = [
      androidSdk
      gnumake
      python3
      which
    ];

    preBuild = ''
      ${lib.concatMapStringsSep "\n" (drv: ''
        echo "vendoring external: ${drv.targetPath}"
        cp -a --reflink=auto ${drv}/upstream.patched ${drv.targetPath}/upstream.patched
        if [ -e ${drv}/.stamp ]; then cp -a ${drv}/.stamp ${drv.targetPath}/.stamp; fi
        chmod -R u+w ${drv.targetPath}
      '') legacyExternals}

      patchShebangs --build core-legacy/externals
    '';

    buildPhase = ''
      runHook preBuild

      # What :OsmAnd:buildOsmAndCore does, with the same ABI-selecting env var its Exec
      # task sets from the requested gradle flavour.
      export ${abiSelector}=1
      ( cd android/OsmAnd && bash ./old-ndk-build.sh )

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p "$out"
      cp -r android/OsmAnd/libs/. "$out/"

      if [ -z "$(find "$out" -name '*.so' -print -quit)" ]; then
        echo "ndk-build produced no shared libraries" >&2
        exit 1
      fi

      runHook postInstall
    '';

    dontConfigure = true;
    dontStrip = true;
    dontFixup = true;

    meta.description = "OsmAnd legacy native core (${versions.abi}), via ndk-build";
  }
  // androidEnv
)
