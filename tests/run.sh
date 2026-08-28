#!/bin/bash
# convert.sh (1 ファイルの変換) の自動テスト。
#   使い方: ./tests/run.sh
#   DROPVERT_TEST_KEEP=1 を付けると失敗の調査用に作業ディレクトリを残す。
#
# 素材も出力もすべて mktemp -d した作業ディレクトリの中だけに作る。
# 利用者の実ファイルは絶対に触らない (変換に成功した元ファイルは、アプリ経由なら
# ゴミ箱へ移動される。テストが実ファイルを掴むと取り返しがつかない)。
#
# run.sh 層 (並列実行とサマリの契約) のテストはここには無い。
set -u

repo=$(cd "$(dirname "$0")/.." && pwd)
conv="$repo/convert.sh"

# 変換に要るコマンドが無ければ、テストだけ緑になる余地を作らずに落とす。
# 複数の名前をまとめて command -v に渡さないこと。macOS の bash 3.2 は
# 「どれか 1 つでも見つかれば 0」を返す。
for tool in sips cwebp gif2webp; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "テストに必要なコマンドがありません: $tool (brew install webp)" >&2
		exit 1
	fi
done

work=$(mktemp -d -t dropvert-test)
cleanup() {
	[ -n "$work" ] || return 0
	# 書き込み権限のテストで 555 にしたディレクトリも消せるようにする
	chmod -R u+w "$work" 2>/dev/null
	if [ "${DROPVERT_TEST_KEEP:-0}" = "1" ]; then
		echo "作業ディレクトリを残しました: $work"
	else
		rm -rf "$work"
	fi
	return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------- 素材

# 1 枚の PNG を起点に、sips で各形式へ派生させる (heic / tiff / gif / jpeg は
# どれも sips が書き出せる)。240px に落とすのは、並列テストで 60 回変換しても
# 数秒で終わるようにするため。
assets="$work/assets"
mkdir -p "$assets"
base="$assets/base.png"

wallpaper=/System/Library/CoreServices/DefaultDesktop.heic
if [ -f "$wallpaper" ]; then
	sips -s format png -Z 240 "$wallpaper" --out "$base" >/dev/null 2>&1 || true
fi
if [ ! -s "$base" ]; then
	found=$(find /System/Library/Wallpapers -type f -name '*.heic' 2>/dev/null | head -1)
	if [ -n "$found" ]; then
		sips -s format png -Z 240 "$found" --out "$base" >/dev/null 2>&1 || true
	fi
fi
if [ ! -s "$base" ]; then
	# 最終手段。8x8 の PNG (メタデータなし) を埋め込んである。標準の壁紙が
	# 見つからない環境でもテストを走らせるため。
	seed='iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAVUlEQVR42g3JMQHAMAgAMJRUCUpQwjkVKEEJipYjVyLii0dSNMNyxPMkRTMsR6QnKZphOaI8SdEMyxHtSYpmWI4YT1I0w3LEepKiGZYjzpMUzbDcfT+z3FSBJ+XiEgAAAABJRU5ErkJggg=='
	printf '%s' "$seed" | base64 -D >"$assets/seed.png" 2>/dev/null
	sips -s format png -z 135 240 "$assets/seed.png" --out "$base" >/dev/null 2>&1 || true
fi
if [ ! -s "$base" ]; then
	echo "テスト素材を作れませんでした" >&2
	exit 1
fi

# 派生素材。1 つでも作れなければ、素材が欠けたまま緑になるので落とす。
make_asset() {
	# <出力パス> <sips の format>
	sips -s format "$2" "$base" --out "$1" >/dev/null 2>&1
	if [ ! -s "$1" ]; then
		echo "テスト素材を作れませんでした: $1" >&2
		exit 1
	fi
}
make_asset "$assets/base.jpg" jpeg
make_asset "$assets/base.tiff" tiff
make_asset "$assets/base.gif" gif
make_asset "$assets/base.heic" heic
if ! cwebp -quiet -q 85 "$base" -o "$assets/base.webp" 2>/dev/null || [ ! -s "$assets/base.webp" ]; then
	echo "テスト素材を作れませんでした: base.webp" >&2
	exit 1
fi

# ---------------------------------------------------------------- 判定

passes=0
fails=0
case_name=""
case_dir=""
case_failed=0

# ケースの失敗を記録する。1 ケースに複数あっても数えるのは 1 回。
bad() {
	if [ "$case_failed" -eq 0 ]; then
		printf 'FAIL  %s\n' "$case_name"
	fi
	case_failed=1
	printf '      %s\n' "$1"
}

assert_eq() {
	# <期待> <実際> <説明>
	[ "$1" = "$2" ] && return 0
	bad "$3: 期待 [$1] / 実際 [$2]"
}

assert_prefix() {
	# <期待する接頭辞> <実際> <説明>
	case "$2" in
	"$1"*) return 0 ;;
	esac
	bad "$3: [$1] で始まるはずが [$2]"
}

