// Dropvert の設定ウィンドウ。
//
// アプリのアイコンをダブルクリックしたとき、Dropvert.applescript の on run から
// 起動される。保存ボタンは持たず、値を変えた瞬間に defaults へ書く。
// ウィンドウを閉じるとプロセスごと終了する。
//
// このファイルは設定の読み書きと UI だけを担当する。変換・削除・並列制御には
// 一切関わらない (それぞれ convert.sh / trash.js / run.sh の責務)。
//
// 単体でのビルドと実行:
//   /Library/Developer/CommandLineTools/usr/bin/swiftc \
//     -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
//     -O -o /tmp/Prefs Prefs.swift && /tmp/Prefs

import AppKit
import Darwin

// MARK: - 設定の定義
//
// 項目を増やすときはここに 1 件足す。UI の組み立てと保存は
// makePopUp / makeCheckBox が引き受けるので、レイアウトに 1 行加えるだけで済む。
// 例: 将来の言語設定は
//   static let language = PopUpSpec(key: "language", choices: [...], fallback: "system")
// を足し、ヘッダの stack に makePopUp(Pref.language, store) を追加する。

enum Pref {
	/// 設定の保存先ドメイン。
	/// Dropvert.applescript の `property prefsDomain` および build.sh の
	/// `bundle_id` と必ず一致させること。ずれると設定が黙って無視される。
	static let domain = "io.github.suemura.dropvert"

	/// 選択肢 1 つ。code は AppleScript / シェル側の語彙、title は画面に出す名前。
	struct Choice {
		let code: String
		let title: String
	}

	/// ポップアップボタン 1 個ぶんの定義。
	struct PopUpSpec {
		let key: String
		let choices: [Choice]
		let fallback: String
	}

	/// チェックボックス 1 個ぶんの定義。
	/// off のときもキーを消さずに offValue を明示的に書く。キーを消すと
	/// 読み手が既定値 (= on 相当) に落ちてしまい、チェックを外したのに
	/// 元ファイルがゴミ箱へ行く事故になる。
	struct CheckSpec {
		let key: String
		let title: String
		let onValue: String
		let offValue: String
		let onIsDefault: Bool
	}

	static let format = PopUpSpec(
		key: "format",
		choices: [
			Choice(code: "webp", title: "WebP"),
			Choice(code: "avif", title: "AVIF"),
			Choice(code: "jpeg", title: "JPEG"),
			Choice(code: "png", title: "PNG"),
		],
		fallback: "webp")

	static let original = CheckSpec(
		key: "originalAction",
		title: L.originalCheckbox,
		onValue: "trash",
		offValue: "keep",
		onIsDefault: true)

	/// 単色で塗りつぶされた余白の自動削除。既定は off。
	/// 元の絵を削る操作なので、設定を触っていない利用者には起こらないようにする。
	static let trim = CheckSpec(
		key: "trimPadding",
		title: L.trimCheckbox,
		onValue: "on",
		offValue: "off",
		onIsDefault: false)

	static let qualityKey = "quality"
	static let qualityFallback = "85"

	/// 圧縮率の指定が意味を持たない出力形式。スライダーを無効化する。
	static let formatsIgnoringQuality: Set<String> = ["png"]

	/// スライダー最右 (lossless) が本当に可逆圧縮になる出力形式。
	/// それ以外の形式では「最高品質」として扱われる。
	static let formatsWithLossless: Set<String> = ["webp"]

	static let allKeys = [qualityKey, format.key, original.key, trim.key]

	/// スライダーの最右の位置。ここに合わせると quality に "lossless" を書く。
	static let losslessTick = 101.0
}

// MARK: - 文言
//
// このバイナリはアプリのバンドルを持たない (Contents/Resources に置かれた
// 裸の実行ファイル) ため、Bundle.main はアプリを指さず .lproj も
// NSLocalizedString も使えない。画面に出す文字列はすべてここに集約する。
// 将来の言語切替は、この enum を言語ごとの struct に差し替える形になる。

