# Everything that identifies *which* OsmAnd we build.
# Mirrors the last Builds: entry of
# https://gitlab.com/fdroid/fdroiddata/-/blob/master/metadata/net.osmand.plus.yml
{
  # F-Droid builds from a mirror that pins all of OsmAnd's repos as submodules.
  repo = "https://gitlab.com/f-droid-mirrors/OsmAnd-submodules.git";
  tag = "v5.3.10";

  versionName = "5.3.10";

  # versionCode*100 + 1/2/3 for split ABI (armv7/x86/arm64), per MaintainerNotes.
  # Overridden per-ABI in nix/default.nix; the x86 flavour carries x86 *and* x86_64
  # (build-common.gradle abiFilters), which is what an x86_64 emulator needs.
  versionCode = "531003";
  abi = "arm64";

  # gradle: [android, full, opengl, arm64] -> flavours androidFull + opengl + arm64
  gradleTask = "assembleAndroidFullOpenglArm64Release";

  # ndk: r28c
  ndkVersion = "28.2.13676358";

  # android/versions.gradle
  compileSdk = "35";
  buildToolsVersion = "35.0.0";

  # MPAndroidChart is pinned to AGP 8.5.2 by prebuild.sh, whose default
  # build-tools is 34.0.0. F-Droid's builder has every version lying around;
  # a read-only Nix store has exactly what we declare, so declare it.
  extraBuildTools = [ "34.0.0" ];

  # prebuild.sh installs this itself ("required for qtbase-android"); we
  # provide it up-front instead so the build never talks to sdkmanager.
  extraPlatforms = [ "31" ];

  # The name F-Droid ships is "OsmAnd~". Ours carries the extra tilde.
  appName = "OsmAnd~~";
  # Installation identity, deliberately distinct from F-Droid's net.osmand.plus.
  applicationId = "io.github.aleclearmind.osmand";
}
