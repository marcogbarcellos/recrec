#!/bin/zsh
# usage: quality.sh outdir WxH refdir -> PSNR(Y)/SSIM per config at t=5,15,45 vs rendered reference (exactly one frame compared)
dir=$1; res=$2; refdir=${3:-$1}
printf "%-28s %4s %8s %8s %8s %9s\n" config t "PSNR-Y" "PSNR-av" "SSIM" "size"
for t in 5 15 45; do
  ref=$refdir/ref_${t}s_${res}.png
  [ -f "$ref" ] || continue
  for f in $dir/*_${res}.mp4; do
    name=$(basename $f .mp4); name=${name%_$res}
    out=$(ffmpeg -nostats -v info -i "$f" -i "$ref" -lavfi "[1:v]scale=out_color_matrix=bt709:out_range=tv,format=yuv420p[ref];[0:v]select='gte(t\,$t)',trim=end_frame=1,setpts=PTS-STARTPTS,format=yuv420p[v];[v][ref]psnr" -f null - 2>&1 | grep "PSNR")
    y=$(echo "$out" | grep -o "y:[0-9.]*" | head -1 | cut -d: -f2)
    avg=$(echo "$out" | grep -o "average:[0-9.]*" | head -1 | cut -d: -f2)
    s=$(ffmpeg -nostats -v info -i "$f" -i "$ref" -lavfi "[1:v]scale=out_color_matrix=bt709:out_range=tv,format=yuv420p[ref];[0:v]select='gte(t\,$t)',trim=end_frame=1,setpts=PTS-STARTPTS,format=yuv420p[v];[v][ref]ssim" -f null - 2>&1 | grep -o "All:[0-9.]*" | cut -d: -f2)
    size=$(stat -f %z "$f")
    printf "%-28s %3ss %8.2f %8.2f %8.4f %7.2fMB\n" $name $t "$y" "$avg" "$s" $(echo "$size/1048576" | bc -l)
  done
done
