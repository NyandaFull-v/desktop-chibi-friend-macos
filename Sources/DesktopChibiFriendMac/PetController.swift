import AppKit
import Foundation

final class WorldObject {
    let panel: TransparentPanel
    let view: ObjectView
    let kind: ObjectKind
    let itemIndex: Int?
    var velocityY: CGFloat = 0
    var expiry: Date?
    var dragged = false
    var dragOffset = CGPoint.zero

    init(panel: TransparentPanel, view: ObjectView, kind: ObjectKind, itemIndex: Int?) {
        self.panel = panel
        self.view = view
        self.kind = kind
        self.itemIndex = itemIndex
    }
}

final class PetController: NSObject {
    private let storage: Storage
    private let sprites: SpriteStore
    private(set) var settings: AppSettings
    private(set) var profile: UserProfile
    private let petPanel: TransparentPanel
    private let petView: PetView
    private var settingsController: SettingsController?
    private let mouseMonitor = GlobalMouseMonitor()
    private let obsServer = OBSHTTPServer()
    private var objects: [WorldObject] = []
    private var cavePanel: TransparentPanel?
    private var bubblePanel: TransparentPanel?
    private var bubbleView: BubbleView?
    private var bubbleExpiry: Date?
    private var bubbleThrown = false
    private var bubbleVelocity = CGVector.zero
    private var timer: Timer?
    private var lastTick = Date()
    private var lastTerrainScan = Date.distantPast
    private var lastSystemCheck = Date.distantPast
    private var surfaces: [Surface] = []
    private var mode: PetMode = .normal
    private var pausedMode: PetMode = .normal
    private var pose: Pose = .stand
    private var frames: [NSImage] = []
    private var frameIndex = 0
    private var lastFrameChange = Date()
    private var facesRight = true
    private var velocity = CGVector.zero
    private var dragOffset = CGPoint.zero
    private var lastDragPoint = CGPoint.zero
    private var lastDragTime = Date()
    private var nextAction = Date().addingTimeInterval(5)
    private var targetSurface: Int?
    private var targetX: CGFloat = 0
    private var climbingWillSucceed = false
    private var phantomClimb = false
    private weak var summonedTarget: WorldObject?
    private var pokeTimes: [Date] = []
    private var obsActive = false
    private var blocked = false
    private var homeUntil: Date?
    private var homeWasAngry = false
    private var shoppingDue: Date?
    private var pendingPurchase: Int?
    private var pomodoroActive = false
    private var pomodoroBreak = false
    private var pomodoroRound = 1
    private var pomodoroDue: Date?
    private var lastHourlyKey = ""
    private var lastAlarmKey = ""
    private var alertBaseY: CGFloat = 0
    private var pausedAt: Date?
    private var obsPausedAt: Date?
    private var activeSound: NSSound?

