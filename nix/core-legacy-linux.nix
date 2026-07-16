# The legacy native core, built for x86_64-linux/glibc instead of Android: libosmand.so.
#
# core-legacy.nix builds the same core with ndk-build, for Android ABIs — those .so link Bionic
# and cannot be loaded by a desktop JVM. But core-legacy also ships a CMake build with desktop
# targets (targets/.cmake/targets/amd64-linux-clang.cmake), which is what OsmAndMapCreator uses
# on the desktop. This derivation drives that build and drops out the one shared library the
# transit CLI's native backend loads via NativeLibrary.loadOldLib -> System.load.
#
# The entry point is core-legacy/targets/.cmake/CMakeLists.txt (project osmand_core_legacy). Its
# target file (targets/amd64-linux-clang.cmake, OsmAnd's old "bake" convention) is loaded as a `-C`
# initial cache, but the OS/arch selectors it sets have to be re-passed as -D cache vars to stick
# (see the buildPhase note). The non-Android branch of that CMakeLists links GDAL/PROJ/SQLite in and
# builds the `osmand` shared library with the full router — which is what we need
# (nativeTransportRouting lives in java_wrap.cpp -> transportRoutePlanner.cpp).
#
# All external C/C++ sources come from the five legacy-external FODs (skia carries zlib, libpng,
# expat, freetype, harfbuzz and libjpeg-turbo in its third_party; gdal/proj/protobuf/sqlite are
# their own), vendored into core-legacy/externals exactly as core-legacy.nix does for ndk-build.
{
  lib,
  clangStdenv,
  cmake,
  pkg-config,
  gnumake,
  python3,
  which,
  autoPatchelfHook,
  jdk21,
  freetype,
  fontconfig,
  versions,
  src,
  legacyExternals,
}:

clangStdenv.mkDerivation {
  pname = "osmand-core-legacy-linux";
  version = versions.versionName;

  inherit src;

  nativeBuildInputs = [
    cmake
    pkg-config
    gnumake
    python3
    which
    autoPatchelfHook
  ];

  # libosmand.so bundles its heavy externals (skia, gdal, proj, ...) statically, but the desktop
  # skia links system freetype + fontconfig dynamically (projects/skia/CMakeLists.txt), so those
  # are real run-time deps alongside the C++ runtime. autoPatchelfHook writes the rpath from these
  # buildInputs, so the JVM's System.load resolves everything without LD_LIBRARY_PATH.
  buildInputs = [
    clangStdenv.cc.cc.lib
    freetype
    fontconfig
  ];

  # We invoke cmake by hand (custom source dir + `-C` target cache), so skip the setup hook's
  # own configure that would run in the wrong directory with the wrong arguments.
  dontUseCmakeConfigure = true;

  # The OsmAndCore/linux branch adds $JAVA_HOME/include{,/linux} for jni.h itself; give it a real one.
  JAVA_HOME = "${jdk21}";

  preBuild = ''
    ${lib.concatMapStringsSep "\n" (drv: ''
      echo "vendoring external: ${drv.targetPath}"
      cp -a --reflink=auto ${drv}/upstream.patched ${drv.targetPath}/upstream.patched
      chmod -R u+w ${drv.targetPath}
    '') legacyExternals}

    patchShebangs --build core-legacy/externals

    # The desktop core logs every level (INFO/DEBUG/WARN/ERROR) to *stdout* via printf
    # (targets/linux/OsmAndCore/src/Logging.cpp). For a CLI whose stdout carries the itinerary,
    # diagnostics belong on stderr — send them there so `2>/dev/null` yields a clean report, the
    # same as the pure-Java backend (which the CLI mutes via System.setOut). Pure Java can't
    # redirect the native fd, so it has to happen here.
    substituteInPlace core-legacy/targets/linux/OsmAndCore/src/Logging.cpp \
      --replace-fail 'printf("' 'fprintf(stderr, "' \
      --replace-fail 'vprintf(msg, args)' 'vfprintf(stderr, msg, args)'

    # java_wrap.cpp / java_renderRules.h include <jni.h>. On Android the NDK supplies it; for a
    # desktop build point clang at the JDK's headers. The resulting .so keeps the JNI entry points
    # as undefined symbols resolved by the JVM at load time (the clang target does not pass
    # -Wl,--no-undefined, unlike the gcc one), which is exactly how a JNI library is meant to link.
    export NIX_CFLAGS_COMPILE="''${NIX_CFLAGS_COMPILE:-} -I${jdk21}/include -I${jdk21}/include/linux"
  '';

  buildPhase = ''
    runHook preBuild

    cd core-legacy/targets/.cmake

    # The target file (targets/amd64-linux-clang.cmake) is loaded as a `-C` initial cache, but its
    # plain `set(CMAKE_TARGET_OS linux)` does NOT persist into the configure — so the OS/arch that
    # select the whole Linux source set (skia's fontconfig font manager + SkOpts SIMD, and
    # targets/linux/OsmAndCore/src/Logging.cpp) were empty, and the .so linked with those symbols
    # undefined. Pass them as real cache variables instead. clangStdenv already supplies the
    # compiler via CC/CXX, which is why only these OS/arch selectors are missing.
    #
    # CMAKE_POLICY_VERSION_MINIMUM: core-legacy still declares cmake_minimum_required(VERSION 2.8/3.1),
    # and CMake 4 dropped compatibility with < 3.5.
    cmake -G "Unix Makefiles" \
      -C targets/amd64-linux-clang.cmake \
      -DCMAKE_TARGET_OS=linux \
      -DCMAKE_TARGET_CPU_ARCH=amd64 \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DCMAKE_BUILD_TYPE=Release \
      .

    # `osmand` is the SHARED target (add_library(osmand SHARED ...)); building it pulls in the
    # externals it depends on (skia, gdal, proj, sqlite, protobuf, ...).
    make -j"''${NIX_BUILD_CORES:-1}" osmand

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    # CMake writes the .so under core-legacy/binaries/<os>/<arch>//Release/; the buildPhase left us
    # in the targets/.cmake subdir, so search the whole build tree rather than the current dir.
    lib=$(find "$NIX_BUILD_TOP" -name 'libosmand.so' -print -quit)
    if [ -z "$lib" ]; then
      echo "CMake build produced no libosmand.so" >&2
      exit 1
    fi
    install -Dm755 "$lib" "$out/lib/libosmand.so"

    runHook postInstall
  '';

  meta = {
    description = "OsmAnd legacy native core for x86_64-linux (libosmand.so), via CMake — the JNI backend for headless routing";
    license = lib.licenses.gpl3Only;
    platforms = [ "x86_64-linux" ];
  };
}
