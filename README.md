# Dropvert

macOS 用の、極めてシンプルな画像コンバータ。

ファイルをアイコンにドラッグ&ドロップすると、**元と同じフォルダ**に変換後の画像を作成し、生成を確認できたものだけ元ファイルをゴミ箱へ移動します。設定画面もウィンドウもありません。ドロップするだけです。

現在の出力形式は WebP です。将来的に他形式へ切り替えられる構成を想定しています。

## 特徴

- **ドラッグ&ドロップのみ** — Dock やデスクトップに置いたアイコンへ複数ファイルをまとめて投げる
- **元の場所に出力** — 保存先を選ぶ操作がない
- **安全な後始末** — 変換に成功したファイルだけをゴミ箱へ移動（「元に戻す」が使える）。失敗したファイルは削除しない
- **権限の確認ダイアログが出ない** — Finder を操作せず `NSFileManager` でゴミ箱へ移動するため、自動化の許可を求められない
- **軽量** — AppleScript の droplet + シェルスクリプトのみ。常駐プロセスなし、フレームワークなし
- **幅広い入力形式** — HEIC や AVIF なども macOS 標準の `sips` を中間変換に使って対応

## 必要環境

- macOS（`sips` を使用。macOS の `sips` は WebP の書き出しに対応していないため変換は `cwebp` が担当します）
- [WebP ツール](https://developers.google.com/speed/webp/download)

```sh
brew install webp
```

`cwebp` が見つからない場合、Dropvert は変換を行わずにインストール方法を表示します。

## インストール

```sh
git clone https://github.com/Suemura/dropvert.git
cd dropvert
./build.sh
```

`~/Applications/Dropvert.app` が生成されます。出力先を変えたい場合は引数で指定してください。

```sh
./build.sh /Applications
```

生成された `Dropvert.app` を Dock やデスクトップにドラッグして置いておくと使いやすくなります。

## 使い方

1. 画像ファイル（複数可）を `Dropvert.app` のアイコンにドロップする
2. 元と同じフォルダに `.webp` が作られる
3. 生成を確認できたファイルがゴミ箱へ移動する
4. 結果が通知される（失敗があればダイアログでファイル名と理由を表示）

アイコンをダブルクリックした場合は、使い方を説明するダイアログが表示されるだけで、何も変換されません。

権限の確認ダイアログは表示されません。ゴミ箱への移動は Finder への自動化ではなく `NSFileManager` の API で行っているためです。

## 対応形式

| 入力 | 変換経路 |
| --- | --- |
| PNG / JPEG / TIFF | `cwebp` で直接変換 |
| GIF | `gif2webp` で変換（アニメーションを保持） |
| HEIC / AVIF / BMP / PSD / JPEG XL など | `sips` で PNG に中間変換してから `cwebp` |
| WebP | スキップ（変換しない、削除もしない） |

フォルダをドロップした場合はスキップし、結果に「フォルダはスキップ」と表示します。

## 動作の詳細

- **出力名の衝突回避** — `photo.webp` が既に存在する場合は `photo-1.webp`、`photo-2.webp` … と退避します。既存ファイルを上書きすることはありません
- **削除の判定** — 出力ファイルが存在し、かつサイズが 0 でないことを確認したうえで初めてゴミ箱へ移動します
- **失敗時** — 出力の残骸を削除し、元ファイルはそのまま残します
- **書き込み権限がない場所** — 変換せずに理由を報告します
- **メタデータ** — ICC プロファイルを引き継ぎます（`-metadata icc`）

## 設定

`Dropvert.applescript` の先頭にある品質設定を編集し、`./build.sh` を再実行してください。

```applescript
property webpQuality : "85"
```

- `"0"`〜`"100"` — 非可逆圧縮の品質（デフォルト: `85`）
- `"lossless"` — 可逆圧縮

## 構成

```
dropvert/
├── Dropvert.applescript  # droplet 本体。ドロップ受付、結果通知
├── convert.sh            # 1 ファイルを変換するロジック
├── trash.js              # ゴミ箱へ移動する JXA スクリプト
├── build.sh              # osacompile でアプリをビルドし、ad-hoc 署名を付け直す
├── README.md
├── CLAUDE.md
└── LICENSE
```

`convert.sh` は Dropvert.app 内の `Contents/Resources/` に同梱され、droplet から呼び出されます。単体でも実行できます。

```sh
./convert.sh path/to/image.png 85
```

標準出力は次のいずれかです（元ファイルの削除は行いません）。

- 生成された `.webp` のパス（成功）
- `SKIP`（対象外）
- `FAIL:理由`（失敗）

## 名前について

`Dropvert` = drop + convert。無関係の同名 Web サービス（dropvert.com）が存在しますが、本プロジェクトとは一切関係ありません。

## ライセンス

MIT
