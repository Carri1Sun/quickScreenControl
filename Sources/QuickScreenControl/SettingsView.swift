import SwiftUI

/// 设置窗口（低频使用）：预设、自动规则、定时亮度、屏幕别名
struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            PresetsTab(model: model)
                .tabItem { Label("预设", systemImage: "square.stack") }
            RulesTab(model: model)
                .tabItem { Label("自动规则", systemImage: "bolt") }
            ScheduleTab(model: model)
                .tabItem { Label("定时亮度", systemImage: "clock") }
            AliasTab(model: model)
                .tabItem { Label("屏幕名称", systemImage: "character.cursor.ibeam") }
        }
        .padding(12)
        .frame(width: 560, height: 420)
    }
}

// MARK: - 预设

private struct PresetsTab: View {
    @ObservedObject var model: AppModel
    @State private var selected: UUID?

    var body: some View {
        HSplitView {
            List(selection: $selected) {
                ForEach(model.config.presets) { preset in
                    Text(preset.name).tag(preset.id)
                }
            }
            .frame(minWidth: 160)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button { addPreset() } label: { Image(systemName: "plus") }
                    Button { removeSelected() } label: { Image(systemName: "minus") }
                        .disabled(selected == nil)
                }
                .padding(6)
            }

            if let idx = model.config.presets.firstIndex(where: { $0.id == selected }) {
                PresetEditor(model: model, index: idx)
            } else {
                Text("选择或新建一个预设").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func addPreset() {
        let preset = Preset(name: "新预设", actions: [], hotkeySlot: nil)
        model.update { $0.presets.append(preset) }
        selected = preset.id
    }

    private func removeSelected() {
        guard let id = selected else { return }
        model.update { cfg in
            cfg.presets.removeAll { $0.id == id }
            cfg.rules.removeAll { $0.presetID == id }
        }
        selected = nil
    }
}

private struct PresetEditor: View {
    @ObservedObject var model: AppModel
    let index: Int
    @State private var draft = ActionDraft()

    private var preset: Preset { model.config.presets[index] }

