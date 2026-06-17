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
#   Vendor/ish-rootfs/                                          (populated Alpine aarch64 fakefs)
#
# The rootfs is built from scripts/rootfs.Dockerfile (out-of-box packages + the
# `operator` user); see that file. bootstrap.sh installs the heavier dev tooling
# from inside the guest on first boot.
#
# Prereqs (one-time): brew install meson ninja libarchive; Docker Desktop (the
# rootfs is built as a linux/arm64 image — native on Apple Silicon).
#   (ish-arm64 is GPLv3 — see Vendor/ish-arm64/LICENSE.md)

set -euo pipefail
cd "$(dirname "$0")/.."   # ios/
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"

ISH=Vendor/ish-arm64
# Pin to the OpenMinis master commit the gadget-dedup patch was verified against.
ISH_COMMIT=3db171630bcf993bf7dff9c1768966e55cbbda49

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
  fi
  # task-uaf: detached guest pthreads that miss do_exit_group's SIGKILL timeout
  # keep writing current->cpu from the JIT after task_destroy; recycling the task
  # struct caused use-after-free heap corruption ("corruption of free block") that
  # crashed the app under threaded runtimes (tmux, node, etc.) on-device. Stop
  # recycling task structs (leak them). Idempotent: skip if applied.
  if git apply --reverse --check "$SCRIPTS/ish-arm64-task-uaf.patch" >/dev/null 2>&1; then
    echo "  task-uaf already applied"
  else
    git apply "$SCRIPTS/ish-arm64-task-uaf.patch"
    echo "  task-uaf applied"
  fi
  # capget: the stub returned 0 without reporting a capability version, so OCI
  # runtimes (crun/podman) failed with "unknown capability version". Implement it
  # (report v3 + full caps; we don't enforce capabilities). Idempotent.
  if git apply --reverse --check "$SCRIPTS/ish-arm64-capget.patch" >/dev/null 2>&1; then
    echo "  capget already applied"
  else
    git apply "$SCRIPTS/ish-arm64-capget.patch"
    echo "  capget applied"
  fi
  # proc-status: add /proc/<pid>/status (uid/gid/caps). OCI runtimes read
  # /proc/self/status and abort ("no such file or directory") without it. Idempotent.
  if git apply --reverse --check "$SCRIPTS/ish-arm64-proc-status.patch" >/dev/null 2>&1; then
    echo "  proc-status already applied"
  else
    git apply "$SCRIPTS/ish-arm64-proc-status.patch"
    echo "  proc-status applied"
  fi
  # clone-ns: tolerate (ignore) CLONE_NEW* namespace flags so container runtimes
  # can clone into "new" namespaces instead of failing with EINVAL ("cannot
  # clone: Invalid argument"). No real isolation. Idempotent.
  if git apply --reverse --check "$SCRIPTS/ish-arm64-clone-ns.patch" >/dev/null 2>&1; then
    echo "  clone-ns already applied"
  else
    git apply "$SCRIPTS/ish-arm64-clone-ns.patch"
    echo "  clone-ns applied"
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

echo "[7/7] Building populated Alpine aarch64 fakefs (Docker linux/arm64)…"
# A bare minirootfs has no packages and no users. We bake the out-of-box set +
# the `operator` user via a linux/arm64 image (native on Apple Silicon), export
# it, then convert to the iSH fakefs format. Docker is required for this step.
if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker not found — needed to build the populated rootfs." >&2
  echo "       install Docker Desktop (Apple Silicon runs linux/arm64 natively)." >&2
  exit 1
fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
echo "  building rootfs image…"
docker build --platform linux/arm64 -t ish-arm64-rootfs -f scripts/rootfs.Dockerfile scripts >/dev/null
echo "  exporting…"
cid=$(docker create --platform linux/arm64 ish-arm64-rootfs)
docker export "$cid" -o "$tmp/rootfs.tar"
docker rm -f "$cid" >/dev/null
# docker export uses a pax tar that flags names as UTF-8; fakefsify reads it in
# the C locale and aborts on non-ASCII names (e.g. a Hungarian CA cert symlink:
# "Linkpath can't be converted from UTF-8 to current locale"). Re-pack as GNU
# tar, which libarchive reads as opaque bytes — no charset conversion. (/usr/bin/tar
# is bsdtar on macOS; the @archive form copies entries between archives.)
/usr/bin/tar --format gnutar -cf "$tmp/rootfs-gnu.tar" "@$tmp/rootfs.tar"
rm -rf Vendor/ish-rootfs
"$ISH"/build-native/tools/fakefsify "$tmp/rootfs-gnu.tar" Vendor/ish-rootfs

echo "Done. libs → CodeServerClient/Remote/Ish (+ sim/), rootfs → Vendor/ish-rootfs ($(du -sh Vendor/ish-rootfs | cut -f1))"
