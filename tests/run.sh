#!/bin/bash
# convert.sh (1 ファイルの変換) と run.sh (並列実行と結果の集約) の自動テスト。
#   使い方: ./tests/run.sh
#   DROPVERT_TEST_KEEP=1 を付けると失敗の調査用に作業ディレクトリを残す。
#
# 素材も出力もすべて mktemp -d した作業ディレクトリの中だけに作る。
# 利用者の実ファイルは絶対に触らない (変換に成功した元ファイルは、アプリ経由なら
# ゴミ箱へ移動される。テストが実ファイルを掴むと取り返しがつかない)。
#
# ケースは層ごとに 2 つの節に分かれている (convert.sh 層 / run.sh 層)。
# AppleScript 層や trash.js 層を足してさらに大きくなるようなら、
# そのときにファイルの分割を考えること。
set -u

repo=$(cd "$(dirname "$0")/.." && pwd)
conv="$repo/convert.sh"

# 変換に要るコマンドが無ければ、テストだけ緑になる余地を作らずに落とす。
# 複数の名前をまとめて command -v に渡さないこと。macOS の bash 3.2 は
# 「どれか 1 つでも見つかれば 0」を返す。
for tool in sips cwebp gif2webp webpmux; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "テストに必要なコマンドがありません: $tool (brew install webp)" >&2
		exit 1
	fi
done

work=$(mktemp -d -t dropvert-test) || exit 1
# 空のまま進むと、この下の "$work/assets" が /assets になってしまう
[ -n "$work" ] || exit 1
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
p3profile="/System/Library/ColorSync/Profiles/Display P3.icc"

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
# 広色域の素材。ICC プロファイルを引き継げているかを見るのに使う。
if [ -f "$p3profile" ]; then
	sips -m "$p3profile" "$base" --out "$assets/p3.png" >/dev/null 2>&1 || true
	if [ -s "$assets/p3.png" ]; then
		sips -s format tiff "$assets/p3.png" --out "$assets/p3.tiff" >/dev/null 2>&1 || true
	fi
fi

make_asset "$assets/base.jpg" jpeg
make_asset "$assets/base.tiff" tiff
make_asset "$assets/base.gif" gif
make_asset "$assets/base.heic" heic
if ! cwebp -quiet -q 85 "$base" -o "$assets/base.webp" 2>/dev/null || [ ! -s "$assets/base.webp" ]; then
	echo "テスト素材を作れませんでした: base.webp" >&2
	exit 1
fi
# アニメーション WebP。同じコマ 2 枚でよい (見たいのは VP8X のフラグだけ)。
if ! webpmux -frame "$assets/base.webp" +100 -frame "$assets/base.webp" +100 \
	-o "$assets/anim.webp" >/dev/null 2>&1 || [ ! -s "$assets/anim.webp" ]; then
	echo "テスト素材を作れませんでした: anim.webp" >&2
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
	local want got entry names
	want=$(printf '%s\n' "$@" | sort)
	# ls ではなく glob で集める。名前に空白や絵文字が入っても壊れない。
	names=""
	for entry in "$dir"/* "$dir"/.[!.]*; do
		[ -e "$entry" ] || continue
		names="$names${entry##*/}
"
	done
	got=$(printf '%s' "$names" | sort)
	if [ "$want" != "$got" ]; then
		bad "ディレクトリの中身が違う: $dir"
		bad "  期待: $(printf '%s' "$want" | tr '\n' ' ')"
		bad "  実際: $(printf '%s' "$got" | tr '\n' ' ')"
	fi
	return 0
}

# ------------------------------------------------ run.sh 層のためのヘルパ

# run.sh のサマリ行のタグ。ここに無いものが stdout に出たら契約違反。
summary_tags='TMP|CONVERTED|SKIPPED|UNPROCESSED|LIST|RENAME|FAIL'

