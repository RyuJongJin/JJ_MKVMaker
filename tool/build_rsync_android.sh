#!/bin/sh
# Android (arm64) 용 rsync 를 소스에서 빌드해 third_party/rsync/android/arm64-v8a/librsync.so 로 둔다
# (APK 의 jniLibs 로 들어가 앱의 네이티브 라이브러리 폴더에서 실행된다. Android 의 libc 만 쓴다).
#   소스: https://download.samba.org/pub/rsync/src/rsync-3.4.1.tar.gz (SHA256 고정, 고치지 않음)
#   선택 기능 (openssl · xxhash · zstd · lz4 · iconv · ACL · xattr) 은 끄고, 들어 있는 zlib · popt 를 쓴다.
# 사용법 (Git Bash): sh tool/build_rsync_android.sh   - Android NDK 가 필요 (ANDROID_NDK 또는 tools/android-sdk/ndk/*)
set -e
APP=$(cd "$(dirname "$0")/.." && pwd)
VER=3.4.1
SHA=2924bcb3a1ed8b551fc101f740b9f0fe0a202b115027647cf69850d65fd88c52
NDK_ROOT=${ANDROID_NDK:-$(ls -d "$APP"/../tools/android-sdk/ndk/* | sort | tail -1)}
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) HOST=windows-x86_64; EXE=.exe ;; Darwin) HOST=darwin-x86_64; EXE= ;; *) HOST=linux-x86_64; EXE= ;; esac
TC=$NDK_ROOT/toolchains/llvm/prebuilt/$HOST/bin
MAKE=$NDK_ROOT/prebuilt/$HOST/bin/make$EXE
[ -x "$MAKE" ] || MAKE=make
WORK=${TMPDIR:-/tmp}/jj_rsync_android
rm -rf "$WORK" && mkdir -p "$WORK" && cd "$WORK"
curl -sSLf -o rsync.tar.gz "https://download.samba.org/pub/rsync/src/rsync-$VER.tar.gz"
echo "$SHA  rsync.tar.gz" | sha256sum -c -
tar xzf rsync.tar.gz 2>/dev/null || true   # md2man 심볼릭 링크 오류는 무시 (문서용)
cd "rsync-$VER"
export CC="$TC/clang$EXE --target=aarch64-linux-android24" AR="$TC/llvm-ar$EXE" RANLIB="$TC/llvm-ranlib$EXE"
./configure --host=aarch64-linux-android --disable-openssl --disable-xxhash --disable-zstd --disable-lz4 \
  --disable-md2man --disable-iconv --disable-acl-support --disable-xattr-support \
  --with-included-zlib --with-included-popt --disable-ipv6 > configure.log
"$MAKE" SHELL=/bin/sh rsync > make.log 2>&1
OUT="$APP/third_party/rsync/android/arm64-v8a"
mkdir -p "$OUT"
"$TC/llvm-strip$EXE" -o "$OUT/librsync.so" rsync
ls -l "$OUT/librsync.so"