# 拡張子ではなく中身を見る。壊れた出力を「成功」と数えないため。
assert_image() {
	# <パス> <期待する形式>
	if [ ! -f "$1" ]; then
		bad "出力が無い: $1"
		return 0
	fi
	if [ ! -s "$1" ]; then
		bad "出力が 0 バイト: $1"
		return 0
	fi
	local got
	got=$(sips -g format "$1" 2>/dev/null | awk '/format:/ {print $2}')
	[ "$got" = "$2" ] || bad "中身が $2 でない: $1 は [$got]"
	return 0
}

# 残骸が残っていないこと・元ファイルが消えていないことを 1 本で見る。
assert_dir_exactly() {
	# <ディレクトリ> <期待するファイル名...>
	local dir=$1
	shift
	local want got
	want=$(printf '%s\n' "$@" | sort)
	got=$(ls -A "$dir" | sort)
	if [ "$want" != "$got" ]; then
		bad "ディレクトリの中身が違う: $dir"
		bad "  期待: $(printf '%s' "$want" | tr '\n' ' ')"
		bad "  実際: $(printf '%s' "$got" | tr '\n' ' ')"
	fi
	return 0
}

# ケース専用のディレクトリに素材を置く。ケース同士が混ざらず、
# そのディレクトリを丸ごと見れば残骸の有無が分かる。
setup() {
	# <素材のファイル名...> — assets から case_dir へコピーする
	mkdir -p "$case_dir"
	local a
	for a in "$@"; do
		cp "$assets/$a" "$case_dir/$a"
	done
	return 0
}

# ---------------------------------------------------------------- ケース

case_png_to_webp() {
	setup base.png
	out=$("$conv" "$case_dir/base.png" 85)
	assert_eq "$case_dir/base.webp" "$out" "出力パス"
	assert_image "$case_dir/base.webp" webp
	assert_dir_exactly "$case_dir" base.png base.webp
}

case_jpeg_to_webp() {
	setup base.jpg
	out=$("$conv" "$case_dir/base.jpg" 85)
	assert_eq "$case_dir/base.webp" "$out" "出力パス"
	assert_image "$case_dir/base.webp" webp
}

# 拡張子の大文字小文字を区別しないこと
case_uppercase_jpg_to_webp() {
	setup base.jpg
	mv "$case_dir/base.jpg" "$case_dir/BASE.JPG"
	out=$("$conv" "$case_dir/BASE.JPG" 85)
	assert_eq "$case_dir/BASE.webp" "$out" "出力パス"
	assert_image "$case_dir/BASE.webp" webp
}

case_tiff_to_webp() {
	setup base.tiff
	out=$("$conv" "$case_dir/base.tiff" 85)
	assert_eq "$case_dir/base.webp" "$out" "出力パス"
	assert_image "$case_dir/base.webp" webp
}

# GIF は gif2webp が担当する (cwebp では読めない)
case_gif_to_webp() {
	setup base.gif
	out=$("$conv" "$case_dir/base.gif" 85)
	assert_eq "$case_dir/base.webp" "$out" "出力パス"
	assert_image "$case_dir/base.webp" webp
}

# HEIC は sips で PNG に中間変換してから cwebp に渡す経路
case_heic_to_webp() {
	setup base.heic
	out=$("$conv" "$case_dir/base.heic" 85)
	assert_eq "$case_dir/base.webp" "$out" "出力パス"
	assert_image "$case_dir/base.webp" webp
	assert_dir_exactly "$case_dir" base.heic base.webp
}

case_output_avif() {
	setup base.png
	out=$("$conv" "$case_dir/base.png" 85 avif)
	assert_eq "$case_dir/base.avif" "$out" "出力パス"
	assert_image "$case_dir/base.avif" avif
}

case_output_jpeg() {
	setup base.png
	out=$("$conv" "$case_dir/base.png" 85 jpeg)
	assert_eq "$case_dir/base.jpg" "$out" "出力パス"
	assert_image "$case_dir/base.jpg" jpeg
}

case_output_png() {
	setup base.jpg
	out=$("$conv" "$case_dir/base.jpg" 85 png)
	assert_eq "$case_dir/base.png" "$out" "出力パス"
	assert_image "$case_dir/base.png" png
}

