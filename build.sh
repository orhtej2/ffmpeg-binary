#!/bin/bash
set -e

# FFmpeg Fully Static Self-Contained Build Script (GPL variant)
# Builds ffmpeg + ffprobe with ALL dependencies statically linked into single binaries
# No .so files, no external dependencies
# Usage: ./build.sh [TAG] [ARCH]
# Examples:
#   ./build.sh n7.1.5 amd64      # Build specific FFmpeg tag for amd64
#   ./build.sh n7.1.5 arm64      # Build specific FFmpeg tag for arm64
#   ./build.sh n7.1.5 armv7      # Build specific FFmpeg tag for armv7/armhf
#   ./build.sh                    # Build latest stable release for current architecture

FFMPEG_REPO="https://github.com/FFmpeg/FFmpeg.git"
RELEASE_TAG="${1:-latest}"
TARGET_ARCH="${2:-$(uname -m)}"
WORK_DIR="${PWD}/build-work"
BUILD_DIR="${PWD}/build"
PREFIX="${WORK_DIR}/install"
LOCK_FILE="${PWD}/dependencies.lock"
HOST_MULTIARCH="$(gcc -dumpmachine 2>/dev/null || true)"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
MESON_BIN="meson"
MESON_CROSS_FILE=""
PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig:$PREFIX/share/pkgconfig"

if [ -n "$HOST_MULTIARCH" ]; then
    PKG_CONFIG_PATH="$PKG_CONFIG_PATH:$PREFIX/lib/$HOST_MULTIARCH/pkgconfig"
fi

# Keep pkg-config isolated from host metadata so ffmpeg only enables
# components that this script actually built into the local prefix.
PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"

export PKG_CONFIG_PATH="${PKG_CONFIG_PATH}"
export PKG_CONFIG_LIBDIR="${PKG_CONFIG_LIBDIR}"
export PKG_CONFIG_DIR=""
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="-L$PREFIX/lib -L$PREFIX/lib64${HOST_MULTIARCH:+ -L$PREFIX/lib/$HOST_MULTIARCH}"
export LD_LIBRARY_PATH="$PREFIX/lib${HOST_MULTIARCH:+:$PREFIX/lib/$HOST_MULTIARCH}:$LD_LIBRARY_PATH"

# Additional compiler flags for full static linking
export CFLAGS="-O2"
export CXXFLAGS="-O2"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

compiler_supports_flag() {
    local flag="$1"
    local cc_bin="${CC:-gcc}"

    printf 'int main(void){return 0;}\n' | "$cc_bin" "$flag" -x c -c -o /dev/null - >/dev/null 2>&1
}

compiler_supports_armv7_fpu_flags() {
    local cc_bin="${CC:-gcc}"

    printf 'int main(void){return 0;}\n' | "$cc_bin" -march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=hard -x c -c -o /dev/null - >/dev/null 2>&1
}

autotools_host_flags() {
    if [ -n "${TARGET_TRIPLET:-}" ]; then
        printf '%s' "--host=${TARGET_TRIPLET}"
    fi
}

write_meson_cross_file() {
    local cross_file="$WORK_DIR/meson-armv7-cross.txt"
    mkdir -p "$WORK_DIR"
    cat > "$cross_file" <<EOF
[binaries]
c = '${CC:-arm-linux-gnueabihf-gcc}'
cpp = '${CXX:-arm-linux-gnueabihf-g++}'
ar = '${AR:-arm-linux-gnueabihf-ar}'
strip = '${STRIP:-arm-linux-gnueabihf-strip}'
pkgconfig = 'pkg-config'
exe_wrapper = ['qemu-arm-static', '-L', '/usr/arm-linux-gnueabihf']

[host_machine]
system = 'linux'
cpu_family = 'arm'
cpu = 'armv7'
endian = 'little'

[properties]
needs_exe_wrapper = true
EOF
    MESON_CROSS_FILE="$cross_file"
    export MESON_CROSS_FILE
    printf '%s' "$cross_file"
}

