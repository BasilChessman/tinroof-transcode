#!/bin/sh
# Generates the sample media used by the integration tests (TestMedia/).
set -e
cd "$(dirname "$0")/../TestMedia" 2>/dev/null || { mkdir -p "$(dirname "$0")/../TestMedia"; cd "$(dirname "$0")/../TestMedia"; }
# Interlaced 16:9 PAL MPEG-2 with 5.1 AC3 in a DVD program stream.
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=720x576:rate=25" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000" -f lavfi -i "sine=frequency=880:sample_rate=48000" \
  -filter_complex "[0:v]setfield=tff[v];[1][2][1][2][1][2]amerge=inputs=6,channelmap=channel_layout=5.1[a]" \
  -map "[v]" -map "[a]" -t 20 -c:v mpeg2video -b:v 6M -g 12 -flags +ildct+ilme -aspect 16:9 \
  -c:a ac3 -b:a 384k -f dvd sample_pal_ac3.mpg
# 1080p H.264 + AAC transport stream.
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1920x1080:rate=30000/1001" \
  -f lavfi -i "sine=frequency=300:sample_rate=48000" -t 15 -c:v libx264 -g 30 -c:a aac -f mpegts sample_h264.ts
# A DVD title split into two VOB files at a byte boundary (timestamps continue across files).
size=$(stat -f %z sample_pal_ac3.mpg)
half=$(( (size / 2 / 2048) * 2048 ))
head -c $half sample_pal_ac3.mpg > VTS_01_1.VOB
tail -c +$((half + 1)) sample_pal_ac3.mpg > VTS_01_2.VOB
echo "Test media written to $(pwd)"
