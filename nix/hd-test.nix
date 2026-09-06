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
  name = "hd-test-android";

  src = builtins.path {
    path = ../hd-test;
    name = "hd-test-src";
  };

  # 必须用 clang++:靠扩展名识别虽能编过,但链接阶段不带 C++ 运行时,
  # 一旦引入 iostream/std::string 就会链接失败。
  # -static-libstdc++ 必须带上:clang++ 默认动态链 libc++_shared.so,
  # 设备上没有这个 NDK 运行库,二进制直接 CANNOT LINK(v1.2.1 真机踩过)
  buildPhase = ''
    runHook preBuild
    ${llvm}/bin/${target}-clang++ -O2 -static-libstdc++ -o hd-test hd-test.cpp -lm
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 hd-test $out/bin/hd-test
    runHook postInstall
  '';
}