load_dependency_lock() {
    if [ ! -f "$LOCK_FILE" ]; then
        log_error "Dependency lock file not found: $LOCK_FILE"
        exit 1
    fi

    # shellcheck source=/dev/null
    source "$LOCK_FILE"

    local required_vars=(
        ZLIB_REPO ZLIB_TAG
        LIBOGG_REPO LIBOGG_TAG
        LIBVORBIS_REPO LIBVORBIS_TAG
        OPUS_REPO OPUS_TAG
        LAME_REPO LAME_TAG
        LIBVPX_REPO LIBVPX_TAG
        LIBAOM_REPO LIBAOM_TAG
        DAV1D_REPO DAV1D_TAG
        X264_REPO X264_REF
        X265_REPO X265_TAG
        EXPAT_REPO EXPAT_TAG
        FREETYPE_REPO FREETYPE_TAG
        HARFBUZZ_REPO HARFBUZZ_TAG
        FRIBIDI_REPO FRIBIDI_TAG
        FONTCONFIG_REPO FONTCONFIG_TAG
        LIBASS_REPO LIBASS_TAG
    )

    local missing=0
    for var_name in "${required_vars[@]}"; do
        if [ -z "${!var_name}" ]; then
            log_error "Missing '$var_name' in dependency lock file"
            missing=1
        fi
    done
    if [ "$missing" -ne 0 ]; then
        exit 1
    fi
}

checkout_repo_tag() {
    local repo_dir="$1"
    local repo_url="$2"
    local repo_tag="$3"

    if [ -d "$repo_dir/.git" ]; then
        log_info "Updating $repo_dir to tag $repo_tag"
        git -C "$repo_dir" remote set-url origin "$repo_url"
        git -C "$repo_dir" fetch --depth 1 origin "refs/tags/$repo_tag:refs/tags/$repo_tag" || \
            git -C "$repo_dir" fetch --depth 1 origin "$repo_tag"
        git -C "$repo_dir" checkout -f "$repo_tag"
        git -C "$repo_dir" reset --hard "$repo_tag"
        git -C "$repo_dir" clean -fdx
    else
        rm -rf "$repo_dir"
        log_info "Cloning $repo_dir at tag $repo_tag"
        git clone --depth 1 --branch "$repo_tag" "$repo_url" "$repo_dir"
    fi

    git -C "$repo_dir" checkout -f "$repo_tag"
}

checkout_repo_ref() {
    local repo_dir="$1"
    local repo_url="$2"
    local repo_ref="$3"

    rm -rf "$repo_dir"
    mkdir -p "$repo_dir"

    git -C "$repo_dir" init >/dev/null
    git -C "$repo_dir" remote add origin "$repo_url"
    git -C "$repo_dir" fetch --depth 1 origin "$repo_ref"
    git -C "$repo_dir" checkout -f FETCH_HEAD
    git -C "$repo_dir" clean -fdx
}

# Function to install build dependencies
install_dependencies() {
    if [ "${SKIP_APT_INSTALL:-false}" = "true" ]; then
        log_warn "Skipping apt dependency installation (SKIP_APT_INSTALL=true)"
        return 0
    fi

    log_info "Installing build dependencies..."

    if ! command -v apt-get &> /dev/null; then
        log_error "apt-get not found. This script is designed for Debian/Ubuntu systems."
        exit 1
    fi

    sudo apt-get update
    sudo apt-get install -y \
        build-essential \
        pkgconf \
        git \
        curl \
        wget \
        autoconf \
        automake \
        libtool \
        cmake \
        nasm \
        yasm \
        perl \
        python3 \
        python3-pip \
        python3-venv \
        ninja-build \
        meson \
        texinfo \
        gperf \
        gettext \
        autopoint

    log_info "Build dependencies installed successfully"
}

build_zlib() {
    log_info "Building zlib (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "zlib" "$ZLIB_REPO" "$ZLIB_TAG"

    cd zlib
    CFLAGS="$CFLAGS -Wno-error" ./configure --static --prefix="$PREFIX" $(autotools_host_flags)
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
    cd ..
}

build_ogg() {
    log_info "Building libogg (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "ogg" "$LIBOGG_REPO" "$LIBOGG_TAG"

    cd ogg
    if [ ! -f "configure" ]; then
        log_info "Generating libogg configure script..."
        ./autogen.sh
    fi

    ./configure --prefix="$PREFIX" \
                --disable-shared \
                --enable-static \
                $(autotools_host_flags)
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
    cd ..
}

build_vorbis() {
    log_info "Building libvorbis (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "vorbis" "$LIBVORBIS_REPO" "$LIBVORBIS_TAG"

    cd vorbis
    if [ ! -f "configure" ]; then
        log_info "Generating libvorbis configure script..."
        ./autogen.sh
    fi

    ./configure --prefix="$PREFIX" \
                --disable-shared \
                --enable-static \
                --disable-examples \
                --disable-docs \
                --with-ogg="$PREFIX" \
                $(autotools_host_flags)
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
    cd ..
}

build_opus() {
    log_info "Building libopus (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "opus" "$OPUS_REPO" "$OPUS_TAG"

    cd opus
    if [ ! -f "configure" ]; then
        log_info "Generating libopus configure script..."
        ./autogen.sh
    fi

    ./configure --prefix="$PREFIX" \
                --disable-shared \
                --enable-static \
                --disable-doc \
                --disable-extra-programs \
                $(autotools_host_flags)
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
    cd ..
}

