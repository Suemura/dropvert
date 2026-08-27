#!/bin/bash
# 1ファイルを WebP に変換する。
#   使い方: convert.sh <入力ファイル> <品質: 0-100 または lossless>
#   出力(stdout): 成功=生成した .webp のパス / 対象外=SKIP / 失敗=FAIL:理由
# 元ファイルの削除は呼び出し側(droplet)が担当する。
set -u

src="${1:-}"
q="${2:-85}"

if [ -z "$src" ]; then echo "FAIL:引数なし"; exit 0; fi
if [ -d "$src" ]; then echo "FAIL:フォルダはスキップ"; exit 0; fi
if [ ! -f "$src" ]; then echo "FAIL:ファイルが存在しない"; exit 0; fi

dir=$(dirname "$src")
base=$(basename "$src")
name="${base%.*}"
ext=$(printf '%s' "${base##*.}" | tr '[:upper:]' '[:lower:]')

if [ "$ext" = "webp" ]; then echo "SKIP"; exit 0; fi
if [ ! -w "$dir" ]; then echo "FAIL:書き込み権限なし"; exit 0; fi

# 出力名の衝突回避
out="$dir/$name.webp"
i=1
while [ -e "$out" ]; do
	out="$dir/$name-$i.webp"
	i=$((i + 1))
done

if [ "$q" = "lossless" ]; then
	qflag=(-lossless)
else
	qflag=(-q "$q")
fi

tmpdir=""
cleanup() { [ -n "$tmpdir" ] && rm -rf "$tmpdir"; }
trap cleanup EXIT

err=""
case "$ext" in
png | jpg | jpeg | jpe | tif | tiff)
	err=$(cwebp -quiet "${qflag[@]}" -metadata icc "$src" -o "$out" 2>&1) || true
	;;
gif)
	if command -v gif2webp >/dev/null 2>&1; then
		err=$(gif2webp -quiet "${qflag[@]}" "$src" -o "$out" 2>&1) || true
	else
		err="gif2webp が無い (brew install webp)"
	fi
	;;
*)
	# heic/avif/bmp/psd/jxl など: sips で PNG に中間変換してから cwebp
	tmpdir=$(mktemp -d -t dropvert)
	err=$(sips -s format png "$src" --out "$tmpdir/mid.png" 2>&1) || true
	if [ -s "$tmpdir/mid.png" ]; then
		err=$(cwebp -quiet "${qflag[@]}" "$tmpdir/mid.png" -o "$out" 2>&1) || true
	else
		err="未対応の画像形式"
	fi
	;;
esac

if [ ! -s "$out" ]; then
	rm -f "$out"
	echo "FAIL:$(printf '%s' "${err:-変換失敗}" | head -1)"
	exit 0
fi

echo "$out"
