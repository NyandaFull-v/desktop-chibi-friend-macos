import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PetController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        guard let sprites = SpriteStore(), let pet = PetController(sprites: sprites) else {
            let alert = NSAlert()
            alert.messageText = "起動できませんでした"
            alert.informativeText = "Contents/Resources/characters/chibidaful に画像一式があるか確認してください。"
            alert.runModal()
            NSApplication.shared.terminate(nil)
            return
        }
        controller = pet
        installStatusMenu()
    }

    func applicationWillTerminate(_ notification: Notification) { controller?.prepareForTermination() }

    private func installStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = "🐾"
        item.button?.toolTip = "デスクトップちびフレンド \(appDisplayVersion)"
        let menu = NSMenu()
        menu.addItem(withTitle: "設定を開く", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "ポモドーロ 開始 / 終了", action: #selector(togglePomodoro), keyEquivalent: "p").target = self
        let diceMenu = NSMenu(title: "ダイス")
        for sides in [3, 4, 6, 10, 20, 100] {
            let dice = NSMenuItem(title: "1d\(sides)", action: #selector(rollDice(_:)), keyEquivalent: "")
            dice.tag = sides; dice.target = self; diceMenu.addItem(dice)
        }
        let diceRoot = NSMenuItem(title: "ダイスを振る", action: nil, keyEquivalent: "")
        diceRoot.submenu = diceMenu
        menu.addItem(diceRoot)
        menu.addItem(.separator())
        menu.addItem(withTitle: "アプリを終了", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func openSettings() { controller?.showSettings() }
    @objc private func togglePomodoro() { controller?.menuPomodoro() }
    @objc private func rollDice(_ sender: NSMenuItem) { controller?.rollDice(sides: sender.tag) }
    @objc private func quit() { controller?.quitFromMenu() }
}
