#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="/tmp/ffmpeg-source"
JOBS=$(nproc)

FFMPEG_REPO="https://github.com/jellyfin/jellyfin-ffmpeg.git"
FFMPEG_BRANCH="jellyfin"
MPP_REPO="https://github.com/nyanmisaka/rk-mirrors.git"
MPP_BRANCH="jellyfin-mpp-next"
RGA_REPO="https://github.com/nyanmisaka/rk-mirrors.git"
RGA_BRANCH="jellyfin-rga-next"
MPV_REPO="https://github.com/mpv-player/mpv.git"
MPV_BRANCH="v0.40.0"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_deps() {
    local missing=0
    for dep in gcc g++ make cmake meson ninja pkg-config yasm nasm git wget; do
        command -v "$dep" &>/dev/null || { error "Missing: $dep"; missing=1; }
    done
    for pkg in libdrm libva vulkan rockchip_mpp librga x264 x265 vpx dav1d \
               opus lame libass freetype2 fontconfig fribidi harfbuzz theora webp zimg \
               bluray openmpt soxr zvbi openssl xml2 snappy gnutls; do
        pkg-config --exists "$pkg" 2>/dev/null || { warn "Missing pkg: $pkg"; missing=1; }
    done
    [ "$missing" -eq 1 ] && { error "Install missing deps first"; exit 1; }
    info "All dependencies satisfied"
}

install_deps() {
    info "Installing system dependencies..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq gcc g++ make cmake meson ninja-build pkg-config yasm nasm git wget \
        libdrm-dev libva-dev libvulkan-dev libx11-dev libegl1-mesa-dev libgbm-dev \
        libdav1d-dev libopus-dev libmp3lame-dev libvpx-dev \
        libx264-dev libx265-dev libaom-dev \
        libass-dev libfreetype-dev libfontconfig-dev \
        libfribidi-dev libharfbuzz-dev libtheora-dev libwebp-dev \
        libzimg-dev libxml2-dev zlib1g-dev libssl-dev \
        libbluray-dev libopenmpt-dev libchromaprint-dev \
        libfftw3-dev libzvbi-dev libsoxr-dev \
        liblzma-dev libbz2-dev libsnappy-dev libgmp-dev libgnutls28-dev \
        libwayland-dev libxpresent-dev libxext-dev libxrandr-dev \
        libxinerama-dev libxcursor-dev libxi-dev
    info "System dependencies installed"
}

build_mpp() {
    info "Building MPP from Jellyfin fork..."
    local srcdir=/tmp/rkmpp-build
    [ -d "$srcdir" ] && rm -rf "$srcdir"
    git clone --depth 1 --branch "$MPP_BRANCH" "$MPP_REPO" "$srcdir"
    cd "$srcdir"
    mkdir -p build && cd build
    cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
          -DBUILD_TEST=OFF -DBUILD_SHARED_LIBS=ON ..
    make -j"$JOBS"
    sudo make install
    echo "Libs.private: -lstdc++" | sudo tee -a /usr/lib/aarch64-linux-gnu/pkgconfig/rockchip_mpp.pc
    info "MPP build complete"
}

build_rga() {
    info "Building RGA from Jellyfin fork..."
    local srcdir=/tmp/rkrga-build
    [ -d "$srcdir" ] && rm -rf "$srcdir"
    git clone --depth 1 --branch "$RGA_BRANCH" "$RGA_REPO" "$srcdir"
    cd "$srcdir"
    sed -i 's/shared_library/library/g' meson.build
    mkdir -p build && cd build
    meson setup --prefix=/usr --buildtype=release -Dlibdrm=false -Dlibrga_demo=false ..
    ninja -j"$JOBS"
    sudo ninja install
    echo "Libs.private: -lstdc++" | sudo tee -a /usr/lib/aarch64-linux-gnu/pkgconfig/librga.pc
    info "RGA build complete"
}

clone_source() {
    if [ -d "$SOURCE_DIR/.git" ]; then
        info "Updating ffmpeg source..."
        cd "$SOURCE_DIR" && git pull
    else
        info "Cloning Jellyfin ffmpeg..."
        git clone --depth 1 --branch "$FFMPEG_BRANCH" "$FFMPEG_REPO" "$SOURCE_DIR"
    fi
}

apply_patches() {
    info "Applying patches..."
    cd "$SOURCE_DIR"
    local total=0 ok=0 skip=0 fail=0
    while IFS= read -r patch; do
        ((total++))
        if patch -p1 --forward --dry-run < "debian/patches/$patch" &>/dev/null; then
            patch -p1 --forward < "debian/patches/$patch" &>/dev/null && \
                ((ok++)) || ((fail++))
        else
            ((skip++))
        fi
    done < debian/patches/series
    info "Patches: $ok applied, $skip skipped, $fail failed (of $total)"
    [ "$fail" -gt 0 ] && error "Some patches failed!" && exit 1
}

