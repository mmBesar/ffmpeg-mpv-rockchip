# ffmpeg-rockchip

Build **ffmpeg** and **mpv** with full RK3588 hardware acceleration (rkmpp, rkrga, VAAPI) on Armbian/Debian.

## What you get

| Component | HW Decode | HW Encode | HW Scale |
|-----------|-----------|-----------|----------|
| H.264     | ✅ h264_rkmpp | ✅ h264_rkmpp | ✅ scale_rkrga |
| HEVC      | ✅ hevc_rkmpp | ❌ (not in MPP) | — |
| VP9       | ✅ vp9_rkmpp  | ❌ | — |
| AV1 (8-bit) | ✅ av1_rkmpp | ❌ | — |
| AV1 (10-bit) | ❌ libdav1d (SW fallback, HW limitation) | ✅ libaom-av1 | — |

> **Note:** AV1 HW decode only works with 8-bit streams. 10-bit AV1 falls back to software `libdav1d`.

## Requirements

- **Board:** Orange Pi 5 / 5 Plus, Rock 5B, or any RK3588 device
- **OS:** Armbian / Debian 13 Trixie (aarch64)
- **Kernel:** 6.1+ vendor kernel with rockchip drivers
- **Storage:** ~3 GB free for build artifacts

## Quick Start

```bash
# Clone
git clone https://github.com/YOUR_USER/ffmpeg-rockchip.git
cd ffmpeg-rockchip

# Install system dependencies (requires sudo)
sudo ./build.sh deps-all

# Build and install everything
./build.sh all

# Verify installation
./build.sh verify
```

## Build Commands

```bash
./build.sh             # Run full build (default)
./build.sh deps        # Check dependencies only
./build.sh deps-all    # Install all system deps (sudo)
./build.sh mpp         # Build MPP from Jellyfin fork
./build.sh rga         # Build RGA from Jellyfin fork
./build.sh source      # Clone/update ffmpeg source
./build.sh patches     # Apply Jellyfin patches
./build.sh configure   # Configure ffmpeg
./build.sh build       # Compile ffmpeg
./build.sh install     # Install to /usr/local
./build.sh verify      # Verify installation
./build.sh test        # Test HW decode
./build.sh mpv         # Build and install mpv
./build.sh clean       # Remove build artifacts
```

## What gets installed

| Path | Component |
|------|-----------|
| `/usr/local/bin/ffmpeg` | ffmpeg 8.1.1-rockchip-rk3588 |
| `/usr/local/bin/ffprobe` | ffprobe |
| `/usr/local/bin/mpv` | mpv v0.40.0+ |
| `/usr/local/lib/libavcodec.so.62` | Shared ffmpeg libs |
| `/usr/lib/librockchip_mpp.so` | MPP (Media Process Platform) |
| `/usr/lib/librga.so` | RGA (2D graphics accelerator) |
| `~/.config/mpv/mpv.conf` | mpv config (`hwdec=rkmpp-copy`) |

## Testing HW Acceleration

```bash
# ffmpeg HW decode benchmark
ffmpeg -hwaccel rkmpp -c:v h264_rkmpp -i input.mp4 -f null - -benchmark

# Full HW pipeline (decode → RGA scale → encode)
ffmpeg -hwaccel rkmpp -c:v h264_rkmpp -i input.mp4 \
  -vf hwupload=extra_hw_frames=32,format=rkmpp,scale_rkrga=w=1280:h=720:format=nv12, \
      hwdownload,format=nv12 \
  -c:v h264_rkmpp -b:v 1M output.mp4

# mpv HW playback
mpv --hwdec=rkmpp-copy video.mp4
```

Speed multiplier (`speed=`) above 1× indicates hardware acceleration is working.

## Known Issues

- **`--hwdec=rkmpp` (zero-copy):** Requires mpv built with drm/egl-drm support. Current build uses `rkmpp-copy` (negligible overhead on UMA systems). Edit `~/.config/mpv/mpv.conf` to change.
- **AV1 10-bit:** Not supported by RK3588 MPP hardware decoder. Falls back to software `libdav1d`.
- **VAAPI:** Not configured/tested. rkmpp is the primary hwdec path on Rockchip.

## How it works

```
┌─────────────┐    ┌──────────┐    ┌──────────┐
│  Video File │───▶│  rkmpp   │───▶│  RGA     │───▶ Output
│ (H.264/HEVC/│    │  Decode  │    │  Scale   │
│  VP9/AV1)   │    │ (HW)     │    │ (HW)     │
└─────────────┘    └──────────┘    └──────────┘
```

The build chain:
1. **MPP** (Rockchip Media Process Platform) — HW codec API
2. **RGA** (Rockchip 2D Graphics Accelerator) — HW scaler
3. **FFmpeg** (Jellyfin fork + patches) — All codecs + rockchip integration
4. **mpv** — Player linked against our ffmpeg

## CI/CD

The `.github/workflows/build.yml` builds ffmpeg as a tarball artifact on GitHub Actions (arm64 runner required).

## License

ffmpeg and mpv are GPL-licensed. This build script is provided as-is.
