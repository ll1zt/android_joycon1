{
  description = "joycond for Android — Joy-Con 系统级合成 KernelSU 模块 (Pixel 6 / GKI 6.1)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable?shallow=1";
  };

  outputs =
    { self, nixpkgs }:
    let
      # 构建主机固定 x86_64-linux(交叉产物为 aarch64-android)
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = import nixpkgs {
        inherit system;
        config = {
          # 主实例仅白名单 android-* 包(devShell 的 android-tools 等)
          allowUnfreePredicate =
            pkg: lib.hasPrefix "android-" (lib.getName pkg);
        };
        overlays = [ ];
      };
      # androidenv 包簇(NDK 及其依赖的 src 派生物)全部 unfree 且内部多层实例化,
      # 谓词无法覆盖全部检查点;按社区惯例用专用 allowUnfree 实例只取 NDK。
      # 仅作为构建工具进入闭包,不污染主实例。
      pkgsAndroid = import nixpkgs {
        inherit system;
        config = { allowUnfree = true; };
        overlays = [ ];
      };
    in
    {
      packages.${system} = {
        joycond-android = pkgs.callPackage ./nix/joycond-android.nix {
          ndk-bundle = pkgsAndroid.androidenv.androidPkgs.ndk-bundle;
        };
        kernelsu-module = pkgs.callPackage ./nix/module.nix {
          joycond = self.packages.${system}.joycond-android;
          moduleSrc = builtins.path {
            path = ./module;
            name = "joycond-module-src";
          };
        };
        default = self.packages.${system}.kernelsu-module;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = builtins.attrValues {
          inherit (pkgs)
            nixfmt-rfc-style
            android-tools
            zip
            ;
        };
        shellHook = ''
          echo "joycond-android: nix build 产出 KernelSU 模块 zip 于 ./result"
        '';
      };
    };
}