    init?(sprites: SpriteStore) {
        let persistence = Storage()
        let loadedSettings = persistence.loadSettings()
        let loadedProfile = persistence.loadProfile()
        storage = persistence
        self.sprites = sprites
        settings = loadedSettings
        profile = loadedProfile
        let size = CGFloat(loadedSettings.desktopPetSize)
        let primary = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
        let x = loadedProfile.lastX >= 0 ? CGFloat(loadedProfile.lastX) : primary.minX + 30
        let y = loadedProfile.lastY >= 0 ? CGFloat(loadedProfile.lastY) : primary.minY
        petPanel = TransparentPanel(frame: NSRect(x: x, y: y, width: size, height: size))
        petView = PetView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        super.init()
        petPanel.contentView = petView
        connectInput()
        setPose(.stand)
        petPanel.orderFrontRegardless()
        mouseMonitor.onBlankRightDoubleClick = { [weak self] point in self?.blankRightDoubleClick(at: point) }
        mouseMonitor.onBlankLeftTripleClick = { [weak self] point in self?.blankLeftTripleClick(at: point) }
        mouseMonitor.start()
        installWorkspaceObservers()
        scanTerrain()
        if settings.autoStart { try? MacSystem.setLoginItem(enabled: true) }
        timer = Timer.scheduledTimer(timeInterval: 1.0 / 30.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        scheduleAction(3...7)
        if profile.nextCoinUnix <= Date().timeIntervalSince1970 { scheduleCoin() }
        if profile.nextSpeechUnix <= Date().timeIntervalSince1970 { scheduleSpeech() }
    }

    deinit {
        timer?.invalidate()
        mouseMonitor.stop()
        obsServer.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    private var petSize: CGFloat { CGFloat(settings.desktopPetSize) }

    private func connectInput() {
        petView.onPoke = { [weak self] in self?.poke() }
        petView.onRightClick = { [weak self] in self?.showSettings() }
        petView.onDragBegan = { [weak self] _ in self?.beginDrag() }
        petView.onDragged = { [weak self] _ in self?.dragPet() }
        petView.onDragEnded = { [weak self] _ in self?.endDrag() }
        petView.onPetting = { [weak self] in self?.petting() }
    }

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(systemPaused), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(systemPaused), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(systemResumed), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(systemResumed), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func systemPaused() {
        if mode != .paused { pausedMode = mode; mode = .paused; pausedAt = Date() }
    }

    @objc private func systemResumed() {
        if mode == .paused {
            if let pausedAt { shiftSchedules(by: Date().timeIntervalSince(pausedAt)) }
            self.pausedAt = nil
            mode = pausedMode
            lastTick = Date()
            scanTerrain()
        }
    }

    @objc private func screenChanged() { scanTerrain(); keepRecoverable() }

    func showSettings(gently: Bool = false) {
        if settingsController == nil {
            let controller = SettingsController(settings: settings, profile: profile)
            controller.onSave = { [weak self] in self?.apply(settings: $0) }
            controller.onPomodoro = { [weak self] in self?.togglePomodoro() }
            controller.onRoll = { [weak self] in self?.rollDice(sides: $0) }
            controller.onQuit = { [weak self] in self?.confirmQuit() }
            settingsController = controller
        }
        settingsController?.update(settings: settings, profile: profile)
        settingsController?.show(gently: gently)
    }

    private func apply(settings newValue: AppSettings) {
        let oldSize = settings.desktopPetSize
        settings = newValue
        if oldSize != settings.desktopPetSize {
            petPanel.setContentSize(NSSize(width: petSize, height: petSize))
            petView.frame = NSRect(x: 0, y: 0, width: petSize, height: petSize)
            setPose(pose, force: true)
            keepRecoverable()
        }
        do { try MacSystem.setLoginItem(enabled: settings.autoStart) }
        catch { showBubble("自動起動は、システム設定の『ログイン項目』で許可して。") }
        save()
        showBubble(settings.alarmEnabled || settings.alarmTime.isEmpty || validAlarm(settings.alarmTime) ? "設定した。" : "アラームはHH:MMで入れて。")
    }

    private func confirmQuit() {
        let alert = NSAlert()
        alert.messageText = "ちび堕ふるを終了しますか？"
        alert.informativeText = "移動した通常ウィンドウはないため、復元対象はありません。"
        alert.addButton(withTitle: "終了する")
        alert.addButton(withTitle: "やめる")
        if alert.runModal() == .alertFirstButtonReturn {
            save()
            NSApplication.shared.terminate(nil)
        }
    }

    func rollDice(sides: Int) {
        guard [3, 4, 6, 10, 20, 100].contains(sides) else { return }
        velocity = .zero
        targetSurface = nil
        if mode != .alert { mode = .normal }
        setPose(.dice)
        showBubble("1d\(sides) → \(Int.random(in: 1...sides))！")
        scheduleAction(4...5)
    }

    func menuPomodoro() { togglePomodoro() }
    func quitFromMenu() { confirmQuit() }
    func prepareForTermination() { save(); obsServer.stop(); mouseMonitor.stop() }

    private func save() {
        profile.lastX = petPanel.frame.minX
        profile.lastY = petPanel.frame.minY
        storage.save(settings: settings, profile: profile)
        settingsController?.update(settings: settings, profile: profile)
    }

    private func setPose(_ value: Pose, force: Bool = false) {
        if !force, pose == value, !frames.isEmpty { return }
        pose = value
        frames = sprites.frames(for: value, size: petSize)
        frameIndex = 0
        lastFrameChange = Date()
        petView.image = frames.first
        petView.facesRight = facesRight
    }

    private func animate(now: Date) {
        guard frames.count > 1, now.timeIntervalSince(lastFrameChange) >= 0.16 else { return }
        lastFrameChange = now
        frameIndex = (frameIndex + 1) % frames.count
        petView.image = frames[frameIndex]
    }

    private func movePet(x: CGFloat? = nil, y: CGFloat? = nil) {
        var origin = petPanel.frame.origin
        if let x { origin.x = x }
        if let y { origin.y = y }
        petPanel.setFrameOrigin(origin)
        positionBubble()
    }

    private func beginDrag() {
        if mode == .alert { dismissAlert(); return }
        let point = NSEvent.mouseLocation
        dragOffset = CGPoint(x: point.x - petPanel.frame.minX, y: point.y - petPanel.frame.minY)
        lastDragPoint = point
        lastDragTime = Date()
        velocity = .zero
        mode = .dragged
    }

    private func dragPet() {
        guard mode == .dragged else { return }
        let point = NSEvent.mouseLocation
        let now = Date(), dt = max(0.005, now.timeIntervalSince(lastDragTime))
        velocity.dx = (point.x - lastDragPoint.x) / dt
        velocity.dy = (point.y - lastDragPoint.y) / dt
        lastDragPoint = point
        lastDragTime = now
        movePet(x: point.x - dragOffset.x, y: point.y - dragOffset.y)
    }

    private func endDrag() {
        guard mode == .dragged else { return }
        velocity.dx = velocity.dx.clamped(to: -1100...1100)
        velocity.dy = velocity.dy.clamped(to: -900...900)
        mode = .falling
        setPose(.fall)
    }

    private func petting() {
        guard mode == .dragged || mode == .normal else { return }
        mode = .normal
        velocity = .zero
        setPose(.petting)
        showBubble(Bool.random() ? "わーい！　💙" : "……もう少し。💙")
        scheduleAction(4...7)
    }

    private func poke() {
        if mode == .alert { dismissAlert(); return }
        if mode == .angryHome || mode == .blockedHome || mode == .obsRest { return }
        if mode == .dragged { mode = .normal }
        let now = Date()
        pokeTimes = (pokeTimes + [now]).filter { now.timeIntervalSince($0) <= 300 }
        velocity = .zero
        if pokeTimes.count >= 10 {
            pokeTimes.removeAll()
            showBubble("むすーっ。もう帰る。")
            enterHome(angry: true)
        } else if pokeTimes.count >= 7 {
            setPose(.trip); showBubble("いたい。")
        } else if pokeTimes.count >= 4 {
            setPose(.look); showBubble("ますた、まだやるの？")
        } else {
            setPose(.look); showBubble(["ますた、なに？", "びくっ。", "わっ。"].randomElement()!)
        }
        scheduleAction(3...6)
    }

    private func showBubble(_ text: String, alert: Bool = false) {
        hideBubble()
        let width = min(520, max(150, CGFloat(text.count) * 15 + 34))
        let height: CGFloat = text.count > 28 ? 62 : 46
        let panel = TransparentPanel(frame: NSRect(x: 0, y: 0, width: width, height: height), level: .statusBar)
        let view = BubbleView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.label.stringValue = text
        view.onClick = { [weak self] in
            if self?.mode == .alert { self?.dismissAlert() } else { self?.hideBubble() }
        }
        panel.contentView = view
        bubblePanel = panel
        bubbleView = view
        bubbleExpiry = alert ? nil : Date().addingTimeInterval(max(3, Double(text.count) / 2.0))
        bubbleThrown = false
        positionBubble()
        panel.orderFrontRegardless()
    }

    private func positionBubble() {
        guard let panel = bubblePanel, !bubbleThrown else { return }
        let screen = screen(containing: petPanel.frame.center) ?? NSScreen.screens.first
        guard let area = screen?.visibleFrame else { return }
        var x = petPanel.frame.midX - panel.frame.width / 2
        var y = petPanel.frame.maxY + 5
        if y + panel.frame.height > area.maxY { y = petPanel.frame.minY - panel.frame.height - 5 }
        x = x.clamped(to: area.minX...max(area.minX, area.maxX - panel.frame.width))
        y = y.clamped(to: area.minY...max(area.minY, area.maxY - panel.frame.height))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func throwBubble() {
        guard bubblePanel != nil else { return }
        bubbleThrown = true
        bubbleVelocity = CGVector(dx: facesRight ? 380 : -380, dy: 260)
    }

    private func hideBubble() {
        bubblePanel?.orderOut(nil)
        bubblePanel = nil
        bubbleView = nil
        bubbleExpiry = nil
        bubbleThrown = false
    }

    private func updateBubble(dt: TimeInterval, now: Date) {
        guard let panel = bubblePanel else { return }
        if let expiry = bubbleExpiry, now >= expiry { hideBubble(); return }
        guard bubbleThrown else { return }
        let delta = CGFloat(dt)
        bubbleVelocity.dy -= 720 * delta
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX + bubbleVelocity.dx * delta, y: panel.frame.minY + bubbleVelocity.dy * delta))
        if !NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -panel.frame.width, dy: -panel.frame.height).intersects(panel.frame) }) { hideBubble() }
    }

    private func blankRightDoubleClick(at point: CGPoint) {
        guard mode != .angryHome, mode != .blockedHome, mode != .obsRest, mode != .paused, !blocked else { return }
        let owned = itemDefinitions.enumerated().filter { profile.unlocked.contains($0.element.id) }
        guard let pick = owned.randomElement() else { return }
        objects.filter { $0.kind == .item }.forEach { removeObject($0) }
        let object = spawnObject(kind: .item, itemIndex: pick.offset,
                                 origin: CGPoint(x: point.x - 48, y: point.y + 15))
        summonedTarget = object
        showBubble("見つけた。行く！")
        beginChase()
    }

    private func blankLeftTripleClick(at point: CGPoint) {
        guard mode == .angryHome else { return }
        pokeTimes.removeAll()
        leaveHome(from: point)
    }

    @discardableResult
    private func spawnObject(kind: ObjectKind, itemIndex: Int?, origin: CGPoint) -> WorldObject? {
        let size: CGFloat = kind == .coin ? 54 : 96
        let image: NSImage?
        if kind == .coin { image = sprites.coin(size: size) }
        else if let itemIndex, itemDefinitions.indices.contains(itemIndex) { image = sprites.item(itemDefinitions[itemIndex], size: size) }
        else { image = nil }
        guard let image else { return nil }
        let panel = TransparentPanel(frame: NSRect(x: origin.x, y: origin.y, width: size, height: size), level: .floating)
        let view = ObjectView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.image = image
        panel.contentView = view
        let object = WorldObject(panel: panel, view: view, kind: kind, itemIndex: itemIndex)
        object.expiry = kind == .coin ? Date().addingTimeInterval(3600) : (kind == .showcase ? Date().addingTimeInterval(5) : nil)
        view.onDrag = { [weak self, weak object] phase, _ in self?.dragObject(object, phase: phase) }
        objects.append(object)
        panel.orderFrontRegardless()
        return object
    }

    private func dragObject(_ object: WorldObject?, phase: NSEvent.Phase) {
        guard let object else { return }
        let mouse = NSEvent.mouseLocation
        if phase.contains(.began) {
            object.dragged = true
            object.dragOffset = CGPoint(x: mouse.x - object.panel.frame.minX, y: mouse.y - object.panel.frame.minY)
        } else if phase.contains(.changed) {
            object.panel.setFrameOrigin(NSPoint(x: mouse.x - object.dragOffset.x, y: mouse.y - object.dragOffset.y))
        } else if phase.contains(.ended) {
            object.dragged = false
            object.velocityY = 0
        }
    }

    private func removeObject(_ object: WorldObject) {
        object.panel.orderOut(nil)
        objects.removeAll { $0 === object }
        if summonedTarget === object { summonedTarget = nil }
    }

    private func spawnCoin() {
        guard let screen = screen(containing: petPanel.frame.center) ?? NSScreen.screens.randomElement() else { return }
        let x = CGFloat.random(in: (screen.visibleFrame.minX + 25)...max(screen.visibleFrame.minX + 26, screen.visibleFrame.maxX - 80))
        _ = spawnObject(kind: .coin, itemIndex: nil, origin: CGPoint(x: x, y: screen.frame.maxY + 20))
        scheduleCoin()
    }

    private func updateObjects(dt: TimeInterval, now: Date) {
        let delta = CGFloat(dt)
        for object in Array(objects.reversed()) {
            if let expiry = object.expiry, now >= expiry { removeObject(object); continue }
            if !object.dragged, object.kind != .showcase {
                let oldBottom = object.panel.frame.minY
                object.velocityY -= 900 * delta
                var y = oldBottom + object.velocityY * delta
                let centerX = object.panel.frame.midX
                var landing: CGFloat?
                if object.velocityY <= 0 {
                    for surface in surfaces where centerX >= surface.rect.minX + 5 && centerX <= surface.rect.maxX - 5 {
                        let top = surface.rect.maxY
                        if oldBottom >= top - 2, y <= top + 2, landing == nil || top > landing! { landing = top }
                    }
                }
                if let landing { y = landing; object.velocityY = 0 }
                object.panel.setFrameOrigin(NSPoint(x: object.panel.frame.minX, y: y))
                if !NSScreen.screens.contains(where: { $0.frame.insetBy(dx: 120, dy: 120).intersects(object.panel.frame) }) {
                    if object.kind == .item { removeObject(object) }
                    else if let primary = NSScreen.screens.first { object.panel.setFrameOrigin(NSPoint(x: primary.frame.midX, y: primary.frame.maxY + 20)); object.velocityY = 0 }
                }
            }
            if !object.dragged && (object.kind == .coin || object.kind == .item) {
                let distance = hypot(object.panel.frame.midX - petPanel.frame.midX, object.panel.frame.midY - petPanel.frame.midY)
                if distance < petSize * 0.43 + object.panel.frame.width * 0.25 { collect(object) }
            }
        }
    }

    private func collect(_ object: WorldObject) {
        let kind = object.kind, index = object.itemIndex
        removeObject(object)
        velocity = .zero
        if kind == .coin {
            profile.coins += 1
            setPose(.joy)
            showBubble("コイン！ うれしい。")
        } else if kind == .item, let index, itemDefinitions.indices.contains(index) {
            let item = itemDefinitions[index]
            profile.counts[item.id, default: 0] += 1
            setPose(item.category == .sweet ? .sit : .joy)
            showBubble(item.reaction)
        }
        save()
        scheduleAction(4...7)
    }

    private func beginChase() {
        guard let object = summonedTarget else { return }
        if object.panel.frame.minY > petPanel.frame.minY + 60,
           let index = surfaces.indices.min(by: { abs(surfaces[$0].rect.maxY - object.panel.frame.minY) < abs(surfaces[$1].rect.maxY - object.panel.frame.minY) }),
           abs(surfaces[index].rect.maxY - object.panel.frame.minY) < 22, !surfaces[index].floor {
            targetSurface = index
            let rect = surfaces[index].rect
            targetX = abs(petPanel.frame.midX - rect.minX) < abs(petPanel.frame.midX - rect.maxX) ? rect.minX - petSize * 0.58 : rect.maxX - petSize * 0.42
            facesRight = targetX > petPanel.frame.minX
            velocity.dx = facesRight ? 180 : -180
            setPose(.dash)
        } else {
            targetSurface = nil
            facesRight = object.panel.frame.midX > petPanel.frame.midX
            velocity.dx = facesRight ? 250 : -250
            setPose(.dash)
        }
    }

    private func scanTerrain() {
        surfaces = MacSystem.surfaces(ownPID: ProcessInfo.processInfo.processIdentifier)
        lastTerrainScan = Date()
    }

    private func supported(x: CGFloat, bottom: CGFloat) -> Int? {
        surfaces.indices
            .filter { x >= surfaces[$0].rect.minX + 6 && x <= surfaces[$0].rect.maxX - 6 && abs(bottom - surfaces[$0].rect.maxY) < 15 }
            .min { abs(bottom - surfaces[$0].rect.maxY) < abs(bottom - surfaces[$1].rect.maxY) }
    }

    private func selectWindowTarget() {
        let center = petPanel.frame.center
        let candidates = surfaces.indices.filter { !surfaces[$0].floor && surfaces[$0].rect.maxY > petPanel.frame.minY + 25 }
        guard let index = candidates.min(by: {
            let a = min(abs(center.x - surfaces[$0].rect.minX), abs(center.x - surfaces[$0].rect.maxX)) + abs(center.y - surfaces[$0].rect.midY) * 0.2
            let b = min(abs(center.x - surfaces[$1].rect.minX), abs(center.x - surfaces[$1].rect.maxX)) + abs(center.y - surfaces[$1].rect.midY) * 0.2
            return a < b
        }) else { randomWalk(); return }
        targetSurface = index
        let rect = surfaces[index].rect
        targetX = abs(center.x - rect.minX) < abs(center.x - rect.maxX) ? rect.minX - petSize * 0.58 : rect.maxX - petSize * 0.42
        facesRight = targetX > petPanel.frame.minX
        velocity.dx = facesRight ? 155 : -155
        setPose(.walk)
    }

    private func beginFall(impulse: CGFloat = 0) {
        mode = .falling
        velocity.dy = impulse
        targetSurface = nil
        setPose(.fall)
    }

    private func randomWalk() {
        targetSurface = nil
        facesRight = Bool.random()
        velocity.dx = facesRight ? CGFloat.random(in: 70...130) : -CGFloat.random(in: 70...130)
        setPose(.walk)
        scheduleAction(3...7)
    }

    private func randomAction() {
        guard mode == .normal, !obsActive, !blocked, summonedTarget == nil else { return }
        let roll = Int.random(in: 0..<100)
        if roll < 44 { selectWindowTarget(); scheduleAction(8...15) }
        else if roll < 56 { randomWalk() }
        else if roll < 69 { velocity = .zero; setPose(.sit); scheduleAction(5...12) }
        else if roll < 80 { velocity = .zero; setPose(.sleep); scheduleAction(10...22) }
        else if roll < 86 { velocity = .zero; setPose(.look); scheduleAction(3...5) }
        else if roll < 90 { phantomClimb = true; mode = .climbing; velocity = .zero; setPose(.climb); scheduleAction(2...4) }
        else if roll < 96 {
            velocity = .zero; setPose(.dig); scheduleAction(4...7)
            if Int.random(in: 0..<100) < 6 { profile.coins += 1; showBubble("……あった！ コイン！"); save() }
        } else if roll < 98 { facesRight = Bool.random(); velocity.dx = facesRight ? 420 : -420; setPose(.dash); scheduleAction(2...4) }
        else if roll < 99 { velocity = .zero; setPose(.trip); scheduleAction(2...3) }
        else { velocity = .zero; setPose(.sit); showBubble("♪　♪"); scheduleAction(5...9) }
    }

    private func scheduleAction(_ range: ClosedRange<Double>) {
        var delay = Double.random(in: range)
        if settings.activity == "しずか" { delay += 5 }
        if settings.activity == "にぎやか" { delay = max(1, delay - 2) }
        nextAction = Date().addingTimeInterval(delay)
    }

    private func scheduleCoin() {
        let low = settings.coinMinMinutes.clamped(to: 1...60)
        let high = settings.coinMaxMinutes.clamped(to: low...60)
        profile.nextCoinUnix = Date().timeIntervalSince1970 + Double(Int.random(in: low...high) * 60)
        save()
    }

    private func scheduleSpeech() {
        let low = settings.speechMinMinutes.clamped(to: 1...240)
        let high = settings.speechMaxMinutes.clamped(to: low...240)
        profile.nextSpeechUnix = Date().timeIntervalSince1970 + Double(Int.random(in: low...high) * 60)
        save()
    }

    private func shopping() {
        guard profile.coins >= 10, mode == .normal, !obsActive, !blocked, homeUntil == nil else { return }
        let locked = itemDefinitions.indices.filter { !profile.unlocked.contains(itemDefinitions[$0].id) }
        let index = locked.randomElement() ?? itemDefinitions.indices.randomElement()!
        profile.coins -= 5
        let item = itemDefinitions[index]
        if !profile.unlocked.contains(item.id) { profile.unlocked.append(item.id) }
        profile.counts[item.id, default: 0] += 1
        pendingPurchase = index
        save()
        mode = .shopping
        velocity = .zero
        setPose(.dash)
        showBubble("お店、行ってくる！")
        showCave(at: petPanel.frame.origin)
        showSettings(gently: true)
        shoppingDue = Date().addingTimeInterval(2.2)
    }

    private func finishShopping() {
        guard mode == .shopping else { return }
        cavePanel?.orderOut(nil); cavePanel = nil
        settingsController?.close()
        mode = .normal
        shoppingDue = nil
        if let index = pendingPurchase {
            pendingPurchase = nil
            setPose(.joy)
            showBubble("見て、ますた！　\(itemDefinitions[index].name)！")
            _ = spawnObject(kind: .showcase, itemIndex: index, origin: CGPoint(x: petPanel.frame.maxX - 30, y: petPanel.frame.midY))
        }
        if profile.coins >= 10 { nextAction = Date().addingTimeInterval(7) }
        else { scheduleAction(5...9) }
    }

    private func showCave(at point: CGPoint) {
        cavePanel?.orderOut(nil)
        let panel = TransparentPanel(frame: NSRect(x: point.x, y: point.y, width: 180, height: 180))
        panel.contentView = CaveView(frame: NSRect(x: 0, y: 0, width: 180, height: 180))
        cavePanel = panel
        panel.orderFrontRegardless()
    }

    private func enterHome(angry: Bool) {
        homeWasAngry = angry
        mode = angry ? .angryHome : .blockedHome
        velocity = .zero
        showCave(at: petPanel.frame.origin)
        homeUntil = Date().addingTimeInterval(1.2)
    }

    private func leaveHome(from point: CGPoint? = nil) {
        let primary = NSScreen.screens.first?.visibleFrame ?? .zero
        let origin = point ?? CGPoint(x: primary.minX, y: primary.minY)
        showCave(at: CGPoint(x: origin.x.clamped(to: primary.minX...max(primary.minX, primary.maxX - 180)), y: primary.minY))
        movePet(x: cavePanel!.frame.minX + 5, y: primary.minY)
        petPanel.orderFrontRegardless()
        mode = .normal
        homeWasAngry = false
        homeUntil = Date().addingTimeInterval(0.9)
        setPose(.walk)
        facesRight = true
        velocity.dx = 90
        showBubble("……ただいま。")
    }

    private func updateHome(now: Date) {
        guard let due = homeUntil, now >= due else { return }
        homeUntil = nil
        if mode == .angryHome || mode == .blockedHome {
            petPanel.orderOut(nil)
            cavePanel?.orderOut(nil)
            cavePanel = nil
            hideBubble()
        } else {
            cavePanel?.orderOut(nil)
            cavePanel = nil
        }
    }

    private func updateOBS(now: Date) {
        let active = MacSystem.isOBSRunning()
        guard active != obsActive else { return }
        obsActive = active
        if active {
            obsPausedAt = now
            if mode == .shopping { shoppingDue = nil; settingsController?.close() }
            _ = obsServer.start(port: settings.obsPort, root: sprites.root, petSize: settings.obsPetSize,
                                coinMin: settings.coinMinMinutes, coinMax: settings.coinMaxMinutes)
            mode = .obsRest
            petPanel.orderOut(nil); hideBubble(); objects.forEach { $0.panel.orderOut(nil) }
        } else {
            obsServer.stop()
            if let obsPausedAt { shiftSchedules(by: now.timeIntervalSince(obsPausedAt)) }
            self.obsPausedAt = nil
            if mode == .obsRest {
                let primary = NSScreen.screens.first?.visibleFrame ?? .zero
                mode = .normal
                objects.forEach { $0.panel.orderFrontRegardless() }
                leaveHome(from: CGPoint(x: primary.minX, y: primary.minY))
            }
        }
    }

    private func updateBlocked() {
        guard !obsActive, mode != .alert, mode != .angryHome else { return }
        let value = MacSystem.blockedScreen()
        let petCenter = petPanel.frame.center
        if value?.fullscreen == true, pomodoroActive { stopPomodoro() }
        if let value, value.screen.frame.contains(petCenter) {
            if mode == .shopping { shoppingDue = nil; settingsController?.close() }
            if let destination = NSScreen.screens.filter({ $0 !== value.screen }).min(by: { abs($0.frame.midX - petCenter.x) < abs($1.frame.midX - petCenter.x) }) {
                mode = .falling
                movePet(x: destination.visibleFrame.midX - petSize / 2, y: destination.frame.maxY + 10)
                velocity = CGVector(dx: 0, dy: -120)
                setPose(.fall)
                showBubble(value.game ? "ゲーム中。あっちにいる。" : "全力で避難！！")
            } else {
                enterHome(angry: false)
            }
            blocked = true
        } else {
            if blocked, mode == .blockedHome { leaveHome() }
            blocked = false
        }
        if let value {
            for object in objects {
                if value.screen.frame.intersects(object.panel.frame) { object.panel.orderOut(nil) }
                else { object.panel.orderFrontRegardless() }
            }
        } else if mode != .angryHome && mode != .blockedHome {
            objects.forEach { $0.panel.orderFrontRegardless() }
        }
    }

    private func checkClock(now: Date) {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let key = "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)-\(parts.hour ?? 0)"
        if parts.minute == 0, key != lastHourlyKey, !obsActive {
            lastHourlyKey = key
            showBubble("\(parts.hour ?? 0)時だよ！")
        }
        let minuteKey = "\(key)-\(parts.minute ?? 0)"
        if settings.alarmEnabled, settings.alarmTime == String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0), minuteKey != lastAlarmKey {
            lastAlarmKey = minuteKey
            settings.alarmEnabled = false
            save()
            if !obsActive { playAlert(text: "時間！！") }
        }
        if pomodoroActive, let due = pomodoroDue, now >= due {
            if pomodoroBreak {
                pomodoroBreak = false
                pomodoroRound += 1
                if pomodoroRound > settings.pomodoroLoops { pomodoroActive = false; pomodoroDue = nil; playAlert(text: "おわり！！") }
                else { pomodoroDue = now.addingTimeInterval(Double(settings.focusMinutes * 60)); playAlert(text: "集中、はじめ！") }
            } else {
                pomodoroBreak = true
                pomodoroDue = now.addingTimeInterval(Double(settings.breakMinutes * 60))
                playAlert(text: "おわり！！")
            }
        }
    }

    private func validAlarm(_ text: String) -> Bool {
        let parts = text.split(separator: ":")
        guard text.count == 5, parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return false }
        return (0..<24).contains(h) && (0..<60).contains(m)
    }

    private func togglePomodoro() {
        pomodoroActive ? stopPomodoro() : startPomodoro()
    }

    private func startPomodoro() {
        pomodoroActive = true; pomodoroBreak = false; pomodoroRound = 1
        pomodoroDue = Date().addingTimeInterval(Double(settings.focusMinutes * 60))
        showBubble("集中、はじめ！")
    }

    private func stopPomodoro() {
        pomodoroActive = false; pomodoroDue = nil
        if mode == .alert { dismissAlert() }
        showBubble("ポモドーロ終了。")
    }

    private func playAlert(text: String) {
        if settings.effectsEnabled, !obsActive { playTone(volume: settings.effectsVolume) }
        if let blocked = MacSystem.blockedScreen() {
            movePet(x: blocked.screen.frame.midX - petSize / 2, y: blocked.screen.frame.maxY - petSize - 24)
        }
        alertBaseY = petPanel.frame.minY
        mode = .alert
        velocity = .zero
        petPanel.orderFrontRegardless()
        setPose(.joy)
        showBubble(text, alert: true)
    }

    private func dismissAlert() {
        guard mode == .alert else { hideBubble(); return }
        hideBubble(); mode = .normal; movePet(y: alertBaseY); setPose(.stand); scheduleAction(3...6)
    }

    private func playTone(volume: Int) {
        let sampleRate = 22_050, count = 5_512
        var pcm = Data(capacity: count)
        for index in 0..<count {
            let hz = index < count / 2 ? 740.0 : 988.0
            let sample = UInt8((128.0 + sin(2 * .pi * hz * Double(index) / Double(sampleRate)) * Double(volume.clamped(to: 0...100))).clamped(to: 0...255))
            pcm.append(sample)
        }
        var wav = Data("RIFF".utf8)
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        append32(UInt32(36 + pcm.count)); wav.append(Data("WAVEfmt ".utf8)); append32(16); append16(1); append16(1)
        append32(UInt32(sampleRate)); append32(UInt32(sampleRate)); append16(1); append16(8)
        wav.append(Data("data".utf8)); append32(UInt32(pcm.count)); wav.append(pcm)
        if let sound = NSSound(data: wav) {
            activeSound = sound
            sound.volume = Float(volume.clamped(to: 0...100)) / 100
            sound.play()
        }
    }

    @objc private func tick() {
        let now = Date(), dt = min(0.08, now.timeIntervalSince(lastTick)); lastTick = now
        guard mode != .paused else { return }
        animate(now: now)
        updateHome(now: now)
        if now.timeIntervalSince(lastSystemCheck) >= 1 {
            lastSystemCheck = now
            updateOBS(now: now)
            updateBlocked()
            checkClock(now: now)
        }
        guard !obsActive, mode != .obsRest, mode != .angryHome, mode != .blockedHome else { return }
        if now.timeIntervalSince(lastTerrainScan) >= 2 { scanTerrain() }
        updateBubble(dt: dt, now: now)
        if let due = shoppingDue, now >= due { finishShopping() }
        if mode == .alert {
            let hop = CGFloat(abs(sin(ProcessInfo.processInfo.systemUptime * 11)) * 24)
            movePet(y: alertBaseY + hop)
            return
        }
        if mode == .dragged { updateObjects(dt: dt, now: now); return }
        if mode == .shopping { return }
        updatePetPhysics(dt: dt, now: now)
        updateObjects(dt: dt, now: now)
        if Date().timeIntervalSince1970 >= profile.nextCoinUnix, !blocked { spawnCoin() }
        if Date().timeIntervalSince1970 >= profile.nextSpeechUnix, !settings.silentMode, !blocked {
            let maybe = Int.random(in: 0..<100) < settings.maybeFrequency
            let list = maybe ? sprites.character.maybeSpeech : sprites.character.normalSpeech
            if let line = list.randomElement() { showBubble(line); if Int.random(in: 0..<5) == 0 { throwBubble() } }
            scheduleSpeech()
        }
        if profile.coins >= 10, mode == .normal, now >= nextAction, Int.random(in: 0..<3) == 0 { shopping(); return }
        if now >= nextAction, mode == .normal { randomAction() }
        if summonedTarget != nil, mode == .normal, abs(velocity.dx) < 1 { beginChase() }
    }

    private func updatePetPhysics(dt: TimeInterval, now: Date) {
        let delta = CGFloat(dt)
        if mode == .falling {
            let oldBottom = petPanel.frame.minY
            velocity.dy = max(-1300, velocity.dy - 1000 * delta)
            let newX = petPanel.frame.minX + velocity.dx * delta
            var newY = oldBottom + velocity.dy * delta
            var landing: (CGFloat, Int)?
            if velocity.dy <= 0 {
                let centerX = newX + petSize / 2
                for index in surfaces.indices where centerX >= surfaces[index].rect.minX + 7 && centerX <= surfaces[index].rect.maxX - 7 {
                    let top = surfaces[index].rect.maxY
                    if oldBottom >= top - 3, newY <= top + 3, landing == nil || top > landing!.0 { landing = (top, index) }
                }
            }
            if let landing {
                newY = landing.0; velocity = .zero; mode = .normal; setPose(.sit); scheduleAction(3...7)
            }
            movePet(x: newX, y: newY)
            keepRecoverable()
            return
        }
        if mode == .climbing {
            if phantomClimb {
                movePet(y: petPanel.frame.minY + 95 * delta)
                if now >= nextAction { phantomClimb = false; showBubble("壁、なかった。"); beginFall(impulse: -40) }
                return
            }
            guard let index = targetSurface, surfaces.indices.contains(index) else { beginFall(); return }
            let surface = surfaces[index]
            movePet(y: petPanel.frame.minY + 170 * delta)
            if petPanel.frame.minY >= surface.rect.maxY - 2 {
                if climbingWillSucceed {
                    movePet(x: petPanel.frame.minX.clamped(to: surface.rect.minX...max(surface.rect.minX, surface.rect.maxX - petSize)), y: surface.rect.maxY)
                    targetSurface = nil; velocity = .zero; mode = .normal; setPose(.sit); scheduleAction(5...12)
                } else { showBubble("あっ。"); beginFall(impulse: -80) }
            }
            return
        }
        let sourceScreen = screen(containing: petPanel.frame.center)
        var x = petPanel.frame.minX + velocity.dx * delta
        if abs(velocity.dx) > 1 { facesRight = velocity.dx > 0; petView.facesRight = facesRight }
        if let target = targetSurface, surfaces.indices.contains(target), abs(x - targetX) < 8 {
            x = targetX; velocity.dx = 0
            if Int.random(in: 0..<4) < 3 { showBubble("わっ。"); beginFall(impulse: 120) }
            else { mode = .climbing; climbingWillSucceed = Bool.random(); setPose(.climb) }
        } else if supported(x: x + petSize / 2, bottom: petPanel.frame.minY) == nil {
            beginFall()
        }
        movePet(x: x)
        crossMonitorIfNeeded(from: sourceScreen)
    }

    private func crossMonitorIfNeeded(from source: NSScreen?) {
        guard let current = source else { keepRecoverable(); return }
        let movingRight = velocity.dx > 0
        let passed = movingRight ? petPanel.frame.minX > current.frame.maxX - petSize * 0.1 : petPanel.frame.maxX < current.frame.minX + petSize * 0.1
        guard passed else { return }
        let destinations = NSScreen.screens.filter { $0 !== current && (movingRight ? $0.frame.minX >= current.frame.maxX - 4 : $0.frame.maxX <= current.frame.minX + 4) }
        if let destination = destinations.min(by: { abs($0.frame.midY - current.frame.midY) < abs($1.frame.midY - current.frame.midY) }) {
            let x = movingRight ? destination.frame.minX - petSize * 0.35 : destination.frame.maxX - petSize * 0.65
            movePet(x: x, y: destination.frame.maxY + 8)
            velocity.dy = -120
            mode = .falling
            setPose(.fall)
        } else {
            movePet(x: petPanel.frame.minX.clamped(to: current.visibleFrame.minX...max(current.visibleFrame.minX, current.visibleFrame.maxX - petSize)))
            velocity.dx *= -1; facesRight.toggle(); petView.facesRight = facesRight
        }
    }

    private func keepRecoverable() {
        if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -petSize, dy: -petSize).intersects(petPanel.frame) }) { return }
        guard let primary = NSScreen.screens.first else { return }
        movePet(x: primary.visibleFrame.midX - petSize / 2, y: primary.frame.maxY + 8)
        velocity = CGVector(dx: 0, dy: -120)
        mode = .falling
        setPose(.fall)
        petPanel.orderFrontRegardless()
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.screens.min(by: {
            hypot($0.frame.midX - point.x, $0.frame.midY - point.y) < hypot($1.frame.midX - point.x, $1.frame.midY - point.y)
        })
    }

    private func shiftSchedules(by seconds: TimeInterval) {
        guard seconds > 0 else { return }
        nextAction = nextAction.addingTimeInterval(seconds)
        profile.nextCoinUnix += seconds
        profile.nextSpeechUnix += seconds
        if let value = bubbleExpiry { bubbleExpiry = value.addingTimeInterval(seconds) }
        if let value = shoppingDue { shoppingDue = value.addingTimeInterval(seconds) }
        if let value = pomodoroDue { pomodoroDue = value.addingTimeInterval(seconds) }
        if let value = homeUntil { homeUntil = value.addingTimeInterval(seconds) }
        for object in objects where object.expiry != nil {
            object.expiry = object.expiry!.addingTimeInterval(seconds)
        }
        save()
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
