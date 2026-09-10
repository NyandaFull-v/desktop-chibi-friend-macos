import AppKit

final class SettingsController: NSWindowController, NSWindowDelegate {
    var onSave: ((AppSettings) -> Void)?
    var onPomodoro: (() -> Void)?
    var onRoll: ((Int) -> Void)?
    var onQuit: (() -> Void)?
    private var fields: [String: NSTextField] = [:]
    private let silent = NSButton(checkboxWithTitle: "無言にする", target: nil, action: nil)
    private let effects = NSButton(checkboxWithTitle: "効果音を鳴らす", target: nil, action: nil)
    private let alarmEnabled = NSButton(checkboxWithTitle: "1回だけ有効", target: nil, action: nil)
    private let autoStart = NSButton(checkboxWithTitle: "Mac起動時に起こす", target: nil, action: nil)
    private let collection = NSTextView()
    private let coinLabel = NSTextField(labelWithString: "コイン：0枚")
    private let obsLabel = NSTextField(labelWithString: "")
    private let dice = NSPopUpButton()
    private let activity = NSPopUpButton()
    private var current = AppSettings()

    init(settings: AppSettings, profile: UserProfile) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 690),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "デスクトップちびフレンド \(appDisplayVersion)"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
        update(settings: settings, profile: profile)
    }

    required init?(coder: NSCoder) { nil }

    private func label(_ text: String) -> NSTextField {
        let value = NSTextField(labelWithString: text)
        value.font = .systemFont(ofSize: 13)
        return value
    }

    private func field(_ key: String, width: CGFloat = 72) -> NSTextField {
        let value = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        fields[key] = value
        return value
    }

    private func row(_ title: String, _ controls: [NSView]) -> NSStackView {
        let titleLabel = label(title)
        titleLabel.widthAnchor.constraint(equalToConstant: 170).isActive = true
        let stack = NSStackView(views: [titleLabel] + controls)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        return stack
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let value = NSButton(title: title, target: self, action: action)
        value.bezelStyle = .rounded
        return value
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let left = NSStackView()
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 10
        left.addArrangedSubview(label("表示と出現"))
        left.addArrangedSubview(row("デスクトップサイズ", [field("size"), label("px")]))
        left.addArrangedSubview(row("OBSサイズ", [field("obsSize"), label("px")]))
        activity.addItems(withTitles: ["しずか", "ふつう", "にぎやか"])
        left.addArrangedSubview(row("活動量", [activity]))
        left.addArrangedSubview(row("コイン 最短 / 最長", [field("coinMin", width: 58), label("～"), field("coinMax", width: 58), label("分")]))
        left.addArrangedSubview(row("会話 最短 / 最長", [field("speechMin", width: 58), label("～"), field("speechMax", width: 58), label("分")]))
        left.addArrangedSubview(row("『…たぶん』頻度", [field("maybe"), label("%")]))
        left.addArrangedSubview(silent)
        left.addArrangedSubview(label("ポモドーロ"))
        left.addArrangedSubview(row("集中 / 休憩 / 回数", [field("focus", width: 52), field("break", width: 52), field("loops", width: 52)]))
        left.addArrangedSubview(button("自動開始 / 終了", action: #selector(pomodoroPressed)))
        left.addArrangedSubview(label("通知"))
        left.addArrangedSubview(row("効果音の音量", [field("volume"), label("%")]))
        left.addArrangedSubview(effects)
        left.addArrangedSubview(row("アラーム HH:MM", [field("alarm", width: 80)]))
        left.addArrangedSubview(alarmEnabled)
        left.addArrangedSubview(autoStart)

        let right = NSStackView()
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 10
        let inventoryTop = NSStackView(views: [label("所持品"), coinLabel])
        inventoryTop.orientation = .horizontal
        inventoryTop.spacing = 32
        right.addArrangedSubview(inventoryTop)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 315, height: 350))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        collection.isEditable = false
        collection.isSelectable = true
        collection.font = .systemFont(ofSize: 13)
        collection.frame = NSRect(x: 0, y: 0, width: 315, height: 350)
        collection.autoresizingMask = [.width]
        scroll.documentView = collection
        scroll.widthAnchor.constraint(equalToConstant: 315).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 350).isActive = true
        right.addArrangedSubview(scroll)
        let diceLabel = label("ダイス")
        dice.addItems(withTitles: ["1d3", "1d4", "1d6", "1d10", "1d20", "1d100"])
        dice.selectItem(withTitle: "1d6")
        let diceRow = NSStackView(views: [diceLabel, dice, button("振る", action: #selector(rollPressed))])
        diceRow.orientation = .horizontal
        diceRow.spacing = 10
        right.addArrangedSubview(diceRow)
        obsLabel.maximumNumberOfLines = 2
        right.addArrangedSubview(obsLabel)

        let columns = NSStackView(views: [left, right])
        columns.orientation = .horizontal
        columns.spacing = 28
        columns.alignment = .top
        let save = button("設定を保存", action: #selector(savePressed))
        save.keyEquivalent = "\r"
        let quit = button("アプリを終了", action: #selector(quitPressed))
        let actions = NSStackView(views: [save, quit])
        actions.orientation = .horizontal
        actions.spacing = 14
        let root = NSStackView(views: [columns, actions])
        root.orientation = .vertical
        root.spacing = 18
        root.alignment = .centerX
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18)
        ])
    }

    func update(settings: AppSettings, profile: UserProfile) {
        current = settings
        let values: [String: String] = [
            "size": "\(settings.desktopPetSize)", "obsSize": "\(settings.obsPetSize)",
            "coinMin": "\(settings.coinMinMinutes)", "coinMax": "\(settings.coinMaxMinutes)",
            "speechMin": "\(settings.speechMinMinutes)", "speechMax": "\(settings.speechMaxMinutes)",
            "maybe": "\(settings.maybeFrequency)", "focus": "\(settings.focusMinutes)",
            "break": "\(settings.breakMinutes)", "loops": "\(settings.pomodoroLoops)",
            "volume": "\(settings.effectsVolume)", "alarm": settings.alarmTime
        ]
        for (key, value) in values { fields[key]?.stringValue = value }
        silent.state = settings.silentMode ? .on : .off
        effects.state = settings.effectsEnabled ? .on : .off
        alarmEnabled.state = settings.alarmEnabled ? .on : .off
        autoStart.state = settings.autoStart ? .on : .off
        activity.selectItem(withTitle: settings.activity)
        coinLabel.stringValue = "コイン：\(profile.coins)枚"
        obsLabel.stringValue = "OBS URL: http://127.0.0.1:\(settings.obsPort)/"
        collection.string = itemDefinitions.map { item in
            let count = profile.counts[item.id] ?? 0
            return count > 0 ? "● \(item.name)　× \(count)" : "？ 未収集"
        }.joined(separator: "\n")
    }

    func show(gently: Bool = false) {
        guard let window else { return }
        window.center()
        if gently {
            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                window.animator().alphaValue = 1
            }
        } else {
            showWindow(nil)
            window.orderFrontRegardless()
        }
    }

    private func number(_ key: String, fallback: Int) -> Int { Int(fields[key]?.stringValue ?? "") ?? fallback }
    private func validTime(_ text: String) -> Bool {
        let parts = text.split(separator: ":")
        guard text.count == 5, parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return false }
        return (0..<24).contains(h) && (0..<60).contains(m)
    }

    @objc private func savePressed() {
        var value = current
        value.desktopPetSize = number("size", fallback: 180).clamped(to: 96...420)
        value.obsPetSize = number("obsSize", fallback: 180).clamped(to: 96...420)
        value.activity = activity.titleOfSelectedItem ?? "ふつう"
        value.coinMinMinutes = number("coinMin", fallback: 15).clamped(to: 1...60)
        value.coinMaxMinutes = number("coinMax", fallback: 30).clamped(to: value.coinMinMinutes...60)
        value.speechMinMinutes = number("speechMin", fallback: 8).clamped(to: 1...240)
        value.speechMaxMinutes = number("speechMax", fallback: 15).clamped(to: value.speechMinMinutes...240)
        value.maybeFrequency = number("maybe", fallback: 30).clamped(to: 0...100)
        value.focusMinutes = number("focus", fallback: 25).clamped(to: 1...240)
        value.breakMinutes = number("break", fallback: 5).clamped(to: 1...120)
        value.pomodoroLoops = number("loops", fallback: 4).clamped(to: 1...20)
        value.effectsVolume = number("volume", fallback: 65).clamped(to: 0...100)
        value.alarmTime = fields["alarm"]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        value.silentMode = silent.state == .on
        value.effectsEnabled = effects.state == .on
        value.alarmEnabled = alarmEnabled.state == .on && validTime(value.alarmTime)
        value.autoStart = autoStart.state == .on
        current = value
        onSave?(value)
    }

    @objc private func pomodoroPressed() { savePressed(); onPomodoro?() }
    @objc private func rollPressed() {
        let sides = [3, 4, 6, 10, 20, 100]
        onRoll?(sides[dice.indexOfSelectedItem.clamped(to: 0...(sides.count - 1))])
    }
    @objc private func quitPressed() { onQuit?() }
}
