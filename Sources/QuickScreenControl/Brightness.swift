import Foundation
import CoreGraphics

/// 内置屏亮度（DisplayServices 私有框架）
private enum DisplayServicesAPI {
    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    static let get: GetFn? = {
        guard let h = handle, let s = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(s, to: GetFn.self)
    }()
    static let set: SetFn? = {
        guard let h = handle, let s = dlsym(h, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(s, to: SetFn.self)
    }()
}

/// 统一的亮度控制：内置屏走 DisplayServices，外接屏走 DDC/CI。
/// 写入是串行的并且会合并：拖动滑块时只保留最新值，避免 DDC 堆积。
final class BrightnessController {
    enum Backend {
        case builtin(CGDirectDisplayID)
        case ddc(DDCDevice)
    }

    let backend: Backend
    private let queue = DispatchQueue(label: "brightness.write")
    private let lock = NSLock()
    private var pending: Int?
    private var writing = false
    private var ddcMax: Int?

    init(backend: Backend) { self.backend = backend }

    var isSupported: Bool {
        switch backend {
        case .builtin: return DisplayServicesAPI.get != nil && DisplayServicesAPI.set != nil
        case .ddc: return true
        }
    }

    /// 读取当前亮度百分比（0-100）
    func read() -> Int? {
        switch backend {
        case .builtin(let id):
            guard let get = DisplayServicesAPI.get else { return nil }
            var v: Float = 0
            guard get(id, &v) == 0 else { return nil }
            return Int((v * 100).rounded())
        case .ddc(let dev):
            guard let r = dev.read(vcp: 0x10) else { return nil }
            ddcMax = r.max
            return r.max > 0 ? r.current * 100 / r.max : nil
        }
    }

    /// 异步设置亮度百分比（0-100）
    func set(_ percent: Int) {
        let p = max(0, min(100, percent))
        lock.lock()
        pending = p
        let shouldStart = !writing
        writing = true
        lock.unlock()
        guard shouldStart else { return }
        queue.async { [weak self] in self?.drain() }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let p = pending else {
                writing = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            apply(p)
        }
    }

    private func apply(_ p: Int) {
        switch backend {
        case .builtin(let id):
            _ = DisplayServicesAPI.set?(id, Float(p) / 100)
        case .ddc(let dev):
            if ddcMax == nil { ddcMax = dev.read(vcp: 0x10)?.max }
            let max = ddcMax ?? 100
            dev.write(vcp: 0x10, value: p * max / 100)
        }
    }
}