enum L {
	static let windowTitle = "Dropvert"
	static let qualityLabel = "圧縮率"
	static let qualityLossless = "可逆 (lossless)"
	static let qualityBest = "最高品質（可逆圧縮はありません）"
	static let qualityUnused = "この形式では使用しません"
	static let tickMin = "最小"
	static let tickNormal = "標準"
	static let tickHigh = "最高"
	static let tickLossless = "可逆"
	static let originalCheckbox = "変換に成功した元ファイルをゴミ箱に入れる"
	static let originalNote = "変換に失敗したファイルは、どちらの設定でも削除されません。"
	static let trimCheckbox = "単色で塗りつぶされた余白を自動で削除する"
	static let trimNote = "完全に同じ色が続いている部分だけを削ります。GIF は対象外です。"
	static let resetButton = "デフォルトに戻す"
	static let dropHint = "画像ファイルをこのアプリのアイコンにドラッグ&ドロップすると変換します。"

	/// 0〜100 の圧縮率に付ける帯の名前。
	static func band(_ value: Int) -> String {
		switch value {
		case ..<41: return "低"
		case ..<71: return "標準"
		case ..<91: return "高"
		default: return "最高"
		}
	}
}

// MARK: - 保存
//
// 値はすべて string で書く。AppleScript 側は defaults read の出力を
// 文字列として扱うため、型が変わると読み取りが壊れる。

final class Store {
	private let defaults: UserDefaults
	/// 遅延中の書き込み。値そのものを持つ。DispatchWorkItem に持たせて
	/// flush で perform する形にはできない (cancel 済みの work item は
	/// perform しても本体が実行されず、書き込みが黙って消える)。
	private var pendingWrite: (key: String, value: String)?
	private var timer: DispatchWorkItem?

	init?() {
		guard let d = UserDefaults(suiteName: Pref.domain) else { return nil }
		defaults = d
	}

	func string(_ key: String, or fallback: String) -> String {
		defaults.string(forKey: key) ?? fallback
	}

	func write(_ key: String, _ value: String) {
		if pendingWrite?.key == key {
			cancelPending()
		}
		defaults.set(value, forKey: key)
	}

	/// スライダーのドラッグ中に毎イベント書き込まないための遅延書き込み。
	/// 表示はイベントごとに更新し、保存だけを間引く。
	func writeDebounced(_ key: String, _ value: String) {
		pendingWrite = (key, value)
		timer?.cancel()
		let work = DispatchWorkItem { [weak self] in self?.flush() }
		timer = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
	}

	/// 遅延中の書き込みを今すぐ実行する。ウィンドウを閉じるときと
	/// アプリの終了時に呼び、最後の 1 回を取りこぼさないため。
	func flush() {
		timer?.cancel()
		timer = nil
		guard let write = pendingWrite else { return }
		pendingWrite = nil
		defaults.set(write.value, forKey: write.key)
	}

	/// 保存した設定をすべて消す。plist が無い状態 (= 既定値) に戻る。
	func resetAll() {
		cancelPending()
		for key in Pref.allKeys {
			defaults.removeObject(forKey: key)
		}
	}

	private func cancelPending() {
		timer?.cancel()
		timer = nil
		pendingWrite = nil
	}
}

// MARK: - 部品

/// ポップアップボタン。現在値の反映と、選択時の保存まで面倒を見る。
func makePopUp(_ spec: Pref.PopUpSpec, _ store: Store,
               onChange: @escaping (String) -> Void) -> NSPopUpButton {
	let button = NSPopUpButton(frame: .zero, pullsDown: false)
	button.addItems(withTitles: spec.choices.map { $0.title })
	for (index, choice) in spec.choices.enumerated() {
		button.item(at: index)?.representedObject = choice.code
	}

	let current = store.string(spec.key, or: spec.fallback)
	let index = spec.choices.firstIndex { $0.code == current }
		?? spec.choices.firstIndex { $0.code == spec.fallback } ?? 0
	button.selectItem(at: index)

	onAction(button) { [weak button] in
		guard let code = button?.selectedItem?.representedObject as? String else { return }
		store.write(spec.key, code)
		onChange(code)
	}
	return button
}

