# VIDEOWASTE Community Programs for Videomancer

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

FPGA video processing programs for the [Videomancer](https://github.com/lzxindustries/videomancer-sdk) platform by [VIDEOWASTE](https://github.com/VIDEOWASTE).

## Programs

> **Note:** These programs are under active development. Expect changes between versions.

| Program | Description |
|---------|-------------|
| **H/V Scroll** | Horizontal scroll/pan with animated motion and diagonal rolling effects. |
| **Luma Quantize** | Maps continuous video to retro fixed color palettes (1-bit, CGA, EGA-style) with optional ordered dithering. |
| **Temporal Diff** | Motion detection via temporal pixel difference with threshold, colorization, and persistence. |
| **Time Displace** | Luma-controlled temporal delay with full-spectrum color shift, solarize, negative, mono, and edge enhancement. |
| **Time Sculpt** | Movable temporal lens: position a zone on screen where video is time-displaced by depth and luma. |
| **Wave Distort** | Sine-wave spatial displacement with adjustable frequency, amplitude, and waveform. |

## Downloads

Pre-built `.vmprog` files (Rev B) are available on the [Releases](https://github.com/VIDEOWASTE/videomancer-community-programs/releases) page. Copy to your SD card to use.

## Building from Source

```bash
# Clone
git clone https://github.com/VIDEOWASTE/videomancer-community-programs.git
cd videomancer-community-programs

# Initialize submodules
git submodule update --init --recursive

# Setup toolchain (one-time)
./scripts/setup.sh

# Build all programs
./build_programs.sh videowaste

# Build a specific program
./build_programs.sh videowaste time_displace
```

Compiled `.vmprog` files will be in `out/rev_b/videowaste/`.

## License

GPL-3.0-only. See [LICENSE](LICENSE) for details.

Built with the [Videomancer SDK](https://github.com/lzxindustries/videomancer-sdk) by LZX Industries.
