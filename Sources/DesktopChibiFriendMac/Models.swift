import AppKit
import Foundation

let appDisplayVersion = "0.4.1-mac"

enum Pose: String, CaseIterable {
    case stand, walk, dash, sit, sleep, fall, climb, joy, dice, dig, petting, look, trip
}

enum PetMode {
    case normal, dragged, falling, climbing, alert, shopping, angryHome, blockedHome, obsRest, paused
}

enum ObjectKind {
    case coin, item, showcase, cave
}

enum ItemCategory: Int, Codable {
    case accessory = 0, sweet = 1, toy = 2
}

struct ItemDefinition: Codable, Hashable {
    let id: String
    let name: String
    let reaction: String
    let category: ItemCategory
    let atlasIndex: Int
}

let itemDefinitions: [ItemDefinition] = [
    .init(id: "aqua_ribbon", name: "水色のリボン", reaction: "我のリボン、似合う？", category: .accessory, atlasIndex: 0),
    .init(id: "salt_crystal", name: "岩塩結晶の飾り", reaction: "きらきら。洞窟の色だぞ、ますた。", category: .accessory, atlasIndex: 1),
    .init(id: "star_brooch", name: "星のブローチ", reaction: "我、ちょっとえらそう。", category: .accessory, atlasIndex: 2),
    .init(id: "tiny_bell", name: "小さな鈴", reaction: "鳴らさず見せるだけ。えらい。", category: .accessory, atlasIndex: 3),
    .init(id: "flower", name: "花飾り", reaction: "我、花まで似合ってしまう。", category: .accessory, atlasIndex: 4),
    .init(id: "cookie", name: "クッキー", reaction: "さくさく。ますたにも一口……ない。", category: .sweet, atlasIndex: 0),
    .init(id: "pudding", name: "プリン", reaction: "ぷるぷるは正義。", category: .sweet, atlasIndex: 1),
    .init(id: "donut", name: "ドーナツ", reaction: "穴のぶんだけカロリーが少ない……たぶん", category: .sweet, atlasIndex: 2),
    .init(id: "cupcake", name: "カップケーキ", reaction: "上から食べるか、下から食べるか。", category: .sweet, atlasIndex: 3),
    .init(id: "candy", name: "キャンディ", reaction: "あまい。もう一個ほしい。", category: .sweet, atlasIndex: 4),
    .init(id: "cat_teaser", name: "猫じゃらし", reaction: "我は猫では……ちょ、もう一回。", category: .toy, atlasIndex: 0),
    .init(id: "yarn", name: "毛糸玉", reaction: "ほどくのは得意。戻すのは知らない。", category: .toy, atlasIndex: 1),
    .init(id: "bell_ball", name: "鈴ボール", reaction: "ころころ……待てー！", category: .toy, atlasIndex: 2),
    .init(id: "feather", name: "羽根のおもちゃ", reaction: "ふわふわが逃げる。", category: .toy, atlasIndex: 3),
    .init(id: "plush", name: "小さなぬいぐるみ", reaction: "我がぬいを抱く。入れ子だな。", category: .toy, atlasIndex: 4)
]

struct AppSettings: Codable {
    var desktopPetSize = 180
    var obsPetSize = 180
    var activity = "ふつう"
    var coinMinMinutes = 15
    var coinMaxMinutes = 30
    var speechMinMinutes = 8
    var speechMaxMinutes = 15
    var maybeFrequency = 30
    var silentMode = false
    var focusMinutes = 25
    var breakMinutes = 5
    var pomodoroLoops = 4
    var effectsEnabled = true
    var effectsVolume = 65
    var alarmTime = ""
    var alarmEnabled = false
    var autoStart = true
    var obsPort = 47831
}

struct UserProfile: Codable {
    var coins = 0
    var unlocked = ["aqua_ribbon", "cookie", "cat_teaser"]
    var counts = ["aqua_ribbon": 1, "cookie": 1, "cat_teaser": 1]
    var nextCoinUnix: TimeInterval = Date().timeIntervalSince1970 + 15 * 60
    var nextSpeechUnix: TimeInterval = Date().timeIntervalSince1970 + 8 * 60
    var lastX: Double = -1
    var lastY: Double = -1
}

struct CharacterDefinition: Codable {
    struct AnimationSheet: Codable { let file: String; let columns: Int; let rows: Int }
    struct AnimationSheets: Codable {
        let sitWalk: AnimationSheet
        let petClimb: AnimationSheet
        let sleepLookTrip: AnimationSheet
        let dig: AnimationSheet
    }
    struct ItemAtlases: Codable { let accessory: String; let sweet: String; let toy: String }
    let schemaVersion: Int
    let id: String
    let displayName: String
    let spriteSheet: String
    let coinFile: String
    let animationSheets: AnimationSheets
    let itemAtlases: ItemAtlases
    let columns: Int
    let rows: Int
    let poses: [String]
    let firstPerson: String
    let userName: String
    let style: String
    let normalSpeech: [String]
    let maybeSpeech: [String]
}

struct Surface {
    let ownerPID: pid_t
    let rect: CGRect
    let floor: Bool
}