build_lame() {
    log_info "Building libmp3lame (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "lame" "$LAME_REPO" "$LAME_TAG"

    cd lame
    if [ ! -f "configure" ]; then
        log_info "Regenerating lame configure script..."
        autoreconf -fiv
    fi

    ./configure --prefix="$PREFIX" \
                --disable-shared \
                --enable-static \
                --disable-frontend \
                --disable-decoder \
                $(autotools_host_flags)
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
    cd ..
}

build_vpx() {
    log_info "Building libvpx (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "libvpx" "$LIBVPX_REPO" "$LIBVPX_TAG"

    cd libvpx
    rm -rf build-static
    mkdir -p build-static
    cd build-static

    local vpx_target
    case "$TARGET_ARCH" in
        amd64) vpx_target="x86_64-linux-gcc" ;;
        arm64) vpx_target="arm64-linux-gcc" ;;
        armv7) vpx_target="armv7-linux-gcc" ;;
    esac

    local vpx_cross=""
    if [ -n "${TARGET_TRIPLET:-}" ]; then
        vpx_cross="${TARGET_TRIPLET}-"
    fi

    CROSS="$vpx_cross" ../configure \
        --prefix="$PREFIX" \
        --target="$vpx_target" \
        --disable-examples \
        --disable-unit-tests \
        --disable-docs \
        --disable-shared \
        --enable-static \
        --enable-vp9-highbitdepth \
        --enable-pic
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
    cd ../..
}

build_aom() {
    log_info "Building libaom (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "aom" "$LIBAOM_REPO" "$LIBAOM_TAG"

    rm -rf aom_build
    mkdir -p aom_build
    cd aom_build

    # Without an explicit toolchain file, CMake assumes the target processor
    # matches the build host (x86_64) even though CC/CXX point at the arm
    # cross-compiler, so aom's x86-only SIMD flags get required incorrectly.
    local aom_cmake_args=(
        -G "Unix Makefiles"
        -DCMAKE_INSTALL_PREFIX="$PREFIX"
        -DCMAKE_BUILD_TYPE=Release
        -DBUILD_SHARED_LIBS=OFF
        -DENABLE_TESTS=OFF
        -DENABLE_EXAMPLES=OFF
        -DENABLE_TOOLS=OFF
        -DENABLE_DOCS=OFF
        -DCMAKE_C_FLAGS="$CFLAGS -static-libgcc"
        -DCMAKE_CXX_FLAGS="$CXXFLAGS -static-libgcc -static-libstdc++"
        # Re-add $LDFLAGS (carries -no-pie on arm64) since an explicit
        # CMAKE_EXE_LINKER_FLAGS overrides CMake's own env LDFLAGS seeding,
        # otherwise try_compile checks mismatch the -fno-PIE compile flags.
        -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS -static-libgcc -static-libstdc++"
    )

    if [ "$TARGET_ARCH" = "armv7" ]; then
        aom_cmake_args+=(-DCMAKE_TOOLCHAIN_FILE="../aom/cmake/toolchains/armv7-linux-gcc.cmake")
    else
        aom_cmake_args+=(-DENABLE_NASM=ON)
    fi

    cmake "${aom_cmake_args[@]}" ../aom
    cmake --build . --parallel "$BUILD_JOBS"
    cmake --install .
    cd ..
}

build_dav1d() {
    log_info "Building dav1d (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "dav1d" "$DAV1D_REPO" "$DAV1D_TAG"

    cd dav1d
    rm -rf build
    local meson_cmd=(setup build \
        --prefix="$PREFIX" \
        --libdir=lib \
        --default-library=static \
        --buildtype=release \
        -Denable_tools=false \
        -Denable_tests=false)
    if [ -n "$MESON_CROSS_FILE" ]; then
        meson_cmd+=(--cross-file "$MESON_CROSS_FILE")
    fi
    "$MESON_BIN" "${meson_cmd[@]}"
    ninja -C build -j"$BUILD_JOBS"
    ninja -C build -j"$BUILD_JOBS" install
    cd ..
}

build_x264() {
    log_info "Building x264 (static)..."
    cd "$WORK_DIR"

    checkout_repo_ref "x264" "$X264_REPO" "$X264_REF"

    cd x264
    ./configure --prefix="$PREFIX" \
                --enable-static \
                --enable-pic \
                --disable-cli \
                --disable-opencl \
                $(autotools_host_flags)
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
    cd ..
}

