#!/usr/bin/env bash
#
# Cross-compile GNU coreutils (git trunk) against an old glibc using the
# OBGGCC toolchain: https://github.com/AmanoTeam/obggcc
#
# Usage: ./build.sh
#
# Environment knobs (defaults):
#   OBGGCC_TARGET=               full target spec, e.g. x86_64-unknown-linux-gnu2.31
#                                (overrides TRIPLET/GLIBC_TARGET; "" = toolchain default)
#   GLIBC_TARGET=2.31            target glibc; "" = toolchain default (2.3)
#   OBGGCC_HOME=                 pre-extracted toolchain root; skips the download
#   WORKDIR=./coreutils-cross    scratch dir for toolchain, sources, build, out/
#   COREUTILS_REPO=https://github.com/coreutils/coreutils.git
#   COREUTILS_BRANCH=master
#   GNULIB_URL=https://github.com/coreutils/gnulib.git   (Savannah is flaky)
#   TOOLCHAIN_URL=https://github.com/AmanoTeam/obggcc/releases/download/gcc-16/x86_64-unknown-linux-gnu.tar.xz
#   TRIPLET=x86_64-unknown-linux-gnu
#   JOBS=$(nproc)                parallel build level
#   ENABLE_NLS=1                 0 = --disable-nls
#   STRIP_BINS=1                 0 = keep unstripped binaries
#   SMOKE_TEST=1                 run a built binary when the host can execute it
#   BOOTSTRAP_FORCE=0            1 = always re-run ./bootstrap
#
# Output: $WORKDIR/out/ — a /usr tree (bin, share/man, ...) installable on any
# $TRIPLET machine with glibc >= $GLIBC_TARGET.

set -euo pipefail

GLIBC_TARGET="${GLIBC_TARGET-2.31}"
TRIPLET="${TRIPLET:-x86_64-unknown-linux-gnu}"
OBGGCC_TARGET="${OBGGCC_TARGET:-}"
TOOLCHAIN_URL="${TOOLCHAIN_URL:-https://github.com/AmanoTeam/obggcc/releases/download/gcc-16/x86_64-unknown-linux-gnu.tar.xz}"

if [ -n "$OBGGCC_TARGET" ]; then
    if [[ "$OBGGCC_TARGET" =~ ^(.*gnu(eabi|eabihf)?)([0-9]+\.[0-9]+)$ ]]; then
        TRIPLET="${BASH_REMATCH[1]}"
        GLIBC_TARGET="${BASH_REMATCH[3]}"
    else
        TRIPLET="$OBGGCC_TARGET"
        GLIBC_TARGET=""
    fi
fi
COREUTILS_REPO="${COREUTILS_REPO:-https://github.com/coreutils/coreutils.git}"
COREUTILS_BRANCH="${COREUTILS_BRANCH:-master}"
GNULIB_URL="${GNULIB_URL:-https://github.com/coreutils/gnulib.git}"
WORKDIR="${WORKDIR:-$PWD/coreutils-cross}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"
ENABLE_NLS="${ENABLE_NLS:-1}"
STRIP_BINS="${STRIP_BINS:-1}"
SMOKE_TEST="${SMOKE_TEST:-1}"
BOOTSTRAP_FORCE="${BOOTSTRAP_FORCE:-0}"

DESTDIR="$WORKDIR/out"

die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing host build dependency: $1"; }

for tool in curl tar xz git make perl autoconf automake autopoint bison m4 cc; do
    need "$tool"
done
if [ "$ENABLE_NLS" = 1 ]; then
    need msgfmt
fi

step "host dependencies ok"
mkdir -p "$WORKDIR"

step "fetching OBGGCC toolchain from ${TOOLCHAIN_URL}"
toolchain_tar="$WORKDIR/$(basename "${TOOLCHAIN_URL%%\?*}")"
toolchain_dir="$WORKDIR/toolchain"
if [ -n "${OBGGCC_HOME:-}" ]; then
    env_script="$OBGGCC_HOME/build/autotools/${TRIPLET}${GLIBC_TARGET}.sh"
    [ -f "$env_script" ] || die "OBGGCC_HOME has no target script for ${TRIPLET}${GLIBC_TARGET}; see ${OBGGCC_HOME}/build/autotools/"
    echo "    using pre-provisioned toolchain at ${OBGGCC_HOME}"
else
    toolchain_home="$toolchain_dir/obggcc"
    env_script="$toolchain_home/build/autotools/${TRIPLET}${GLIBC_TARGET}.sh"
    if [ ! -f "$env_script" ]; then
        if [ ! -f "$toolchain_tar" ]; then
            curl --fail --location --retry 3 --progress-bar \
                -o "$toolchain_tar.part" "$TOOLCHAIN_URL"
            mv "$toolchain_tar.part" "$toolchain_tar"
        fi
        rm -rf "$toolchain_dir"
        mkdir -p "$toolchain_dir"
        tar --extract --xz --file="$toolchain_tar" --directory="$toolchain_dir"
        [ -f "$env_script" ] || die "toolchain has no target for glibc ${GLIBC_TARGET:-<default>}; see ${toolchain_home}/build/autotools/"
    else
        echo "    toolchain already present, skipping download"
    fi
    OBGGCC_HOME="$(cd "$toolchain_home" && pwd)"
    export OBGGCC_HOME