# lossless / 100 / 0。AVIF の 100 と lossless は 99 に丸める経路を通る
# (sips は formatOptions 100 / best を Error 13 で拒む)。
case_quality_extremes() {
	setup base.png
	local q fmt ext out
	for fmt in webp avif; do
		case "$fmt" in
		webp) ext=webp ;;
		avif) ext=avif ;;
		esac
		for q in lossless 100 0; do
			mkdir -p "$case_dir/$fmt-$q"
			cp "$assets/base.png" "$case_dir/$fmt-$q/base.png"
			out=$("$conv" "$case_dir/$fmt-$q/base.png" "$q" "$fmt")
			assert_eq "$case_dir/$fmt-$q/base.$ext" "$out" "$fmt 品質 $q の出力パス"
			assert_image "$case_dir/$fmt-$q/base.$ext" "$fmt"
		done
	done
	rm -f "$case_dir/base.png"
}

# 呼び出し側の検証をすり抜けた不正な品質でも、既定値で変換できること
case_quality_invalid() {
	setup base.png
	local q out
	for q in abc 150 ""; do
		mkdir -p "$case_dir/q"
		cp "$assets/base.png" "$case_dir/q/base.png"
		out=$("$conv" "$case_dir/q/base.png" "$q")
		assert_eq "$case_dir/q/base.webp" "$out" "品質 [$q] の出力パス"
		assert_image "$case_dir/q/base.webp" webp
		rm -rf "$case_dir/q"
	done
	rm -f "$case_dir/base.png"
}

# 入力が出力形式と同じなら変換しない (トリムが無効なので必ず SKIP)
case_skip_same_format() {
	setup base.webp base.jpg base.png
	cp "$case_dir/base.jpg" "$case_dir/base.jpeg"
	cp "$case_dir/base.jpg" "$case_dir/base.jpe"
	assert_eq "SKIP" "$("$conv" "$case_dir/base.webp" 85 webp)" "webp 入力 → webp"
	assert_eq "SKIP" "$("$conv" "$case_dir/base.jpg" 85 jpeg)" "jpg 入力 → jpeg"
	assert_eq "SKIP" "$("$conv" "$case_dir/base.jpeg" 85 jpeg)" "jpeg 入力 → jpeg"
	assert_eq "SKIP" "$("$conv" "$case_dir/base.jpe" 85 jpeg)" "jpe 入力 → jpeg"
	assert_eq "SKIP" "$("$conv" "$case_dir/base.png" 85 png)" "png 入力 → png"
	# SKIP なので新しいファイルは 1 つも作られない
	assert_dir_exactly "$case_dir" base.webp base.jpg base.jpeg base.jpe base.png
}

case_unknown_format() {
	setup base.png
	assert_eq "FAIL:未知の出力形式" "$("$conv" "$case_dir/base.png" 85 tiff)" "未知の出力形式"
	assert_dir_exactly "$case_dir" base.png
}

case_bad_arguments() {
	assert_eq "FAIL:引数なし" "$("$conv")" "引数なし"
	assert_eq "FAIL:ファイルが存在しない" "$("$conv" "$case_dir/no-such-file.png" 85)" "存在しないパス"
}

# フォルダをドロップしても消さない・触らないこと
case_folder_is_rejected() {
	mkdir -p "$case_dir/album"
	cp "$assets/base.png" "$case_dir/album/inside.png"
	assert_prefix "FAIL:" "$("$conv" "$case_dir/album" 85)" "フォルダ"
	assert_dir_exactly "$case_dir" album
	assert_dir_exactly "$case_dir/album" inside.png
}

# 壊れたファイルは FAIL を返し、予約した出力名の残骸を残さないこと。
# ここが崩れると、変換できていないのに元ファイルが削除される事故になる。
case_broken_file_leaves_nothing() {
	mkdir -p "$case_dir"
	echo bad >"$case_dir/broken.png"
	assert_prefix "FAIL:" "$("$conv" "$case_dir/broken.png" 85)" "壊れた PNG"
	assert_dir_exactly "$case_dir" broken.png
}

case_tricky_file_names() {
	setup base.png
	local name out
	for name in "with space.png" "日本語.png" "絵文字🎨.png"; do
		cp "$case_dir/base.png" "$case_dir/$name"
		out=$("$conv" "$case_dir/$name" 85)
		assert_eq "$case_dir/${name%.png}.webp" "$out" "[$name] の出力パス"
		assert_image "$case_dir/${name%.png}.webp" webp
	done
}

