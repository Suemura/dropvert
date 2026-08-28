-- Dropvert droplet: ドロップされた画像を変換し、成功したものだけ元ファイルをゴミ箱へ移動する
--   ダブルクリック (on run)  → 設定画面
--   ドロップ    (on open)   → 保存済みの設定で即変換 (操作は増やさない)

-- 設定の保存先ドメイン。build.sh が Info.plist に書く CFBundleIdentifier と
-- 必ず一致させること。ずれると設定が黙って無視される。
property prefsDomain : "io.github.suemura.dropvert"
-- 設定を一度も触っていないときの値。ここだけで実用的に動くこと。
property defaultQuality : "85"
property defaultFormat : "webp"
property defaultOriginal : "trash"
property defaultTrim : "off"
-- 同時に変換する数。"0" で CPU コア数 (hw.ncpu)、"1" で逐次実行
property parallelism : "0"

-- 設定画面。同梱した Prefs (Swift 製) を開くだけ。設定の中身はあちらが持つ。
--
-- バックグラウンドで起動してすぐ制御を返すこと。同期で待つと、設定ウィンドウを
-- 開いている間にドロップされたファイルが処理されない (アプレットは一度に 1 つの
-- イベントしか扱えないため、on open が on run の後ろで待たされる)。
-- ウィンドウが二重に開かないための制御は Prefs 側が持っている。
on run
	try
		set prefsPath to POSIX path of (path to resource "Prefs")
	on error
		display alert "設定画面を開けません" message "アプリの内容が壊れています。build.sh で再ビルドしてください。" as critical
		return
	end try
	-- バックグラウンド起動そのものは失敗を返さない (シェルは即座に 0 を返す)。
	-- 起動できずに終わったことに気づけないと「ダブルクリックしても無反応」に
	-- なってしまうので、失敗したときだけ終了コードを一時ファイルに書かせ、
	-- 少しだけ様子を見る。
	--
	-- 正常に終わったときは何も書かない。ここで待つのは 0.7 秒だけで、設定
	-- ウィンドウはそのあとも開かれ続けるため、「終了時に必ず書く」形にすると
	-- 消したはずの一時ファイルがウィンドウを閉じたときに作り直されてしまう。
	-- 既に開いていて二重起動をやめた場合 (終了コード 0) も書かれないので、
	-- ファイルが空かどうかだけを見ればよい。
	set statusPath to ""
	try
		set statusPath to do shell script "/usr/bin/mktemp -t dropvert-prefs"
		do shell script "( " & quoted form of prefsPath & " >/dev/null 2>&1 || echo $? >" & quoted form of statusPath & " ) >/dev/null 2>&1 </dev/null &"
	on error errMsg number errNum
		my removeFile(statusPath)
		if errNum is -128 then return
		display alert "設定画面を開けません" message errMsg as critical
		return
	end try

	try
		delay 0.7
	end try
	set launchStatus to ""
	try
		set launchStatus to do shell script "/bin/cat " & quoted form of statusPath
	end try
	my removeFile(statusPath)
	if launchStatus is not "" then
		display alert "設定画面を開けません" message "設定画面を起動できませんでした（終了コード " & launchStatus & "）。build.sh で再ビルドしてください。" as critical
	end if
end run