    var body: some View {
        Form {
            TextField("名称", text: Binding(
                get: { model.config.presets[index].name },
                set: { v in model.update { $0.presets[index].name = v } }
            ))
            Picker("快捷键", selection: Binding(
                get: { preset.hotkeySlot ?? 0 },
                set: { v in model.update { $0.presets[index].hotkeySlot = v == 0 ? nil : v } }
            )) {
                Text("无").tag(0)
                Text("⌃⌥⌘1").tag(1)
                Text("⌃⌥⌘2").tag(2)
                Text("⌃⌥⌘3").tag(3)
            }

            Section("动作（按顺序执行）") {
                ForEach(Array(preset.actions.enumerated()), id: \.offset) { i, action in
                    HStack {
                        Text(action.summary).font(.caption)
                        Spacer()
                        Button { model.update { $0.presets[index].actions.remove(at: i) } } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Section("添加动作") {
                ActionDraftView(model: model, draft: $draft)
                Button("添加") {
                    if let action = draft.build() {
                        model.update { $0.presets[index].actions.append(action) }
                    }
                }
                .disabled(draft.build() == nil)
            }
        }
        .padding(.leading, 8)
    }
}

/// 动作编辑草稿
struct ActionDraft {
    enum Kind: String, CaseIterable, Identifiable {
        case mirror = "镜像", brightness = "亮度", tint = "色温", restoreAll = "恢复扩展"
        var id: String { rawValue }
    }
    var kind: Kind = .restoreAll
    var source: String = ""
    var target: String = ""   // 空字符串表示停止镜像
    var value: Int = 50

    func build() -> PresetAction? {
        switch kind {
        case .restoreAll: return .restoreAll
        case .mirror:
            guard !source.isEmpty else { return nil }
            return .mirror(source: source, target: target.isEmpty ? nil : target)
        case .brightness:
            return source.isEmpty ? nil : .brightness(display: source, value: value)
        case .tint:
            return source.isEmpty ? nil : .tint(display: source, kelvin: value)
        }
    }
}

private struct ActionDraftView: View {
    @ObservedObject var model: AppModel
    @Binding var draft: ActionDraft

    var body: some View {
        Picker("类型", selection: $draft.kind) {
            ForEach(ActionDraft.Kind.allCases) { Text($0.rawValue).tag($0) }
        }
        if draft.kind != .restoreAll {
            Picker("屏幕", selection: $draft.source) {
                Text("选择").tag("")
                ForEach(model.displays, id: \.key) { Text(model.name(for: $0)).tag($0.key) }
            }
        }
        if draft.kind == .mirror {
            Picker("镜像到", selection: $draft.target) {
                Text("停止镜像").tag("")
                ForEach(model.displays, id: \.key) { Text(model.name(for: $0)).tag($0.key) }
            }
        }
        if draft.kind == .brightness {
            Stepper("亮度 \(draft.value)%", value: $draft.value, in: 0...100, step: 5)
        }
        if draft.kind == .tint {
            Stepper("色温 \(draft.value)K", value: $draft.value, in: 3000...6500, step: 100)
        }
    }
}

// MARK: - 自动规则

private struct RulesTab: View {
    @ObservedObject var model: AppModel
    @State private var displayKey = ""
    @State private var onConnect = true
    @State private var presetID: UUID?

    var body: some View {
        Form {
            Section("新规则") {
                Picker("屏幕", selection: $displayKey) {
                    Text("选择").tag("")
                    ForEach(model.displays, id: \.key) { Text(model.name(for: $0)).tag($0.key) }
                }
                Picker("触发", selection: $onConnect) {
                    Text("接入时").tag(true)
                    Text("断开时").tag(false)
                }
                Picker("执行预设", selection: $presetID) {
                    Text("选择").tag(UUID?.none)
                    ForEach(model.config.presets) { Text($0.name).tag(Optional($0.id)) }
                }
                Button("添加规则") {
                    guard let presetID, !displayKey.isEmpty else { return }
                    model.update { $0.rules.append(AutoRule(displayKey: displayKey, onConnect: onConnect, presetID: presetID)) }
                }
                .disabled(presetID == nil || displayKey.isEmpty)
            }
            Section("已有规则") {
                ForEach(model.config.rules) { rule in
                    HStack {
                        Text("\(rule.onConnect ? "接入" : "断开") \(label(rule.displayKey)) → \(presetName(rule.presetID))")
                            .font(.caption)
                        Spacer()
                        Button { model.update { $0.rules.removeAll { $0.id == rule.id } } } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private func label(_ key: String) -> String { model.config.aliases[key] ?? key }
    private func presetName(_ id: UUID) -> String { model.config.presets.first { $0.id == id }?.name ?? "已删除" }
}

// MARK: - 定时亮度

private struct ScheduleTab: View {
    @ObservedObject var model: AppModel
    @State private var displayKey = ""
    @State private var time = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var brightness = 40

    var body: some View {
        Form {
            Section("新定时") {
                Picker("屏幕", selection: $displayKey) {
                    Text("选择").tag("")
                    ForEach(model.displays.filter { model.supportsBrightness($0) }, id: \.key) {
                        Text(model.name(for: $0)).tag($0.key)
                    }
                }
                DatePicker("时间", selection: $time, displayedComponents: .hourAndMinute)
                Stepper("亮度 \(brightness)%", value: $brightness, in: 0...100, step: 5)
                Button("添加") {
                    let c = Calendar.current.dateComponents([.hour, .minute], from: time)
                    model.update {
                        $0.schedules.append(ScheduleEntry(displayKey: displayKey, hour: c.hour ?? 0, minute: c.minute ?? 0, brightness: brightness))
                    }
                }
                .disabled(displayKey.isEmpty)
            }
            Section("已有定时（每天）") {
                ForEach(model.config.schedules) { entry in
                    HStack {
                        Text(String(format: "%02d:%02d  %@  → %d%%", entry.hour, entry.minute,
                                    model.config.aliases[entry.displayKey] ?? entry.displayKey, entry.brightness))
                            .font(.caption)
                        Spacer()
                        Button { model.update { $0.schedules.removeAll { $0.id == entry.id } } } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}

// MARK: - 屏幕名称

private struct AliasTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("为屏幕起一个容易识别的名字") {
                ForEach(model.displays, id: \.key) { d in
                    TextField(d.name, text: Binding(
                        get: { model.config.aliases[d.key] ?? "" },
                        set: { v in model.update { $0.aliases[d.key] = v.isEmpty ? nil : v } }
                    ))
                }
            }
        }
    }
}