/// チェックボックス。on / off のどちらでも値を明示的に書く。
func makeCheckBox(_ spec: Pref.CheckSpec, _ store: Store) -> NSButton {
	let fallback = spec.onIsDefault ? spec.onValue : spec.offValue
	let current = store.string(spec.key, or: fallback)
	// 未知の値は fallback と同じ扱いにする (読み手側の検証と揃える)
	let isOn = current == spec.onValue || (current != spec.offValue && spec.onIsDefault)

	let button = NSButton(checkboxWithTitle: spec.title, target: nil, action: nil)
	button.state = isOn ? .on : .off

	onAction(button) { [weak button] in
		guard let button = button else { return }
		store.write(spec.key, button.state == .on ? spec.onValue : spec.offValue)
	}
	return button
}

/// target/action をクロージャで書くための小さな受け皿。
/// AppKit は target を弱参照で持つので、コントロール側に紐付けて生かしておく。
final class ActionTrampoline: NSObject {
	private let handler: () -> Void

	init(_ handler: @escaping () -> Void) {
		self.handler = handler
	}

	@objc func fire() {
		handler()
	}
}

/// コントロールが操作されたときの処理をクロージャで指定する。
func onAction(_ control: NSControl, _ handler: @escaping () -> Void) {
	let trampoline = ActionTrampoline(handler)
	control.target = trampoline
	control.action = #selector(ActionTrampoline.fire)
	objc_setAssociatedObject(control, Unmanaged.passUnretained(control).toOpaque(),
	                         trampoline, .OBJC_ASSOCIATION_RETAIN)
}

func makeLabel(_ text: String, small: Bool = false, secondary: Bool = false) -> NSTextField {
	let label = NSTextField(labelWithString: text)
	if small {
		label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
	}
	if secondary {
		label.textColor = .secondaryLabelColor
	}
	return label
}

// MARK: - ウィンドウ

final class PrefsWindowController: NSObject, NSWindowDelegate {
	private let store: Store
	private let window: NSWindow

	private let qualityCaption: NSTextField
	private let qualitySlider: NSSlider
	private let tickLabels: NSStackView
	private var formatPopUp: NSPopUpButton!
	private var originalCheck: NSButton!
	private var trimCheck: NSButton!

	init(store: Store) {
		self.store = store

		window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
			styleMask: [.titled, .closable],
			backing: .buffered,
			defer: false)
		window.title = L.windowTitle

		qualityCaption = makeLabel(L.qualityLabel)
		qualitySlider = NSSlider(value: 85, minValue: 0, maxValue: Pref.losslessTick,
		                         target: nil, action: nil)
		tickLabels = NSStackView(views: [
			makeLabel(L.tickMin, small: true, secondary: true),
			makeLabel(L.tickNormal, small: true, secondary: true),
			makeLabel(L.tickHigh, small: true, secondary: true),
			makeLabel(L.tickLossless, small: true, secondary: true),
		])

		super.init()

