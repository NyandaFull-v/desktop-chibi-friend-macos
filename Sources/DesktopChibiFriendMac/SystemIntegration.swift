import AppKit
import ApplicationServices
import Foundation
import Network
import ServiceManagement

private let globalMouseCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<GlobalMouseMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    monitor.receive(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

final class GlobalMouseMonitor {
    var onBlankRightDoubleClick: ((CGPoint) -> Void)?
    var onBlankLeftTripleClick: ((CGPoint) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var lastBlankRight: (time: TimeInterval, point: CGPoint)?
    private var leftTimes: [TimeInterval] = []

    func start(promptForPermission: Bool = true) {
        if promptForPermission {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        }
        let mask = (CGEventMask(1) << CGEventType.rightMouseDown.rawValue) |
            (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                place: .headInsertEventTap,
                                options: .listenOnly,
                                eventsOfInterest: mask,
                                callback: globalMouseCallback,
                                userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return }
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        tap = nil
    }

    fileprivate func receive(type: CGEventType, event: CGEvent) {
        let point = event.location
        let now = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if type == .rightMouseDown {
                if let previous = self.lastBlankRight,
                   now - previous.time <= 0.48,
                   hypot(point.x - previous.point.x, point.y - previous.point.y) <= 16 {
                    self.lastBlankRight = nil
                    self.onBlankRightDoubleClick?(self.appKitPoint(from: point))
                } else if self.isBlankDesktop(cgPoint: point) {
                    self.lastBlankRight = (now, point)
                } else {
                    self.lastBlankRight = nil
                }
            } else if type == .leftMouseDown {
                guard self.isBlankDesktop(cgPoint: point) else { self.leftTimes.removeAll(); return }
                self.leftTimes = (self.leftTimes + [now]).filter { now - $0 <= 0.62 }
                if self.leftTimes.count >= 3 {
                    self.leftTimes.removeAll()
                    self.onBlankLeftTripleClick?(self.appKitPoint(from: point))
                }
            }
        }
    }

    private func isBlankDesktop(cgPoint: CGPoint) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        if let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
            for entry in list {
                guard let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0,
                      let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                      let x = (bounds["X"] as? NSNumber)?.doubleValue,
                      let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                      let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                      let height = (bounds["Height"] as? NSNumber)?.doubleValue else { continue }
                if CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height)).contains(cgPoint) { return false }
            }
        }
        let system = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(cgPoint.x), Float(cgPoint.y), &hit) == .success,
              let hit else { return true }
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(hit, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String else { return true }
        return role == "AXDesktop" || role == (kAXGroupRole as String) || role == (kAXScrollAreaRole as String)
    }

    private func appKitPoint(from point: CGPoint) -> CGPoint {
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: point.x, y: mainTop - point.y)
    }
}

enum MacSystem {
    static func appKitRect(fromCG dictionary: [String: Any]) -> CGRect? {
        guard let x = (dictionary["X"] as? NSNumber)?.doubleValue,
              let y = (dictionary["Y"] as? NSNumber)?.doubleValue,
              let width = (dictionary["Width"] as? NSNumber)?.doubleValue,
              let height = (dictionary["Height"] as? NSNumber)?.doubleValue else { return nil }
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: CGFloat(x), y: mainTop - CGFloat(y) - CGFloat(height), width: CGFloat(width), height: CGFloat(height))
    }

    static func surfaces(ownPID: pid_t) -> [Surface] {
        var result: [Surface] = []
        var blockers: [CGRect] = []
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        for entry in list {
            guard let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0,
                  let pidNumber = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha > 0.05,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let rect = appKitRect(fromCG: bounds), rect.width >= 140, rect.height >= 80 else { continue }
            let pid = pid_t(pidNumber.int32Value)
            let maximized = NSScreen.screens.contains { screen in
                abs(rect.minX - screen.frame.minX) < 3 && abs(rect.maxX - screen.frame.maxX) < 3 &&
                abs(rect.minY - screen.frame.minY) < 3 && abs(rect.maxY - screen.frame.maxY) < 3
            }
            if maximized { blockers.append(rect); continue }
            let exposed = stride(from: CGFloat(0.1), through: CGFloat(0.9), by: CGFloat(0.1)).contains { fraction in
                let sample = CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY - 3)
                return !blockers.contains(where: { $0.contains(sample) })
            }
            blockers.append(rect)
            if exposed { result.append(.init(ownerPID: pid, rect: rect, floor: false)) }
        }
        for screen in NSScreen.screens {
            let floor = CGRect(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY - 3, width: screen.visibleFrame.width, height: 4)
            result.append(.init(ownerPID: 0, rect: floor, floor: true))
        }
        return result
    }

    static func isOBSRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.obsproject.obs-studio" || $0.localizedName?.localizedCaseInsensitiveContains("OBS") == true
        }
    }

    static func blockedScreen() -> (screen: NSScreen, game: Bool, fullscreen: Bool)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let appWindows = windows.filter {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier &&
            ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
        }
        guard let entry = appWindows.max(by: { lhs, rhs in
            let left = (lhs[kCGWindowBounds as String] as? [String: Any]).flatMap { appKitRect(fromCG: $0) } ?? .zero
            let right = (rhs[kCGWindowBounds as String] as? [String: Any]).flatMap { appKitRect(fromCG: $0) } ?? .zero
            return left.width * left.height < right.width * right.height
        }),
              let bounds = entry[kCGWindowBounds as String] as? [String: Any], let rect = appKitRect(fromCG: bounds),
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) else { return nil }
        let fullscreen = abs(rect.minX - screen.frame.minX) < 3 && abs(rect.maxX - screen.frame.maxX) < 3 &&
            abs(rect.minY - screen.frame.minY) < 3 && abs(rect.maxY - screen.frame.maxY) < 3
        let path = app.bundleURL?.path.lowercased() ?? ""
        let knownNonGames = ["wallpaper engine", "lossless scaling", "steamvr"]
        let storeGame = path.contains("/steamapps/common/") && !knownNonGames.contains(where: { path.contains($0) })
        let game = storeGame || path.contains("/epic games/") || path.contains("/gog games/")
        return fullscreen || game ? (screen, game, fullscreen) : nil
    }

    static func setLoginItem(enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}

