#!/bin/bash
# Builds the small ffmpeg Editroom ships in Vendor/ffmpeg/ffmpeg (about 4.6 MB, Apple silicon,
# LGPL). Editroom only uses it to rewrap or convert files macOS can't open itself (MXF, MKV, WebM…),
# so it has container readers, a .mov writer, decoders for codecs macOS lacks, and Apple's hardware
# encoder; nothing else. Run it to update ffmpeg (for security fixes): ./scripts/build-ffmpeg.sh 9.1
set -euo pipefail
VERSION="${1:-9.1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
curl -fsSLO "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
tar xf "ffmpeg-$VERSION.tar.xz"
mkdir build && cd build
"../ffmpeg-$VERSION/configure" \
  --arch=arm64 --cc=clang \
  --disable-everything --disable-autodetect --disable-doc --disable-debug --disable-network \
  --disable-ffplay --disable-ffprobe --enable-ffmpeg --enable-small --disable-shared --enable-static \
  --enable-videotoolbox --enable-zlib \
  --enable-protocol=file,pipe \
  --enable-demuxer=mpegts,mpegps,mxf,matroska,ogg,avi,flv,asf,mov,wav,flac,mp3,aac,ac3,eac3,dv,mpegvideo,h264,hevc,m4v \
  --enable-muxer=mov \
  --enable-parser=h264,hevc,aac,ac3,mpegaudio,mpegvideo,vp8,vp9,av1,opus,vorbis,flac,dnxhd,dvbsub \
  --enable-bsf=aac_adtstoasc,extract_extradata,vp9_superframe \
  --enable-decoder=mpeg1video,mpeg2video,dnxhd,vp8,vp9,theora,h264,hevc,dvvideo,vorbis,opus,mp2,mp3,ac3,eac3,flac,aac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_s16be,pcm_s24be,pcm_bluray,pcm_dvd \
  --enable-encoder=h264_videotoolbox,hevc_videotoolbox,aac,pcm_s16le \
  --enable-filter=scale,format,aresample,aformat,null,anull,setpts,asetpts \
  --enable-swscale --enable-swresample \
  --extra-cflags="-Os -flto" --extra-ldflags="-flto -Wl,-dead_strip"
make -j"$(sysctl -n hw.ncpu)" ffmpeg
cp ffmpeg "$ROOT/Vendor/ffmpeg/ffmpeg"
echo "$VERSION" > "$ROOT/Vendor/ffmpeg/VERSION"
ls -la "$ROOT/Vendor/ffmpeg/ffmpeg"