		buildUI()
		loadIntoUI()
		window.delegate = self
		window.center()
	}

	// MARK: 組み立て

	private func buildUI() {
		// 出力形式は Keka と同じくタイトルバーの右上に置く。
		formatPopUp = makePopUp(Pref.format, store) { [weak self] _ in
			self?.refreshQualityUI()
		}
		// タイトルバーのアクセサリは frame でサイズを与える。素の NSView は
		// intrinsic size を持たないため、制約だけ書くと幅 0 に潰れて何も見えない。
		formatPopUp.sizeToFit()
		let popUpWidth = max(formatPopUp.frame.width, 110)
		let holder = NSView(frame: NSRect(x: 0, y: 0, width: popUpWidth + 12, height: 30))
		formatPopUp.frame = NSRect(x: 0, y: 2, width: popUpWidth, height: 25)
		holder.addSubview(formatPopUp)

		let accessory = NSTitlebarAccessoryViewController()
		accessory.view = holder
		accessory.layoutAttribute = .right
		window.addTitlebarAccessoryViewController(accessory)

		qualitySlider.isContinuous = true
		qualitySlider.numberOfTickMarks = 6
		qualitySlider.allowsTickMarkValuesOnly = false
		onAction(qualitySlider) { [weak self] in
			self?.qualityChanged()
		}

		tickLabels.orientation = .horizontal
		tickLabels.distribution = .equalSpacing

		originalCheck = makeCheckBox(Pref.original, store)
		trimCheck = makeCheckBox(Pref.trim, store)

		let separator = NSBox()
		separator.boxType = .separator

		let resetButton = NSButton(title: L.resetButton, target: nil, action: nil)
		resetButton.bezelStyle = .rounded
		resetButton.controlSize = .small
		onAction(resetButton) { [weak self] in
			self?.resetToDefaults()
		}

		let resetRow = NSStackView(views: [NSView(), resetButton])
		resetRow.orientation = .horizontal
		resetRow.distribution = .fill

		let hint = makeLabel(L.dropHint, small: true, secondary: true)
		hint.lineBreakMode = .byWordWrapping
		hint.maximumNumberOfLines = 2

		let stack = NSStackView(views: [
			qualityCaption,
			qualitySlider,
			tickLabels,
			separator,
			originalCheck,
			makeLabel(L.originalNote, small: true, secondary: true),
			trimCheck,
			makeLabel(L.trimNote, small: true, secondary: true),
			hint,
			resetRow,
		])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 10
		stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
		stack.setCustomSpacing(4, after: qualityCaption)
		stack.setCustomSpacing(2, after: qualitySlider)
		stack.setCustomSpacing(16, after: tickLabels)
		stack.setCustomSpacing(16, after: separator)
		stack.setCustomSpacing(2, after: originalCheck)
		stack.setCustomSpacing(2, after: trimCheck)

		stack.translatesAutoresizingMaskIntoConstraints = false
		let content = NSView()
		content.addSubview(stack)
		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
			stack.topAnchor.constraint(equalTo: content.topAnchor),
			stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
			qualitySlider.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
			tickLabels.widthAnchor.constraint(equalTo: qualitySlider.widthAnchor),
			hint.widthAnchor.constraint(equalTo: qualitySlider.widthAnchor),
			resetRow.widthAnchor.constraint(equalTo: qualitySlider.widthAnchor),
		])
		window.contentView = content
		window.setContentSize(NSSize(width: 420, height: content.fittingSize.height))
	}

	// MARK: 値の反映

	private func loadIntoUI() {
		qualitySlider.doubleValue = Self.sliderValue(from: store.string(Pref.qualityKey,
		                                                               or: Pref.qualityFallback))
		refreshQualityUI()
	}

	/// defaults の値 → スライダーの位置。"lossless" は最右に置く。
	private static func sliderValue(from stored: String) -> Double {
		if stored == "lossless" { return Pref.losslessTick }
		guard let n = Int(stored), (0...100).contains(n) else {
			return Double(Pref.qualityFallback) ?? 85
		}
		return Double(n)
	}

	/// スライダーの位置 → defaults に書く値。
	private static func storedValue(from slider: Double) -> String {
		let n = Int(slider.rounded())
		return n >= Int(Pref.losslessTick) ? "lossless" : String(n)
	}

	private var selectedFormat: String {
		formatPopUp.selectedItem?.representedObject as? String ?? Pref.format.fallback
	}

	private func qualityChanged() {
		refreshQualityUI()
		store.writeDebounced(Pref.qualityKey, Self.storedValue(from: qualitySlider.doubleValue))
	}

	/// キャプションと有効・無効を、スライダーの位置と出力形式の両方から決める。
	/// スライダーを操作したときと形式を変えたときの両方から呼ぶ。
	private func refreshQualityUI() {
		let format = selectedFormat
		let usesQuality = !Pref.formatsIgnoringQuality.contains(format)

		qualitySlider.isEnabled = usesQuality
		for label in tickLabels.arrangedSubviews.compactMap({ $0 as? NSTextField }) {
			label.textColor = usesQuality ? .secondaryLabelColor : .tertiaryLabelColor
		}

		if !usesQuality {
			// PNG などでは quality を書き換えない。形式を戻せば元の値が復帰する。
			qualityCaption.stringValue = "\(L.qualityLabel) — \(L.qualityUnused)"
			qualityCaption.textColor = .secondaryLabelColor
			return
		}

		qualityCaption.textColor = .labelColor
		let stored = Self.storedValue(from: qualitySlider.doubleValue)
		if stored == "lossless" {
			let text = Pref.formatsWithLossless.contains(format) ? L.qualityLossless : L.qualityBest
			qualityCaption.stringValue = "\(L.qualityLabel): \(text)"
		} else {
			let n = Int(stored) ?? 85
			qualityCaption.stringValue = "\(L.qualityLabel): \(n)（\(L.band(n))）"
		}
	}

	private func resetToDefaults() {
		store.resetAll()
		// UI を既定値に戻す。ポップアップとチェックボックスは作り直さず状態だけ揃える。
		qualitySlider.doubleValue = Self.sliderValue(from: Pref.qualityFallback)
		let index = Pref.format.choices.firstIndex { $0.code == Pref.format.fallback } ?? 0
		formatPopUp.selectItem(at: index)
		originalCheck.state = Pref.original.onIsDefault ? .on : .off
		trimCheck.state = Pref.trim.onIsDefault ? .on : .off
		refreshQualityUI()
	}

	// MARK: 表示と終了

	func show() {
		window.makeKeyAndOrderFront(nil)
		window.orderFrontRegardless()
		NSApp.activate(ignoringOtherApps: true)
	}

	func windowWillClose(_ notification: Notification) {
		store.flush()
		NSApp.terminate(nil)
	}
}