# ディレクトリ直下のファイル数。ls -l | wc -l と違って
# ディレクトリが無い場合も 0 を返す。
count_files() {
	# <ディレクトリ>
	local entry n=0
	for entry in "$1"/*; do
		[ -e "$entry" ] || continue
		n=$((n + 1))
	done
	printf '%s' "$n"
}

mklist() {
	# <出力先> <パス...> — 1 行 1 パスの入力リストを書く
	local out=$1
	shift
	printf '%s\n' "$@" >"$out"
	return 0
}

# サマリ行から値を取り出す。<KEY> の行が無ければ空を返す。
sum() {
	# <run.sh の stdout> <KEY>
	awk -F'\t' -v k="$2" '$1 == k {print $2; exit}' "$1"
}

sum_lines() {
	# <run.sh の stdout> <KEY> — その KEY の行数
	awk -F'\t' -v k="$2" '$1 == k {n++} END {print n + 0}' "$1"
}

# サマリ行以外が混ざっていないこと。convert.sh の出力や
# シェルのエラーが漏れると、呼び出し側のパースが狂う。
assert_summary_only() {
	# <run.sh の stdout>
	local strays
	strays=$(grep -vcE "^($summary_tags)"$'\t' "$1" || true)
	if [ "$strays" != "0" ]; then
		bad "サマリ以外の行が stdout に混ざっている: $1"
		bad "  $(grep -vE "^($summary_tags)"$'\t' "$1" | head -3 | tr '\n' ' ')"
	fi
	return 0
}

# NUL 区切りのファイル (LIST / RENAME の中身) を並べ替えた 1 つの文字列にする。
# ディレクトリが違うもの同士を比べたいときは basename だけにする。
# 並び順は LC_ALL=C で固定する。ロケールによって日本語や絵文字の
# 位置が変わると、期待値が環境依存になる。
nul_paths() {
	# <NUL 区切りのファイル> [basename]
	if [ "${2:-}" = "basename" ]; then
		tr '\0' '\n' <"$1" | sed 's|.*/||' | LC_ALL=C sort | tr '\n' ' '
	else
		tr '\0' '\n' <"$1" | LC_ALL=C sort | tr '\n' ' '
	fi
}

# 余白トリムが効く状態を作る。convert.sh は自分と同じディレクトリの Trim を
# 見るので、コピーと矩形を返すだけのスタブを 1 つのディレクトリに揃える。
# run.sh も同じ場所に置けば $here/convert.sh がこのコピーを指す。
make_trim_sandbox() {
	# <ディレクトリ> — convert.sh (と run.sh) のコピー + Trim スタブを置く
	mkdir -p "$1"
	cp "$conv" "$1/convert.sh"
	cp "$repo/run.sh" "$1/run.sh"
	printf '#!/bin/sh\necho "10 10 200 100 240 135"\n' >"$1/Trim"
	chmod +x "$1/Trim"
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
	assert_dir_exactly "$case_dir" base.jpg base.webp
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
	# 中間変換の一時ファイルが漏れていないことも見る
	assert_dir_exactly "$case_dir" base.tiff base.webp
}

# GIF は gif2webp が担当する (cwebp では読めない)
case_gif_to_webp() {
	setup base.gif
	out=$("$conv" "$case_dir/base.gif" 85)
	assert_eq "$case_dir/base.webp" "$out" "出力パス"
	assert_image "$case_dir/base.webp" webp
	assert_dir_exactly "$case_dir" base.gif base.webp
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
	assert_dir_exactly "$case_dir" base.png base.avif
}

case_output_jpeg() {
	setup base.png
	out=$("$conv" "$case_dir/base.png" 85 jpeg)
	assert_eq "$case_dir/base.jpg" "$out" "出力パス"
	assert_image "$case_dir/base.jpg" jpeg
	assert_dir_exactly "$case_dir" base.png base.jpg
}