configure_ffmpeg() {
    info "Configuring ffmpeg..."
    cd "$SOURCE_DIR"
    ./configure \
        --prefix=/usr/local \
        --extra-version="rockchip-rk3588" \
        --enable-shared --disable-static \
        --enable-gpl --enable-version3 \
        --disable-unstable --disable-ffplay \
        --disable-debug --disable-doc --disable-sdl2 \
        --disable-libxcb --disable-xlib \
        --enable-lto=auto --enable-runtime-cpudetect \
        --enable-rkmpp --enable-rkrga \
        --enable-vaapi --enable-vulkan --enable-libdrm \
        --enable-libx264 --enable-libx265 --enable-libaom \
        --enable-libvpx --enable-libdav1d \
        --enable-libopus --enable-libmp3lame \
        --enable-libtheora --enable-libwebp --enable-libzimg \
        --enable-libass --enable-libfreetype \
        --enable-libfontconfig --enable-libfribidi \
        --enable-libbluray --enable-libopenmpt \
        --enable-libsoxr --enable-libzvbi \
        --enable-openssl --enable-libxml2 --enable-libsnappy \
        --enable-bzlib --enable-lzma --enable-zlib \
        || { error "Configure failed!"; cat ffbuild/config.log | tail -20; exit 1; }
    info "Configure successful"
}

build_ffmpeg() {
    info "Building ffmpeg..."
    cd "$SOURCE_DIR"
    make -j"$JOBS"
    info "ffmpeg build complete!"
}

install_ffmpeg() {
    info "Installing ffmpeg..."
    cd "$SOURCE_DIR"
    sudo make install
    sudo ldconfig 2>/dev/null || true
}

package_ffmpeg_deb() {
    info "Packaging ffmpeg .deb..."
    cd "$SOURCE_DIR"
    sudo make install DESTDIR=/tmp/ffmpeg-deb
    mkdir -p /tmp/ffmpeg-deb/DEBIAN
    cat > /tmp/ffmpeg-deb/DEBIAN/control <<CONTROL
Package: ffmpeg-rockchip
Version: 8.1.1
Section: video
Priority: optional
Architecture: arm64
Depends: libdrm2, libva2, libvulkan1, libx264-164, libx265-209, libvpx9, libdav1d7, libaom3, libopus0, libmp3lame0, libass9, libfreetype6, libfontconfig1, libfribidi0, libtheora0, libwebp7, libzimg2, libbluray2, libopenmpt0, libsoxr0, libzvbi0, libssl3, libxml2, libsnappy1v5, liblzma5, libbz2-1.0, zlib1g
Maintainer: ffmpeg-rockchip
Description: FFmpeg 8.1 with RK3588 hardware acceleration (rkmpp, rkrga, vaapi)
CONTROL
    sudo chown -R root:root /tmp/ffmpeg-deb
    sudo dpkg-deb --build /tmp/ffmpeg-deb "$REPO_DIR/ffmpeg-rockchip_8.1.1_arm64.deb"
    info "Created: ffmpeg-rockchip_8.1.1_arm64.deb"
}

build_mpv() {
    info "Building mpv..."
    local mpv_src=/tmp/mpv-source
    [ -d "$mpv_src" ] && rm -rf "$mpv_src"
    git init "$mpv_src" && cd "$mpv_src"
    git remote add origin "$MPV_REPO"
    git fetch --depth 1 origin "$MPV_BRANCH"
    git checkout FETCH_HEAD
    meson setup build \
        -Dlibmpv=true -Dcplayer=true \
        -Dlua=enabled \
        -Ddrm=enabled -Degl-drm=enabled \
        -Dx11=enabled -Dwayland=enabled \
        --buildtype=release --prefix=/usr/local
    ninja -C build -j"$JOBS"
    sudo ninja -C build install
    sudo ldconfig 2>/dev/null || true
    mkdir -p ~/.config/mpv
    echo "hwdec=rkmpp-copy" > ~/.config/mpv/mpv.conf
    info "mpv installed to /usr/local"
}

package_mpv_deb() {
    info "Packaging mpv .deb..."
    local mpv_src=/tmp/mpv-source
    cd "$mpv_src"
    sudo DESTDIR=/tmp/mpv-deb ninja -C build install
    mkdir -p /tmp/mpv-deb/DEBIAN
    cat > /tmp/mpv-deb/DEBIAN/control <<CONTROL
Package: mpv-rockchip
Version: 0.40.0
Section: video
Priority: optional
Architecture: arm64
Depends: ffmpeg-rockchip (= 8.1.1), libdrm2, libva2, libegl1, libwayland-client0, libx11-6
Maintainer: mpv-rockchip
Description: mpv v0.40.0 built against ffmpeg-rockchip with rkmpp HW decode
CONTROL
    sudo chown -R root:root /tmp/mpv-deb
    sudo dpkg-deb --build /tmp/mpv-deb "$REPO_DIR/mpv-rockchip_0.40.0_arm64.deb"
    info "Created: mpv-rockchip_0.40.0_arm64.deb"
}

