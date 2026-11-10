{
  description = "Prepared WSL2 kernel trees and a builder for modules that load into WSL's kernel";

  # Pinned on purpose and not meant to follow anyone's nixpkgs: the modules
  # depend only on the kernel source, its config and kgcc, so a nixpkgs bump
  # would rebuild the trees for nothing. Only build tools come from here.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      forAllSystems =
        f: lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (system: f nixpkgs.legacyPackages.${system});

      # Every supported WSL kernel release. Each needs its captured config in
      # ./conf/kernel-<release>.conf and the hash of the matching
      # microsoft/WSL2-Linux-Kernel tag; add-kernel.sh adds both.
      kernels = {
        "6.18.40.1-microsoft-standard-WSL2" = "sha256-YMqq3RzXNPibwzckYboDChp2IrUQYauX7Zc0nE+CgMY=";
        "6.18.54.1-microsoft-standard-WSL2" = "sha256-iN6eWKJV20yGn2TPtLFxA4mI52G0dcO2zEOMJV1lfcs=";
        "6.18.58.1-microsoft-standard-WSL2" = "sha256-PWAyLZoaCXW7fjiLnAi4nTsHljt3EMPPxZrg89qTXpk=";
      };

      kernelConfig = release: ./conf + "/kernel-${release}.conf";

      # The newest release, for dev shells and the unqualified names.
      latest = lib.last (lib.sort (a: b: lib.versionOlder a b) (lib.attrNames kernels));

      # The compiler the shipped WSL kernels are built with: a vanilla gcc
      # 13.2.0 from kernel.org. MODVERSIONS CRCs depend on it, so this is what
      # makes a module loadable.
      kgccVersion = "13.2.0";

      perSystem =
        pkgs:
        let
          # kernel.org only ships the toolchain as x86_64 host binaries. On
          # other hosts fall back to nixpkgs' cross gcc, which still makes a
          # faithful compile check but not a loadable module.
          haveKgcc = pkgs.stdenv.hostPlatform.isx86_64;

          kgcc = pkgs.stdenv.mkDerivation {
            pname = "kgcc";
            version = kgccVersion;

            src = pkgs.fetchurl {
              url = "https://mirrors.edge.kernel.org/pub/tools/crosstool/files/bin/x86_64/${kgccVersion}/x86_64-gcc-${kgccVersion}-nolibc-x86_64-linux.tar.xz";
              hash = "sha256-Lxl1SWoVIA8qrvTgmYxTC7y6bKI3KFvnbwMAh9pWP7Y=";
            };

            # Drops the archive's gcc-<version>-nolibc/x86_64-linux/ prefix; gcc
            # finds its libexec relative to argv[0].
            unpackPhase = ''
              mkdir -p $out
              tar -xJf $src -C $out --strip-components=2
            '';

            # The binaries want /lib64/ld-linux-x86-64.so.2. Rather than
            # patchelf them, each executable becomes a script running the
            # original through nixpkgs' loader: a patchelf'd non-PIE binary
            # gets a load segment below 0x400000, which qemu-user cannot map
            # on a 16K-page host (Apple silicon), and that is where this gets
            # built under emulation. --argv0 keeps gcc's relative lookup of
            # cc1, as and friends pointing at the wrappers.
            installPhase =
              let
                loader = "${pkgs.glibc}/lib/ld-linux-x86-64.so.2";
                libPath = lib.makeLibraryPath [
                  pkgs.glibc
                  pkgs.zstd
                  pkgs.zlib
                  pkgs.stdenv.cc.cc.lib
                ];
              in
              ''
                runHook preInstall
                find $out -type f -executable ! -name '*.so*' -print0 | while IFS= read -r -d "" f; do
                  isELF "$f" || continue
                  dir="$(dirname "$f")"
                  real=".$(basename "$f")-wrapped"
                  mv "$f" "$dir/$real"
                  printf '#!%s\nexec %s --argv0 "$0" --library-path %s "%s/%s" "$@"\n' \
                    "${pkgs.runtimeShell}" "${loader}" "${libPath}" "$dir" "$real" > "$f"
                  chmod +x "$f"
                done
                # gcc names itself after argv[0] in --version, which the kernel
                # records as CONFIG_CC_VERSION_TEXT. The WSL kernel's says
                # plain "gcc (GCC) 13.2.0".
                ln -s x86_64-linux-gcc $out/bin/gcc
                runHook postInstall
              '';

            dontConfigure = true;
            dontBuild = true;
            dontStrip = true;
            dontPatchELF = true;

            doInstallCheck = true;
            installCheckPhase = ''
              $out/bin/x86_64-linux-gcc --version | head -n1 | grep -qx 'x86_64-linux-gcc (GCC) ${kgccVersion}'
              echo 'int f(void) { return 0; }' > t.c
              $out/bin/x86_64-linux-gcc -O2 -c t.c -o t.o
            '';
          };

          # Tools kbuild runs on the build machine (scripts/, objtool,
          # resolve_btfids, sign-file, pahole for BTF). The target compiler and
          # binutils come from kgcc, which ships binutils 2.41 -- the same
          # version the WSL kernel records in CONFIG_LD_VERSION.
          cross = pkgs.pkgsCross.gnu64.stdenv.cc;
          crossCompile = if haveKgcc then "${kgcc}/bin/x86_64-linux-" else cross.targetPrefix;
          kcc = if haveKgcc then "${kgcc}/bin/gcc" else "${crossCompile}gcc";

          kbuildTools = with pkgs; [
            cross
            bc
            bison
            flex
            perl
            python3
            cpio
            kmod
            pahole
            elfutils
            openssl
            zlib
            zstd
            gmp
            libmpc
          ];

          # Kbuild reads ARCH and CROSS_COMPILE from the environment; dxgdrm's
          # Makefile takes KGCC and passes it as CC.
          kbuildEnv = {
            ARCH = "x86_64";
            CROSS_COMPILE = crossCompile;
            KGCC = kcc;
          };

          # LOCALVERSION= keeps setlocalversion from appending "+".
          makeFlags = [
            "ARCH=x86_64"
            "CROSS_COMPILE=${crossCompile}"
            "CC=${kcc}"
            "LOCALVERSION="
          ];

          # The WSL kernel tree prepared as far as a module build needs it.
          # vmlinux is built (not just modules_prepare) for the MODVERSIONS
          # CRCs, and kept so modules get BTF.
          mkKernelDev =
            release: hash:
            let
              version = builtins.head (lib.splitString "-" release);
              config = kernelConfig release;
            in
            pkgs.stdenv.mkDerivation (
              kbuildEnv
              // {
                pname = "wsl-kernel-dev";
                inherit version makeFlags;

                src = pkgs.fetchFromGitHub {
                  owner = "microsoft";
                  repo = "WSL2-Linux-Kernel";
                  tag = "linux-msft-wsl-${version}";
                  inherit hash;
                };

                nativeBuildInputs = kbuildTools;

                # The kernel sets its own flags; nix's hardening wrappers only
                # get in the way.
                hardeningDisable = [ "all" ];
                enableParallelBuilding = true;

                postPatch = ''
                  patchShebangs scripts tools
                '';

                # olddefconfig rewrites the compiler-derived options
                # (CC_VERSION_TEXT, GCC_VERSION, AS_/LD_VERSION, CC_HAS_*, ...)
                # from the toolchain it finds. With the kernel's own toolchain
                # only these may change, none of which reach a CRC:
                #   - the header comment, which names ARCH;
                #   - PAHOLE_VERSION, which only affects BTF;
                #   - CC_CAN_LINK, lost because kgcc has no libc. It gates
                #     userspace test programs only.
                #   - DEBUG_INFO_COMPRESSED_ZSTD, unavailable because kgcc's
                #     -gz=zstd probe fails. Debug info compression only.
                # Anything else means the CRCs may not match either, so stop
                # here rather than after the vmlinux build.
                #
                # Only set values are compared, sorted: a config taken from the
                # tree (add-kernel.sh) is not olddefconfig'd, so its order and
                # "is not set" lines differ from /proc/config.gz, its values not.
                configurePhase = ''
                  runHook preConfigure
                  cp ${config} .config
                  make $makeFlags olddefconfig
                  ${lib.optionalString haveKgcc ''
                    values() {
                      grep '^CONFIG_' "$1" | grep -vE '^CONFIG_(PAHOLE_VERSION|CC_CAN_LINK|DEBUG_INFO_COMPRESSED_ZSTD)=' | sort
                    }
                    if ! diff -u <(values ${config}) <(values .config); then
                      echo "the prepared .config differs from ${config}; modules would not load" >&2
                      exit 1
                    fi
                  ''}
                  runHook postConfigure
                '';

                buildFlags = [
                  "vmlinux"
                  "modules_prepare"
                ];

                postBuild = ''
                  cp vmlinux.symvers Module.symvers
                '';

                installPhase = ''
                  runHook preInstall

                  built_release="$(cat include/config/kernel.release)"
                  if [ "$built_release" != "${release}" ]; then
                    echo "prepared tree reports '$built_release', expected '${release}'" >&2
                    exit 1
                  fi

                  # Object files are only needed to link vmlinux; drop them to
                  # keep the store path small. scripts/ and tools/ keep theirs.
                  find . -path ./scripts -prune -o -path ./tools -prune -o \
                    \( -name '*.o' -o -name '*.a' -o -name '.*.cmd' \) -type f -print0 \
                    | xargs -0 rm -f
                  rm -rf .git .tmp_vmlinux* vmlinux.unstripped

                  # Module BTF is generated against vmlinux's .BTF section, which
                  # --strip-debug leaves alone; the DWARF is most of its size.
                  ${crossCompile}objcopy --strip-debug vmlinux

                  mkdir -p $out
                  cp -a . $out/

                  runHook postInstall
                '';

                dontFixup = true;
              }
            );

          kernelDevs = lib.mapAttrs mkKernelDev kernels;

          # Builds modules for one release in a writable copy of its prepared
          # tree. vmlinux is not rebuilt: the modules are loaded into the
          # kernel WSL ships, so the config may only change where `allowed`
          # says, and the build fails otherwise.
          #
          #   release   kernel release, a key of `kernels`
          #   patches   applied to the tree, e.g. to make a bool a tristate
          #   config    arguments to scripts/config, e.g. "-m RFKILL"
          #   allowed   ERE for the option names `config` may change
          #   targets   in-tree .ko targets to build, relative to the tree
          #   external  source directory built with M= after the targets
          #   install   .ko files to ship: tree-relative, or "M/x.ko" for the
          #             external module. They land in lib/modules/<release>/extra
          #             with a modules.dep, for `modprobe -d $out`.
          #
          # Other attributes go to mkDerivation, e.g. postInstall or preBuild.
          mkModules =
            {
              release,
              patches ? [ ],
              config ? "",
              allowed ? null,
              targets ? [ ],
              external ? null,
              install,
              ...
            }@args:
            let
              kernelDev = kernelDevs.${release};
            in
            assert lib.assertMsg (config == "" || allowed != null) "mkModules: config needs allowed";
            pkgs.stdenv.mkDerivation (
              kbuildEnv
              // removeAttrs args [
                "release"
                "config"
                "allowed"
                "targets"
                "external"
                "install"
              ]
              // {
                version = args.version or release;
                src = kernelDev;
                inherit patches makeFlags;

                nativeBuildInputs = kbuildTools ++ [ pkgs.removeReferencesTo ] ++ (args.nativeBuildInputs or [ ]);

                hardeningDisable = [ "all" ];
                enableParallelBuilding = true;

                # In-tree modpost takes vmlinux's exports from vmlinux.o, which
                # the prepared tree no longer has; vmlinux.symvers holds the
                # same CRCs.
                postPatch = ''
                  substituteInPlace scripts/Makefile.modpost \
                    --replace-fail 'missing-input := vmlinux.o' 'modpost-args += -i vmlinux.symvers'
                  ${args.postPatch or ""}
                '';

                configurePhase = ''
                  runHook preConfigure
                  ${lib.optionalString (config != "") ''
                    cp .config .config.prepared
                    scripts/config ${config}
                    make $makeFlags olddefconfig
                    changed="$(diff <(grep '^CONFIG_' .config.prepared) <(grep '^CONFIG_' .config) \
                      | grep '^[<>]' | grep -vE '^> CONFIG_(${allowed})=' || true)"
                    if [ -n "$changed" ]; then
                      echo "the config changed outside '${allowed}':" >&2
                      echo "$changed" >&2
                      exit 1
                    fi
                  ''}
                  runHook postConfigure
                '';

                # Without vmlinux.o, in-tree modpost writes the new modules'
                # exports to modules-only.symvers (also from a preBuild);
                # external modules need those and vmlinux's in Module.symvers.
                buildPhase = ''
                  runHook preBuild
                  ${lib.optionalString (targets != [ ]) ''
                    make $makeFlags -j$NIX_BUILD_CORES ${toString targets}
                  ''}
                  touch modules-only.symvers
                  sort -u -o Module.symvers Module.symvers vmlinux.symvers modules-only.symvers
                  ${lib.optionalString (external != null) ''
                    cp -r ${external} M
                    chmod -R u+w M
                    make $makeFlags -j$NIX_BUILD_CORES M=$PWD/M modules
                  ''}
                  runHook postBuild
                '';

                # The modules carry paths into the tree: in their debug info,
                # and as __FILE__ strings from WARN()s in inline headers. Left
                # in, Nix counts the whole tree (and kgcc through it) as a
                # runtime dependency. The debug info goes (.BTF stays), the
                # strings get their store hash blanked.
                installPhase = ''
                  runHook preInstall
                  for ko in ${toString install}; do
                    ${crossCompile}objcopy --strip-debug $ko
                    remove-references-to -t ${kernelDev} ${lib.optionalString haveKgcc "-t ${kgcc}"} $ko
                    install -Dm644 $ko $out/lib/modules/${release}/extra/$(basename $ko)
                  done
                  depmod -b $out ${release}
                  runHook postInstall
                '';

                disallowedReferences = args.disallowedReferences or ([ kernelDev ] ++ lib.optional haveKgcc kgcc);

                dontFixup = true;
              }
            );

          # mkModules for every release, joined into one module root; the
          # loader picks lib/modules/$(uname -r).
          mkModulesAll =
            name: f:
            pkgs.symlinkJoin {
              inherit name;
              paths = map (release: mkModules (f release)) (lib.attrNames kernels);
            };
        in
        {
          inherit
            kernelDevs
            mkModules
            mkModulesAll
            kbuildTools
            kbuildEnv
            ;
          kgcc = if haveKgcc then kgcc else null;
        };
    in
    {
      lib = {
        releases = lib.attrNames kernels;
        inherit latest kernelConfig;
      };

      # Functions and the kbuild environment, per build system.
      legacyPackages = forAllSystems perSystem;

      packages = forAllSystems (
        pkgs:
        let
          s = perSystem pkgs;
        in
        lib.mapAttrs' (release: drv: lib.nameValuePair "wsl-kernel-dev-${release}" drv) s.kernelDevs
        // lib.optionalAttrs (s.kgcc != null) { inherit (s) kgcc; }
        // {
          wsl-kernel-dev = s.kernelDevs.${latest};
          default = s.kernelDevs.${latest};
        }
      );
    };
}
