#!/usr/bin/env bash
# Installs the macOS SDK's frameworks, headers and libraries into a toolchain
# targeting macOS, for C code using Apple's frameworks (CoreFoundation, Security,
# ...) from Linux or Windows. Its `zcaml-cc` uses `lib/zcaml/macos-sdk`
# (build/ocaml/cc_wrapper.zig). On macOS, Xcode's SDK is used without this.
#
#   scripts/add-macos-sdk.sh <toolchain-dir>
#
# The SDK is hexops' xcode-frameworks, a subset of Xcode's, downloaded from them:
# zcaml doesn't redistribute it. It is Apple's, under the Xcode and Apple SDKs
# Agreement. Pinned with build.zig.zon's `xcode_frameworks`: keep them in sync.
set -euo pipefail

commit=62f660e82e4eddb5007cb4cf06a6d3d31237f05e
sha256=ff6978e4f8b0a14819cfeb01f4e48cf6e775820fe5a26900618ae662a0a639ee
url="https://code.hexops.org/hexops/xcode-frameworks/archive/$commit.tar.gz"

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <toolchain-dir>" >&2
  exit 2
fi
toolchain="$1"
if ! compgen -G "$toolchain/bin/zcaml-cc-*-apple-darwin*" >/dev/null; then
  echo "error: $toolchain is not a toolchain targeting macOS (no bin/zcaml-cc-*-apple-darwin)" >&2
  exit 1
fi

echo "The macOS SDK is Apple's, under the Xcode and Apple SDKs Agreement:"
echo "  https://www.apple.com/legal/sla/docs/xcode.pdf"
echo "Downloading hexops' xcode-frameworks ($commit)..."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl -fsSL -o "$work/sdk.tar.gz" "$url"
if command -v sha256sum >/dev/null; then
  got="$(sha256sum "$work/sdk.tar.gz" | cut -d' ' -f1)"
else
  got="$(shasum -a 256 "$work/sdk.tar.gz" | cut -d' ' -f1)"
fi
if [[ "$got" != "$sha256" ]]; then
  echo "error: $url: sha256 $got, expected $sha256" >&2
  exit 1
fi
tar -xzf "$work/sdk.tar.gz" -C "$work"

# Xcode's layout, which zcaml-cc expects of any SDK.
sdk="$toolchain/lib/zcaml/macos-sdk"
rm -rf "$sdk"
mkdir -p "$sdk/System/Library" "$sdk/usr"
mv "$work/xcode-frameworks/Frameworks" "$sdk/System/Library/Frameworks"
mv "$work/xcode-frameworks/include" "$sdk/usr/include"
mv "$work/xcode-frameworks/lib" "$sdk/usr/lib"
cp "$work/xcode-frameworks/LICENSE" "$sdk/LICENSE"
echo "Installed to $sdk"
