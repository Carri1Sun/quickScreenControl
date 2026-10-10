import AppKit
import CoreGraphics

struct DisplayInfo {
    let id: CGDirectDisplayID
    let identity: DisplayIdentity
    let name: String
    let width: Int
    let height: Int
    let isBuiltin: Bool
    let isMain: Bool
    /// 若本屏幕正在镜像另一块屏，这里是源屏 ID；否则为 0
    let mirrorsOf: CGDirectDisplayID

    var isMirroring: Bool { mirrorsOf != 0 }

    /// 稳定标识，用于配置与规则引用
    var key: String { identity.key }
}

/// 管理所有在线显示器：枚举、身份匹配、亮度控制器、镜像切换
final class DisplayManager {
    private(set) var displays: [DisplayInfo] = []
    private(set) var brightness: [CGDirectDisplayID: BrightnessController] = [:]
    /// 外接屏的 DDC 通道（亮度等 VCP 控制）
    private(set) var ddcDevices: [CGDirectDisplayID: DDCDevice] = [:]

    init() {
        refresh()
    }

    func refresh() {
        let ids = onlineDisplayIDs()
        let services = DDCDiscovery.discover()

        // 1) 身份匹配：外接屏与 DDC 通道通过 EDID 对应
        var assigned: [CGDirectDisplayID: DDCDevice] = [:]
        var usedServices = Set<Int>()
        var unmatchedExternal: [CGDirectDisplayID] = []

        for id in ids where CGDisplayIsBuiltin(id) == 0 {
            let identity = Self.identity(of: id)
            if let idx = services.indices.first(where: { !usedServices.contains($0) && services[$0].identity?.matches(identity) == true }) {
                assigned[id] = services[idx].device
                usedServices.insert(idx)
            } else {
                unmatchedExternal.append(id)
            }
        }

        // 2) 兜底：未匹配的外接屏与未用的 DDC 通道数量一致时按顺序配对
        let freeServices = services.indices.filter { !usedServices.contains($0) }
        if !unmatchedExternal.isEmpty, unmatchedExternal.count == freeServices.count {
            for (id, idx) in zip(unmatchedExternal, freeServices) {
                assigned[id] = services[idx].device
            }
        }

        // 3) 生成显示器信息与亮度控制器
        displays = ids.map { id in
            let identity = Self.identity(of: id)
            return DisplayInfo(
                id: id,
                identity: identity,
                name: Self.name(of: id, identity: identity),
                width: Int(CGDisplayPixelsWide(id)),
                height: Int(CGDisplayPixelsHigh(id)),
                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                isMain: CGDisplayIsMain(id) != 0,
                mirrorsOf: CGDisplayMirrorsDisplay(id)
            )
        }

        ddcDevices = assigned

        var newBrightness: [CGDirectDisplayID: BrightnessController] = [:]
        for d in displays {
            if d.isBuiltin {
                newBrightness[d.id] = BrightnessController(backend: .builtin(d.id))
            } else if let dev = assigned[d.id] {
                newBrightness[d.id] = BrightnessController(backend: .ddc(dev))
            }
        }
        brightness = newBrightness
    }

    func display(id: CGDirectDisplayID) -> DisplayInfo? {
        displays.first { $0.id == id }
    }

    // MARK: - 镜像

    /// 让 `source` 镜像 `target`；target 为 0 时停止镜像
    @discardableResult
    func setMirror(source: CGDirectDisplayID, target: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { return false }
        guard CGConfigureDisplayMirrorOfDisplay(cfg, source, target) == .success else {
            CGCancelDisplayConfiguration(cfg)
            return false
        }
        let ok = CGCompleteDisplayConfiguration(cfg, .forSession) == .success
        refresh()
        return ok
    }

    /// 停止所有镜像（恢复扩展）
    func stopAllMirrors() {
        for d in displays where d.isMirroring {
            setMirror(source: d.id, target: 0)
        }
        refresh()
    }

    // MARK: - 工具

    private func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    private static func identity(of id: CGDirectDisplayID) -> DisplayIdentity {
        DisplayIdentity(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id))
    }

    /// 屏幕名称：优先用 NSScreen；镜像等情况下 NSScreen 会暂时缺失，此时使用上次缓存的名称
    private static func name(of id: CGDirectDisplayID, identity: DisplayIdentity) -> String {
        let cacheKey = "displayName.\(identity.vendor)-\(identity.model)"
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
        if let name = screen?.localizedName {
            UserDefaults.standard.set(name, forKey: cacheKey)
            return name
        }
        return UserDefaults.standard.string(forKey: cacheKey) ?? "显示器 \(id)"
    }
}
