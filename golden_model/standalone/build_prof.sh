#!/bin/bash
# 编译"独立跑黄金模型"的指令画像工具 (不开 RTL 仿真).
#   usage: ./build_prof.sh [out]      # 默认 /tmp/gmprof
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
GM="$(dirname "$HERE")"
OUT="${1:-/tmp/gmprof}"

gcc -O2 -w -std=gnu89 \
    -I "$GM/include" -I "$GM" \
    "$GM"/*.c "$GM"/stage/*.c "$GM"/peripheral/*.c "$HERE"/main_prof.c \
    -o "$OUT"

echo "built: $OUT"