build_x265() {
    log_info "Building x265 (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "x265_git" "$X265_REPO" "$X265_TAG"

    cd x265_git/build/linux
    rm -rf static-build
    mkdir -p static-build
    cd static-build
    # x265 is C++; without forcing static libgcc/libstdc++ here, the CMake-detected
    # implicit link libraries bake a "-lgcc_s" (shared-only) reference into x265.pc,
    # which breaks ffmpeg's fully static (-static) link.
    local x265_cmake_args=(
        -G "Unix Makefiles"
        -DCMAKE_INSTALL_PREFIX="$PREFIX"
        -DCMAKE_BUILD_TYPE=Release
        -DENABLE_SHARED=OFF
        -DENABLE_CLI=OFF
        -DENABLE_LIBNUMA=OFF
        -DCMAKE_C_FLAGS="$CFLAGS -static-libgcc"
        -DCMAKE_CXX_FLAGS="$CXXFLAGS -static-libgcc -static-libstdc++"
        # Explicit CMAKE_EXE_LINKER_FLAGS overrides the env LDFLAGS that CMake
        # would otherwise seed it with, so re-add $LDFLAGS (carries -no-pie on
        # arm64) here too; otherwise try_compile checks like strtok_r detection
        # mismatch the -fno-PIE compile flags and fail to link, producing a
        # false "not found" that later conflicts with glibc's real declaration.
        -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS -static-libgcc -static-libstdc++"
    )

    if [ -n "${TARGET_TRIPLET:-}" ]; then
        # Without CMAKE_SYSTEM_PROCESSOR, x265 assumes the host arch (x86_64) and
        # tries to build x86 NASM primitives even though we're cross-compiling to arm.
        x265_cmake_args+=(
            -DCMAKE_SYSTEM_NAME=Linux
            -DCMAKE_SYSTEM_PROCESSOR=armv7
            -DCMAKE_C_COMPILER="${CC}"
            -DCMAKE_CXX_COMPILER="${CXX}"
            -DENABLE_ASSEMBLY=OFF
        )
    fi

    if [ "$TARGET_ARCH" = "arm64" ]; then
        # By default x265 enables runtime CPU dispatch for every aarch64 SIMD
        # extension (dotprod/i8mm/sve/sve2), which bakes in "-march=armv9-a+..."
        # combinations that older/generic GCC toolchains reject. Keep only
        # baseline NEON (mandatory on armv8-a, matches Debian's generic aarch64
        # baseline) for a portable build across all arm64 hardware.
        x265_cmake_args+=(
            -DAARCH64_RUNTIME_CPU_DETECT=OFF
            -DENABLE_NEON_DOTPROD=OFF
            -DENABLE_NEON_I8MM=OFF
            -DENABLE_SVE=OFF
            -DENABLE_SVE2=OFF
            -DENABLE_SVE2_BITPERM=OFF
        )
    fi

    cmake "${x265_cmake_args[@]}" ../../../source
    cmake --build . --parallel "$BUILD_JOBS"
    cmake --install .
    cd ../../../..
}

build_expat() {
    log_info "Building expat (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "libexpat" "$EXPAT_REPO" "$EXPAT_TAG"

    cd libexpat/expat
    rm -rf build
    cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DEXPAT_SHARED_LIBS=OFF \
        -DEXPAT_BUILD_EXAMPLES=OFF \
        -DEXPAT_BUILD_TESTS=OFF \
        -DEXPAT_BUILD_TOOLS=OFF \
        -DEXPAT_BUILD_DOCS=OFF \
        -DEXPAT_BUILD_PKGCONFIG=ON
    cmake --build build --parallel "$BUILD_JOBS"
    cmake --install build
    cd ../..
}

build_freetype() {
    local enable_harfbuzz="${1:-false}"

    if [ "$enable_harfbuzz" = "true" ]; then
        log_info "Building freetype (static, with harfbuzz)..."
    else
        log_info "Building freetype (static, without harfbuzz)..."
    fi

    cd "$WORK_DIR"

    checkout_repo_tag "freetype" "$FREETYPE_REPO" "$FREETYPE_TAG"

    cd freetype
    # Clean previous build state so the second pass can pick up harfbuzz.
    if [ -f "Makefile" ]; then
        make distclean >/dev/null 2>&1 || true
    fi

    log_info "Generating freetype configure script..."
    ./autogen.sh

    local harfbuzz_flag="--without-harfbuzz"
    if [ "$enable_harfbuzz" = "true" ]; then
        harfbuzz_flag="--with-harfbuzz=yes"
    fi

    ./configure --prefix="$PREFIX" \
                --disable-shared \
                --enable-static \
                "$harfbuzz_flag" \
                --with-zlib-prefix="$PREFIX" \
                $(autotools_host_flags)
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
    cd ..
}