case_output_png() {
	setup base.jpg
	out=$("$conv" "$case_dir/base.jpg" 85 png)
	assert_eq "$case_dir/base.png" "$out" "出力パス"
	assert_image "$case_dir/base.png" png
	assert_dir_exactly "$case_dir" base.jpg base.png
}

# ICC プロファイルを落とさないこと。直行経路 (PNG) と sips 中間変換の経路
# (TIFF) の両方で見る。中間変換の側で -metadata icc を付け忘れると、
# Display P3 の写真 (iPhone の HEIC など) が sRGB 扱いの WebP になる。
case_icc_profile_is_kept() {
	if [ ! -s "$assets/p3.png" ] || [ ! -s "$assets/p3.tiff" ]; then
		# Display P3 のプロファイルが無い環境では確かめられない
		return 0
	fi
	setup p3.png p3.tiff
	local got
	for name in p3.png p3.tiff; do
		"$conv" "$case_dir/$name" 85 >/dev/null
		got=$(sips -g profile "$case_dir/${name%.*}.webp" 2>/dev/null | awk -F': ' '/profile:/ {print $2}')
		assert_eq "Display P3" "$got" "[$name] の出力が ICC を保っている"
		rm -f "$case_dir/${name%.*}.webp"
	done
}

# lossless / 100 / 0。AVIF の 100 と lossless は 99 に丸める経路を通る
# (sips は formatOptions 100 / best を Error 13 で拒む)。
case_quality_extremes() {
	# 品質ごとにサブディレクトリを作って撒くので、case_dir 直下には何も置かない
	local q fmt out
	# webp と avif は拡張子が形式名と同じなので、そのまま使える。
	for fmt in webp avif; do
		for q in lossless 100 0; do
			mkdir -p "$case_dir/$fmt-$q"
			cp "$assets/base.png" "$case_dir/$fmt-$q/base.png"
			out=$("$conv" "$case_dir/$fmt-$q/base.png" "$q" "$fmt")
			assert_eq "$case_dir/$fmt-$q/base.$fmt" "$out" "$fmt 品質 $q の出力パス"
			assert_image "$case_dir/$fmt-$q/base.$fmt" "$fmt"
		done
	done
}

