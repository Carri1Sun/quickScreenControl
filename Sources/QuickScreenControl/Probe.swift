import Foundation
import CoreGraphics

/// 命令行诊断：`QuickScreenControl --probe`
enum Probe {
    static func run() {
        let manager = DisplayManager()
        print("在线显示器：\(manager.displays.count)")
        for d in manager.displays {
            let kind = d.isBuiltin ? "内置" : "外接"
            print("- id=\(d.id) \(d.name) \(d.width)x\(d.height) [\(kind)] vendor=\(d.identity.vendor) model=\(d.identity.model) serial=\(d.identity.serial) mirrorsOf=\(d.mirrorsOf)")
            if let c = manager.brightness[d.id] {
                let v = c.read().map { "\($0)%" } ?? "读取失败"
                print("    亮度：\(v)")
            } else {
                print("    亮度：无可用通道")
            }
        }
        let services = DDCDiscovery.discover()
        print("DDC 服务数：\(services.count)")
        for (i, s) in services.enumerated() {
            let idText = s.identity.map { "vendor=\($0.vendor) model=\($0.model) serial=\($0.serial)" } ?? "无 EDID"
            print("  svc[\(i)] \(idText) read98?=\(s.device.read(vcp: 0x10).map { "\($0.current)/\($0.max)" } ?? "失败")")
        }

        if CommandLine.arguments.contains("--mirror-test") {
            let all = manager.displays
            guard all.count >= 2 else { print("需要两块屏幕"); return }
            let src = all[0], dst = all[1]
            print("镜像测试：\(src.name)(\(src.id)) -> \(dst.name)(\(dst.id))")
            print("setMirror 返回：\(manager.setMirror(source: src.id, target: dst.id))")
            Thread.sleep(forTimeInterval: 2)
            for d in manager.displays {
                print("  \(d.name) mirrorsOf=\(d.mirrorsOf) isMirroring=\(d.isMirroring) bounds=\(CGDisplayBounds(d.id))")
            }
            print("恢复扩展：\(manager.setMirror(source: src.id, target: 0))")
            Thread.sleep(forTimeInterval: 2)
            for d in manager.displays {
                print("  \(d.name) mirrorsOf=\(d.mirrorsOf) bounds=\(CGDisplayBounds(d.id))")
            }
        }

        if let idx = CommandLine.arguments.firstIndex(of: "--set"), idx + 1 < CommandLine.arguments.count,
           let target = Int(CommandLine.arguments[idx + 1]) {
            for d in manager.displays {
                manager.brightness[d.id]?.set(target)
            }
            Thread.sleep(forTimeInterval: 1.5)
            for d in manager.displays {
                print("写入 \(target) 后读取：\(manager.brightness[d.id]?.read() ?? -1)%")
            }
        }
    }
}
