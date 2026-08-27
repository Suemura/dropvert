#!/bin/bash
# 複数ファイルの変換を並列実行し、結果を集約する。
#   使い方: run.sh <入力リストファイル> <品質: 0-100 または lossless> [並列度] [作業ディレクトリ]
#
# 入力リストファイルは 1 行 1 パス（改行区切り）。
# 並列度は省略・0・数値以外のとき hw.ncpu を使う。1 を指定すれば逐次実行。
# 作業ディレクトリを渡すとそこを使う（呼び出し側が進行度を見張るため）。省略時は mktemp。
#
# 出力(stdout): タブ区切りのサマリ行のみ。
#   TMP<TAB><作業ディレクトリ>            必ず 1 行。呼び出し側が使い終わったら削除する
#   CONVERTED<TAB><件数>                  必ず 1 行
#   SKIPPED<TAB><件数>                    必ず 1 行
#   LIST<TAB><パス>                       成功が 1 件以上のときのみ。成功した「元ファイル」の
#                                         パスを NUL 区切りで並べたファイル
#   FAIL<TAB><ファイル名><TAB><理由>      失敗 1 件につき 1 行
#
# 作業ディレクトリ内のファイルは呼び出し側との取り決め:
#   results/    1 ファイル完了ごとに 1 件増える。数えれば完了件数になる（進行度表示用）
#   cancel      呼び出し側が作ると、未着手のファイルを変換せず SKIP として終える
#   exit        処理を終えると必ず作られる。呼び出し側の待ちループの終了条件
#
# 実際の変換は convert.sh が 1 ファイルずつ担当する（stdout 契約はそちらを参照）。
# 元ファイルの削除はここでも行わない。呼び出し側(droplet)が LIST を使って行う。
set -u

listfile="${1:-}"
q="${2:-85}"
par="${3:-0}"
workdir="${4:-}"

here=$(cd "$(dirname "$0")" && pwd)
converter="$here/convert.sh"

# 作業ディレクトリは最初に確定させる。呼び出し側は起動直後から results/ を数えるため、
# 存在しない状態を長く作らない。
if [ -n "$workdir" ] && mkdir -p "$workdir" 2>/dev/null; then
	tmp="$workdir"
else
	tmp=$(mktemp -d -t dropvert)
fi
printf 'TMP\t%s\n' "$tmp"
mkdir -p "$tmp/inputs" "$tmp/parts" "$tmp/results"

# どんな終わり方をしても exit を残す。これが無いと呼び出し側の待ちループが抜けられない。
mark_done() { : >"$tmp/exit" 2>/dev/null || true; }
trap mark_done EXIT

if [ ! -f "$listfile" ]; then
	printf 'FAIL\t-\t入力リストが見つからない\n'
	exit 0
fi

# 並列度の決定
case "$par" in
'' | *[!0-9]*) par=0 ;;
esac
if [ "$par" -eq 0 ]; then
	par=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
fi

# 入力に連番を振り、1 ファイル 1 パスで書き出す。
# 結果も同じ連番で受け取るため、完了順に関係なく入力と結果が 1:1 で対応する。
# パイプへ並列に書き込ませないのは、行が混ざると「失敗したファイルを削除する」
# 事故につながるため。
total=0
while IFS= read -r line || [ -n "$line" ]; do
	[ -z "$line" ] && continue
	total=$((total + 1))
	printf '%s' "$line" >"$tmp/inputs/$(printf '%04d' "$total")"
done <"$listfile"

if [ "$total" -eq 0 ]; then
	printf 'CONVERTED\t0\nSKIPPED\t0\n'
	exit 0
fi

# 並列変換。結果は parts/ に書いてから results/ へ mv する。
# mv は同一ディレクトリ内でアトミックなので、results/ の件数は
# 「開始した件数」ではなく「完了した件数」になる（進行度がずれない）。
# cancel があれば変換せず SKIP を返す。中断でも「変換に失敗したファイル」を作らない。
seq 1 "$total" | xargs -P "$par" -I{} /bin/bash -c '
	idx=$(printf "%04d" "$1")
	if [ -e "$2/cancel" ]; then
		printf "SKIP" >"$2/parts/$idx"
	else
		src=$(cat "$2/inputs/$idx")
		"$3" "$src" "$4" >"$2/parts/$idx" 2>/dev/null
	fi
	mv -f "$2/parts/$idx" "$2/results/$idx"
' _ {} "$tmp" "$converter" "$q"

# 集約は逐次で行う（競合の余地をなくす）
converted=0
skipped=0
succlist="$tmp/succeeded.list"
: >"$succlist"

i=1
while [ "$i" -le "$total" ]; do
	idx=$(printf '%04d' "$i")
	i=$((i + 1))
	src=$(cat "$tmp/inputs/$idx")
	res=""
	[ -f "$tmp/results/$idx" ] && res=$(head -1 "$tmp/results/$idx")

	reason=""
	if [ -z "$res" ]; then
		reason="変換プロセスが異常終了"
	elif [ "$res" = "SKIP" ]; then
		skipped=$((skipped + 1))
	elif [ "${res#FAIL:}" != "$res" ]; then
		reason="${res#FAIL:}"
	elif [ ! -s "$res" ]; then
		# convert.sh は検証済みのパスしか返さないが、削除の直前なので念のため再確認する
		reason="出力ファイルを確認できない"
	else
		converted=$((converted + 1))
		printf '%s\0' "$src" >>"$succlist"
	fi

	if [ -n "$reason" ]; then
		printf 'FAIL\t%s\t%s\n' "$(basename "$src")" "$(printf '%s' "$reason" | tr '\t' ' ')"
	fi
done

printf 'CONVERTED\t%s\n' "$converted"
printf 'SKIPPED\t%s\n' "$skipped"
if [ "$converted" -gt 0 ]; then
	printf 'LIST\t%s\n' "$succlist"
fi
