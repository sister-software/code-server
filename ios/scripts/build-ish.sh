#!/usr/bin/env bash
# Builds the ish-arm64 (OpenMinis/ish-arm64) emulator core for iOS and an Alpine
# fakefs, staging both where the Xcode build expects them. ish-arm64 runs an
# AArch64 Linux guest under Asbestos (same-arch threaded interpreter, ~3-30x
# overhead vs native), so Alpine here is arm64 — far faster than iSH's x86
# emulation. Artifacts are gitignored (like the vscode-web bundle); re-run after
# a clean checkout.
#
# We track OpenMinis/ish-arm64 directly — it's the canonical home of the ARM64
# Asbestos backend (the rcarmo/ios-linuxkit fork we used previously is a squashed
# snapshot of it plus an iOS app shell we don't use).
#
# Produces:
#   CodeServerClient/Remote/Ish/lib{ish,ish_emu,fakefs}.a       (arm64 device libs)
#   CodeServerClient/Remote/Ish/sim/lib{ish,ish_emu,fakefs}.a   (arm64 simulator libs)
#   Vendor/ish-rootfs/                                          (Alpine aarch64 fakefs)
#
# Prereqs (one-time): brew install meson ninja libarchive
#   (ish-arm64 is GPLv3 — see Vendor/ish-arm64/LICENSE.md)

set -euo pipefail
cd "$(dirname "$0")/.."   # ios/
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"

ISH=Vendor/ish-arm64
# Pin to the OpenMinis master commit the gadget-dedup patch was verified against.
ISH_COMMIT=3db171630bcf993bf7dff9c1768966e55cbbda49
ALPINE_VER=3.20
ALPINE_REL=3.20.3
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/releases/aarch64/alpine-minirootfs-${ALPINE_REL}-aarch64.tar.gz"

export PATH="/opt/homebrew/bin:$PATH"
export PKG_CONFIG_PATH="/opt/homebrew/opt/libarchive/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

if [ ! -d "$ISH/emu" ]; then
  echo "[1/7] Cloning OpenMinis/ish-arm64…"
  git clone --recursive https://github.com/OpenMinis/ish-arm64.git "$ISH"
fi

echo "[2/7] Pinning + patching ish-arm64…"
( cd "$ISH"
  git fetch --depth 1 origin "$ISH_COMMIT" 2>/dev/null || true
  git checkout -q "$ISH_COMMIT"
  git submodule update --init --recursive >/dev/null 2>&1 || true
  # Upstream's bits.S and math.S both define sxtw/uxtb/uxth/rev32; math.S is the
  # canonical version (it consumes the `sf`/packed param word the decoder emits),
  # so drop the stale simple copies from bits.S. Without this the app fails to
  # link under -force_load (duplicate gadget symbols). Idempotent: skip if applied.
  if git apply --reverse --check "$SCRIPTS/ish-arm64-gadget-dedup.patch" >/dev/null 2>&1; then
    echo "  gadget-dedup already applied"
  else
    git apply "$SCRIPTS/ish-arm64-gadget-dedup.patch"
    echo "  gadget-dedup applied"
  fi )

echo "[3/7] Cross-compiling ish-arm64 core for iOS arm64…"
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
  # -Dguest_arch=arm64: OpenMinis defaults the guest to x86; we need the AArch64
  # guest engine (else /bin/sh from arm64 Alpine fails do_execve with ENOEXEC).
  meson setup build-ios --cross-file cross-ios.txt --default-library=static -Dguest_arch=arm64 >/dev/null
  ninja -C build-ios libish_emu.a libish.a libfakefs.a )

echo "[4/7] Staging device libs…"
mkdir -p CodeServerClient/Remote/Ish
cp "$ISH"/build-ios/lib{ish_emu,ish,fakefs}.a CodeServerClient/Remote/Ish/

echo "[5/7] Cross-compiling for the iOS Simulator (arm64) + staging…"
# Same arm64 code, but a simulator-platform Mach-O (the linker rejects an
# iphoneos archive when building for the simulator). Lets the app run in the
# Simulator for side-by-side testing. Apple-Silicon host only.
SIMSDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
cat > "$ISH/cross-sim.txt" <<EOF
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
c_args = ['-target', 'arm64-apple-ios16.4-simulator', '-isysroot', '$SIMSDK']
c_link_args = ['-target', 'arm64-apple-ios16.4-simulator', '-isysroot', '$SIMSDK']
cpp_args = ['-target', 'arm64-apple-ios16.4-simulator', '-isysroot', '$SIMSDK']
[properties]
needs_exe_wrapper = true
EOF
( cd "$ISH"
  export CC_FOR_BUILD="env -u SDKROOT -u IPHONEOS_DEPLOYMENT_TARGET xcrun clang"
  rm -rf build-sim
  meson setup build-sim --cross-file cross-sim.txt --default-library=static -Dguest_arch=arm64 >/dev/null
  ninja -C build-sim libish_emu.a libish.a libfakefs.a )
mkdir -p CodeServerClient/Remote/Ish/sim
cp "$ISH"/build-sim/lib{ish_emu,ish,fakefs}.a CodeServerClient/Remote/Ish/sim/

echo "[6/7] Building fakefsify (native)…"
( cd "$ISH"
  rm -rf build-native
  meson setup build-native --default-library=static >/dev/null
  ninja -C build-native tools/fakefsify )

echo "[7/7] Building Alpine aarch64 fakefs…"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/alpine.tar.gz" "$ALPINE_URL"
rm -rf Vendor/ish-rootfs
"$ISH"/build-native/tools/fakefsify "$tmp/alpine.tar.gz" Vendor/ish-rootfs

echo "Done. libs → CodeServerClient/Remote/Ish (+ sim/), rootfs → Vendor/ish-rootfs ($(du -sh Vendor/ish-rootfs | cut -f1))"
