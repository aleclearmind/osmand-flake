# Fixed-output derivation with the full OsmAnd source tree.
#
# F-Droid does `git clone --recursive` of the submodule mirror at the tag. We do
# the same but shallow, strip every .git, and let the FOD hash pin the result.
# Content is deterministic: the tag pins the superproject, and the superproject
# pins each submodule to an exact commit.
{
  lib,
  stdenvNoCC,
  git,
  cacert,
  versions,
  hash,
}:

stdenvNoCC.mkDerivation {
  pname = "osmand-src";
  version = versions.versionName;

  nativeBuildInputs = [
    git
    cacert
  ];

  outputHashMode = "recursive";
  outputHashAlgo = "sha256";
  outputHash = hash;

  dontUnpack = true;

  buildCommand = ''
    export HOME="$TMPDIR"
    export GIT_CONFIG_NOSYSTEM=1
    git clone --depth 1 --shallow-submodules --recurse-submodules -j4 \
      --branch ${versions.tag} ${versions.repo} "$out"

    # .git is a directory in the superproject and a file in each submodule.
    find "$out" -name .git -exec rm -rf {} + 2>/dev/null || true
  '';

  meta = {
    description = "OsmAnd ${versions.versionName} sources, as F-Droid checks them out";
    license = lib.licenses.gpl3Only;
  };
}
