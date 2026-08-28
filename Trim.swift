// 画像の周囲にある単色の余白を測り、切り出すべき矩形を返す。
//
// 切り出しもエンコードも行わない。実際に切り出すのは convert.sh が呼ぶ
// cwebp (-crop) と sips (-c/--cropOffset) で、このバイナリは矩形を返すだけ。
// 画像は読むだけで、どのファイルも書き換えない。
//
//   使い方: Trim <入力ファイル>
//
//   出力(stdout): 必ず 1 行。終了コードは常に 0。
//     "<x> <y> <w> <h> <W> <H>"  切り出すべき矩形と、元画像のピクセル寸法
//     "NONE"                     削る余白が無い / 全面が単色 / 触らない方がよい
//     "FAIL:<理由>"              画像として読めない (理由は 1 行のみ)
//
//   元画像の寸法まで返すのは、呼び出し側が矩形の妥当性を検証できるようにするため。
//   sips は範囲外の --cropOffset をエラーにせず黙ってクランプするので、
//   矩形が壊れていても「変換成功」になり、別の絵で元ファイルが削除されうる。
//
// 余白の判定は完全一致のみ。1 ピクセルでも色が違えばそこで止める。
// JPEG のノイズが乗った余白は削り残るが、削りすぎるより削り足りない方に倒す。
//
// 単体でのビルドと実行:
//   /Library/Developer/CommandLineTools/usr/bin/swiftc \
//     -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
//     -O -o /tmp/Trim Trim.swift && /tmp/Trim image.png

import CoreGraphics
import Foundation
import ImageIO

/// 理由を返して終わる。呼び出し側はトリムなしで変換を続けられるので、
/// 終了コードは常に 0 にする (失敗を変換の失敗に昇格させない)。
func fail(_ reason: String) -> Never {
	print("FAIL:\(reason)")
	exit(0)
}

func nothingToTrim() -> Never {
	print("NONE")
	exit(0)
}

let args = CommandLine.arguments
guard args.count >= 2, !args[1].isEmpty else { fail("引数なし") }

let url = URL(fileURLWithPath: args[1])
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { fail("画像として読めない") }

let width = image.width
let height = image.height
guard width > 0, height > 0 else { fail("サイズが不正") }

// 既知のフォーマット (sRGB / RGBA8) に正規化してから走査する。16bit や P3 の
// 画像でも、単色の余白は変換後も単色のままなので判定には影響しない。
//
// CGImageAlphaInfo.last (non-premultiplied) は CGContext が受け付けず、
// エラーを出さずに nil を返すだけなので premultipliedLast を使う。透明な
// 余白は RGB が 0 に潰れるが、余白どうしの比較なので判定は変わらない。
let bytesPerRow = width * 4
var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
	guard let space = CGColorSpace(name: CGColorSpace.sRGB),
	      let context = CGContext(data: buffer.baseAddress,
	                              width: width, height: height,
	                              bitsPerComponent: 8, bytesPerRow: bytesPerRow,
	                              space: space,
	                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
	else { return false }
	context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
	return true
}
guard drawn else { fail("画像を展開できない") }

@inline(__always) func pixel(_ x: Int, _ y: Int) -> UInt32 {
	let i = y * bytesPerRow + x * 4
	return UInt32(pixels[i]) << 24 | UInt32(pixels[i + 1]) << 16
		| UInt32(pixels[i + 2]) << 8 | UInt32(pixels[i + 3])
}

func rowIsUniform(_ y: Int, _ color: UInt32, _ from: Int, _ to: Int) -> Bool {
	var x = from
	while x < to {
		if pixel(x, y) != color { return false }
		x += 1
	}
	return true
}

func columnIsUniform(_ x: Int, _ color: UInt32, _ from: Int, _ to: Int) -> Bool {
	var y = from
	while y < to {
		if pixel(x, y) != color { return false }
		y += 1
	}
	return true
}

// 4 辺それぞれについて、その辺の色を基準に同じ色が続く限り内側へ削る。
// 基準色を辺ごとに取り直すのは、片側だけに余白がある画像 (上に帯があるだけの
// スクリーンショットなど) を扱うため。既に削った分は走査範囲から外すので、
// 辺ごとに色が違っても破綻しない。
//
// 各段の前に残りの領域が空になっていないか確かめる。全面が単色の画像では
// 最初の走査だけで領域を使い切り、次の基準色を読むと範囲外になる。
var top = 0
var bottom = height
var left = 0
var right = width

var color = pixel(0, 0)
while top < bottom, rowIsUniform(top, color, left, right) { top += 1 }
if top >= bottom { nothingToTrim() }

color = pixel(0, bottom - 1)
while bottom > top, rowIsUniform(bottom - 1, color, left, right) { bottom -= 1 }
if bottom <= top { nothingToTrim() }

color = pixel(0, top)
while left < right, columnIsUniform(left, color, top, bottom) { left += 1 }
if left >= right { nothingToTrim() }

color = pixel(right - 1, top)
while right > left, columnIsUniform(right - 1, color, top, bottom) { right -= 1 }
if right <= left { nothingToTrim() }

let cropWidth = right - left
let cropHeight = bottom - top
if cropWidth == width, cropHeight == height { nothingToTrim() }

print("\(left) \(top) \(cropWidth) \(cropHeight) \(width) \(height)")
