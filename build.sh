#!/usr/bin/env bash
#
# Cross-compile GNU coreutils (git trunk) for an old baseline system using the
# AmanoTeam cross toolchains (https://github.com/AmanoTeam): OBGGCC (old glibc),
# musl-gcc-cross, freebsd-gcc-cross, netbsd-gcc-cross, dragonfly-gcc-cross,
# mingw-gcc-cross, darwin-clang-cross, android-gcc-cross.
#
# Usage: ./build.sh
#
# The cross environment is taken from the caller when already provisioned
# (i.e. the 'build/autotools/<triplet>.sh' script of any of the toolchains
# above was sourced, like the CI workflow does). Otherwise OBGGCC is fetched
# and provisioned automatically (standalone mode for local use).
#
# Environment knobs (defaults):
#   TRIPLET=x86_64-unknown-linux-gnu   OBGGCC target triplet (standalone mode;
#                                targets the toolchain default, i.e. oldest glibc)
#   OBGGCC_HOME=                 pre-extracted OBGGCC root; skips the download
#   TOOLCHAIN_URL=https://github.com/AmanoTeam/obggcc/releases/download/gcc-16/x86_64-unknown-linux-gnu.tar.xz
#   WORKDIR=./coreutils-cross    scratch dir for toolchain, sources, build, out/
#   COREUTILS_REPO=https://github.com/coreutils/coreutils.git
#   COREUTILS_BRANCH=master
#   GNULIB_URL=https://github.com/coreutils/gnulib.git   (Savannah is flaky)
#   JOBS=$(nproc)                parallel build level
#   ENABLE_NLS=auto              1/0 to force; auto enables it only for glibc targets
#   STRIP_BINS=1                 0 = keep unstripped binaries
#   SMOKE_TEST=1                 run a built binary when the host can execute it
#   BOOTSTRAP_FORCE=0            1 = always re-run ./bootstrap
#
# Output: $WORKDIR/out/ — an installable 'usr/' tree for the target system.

set -euo pipefail

if [ -n "${CROSS_COMPILE_TRIPLET:-}" ] && [ -n "${CC:-}" ]; then
    provisioned='yes'
else
    provisioned='no'
    TRIPLET="${TRIPLET:-x86_64-unknown-linux-gnu}"
    TOOLCHAIN_URL="${TOOLCHAIN_URL:-https://github.com/AmanoTeam/obggcc/releases/download/gcc-16/x86_64-unknown-linux-gnu.tar.xz}"
fi

COREUTILS_REPO="${COREUTILS_REPO:-https://github.com/coreutils/coreutils.git}"
COREUTILS_BRANCH="${COREUTILS_BRANCH:-master}"
GNULIB_URL="${GNULIB_URL:-https://github.com/coreutils/gnulib.git}"
WORKDIR="${WORKDIR:-$PWD/coreutils-cross}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"
ENABLE_NLS="${ENABLE_NLS:-auto}"
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

step "host dependencies ok"
mkdir -p "$WORKDIR"

step "activating cross environment"
if [ "$provisioned" = yes ]; then
    echo "    using environment-provisioned toolchain (${CROSS_COMPILE_ARCHITECTURE:-?}-${CROSS_COMPILE_SYSTEM:-?})"
else
    toolchain_tar="$WORKDIR/$(basename "${TOOLCHAIN_URL%%\?*}")"
    toolchain_dir="$WORKDIR/toolchain"
    if [ -n "${OBGGCC_HOME:-}" ]; then
        env_script="$OBGGCC_HOME/build/autotools/${TRIPLET}.sh"
        [ -f "$env_script" ] || die "OBGGCC_HOME has no target script for ${TRIPLET}; see ${OBGGCC_HOME}/build/autotools/"
        echo "    using pre-provisioned OBGGCC toolchain at ${OBGGCC_HOME}"
    else
        toolchain_home="$toolchain_dir/obggcc"
        env_script="$toolchain_home/build/autotools/${TRIPLET}.sh"
        if [ ! -f "$env_script" ]; then
            if [ ! -f "$toolchain_tar" ]; then
                curl --fail --location --retry 3 --progress-bar \
                    -o "$toolchain_tar.part" "$TOOLCHAIN_URL"
                mv "$toolchain_tar.part" "$toolchain_tar"
            fi
            rm -rf "$toolchain_dir"
            mkdir -p "$toolchain_dir"
            tar --extract --xz --file="$toolchain_tar" --directory="$toolchain_dir"
            [ -f "$env_script" ] || die "toolchain has no target script for ${TRIPLET}; see ${toolchain_home}/build/autotools/"
        fi
        OBGGCC_HOME="$(cd "$toolchain_home" && pwd)"
        export OBGGCC_HOME
        PATH="$OBGGCC_HOME/bin:$PATH"
        export PATH
    fi
    # shellcheck source=/dev/null disable=SC1090
    source "$OBGGCC_HOME/build/autotools/${TRIPLET}.sh"
