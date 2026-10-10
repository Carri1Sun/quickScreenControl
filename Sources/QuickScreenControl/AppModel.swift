import AppKit
import CoreGraphics
import Carbon.HIToolbox
import Foundation
import ServiceManagement

/// 应用的核心状态：显示器列表、配置、动作执行、定时与插拔规则、快捷键
final class AppModel: ObservableObject {
    let manager = DisplayManager()

    @Published var config: AppConfig
    @Published private(set) var displays: [DisplayInfo] = []
    @Published var brightness: [CGDirectDisplayID: Int] = [:]
    @Published var tint: [CGDirectDisplayID: Int] = [:]
    @Published var message: String?
    @Published var launchAtLogin: Bool = false

    private var knownKeys: Set<String> = []
    private var firedSchedules: Set<String> = []
    private var scheduleTimer: Timer?
    private var reconfigWork: DispatchWorkItem?

    init() {
        config = ConfigStore.load()
        displays = manager.displays
        knownKeys = Set(displays.map(\.key))
        launchAtLogin = SMAppService.mainApp.status == .enabled

        CGDisplayRegisterReconfigurationCallback({ _, flags, userInfo in
            // 只关心屏幕增删或模式变化
            guard let userInfo, !flags.contains(.beginConfigurationFlag) else { return }
            let model = Unmanaged<AppModel>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async { model.scheduleReconfigure() }
        }, Unmanaged.passUnretained(self).toOpaque())

        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.checkSchedules()
        }
        registerHotkeys()
        readAllStates()
    }

    // MARK: - 显示器状态

    /// 重新枚举显示器（菜单打开时调用）
    func refresh() {
        manager.refresh()
        displays = manager.displays
        readAllStates()
    }

    func name(for d: DisplayInfo) -> String {
        config.aliases[d.key] ?? d.name
    }

    func display(key: String) -> DisplayInfo? {
        displays.first { $0.key == key }
    }

    func supportsBrightness(_ d: DisplayInfo) -> Bool {
        manager.brightness[d.id]?.isSupported == true
    }

    /// 后台读取亮度，读完回到主线程更新
    func readAllStates() {
        let snapshot = displays
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var b: [CGDirectDisplayID: Int] = [:]
            for d in snapshot {
                if let v = self.manager.brightness[d.id]?.read() { b[d.id] = v }
            }
            DispatchQueue.main.async {
                self.brightness.merge(b) { _, new in new }
            }
        }
    }

    // MARK: - 单项操作

    func setBrightness(_ id: CGDirectDisplayID, _ value: Int) {
        brightness[id] = value
        manager.brightness[id]?.set(value)
    }

    func setTint(_ id: CGDirectDisplayID, _ kelvin: Int) {
        tint[id] = kelvin
        Tint.apply(display: id, kelvin: kelvin)
    }

    func mirror(source: DisplayInfo, target: DisplayInfo?) {
        manager.setMirror(source: source.id, target: target?.id ?? 0)
        displays = manager.displays
    }

    func restoreAll() {
        manager.stopAllMirrors()
        displays = manager.displays
    }

    // MARK: - 预设

    func apply(_ preset: Preset) {
        for action in preset.actions { run(action) }
        notify("已应用「\(preset.name)」")
        refresh()
    }

    func run(_ action: PresetAction) {
        switch action {
        case .restoreAll:
            manager.stopAllMirrors()
        case .mirror(let s, let t):
            guard let src = display(key: s) else { return }
            let tgt = t.flatMap { display(key: $0) }
            if t != nil && tgt == nil { return }
            manager.setMirror(source: src.id, target: tgt?.id ?? 0)
        case .brightness(let d, let v):
            if let disp = display(key: d) { setBrightness(disp.id, v) }
        case .tint(let d, let k):
            if let disp = display(key: d) { setTint(disp.id, k) }
        }
    }

    func notify(_ text: String) {
        message = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.message == text { self?.message = nil }
        }
    }

    // MARK: - 配置修改

    func update(_ mutate: (inout AppConfig) -> Void) {
        mutate(&config)
        ConfigStore.save(config)
        registerHotkeys()
    }

    // MARK: - 快捷键

    func registerHotkeys() {
        Hotkeys.unregisterAll()

        // ⌃⌥⌘↑ / ↓：所有可控屏幕亮度 ±10
        Hotkeys.register(id: 1, keyCode: kVK_UpArrow) { [weak self] in self?.nudgeBrightness(by: 10) }
        Hotkeys.register(id: 2, keyCode: kVK_DownArrow) { [weak self] in self?.nudgeBrightness(by: -10) }

        // ⌃⌥⌘1-3：按槽位应用预设
        let digitKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3]
        for preset in config.presets {
            guard let slot = preset.hotkeySlot, (1...3).contains(slot) else { continue }
            let p = preset
            Hotkeys.register(id: UInt32(100 + slot), keyCode: digitKeys[slot - 1]) { [weak self] in self?.apply(p) }
        }
    }

    private func nudgeBrightness(by delta: Int) {
        for d in displays where supportsBrightness(d) {
            let current = brightness[d.id] ?? 50
            setBrightness(d.id, max(0, min(100, current + delta)))
        }
        notify("亮度 \(delta > 0 ? "+" : "")\(delta)")
    }

    // MARK: - 插拔规则

    private func scheduleReconfigure() {
        reconfigWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.handleReconfigure() }
        reconfigWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func handleReconfigure() {
        manager.refresh()
        displays = manager.displays
        let current = Set(displays.map(\.key))
        let connected = current.subtracting(knownKeys)
        let disconnected = knownKeys.subtracting(current)
        knownKeys = current

        for rule in config.rules {
            let hit = rule.onConnect ? connected.contains(rule.displayKey) : disconnected.contains(rule.displayKey)
            guard hit, let preset = config.presets.first(where: { $0.id == rule.presetID }) else { continue }
            apply(preset)
        }
        readAllStates()
    }

    // MARK: - 定时亮度

    private func checkSchedules() {
        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let day = "\(comps.year!)-\(comps.month!)-\(comps.day!)"
        let minutesNow = comps.hour! * 60 + comps.minute!

        for entry in config.schedules where entry.enabled {
            let fireKey = "\(entry.id)-\(day)"
            guard !firedSchedules.contains(fireKey), minutesNow >= entry.hour * 60 + entry.minute else { continue }
            firedSchedules.insert(fireKey)
            if let d = display(key: entry.displayKey), supportsBrightness(d) {
                setBrightness(d.id, entry.brightness)
            }
        }
    }

    // MARK: - 开机启动

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("开机启动设置失败: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - URL Scheme：quickscreen://preset/<预设名>

    func handle(url: URL) {
        guard url.scheme == "quickscreen" else { return }
        let name = url.lastPathComponent
        if url.host == "preset", let preset = config.presets.first(where: { $0.name == name }) {
            apply(preset)
        }
    }
}
