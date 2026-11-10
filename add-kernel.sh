#!/usr/bin/env bash
set -euo pipefail

# Adds a WSL kernel release to the flake: fetches its in-tree config into
# conf/ and its source hash into `kernels` in flake.nix.
#
#   ./add-kernel.sh                  # the newest linux-msft-wsl-* tag
#   ./add-kernel.sh 6.18.54.1
#   ./add-kernel.sh "$(uname -r)"    # the kernel this WSL runs
#
# Run inside WSL on that kernel, it takes /proc/config.gz. Otherwise it takes
# the in-tree config, which is not olddefconfig'd (stale header, different
# order; the flake's config check compares values only) and can lack modules
# the shipped kernel has (6.18.58.1: CRYPTO_CAMELLIA, CRYPTO_KRB5*).

cd "$(dirname "$0")"
repo=microsoft/WSL2-Linux-Kernel

version="${1:-}"
version="${version%%-*}"
if [ -z "${version}" ]; then
  version="$(git ls-remote --tags --refs "https://github.com/${repo}" 'linux-msft-wsl-*' \
    | sed 's|.*/linux-msft-wsl-||' | sort -V | tail -n1)"
fi
tag="linux-msft-wsl-${version}"

config="$(mktemp)"
trap 'rm -f "${config}"' EXIT
if [ "$(uname -r | cut -d- -f1)" = "${version}" ] && [ -r /proc/config.gz ]; then
  zcat /proc/config.gz > "${config}"
else
  curl -fsSL -o "${config}" "https://raw.githubusercontent.com/${repo}/${tag}/arch/x86/configs/config-wsl"
fi

localversion="$(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"$/\1/p' "${config}")"
release="${version}${localversion}"
conf="conf/kernel-${release}.conf"

if grep -qF "\"${release}\" = " flake.nix; then
  echo "add-kernel.sh: ${release} is already in flake.nix" >&2
  exit 1
fi

echo "add-kernel.sh: prefetching ${tag} (a few hundred MB)"
hash="$(nix flake prefetch --json "github:${repo}/${tag}" | jq -r .hash)"

cp "${config}" "${conf}"
# The entries are sorted by version; a new release goes last.
sed -i "/^      kernels = {/,/^      };/ s|^      };|        \"${release}\" = \"${hash}\";\n      };|" flake.nix

echo "add-kernel.sh: added ${release} (${conf}, ${hash})"
echo "build it with: nix build '.#\"wsl-kernel-dev-${release}\"'"
echo "git add ${conf} before building, the flake only sees tracked files"