on open droppedItems
	set shellPrefix to "export PATH=/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin; "
	set runnerPath to POSIX path of (path to resource "run.sh")

	set s to my loadSettings()
	set theQuality to quality of s
	set theFormat to fmt of s
	set theOriginal to orig of s
	-- シェル側の語彙は 1 / 0。設定の "on" / "off" をここで写す。
	if trim of s is "on" then
		set theTrim to "1"
	else
		set theTrim to "0"
	end if

	-- cwebp の存在確認。WebP だけは sips が書き出せず外部コマンドに頼るため、
	-- 出力形式が WebP のときだけ確認する。
	if theFormat is "webp" then
		try
			do shell script shellPrefix & "command -v cwebp"
		on error
			display alert "cwebp が見つかりません" message "WebP の書き出しには cwebp が必要です。Homebrew でインストールしてください:" & return & return & "brew install webp" & return & return & "アプリをダブルクリックすると、出力形式を AVIF / JPEG / PNG に変更できます (これらは追加のインストールなしで変換できます)。" as critical
			return
		end try
	end if

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
	set unprocessedCount to 0
	set succListPath to ""
	set renListPath to ""
	set tmpDir to ""
	set listPath to ""
	set workDir to ""
	set cancelled to false

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

		-- 作業ディレクトリはこちらで作って run.sh に渡す。起動直後から
		-- results/ を数えて進行度を出せるようにするため。
		set workDir to do shell script "/usr/bin/mktemp -d -t dropvert-work"
		set outPath to workDir & "/runner.out"
		set totalCount to count of inputLines

		-- 進捗ウィンドウはアプレットが自動で出し、on open を抜けると自動で消える。
		-- 途中で閉じることはできない (total steps を 0 に戻しても残る) ので、
		-- 失敗アラートを出す場合はアラートを閉じるまで背後に残ることになる。
		set progress description to "画像を変換中"
		set progress additional description to my progressText(0, totalCount)
		set progress total steps to totalCount
		set progress completed steps to 0

		-- do shell script は同期呼び出しなので、待っている間は進行度を更新できない。
		-- run.sh をバックグラウンドで起動し、PID を受け取って自分でポーリングする。
		-- これで do shell script の暗黙のタイムアウト (2 分) にもかからない。
		try
			set runnerPID to do shell script shellPrefix & "/bin/bash " & quoted form of runnerPath & " " & quoted form of listPath & " " & quoted form of theQuality & " " & quoted form of parallelism & " " & quoted form of workDir & " " & quoted form of theFormat & " " & quoted form of theTrim & " >" & quoted form of outPath & " 2>&1 </dev/null & echo $!"
		on error errMsg
			my removeFile(listPath)
			my removeDir(workDir)
			display alert "変換を開始できません" message errMsg as critical
			return
		end try

		-- 進行度の見張り。1 回の呼び出しで「完了件数」と「まだ動いているか」を取る。
		-- 終了判定は exit ファイルと kill -0 の二重。run.sh が異常終了しても抜けられる。
		set statusCmd to "/bin/ls -1 " & quoted form of (workDir & "/results") & " 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' '; " & my aliveCmd(workDir, runnerPID)
		try
			repeat
				set statusText to do shell script statusCmd
				set doneCount to (paragraph 1 of statusText) as integer
				if doneCount > totalCount then set doneCount to totalCount
				set progress completed steps to doneCount
				set progress additional description to my progressText(doneCount, totalCount)
				if (paragraph 2 of statusText) is "DONE" then exit repeat
				delay 0.3
			end repeat
		on error errMsg number errNum
			-- -128 は進捗ウィンドウの「停止」。それ以外 (見張り自体の失敗) も
			-- 同じ扱いにする。どちらも cancel を置いて run.sh を自然に終わらせれば、
			-- 変換できた分の後始末は通常のサマリ経路でやり切れる。
			set cancelled to true
			if errNum is not -128 then
				set end of failedList to "- — 進行度の監視に失敗: " & errMsg
			end if
			try
				do shell script "/usr/bin/touch " & quoted form of (workDir & "/cancel")
			end try
			-- run.sh の終了を待つ。「停止」の連打で抜けてしまわないよう -128 は
			-- 握り潰すが、exit を書けなかった場合に永久に回らないよう上限を置く。
			set waitUntil to (current date) + 120
			repeat
				try
					if (do shell script my aliveCmd(workDir, runnerPID)) is "DONE" then exit repeat
				end try
				if (current date) > waitUntil then exit repeat
				try
					delay 0.3
				end try
			end repeat
		end try
		-- ここから先も「停止」は押せる (進捗ウィンドウは on open を抜けるまで
		-- 閉じられない)。連打で後始末が飛ばないよう、以降は -128 を握り潰す。
		try
			set progress completed steps to totalCount
			set progress additional description to my progressText(totalCount, totalCount)
		end try
		my removeFile(listPath)

		try
			set res to do shell script "/bin/cat " & quoted form of outPath
		on error
			set res to ""
		end try
		if res is "" then
			my removeDir(workDir)
			display alert "変換に失敗しました" message "変換プロセスが結果を返しませんでした。" as critical
			return
		end if

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
				else if tagName is "UNPROCESSED" and (count of fields) ≥ 2 then
					set unprocessedCount to (item 2 of fields) as integer
				else if tagName is "LIST" and (count of fields) ≥ 2 then
					set succListPath to item 2 of fields
				else if tagName is "RENAME" and (count of fields) ≥ 2 then
					set renListPath to item 2 of fields
				else if tagName is "FAIL" and (count of fields) ≥ 3 then
					set end of failedList to (item 2 of fields) & " — " & (item 3 of fields)
				end if
			end if
		end repeat
	end if

	-- 変換に成功したものだけ、まとめてゴミ箱へ (設定が「残す」なら何もしない)。
	-- Finder への AppleEvent を使うと自動化の権限が必要になるため、
	-- NSFileManager を直接叩く JXA スクリプト (trash.js) に任せる。
	-- 件数が多いときのためにパスは NUL 区切りのリストから xargs で渡す。
	-- 「停止」は後始末の間もずっと押せる (進捗ウィンドウは on open を抜けるまで
	-- 閉じられない)。移動と後片付けを先に済ませ、画面表示は最後に回す。
	-- こうしておけば連打で -128 が飛んできても消し残りが出ない。
	set trashFailed to ""
	if succListPath is not "" and theOriginal is "trash" then
		try
			-- パイプを足してはいけない。do shell script はパイプ全体 (末尾のコマンド) の
			-- 終了ステータスしか見ないため、osascript が起動できなかった場合の失敗を
			-- 取りこぼす。trash.js 側で成功時の出力を 0 バイトにしてある。
			set trashFailed to do shell script shellPrefix & "/usr/bin/xargs -0 -n 200 /usr/bin/osascript -l JavaScript " & quoted form of (POSIX path of (path to resource "trash.js")) & " < " & quoted form of succListPath
		on error errMsg number errNum
			if errNum is -128 then
				set cancelled to true
				set trashFailed to "移動中に中止されました。元ファイルの一部が残っている可能性があります。"
			else
				set trashFailed to errMsg
			end if
		end try
	end if

	-- 同じ形式のまま余白だけ削ったファイルは、元ファイルが名前を占有していたため
	-- "-1" が付いている。元をゴミ箱へ移した今なら名前が空いているので戻す。
	-- 元ファイルを残す設定のときは名前が空かないので何もしない。
	--
	-- 宛先が既にある場合は触らない。ゴミ箱への移動が失敗していれば元ファイルが
	-- そこに残っているので、この確認がそのまま踏み潰しを防ぐ仕掛けになる
	-- (mv -n と合わせて二重の歯止め)。失敗しても "-1" が付いたまま残るだけで、
	-- 中身は失われない。通知を増やす価値がないので黙って進む。
	if renListPath is not "" and theOriginal is "trash" then
		try
			do shell script "/usr/bin/xargs -0 -n 2 /bin/sh -c 'if [ ! -e \"$2\" ]; then /bin/mv -n -- \"$1\" \"$2\"; fi' _ < " & quoted form of renListPath
		end try
	end if

	my removeDir(tmpDir)
	my removeDir(workDir)

	-- 結果通知
	set msg to (convertedCount as text) & " 件変換"
	if cancelled then set msg to "中止 — " & msg
	if skippedCount > 0 then set msg to msg & " / " & (skippedCount as text) & " 件スキップ"
	if unprocessedCount > 0 then set msg to msg & " / " & (unprocessedCount as text) & " 件未処理"
	if (count of failedList) > 0 then
		set msg to msg & " / " & (count of failedList as text) & " 件失敗"
	end if

	try
		if trashFailed is not "" then
			display alert "ゴミ箱への移動に失敗" message trashFailed & return & return & "変換後のファイルは生成済みです。元ファイルは手動で削除してください。" as warning
		end if
		if (count of failedList) > 0 then
			set AppleScript's text item delimiters to return
			set detail to failedList as text
			set AppleScript's text item delimiters to ""
			display alert "Dropvert: 一部失敗" message msg & return & return & detail as warning
		else
			display notification msg with title "Dropvert" sound name "Glass"
		end if
	end try