fi

step "fetching coreutils trunk (${COREUTILS_BRANCH} from ${COREUTILS_REPO})"
src="$WORKDIR/coreutils"
if [ ! -d "$src/.git" ]; then
    git clone --branch "$COREUTILS_BRANCH" "$COREUTILS_REPO" "$src"
fi
git -C "$src" fetch origin "$COREUTILS_BRANCH"
git -C "$src" checkout --detach FETCH_HEAD >/dev/null
if [ -f "$src/.gitmodules" ]; then
    git -C "$src" config submodule.gnulib.url "$GNULIB_URL" || true
fi
rev_info="$(git -C "$src" log -1 --format='%h (%cd)' --date=short)"
echo "    coreutils $rev_info"

step "bootstrapping coreutils (gnulib + autoreconf)"
if [ ! -x "$src/configure" ] || [ "$BOOTSTRAP_FORCE" = 1 ]; then
    (
        unset CC CXX CPP AR AS LD NM RANLIB STRIP OBJCOPY OBJDUMP READELF PKG_CONFIG YASM \
              CFLAGS CXXFLAGS LDFLAGS || true
        cd "$src"
        ./bootstrap
    )
else
    echo "    configure already generated, skipping (set BOOTSTRAP_FORCE=1 to redo)"
fi

step "activating OBGGCC cross environment"
# shellcheck source=/dev/null disable=SC1090
source "$OBGGCC_HOME/build/autotools/${TRIPLET}${GLIBC_TARGET}.sh"
PATH="$OBGGCC_HOME/bin:$PATH"
export PATH
echo "    CC=${CC}"
echo "    target glibc=${CROSS_COMPILE_GLIBCVER}"

step "configuring coreutils"
host_triplet="$("$src/build-aux/config.guess")"
build_dir="$WORKDIR/build${GLIBC_TARGET:+-$GLIBC_TARGET}"
mkdir -p "$build_dir"
cd "$build_dir"
conf_opts=(
    --host="$CROSS_COMPILE_TRIPLET"
    --build="$host_triplet"
    --prefix=/usr
    --disable-gcc-warnings
)
case "$TRIPLET" in
    i[3-6]86-*|arm-*)
        # 32-bit glibc gained 64-bit time_t in 2.34; older sysroots cannot enable year2038.
        if [ -z "$GLIBC_TARGET" ] || [ -n "$(printf '%s\n' "${GLIBC_TARGET:-2.3}" | awk '$1 < 2.34')" ]; then
            conf_opts+=("--disable-year2038")
        fi
        ;;
esac
if [ "$ENABLE_NLS" != 1 ]; then
    conf_opts+=("--disable-nls")
fi
"$src/configure" "${conf_opts[@]}"

step "building coreutils"
make -j "$JOBS"

step "installing to ${DESTDIR}"
rm -rf "$DESTDIR"
make DESTDIR="$DESTDIR" install

if [ "$STRIP_BINS" = 1 ]; then
    step "stripping ELF files"
    while IFS= read -r -d '' bin; do
        if [ "$(head -c 4 "$bin")" = "$(printf '\x7fELF')" ]; then
            "$STRIP" --strip-unneeded "$bin" 2>/dev/null || true
        fi
    done < <(find "$DESTDIR" -type f -print0)
fi

if [ "$SMOKE_TEST" = 1 ]; then
    step "smoke test"
    if "$DESTDIR/usr/bin/ls" --version >/dev/null 2>&1; then
        "$DESTDIR/usr/bin/ls" --version | head -n 1
        "$DESTDIR/usr/bin/cat" <<< "smoke test: $(uname -m) host ran the cross-built binary"
    else
        echo "    cannot execute ${TRIPLET} binaries on this $(uname -m) host; skipped"
    fi
fi

step "summary"
version="$(sed -n 's/^#define PACKAGE_VERSION "\(.*\)"/\1/p' "$build_dir/lib/config.h")"
glibc_needed="$(
    find "$DESTDIR/usr/bin" -type f -print0 |
    xargs -0 --no-run-if-empty "$READELF" --version-info 2>/dev/null |
    grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -n 1
)"
bin_count="$(find "$DESTDIR/usr/bin" -type f | wc -l)"
echo "    coreutils version: ${version} ${rev_info}"
echo "    binaries installed: ${bin_count} -> ${DESTDIR}/usr/bin"
echo "    target triplet:     ${CROSS_COMPILE_TRIPLET} (glibc ${CROSS_COMPILE_GLIBCVER})"
echo "    highest glibc symbol required: ${glibc_needed:-none}"
echo "    deploy: tar -C '$DESTDIR' -cf - usr | tar -C / -xf -"