build_harfbuzz() {
    log_info "Building harfbuzz (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "harfbuzz" "$HARFBUZZ_REPO" "$HARFBUZZ_TAG"

    cd harfbuzz
    rm -rf build
    local meson_cmd=(setup build \
        --prefix="$PREFIX" \
        --libdir=lib \
        --default-library=static \
        --buildtype=release \
        -Dtests=disabled \
        -Ddocs=disabled \
        -Dintrospection=disabled \
        -Dglib=disabled \
        -Dgobject=disabled \
        -Dcairo=disabled \
        -Dicu=disabled \
        -Dgraphite=disabled \
        -Dfreetype=enabled)
    if [ -n "$MESON_CROSS_FILE" ]; then
        meson_cmd+=(--cross-file "$MESON_CROSS_FILE")
    fi
    "$MESON_BIN" "${meson_cmd[@]}"
    ninja -C build -j"$BUILD_JOBS"
    ninja -C build -j"$BUILD_JOBS" install
    cd ..
}

build_fribidi() {
    log_info "Building fribidi (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "fribidi" "$FRIBIDI_REPO" "$FRIBIDI_TAG"

    cd fribidi
    rm -rf build
    local meson_cmd=(setup build \
        --prefix="$PREFIX" \
        --libdir=lib \
        --default-library=static \
        --buildtype=release \
        -Ddocs=false \
        -Dtests=false \
        -Dbin=false)
    if [ -n "$MESON_CROSS_FILE" ]; then
        meson_cmd+=(--cross-file "$MESON_CROSS_FILE")
    fi
    "$MESON_BIN" "${meson_cmd[@]}"
    ninja -C build -j"$BUILD_JOBS"
    ninja -C build -j"$BUILD_JOBS" install
    cd ..
}

build_fontconfig() {
    log_info "Building fontconfig (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "fontconfig" "$FONTCONFIG_REPO" "$FONTCONFIG_TAG"

    cd fontconfig
    git clean -xdff

    if [ ! -f "configure" ]; then
        log_info "Generating fontconfig configure script..."
        ./autogen.sh --prefix="$PREFIX" \
                     --disable-shared \
                     --enable-static \
                     --disable-libxml2 \
                     --disable-docs \
                     --with-freetype-config="$PREFIX/bin/freetype-config" \
                     $(autotools_host_flags)
    else
        ./configure --prefix="$PREFIX" \
                     --disable-shared \
                     --enable-static \
                     --disable-libxml2 \
                     --disable-docs \
                     --with-freetype-config="$PREFIX/bin/freetype-config" \
                     $(autotools_host_flags)
    fi
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
    cd ..
}

build_libass() {
    log_info "Building libass (static)..."
    cd "$WORK_DIR"

    checkout_repo_tag "libass" "$LIBASS_REPO" "$LIBASS_TAG"

    cd libass
    if [ ! -f "configure" ]; then
        log_info "Generating libass configure script..."
        ./autogen.sh
    fi

    ./configure --prefix="$PREFIX" \
                --disable-shared \
                --enable-static \
                --disable-fuzz \
                $(autotools_host_flags)
    make -j"$BUILD_JOBS"
    make -j"$BUILD_JOBS" install
    cd ..
}

# Function to fetch and checkout FFmpeg source
fetch_ffmpeg() {
    local tag=$1

    log_info "Fetching FFmpeg source..."

    if [ -d "$WORK_DIR/FFmpeg" ]; then
        log_info "Updating existing FFmpeg repository..."
        cd "$WORK_DIR/FFmpeg"
        git fetch --tags origin
        cd "$WORK_DIR"
    else
        log_info "Cloning FFmpeg repository..."
        cd "$WORK_DIR"
        git clone "$FFMPEG_REPO" FFmpeg
    fi

    cd "$WORK_DIR/FFmpeg"

    if [ "$tag" = "latest" ]; then
        log_info "Resolving latest stable FFmpeg release tag..."
        tag=$(git tag --list 'n[0-9]*' | grep -Ev -- '-dev$|-rc[0-9]*$' | sort -V | tail -n 1)
        if [ -z "$tag" ]; then
            log_error "Unable to resolve latest FFmpeg release tag"
            exit 1
        fi
    fi

    log_info "Checking out tag: $tag..."
    git checkout -f "$tag"
    git clean -fdx

    CHECKED_OUT_TAG=$(git describe --tags 2>/dev/null || git rev-parse --short HEAD)
    log_info "Checked out: $CHECKED_OUT_TAG"

    cd "$WORK_DIR"
}