# 同じ出力名を狙う入力が同じディレクトリにある場合、採番で退避すること
case_output_name_collision() {
	setup base.png base.tiff
	local first second
	first=$("$conv" "$case_dir/base.png" 85)
	second=$("$conv" "$case_dir/base.tiff" 85)
	assert_eq "$case_dir/base.webp" "$first" "1 件目の出力パス"
	assert_eq "$case_dir/base-1.webp" "$second" "2 件目の出力パス"
	assert_image "$case_dir/base.webp" webp
	assert_image "$case_dir/base-1.webp" webp
	assert_dir_exactly "$case_dir" base.png base.tiff base.webp base-1.webp
}

# 同じ入力を多重に並列変換しても、出力名が衝突せず残骸も出ないこと。
# 採番は noclobber による予約で守られている。ここが崩れると、複数の
# プロセスが同じ名前を掴んで変換結果を上書きし合う。
case_parallel_same_input() {
	setup base.png
	local out_list uniq total zero webps
	out_list="$case_dir/stdout.txt"
	seq 1 60 | xargs -P 12 -I{} "$conv" "$case_dir/base.png" 85 >"$out_list"
	total=$(grep -c . "$out_list")
	assert_eq "60" "$total" "出力の行数"
	if grep -qE '^(FAIL|SKIP)' "$out_list"; then
		bad "並列変換に失敗した行がある: $(grep -E '^(FAIL|SKIP)' "$out_list" | head -1)"
	fi
	uniq=$(sort -u "$out_list" | grep -c .)
	assert_eq "60" "$uniq" "ユニークな出力パスの数"
	webps=$(find "$case_dir" -name '*.webp' | grep -c .)
	assert_eq "60" "$webps" "生成された webp の数"
	zero=$(find "$case_dir" -name '*.webp' -size 0 | grep -c . || true)
	assert_eq "0" "$zero" "0 バイトの残骸の数"
}

# 余白トリムを有効にしても、Trim バイナリが無いソースツリーでは
# 契約が変わらないこと (トリムできない事情はすべて「付けない」に倒れる)。
case_trim_flag_without_binary() {
	setup base.png base.webp
	if [ -x "$repo/Trim" ]; then
		bad "リポジトリに Trim バイナリがある。このケースの前提が崩れている"
		return 0
	fi
	out=$("$conv" "$case_dir/base.png" 85 webp 1)
	assert_eq "$case_dir/base-1.webp" "$out" "トリム有効でも通常どおり変換する"
	assert_image "$case_dir/base-1.webp" webp
	assert_eq "SKIP" "$("$conv" "$case_dir/base.webp" 85 webp 1)" "同形式はトリムできなければ SKIP"
}

# 書き込めないディレクトリでは、変換を試みずに理由を返すこと
case_readonly_directory() {
	if [ "$(id -u)" -eq 0 ]; then
		# root では権限の判定が素通りするので確かめられない
		return 0
	fi
	setup base.png
	chmod 555 "$case_dir"
	assert_eq "FAIL:書き込み権限なし" "$("$conv" "$case_dir/base.png" 85)" "書き込み権限なし"
	chmod u+w "$case_dir"
	assert_dir_exactly "$case_dir" base.png
}

# ---------------------------------------------------------------- 実行

cases=(
	case_png_to_webp
	case_jpeg_to_webp
	case_uppercase_jpg_to_webp
	case_tiff_to_webp
	case_gif_to_webp
	case_heic_to_webp
	case_output_avif
	case_output_jpeg
	case_output_png
	case_quality_extremes
	case_quality_invalid
	case_skip_same_format
	case_unknown_format
	case_bad_arguments
	case_folder_is_rejected
	case_broken_file_leaves_nothing
	case_tricky_file_names
	case_output_name_collision
	case_parallel_same_input
	case_trim_flag_without_binary
	case_readonly_directory
)

for c in "${cases[@]}"; do
	case_name=$c
	case_dir="$work/$c"
	case_failed=0
	mkdir -p "$case_dir"
	"$c"
	if [ "$case_failed" -eq 0 ]; then
		printf 'PASS  %s\n' "$case_name"
		passes=$((passes + 1))
	else
		printf '      作業ディレクトリ: %s\n' "$case_dir"
		fails=$((fails + 1))
	fi
done

printf '\n%d passed, %d failed\n' "$passes" "$fails"
if [ "$fails" -ne 0 ]; then
	echo "調査するには DROPVERT_TEST_KEEP=1 を付けて実行してください" >&2
	exit 1
fi