end open

-- 設定の読み出し。保存先は defaults (~/Library/Preferences/<prefsDomain>.plist)。
-- 書き込むのは設定ウィンドウ (Prefs) だけで、こちらは読むだけ。
-- 値はすべて string で持ち、読むたびに検証して不正なら既定値に落とす
-- (書き戻しはしない = 触っていなければ plist を作らない)。
-- 手で defaults write された値や、古いバージョンが書いた値から身を守る役目もある。
on readPref(theKey, fallback)
	try
		return do shell script "/usr/bin/defaults read " & quoted form of prefsDomain & " " & quoted form of theKey
	on error
		return fallback
	end try
end readPref

on loadSettings()
	set q to my readPref("quality", defaultQuality)
	if my isValidQuality(q) is false then set q to defaultQuality
	if q is "lossless" then set q to "lossless" -- 大文字表記を正規化する
	set f to my readPref("format", defaultFormat)
	if f is not in {"webp", "avif", "jpeg", "png"} then set f to defaultFormat
	set o to my readPref("originalAction", defaultOriginal)
	if o is not in {"trash", "keep"} then set o to defaultOriginal
	set t to my readPref("trimPadding", defaultTrim)
	if t is not in {"on", "off"} then set t to defaultTrim
	return {quality:q, fmt:f, orig:o, trim:t}
end loadSettings

-- 0〜100 の整数、または lossless だけを通す。"85.5" や "０" のような
-- 見た目が紛らわしい値は、整数に直して文字列へ戻し一致するかで弾く。
on isValidQuality(v)
	if v is "lossless" then return true
	try
		set n to v as integer
	on error
		return false
	end try
	if (n as text) is not v then return false
	if n < 0 or n > 100 then return false
	return true
end isValidQuality

-- 進捗ウィンドウに出す「12 / 40 (30%)」の文字列。
on progressText(doneCount, totalCount)
	set pct to 0
	if totalCount > 0 then set pct to (doneCount * 100) div totalCount
	return (doneCount as text) & " / " & (totalCount as text) & " (" & (pct as text) & "%)"
end progressText

-- run.sh がまだ動いているかを 1 行で返すシェル片。exit ファイルが先で、
-- 無ければプロセスの生存を見る (消えていれば DONE)。
-- kill -0 ではなくコマンド行まで確認するのは、exit を書けなかった場合に
-- PID が別プロセスに再利用されると永久に RUN を返してしまうため。
on aliveCmd(wd, thePID)
	return "if [ -e " & quoted form of (wd & "/exit") & " ]; then echo DONE; elif /bin/ps -o command= -p " & thePID & " 2>/dev/null | /usr/bin/grep -qF 'run.sh'; then echo RUN; else echo DONE; fi"
end aliveCmd

on removeDir(p)
	if p is "" then return
	try
		do shell script "/bin/rm -rf " & quoted form of p
	end try
end removeDir

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