verify_build() {
    info "Verifying installation..."
    local fail=0
    echo -n "ffmpeg: " && ffmpeg -version 2>&1 | head -1 || { echo "NOT FOUND"; ((fail++)); }
    echo -n "mpv:    " && mpv --version 2>&1 | head -1 || { echo "NOT FOUND"; ((fail++)); }
    echo "---"
    echo "rkmpp decoders:"
    ffmpeg -decoders 2>&1 | grep rkmpp | awk '{print $3}' || ((fail++))
    echo "---"
    echo "rkmpp encoders:"
    ffmpeg -encoders 2>&1 | grep rkmpp | awk '{print $3}' || ((fail++))
    echo "---"
    echo "rkrga filters:"
    ffmpeg -filters 2>&1 | grep rkrga | awk '{print $2}' || ((fail++))
    echo "---"
    echo "hwaccel methods:"
    ffmpeg -hwaccels 2>&1 | grep rkmpp || true
    [ "$fail" -gt 0 ] && error "Verification failed!" && exit 1
    info "All checks passed!"
}

test_hw_decode() {
    info "Testing HW decode..."
    rm -f /tmp/test-h264.mp4
    ffmpeg -f lavfi -i testsrc2=size=1280x720:rate=30:duration=5 \
           -c:v libx264 -preset ultrafast -b:v 1M /tmp/test-h264.mp4 -y 2>/dev/null
    echo -n "H.264 rkmpp: "
    ffmpeg -hwaccel rkmpp -c:v h264_rkmpp -i /tmp/test-h264.mp4 -t 3 -f null - 2>&1 | \
        grep -oP 'speed=\K[0-9.]+x' || echo "FAIL"
    echo -n "mpv rkmpp-copy: "
    mpv --hwdec=rkmpp-copy --vo=null --no-audio --untimed --frames=50 \
        /tmp/test-h264.mp4 2>&1 | grep -oP "hardware decoding" || echo "software"
    rm -f /tmp/test-h264.mp4
    info "HW decode test complete"
}

clean_all() {
    info "Cleaning build artifacts..."
    rm -rf "$SOURCE_DIR" /tmp/rkmpp-build /tmp/rkrga-build /tmp/mpv-source \
          /tmp/ffmpeg-deb /tmp/mpv-deb /tmp/test-h264.mp4
    rm -f "$REPO_DIR"/*.deb
    info "Clean complete"
}

usage() {
    cat <<EOF
Usage: $0 [command]

Commands:
  deps         Check dependencies
  deps-all     Install all system dependencies (sudo)
  mpp          Build MPP from Jellyfin fork
  rga          Build RGA from Jellyfin fork
  source       Clone/update ffmpeg source
  patches      Apply Jellyfin patches
  configure    Configure ffmpeg
  build        Compile ffmpeg
  install      Install ffmpeg to /usr/local
  deb-ffmpeg   Package ffmpeg as .deb
  mpv          Build and install mpv
  deb-mpv      Package mpv as .deb
  debs         Build both .deb packages
  verify       Verify installation
  test         Test HW decode
  all          Full build chain (deps->mpp->rga->ffmpeg->mpv->verify->test)
  clean        Remove all build artifacts
EOF
}

cmd="${1:-all}"
case "$cmd" in
    all)
        install_deps
        build_mpp
        build_rga
        clone_source
        apply_patches
        configure_ffmpeg
        build_ffmpeg
        install_ffmpeg
        build_mpv
        verify_build
        test_hw_decode
        info "Full build complete! ffmpeg + mpv with RK3588 HWA installed."
        ;;
    deps)       check_deps ;;
    deps-all)   install_deps ;;
    mpp)        build_mpp ;;
    rga)        build_rga ;;
    source)     clone_source ;;
    patches)    apply_patches ;;
    configure)  configure_ffmpeg ;;
    build)      build_ffmpeg ;;
    install)    install_ffmpeg ;;
    deb-ffmpeg) package_ffmpeg_deb ;;
    mpv)        build_mpv ;;
    deb-mpv)    package_mpv_deb ;;
    debs)
        package_ffmpeg_deb
        package_mpv_deb
        info ".deb packages created in $REPO_DIR"
        ;;
    verify)     verify_build ;;
    test)       test_hw_decode ;;
    clean)      clean_all ;;
    *)          usage; exit 1 ;;
esac
