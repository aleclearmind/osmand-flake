# OsmAnd's patched ICU4J. `build.sh` step 3.
#
# prebuild.sh points OsmAnd-java at libs/icu4j.jar instead of the prebuilt jar F-Droid
# deletes; this is what produces it, trimmed of the data files OsmAnd does not use
# (which is most of them — it halves the jar).
{
  lib,
  stdenv,
  jdk21,
  ant,
  zip,
  versions,
  prepared,
}:

stdenv.mkDerivation {
  pname = "osmand-icu4j";
  version = versions.versionName;

  src = prepared;

  nativeBuildInputs = [
    jdk21
    ant
    zip
  ];

  JAVA_HOME = "${jdk21}";

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    ( cd icu-release-50-2-1-patched-mirror/icu4j
      ant jar
      for d in brkitr coll curr lang rbnf region translit zone; do
        zip -d icu4j.jar "com/ibm/icu/impl/data/icudt50b/$d/*" || true
      done )

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm644 icu-release-50-2-1-patched-mirror/icu4j/icu4j.jar "$out/icu4j.jar"
    runHook postInstall
  '';

  dontFixup = true;

  meta.description = "OsmAnd's patched ICU4J, trimmed as build.sh trims it";
}
