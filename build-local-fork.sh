#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-1.97.1}"
export VCPKG_ROOT="${VCPKG_ROOT:-$HOME/vcpkg}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/android-sdk}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$HOME/android-ndk-r28c}"
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
export PATH="${FORK_FLUTTER_ROOT:-$HOME/flutter-3.24.5}/bin:$JAVA_HOME/bin:$HOME/.cargo/bin:$PATH"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}"
# The pinned libwebm parser omits this header; GCC 15 no longer includes it indirectly.
export CXXFLAGS_x86_64_unknown_linux_gnu="${CXXFLAGS_x86_64_unknown_linux_gnu:--include cstdint}"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
artifacts="${FORK_ARTIFACTS_DIR:-$(dirname "$PWD")/artifacts}"
mkdir -p -- "$artifacts"

if [[ -n "$(git ls-files -u)" ]]; then
  echo "Resolve merge conflicts before building." >&2
  exit 1
fi
git submodule update --init --recursive
(cd flutter && flutter pub get)
flutter_rust_bridge_codegen --rust-input src/flutter_ffi.rs \
  --dart-output flutter/lib/generated_bridge.dart \
  --c-output flutter/macos/Runner/bridge_generated.h \
  --llvm-path "${FORK_LLVM_ROOT:-/usr/lib/llvm-21}"
cp flutter/macos/Runner/bridge_generated.h flutter/ios/Runner/bridge_generated.h
(cd flutter && flutter test --reporter expanded)

version=$(python3 -c 'from pathlib import Path; print(next(x.split(":",1)[1].strip() for x in Path("flutter/pubspec.yaml").read_text().splitlines() if x.startswith("version:")))')
core_version=$(python3 -c 'import tomllib; print(tomllib.load(open("Cargo.toml","rb"))["package"]["version"])')
python3 build.py --flutter
cp "rustdesk-$core_version.deb" "$artifacts/rustdesk-$version-linux-amd64.deb"

# Flutter alone would silently reuse the old native library in jniLibs.
cargo ndk --platform 22 --target aarch64-linux-android build \
  --locked --release --features flutter,hwcodec
"$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip" \
  -o flutter/android/app/src/main/jniLibs/arm64-v8a/librustdesk.so \
  target/aarch64-linux-android/release/liblibrustdesk.so
(cd flutter && flutter build apk --release --split-per-abi --target-platform android-arm64)
cp flutter/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk \
  "$artifacts/rustdesk-$version-herdr-arm64.apk"
sha256sum "$artifacts/rustdesk-$version-linux-amd64.deb" \
  "$artifacts/rustdesk-$version-herdr-arm64.apk" > "$artifacts/rustdesk-$version.sha256"
