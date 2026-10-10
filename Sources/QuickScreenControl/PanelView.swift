import AppKit
import CoreGraphics
import SwiftUI

/// 状态栏下拉面板（NSPopover 承载，不是独立窗口）
struct PanelView: View {
    @ObservedObject var model: AppModel
    var openSettings: () -> Void

    var body: some View {
        // 内容超过屏幕高度时整体可滚动，保证顶边始终贴着菜单栏
        ScrollView(.vertical, showsIndicators: true) {
            content
        }
        .frame(width: 340)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("屏幕控制").font(.headline)
                Spacer()
                if let message = model.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }

            if !model.config.presets.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.config.presets) { preset in
                            Button(preset.name) { model.apply(preset) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
            }

            if model.displays.isEmpty {
                Text("未检测到显示器").foregroundStyle(.secondary)
            }

            ForEach(model.displays, id: \.id) { display in
                DisplayCard(model: model, display: display)
            }

            Divider()

            HStack {
                Button("设置…", action: openSettings)
                Toggle("开机启动", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }
}

/// 每块屏幕一张卡片：亮度、对比度、色温、镜像
struct DisplayCard: View {
    @ObservedObject var model: AppModel
    let display: DisplayInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
                Text(model.name(for: display)).font(.subheadline.bold()).lineLimit(1)
                if display.isMain { badge("主屏") }
                if display.isMirroring { badge("镜像中", tint: .orange) }
                Spacer()
            }

            if model.supportsBrightness(display) {
                slider("亮度", value: Binding(
                    get: { model.brightness[display.id] ?? 50 },
                    set: { model.setBrightness(display.id, $0) }
                ), range: 0...100, suffix: "%")
            } else {
                Text("亮度：此屏幕无可用控制通道").font(.caption).foregroundStyle(.secondary)
            }

            if model.isDDC(display) {
                slider("对比度", value: Binding(
                    get: { model.contrast[display.id] ?? 50 },
                    set: { model.setContrast(display.id, $0) }
                ), range: 0...100, suffix: "%")
            }

            slider("色温", value: Binding(
                get: { model.tint[display.id] ?? 6500 },
                set: { model.setTint(display.id, $0) }
            ), range: 3000...6500, suffix: "K", step: 100)

            HStack(spacing: 6) {
                mirrorMenu
                Spacer()
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.12)))
    }

    private func slider(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, suffix: String, step: Int = 1) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).frame(width: 40, alignment: .leading)
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0) }),
                   in: Double(range.lowerBound)...Double(range.upperBound),
                   step: Double(step))
            Text("\(value.wrappedValue)\(suffix)")
                .font(.caption.monospacedDigit())
                .frame(width: 52, alignment: .trailing)
        }
    }

    private var mirrorMenu: some View {
        Menu {
            if display.isMirroring {
                Button("恢复扩展（停止镜像）") { model.mirror(source: display, target: nil) }
            } else {
                let others = model.displays.filter { $0.id != display.id && !$0.isMirroring }
                ForEach(others, id: \.id) { target in
                    Button("镜像到「\(model.name(for: target))」") { model.mirror(source: display, target: target) }
                }
                if model.displays.contains(where: { $0.mirrorsOf == display.id }) {
                    Button("停止让其他屏幕镜像此屏") {
                        for other in model.displays where other.mirrorsOf == display.id {
                            model.mirror(source: other, target: nil)
                        }
                    }
                }
            }
            if model.displays.contains(where: { $0.isMirroring }) {
                Divider()
                Button("恢复所有屏幕为扩展") { model.restoreAll() }
            }
        } label: {
            Label(display.isMirroring ? "已镜像" : "镜像", systemImage: "rectangle.on.rectangle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func badge(_ text: String, tint: Color = .accentColor) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.2)))
            .foregroundStyle(tint)
    }
}
