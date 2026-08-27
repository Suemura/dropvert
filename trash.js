// 引数で受け取ったファイルをゴミ箱へ移動する (JXA)。
//   使い方: osascript -l JavaScript trash.js <ファイル> [<ファイル> ...]
//   出力: 移動に失敗したファイルのパスを 1 行ずつ。すべて成功なら空。
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

	return failed.join('\n')
}
