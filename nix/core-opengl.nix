# The OpenGL core: Qt5, Skia, GDAL, Boost, ICU4C, then libOsmAndCoreWithJNI.so, wrapped
# in the two AARs the app consumes. This is the 15 minutes of the build, and it depends
# on nothing but the OsmAnd sources and the vendored externals — in particular not on
# the plugin, which is why it lives in its own derivation.
#
# `build.sh` step 2, on its own.
{
  lib,
  stdenv,
  gradle,
  jdk21,
  androidSdk,
  sdkRoot,
  ndkRoot,
  cmake,
  gnumake,
  clang,
  swig,
  python3,
  perl,
  unzip,
  which,
  file,
  versions,
  prepared,
  coreExternals,
  androidEnv,
  gradleProps,
}:

stdenv.mkDerivation (
  finalAttrs: {
    pname = "osmand-core-opengl";
    version = versions.versionName;

    src = prepared;

    nativeBuildInputs = [
      gradle
      jdk21
      androidSdk
      cmake
      gnumake
      # Boost bootstraps its b2 engine with the *host* clang (F-Droid gets it from
      # `apt-get install clang`); the NDK's clang is only for the target.
      clang
      swig
      python3
      perl
      unzip
      which
      file
    ];

    mitmCache = gradle.fetchDeps {
      pkg = finalAttrs.finalPackage;
      data = ./deps.json;
    };

    dontUseGradleBuild = true;
    dontUseGradleCheck = true;
    # cmake is a *tool* here — OsmAnd's own scripts invoke it. Without this, cmake's
    # setup hook takes over configurePhase and tries to configure the repo root.
    dontUseCmakeConfigure = true;

    gradleFlags = [
      "--init-script"
      "${./tolerant-deps.gradle}"
    ];

    preBuild = ''
      # F-Droid installs python-is-python3; Qt's configure calls plain `python`.
      mkdir -p "$TMPDIR/shims"
      ln -sf ${python3}/bin/python3 "$TMPDIR/shims/python"
      export PATH="$TMPDIR/shims:$PATH"

      # Drop the vendored externals in place of the downloads configure.sh would do.
      # Reflink-copy: source and build dir are the same btrfs filesystem.
      ${lib.concatMapStringsSep "\n" (drv: ''
        echo "vendoring external: ${drv.targetPath}"
        cp -a --reflink=auto ${drv}/upstream.patched ${drv.targetPath}/upstream.patched
        if [ -e ${drv}/.stamp ]; then cp -a ${drv}/.stamp ${drv.targetPath}/.stamp; fi
        chmod -R u+w ${drv.targetPath}
      '') coreExternals}

      # The externals arrive after patchShebangs ran, so their build scripts still carry
      # #!/usr/bin/perl and friends, which do not exist in the sandbox (qtbase's
      # syncqt.pl is the first casualty).
      patchShebangs --build core/externals

      # proj asks for a pthread library on every non-Windows target. Android has no such
      # library — Bionic puts pthread inside libc — so on F-Droid's Debian builder this
      # find_library simply comes back empty and is skipped. Under Nix it instead
      # resolves to the *host* glibc's libpthread.so, and linking libOsmAndCoreWithJNI.so
      # for arm64 then dies with "libpthread.so is incompatible with aarch64linux".
      substituteInPlace core/externals/proj/CMakeLists.txt \
        --replace-fail 'find_library(PTHREAD_LIBRARY pthread)' \
                       'if (NOT CMAKE_TARGET_OS STREQUAL "android")
		find_library(PTHREAD_LIBRARY pthread)
	endif()'

      # Qt5's configure shells out to /bin/pwd, which exists on Debian but not in the
      # sandbox (only /bin/sh is bind-mounted). Without this it cannot even locate its
      # own .qmake.conf.
      sed -i 's#/bin/pwd#pwd#g' core/externals/qtbase-android/upstream.patched/configure

      # qtbase is a git checkout, so its include/QtCore/* forwarding headers are not
      # shipped — configure generates them with syncqt.pl, but only when it sees a .git
      # ("make a build from GIT"). The FOD strips .git to keep its hash stable, so
      # restore the marker: configure only tests for existence, and syncqt.pl itself
      # never shells out to git. Without this, qmake's bootstrap fails on a missing
      # QtCore/qconfig-bootstrapped.h.
      touch core/externals/qtbase-android/upstream.patched/.git

      ${gradleProps}
    '';

    buildPhase = ''
      runHook preBuild

      export OSMAND_BUILD_CPU_CORES_NUM=''${NIX_BUILD_CORES:-1}

      # nixpkgs' cmake hook puts every native input on CMAKE_PREFIX_PATH, and the clang
      # wrapper propagates the host glibc. This is a cross build and every native
      # dependency is vendored, so cmake has nothing legitimate to find on the host.
      unset CMAKE_PREFIX_PATH CMAKE_LIBRARY_PATH CMAKE_INCLUDE_PATH CMAKE_FRAMEWORK_PATH

      # build.sh's core step, verbatim.
      ( cd core/wrappers/android \
        && gradle assembleRelease -x :OsmAndCore_androidNativeDebug:assembleRelease )

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p "$out"
      cp core/wrappers/android/build/outputs/aar/OsmAndCore_android-release.aar "$out/"
      cp core/wrappers/android/NativeCoreRelease/build/outputs/aar/OsmAndCore_androidNativeRelease-release.aar "$out/"

      runHook postInstall
    '';

    dontStrip = true;
    dontFixup = true;

    meta.description = "OsmAnd OpenGL core (${versions.abi}) as the two AARs the app links";
  }
  // androidEnv
)
