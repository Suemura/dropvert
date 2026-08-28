#!/bin/bash
# 静的チェックをまとめて実行する。検査のみで、ビルド・変換・削除には一切関与しない。
#   使い方: ./lint.sh
#
# 未インストールの shfmt / shellcheck は該当の層を SKIP して続行する (exit 0 のまま)。
# 導入は: brew install shellcheck shfmt
# (語順が不自然なのはコメント先頭語 shellcheck が directive 扱いされるため。
#  CLAUDE.md「注意点」参照)
# osacompile / swiftc はこのプロジェクトの開発に必須なので、欠けていれば NG。
set -u

here=$(cd "$(dirname "$0")" && pwd)
shell_files=(
	"$here/convert.sh"
	"$here/run.sh"
	"$here/build.sh"
	"$here/lint.sh"
	"$here/tests/run.sh"
)

fail=0
ok() { printf 'OK    %s\n' "$1"; }
ng() {
	printf 'NG    %s\n' "$1"
	fail=1
}
skip() { printf 'SKIP  %s\n' "$1"; }

# コマンドを実行し、終了コードで OK / NG を 1 行報告する。
# チェック自体の出力 (エラー・diff) はそのまま流す。
run_check() {
	local name=$1
	shift
	if "$@"; then
		ok "$name"
	else
		ng "$name"
	fi
}

# 1. bash -n — shellcheck が SKIP の環境でも構文だけは常に担保する。
# ただし bash 3.2 の「set -u 下の空配列展開」は bash -n では検出できない
# (実行して初めて落ちる)。CLAUDE.md「注意点」参照。
for f in "${shell_files[@]}"; do
	# 表示はリポジトリ相対にする (run.sh と tests/run.sh を取り違えないため)
	run_check "bash -n ${f#"$here"/}" bash -n "$f"
done

# 2. shellcheck (未インストールなら SKIP)
if command -v shellcheck >/dev/null 2>&1; then
	run_check "shellcheck" shellcheck "${shell_files[@]}"
else
	skip "shellcheck (brew install shellcheck shfmt)"
fi

# 3. shfmt (未インストールなら SKIP)。--diff は表示のみで書き換えない。
if command -v shfmt >/dev/null 2>&1; then
	run_check "shfmt --diff" shfmt --diff "${shell_files[@]}"
else
	skip "shfmt (brew install shellcheck shfmt)"
fi

# 4. AppleScript の構文チェック
run_check "osacompile Dropvert.applescript" \
	osacompile -o /dev/null "$here/Dropvert.applescript"

# 5. JXA の構文チェック。osacompile は JXA もコンパイルできるため node に依存しない
# (ESLint は $ / ObjC のグローバル定義が必要でオーバーキル)
run_check "osacompile -l JavaScript trash.js" \
	osacompile -l JavaScript -o /dev/null "$here/trash.js"

# 6. Swift の型チェック。ビルドより速く、.app を作り直さずに検証できる。
# swiftc のフォールバックは build.sh と同じ: xcode-select が Xcode を指していて
# ライセンス未同意だと /usr/bin/swiftc も xcrun も落ちるため、Command Line Tools の
# swiftc に -sdk を明示して切り替える。swiftc_sdk の展開が ${arr[@]+"${arr[@]}"} なのは
# bash 3.2 の set -u では空配列の "${arr[@]}" が unbound variable になるため。
swiftc_bin=$(command -v swiftc || true)
swiftc_sdk=()
if [ -z "$swiftc_bin" ] || ! "$swiftc_bin" -version >/dev/null 2>&1; then
	swiftc_bin=/Library/Developer/CommandLineTools/usr/bin/swiftc
	swiftc_sdk=(-sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk)
fi
# 2 つの .swift はどちらもトップレベルにコードを持つ独立したプログラムなので、
# 1 回の呼び出しにまとめず 1 ファイルずつ型チェックする。
if [ -x "$swiftc_bin" ]; then
	for f in "$here/Prefs.swift" "$here/Trim.swift"; do
		run_check "swiftc -typecheck ${f##*/}" \
			"$swiftc_bin" ${swiftc_sdk[@]+"${swiftc_sdk[@]}"} -typecheck "$f"
	done
else
	ng "swiftc が見つかりません (xcode-select --install)"
fi

# 7. バージョン番号の整合。VERSION が唯一の出どころで、Homebrew cask の雛形が
# それを写している。bundle identifier が 3 箇所に散って黙って不一致になった
# 前例があるため (CLAUDE.md「設定」参照)、注意書きではなく機械で止める。
check_version() {
	local version_file="$here/VERSION" cask="$here/packaging/Casks/dropvert.rb"
	if [ ! -f "$version_file" ]; then
		echo "VERSION がありません" >&2
		return 1
	fi
	local version
	version=$(head -n 1 "$version_file" | tr -d '[:space:]')
	if ! printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
		echo "VERSION が SemVer ではありません: '$version'" >&2
		return 1
	fi
	if [ ! -f "$cask" ]; then
		echo "cask の雛形がありません: $cask" >&2
		return 1
	fi
	local cask_version
	cask_version=$(sed -n 's/^ *version "\([^"]*\)".*/\1/p' "$cask" | head -n 1)
	if [ "$cask_version" != "$version" ]; then
		echo "cask の version ($cask_version) が VERSION ($version) と一致しません" >&2
		return 1
	fi
}
run_check "VERSION と cask の整合" check_version

if [ "$fail" -ne 0 ]; then
	echo "lint: NG があります" >&2
	exit 1
fi
echo "lint: すべて OK"
