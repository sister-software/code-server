#!/usr/bin/env bash
# Builds the iSH x86-Linux emulator core for iOS and an Alpine fakefs, staging
# both where the Xcode build expects them. Artifacts are gitignored (like the
# vscode-web bundle); re-run after a clean checkout.
#
# Produces:
#   CodeServerClient/Remote/Ish/lib{ish,ish_emu,fakefs}.a   (arm64 device libs)
#   Vendor/ish-rootfs/                                        (Alpine i386 fakefs)
#
# Prereqs (one-time): brew install meson ninja libarchive
#   (iSH is GPLv3 — see Vendor/ish/LICENSE.md)

set -euo pipefail
cd "$(dirname "$0")/.."   # ios/

ISH=Vendor/ish
ALPINE_VER=3.20
ALPINE_REL=3.20.3
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/releases/x86/alpine-minirootfs-${ALPINE_REL}-x86.tar.gz"

export PATH="/opt/homebrew/bin:$PATH"
export PKG_CONFIG_PATH="/opt/homebrew/opt/libarchive/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

if [ ! -d "$ISH/emu" ]; then
  echo "[1/5] Cloning iSH…"
  git clone --recursive https://github.com/ish-app/ish.git "$ISH"
fi

echo "[2/5] Cross-compiling iSH core for iOS arm64…"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
cat > "$ISH/cross-ios.txt" <<EOF
[binaries]
c = 'clang'
cpp = 'clang++'
ar = 'ar'
strip = 'strip'
[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
[built-in options]
c_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=16.4']
c_link_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=16.4']
cpp_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=16.4']
[properties]
needs_exe_wrapper = true
EOF
( cd "$ISH"
  export CC_FOR_BUILD="env -u SDKROOT -u IPHONEOS_DEPLOYMENT_TARGET xcrun clang"
  rm -rf build-ios
  meson setup build-ios --cross-file cross-ios.txt --default-library=static >/dev/null
  ninja -C build-ios libish_emu.a libish.a libfakefs.a )

echo "[3/5] Staging libs…"
mkdir -p CodeServerClient/Remote/Ish
cp "$ISH"/build-ios/lib{ish_emu,ish,fakefs}.a CodeServerClient/Remote/Ish/

echo "[4/5] Building fakefsify (native)…"
( cd "$ISH"
  rm -rf build-native
  meson setup build-native --default-library=static >/dev/null
  ninja -C build-native tools/fakefsify )

echo "[5/5] Building Alpine fakefs…"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/alpine.tar.gz" "$ALPINE_URL"
rm -rf Vendor/ish-rootfs
"$ISH"/build-native/tools/fakefsify "$tmp/alpine.tar.gz" Vendor/ish-rootfs

echo "Done. libs → CodeServerClient/Remote/Ish, rootfs → Vendor/ish-rootfs ($(du -sh Vendor/ish-rootfs | cut -f1))"