# Function to build FFmpeg with full static linking (GPL variant)
build_ffmpeg() {
    log_info "Building FFmpeg (ffmpeg + ffprobe) with ALL dependencies statically linked..."

    cd "$WORK_DIR/FFmpeg"

    if [ -f "Makefile" ]; then
        make distclean >/dev/null 2>&1 || true
    fi

    rm -rf "$PREFIX/ffmpeg"

    # PIE + fully static linking overflows the aarch64 GOT page range
    # (R_AARCH64_LD64_GOTPAGE_LO15), so force a non-PIE final link there.
    local no_pie_ldflag=""
    if [ "$TARGET_ARCH" = "arm64" ]; then
        no_pie_ldflag=" -no-pie"
    fi

    local configure_args=(
        --prefix="$PREFIX/ffmpeg"
        --pkg-config-flags=--static
        --pkg-config=pkg-config
        --extra-cflags="-I$PREFIX/include"
        --extra-cxxflags="-I$PREFIX/include"
        --extra-ldflags="-L$PREFIX/lib -static${no_pie_ldflag}"
        --extra-libs="-lpthread -lm -ldl"
        --ld="${CXX:-g++}"
        --cc="${CC:-gcc}"
        --cxx="${CXX:-g++}"
        --ar="${AR:-ar}"
        --ranlib="${RANLIB:-ranlib}"
        --strip="${STRIP:-strip}"
        --arch="${FFMPEG_ARCH}"
        --target-os=linux
        --enable-static
        --disable-shared
        --disable-debug
        --disable-doc
        --disable-ffplay
        --disable-htmlpages
        --disable-manpages
        --disable-podpages
        --disable-txtpages
        --enable-gpl
        --enable-pthreads
        --enable-zlib
        --enable-libx264
        --enable-libx265
        --enable-libvpx
        --enable-libaom
        --enable-libdav1d
        --enable-libopus
        --enable-libmp3lame
        --enable-libvorbis
        --enable-libass
        --enable-libfreetype
        --enable-libfontconfig
    )

    if [ -n "${TARGET_TRIPLET:-}" ]; then
        configure_args+=(--enable-cross-compile --cross-prefix="${TARGET_TRIPLET}-")
    fi

    ./configure "${configure_args[@]}"

    log_info "Compiling FFmpeg with full static linking (using $BUILD_JOBS cores)..."
    make -j"$BUILD_JOBS"

    log_info "Installing..."
    make -j"$BUILD_JOBS" install

    cd "$WORK_DIR"
}