# 呼び出し側の検証をすり抜けた不正な品質でも、既定値で変換できること
case_quality_invalid() {
	local q out
	for q in abc 150 ""; do
		mkdir -p "$case_dir/q"
		cp "$assets/base.png" "$case_dir/q/base.png"
		out=$("$conv" "$case_dir/q/base.png" "$q")
		assert_eq "$case_dir/q/base.webp" "$out" "品質 [$q] の出力パス"
		assert_image "$case_dir/q/base.webp" webp
		rm -rf "$case_dir/q"
	done
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

# アニメーション WebP を同じ形式へ書き戻さないこと。
# この経路は sips で PNG に中間変換するため 1 フレームに潰れる。潰れた出力を
# 「変換成功」と扱うと、アニメーションが失われたまま元ファイルがゴミ箱へ行く。
#
# この判定に届くのは「同じ形式 + 削れる余白あり」のときだけで、余白の測定には
# Trim が要る。ソースツリーには Trim が無いので、矩形を返すだけのスタブを置いた
# コピーを作って呼ぶ (convert.sh は自分と同じディレクトリの Trim を見る)。
# スタブを置かないと手前の「同じ形式は SKIP」で止まり、判定を壊しても
# 気づけないテストになる。
case_animated_webp_is_skipped() {
	setup anim.webp base.webp
	local sandbox out
	sandbox="$case_dir/bin"
	make_trim_sandbox "$sandbox"

	# まずスタブが効いていることを確かめる。静止画の webp は「余白あり」と
	# 見なされて再エンコードされるはず。ここが SKIP なら、下の判定は
	# アニメーションとは無関係に通ってしまう。
	out=$("$sandbox/convert.sh" "$case_dir/base.webp" 85 webp 1)
	assert_eq "$case_dir/base-1.webp" "$out" "(前提) 静止画 webp は余白があれば再エンコードされる"

	# 本題。同じ条件でもアニメーションなら SKIP でなければならない。
	assert_eq "SKIP" "$("$sandbox/convert.sh" "$case_dir/anim.webp" 85 webp 1)" \
		"アニメーション webp はトリム有効でも SKIP"
	# トリムが無効なら、そもそも同じ形式なので SKIP
	assert_eq "SKIP" "$("$conv" "$case_dir/anim.webp" 85 webp)" "アニメーション webp → webp"
	assert_dir_exactly "$case_dir" anim.webp base.webp base-1.webp bin
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
	# 採番も残骸の後始末も、この手の名前で壊れやすい
	assert_dir_exactly "$case_dir" base.png \
		"with space.png" "with space.webp" \
		"日本語.png" "日本語.webp" \
		"絵文字🎨.png" "絵文字🎨.webp"
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
	mkdir -p "$case_dir/outs"
	# 60 プロセスの stdout を 1 つのファイルへ束ねない。行が混ざったとき、
	# それを convert.sh の採番のバグと見分けられなくなるため。
	# (子プロセスの bash が展開する位置引数なので、シングルクォートは意図的)
	# shellcheck disable=SC2016
	seq 1 60 | xargs -P 12 -I{} /bin/bash -c \
		'"$1" "$2" 85 >"$3/{}"' _ "$conv" "$case_dir/base.png" "$case_dir/outs"
	cat "$case_dir"/outs/* >"$out_list"
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

# ------------------------------------------------------ ケース (run.sh 層)
#
# ここから下は run.sh の契約を見る。stdout のサマリ行と作業ディレクトリの
# 中身は AppleScript 側の分岐が依存していて、崩れると「失敗したファイルを
# 削除する」事故になる。

# サマリ行の形。成功・SKIP・失敗が混ざった状態で、各行が契約どおりに
# 出ているかをまとめて見る。
case_run_summary_shape() {
	setup base.png base.jpg base.webp
	local out list
	out="$case_dir/out.txt"
	echo bad >"$case_dir/broken.png"
	mklist "$case_dir/in.list" \
		"$case_dir/base.png" "$case_dir/base.jpg" "$case_dir/base.webp" \
		"$case_dir/broken.png" "$case_dir/no-such-file.png"
	"$repo/run.sh" "$case_dir/in.list" 85 1 "$case_dir/wd" >"$out" 2>"$case_dir/err.txt"

	assert_eq "1" "$(sum_lines "$out" TMP)" "TMP は 1 行"
	assert_eq "$case_dir/wd" "$(sum "$out" TMP)" "TMP は渡した作業ディレクトリ"
	assert_eq "1" "$(sum_lines "$out" CONVERTED)" "CONVERTED は 1 行"
	assert_eq "1" "$(sum_lines "$out" SKIPPED)" "SKIPPED は 1 行"
	assert_eq "1" "$(sum_lines "$out" UNPROCESSED)" "UNPROCESSED は 1 行"
	assert_eq "2" "$(sum "$out" CONVERTED)" "変換できた件数"
	assert_eq "1" "$(sum "$out" SKIPPED)" "対象外の件数"
	assert_eq "0" "$(sum "$out" UNPROCESSED)" "未処理の件数"
	# 壊れたファイルと存在しないパスで 1 行ずつ
	assert_eq "2" "$(sum_lines "$out" FAIL)" "FAIL の行数"
	# FAIL はタブ区切り 3 フィールドで、2 番目はファイル名 (パスではない)
	assert_eq "3" "$(awk -F'\t' '$1 == "FAIL" {print NF; exit}' "$out")" "FAIL のフィールド数"
	assert_eq "broken.png no-such-file.png" \
		"$(awk -F'\t' '$1 == "FAIL" {print $2}' "$out" | sort | tr '\n' ' ' | sed 's/ $//')" \
		"FAIL のファイル名"
	if awk -F'\t' '$1 == "FAIL" && $3 == "" {found = 1} END {exit !found}' "$out"; then
		bad "理由が空の FAIL 行がある"
	fi

	# LIST は成功した「元ファイル」を NUL 区切りで並べたもの。
	# 変換後のパス (.webp) が入っていたら、呼び出し側が変換結果をゴミ箱へ送る。
	assert_eq "1" "$(sum_lines "$out" LIST)" "LIST は 1 行"
	list=$(sum "$out" LIST)
	assert_eq "base.jpg base.png " "$(nul_paths "$list" basename)" "LIST の中身は元ファイル"
	assert_eq "0" "$(sum_lines "$out" RENAME)" "リネーム対象が無ければ RENAME は出ない"
	assert_summary_only "$out"
	assert_eq "" "$(cat "$case_dir/err.txt")" "stderr に何も出ない"
}

# 成功が 0 件なら LIST 行そのものが出ないこと
case_run_no_success_no_list() {
	setup base.webp
	local out
	out="$case_dir/out.txt"
	mklist "$case_dir/in.list" "$case_dir/base.webp"
	"$repo/run.sh" "$case_dir/in.list" 85 1 "$case_dir/wd" >"$out" 2>/dev/null
	assert_eq "0" "$(sum "$out" CONVERTED)" "変換できた件数"
	assert_eq "1" "$(sum "$out" SKIPPED)" "対象外の件数"
	assert_eq "0" "$(sum_lines "$out" LIST)" "LIST は出ない"
	assert_summary_only "$out"
}

# 作業ディレクトリの契約。results/ の件数は進行度表示が数えているので、
# 「完了した件数」と一致していなければならない。
case_run_workdir_contract() {
	setup base.png base.jpg base.webp
	local out wd done_count
	out="$case_dir/out.txt"
	wd="$case_dir/wd"
	echo bad >"$case_dir/broken.png"
	mklist "$case_dir/in.list" \
		"$case_dir/base.png" "$case_dir/base.jpg" \
		"$case_dir/base.webp" "$case_dir/broken.png"
	"$repo/run.sh" "$case_dir/in.list" 85 0 "$wd" >"$out" 2>/dev/null

	if [ ! -e "$wd/exit" ]; then
		bad "exit が作られていない (呼び出し側の待ちループが抜けられない)"
	fi
	done_count=$(count_files "$wd/results")
	assert_eq "4" "$done_count" "results/ の件数 = 完了件数"
	assert_eq "4" "$(count_files "$wd/inputs")" "inputs/ の件数 = 入力件数"
	# parts/ から results/ へ mv し切っていること。残っていると
	# results/ が「開始した件数」ではなく途中の数を指してしまう。
	assert_eq "0" "$(count_files "$wd/parts")" "parts/ に残骸が無い"
}

# 早い段階で return する経路でも exit が残ること (trap の担保)
case_run_exit_is_always_created() {
	mkdir -p "$case_dir"
	: >"$case_dir/empty.list"
	"$repo/run.sh" "$case_dir/empty.list" 85 1 "$case_dir/wd-empty" >/dev/null 2>&1
	if [ ! -e "$case_dir/wd-empty/exit" ]; then
		bad "空リストのとき exit が作られていない"
	fi
	"$repo/run.sh" "$case_dir/nope.list" 85 1 "$case_dir/wd-missing" >/dev/null 2>&1
	if [ ! -e "$case_dir/wd-missing/exit" ]; then
		bad "リストが無いとき exit が作られていない"
	fi
}

case_run_empty_list() {
	mkdir -p "$case_dir"
	local out
	out="$case_dir/out.txt"
	# 0 バイトのリストと、空行だけのリスト。どちらも 0 件として扱う。
	: >"$case_dir/empty.list"
	printf '\n\n\n' >"$case_dir/blank.list"
	for name in empty blank; do
		"$repo/run.sh" "$case_dir/$name.list" 85 1 "$case_dir/wd-$name" >"$out" 2>/dev/null
		assert_eq "0" "$(sum "$out" CONVERTED)" "[$name] CONVERTED"
		assert_eq "0" "$(sum "$out" SKIPPED)" "[$name] SKIPPED"
		assert_eq "0" "$(sum "$out" UNPROCESSED)" "[$name] UNPROCESSED"
		assert_eq "0" "$(sum_lines "$out" LIST)" "[$name] LIST は出ない"
		assert_eq "0" "$(sum_lines "$out" FAIL)" "[$name] FAIL は出ない"
		assert_summary_only "$out"
	done
}

# 入力リストが見つからない経路。ここだけは CONVERTED / SKIPPED /
# UNPROCESSED が出ない (run.sh が TMP と FAIL だけ出して終わる)。
# AppleScript 側が 3 つのカウンタを 0 で初期化してからパースするので実害は
# 無い。現行の挙動をそのまま固定する。
case_run_missing_list() {
	mkdir -p "$case_dir"
	local out status
	out="$case_dir/out.txt"
	status=0
	"$repo/run.sh" "$case_dir/nope.list" 85 1 "$case_dir/wd" >"$out" 2>/dev/null || status=$?
	assert_eq "0" "$status" "終了コード (呼び出し側は落ちない前提)"
	assert_eq "1" "$(sum_lines "$out" TMP)" "TMP は 1 行"
	assert_eq "1" "$(sum_lines "$out" FAIL)" "FAIL は 1 行"
	assert_eq "入力リストが見つからない" \
		"$(awk -F'\t' '$1 == "FAIL" {print $3; exit}' "$out")" "FAIL の理由"
	assert_eq "0" "$(sum_lines "$out" LIST)" "LIST は出ない"
	assert_summary_only "$out"
}

# 起動前に cancel を置くと、1 件も変換せずに全件 UNPROCESSED になること
case_run_cancel_before_start() {
	setup base.png base.jpg
	local out wd
	out="$case_dir/out.txt"
	wd="$case_dir/wd"
	mkdir -p "$wd"
	: >"$wd/cancel"
	mklist "$case_dir/in.list" "$case_dir/base.png" "$case_dir/base.jpg"
	"$repo/run.sh" "$case_dir/in.list" 85 1 "$wd" >"$out" 2>/dev/null

	assert_eq "0" "$(sum "$out" CONVERTED)" "変換できた件数"
	assert_eq "0" "$(sum "$out" SKIPPED)" "対象外の件数"
	assert_eq "2" "$(sum "$out" UNPROCESSED)" "未処理の件数"
	assert_eq "0" "$(sum_lines "$out" LIST)" "LIST は出ない"
	# 未着手のファイルは変換もされない (出力が 1 つも増えていない)
	assert_dir_exactly "$case_dir" base.png base.jpg in.list out.txt wd
	assert_summary_only "$out"
}

# 途中で cancel を置くと、着手済みだけが CONVERTED / LIST に入り、
# 未着手は変換されずに UNPROCESSED へ回ること。
# 実際の変換だと所要時間が読めないので、待ち時間が決まっている
# convert.sh のスタブを使う。
case_run_cancel_midway() {
	mkdir -p "$case_dir/bin" "$case_dir/src"
	local out wd i waited converted unprocessed outputs
	out="$case_dir/out.txt"
	wd="$case_dir/wd"
	# 0.3 秒かけて「変換」し、出力のパスを返すスタブ
	cat >"$case_dir/bin/convert.sh" <<'STUB'
#!/bin/bash
sleep 0.3
out="${1%.*}.webp"
echo made >"$out"
echo "$out"
STUB
	chmod +x "$case_dir/bin/convert.sh"
	cp "$repo/run.sh" "$case_dir/bin/run.sh"

	i=1
	: >"$case_dir/in.list"
	while [ "$i" -le 6 ]; do
		cp "$assets/base.png" "$case_dir/src/f$i.png"
		echo "$case_dir/src/f$i.png" >>"$case_dir/in.list"
		i=$((i + 1))
	done

	"$case_dir/bin/run.sh" "$case_dir/in.list" 85 1 "$wd" >"$out" 2>/dev/null &
	# 1 件目が終わったら cancel を置く。results/ が「完了した件数」を
	# 表しているからこの手順が成り立つ (作業ディレクトリの契約そのもの)。
	waited=0
	while [ "$(count_files "$wd/results")" -lt 1 ]; do
		sleep 0.1
		waited=$((waited + 1))
		if [ "$waited" -gt 200 ]; then
			bad "20 秒待っても results/ が増えなかった"
			break
		fi
	done
	# results/ が「開始した件数」ではなく「完了した件数」であることを、
	# 走っている最中に確かめる。並列度 1 でスタブは 0.3 秒かけるので、
	# 2 件目は着手済みでも出力はまだ書いていない。ここが 1 でなければ
	# 進捗ウィンドウの「N / 全件」が着手数を指していることになる。
	assert_eq "1" "$(find "$case_dir/src" -name '*.webp' | grep -c . || true)" \
		"results/ が 1 件の時点で完了した変換も 1 件"
	: >"$wd/cancel"
	wait

	converted=$(sum "$out" CONVERTED)
	unprocessed=$(sum "$out" UNPROCESSED)
	if [ "$converted" -lt 1 ]; then
		bad "着手済みが 1 件も CONVERTED になっていない"
	fi
	if [ "$unprocessed" -lt 1 ]; then
		bad "未着手が 1 件も UNPROCESSED になっていない"
	fi
	assert_eq "6" "$((converted + unprocessed + $(sum "$out" SKIPPED)))" "合計は入力件数"
	# 未着手は変換されない。スタブが作った出力の数が CONVERTED と一致する。
	outputs=$(find "$case_dir/src" -name '*.webp' | grep -c . || true)
	assert_eq "$converted" "$outputs" "変換された件数 = 生成された出力の数"
	# 件数は NUL の数で数える。空白を含む名前でも狂わない。
	assert_eq "$converted" "$(tr -cd '\0' <"$(sum "$out" LIST)" | wc -c | tr -d ' ')" \
		"LIST の件数 = CONVERTED"
}

# 並列度 1 と hw.ncpu で結果が変わらないこと。
# 同じディレクトリで走らせると採番が絡むので、別の場所に同じ素材を撒く。
case_run_parallel_matches_sequential() {
	mkdir -p "$case_dir"
	local par summary1 summary0 s
	for par in 1 0; do
		local d="$case_dir/p$par"
		mkdir -p "$d"
		cp "$assets/base.png" "$d/a.png"
		cp "$assets/base.jpg" "$d/b.jpg"
		cp "$assets/base.heic" "$d/c.heic"
		cp "$assets/base.webp" "$d/d.webp"
		echo bad >"$d/e.png"
		mklist "$d/in.list" "$d/a.png" "$d/b.jpg" "$d/c.heic" "$d/d.webp" "$d/e.png"
		"$repo/run.sh" "$d/in.list" 85 "$par" "$d/wd" >"$d/out.txt" 2>/dev/null
		# TMP と LIST はパスが毎回変わるので、値ではなく件数だけを見る。
		# FAIL は理由まで比べる (並列のときだけ理由が変わる退行を捕まえる)。
		# 理由には入力の絶対パスが入っていて p1 / p0 で必ず食い違うので、
		# ディレクトリの部分だけ落としてから比べる。
		s=$(grep -E '^(CONVERTED|SKIPPED|UNPROCESSED)'$'\t' "$d/out.txt" | sort)
		s="$s
$(awk -F'\t' '$1 == "FAIL" {gsub(/\/[^ ]*\//, "", $3); print $1 "\t" $2 "\t" $3}' "$d/out.txt" | sort)
LIST:$(nul_paths "$(sum "$d/out.txt" LIST)" basename)"
		if [ "$par" = "1" ]; then summary1=$s; else summary0=$s; fi
	done
	assert_eq "$summary1" "$summary0" "並列度 1 と hw.ncpu で結果が一致"
}

# 空白・日本語・絵文字を含む名前が LIST の NUL 区切りで壊れないこと
case_run_tricky_file_names() {
	mkdir -p "$case_dir"
	local out list name
	out="$case_dir/out.txt"
	: >"$case_dir/in.list"
	for name in "with space.png" "日本語.png" "絵文字🎨.png"; do
		cp "$assets/base.png" "$case_dir/$name"
		echo "$case_dir/$name" >>"$case_dir/in.list"
	done
	"$repo/run.sh" "$case_dir/in.list" 85 0 "$case_dir/wd" >"$out" 2>/dev/null
	assert_eq "3" "$(sum "$out" CONVERTED)" "変換できた件数"
	list=$(sum "$out" LIST)
	assert_eq "with space.png 日本語.png 絵文字🎨.png " \
		"$(nul_paths "$list" basename)" "LIST の中身"
}

# RENAME の契約。同じ形式のまま余白だけ削ると、元ファイルが出力名を
# 占有しているので出力は採番される。呼び出し側がゴミ箱へ移したあとで
# 元の名前へ戻せるよう、run.sh は「出力パス」と「リネーム先」の組を返す。
case_run_rename_contract() {
	setup base.png
	local out sandbox renlist
	out="$case_dir/out.txt"
	sandbox="$case_dir/bin"
	make_trim_sandbox "$sandbox"
	mklist "$case_dir/in.list" "$case_dir/base.png"

	# 第 5 引数が出力形式、第 6 引数が余白トリム
	"$sandbox/run.sh" "$case_dir/in.list" 85 1 "$case_dir/wd" png 1 >"$out" 2>/dev/null

	# (前提) スタブが効いて再エンコードが起きていること。ここが 0 なら
	# 下の RENAME の判定は「出なくて当然」で素通りしてしまう。
	assert_eq "1" "$(sum "$out" CONVERTED)" "(前提) 同形式でも余白があれば変換される"
	assert_eq "1" "$(sum_lines "$out" RENAME)" "RENAME は 1 行"
	renlist=$(sum "$out" RENAME)
	# 「出力パス」「リネーム先」のペア。出力は採番されて base-1.png になる。
	assert_eq "base-1.png base.png " "$(nul_paths "$renlist" basename)" "RENAME の中身"
	assert_eq "$case_dir/base-1.png"$'\n'"$case_dir/base.png" \
		"$(tr '\0' '\n' <"$renlist" | sed '/^$/d')" "RENAME はペアで並ぶ"
	# LIST には元ファイルが入る (ゴミ箱へ移す対象)
	assert_eq "base.png " "$(nul_paths "$(sum "$out" LIST)" basename)" "LIST の中身"
	assert_summary_only "$out"
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
	case_icc_profile_is_kept
	case_quality_extremes
	case_quality_invalid
	case_skip_same_format
	case_animated_webp_is_skipped
	case_unknown_format
	case_bad_arguments
	case_folder_is_rejected
	case_broken_file_leaves_nothing
	case_tricky_file_names
	case_output_name_collision
	case_parallel_same_input
	case_trim_flag_without_binary
	case_readonly_directory
	case_run_summary_shape
	case_run_no_success_no_list
	case_run_workdir_contract
	case_run_exit_is_always_created
	case_run_empty_list
	case_run_missing_list
	case_run_cancel_before_start
	case_run_cancel_midway
	case_run_parallel_matches_sequential
	case_run_tricky_file_names
	case_run_rename_contract
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
