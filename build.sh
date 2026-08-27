#!/bin/bash
# Dropvert.app をビルドする。
#   使い方: ./build.sh [出力先ディレクトリ]   (デフォルト: ~/Applications)
set -euo pipefail

src_dir=$(cd "$(dirname "$0")" && pwd)
dest_dir="${1:-$HOME/Applications}"
app="$dest_dir/Dropvert.app"

mkdir -p "$dest_dir"
rm -rf "$app"

osacompile -o "$app" "$src_dir/Dropvert.applescript"

# スクリプトを bundle 内 Resources に同梱 (path to resource で参照される)
cp "$src_dir/convert.sh" "$app/Contents/Resources/convert.sh"
chmod +x "$app/Contents/Resources/convert.sh"
cp "$src_dir/trash.js" "$app/Contents/Resources/trash.js"

# 画像ファイルのドロップを受け付けるよう宣言
plist="$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes array" "$plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0 dict" "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:CFBundleTypeName string 'Image'" "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:CFBundleTypeRole string 'Editor'" "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:LSHandlerRank string 'Alternate'" "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes array" "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes:0 string 'public.image'" "$plist"

# Info.plist と Resources を書き換えると osacompile が付けた ad-hoc 署名が壊れる。
# 署名が壊れたアプリは macOS から不正扱いされるため、必ず再署名する。
codesign --force --sign - "$app"

if ! codesign --verify --deep --strict "$app" 2>/dev/null; then
	echo "警告: 署名の検証に失敗しました" >&2
	exit 1
fi

touch "$app"
echo "ビルド完了: $app"