fi
echo "    CC=${CC}"
echo "    target triplet=${CROSS_COMPILE_TRIPLET}"
if [ -n "${CROSS_COMPILE_GLIBCVER:-}" ]; then
    echo "    target glibc=${CROSS_COMPILE_GLIBCVER}"
fi

if [ "$ENABLE_NLS" = auto ]; then
    case "${CROSS_COMPILE_TRIPLET}${CROSS_COMPILE_GLIBCVER:-}" in
        *-linux-gnu*) ENABLE_NLS=1 ;;
        *) ENABLE_NLS=0 ;;
    esac
fi
if [ "$ENABLE_NLS" = 1 ]; then
    need msgfmt
    echo "    nls: enabled"
else
    echo "    nls: disabled"
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

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for p in "$script_dir"/patches/*.patch; do
    [ -f "$p" ] || continue
    step "applying $(basename "$p")"
    patch --forward --quiet --batch --strip=1 --directory="$src/gnulib" --input="$p" ||
        grep -q '__builtin_bswap16 (x)' "$src/gnulib/lib/byteswap.in.h" ||
        die "failed to apply $p"
done

step "configuring coreutils"
host_triplet="$("$src/build-aux/config.guess")"
build_dir="$WORKDIR/build/${CROSS_COMPILE_TRIPLET}${CROSS_COMPILE_GLIBCVER:-}"
mkdir -p "$build_dir"
cd "$build_dir"
conf_opts=(
    --host="$CROSS_COMPILE_TRIPLET"
    --build="$host_triplet"
    --prefix=/usr
    --disable-gcc-warnings
)
case "$CROSS_COMPILE_TRIPLET" in
    i[3-6]86-*-linux-gnu*|arm-*-linux-gnueabi*)
        # 32-bit glibc gained 64-bit time_t in 2.34; older sysroots cannot enable year2038.
        glibc_ref="${CROSS_COMPILE_GLIBCVER:-2.3}"
        if [ -n "$(printf '%s\n' "$glibc_ref" | awk '$1 < 2.34')" ]; then
            conf_opts+=("--disable-year2038")
        fi
        ;;
    i[3-6]86-unknown-linux-android*|armv7-unknown-linux-androideabi*)
        # 32-bit bionic cannot prove 64-bit time_t under cross-compilation.
        conf_opts+=("--disable-year2038")
        ;;
    i[3-6]86-*-freebsd*)
        # 32-bit FreeBSD cannot prove year2038 support under cross-compilation.
        conf_opts+=("--disable-year2038")
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
    step "stripping binaries"
    while IFS= read -r -d '' bin; do
        magic="$(head -c 4 "$bin")"
        if [ "$magic" = "$(printf '\x7fELF')" ] || [ "$magic" = "$(printf 'MZ')" ]; then
            "${STRIP:-strip}" --strip-unneeded "$bin" 2>/dev/null || true
        fi
    done < <(find "$DESTDIR" -type f -print0)
fi

if [ "$SMOKE_TEST" = 1 ]; then
    step "smoke test"
    if "$DESTDIR/usr/bin/ls" --version >/dev/null 2>&1; then
        "$DESTDIR/usr/bin/ls" --version | head -n 1
        "$DESTDIR/usr/bin/cat" <<< "smoke test: $(uname -m) host ran the cross-built binary"
    else
        echo "    cannot execute ${CROSS_COMPILE_TRIPLET} binaries on this $(uname -m) host; skipped"
    fi
fi

step "summary"
version="$(sed -n 's/^#define PACKAGE_VERSION "\(.*\)"/\1/p' "$build_dir/lib/config.h")"
bin_count="$(find "$DESTDIR/usr/bin" -maxdepth 1 -type f | wc -l)"
echo "    coreutils version: ${version} ${rev_info}"
echo "    binaries installed: ${bin_count} -> ${DESTDIR}/usr/bin"
if [ -n "${CROSS_COMPILE_GLIBCVER:-}" ]; then
    glibc_needed="$(
        find "$DESTDIR/usr/bin" -maxdepth 1 -type f -print0 |
        xargs -0 --no-run-if-empty "${READELF:-readelf}" --version-info 2>/dev/null |
        grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -n 1
    )"
    echo "    target glibc:        ${CROSS_COMPILE_GLIBCVER} (highest symbol required: ${glibc_needed:-none})"
fi
echo "    target system:        ${CROSS_COMPILE_ARCHITECTURE:-?}-${CROSS_COMPILE_SYSTEM:-?}"
echo "    deploy: tar -C '$DESTDIR' -cf - usr | tar -C / -xf -"
