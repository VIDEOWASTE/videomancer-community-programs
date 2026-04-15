# VIDEOWASTE Community Programs for Videomancer

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

FPGA video processing programs for the [Videomancer](https://github.com/lzxindustries/videomancer-sdk) platform by [VIDEOWASTE](https://github.com/VIDEOWASTE).

## Programs

> **Note:** These programs are under active development. Expect changes between versions.

### Time Displace

Luma-controlled temporal delay. Bright areas show current video while dark areas show older video, creating surreal time-displacement effects with ghostly motion trails.

**Controls:**
| Knob | Function |
|------|----------|
| Depth | Maximum time displacement range |
| Threshold | Luma cutoff for displacement |
| Smoothing | Spatial smoothing of displacement map |
| Edge Boost | Enhance edges at time boundaries |
| Color Shift | Full-spectrum hue shift (blue/magenta/red/cyan) |
| Contrast | Output contrast adjustment |
| Dry/Wet | Mix between clean and processed signal |

**Switches:** Negative, Mono, Solarize, Edge Only, Bypass

### Temporal Diff

Motion detection via temporal pixel difference. Highlights areas of change between frames with threshold control, colorization, and adjustable persistence.

**Controls:**
| Knob | Function |
|------|----------|
| Threshold | Motion detection sensitivity |
| Persistence | How long motion trails linger |
| Color Amount | Colorize motion areas |
| Gain | Amplify detected motion |
| Decay | Fade rate of motion trails |
| Contrast | Output contrast |
| Dry/Wet | Mix between clean and processed signal |

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
