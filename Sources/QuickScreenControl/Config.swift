import Foundation

/// 预设中的一个动作。显示器用稳定 key（厂商-型号-序列号）引用，不依赖插口或临时 ID。
enum PresetAction: Codable, Hashable {
    /// 把 source 镜像到 target；target 为 nil 时停止 source 的镜像
    case mirror(source: String, target: String?)
    /// 设置亮度（0-100）
    case brightness(display: String, value: Int)
    /// 设置输入源（VCP 0x60 的值，如 HDMI1=17、HDMI2=18）
    case input(display: String, code: Int)
    /// 设置色温（K）
    case tint(display: String, kelvin: Int)
    /// 停止所有镜像
    case restoreAll

    var summary: String {
        switch self {
        case .mirror(let s, let t): return t == nil ? "停止镜像 \(s)" : "镜像 \(s) → \(t!)"
        case .brightness(let d, let v): return "亮度 \(d) = \(v)%"
        case .input(let d, let c): return "输入 \(d) = \(InputSource.name(for: c))"
        case .tint(let d, let k): return "色温 \(d) = \(k)K"
        case .restoreAll: return "恢复所有屏幕为扩展"
        }
    }
}

struct Preset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var actions: [PresetAction]
    /// 快捷键槽位（1-3），nil 表示不绑定
    var hotkeySlot: Int?
}

/// 插拔某块屏幕时执行的预设
struct AutoRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var displayKey: String
    var onConnect: Bool
    var presetID: UUID
}

/// 每天定时的亮度
struct ScheduleEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var displayKey: String
    var hour: Int
    var minute: Int
    var brightness: Int
    var enabled = true
}

struct AppConfig: Codable {
    var presets: [Preset]
    var rules: [AutoRule]
    var schedules: [ScheduleEntry]
    /// 每块屏幕的别名：key -> 名称
    var aliases: [String: String]

    static let `default` = AppConfig(
        presets: [
            Preset(name: "恢复扩展", actions: [.restoreAll], hotkeySlot: 1),
        ],
        rules: [],
        schedules: [],
        aliases: [:]
    )
}

enum InputSource {
    static let options: [(name: String, code: Int)] = [
        ("DP 1", 15), ("DP 2", 16), ("HDMI 1", 17), ("HDMI 2", 18), ("USB-C", 27),
    ]

    static func name(for code: Int) -> String {
        options.first { $0.code == code }?.name ?? "输入 \(code)"
    }
}

/// 配置文件：~/Library/Application Support/QuickScreenControl/config.json
enum ConfigStore {
    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuickScreenControl", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("config.json")
    }

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return .default
        }
        return cfg
    }

    static func save(_ cfg: AppConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(cfg) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