final class Storage {
    let root: URL
    private let settingsURL: URL
    private let profileURL: URL
    private let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.outputFormatting = [.prettyPrinted, .sortedKeys]
        return value
    }()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        root = support.appendingPathComponent("DesktopChibiFriend", isDirectory: true)
        settingsURL = root.appendingPathComponent("settings.json")
        profileURL = root.appendingPathComponent("profile.json")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        importWindowsDataIfPresent()
    }

    func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL), let value = try? JSONDecoder().decode(AppSettings.self, from: data) else { return .init() }
        return value
    }

    func loadProfile() -> UserProfile {
        guard let data = try? Data(contentsOf: profileURL), var value = try? JSONDecoder().decode(UserProfile.self, from: data) else { return .init() }
        for id in ["aqua_ribbon", "cookie", "cat_teaser"] {
            if !value.unlocked.contains(id) { value.unlocked.append(id) }
            value.counts[id] = max(1, value.counts[id] ?? 0)
        }
        return value
    }

    func save(settings: AppSettings, profile: UserProfile) {
        if let data = try? encoder.encode(settings) { try? data.write(to: settingsURL, options: .atomic) }
        if let data = try? encoder.encode(profile) { try? data.write(to: profileURL, options: .atomic) }
    }

    private func importWindowsDataIfPresent() {
        guard !FileManager.default.fileExists(atPath: settingsURL.path),
              !FileManager.default.fileExists(atPath: profileURL.path) else { return }
        let candidates = [
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("data", isDirectory: true),
            Bundle.main.resourceURL?.appendingPathComponent("data", isDirectory: true)
        ].compactMap { $0 }
        guard let legacy = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("profile.json").path) }) else { return }
        var importedSettings = AppSettings()
        if let object = jsonObject(legacy.appendingPathComponent("settings.json")) {
            importedSettings.desktopPetSize = integer(object, "DesktopPetSize", importedSettings.desktopPetSize)
            importedSettings.obsPetSize = integer(object, "ObsPetSize", importedSettings.obsPetSize)
            importedSettings.activity = object["Activity"] as? String ?? importedSettings.activity
            importedSettings.coinMinMinutes = integer(object, "CoinMinMinutes", importedSettings.coinMinMinutes)
            importedSettings.coinMaxMinutes = integer(object, "CoinMaxMinutes", importedSettings.coinMaxMinutes)
            importedSettings.speechMinMinutes = integer(object, "SpeechMinMinutes", importedSettings.speechMinMinutes)
            importedSettings.speechMaxMinutes = integer(object, "SpeechMaxMinutes", importedSettings.speechMaxMinutes)
            importedSettings.maybeFrequency = integer(object, "MaybeFrequency", importedSettings.maybeFrequency)
            importedSettings.silentMode = boolean(object, "SilentMode", importedSettings.silentMode)
            importedSettings.focusMinutes = integer(object, "FocusMinutes", importedSettings.focusMinutes)
            importedSettings.breakMinutes = integer(object, "BreakMinutes", importedSettings.breakMinutes)
            importedSettings.pomodoroLoops = integer(object, "PomodoroLoops", importedSettings.pomodoroLoops)
            importedSettings.effectsEnabled = boolean(object, "EffectsEnabled", importedSettings.effectsEnabled)
            importedSettings.effectsVolume = integer(object, "EffectsVolume", importedSettings.effectsVolume)
            importedSettings.alarmTime = object["AlarmTime"] as? String ?? ""
            importedSettings.alarmEnabled = boolean(object, "AlarmEnabled", false)
            importedSettings.autoStart = boolean(object, "AutoStart", true)
            importedSettings.obsPort = integer(object, "ObsPort", importedSettings.obsPort)
        }
        var importedProfile = UserProfile()
        if let object = jsonObject(legacy.appendingPathComponent("profile.json")) {
            importedProfile.coins = integer(object, "Coins", 0)
            importedProfile.unlocked = object["UnlockedItems"] as? [String] ?? importedProfile.unlocked
            if let entries = object["ItemCounts"] as? [[String: Any]] {
                var counts: [String: Int] = [:]
                for entry in entries {
                    if let key = entry["Key"] as? String, let value = (entry["Value"] as? NSNumber)?.intValue { counts[key] = value }
                }
                importedProfile.counts = counts
            }
            importedProfile.nextCoinUnix = legacyDate(object["NextCoinAtUtc"]) ?? importedProfile.nextCoinUnix
            importedProfile.nextSpeechUnix = legacyDate(object["NextSpeechAtUtc"]) ?? importedProfile.nextSpeechUnix
            importedProfile.lastX = -1
            importedProfile.lastY = -1
        }
        save(settings: importedSettings, profile: importedProfile)
    }

    private func jsonObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    private func integer(_ object: [String: Any], _ key: String, _ fallback: Int) -> Int { (object[key] as? NSNumber)?.intValue ?? fallback }
    private func boolean(_ object: [String: Any], _ key: String, _ fallback: Bool) -> Bool { (object[key] as? NSNumber)?.boolValue ?? fallback }
    private func legacyDate(_ value: Any?) -> TimeInterval? {
        guard let text = value as? String,
              let range = text.range(of: #"[0-9]{10,13}"#, options: .regularExpression),
              let raw = Double(text[range]) else { return nil }
        return raw > 10_000_000_000 ? raw / 1000 : raw
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
