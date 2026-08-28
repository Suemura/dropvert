// 引数で受け取ったファイルをゴミ箱へ移動する (JXA)。
//   使い方: osascript -l JavaScript trash.js <ファイル> [<ファイル> ...]
//   出力: 移動に失敗したファイルのパスを 1 行ずつ。すべて成功なら何も出さない。
//
// 空文字列を返すと osascript が改行を 1 つ出力してしまう。呼び出し側は
// xargs で 200 件ごとに分割するため、その改行が分割数だけ積み上がって
// 「失敗あり」と誤判定される。成功時は undefined を返して出力を 0 バイトにする。
//
// Finder への AppleEvent ではなく NSFileManager を直接使う。
// AppleEvents (自動化) の権限が不要で、かつゴミ箱の「元に戻す」も機能する。
ObjC.import('Foundation')

function run(argv) {
	var fm = $.NSFileManager.defaultManager
	var failed = []

	for (var i = 0; i < argv.length; i++) {
		var ok = false
		try {
			ok = fm.trashItemAtURLResultingItemURLError(
				$.NSURL.fileURLWithPath(argv[i]),
				$(),
				$()
			)
		} catch (e) {
			ok = false
		}
		if (!ok) failed.push(argv[i])
	}

	if (failed.length === 0) return undefined
	return failed.join('\n')
}
