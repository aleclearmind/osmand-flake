# OsmAnd's native cores vendor their C/C++ dependencies themselves: each
# externals/<name>/configure.sh downloads an upstream tarball or git ref *during
# the build* and applies OsmAnd's patches to it. F-Droid lets that happen over the
# network mid-build; we can't, so each one becomes an FOD.
#
# Two trees need this, and they work differently:
#
#  core/externals/<name>          — the OpenGL core (build.sh -> cmake). Shares
#      build/utils/functions.sh, which bails out early if upstream.patched exists
#      — but only *after* a stamp check that wipes upstream.* when `stamp` and
#      `.stamp` disagree. So these must ship the patched tree AND a matching
#      .stamp, or they delete themselves and reach for the network.
#
#  core-legacy/externals/<name>   — the legacy core (old-ndk-build.sh -> ndk-build),
#      which the app's :OsmAnd:buildOsmAndCore task still builds. Self-contained
#      scripts, no stamps: they just exit if upstream.patched is there.
{
  lib,
  stdenvNoCC,
  bash,
  git,
  curl,
  cacert,
  gnutar,
  bzip2,
  gzip,
  xz,
  unzip,
  gnupatch,
  python3,
  src,
  hashes,
}:

let
  # Everything under core/externals except qtbase-desktop and qtbase-ios, which
  # prebuild.sh deletes outright.
  coreNames = [
    "boost"
    "expat"
    "freetype"
    "gdal"
    "geographiclib"
    "giflib"
    "glew"
    "glm"
    "harfbuzz"
    "icu4c"
    "jpeg"
    "libarchive"
    "libpng"
    "proj"
    "protobuf"
    "qtbase-android"
    "skia"
    "sqlite"
    "zlib"
  ];

  # core-legacy/externals/jpeg has no configure.sh — it is committed in-tree and
  # needs no download, unlike these five.
  legacyNames = [
    "gdal"
    "proj"
    "protobuf"
    "skia"
    "sqlite"
  ];

  mkExternal =
    { name, dir }:
    let
      attr = if dir == "core-legacy/externals" then "legacy-${name}" else name;
    in
    stdenvNoCC.mkDerivation {
      pname = "osmand-external-${attr}";
      version = "5.3.10";

      nativeBuildInputs = [
        bash
        git
        curl
        cacert
        gnutar
        bzip2
        gzip
        xz
        unzip
        gnupatch
        python3
      ];

      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
      outputHash = hashes.${attr} or lib.fakeHash;

      dontUnpack = true;

      SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
      GIT_SSL_CAINFO = "${cacert}/etc/ssl/certs/ca-bundle.crt";

      # Where this belongs inside the source tree, for the build to drop it back.
      passthru.targetPath = "${dir}/${name}";

      buildCommand = ''
        export HOME="$TMPDIR"
        export GIT_CONFIG_NOSYSTEM=1

        # The core externals reach for ../../../build/utils/functions.sh, so they
        # need the surrounding directory shape, not just their own directory.
        mkdir -p work/build work/${dir}
        cp -r --no-preserve=mode,ownership ${src}/build/utils work/build/utils
        cp -r --no-preserve=mode,ownership ${src}/${dir}/${name} work/${dir}/${name}
        chmod -R u+w work

        cd work/${dir}/${name}
        patchShebangs . ../../../build/utils

        # core-legacy's skia pulls skia's own third_party/externals (libjpeg-turbo,
        # harfbuzz, ...) by running tools/git-sync-deps, which starts with
        # #!/usr/bin/env python. /usr/bin/env does not exist in the sandbox, and the
        # script only appears *during* configure.sh — after patchShebangs has run —
        # so it can't be fixed up beforehand. configure.sh doesn't check the exit
        # code either, so this failed silently and left third_party/externals empty.
        # The script is python3-clean; call it explicitly.
        sed -i 's|^\./git-sync-deps|python3 ./git-sync-deps|' ./configure.sh

        bash ./configure.sh

        mkdir -p "$out"
        cp -r upstream.patched "$out/upstream.patched"
        # Make the stamp check a no-op for the real build (core externals only).
        if [ -f stamp ]; then
          cp stamp "$out/.stamp"
        fi

        # prepareUpstreamFromGit clones in-tree, and patchUpstream copies the
        # result wholesale — .git and all. Packfiles and FETCH_HEAD differ on every
        # fetch, which would make this FOD's hash unstable. The build only ever
        # compiles the worktree, so drop it.
        find "$out" -name .git -exec rm -rf {} + 2>/dev/null || true
      '';

      meta.description = "OsmAnd ${dir} external: ${name} (downloaded + patched)";
    };

  core = lib.genAttrs coreNames (name: mkExternal {
    inherit name;
    dir = "core/externals";
  });

  legacy = lib.listToAttrs (map (name: {
    name = "legacy-${name}";
    value = mkExternal {
      inherit name;
      dir = "core-legacy/externals";
    };
  }) legacyNames);
in
core // legacy
