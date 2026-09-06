{
  stdenvNoCC,
  ndk-bundle,
}:
let
  ndkRoot = "${ndk-bundle}/libexec/android-sdk/ndk-bundle";
  llvm = "${ndkRoot}/toolchains/llvm/prebuilt/linux-x86_64";
  api = "28";
  target = "aarch64-linux-android${api}";
in
stdenvNoCC.mkDerivation {
  name = "ff-test-android";

  src = builtins.path {
    path = ../ff-test;
    name = "ff-test-src";
  };

  buildPhase = ''
    runHook preBuild
    ${llvm}/bin/${target}-clang -O2 -o ff-test ff-test.c
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 ff-test $out/bin/ff-test
    runHook postInstall
  '';
}
