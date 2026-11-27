#!/bin/bash
# Builds a self-contained x86_64 QEMU (system emulator for x86_64 only, HVF + vmnet) for an Intel Mac whose macOS is
# too old for Homebrew to install bottles (the 2018 MacBook Pro). No sudo, no Homebrew: every dependency is built
# from source into one private prefix and linked statically, so the binary needs nothing outside macOS itself.
# Run as your normal user on the Mac: ./build-qemu-macos-x86.sh   (about 40 minutes on 12 threads).
# Result: $PREFIX/bin/qemu-system-x86_64 and qemu-img, with the firmware in $PREFIX/share/qemu.
#
# Needs Xcode's command-line toolchain and /usr/bin/python3 (3.9 is fine). The meson, ninja and pkgconf build tools
# come from PyPI into ~/Library/Python. Sources are pinned to the versions and sha256 sums Homebrew publishes, so a
# swapped tarball fails the build. See ../../docs/mbp-worker-qemu.md.
#
# Env overrides: PREFIX (default ~/.local/qemu), BUILD (default ~/qemu-build), JOBS.
set -euo pipefail
PREFIX="${PREFIX:-$HOME/.local/qemu}"
B="${BUILD:-$HOME/qemu-build}"
JOBS="${JOBS:-6}"
mkdir -p "$B/src" "$PREFIX"
cd "$B/src"

fetch() { # url sha256
  local f; f=$(basename "$1")
  [ -f "$f" ] || curl -fsSL -o "$f" "$1"
  echo "$2  $f" | shasum -a 256 -c - >/dev/null || { echo "CHECKSUM MISMATCH $f" >&2; exit 1; }
  echo "ok $f"
}
fetch https://download.qemu.org/qemu-11.1.3.tar.xz 5a8289c7940dc77d3873c81a6c29ba3afe1446fc9d36e77fa1658cdbecb84b22
fetch https://download.gnome.org/sources/glib/2.90/glib-2.90.2.tar.xz edf473b4f5ee70a31d2410622ee605dc4a2c8c46dbc0ec53c9abbaf3960232fd
fetch https://cairographics.org/releases/pixman-0.46.4.tar.gz d09c44ebc3bd5bee7021c79f922fe8fb2fb57f7320f55e97ff9914d2346a591c
fetch https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.49/pcre2-10.49.tar.bz2 53c156e1ba416a20da8e65395daa132da0d80e76910424caca3fcdae7831d384
fetch https://github.com/libffi/libffi/releases/download/v3.8.2/libffi-3.8.2.tar.gz a699fda2b090c4b46cb79cf60c4dacfce480eb05742c0de66acf3af174a47f92
fetch https://ftpmirror.gnu.org/gettext/gettext-1.0.tar.gz 85d99b79c981a404874c02e0342176cf75c7698e2b51fe41031cf6526d974f1a
fetch https://github.com/meta/zstd/archive/refs/tags/v1.6.0.tar.gz 289bb207935e5b4f241239f9832e665fa6b9636c3f87f479e125371e13842b8e

python3 -m pip install --user --quiet --upgrade meson ninja packaging tomli pkgconf 2>&1 | tail -2 || true
PYBIN="$(python3 -c 'import site;print(site.USER_BASE)')/bin"
command -v "$PYBIN/pkg-config" >/dev/null || ln -sf "$PYBIN/pkgconf" "$PYBIN/pkg-config"
# Deliberately no /usr/local/bin: Homebrew's libraries must not be found. The linker also searches /usr/local/lib by
# default, so our prefix goes first (and everything we need is static in it).
export PATH="$PREFIX/bin:$PYBIN:/usr/bin:/bin:/usr/sbin:/sbin"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
export CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib" LIBRARY_PATH="$PREFIX/lib"
export MACOSX_DEPLOYMENT_TARGET=15.0
nice="nice -n 10"
unpack() { rm -rf "${B:?}/$1"; mkdir -p "$B/$1"; tar -xf "$B/src/$2" -C "$B/$1" --strip-components=1; }

[ -f "$PREFIX/lib/libffi.a" ] || { echo "== libffi"; unpack libffi libffi-3.8.2.tar.gz
  (cd "$B/libffi" && ./configure --prefix="$PREFIX" --disable-shared --enable-static >/dev/null && $nice make -j"$JOBS" >/dev/null 2>&1 && make install >/dev/null 2>&1); }
[ -f "$PREFIX/lib/libpcre2-8.a" ] || { echo "== pcre2"; unpack pcre2 pcre2-10.49.tar.bz2
  (cd "$B/pcre2" && ./configure --prefix="$PREFIX" --disable-shared --enable-static >/dev/null && $nice make -j"$JOBS" >/dev/null 2>&1 && make install >/dev/null 2>&1); }
[ -f "$PREFIX/lib/libpixman-1.a" ] || { echo "== pixman"; unpack pixman pixman-0.46.4.tar.gz
  (cd "$B/pixman" && meson setup build --prefix="$PREFIX" --default-library=static -Dtests=disabled -Ddemos=disabled >/dev/null && $nice ninja -C build >/dev/null && ninja -C build install >/dev/null); }
[ -f "$PREFIX/lib/libintl.a" ] || { echo "== gettext (runtime)"; unpack gettext gettext-1.0.tar.gz
  (cd "$B/gettext/gettext-runtime" && ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-java --disable-csharp --without-emacs --disable-curses >/dev/null && $nice make -j"$JOBS" >/dev/null 2>&1 && make install >/dev/null 2>&1); }
[ -f "$PREFIX/lib/libzstd.a" ] || { echo "== zstd"; unpack zstd v1.6.0.tar.gz
  (cd "$B/zstd" && $nice make -j"$JOBS" -C lib libzstd.a >/dev/null 2>&1 && make -C lib install-static install-includes install-pc PREFIX="$PREFIX" >/dev/null 2>&1); }
[ -f "$PREFIX/lib/libglib-2.0.a" ] || { echo "== glib"; unpack glib glib-2.90.2.tar.xz
  (cd "$B/glib" && meson setup build --prefix="$PREFIX" --default-library=static -Dtests=false -Dintrospection=disabled -Dnls=disabled -Dlibmount=disabled -Dglib_debug=disabled >/dev/null 2>&1 && $nice ninja -C build >/dev/null && ninja -C build install >/dev/null); }

echo "== qemu"
unpack qemu qemu-11.1.3.tar.xz
mkdir -p "$B/qemu/build" && cd "$B/qemu/build"
../configure --prefix="$PREFIX" --target-list=x86_64-softmmu --enable-hvf --enable-vmnet --enable-zstd \
  --disable-docs --disable-guest-agent --disable-gnutls --disable-slirp --disable-curses \
  --disable-sdl --disable-cocoa --disable-gtk --disable-vnc --disable-libssh --disable-usb-redir --disable-libusb \
  --disable-gcrypt --disable-nettle --disable-capstone --disable-vde --disable-opengl --disable-rust >/dev/null
$nice make -j"$JOBS" >/dev/null 2>&1
make install >/dev/null 2>&1
"$PREFIX/bin/qemu-system-x86_64" --version | head -1
leaks=$(otool -L "$PREFIX/bin/qemu-system-x86_64" "$PREFIX/bin/qemu-img" | grep -c /usr/local || true)
[ "$leaks" -eq 0 ] || { echo "BUILD INCOMPLETE: $leaks libraries linked from /usr/local" >&2; exit 1; }
echo "Built into $PREFIX (no Homebrew libraries linked)."
