# ffmpeg-rockchip — RK3588 Hardware Acceleration Build

## Goal
Build Jellyfin's ffmpeg fork with full RK3588 HW acceleration (rkmpp, rkrga, vaapi) as the system-wide default, and rebuild mpv against it for native HWA support.

## System
- **Board:** Orange Pi 5 Plus (RK3588)
- **OS:** Armbian/Debian 13 Trixie, aarch64
- **Kernel:** 6.1.115-vendor-rk35xx
- **User:** mbesar (groups: video, render, sudo, audio)

## What's Installed

| Component | Location | Version |
|-----------|----------|---------|
| **MPP** | `/usr` (from source) | Jellyfin fork `jellyfin-mpp-next` (a9380ef) |
| **RGA** | `/usr` (from source) | Jellyfin fork `jellyfin-rga-next` (1d330cc) |
| **ffmpeg** | `/usr/local/bin/ffmpeg` | 8.1.1-rockchip-rk3588 |
| **mpv** | `/usr/local/bin/mpv` | v0.40.0-dirty |

Libraries at `/usr/local/lib/` (libavcodec.so.62, etc.).

## Build Order
1. MPP — `cmake .. && make && sudo make install`
2. RGA — `cmake .. && make && sudo make install`
3. ffmpeg — `./configure … && make -j$(nproc) && sudo make install`
4. mpv — `meson setup build … && ninja -C build && sudo ninja -C build install`

## Build Scripts
- **`build.sh`** — Full local build (deps → mpp → rga → ffmpeg → mpv → verify)
- **`.github/workflows/build.yml`** — CI/CD: same build on `ubuntu-24.04-arm` runner, produces .deb packages and publishes GitHub Release

## CI Build Notes — Pitfalls Fixed

### Stale clones (build dir already exists)
CI re-runs fail when `/tmp/rkmpp/build` already exists from a previous run. `mkdir build` errors, `cd build` is skipped (due to `&&` chaining), and `cmake ..` runs from the wrong directory.
- **Fix:** `rm -rf` before each clone; use `mkdir -p build`

### ffmpeg not installed to system prefix for mpv
`Build ffmpeg` step only ran `make`, and `Package ffmpeg .deb` used `DESTDIR=...`. Nothing installed to `/usr/local`, so mpv's meson couldn't find `libavcodec.pc`.
- **Fix:** Add `sudo make install` after `make -j$(nproc)`

### Vulkan detection fails on ARM runners
`ubuntu-24.04-arm` runner has `vulkan.pc` available but ffmpeg's internal compilation test fails (no GPU, header incompatibility). `--enable-vulkan` causes `./configure` to error.
- **Fix:** Use `--disable-vulkan` in CI (vulkan is not needed for rkmpp HW decode; `build.sh` keeps `--enable-vulkan` for real RK3588 builds)

### mpv v0.40.0 annotated tag
`git clone --depth 1 --branch v0.40.0` fails because the tag is an annotated tag object, not a commit.
- **Fix:** `git init + git fetch --depth 1 origin v0.40.0 + git checkout FETCH_HEAD`

### mpv v0.40.0 does not have `-Dlibplacebo=disabled` option
The option doesn't exist in mpv's `meson_options.txt`. libplacebo is a **hard dependency** in `meson.build:29` — must be installed.
- **Fix:** Remove `-Dlibplacebo=disabled`; install `libplacebo-dev`

### Permission denied in packaging steps
`sudo make install DESTDIR=...` creates root-owned directories. Subsequent bare `mkdir` and `cat >` fail.
- **Fix:** `sudo mkdir -p` and `sudo tee` for all writes inside DESTDIR

### ALL missing system deps for mpv v0.40.0

| Meson dependency | Ubuntu package | Required by feature flag |
|---|---|---|
| `libplacebo >= 6.338.2` | `libplacebo-dev` | hard dependency |
| `lua` / `lua5.2` | `liblua5.2-dev` | `-Dlua=enabled` |
| `libdisplay-info >= 0.1.1` | `libdisplay-info-dev` | `-Ddrm=enabled` |
| `wayland-protocols >= 1.31` | `wayland-protocols` | `-Dwayland=enabled` |
| `xkbcommon >= 0.3.0` | `libxkbcommon-dev` | `-Dwayland=enabled` |
| `xscrnsaver >= 1.0.0` | `libxss-dev` | `-Dx11=enabled` |

