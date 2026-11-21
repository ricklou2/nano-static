#!/bin/bash
# 交叉编译 nano 8.7 + ncurses 6.4
# 目标：Linux(musl, zig) 4 架构 + Android(NDK r28c, API24) 4 架构 = 8 个静态单文件
set -u

ROOT=${ROOT:-/tmp/eight}
S=$ROOT/s
W=$ROOT/w
OUT=$ROOT/out
ZIG=${ZIG:-/tmp/zigpkg/ziglang/zig}
NB=${NB:-/home/user/android-sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin}
STRIP=$NB/llvm-strip
ONLY=${ONLY:-}
API=24

mkdir -p "$OUT" "$W"

# name  kind  triplet                     clangprefix              align
TARGETS="
linux_x64,linux,x86_64-linux-musl,,16384
linux_x86,linux,x86-linux-musl,,16384
linux_arm64,linux,aarch64-linux-musl,,16384
linux_armhf,linux,arm-linux-musleabihf,,16384
android_x64,android,x86_64-linux-android24,x86_64-linux-android,16384
android_x86,android,i686-linux-android24,i686-linux-android,16384
android_arm64,android,aarch64-linux-android24,aarch64-linux-android,16384
android_arm,android,armv7a-linux-androideabi24,armv7a-linux-androideabi,16384
"

fail() { echo "!! $*"; exit 1; }

build_one() {
  local name=$1 kind=$2 trip=$3 prefix=$4 align=$5
  local bd=$W/$name

  if [ "$kind" = linux ]; then
    export CC="$ZIG cc -target $trip" AR="$ZIG ar" RANLIB="$ZIG ranlib"
    local CLINK="$ZIG cc -target $trip"
  else
    export CC="$NB/$prefix$API-clang" AR="$NB/llvm-ar" RANLIB="$NB/llvm-ranlib"
    local CLINK="$NB/$prefix$API-clang"
  fi

  local PAGE="-Wl,-z,max-page-size=$align"

  echo "==> [$name] ncurses"
  rm -rf "$bd/ncurses" && mkdir -p "$bd/ncurses" || fail "$name ncurses mkdir"
  ( cd "$bd/ncurses" && "$S/ncurses-6.4/configure" \
      --build=x86_64-pc-linux-gnu --host="$trip" --with-build-cc=gcc \
      --prefix="$bd/dep-nc" --without-shared --with-normal --enable-widec \
      --without-ada --without-manpages --without-tests --without-debug --disable-stripping \
      --without-cxx --without-cxx-binding --with-termlib \
      --with-fallbacks="xterm-256color,xterm,linux,screen-256color,screen,vt100,ansi" \
      > cfg.log 2>&1 && make -j8 > mk.log 2>&1 ) \
    || { tail -25 "$bd/ncurses/cfg.log" "$bd/ncurses/mk.log" 2>/dev/null; fail "[$name] ncurses"; }
  [ -f "$bd/ncurses/lib/libncursesw.a" ] || fail "[$name] libncursesw.a 未生成"

  echo "==> [$name] nano"
  rm -rf "$bd/nano" && mkdir -p "$bd/nano" || fail "$name nano mkdir"
  # Android: bionic 的 pwd.h 在 API24 视图下不导出 getpwent 系列（libc 里其实有符号）
  local NCFLAGS="-g -O2 -Wall"
  [ "$kind" = android ] && NCFLAGS="$NCFLAGS -include $ROOT/compat/pwent_decl.h"
  ( cd "$bd/nano" && CPPFLAGS="-I$bd/ncurses/include -I$bd/ncurses/include/ncursesw" \
      LDFLAGS="-L$bd/ncurses/lib" LIBS="-lncursesw -ltinfow" \
      "$S/nano-8.7/configure" --host="$trip" --build=x86_64-pc-linux-gnu \
      --disable-nls --disable-rpath --disable-libmagic > cfg.log 2>&1 \
      && make -j8 CFLAGS="$NCFLAGS" LDFLAGS="-L$bd/ncurses/lib -static $PAGE" > mk.log 2>&1 ) \
    || { tail -25 "$bd/nano/mk.log" 2>/dev/null; fail "[$name] nano"; }
  [ -x "$bd/nano/src/nano" ] || fail "[$name] nano 未生成"
  "$STRIP" --strip-all "$bd/nano/src/nano" || fail "[$name] strip nano"
  cp "$bd/nano/src/nano" "$OUT/nano-${name//_/-}"
}

while IFS=, read -r name kind trip prefix align; do
  [ -z "$name" ] && continue
  if [ -n "$ONLY" ] && [ "$ONLY" != "$name" ]; then continue; fi
  build_one "$name" "$kind" "$trip" "$prefix" "$align"
done <<< "$TARGETS"

echo
echo "==== 产物 ===="
ls -l "$OUT"
for f in "$OUT"/*; do
  printf '%-28s %8s  %s\n' "$(basename "$f")" "$(stat -c%s "$f")" "$("$NB/llvm-readelf" -h "$f" 2>/dev/null | grep -c 'EXEC\|DYN' >/dev/null; file -b "$f" | cut -c1-60)"
done