# Function to verify binaries are static
verify_static() {
    log_info "Verifying binaries are fully static..."

    local bin_dir="$PREFIX/ffmpeg/bin"
    local static_count=0
    local dynamic_count=0
    local inspected_binary

    for binary in "$bin_dir"/*; do
        if [ -f "$binary" ] && [ -x "$binary" ]; then
            inspected_binary="$binary"
            if [ -L "$binary" ]; then
                inspected_binary="$(readlink -f "$binary")"
            fi

            if file "$inspected_binary" | grep -q "statically linked"; then
                log_info "✓ $(basename "$binary") is fully static"
                static_count=$((static_count + 1))
            else
                log_warn "✗ $(basename "$binary") may have dynamic dependencies"
                dynamic_count=$((dynamic_count + 1))
            fi
        fi
    done

    log_info "Verification complete: $static_count static, $dynamic_count dynamic"
}

# Function to strip and compress binaries
optimize_binaries() {
    log_info "Stripping and optimizing binaries..."

    find "$PREFIX/ffmpeg/bin" -type f -executable -exec "${STRIP:-strip}" --strip-all {} \; 2>/dev/null || true

    log_info "Binary optimization complete"
}

# Function to create portable tarball (ffmpeg + ffprobe only)
create_portable_tarball() {
    local tag=$1
    local arch=$2

    log_info "Creating portable tarball with fully static ffmpeg + ffprobe..."

    mkdir -p "$BUILD_DIR"

    local temp_dir="${WORK_DIR}/portable"
    rm -rf "$temp_dir"
    mkdir -p "$temp_dir/ffmpeg-${tag}-${arch}/bin"

    local bin_dir="$PREFIX/ffmpeg/bin"
    local core_utils=("ffmpeg" "ffprobe")

    for util in "${core_utils[@]}"; do
        if [ -e "$bin_dir/$util" ]; then
            cp -a "$bin_dir/$util" "$temp_dir/ffmpeg-${tag}-${arch}/bin/"
            log_info "Included: $util"
        else
            log_error "Expected binary missing from build output: $util"
            exit 1
        fi
    done

    cat > "$temp_dir/ffmpeg-${tag}-${arch}/README.md" << 'EOF'
# FFmpeg Fully Static Portable Build (GPL)

This is a completely self-contained build of `ffmpeg` and `ffprobe` with ALL
dependencies statically linked into single binaries.

## No External Dependencies Required!

This build includes everything needed:
- zlib
- libogg, libvorbis, libopus, libmp3lame
- libvpx, libaom, libdav1d
- x264, x265
- expat, freetype, fribidi, fontconfig
- libass

All are statically compiled into the binaries themselves.

## Installation

### Option 1: Add to PATH (Recommended)
```bash
export PATH="$(pwd)/bin:$PATH"
```

### Option 2: Install to system
```bash
sudo cp bin/* /usr/local/bin/
```

## Requirements

✓ **NONE!** This build is completely self-contained.
- No external libraries needed
- Works on any Linux system with glibc (Debian Bookworm and compatible)
- No installation required - just run the binaries

## Verification

To verify binaries are fully static:
```bash
file ./bin/ffmpeg
# Should show: "statically linked"

ldd ./bin/ffmpeg
# Should show: "not a dynamic executable"
```

## License

This build is compiled with `--enable-gpl` and includes GPL-licensed
components (x264, x265). Distribution of this build is subject to the terms
of the GNU General Public License.
EOF

    cd "$temp_dir"
    tar -czf "${BUILD_DIR}/ffmpeg-${tag}-linux-${arch}.tar.gz" "ffmpeg-${tag}-${arch}/"
    cd - > /dev/null

    log_info "Portable tarball created: ${BUILD_DIR}/ffmpeg-${tag}-linux-${arch}.tar.gz"
    ls -lh "${BUILD_DIR}/ffmpeg-${tag}-linux-${arch}.tar.gz"

    log_info "Tarball contents:"
    tar -tzf "${BUILD_DIR}/ffmpeg-${tag}-linux-${arch}.tar.gz"
}

usage() {
    cat << EOF
FFmpeg Fully Static Self-Contained Build Script (GPL variant)

Builds ffmpeg + ffprobe with ALL dependencies statically linked into single
binaries. No external dependencies, no .so files, completely portable.

Usage: ./build.sh [OPTIONS]

Environment:
    SKIP_APT_INSTALL=true   Skip the apt-get dependency step for local iterative builds

Options:
    TAG         FFmpeg release tag to build (default: latest)
                Example: n7.1.5

    ARCH        Target architecture (default: current system architecture)
                Options: amd64, arm64, armv7 (armhf)

Examples:
    # Build latest stable release for current architecture
    ./build.sh

    # Build specific version for amd64
    ./build.sh n7.1.5 amd64

    # Build specific version for arm64
    ./build.sh n7.1.5 arm64

    # Build specific version for armv7/armhf
    ./build.sh n7.1.5 armv7

Output:
    - Portable tarball: build/ffmpeg-<tag>-linux-<arch>.tar.gz
    - Build directory: build-work/
    - Installed at: build-work/install/ffmpeg/bin/
    - Dependency lock file: dependencies.lock

To clean up build artifacts:
    rm -rf build-work/

EOF
}

# Cleanup on error
cleanup_on_error() {
    log_error "Build failed"
    log_warn "Build directory retained for debugging: $WORK_DIR"
    exit 1
}

trap cleanup_on_error ERR

# Main script
main() {
    log_info "FFmpeg Fully Static Build (GPL variant, ffmpeg + ffprobe only)"
    log_info "Tag: $RELEASE_TAG, Architecture: $TARGET_ARCH"

    load_dependency_lock
    mkdir -p "$WORK_DIR"
    mkdir -p "$BUILD_DIR"

    # Validate architecture
    case $TARGET_ARCH in
        amd64|x86_64)
            TARGET_ARCH="amd64"
            FFMPEG_ARCH="x86_64"
            ;;
        arm64|aarch64)
            TARGET_ARCH="arm64"
            FFMPEG_ARCH="aarch64"
            ;;
        armv7|armhf|armv7l)
            TARGET_ARCH="armv7"
            FFMPEG_ARCH="arm"
            ;;
        *)
            log_error "Unsupported architecture: $TARGET_ARCH"
            log_warn "Supported architectures: amd64, arm64, armv7 (armhf)"
            exit 1
            ;;
    esac

    if [ "$TARGET_ARCH" = "armv7" ]; then
        local target_triplet="arm-linux-gnueabihf"
        local qemu_sysroot="/usr/arm-linux-gnueabihf"
        TARGET_TRIPLET="$target_triplet"
        export CC="${CC:-${target_triplet}-gcc}"
        export CXX="${CXX:-${target_triplet}-g++}"
        export AR="${AR:-${target_triplet}-ar}"
        export RANLIB="${RANLIB:-${target_triplet}-ranlib}"
        export STRIP="${STRIP:-${target_triplet}-strip}"
        export QEMU_LD_PREFIX="$qemu_sysroot"
        export QEMU_SET_ENV="LD_LIBRARY_PATH=/usr/arm-linux-gnueabihf/lib:/usr/arm-linux-gnueabihf/lib/arm-linux-gnueabihf"
        log_info "Using armv7 cross-toolchain: CC=${CC} CXX=${CXX} AR=${AR} RANLIB=${RANLIB}"
        log_info "QEMU_LD_PREFIX=${QEMU_LD_PREFIX}"
        write_meson_cross_file
    else
        TARGET_TRIPLET=""
        MESON_CROSS_FILE=""
        unset QEMU_LD_PREFIX QEMU_SET_ENV
        export MESON_CROSS_FILE
    fi

    # Use baseline CPU targets for portable binaries.
    local arch_cflags
    case $TARGET_ARCH in
        amd64)
            if compiler_supports_flag "-march=x86-64-v1"; then
                arch_cflags="-march=x86-64-v1 -mtune=generic"
            else
                log_warn "Compiler does not support -march=x86-64-v1; falling back to -march=x86-64"
                arch_cflags="-march=x86-64 -mtune=generic"
            fi
            ;;
        arm64)
            # Distro gcc defaults to PIE, which blows past the aarch64 GOT
            # page range (R_AARCH64_LD64_GOTPAGE_LO15) once fully static.
            arch_cflags="-march=armv8-a -fno-PIE"
            ;;
        armv7)
            arch_cflags="-march=armv7-a"
            if compiler_supports_armv7_fpu_flags; then
                arch_cflags="$arch_cflags -mfpu=vfpv3-d16 -mfloat-abi=hard"
            else
                log_warn "armv7 cross-compiler does not support the required hard-float pair (-mfpu=vfpv3-d16 -mfloat-abi=hard); using generic armv7 baseline without it"
            fi
            ;;
    esac

    export CFLAGS="-O2 $arch_cflags"
    export CXXFLAGS="-O2 $arch_cflags"

    # Objects compiled with -fno-PIE must also be linked non-PIE, otherwise
    # dependency test/helper executables (e.g. libogg's test_bitwise) fail
    # with "relocation ... can not be used when making a shared object".
    if [ "$TARGET_ARCH" = "arm64" ]; then
        export LDFLAGS="$LDFLAGS -no-pie"
    fi

    log_info "Compiler baseline flags: CFLAGS='$CFLAGS' CXXFLAGS='$CXXFLAGS' LDFLAGS='$LDFLAGS'"

    CURRENT_ARCH=$(uname -m)
    if [ "$CURRENT_ARCH" = "x86_64" ] && [ "$TARGET_ARCH" = "arm64" ]; then
        log_error "Cross-compilation for arm64 on amd64 is not supported for static builds"
        log_warn "Please run this script natively on arm64 hardware"
        exit 1
    fi
    if [ "$CURRENT_ARCH" = "aarch64" ] && [ "$TARGET_ARCH" = "amd64" ]; then
        log_error "Cross-compilation for amd64 on arm64 is not supported for static builds"
        log_warn "Please run this script natively on amd64 hardware"
        exit 1
    fi

    mkdir -p "$WORK_DIR"
    mkdir -p "$BUILD_DIR"

    log_info "Work directory: $WORK_DIR"
    log_info "Build output directory: $BUILD_DIR"

    install_dependencies

    log_info "Building static dependencies..."
    build_zlib
    build_ogg
    build_vorbis
    build_opus
    build_lame
    build_vpx
    build_aom
    build_dav1d
    build_x264
    build_x265
    build_expat
    build_freetype false
    build_harfbuzz
    build_freetype true
    build_fribidi
    build_fontconfig
    build_libass

    fetch_ffmpeg "$RELEASE_TAG"
    build_ffmpeg
    verify_static
    optimize_binaries

    ACTUAL_TAG=$CHECKED_OUT_TAG

    create_portable_tarball "$ACTUAL_TAG" "$TARGET_ARCH"

    log_info "================================"
    log_info "✓ Build completed successfully!"
    log_info "================================"
    log_info ""
    log_info "Output: $(pwd)/build/ffmpeg-${ACTUAL_TAG}-linux-${TARGET_ARCH}.tar.gz"
    log_info ""
    log_info "NO external dependencies required - binaries are completely self-contained!"
    log_info ""

    if [ -f "$PREFIX/ffmpeg/bin/ffmpeg" ]; then
        log_info "Final verification..."
        file "$PREFIX/ffmpeg/bin/ffmpeg"
    fi

    log_info ""
    log_info "To clean up build artifacts: rm -rf build-work/"
}

# Run main function
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
    exit 0
fi

main