final class OBSHTTPServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "DesktopChibiFriend.obs", qos: .utility)
    private var root: URL?
    private var petSize = 180
    private var coinMin = 15
    private var coinMax = 30
    private(set) var port: UInt16 = 47831

    func start(port: Int, root: URL, petSize: Int, coinMin: Int, coinMax: Int) -> Bool {
        stop()
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port.clamped(to: 1024...65535))) else { return false }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
        do {
            let value = try NWListener(using: parameters)
            self.root = root
            self.petSize = petSize
            self.coinMin = coinMin
            self.coinMax = coinMax
            self.port = endpointPort.rawValue
            value.newConnectionHandler = { [weak self] in self?.handle($0) }
            value.start(queue: queue)
            listener = value
            return true
        } catch { return false }
    }

    func stop() { listener?.cancel(); listener = nil }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            let first = request.components(separatedBy: "\r\n").first ?? ""
            let path = first.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let body: Data
            let type: String
            if path == "/" {
                body = Data(self.page().utf8); type = "text/html; charset=utf-8"
            } else if path.hasPrefix("/characters/"), let root = self.root {
                let safe = path.replacingOccurrences(of: "..", with: "").dropFirst()
                let url = root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(String(safe))
                body = (try? Data(contentsOf: url)) ?? Data(); type = "image/png"
            } else { body = Data("not found".utf8); type = "text/plain" }
            let status = body.isEmpty ? "404 Not Found" : "200 OK"
            let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            var response = Data(header.utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func page() -> String {
        let low = coinMin * 60_000, high = max(coinMin, coinMax) * 60_000
        return """
        <!doctype html><meta charset="utf-8"><style>
        html,body{margin:0;overflow:hidden;background:transparent}.pet{position:fixed;width:\(petSize)px;height:\(petSize)px;background:url('/characters/chibidaful/animations-sit-walk-v7.png') 0 100%/400% 200% no-repeat;left:2%;bottom:0;animation:walk 18s linear infinite,frames .72s steps(4) infinite}@keyframes frames{to{background-position-x:133.333%}}@keyframes walk{0%{left:2%;transform:scaleX(1)}48%{left:calc(98% - \(petSize)px);transform:scaleX(1)}52%{left:calc(98% - \(petSize)px);transform:scaleX(-1)}98%{left:2%;transform:scaleX(-1)}100%{left:2%;transform:scaleX(1)}}.coin{position:fixed;width:48px;height:48px;object-fit:contain;animation:fall 7s linear forwards}@keyframes fall{from{top:-55px}to{top:calc(100vh - 48px)}}
        </style><div class="pet"></div><script>const lo=\(low),hi=\(high);function coin(){let c=document.createElement('img');c.className='coin';c.src='/characters/chibidaful/coin-v2.png';c.style.left=Math.random()*90+'%';document.body.append(c);setTimeout(()=>c.remove(),8000);setTimeout(coin,lo+Math.random()*(hi-lo))}setTimeout(coin,lo+Math.random()*(hi-lo))</script>
        """
    }
}
