{
  lib,
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
  name = "hd-test-android";

  src = builtins.path {
    path = ../hd-test;
    name = "hd-test-src";
  };

  buildPhase = ''
    runHook preBuild
    ${llvm}/bin/${target}-clang -O2 -o hd-test hd-test.cpp -lm
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 hd-test $out/bin/hd-test
    runHook postInstall
  '';
}
