# CLAUDE.md

このファイルは Claude Code がこのリポジトリで作業する際の指針です。

## プロジェクト概要

Dropvert は macOS 用のドラッグ&ドロップ画像コンバータです。AppleScript の droplet（`osacompile` でビルドした `.app`）と Bash スクリプトだけで構成されており、常駐プロセス・依存フレームワーク・設定 UI を持ちません。

現在の出力形式は WebP のみですが、**将来的に他の出力形式へ切り替えられるようにする予定**です。そのためプロジェクト名・ファイル名は形式非依存にしてあります（`convert.sh`、`Dropvert.app`）。WebP 固有の記述は品質設定と `case` 文の分岐に閉じ込めてください。

## 設計上の原則

この 3 点はプロジェクトの根幹であり、リファクタリングで壊してはいけません。

1. **シンプルさが機能である** — 設定 UI、ウィンドウ、環境設定ファイル、進捗バーは追加しない。ドロップ以外の操作を増やさない
2. **元ファイルの削除は必ず検証の後** — 出力ファイルの存在とサイズ 0 でないことを確認して初めてゴミ箱へ移動する。`rm` は使わず Finder 経由（「元に戻す」を残す）。変換に失敗したファイルは絶対に削除しない
3. **既存ファイルを上書きしない** — 出力名が衝突したら `-1`, `-2` … を付けて退避する

## ファイル構成と役割

- `Dropvert.applescript` — droplet 本体。`on open` でドロップを受け、`convert.sh` を 1 ファイルずつ呼び、成功分をまとめてゴミ箱へ移動し、結果を通知する。ここに変換ロジックを書かない
- `convert.sh` — 1 ファイルの変換のみを担う。**元ファイルの削除は行わない**（責務分離）。stdout で結果を返す契約:
  - 成功 → 生成した `.webp` の絶対パス
  - 対象外 → `SKIP`
  - 失敗 → `FAIL:理由`（理由は 1 行のみ）
- `build.sh` — `osacompile` でアプリを生成し、`convert.sh` を `Contents/Resources/` にコピーし、`Info.plist` に `CFBundleDocumentTypes`（`public.image`）を追加する

この stdout 契約は AppleScript 側の分岐が依存しています。変更する場合は両方を同時に直してください。

## ビルドと確認

```sh
./build.sh                  # ~/Applications/Dropvert.app を生成
./build.sh /Applications    # 出力先を指定
```

ビルドは既存の `.app` を削除してから作り直します。ソースを編集したら必ず再ビルドしてください。**アプリ内の `convert.sh` を直接編集しても、次のビルドで上書きされます。**

構文チェックのみ行う場合:

```sh
osacompile -o /dev/null Dropvert.applescript
```

## テスト方法

自動テストはありません。変更したら `convert.sh` を直接呼んで確認してください。ドロップ操作の GUI 部分は手動確認が必要です。

```sh
# テスト素材の作り方（macOS 標準の壁紙を利用）
sips -s format png /System/Library/CoreServices/DefaultDesktop.heic --out /tmp/t/a.png

./convert.sh /tmp/t/a.png 85
```

最低限、次のケースを確認してください。

- PNG / JPEG（大文字拡張子 `.JPG` を含む）
- HEIC など `sips` 中間変換を通る形式
- 出力名の衝突（同名 `.webp` が既にある状態）
- `.webp` を入力 → `SKIP` を返すこと
- 壊れたファイル（`echo bad > x.png`）→ `FAIL:` を返し、出力の残骸が残らないこと
- フォルダ → 削除されないこと

## 注意点

- **macOS の `sips` は WebP を書き出せません**（読み込みのみ）。`sips --formats` で `org.webmproject.webp` に `Writable` が付いていないことが確認できます。書き出しは `cwebp`（`brew install webp`）が担当します
- **droplet の PATH は最小構成です**。Homebrew のパスは通っていないため、`do shell script` の前に PATH を明示的に設定しています（`shellPrefix`）。新しい外部コマンドを使う場合は注意してください
- `do shell script` に渡す引数は必ず `quoted form of` を通してください。スペースを含むファイル名が壊れます
- `display notification` は失敗しても例外を投げないことがあります。処理の成否をこれで判断しないでください

## コミット・公開について

- コミットメッセージは通常の記述で構いません（Conventional Commits 推奨）
- README.md / CLAUDE.md などのドキュメントは通常の日本語で記述します
- 公開リポジトリのため、絶対パス（`/Users/...`）や個人情報をコミットしないでください
