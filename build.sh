#!/bin/bash
# Dropvert.app をビルドする。
#   使い方: ./build.sh [出力先ディレクトリ]   (デフォルト: ~/Applications)
set -euo pipefail

src_dir=$(cd "$(dirname "$0")" && pwd)
dest_dir="${1:-$HOME/Applications}"
app="$dest_dir/Dropvert.app"

# バージョン番号の唯一の出どころ。Homebrew cask の雛形にも同じ値が書いてあり、
# ズレていないことは lint.sh が検査する (CLAUDE.md「ファイル構成と役割」の
# VERSION の項を参照)。plist に書き込むのはここだけなので、形式の検証もここで
# 行う (lint.sh を通さずに手で書き換えられても不正な値が入らないように)。
# 読み込みと検証は既存の .app を消す前に済ませる (壊さずに失敗して終わるため)。
version_file="$src_dir/VERSION"
if [ ! -f "$version_file" ]; then
	echo "VERSION が見つかりません: $version_file" >&2
	exit 1
fi
version=$(head -n 1 "$version_file" | tr -d '[:space:]')
if ! printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
	echo "VERSION が SemVer (x.y.z) ではありません: '$version'" >&2
	exit 1
fi

# Swift 製の同梱物 (設定ウィンドウ Prefs と、余白を測る Trim) を先にコンパイルする。
# 既存のアプリを消す前に済ませておけば、コンパイルに失敗しても手元のアプリを
# 壊さずに終われる。
#
# xcode-select が Xcode を指していてライセンス未同意の場合、/usr/bin/swiftc も
# xcrun も落ちる。Command Line Tools の swiftc は使えるが、xcrun 経由で SDK を
# 解決できないぶん -sdk を明示する必要がある。
swiftc_bin=$(command -v swiftc || true)
swiftc_sdk=()
if [ -z "$swiftc_bin" ] || ! "$swiftc_bin" -version >/dev/null 2>&1; then
	swiftc_bin=/Library/Developer/CommandLineTools/usr/bin/swiftc
	swiftc_sdk=(-sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk)
fi
if [ ! -x "$swiftc_bin" ]; then
	echo "swiftc が見つかりません。xcode-select --install を実行してください" >&2
	exit 1
fi

build_tmp=$(mktemp -d -t dropvert-build)
trap 'rm -rf "$build_tmp"' EXIT

# 配布用ではなくローカルビルドなので、universal 化はせずネイティブのみ。
# 配列の展開が ${arr[@]+"${arr[@]}"} なのは、bash 3.2 の set -u では
# 空配列の "${arr[@]}" が unbound variable になるため (swiftc がそのまま
# 使える環境では swiftc_sdk が空になる)。
"$swiftc_bin" ${swiftc_sdk[@]+"${swiftc_sdk[@]}"} -O -o "$build_tmp/Prefs" "$src_dir/Prefs.swift"
"$swiftc_bin" ${swiftc_sdk[@]+"${swiftc_sdk[@]}"} -O -o "$build_tmp/Trim" "$src_dir/Trim.swift"

mkdir -p "$dest_dir"
rm -rf "$app"

osacompile -o "$app" "$src_dir/Dropvert.applescript"

# スクリプトを bundle 内 Resources に同梱 (path to resource で参照される)
cp "$src_dir/convert.sh" "$app/Contents/Resources/convert.sh"
chmod +x "$app/Contents/Resources/convert.sh"
cp "$src_dir/run.sh" "$app/Contents/Resources/run.sh"
chmod +x "$app/Contents/Resources/run.sh"
cp "$src_dir/trash.js" "$app/Contents/Resources/trash.js"
cp "$build_tmp/Prefs" "$app/Contents/Resources/Prefs"
chmod +x "$app/Contents/Resources/Prefs"
# Trim は convert.sh が自分と同じディレクトリから探すので、必ず並べて置く
cp "$build_tmp/Trim" "$app/Contents/Resources/Trim"
chmod +x "$app/Contents/Resources/Trim"

plist="$app/Contents/Info.plist"

# 設定の保存先ドメインになる bundle identifier。osacompile の既定
# (com.apple.ScriptEditor.id.Dropvert) は他の Script Editor 製アプリと衝突しうるため明示する。
# Dropvert.applescript の property prefsDomain と必ず一致させること。
bundle_id="io.github.suemura.dropvert"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$plist" 2>/dev/null ||
	/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $bundle_id" "$plist"

# 画像ファイルのドロップを受け付けるよう宣言
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes array" "$plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0 dict" "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:CFBundleTypeName string 'Image'" "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:CFBundleTypeRole string 'Editor'" "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:LSHandlerRank string 'Alternate'" "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes array" "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes:0 string 'public.image'" "$plist"

# バージョン。osacompile の Info.plist はどちらのキーも持たないので Add 側に落ちる。
# 表示用 (CFBundleShortVersionString) とビルド番号 (CFBundleVersion) を分けても
# 管理する値が 2 つになるだけなので、同じ値を入れる。
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist" 2>/dev/null ||
	/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $version" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$plist" 2>/dev/null ||
	/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $version" "$plist"

# Swift 製のバイナリを先に ad-hoc 署名する。swiftc が付ける linker-signed 署名の
# ままにせず、扱いを明示的にしておく。bundle の署名より必ず前に行うこと (後から
# 中身を書き換えると bundle の署名が壊れる)。
codesign --force --sign - "$app/Contents/Resources/Prefs"
codesign --force --sign - "$app/Contents/Resources/Trim"

# Info.plist と Resources を書き換えると osacompile が付けた ad-hoc 署名が壊れる。
# 署名が壊れたアプリは macOS から不正扱いされるため、必ず再署名する。
codesign --force --sign - "$app"

if ! codesign --verify --deep --strict "$app" 2>/dev/null; then
	echo "警告: 署名の検証に失敗しました" >&2
	exit 1
fi

touch "$app"
echo "ビルド完了: $app (v$version)"