// MARK: - 二重起動の防止
//
// droplet 側はこのバイナリをバックグラウンドで起動して即座に制御を返す
// (同期で待つと、設定ウィンドウを開いている間のドロップが処理されない)。
// そのぶん「二重に開かない」保証はこちら側で持つ。
// 先に起動していたインスタンスがロックを握っているので、後から来た方は
// 通知を投げて自分は終了し、先客がウィンドウを前面に出す。

enum SingleInstance {
	static let showNotification = Notification.Name("io.github.suemura.dropvert.prefs.show")

	private static var lockFD: Int32 = -1
	private static var lockPath: String {
		NSHomeDirectory() + "/Library/Caches/io.github.suemura.dropvert.prefs.lock"
	}

	/// ロックを取れたら true。取れなければ既に別のインスタンスが動いている。
	/// ロックの仕組み自体が使えない環境では、開けないよりはと考えて true を返す。
	static func acquire() -> Bool {
		let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
		guard fd >= 0 else { return true }
		if flock(fd, LOCK_EX | LOCK_NB) != 0 {
			close(fd)
			return false
		}
		// プロセスが生きている間ロックを保持する。閉じると解放されてしまう。
		lockFD = fd
		return true
	}

	static func askRunningInstanceToShow() {
		DistributedNotificationCenter.default().postNotificationName(
			showNotification, object: nil, userInfo: nil, deliverImmediately: true)
	}
}

// MARK: - 起動

final class AppDelegate: NSObject, NSApplicationDelegate {
	private var controller: PrefsWindowController?
	private var store: Store?
	private var keyMonitor: Any?

	func applicationDidFinishLaunching(_ notification: Notification) {
		guard let store = Store() else {
			FileHandle.standardError.write("設定を読み書きできません (\(Pref.domain))\n".data(using: .utf8)!)
			exit(1)
		}
		self.store = store
		let controller = PrefsWindowController(store: store)
		self.controller = controller
		controller.show()

		// 二重起動しようとした側から届く「前面に出して」の合図。
		DistributedNotificationCenter.default().addObserver(
			forName: SingleInstance.showNotification, object: nil, queue: .main
		) { [weak controller] _ in
			controller?.show()
		}

		// activationPolicy が .accessory なのでメニューバーを持たない。
		// ⌘W / ⌘Q が効かなくなるため自前で拾う。
		keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
			guard event.modifierFlags.contains(.command) else { return event }
			switch event.charactersIgnoringModifiers?.lowercased() {
			case "w", "q":
				NSApp.terminate(nil)
				return nil
			default:
				return event
			}
		}
	}

	func applicationWillTerminate(_ notification: Notification) {
		// ⌘Q での終了ではウィンドウの windowWillClose が呼ばれない。
		// ここで念を押しておかないと、遅延中の書き込みが消える。
		store?.flush()
		if let monitor = keyMonitor {
			NSEvent.removeMonitor(monitor)
		}
	}
}

if !SingleInstance.acquire() {
	// 既に開いている。そちらを前面に出してもらって自分は消える。
	SingleInstance.askRunningInstanceToShow()
	exit(0)
}

let app = NSApplication.shared
// .regular にすると Dock に Dropvert とは別のアイコンがもう 1 つ出る。
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
