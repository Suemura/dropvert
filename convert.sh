#!/bin/bash
# 1ファイルを指定の形式に変換する。
#   使い方: convert.sh <入力ファイル> <品質: 0-100 または lossless> [出力形式]
#   出力形式: webp (既定) / avif / jpeg / png
#   出力(stdout): 成功=生成したファイルのパス / 対象外=SKIP / 失敗=FAIL:理由
# 元ファイルの削除は呼び出し側(droplet)が担当する。
set -u

src="${1:-}"
q="${2:-85}"
fmt=$(printf '%s' "${3:-webp}" | tr '[:upper:]' '[:lower:]')

if [ -z "$src" ]; then echo "FAIL:引数なし"; exit 0; fi
if [ -d "$src" ]; then echo "FAIL:フォルダはスキップ"; exit 0; fi
if [ ! -f "$src" ]; then echo "FAIL:ファイルが存在しない"; exit 0; fi

# 品質の防御。呼び出し側の検証をすり抜けても既定値で動かす。
case "$q" in
lossless) ;;
'' | *[!0-9]*) q=85 ;;
*) [ "$q" -gt 100 ] && q=85 ;;
esac

# 出力形式ごとの取り決め:
#   outext    生成するファイルの拡張子
#   skipexts  入力がこれらの拡張子なら変換せず SKIP (同じ形式への変換は無意味)
case "$fmt" in
webp)
	outext="webp"
	skipexts=" webp "
	;;
avif)
	outext="avif"
	skipexts=" avif "
	;;
jpeg)
	outext="jpg"
	skipexts=" jpg jpeg jpe "
	;;
png)
	outext="png"
	skipexts=" png "
	;;
*)
	echo "FAIL:未知の出力形式"
	exit 0
	;;
esac

dir=$(dirname "$src")
base=$(basename "$src")
name="${base%.*}"
ext=$(printf '%s' "${base##*.}" | tr '[:upper:]' '[:lower:]')

case "$skipexts" in
*" $ext "*)
	echo "SKIP"
	exit 0
	;;
esac
if [ ! -w "$dir" ]; then echo "FAIL:書き込み権限なし"; exit 0; fi

tmpdir=""
out=""
cleanup() {
	[ -n "$tmpdir" ] && rm -rf "$tmpdir"
	# 名前を予約しただけで中身を書けなかった出力は残さない
	if [ -n "$out" ] && [ -e "$out" ] && [ ! -s "$out" ]; then rm -f "$out"; fi
	return 0
}
trap cleanup EXIT

# 出力名の衝突回避。
# 並列実行では複数プロセスが同時に同じ名前を掴みうるため、noclobber で予約する。
# noclobber 下の `: > file` は既存ファイルに対して必ず失敗するので、
# 予約に成功したプロセスだけがその名前の所有者になる。
i=0
while [ "$i" -le 999 ]; do
	if [ "$i" -eq 0 ]; then
		cand="$dir/$name.$outext"
	else
		cand="$dir/$name-$i.$outext"
	fi
	if (set -o noclobber; : >"$cand") 2>/dev/null; then
		out="$cand"
		break
	fi
	i=$((i + 1))
done
if [ -z "$out" ]; then
	echo "FAIL:出力名を確保できない"
	exit 0
fi

err=""
case "$fmt" in
webp)
	# WebP だけは sips が書き出せない (読み込み専用)。cwebp / gif2webp が担当する。
	if [ "$q" = "lossless" ]; then
		qflag=(-lossless)
	else
		qflag=(-q "$q")
	fi
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
	;;
avif | jpeg | png)
	# macOS 標準の sips が書き出せる形式。外部コマンドは要らない。
	# 品質は formatOptions で渡す。PNG は可逆なので指定しない (sips も無視する)。
	# JPEG / AVIF に真の可逆は無いため、lossless は最高品質 (best) として扱う。
	# 配列は必ず 1 要素以上にしておく (bash 3.2 の set -u では空配列の展開が
	# unbound variable になるため)。
	sipsopts=(-s format "$fmt")
	if [ "$fmt" = "avif" ]; then
		# AVIF は formatOptions に 100 / best を渡すと sips が Error 13 で書き出しに
		# 失敗する (99 までは成功する)。可逆圧縮も無いので、最高品質は 99 で表す。
		# sips には formatOptions lossless もあるが、実測では 99 よりずっと小さい
		# ファイルになり可逆ではないため使わない。
		# 数値比較 (-eq) は使わない。"050" のような先頭ゼロを 8 進数として解釈するため。
		if [ "$q" = "lossless" ] || [ "$q" = "100" ]; then
			q=99
		fi
		sipsopts+=(-s formatOptions "$q")
	elif [ "$fmt" = "jpeg" ]; then
		# JPEG に可逆圧縮は無い。lossless は最高品質として扱う。
		if [ "$q" = "lossless" ]; then
			sipsopts+=(-s formatOptions best)
		else
			sipsopts+=(-s formatOptions "$q")
		fi
	fi
	# PNG はもともと可逆なので品質を渡さない (sips も無視する)。
	# 予約した $out に直接書かせない。sips が途中で失敗すると壊れた非 0 バイトの
	# ファイルが残り、呼び出し側が「変換成功」と誤認して元ファイルを削除しうる。
	tmpdir=$(mktemp -d -t dropvert)
	mid="$tmpdir/out.$outext"
	if err=$(sips "${sipsopts[@]}" "$src" --out "$mid" 2>&1) && [ -s "$mid" ]; then
		# 一時ディレクトリは $TMPDIR にあり、出力先と別のファイルシステムのことがある
		# (外付けディスクなど)。その場合 mv は copy + unlink になり、途中で失敗すると
		# 中途半端な出力が残る。サイズだけを見る後段の判定が「成功」と誤認して元ファイルを
		# 削除しないよう、失敗したら予約したファイルごと消す。
		if ! mv -f "$mid" "$out"; then
			rm -f "$out"
			err="出力を書き込めない"
		fi
	elif [ -z "$err" ]; then
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
