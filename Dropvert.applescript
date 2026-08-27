-- Dropvert droplet: ドロップされた画像を WebP に変換し、成功したものだけ元ファイルをゴミ箱へ移動する
-- 変換品質 (0-100)。可逆圧縮にしたい場合は "lossless" と書く
property webpQuality : "85"

on run
	display dialog "画像ファイルをこのアプリのアイコンにドラッグ&ドロップしてください。" & return & return & "元と同じフォルダに .webp を作成し、成功したら元ファイルをゴミ箱へ移動します。" buttons {"OK"} default button 1 with title "Dropvert"
end run

on open droppedItems
	set shellPrefix to "export PATH=/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin; "
	set converterPath to POSIX path of (path to resource "convert.sh")

	-- cwebp の存在確認
	try
		do shell script shellPrefix & "command -v cwebp"
	on error
		display alert "cwebp が見つかりません" message "Homebrew でインストールしてください:" & return & return & "brew install webp" as critical
		return
	end try

	set convertedCount to 0
	set skippedCount to 0
	set failedList to {}
	set trashList to {}

	repeat with anItem in droppedItems
		set posixPath to POSIX path of (anItem as alias)
		try
			set res to do shell script shellPrefix & "/bin/bash " & quoted form of converterPath & " " & quoted form of posixPath & " " & quoted form of webpQuality
		on error errMsg
			set res to "FAIL:" & errMsg
		end try

		if res starts with "SKIP" then
			set skippedCount to skippedCount + 1
		else if res starts with "FAIL:" then
			set end of failedList to my baseName(posixPath) & " — " & (text 6 thru -1 of res)
		else
			-- res は生成された .webp のパス。存在とサイズはシェル側で検証済み
			set convertedCount to convertedCount + 1
			set end of trashList to (anItem as alias)
		end if
	end repeat

	-- 変換成功したものだけ、まとめてゴミ箱へ
	if (count of trashList) > 0 then
		try
			tell application "Finder" to delete trashList
		on error errMsg
			display alert "ゴミ箱への移動に失敗" message errMsg & return & return & "WebP の生成は完了しています。元ファイルは手動で削除してください。" as warning
		end try
	end if

	-- 結果通知
	set msg to (convertedCount as text) & " 件変換"
	if skippedCount > 0 then set msg to msg & " / " & (skippedCount as text) & " 件スキップ"
	if (count of failedList) > 0 then
		set msg to msg & " / " & (count of failedList as text) & " 件失敗"
		set AppleScript's text item delimiters to return
		set detail to failedList as text
		set AppleScript's text item delimiters to ""
		display alert "Dropvert: 一部失敗" message msg & return & return & detail as warning
	else
		display notification msg with title "Dropvert" sound name "Glass"
	end if
end open

on baseName(p)
	set AppleScript's text item delimiters to "/"
	set parts to text items of p
	set AppleScript's text item delimiters to ""
	return item -1 of parts
end baseName
