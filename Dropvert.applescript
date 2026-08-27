-- Dropvert droplet: ドロップされた画像を WebP に変換し、成功したものだけ元ファイルをゴミ箱へ移動する
-- 変換品質 (0-100)。可逆圧縮にしたい場合は "lossless" と書く
property webpQuality : "85"
-- 同時に変換する数。"0" で CPU コア数 (hw.ncpu)、"1" で逐次実行
property parallelism : "0"

on run
	display dialog "画像ファイルをこのアプリのアイコンにドラッグ&ドロップしてください。" & return & return & "元と同じフォルダに .webp を作成し、成功したら元ファイルをゴミ箱へ移動します。" buttons {"OK"} default button 1 with title "Dropvert"
end run

on open droppedItems
	set shellPrefix to "export PATH=/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin; "
	set runnerPath to POSIX path of (path to resource "run.sh")

	-- cwebp の存在確認
	try
		do shell script shellPrefix & "command -v cwebp"
	on error
		display alert "cwebp が見つかりません" message "Homebrew でインストールしてください:" & return & return & "brew install webp" as critical
		return
	end try

	-- 入力パスは一時ファイル経由で渡す。数百件ドロップされてもコマンドライン長の
	-- 上限にかからない。ファイル名に改行を含むものは行がずれて別のファイルを
	-- 削除する事故になりうるため、変換せずに失敗として扱う。
	set failedList to {}
	set inputLines to {}
	repeat with anItem in droppedItems
		set posixPath to POSIX path of (anItem as alias)
		if posixPath contains linefeed or posixPath contains return then
			set end of failedList to my baseName(posixPath) & " — ファイル名に改行が含まれる"
		else
			set end of inputLines to posixPath
		end if
	end repeat

	set convertedCount to 0
	set skippedCount to 0
	set succListPath to ""
	set tmpDir to ""
	set listPath to ""

	if (count of inputLines) > 0 then
		set listPath to do shell script "/usr/bin/mktemp -t dropvert-input"
		set AppleScript's text item delimiters to linefeed
		set listText to (inputLines as text) & linefeed
		set AppleScript's text item delimiters to ""

		set fh to missing value
		try
			set fh to open for access (POSIX file listPath) with write permission
			set eof fh to 0
			write listText to fh as «class utf8»
			close access fh
			set fh to missing value
		on error errMsg
			if fh is not missing value then
				try
					close access fh
				end try
			end if
			display alert "処理を開始できません" message "入力リストの書き出しに失敗しました。" & return & return & errMsg as critical
			my removeFile(listPath)
			return
		end try

		try
			set res to do shell script shellPrefix & "/bin/bash " & quoted form of runnerPath & " " & quoted form of listPath & " " & quoted form of webpQuality & " " & quoted form of parallelism
		on error errMsg
			my removeFile(listPath)
			display alert "変換に失敗しました" message errMsg as critical
			return
		end try
		my removeFile(listPath)

		-- run.sh のサマリ行を解釈する (タブ区切り)
		repeat with para in paragraphs of res
			set lineText to para as text
			if lineText is not "" then
				set AppleScript's text item delimiters to tab
				set fields to text items of lineText
				set AppleScript's text item delimiters to ""
				set tagName to item 1 of fields
				if tagName is "TMP" and (count of fields) ≥ 2 then
					set tmpDir to item 2 of fields
				else if tagName is "CONVERTED" and (count of fields) ≥ 2 then
					set convertedCount to (item 2 of fields) as integer
				else if tagName is "SKIPPED" and (count of fields) ≥ 2 then
					set skippedCount to (item 2 of fields) as integer
				else if tagName is "LIST" and (count of fields) ≥ 2 then
					set succListPath to item 2 of fields
				else if tagName is "FAIL" and (count of fields) ≥ 3 then
					set end of failedList to (item 2 of fields) & " — " & (item 3 of fields)
				end if
			end if
		end repeat
	end if

	-- 変換に成功したものだけ、まとめてゴミ箱へ。
	-- Finder への AppleEvent を使うと自動化の権限が必要になるため、
	-- NSFileManager を直接叩く JXA スクリプト (trash.js) に任せる。
	-- 件数が多いときのためにパスは NUL 区切りのリストから xargs で渡す。
	if succListPath is not "" then
		try
			-- trash.js は成功時も空行を 1 行返す。xargs が 200 件ごとに分割すると
			-- その空行が積み上がって「失敗した」と誤判定するため、空行を落とす。
			set trashFailed to do shell script shellPrefix & "/usr/bin/xargs -0 -n 200 /usr/bin/osascript -l JavaScript " & quoted form of (POSIX path of (path to resource "trash.js")) & " < " & quoted form of succListPath & " | /usr/bin/sed '/^[[:space:]]*$/d'"
		on error errMsg
			set trashFailed to errMsg
		end try
		if trashFailed is not "" then
			display alert "ゴミ箱への移動に失敗" message trashFailed & return & return & "変換後のファイルは生成済みです。元ファイルは手動で削除してください。" as warning
		end if
	end if

	if tmpDir is not "" then
		try
			do shell script "/bin/rm -rf " & quoted form of tmpDir
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

on removeFile(p)
	if p is "" then return
	try
		do shell script "/bin/rm -f " & quoted form of p
	end try
end removeFile

on baseName(p)
	set AppleScript's text item delimiters to "/"
	set parts to text items of p
	set AppleScript's text item delimiters to ""
	return item -1 of parts
end baseName