### FF_PROFILE_ → AV_PROFILE_ API rename
Jellyfin ffmpeg fork removed deprecated `FF_PROFILE_*` compatibility aliases. mpv v0.40.0's `demux/demux_mkv.c` uses the old names (`FF_PROFILE_ARIB_PROFILE_A`, `FF_PROFILE_ARIB_PROFILE_C`, `FF_PROFILE_UNKNOWN`).
- **Fix:** `sed -i 's/FF_PROFILE_ARIB_PROFILE_A/AV_PROFILE_ARIB_PROFILE_A/g'` (and B, C variants) before meson setup

### .deb files not published as GitHub Release
Uploaded as CI artifacts but never created a proper Release page with downloadable assets.
- **Fix:** `gh release create` step with GITHUB_TOKEN and `contents: write` permission

## ffmpeg Configure Flags (local build)
```
--prefix=/usr/local --extra-version=rockchip-rk3588
--enable-shared --disable-static
--enable-gpl --enable-version3
--disable-unstable --disable-ffplay
--disable-debug --disable-doc --disable-sdl2
--disable-libxcb --disable-xlib
--enable-lto=auto --enable-runtime-cpudetect
--enable-rkmpp --enable-rkrga
--enable-vaapi --enable-vulkan --enable-libdrm
--enable-libx264 --enable-libx265 --enable-libaom
--enable-libvpx --enable-libdav1d
--enable-libopus --enable-libmp3lame
--enable-libtheora --enable-libwebp --enable-libzimg
--enable-libass --enable-libfreetype
--enable-libfontconfig --enable-libfribidi
--enable-libbluray --enable-libopenmpt
--enable-libsoxr --enable-libzvbi
--enable-openssl --enable-libxml2 --enable-libsnappy
--enable-bzlib --enable-lzma --enable-zlib
```

## ffmpeg Configure Flags (CI build)
Same, except **`--disable-vulkan`** — ARM runner cannot compile vulkan code.

## mpv Build Flags (meson)
```
-Dlibmpv=true -Dcplayer=true -Dlua=enabled
-Ddrm=enabled -Degl-drm=enabled
-Dx11=enabled -Dwayland=enabled
--buildtype=release --prefix=/usr/local
```

## Config Files
- **mpv:** `~/.config/mpv/mpv.conf` → `hwdec=rkmpp-copy`

## Verified HWA Results

| Codec | Decoder | ffmpeg `-hwaccel rkmpp` | mpv `--hwdec=rkmpp-copy` | Frame Drops |
|-------|---------|------------------------|--------------------------|-------------|
| H.264 | h264_rkmpp | 80.6× | ✅ | None |
| HEVC | hevc_rkmpp | 131× | ✅ | None |
| VP9 | vp9_rkmpp | 161× | ✅ | None |
| AV1 (8-bit) | av1_rkmpp | 47.3× | ✅ | None |
| AV1 (10-bit) | libdav1d (SW) | N/A | ❌ HW limitation | — |

Full HW pipeline tested: decode → RGA scale (`scale_rkrga`) → encode (`h264_rkmpp`) at 47.9×.

## Known Issues
- **AV1 10-bit** — RK3588 MPP HW decoder does not support 10-bit; falls back to software `libdav1d`.
- **CI vulkan** — `--disable-vulkan` in CI because ubuntu-24.04-arm runner headers conflict with ffmpeg configure. Local builds (RK3588) use `--enable-vulkan`.
- **VAAPI** — Not configured/tested. rkmpp is the primary hwdec path.
- **H.264 4K (High Profile, Level 5.1)** — Works flawlessly with rkmpp-copy.

## Useful Commands
```bash
# Test HW decode performance
ffmpeg -hwaccel rkmpp -c:v h264_rkmpp -i input.mp4 -f null - -benchmark

# Full HW pipeline
ffmpeg -hwaccel rkmpp -c:v h264_rkmpp -i input.mp4 \
  -vf hwupload=extra_hw_frames=32,format=rkmpp,scale_rkrga=w=1280:h=720:format=nv12,hwdownload,format=nv12 \
  -c:v h264_rkmpp -b:v 1M output.mp4

# Play with HW decode
mpv --hwdec=rkmpp-copy video.mp4

# Check decoders
ffmpeg -decoders | grep rkmpp
```

## Project Structure
```
ffmpeg-rockchip/
├── AGENTS.md          # This file
├── build.sh           # Full build script
├── patches/           # Debian patches for ffmpeg
├── scripts/           # Helper scripts
└── .github/workflows/ # CI/CD (GitHub Actions)
```

## Downloadable .deb Files (pre-built, not from our build)
- `/home/mbesar/Downloads/ffmpeg-rockchip_8730f72_arm64.deb`
- `/home/mbesar/Downloads/mpv-rockchip_0.41.0-*_arm64.deb`
