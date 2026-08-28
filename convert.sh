#!/bin/bash
# 1ファイルを指定の形式に変換する。
#   使い方: convert.sh <入力ファイル> <品質: 0-100 または lossless> [出力形式] [余白トリム]
#   出力形式: webp (既定) / avif / jpeg / png
#   余白トリム: 1 で単色余白を切り落とす / 0 (既定) でそのまま
#   出力(stdout): 成功=生成したファイルのパス / 対象外=SKIP / 失敗=FAIL:理由
# 元ファイルの削除は呼び出し側(droplet)が担当する。
set -u

src="${1:-}"
q="${2:-85}"
fmt=$(printf '%s' "${3:-webp}" | tr '[:upper:]' '[:lower:]')
trim="${4:-0}"
case "$trim" in
1) ;;
*) trim=0 ;;
esac

# 余白を測る Trim は同じディレクトリに置かれている (bundle では Resources/)。
here=$(cd "$(dirname "$0")" && pwd)
trimbin="$here/Trim"

if [ -z "$src" ]; then
	echo "FAIL:引数なし"
	exit 0
fi
if [ -d "$src" ]; then
	echo "FAIL:フォルダはスキップ"
	exit 0
fi
if [ ! -f "$src" ]; then
	echo "FAIL:ファイルが存在しない"
	exit 0
fi

# 品質の防御。呼び出し側の検証をすり抜けても既定値で動かす。
case "$q" in
lossless) ;;
'' | *[!0-9]*) q=85 ;;
*) [ "$q" -gt 100 ] && q=85 ;;
esac

# 出力形式ごとの取り決め:
#   outext    生成するファイルの拡張子
#   skipexts  入力がこれらの拡張子なら同じ形式とみなす。変換しても意味がないので
#             原則 SKIP するが、余白トリムが有効で削れる余白があるときだけ、
#             切り出しのために再エンコードする
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

# 出力形式と同じ形式の入力。変換しても意味がないので原則スキップするが、
# 余白トリムが有効で削れる余白があるときだけ、切り出しのために再エンコードする。
# 判定は余白を測ったあと (この下) で行う。
sameformat=0
case "$skipexts" in
*" $ext "*) sameformat=1 ;;
esac

# アニメーション WebP を同じ形式へ書き戻さない。sips が 1 フレームに潰すため、
# アニメーションが失われた出力で元ファイルがゴミ箱へ行ってしまう。
# (別の形式への変換は従来どおり。1 フレームになるのは元からの挙動)
#
# 判定はヘッダの決まった位置だけを見る。ANIM チャンクを探す形にすると、
# 手前に ICC プロファイル (ICCP) が入っているファイルで位置が後ろへずれ、
# アニメーションを静止画と読み違える。
#   0-3   "RIFF"     8-11  "WEBP"    12-15 "VP8X" (拡張形式のときだけ)
#   20    フラグ (0x02 が立っていればアニメーション)
# VP8X が無ければ単一フレームなので、その時点で静止画と分かる。
is_animated_webp() {
	local hdr sig flags
	hdr=$(od -An -tx1 -N 21 "$1" 2>/dev/null | tr -d ' \n')
	[ "${#hdr}" -ge 42 ] || return 1
	sig="${hdr:24:8}"
	flags="${hdr:40:2}"
	[ "$sig" = "56503858" ] || return 1 # "VP8X"
	[ $((0x$flags & 2)) -ne 0 ]
}
if [ "$sameformat" = "1" ] && [ "$ext" = "webp" ] && is_animated_webp "$src"; then
	echo "SKIP"
	exit 0
fi

