# coreutils-portable

Portable [GNU coreutils](https://www.gnu.org/software/coreutils/) builds:
[coreutils master](https://git.savannah.gnu.org/git/coreutils.git) cross-compiled
against specific old glibc versions with the
[OBGGCC](https://github.com/AmanoTeam/obggcc) toolchain, so the resulting
binaries run out of the box on virtually any Linux distribution.

The build logic of this repository is modeled after
[AmanoTeam/Kad](https://github.com/AmanoTeam/Kad).

## Installation

You can obtain precompiled binaries from the [releases](https://github.com/Kartatz/coreutils-portable/releases)
page. Each tarball contains an uncompressed `usr/` tree that may be extracted
anywhere, e.g.:

```
$ tar --extract --file='x86_64-unknown-linux-gnu2.31.tar.xz'
$ ./usr/bin/ls --version
```

Choose the tarball matching your architecture whose glibc version is less than
or equal to the one reported by `ldd --version` on the target machine
(e.g. the `2.3` tarballs run on every x86_64 Linux released since 2007).

## Building

Clone this repository and run [`build.sh`](build.sh):

```
$ ./build.sh
```

By default, coreutils master is cross-compiled for `x86_64-unknown-linux-gnu`
against glibc 2.31, producing a self-contained `usr/` tree under
`coreutils-cross/out/`. All knobs are environment variables (see the header of
[build.sh](build.sh) for the full list), e.g.:

```
$ OBGGCC_TARGET='x86_64-unknown-linux-gnu2.17' ./build.sh
```

## Continuous integration

The [GitHub Actions workflow](.github/workflows/build.yml) cross-compiles a
matrix of targets on every push and daily on schedule (to track coreutils
master), reusing the build logic of
[AmanoTeam/Kad](https://github.com/AmanoTeam/Kad) with its toolchain family:

* **macOS**: `aarch64-unknown-apple-darwin`, `x86_64-unknown-apple-darwin` ([darwin-clang-cross](https://github.com/AmanoTeam/darwin-clang-cross))
* **Linux (glibc)**: `x86_64`, `i386`, `arm`, `aarch64` with selectable baseline glibc ([OBGGCC](https://github.com/AmanoTeam/obggcc))
* **Linux (musl)**: `aarch64`, `x86_64`, `armv6`, `armv7`, `i386` ([musl-gcc-cross](https://github.com/AmanoTeam/musl-gcc-cross))
* **FreeBSD**: `x86_64`, `aarch64`, `i386` ([freebsd-gcc-cross](https://github.com/AmanoTeam/freebsd-gcc-cross))
* **NetBSD**: `i386`, `x86_64` ([netbsd-gcc-cross](https://github.com/AmanoTeam/netbsd-gcc-cross))
* **DragonFly BSD**: `x86_64` ([dragonfly-gcc-cross](https://github.com/AmanoTeam/dragonfly-gcc-cross))
* **Android**: `x86_64`, `i686`, `aarch64`, `armv7` ([android-gcc-cross](https://github.com/AmanoTeam/android-gcc-cross))

The resulting tarballs and their SHA-256 checksums are uploaded to a rolling
release. Native Windows (`*-w64-mingw32`) is not in the matrix because
coreutils requires a POSIX system (`pwd.h` etc. are absent on native Windows);
use Cygwin there instead. Targets proven unbuildable by a given coreutils
revision are excluded from the matrix as evidence accumulates in the build
history — a MinGW attempt failed at `lib/userspec.c` (missing `pwd.h`).
