# wsl-kernel

Prepared WSL2 kernel trees and a builder for kernel modules that load into
the kernel WSL ships. Used by [dxgdrm](https://github.com/weaselway/dxgdrm)
and [weaselway](https://github.com/weaselway/weaselway).

WSL runs Microsoft's kernel, and it cannot be swapped without `kernel=` in
`.wslconfig`. A module only loads into it if it was built for the exact
release, against the same config and with the same compiler, because
`CONFIG_MODVERSIONS=y` checks symbol CRCs.

## What the flake provides

- `packages.<system>.wsl-kernel-dev-<release>`: the `microsoft/WSL2-Linux-Kernel`
  tag of the release, configured with `conf/kernel-<release>.conf`, with
  `vmlinux` and `modules_prepare` built. Object files are dropped; `vmlinux`
  keeps `.BTF` for module BTF. About 6 minutes and 1.8 GB each.
- `packages.x86_64-linux.kgcc`: the kernel.org crosstool gcc 13.2.0 and
  binutils 2.41 the WSL kernel is built with. kernel.org ships only x86_64
  host binaries; on other hosts a nixpkgs cross gcc is used, which compiles
  but does not make loadable modules.
- `legacyPackages.<system>.mkModules`: builds modules for one release, see
  below. `mkModulesAll name f` calls it for every release and joins the
  results into one module root.
- `lib.releases`, `lib.latest` and `lib.kernelConfig <release>` (the path of
  the captured config).

## Checks

- The tree's configure phase fails if `olddefconfig` with kgcc changes any
  value of the captured config other than `PAHOLE_VERSION`, `CC_CAN_LINK` and
  `DEBUG_INFO_COMPRESSED_ZSTD`, none of which reach a CRC. A changed value
  means a toolchain mismatch.
- The install phase fails if `include/config/kernel.release` is not the
  release.
- `mkModules` fails if `config` changes options outside `allowed`, because
  the modules are loaded into a `vmlinux` built from the stock config.

## mkModules

```nix
wsl-kernel.legacyPackages.x86_64-linux.mkModules {
  pname = "wsl-bluetooth-modules";
  release = "6.18.54.1-microsoft-standard-WSL2";
  config = "-m RFKILL";               # scripts/config arguments
  allowed = "RFKILL(_[A-Z0-9_]+)?";   # ERE of option names config may change
  targets = [ "net/rfkill/rfkill.ko" ];
  install = [ "net/rfkill/rfkill.ko" ];
}
```

- `patches` are applied to the tree first.
- `external` is a source directory built with `M=` after the targets; its
  modules are named `M/<name>.ko` in `install`.
- Other attributes (`preBuild`, `postInstall`, ...) go to `mkDerivation`.
- The output is `lib/modules/<release>/extra/*.ko` with a `modules.dep`, so
  `modprobe -d $out <module>` loads a module and its dependencies from there.
  Debug info is stripped and paths into the tree are blanked, so the output
  does not reference the tree or kgcc.
- Targets build against `vmlinux.symvers`, since `vmlinux.o` is gone. Targets
  that are only needed for their symbols (stock modules the new ones import
  from) can be built and left out of `install`. The external module links
  against vmlinux and every in-tree module built before it, also from a
  `preBuild`.

## Pinned nixpkgs

The output depends only on the kernel source, the config and kgcc. nixpkgs
provides build tools only, so it is pinned in `flake.lock` and consumers
should not override it with `follows`: a nixpkgs update would rebuild every
tree for nothing. Update it by hand when a tool needs it.

## Adding a kernel release

```sh
./add-kernel.sh                 # the newest linux-msft-wsl-* tag
./add-kernel.sh 6.18.54.1
./add-kernel.sh "$(uname -r)"   # the kernel this WSL runs
git add conf
```

It writes the config to `conf/kernel-<release>.conf` and adds the source
hash to `kernels` in [flake.nix](flake.nix). Run inside WSL on that kernel,
it takes `/proc/config.gz`. Otherwise it takes the tag's
`arch/x86/configs/config-wsl`, which can lack modules the shipped kernel has
(6.18.58.1 lacks three crypto modules); compare it with `/proc/config.gz`
once WSL runs that kernel. Order and `is not set` lines differ between the
two, so the check compares set values only.