# 余白の測定。切り出しそのものは後段のエンコーダ (cwebp / sips) に任せるので、
# ここで作るのは渡すオプションだけ。中間ファイルは作らない。
#
# トリムできない事情 (Trim が無い・読めない形式・余白なし・矩形が不正) は
# すべて「オプションを付けない」に倒す。変換の失敗には昇格させないので、
# 呼び出し側から見た契約は何も変わらない。
#
# 出力名を noclobber で予約する前に済ませる。予約したまま外部プロセスの終了を
# 待つ時間を作らない。Trim は元ファイルを読むだけで副作用がない。
#
# GIF は対象外。gif2webp に crop オプションが無く、フレームごとに余白が
# 異なりうるため、静止画に限る。
cropwebp=()
cropsips=()
if [ "$trim" = "1" ] && [ "$ext" != "gif" ] && [ -x "$trimbin" ]; then
	rect=$("$trimbin" "$src" 2>/dev/null) || rect=""
	# "x y w h 元の幅 元の高さ" 以外 (NONE / FAIL: / 想定外) はトリムなし。
	# 単語に割るあいだだけ glob を止める (理由の文字列が展開されないように)。
	set -f
	# 単語分割は意図的で、6 個の位置パラメータに割るのが目的。クォートすると
	# 1 個の文字列になって壊れる。glob は上の set -f で止めてある。
	# shellcheck disable=SC2086
	set -- $rect
	set +f
	if [ "$#" -eq 6 ]; then
		rx="$1" ry="$2" rw="$3" rh="$4" rW="$5" rH="$6"
		valid=1
		for n in "$rx" "$ry" "$rw" "$rh" "$rW" "$rH"; do
			case "$n" in
			'' | *[!0-9]*) valid=0 ;;
			esac
		done
		# sips は範囲外の --cropOffset をエラーにせず黙ってクランプする。
		# 矩形が壊れたまま渡すと、別の絵になった出力で「変換成功」となり
		# 元ファイルがゴミ箱へ行く。渡す前にここで必ず確かめる。
		if [ "$valid" = "1" ] &&
			[ "$rw" -gt 0 ] && [ "$rh" -gt 0 ] &&
			[ $((rx + rw)) -le "$rW" ] && [ $((ry + rh)) -le "$rH" ] &&
			{ [ "$rw" -ne "$rW" ] || [ "$rh" -ne "$rH" ]; }; then
			cropwebp=(-crop "$rx" "$ry" "$rw" "$rh")
			# sips の --cropOffset は「Y X」の順で、左上を原点として扱う
			# (sips --help の "offsetY offsetH" という表記は当てにならない)。
			cropsips=(-c "$rh" "$rw" --cropOffset "$ry" "$rx")
		fi
	fi
fi

# 同じ形式への変換は、削れる余白があるときだけ意味がある。
# 無いなら従来どおりスキップする (トリムが無効なときも必ずここに来る)。
if [ "$sameformat" = "1" ] && [ "${#cropwebp[@]}" -eq 0 ]; then
	echo "SKIP"
	exit 0
fi
if [ ! -w "$dir" ]; then
	echo "FAIL:書き込み権限なし"
	exit 0
fi

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
	if (
		set -o noclobber
		: >"$cand"
	) 2>/dev/null; then
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
	png | jpg | jpeg | jpe)
		err=$(cwebp -quiet "${qflag[@]}" ${cropwebp[@]+"${cropwebp[@]}"} -metadata icc "$src" -o "$out" 2>&1) || true
		;;
	gif)
		if command -v gif2webp >/dev/null 2>&1; then
			err=$(gif2webp -quiet "${qflag[@]}" "$src" -o "$out" 2>&1) || true
		else
			err="gif2webp が無い (brew install webp)"
		fi
		;;
	*)
		# heic/avif/bmp/psd/jxl/tiff など: sips で PNG に中間変換してから cwebp
		#
		# TIFF もここを通す。macOS のツール (sips や Preview) が書き出す TIFF は
		# タイル形式で、cwebp が読めない ("TIFF tile dimension (512 x 512) is
		# too large.")。sips を通せばタイルでもストリップでも読める。
		#
		# 切り出しは cwebp ではなく前段の sips に付ける。矩形は元ファイルを
		# 測って得たものなので、それを読むツールに渡すのが確実で、中間変換が
		# 向きを変えた場合でもずれた絵にならない。
		tmpdir=$(mktemp -d -t dropvert)
		err=$(sips -s format png ${cropsips[@]+"${cropsips[@]}"} "$src" --out "$tmpdir/mid.png" 2>&1) || true
		if [ -s "$tmpdir/mid.png" ]; then
			# -metadata icc は中間変換でも要る。sips は ICC プロファイルを
			# 中間 PNG に引き継ぐので、ここで渡せば出力にも乗る。付け忘れると
			# Display P3 の HEIC (iPhone の写真) が sRGB 扱いの WebP になる。
			err=$(cwebp -quiet "${qflag[@]}" -metadata icc "$tmpdir/mid.png" -o "$out" 2>&1) || true
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
	if ! err=$(sips "${sipsopts[@]}" ${cropsips[@]+"${cropsips[@]}"} "$src" --out "$mid" 2>&1); then
		: # err には sips のエラーメッセージが入っている
	elif [ ! -s "$mid" ]; then
		# sips は成功したことになっているが出力が無い。err には成功時の標準出力
		# (入力パスと出力パス) が入っているので、そのまま理由にすると紛らわしい。
		err="未対応の画像形式"
	# 一時ディレクトリは $TMPDIR にあり、出力先と別のファイルシステムのことがある
	# (外付けディスクなど)。その場合 mv は copy + unlink になり、途中で失敗すると
	# 中途半端な出力が残る。サイズだけを見る後段の判定が「成功」と誤認して元ファイルを
	# 削除しないよう、失敗したら予約したファイルごと消す。
	elif ! mv -f "$mid" "$out"; then
		rm -f "$out"
		err="出力を書き込めない"
	fi
	;;
esac

if [ ! -s "$out" ]; then
	rm -f "$out"
	echo "FAIL:$(printf '%s' "${err:-変換失敗}" | head -1)"
	exit 0
fi

echo "$out"
