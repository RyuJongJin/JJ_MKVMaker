#!/bin/sh
# 123 · 121: Android (arm64) 용 stable-diffusion.cpp 의 sd-cli 를 소스에서 빌드해
# third_party/sdcpp/android/arm64-v8a/libsdcli.so 로 둔다 (APK 의 jniLibs 로 들어가 앱의 네이티브 라이브러리 폴더에서 실행된다 -
# Android 10+ 는 앱 데이터 폴더의 파일을 실행할 수 없으므로 받아서 쓰지 않는다).
#   소스: https://github.com/leejet/stable-diffusion.cpp (MIT) 커밋 고정 - Windows 실행 파일 (ai_catalog.dart 의 sdCppVersion) 과 같은 판
#   CPU (arm64, dotprod · i8mm · fp16) 만. OpenMP 는 끈다.
# 사용법 (Git Bash): sh tool/build_sdcpp_android.sh   - Android NDK · SDK 의 cmake (tools/android-sdk) 가 필요
set -e
APP=$(cd "$(dirname "$0")/.." && pwd)
COMMIT=228c707fde018221de74674f1c2f480a9d2b228e
SHORT=228c707
NDK_ROOT=${ANDROID_NDK:-$(ls -d "$APP"/../tools/android-sdk/ndk/* | sort | tail -1)}
CMAKE_DIR=$(ls -d "$APP"/../tools/android-sdk/cmake/* | sort | tail -1)/bin
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) HOST=windows-x86_64; EXE=.exe ;; Darwin) HOST=darwin-x86_64; EXE= ;; *) HOST=linux-x86_64; EXE= ;; esac
TC=$NDK_ROOT/toolchains/llvm/prebuilt/$HOST/bin
WORK=${SDCPP_WORK:-${TMPDIR:-/tmp}/jj_sdcpp_android}
if [ ! -d "$WORK/src/.git" ]; then
  rm -rf "$WORK" && mkdir -p "$WORK"
  git clone --recursive https://github.com/leejet/stable-diffusion.cpp.git "$WORK/src"
fi
cd "$WORK/src"
git fetch --depth 1 origin "$COMMIT" 2>/dev/null || git fetch origin
git checkout -q "$COMMIT" 2>/dev/null || git checkout -q "$SHORT"
git submodule update --init --recursive
PATH="$CMAKE_DIR:$PATH"
cmake -S . -B build-android -G Ninja -DCMAKE_MAKE_PROGRAM="$CMAKE_DIR/ninja$EXE" \
  -DCMAKE_TOOLCHAIN_FILE="$NDK_ROOT/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-28 -DCMAKE_BUILD_TYPE=Release \
  -DGGML_OPENMP=OFF -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+i8mm+fp16 > cmake.log
cmake --build build-android --target sd-cli -j 8 > build.log 2>&1
OUT="$APP/third_party/sdcpp/android/arm64-v8a"
mkdir -p "$OUT"
"$TC/llvm-strip$EXE" -o "$OUT/libsdcli.so" build-android/bin/sd-cli
ls -l "$OUT/libsdcli.so"
