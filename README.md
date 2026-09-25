Prebuilt [FFmpeg](https://ffmpeg.org) (`ffmpeg` + `ffprobe` only) for Debian Bookworm armhf/aarch64/amd64, fully static, GPL variant.

Deps used:

| Library | Repository |
| --- | --- |
| zlib | [repo](https://github.com/madler/zlib) |
| libogg | [repo](https://github.com/xiph/ogg) |
| libvorbis | [repo](https://github.com/xiph/vorbis) |
| opus | [repo](https://github.com/xiph/opus) |
| lame (libmp3lame) | [repo](https://github.com/enzo1982/lame) |
| libvpx | [repo](https://github.com/webmproject/libvpx) |
| libaom | [repo](https://aomedia.googlesource.com/aom) |
| dav1d | [repo](https://code.videolan.org/videolan/dav1d) |
| x264 | [repo](https://github.com/mirror/x264) |
| x265 | [repo](https://bitbucket.org/multicoreware/x265_git) |
| expat | [repo](https://github.com/libexpat/libexpat) |
| freetype | [repo](https://github.com/freetype/freetype) |
| harfbuzz | [repo](https://github.com/harfbuzz/harfbuzz) |
| fribidi | [repo](https://github.com/fribidi/fribidi) |
| fontconfig | [repo](https://gitlab.freedesktop.org/fontconfig/fontconfig) |
| libass | [repo](https://github.com/libass/libass) |

Only `ffmpeg` and `ffprobe` are packaged (no `ffplay`, no CLI tools from the delegate
libraries). The build is configured with `--enable-gpl` and links `x264`/`x265`, so
resulting binaries are distributed under the GNU GPL.

Dependencies are pinned to committed tags/commits in [dependencies.lock](dependencies.lock).

Disclaimer: This repo is almost purely vibecoded with copilot.
