{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  fetchurl,
  ndk-bundle,
  meson,
  ninja,
  pkg-config,
  python3,
}:
let
  ndkRoot = "${ndk-bundle}/libexec/android-sdk/ndk-bundle";
  llvm = "${ndkRoot}/toolchains/llvm/prebuilt/linux-x86_64";
  # API 28:bionic 的 glob/globfree 自 28 起才导出(目标设备 Android 9+)
  api = "28";
  target = "aarch64-linux-android${api}";

  # ---- libevdev:NDK 交叉静态库(meson cross file) ----
  libevdev-android = stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "libevdev-android-aarch64";
    version = "1.13.2";

    src = fetchurl {
      url = "https://www.freedesktop.org/software/libevdev/libevdev-${finalAttrs.version}.tar.xz";
      hash = "sha256-PsqGps5VuB1bzpEGN/xFHIu+NzsflpjzdcfxrQ3jrEg=";
    };

    nativeBuildInputs = [
      meson
      ninja
      pkg-config
      python3
    ];

    # bionic 无 librt(功能在 libc 里);meson 的 system 用 'linux' 选对
    # include/linux/linux/input.h(NDK clang wrapper 已固定 android target);
    # configure_file 的 python 脚本显式用 python3 调用,避免 shebang/env 玄学
    postPatch = ''
      sed -i "s/dep_rt = cc.find_library('rt')/dep_rt = cc.find_library('rt', required: false)/" meson.build
      sed -i "s/command: \\[make_event_names,/command: [find_program('python3'), make_event_names,/" meson.build
    '';

    configurePhase = ''
      runHook preConfigure
      mkdir build
      cat > cross.ini <<EOF
      [binaries]
      c = ['${llvm}/bin/${target}-clang']
      cpp = ['${llvm}/bin/${target}-clang++']
      ar = ['${llvm}/bin/llvm-ar']
      strip = ['${llvm}/bin/llvm-strip']

      [host_machine]
      system = 'linux'
      cpu_family = 'aarch64'
      cpu = 'aarch64'
      endian = 'little'
      EOF
      echo "=== cross.ini ==="; cat cross.ini; meson setup build \
        --prefix=$out \
        --libdir=lib \
        --cross-file cross.ini \
        -Ddefault_library=static \
        -Dtests=disabled \
        -Ddocumentation=disabled
      runHook postConfigure
    '';

    buildPhase = "meson compile -C build";
    installPhase = "DESTDIR= meson install -C build";

    dontFixup = true;
  });

  # ---- joycond:按上游 Android.mk 的源列表直接编译 ----
  # 源文件清单与 Android.mk LOCAL_SRC_FILES 一致(排除 ctlr_detector_udev.cpp)
  joycond-src-files = [
    "src/main.cpp"
    "src/ctlr_detector_android.cpp"
    "src/ctlr_mgr.cpp"
    "src/epoll_mgr.cpp"
    "src/epoll_subscriber.cpp"
    "src/phys_ctlr.cpp"
    "src/virt_ctlr.cpp"
    "src/virt_ctlr_combined.cpp"
    "src/virt_ctlr_passthrough.cpp"
    "src/virt_ctlr_pro.cpp"
  ];
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "joycond-android";
  version = "0.9.0-${lib.substring 0 7 finalAttrs.src.rev}";

  src = fetchFromGitHub {
    owner = "DanielOgorchock";
    repo = "joycond";
    rev = "0df025ac5dc284b1f31172b6b252321ba788c4de";
    hash = "sha256-2rHSQFQvpNZWZJQenZxPEVkbUFQvhRz1Om1AnnIio4M=";
  };

  # 上游 Android.mk 链 AOSP 内部 libnl,但 ctlr_detector_android.cpp
  # 实际只用裸 netlink socket,<netlink/msg.h> 是无用 include;
  # bionic 需显式 include <libgen.h> 才有 basename
  postPatch = ''
    sed -i '/#include <netlink\/msg.h>/d' src/ctlr_detector_android.cpp
    sed -i 's|#include <linux/types.h>|#include <libgen.h>\n#include <linux/types.h>|' src/ctlr_detector_android.cpp
  '';

  # clang 的 android target 自动定义 __ANDROID__,触发 android 检测器分支
  buildPhase = ''
    runHook preBuild
    ${llvm}/bin/${target}-clang++ \
      -std=c++17 -fexceptions -O2 -Wall -Wno-error -static-libstdc++ \
      -Iinclude -I${libevdev-android}/include/libevdev-1.0 \
      ${lib.escapeShellArgs joycond-src-files} \
      ${libevdev-android}/lib/libevdev.a \
      -llog \
      -o joycond
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 joycond $out/bin/joycond
    runHook postInstall
  '';

  dontStrip = false;
  dontFixup = true;

  meta = {
    description = "joycond 守护进程,aarch64-android 静态构建(仅依赖 bionic + liblog)";
    homepage = "https://github.com/DanielOgorchock/joycond";
    license = lib.licenses.gpl3Only;
    platforms = [ "x86_64-linux" ];
  };
})
