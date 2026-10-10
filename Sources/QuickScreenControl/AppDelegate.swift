import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var panelHost: NSHostingController<PanelView>?
    private var settingsWindow: NSWindow?
    private let model = AppModel()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        popover.delegate = self
        panelHost = NSHostingController(rootView: PanelView(model: model, openSettings: { [weak self] in
            self?.openSettings()
        }))
        popover.contentViewController = panelHost

        // 镜像中时图标变化，一眼可见
        model.$displays
            .receive(on: DispatchQueue.main)
            .sink { [weak self] displays in self?.updateIcon(displays) }
            .store(in: &cancellables)
        updateIcon(model.displays)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Tint.restoreAll()
    }

    // 处理 quickscreen://preset/<名称>
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { model.handle(url: $0) }
    }

    private func updateIcon(_ displays: [DisplayInfo]) {
        let mirroring = displays.contains { $0.isMirroring }
        let name = mirroring ? "rectangle.on.rectangle" : "display.2"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "屏幕控制")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let button = statusItem.button, let host = panelHost else { return }
        model.refresh()

        // 先测量 SwiftUI 内容的真实尺寸，再显示，避免弹窗按错误高度定位而越过菜单栏
        let fitted = host.view.fittingSize
        let visible = button.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let maxHeight = max(200, visible.height - 16)
        popover.contentSize = NSSize(width: 340, height: min(fitted.height, maxHeight))

        NSApp.activate(ignoringOtherApps: true)
        // .minY：从状态栏按钮底部向下展开，顶边与菜单栏底边对齐
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "屏幕控制设置"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
