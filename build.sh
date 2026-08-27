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

# シェル本体を bundle 内 Resources に同梱 (path to resource で参照される)
cp "$src_dir/convert.sh" "$app/Contents/Resources/convert.sh"
chmod +x "$app/Contents/Resources/convert.sh"

# 画像ファイルのドロップを受け付けるよう宣言
plist="$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes array" "$plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0 dict" "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:CFBundleTypeName string 'Image'" "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:CFBundleTypeRole string 'Editor'" "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:LSHandlerRank string 'Alternate'" "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes array" "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes:0 string 'public.image'" "$plist"

touch "$app"
echo "ビルド完了: $app"
