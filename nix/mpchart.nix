# MPAndroidChart, pinned by prebuild.sh to AGP 8.5.2. `build.sh` step 1.
{
  lib,
  stdenv,
  gradle,
  jdk21,
  androidSdk,
  sdkRoot,
  versions,
  prepared,
  androidEnv,
  gradleProps,
}:

stdenv.mkDerivation (
  finalAttrs: {
    pname = "osmand-mpandroidchart";
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
    ];

    preBuild = gradleProps;

    buildPhase = ''
      runHook preBuild
      ( cd MPAndroidChart && gradle assembleRelease )
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -Dm644 MPAndroidChart/MPChartLib/build/outputs/aar/MPChartLib-release.aar \
        "$out/MPChartLib-release.aar"
      runHook postInstall
    '';

    dontFixup = true;

    meta.description = "MPAndroidChart AAR, as OsmAnd's build.sh builds it";
  }
  // androidEnv
)
