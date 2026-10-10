import CoreGraphics
import Foundation

/// 色温：通过 gamma 表实现（对内置与外接屏都有效）
enum Tint {
    /// 把色温（K）转换为 RGB 增益（0-1），Tanner Helland 近似
    static func gains(kelvin: Int) -> (r: Float, g: Float, b: Float) {
        let t = Double(max(1000, min(10000, kelvin))) / 100
        func clamp(_ v: Double) -> Double { min(255, max(0, v)) }

        let r = t <= 66 ? 255 : clamp(329.698727446 * pow(t - 60, -0.1332047592))
        let g = t <= 66
            ? clamp(99.4708025861 * log(t) - 161.1195681661)
            : clamp(288.1221695283 * pow(t - 60, -0.0755148492))
        let b: Double
        if t >= 66 { b = 255 } else if t <= 19 { b = 0 } else {
            b = clamp(138.5177312231 * log(t - 10) - 305.0447927307)
        }
        return (Float(r / 255), Float(g / 255), Float(b / 255))
    }

    static func apply(display: CGDirectDisplayID, kelvin: Int) {
        let (r, g, b) = gains(kelvin: kelvin)
        let n = 256
        var rt = [Float](repeating: 0, count: n)
        var gt = rt, bt = rt
        for i in 0..<n {
            let x = Float(i) / Float(n - 1)
            rt[i] = x * r
            gt[i] = x * g
            bt[i] = x * b
        }
        CGSetDisplayTransferByTable(display, UInt32(n), rt, gt, bt)
    }

    /// 恢复系统颜色配置（退出时调用）
    static func restoreAll() {
        CGDisplayRestoreColorSyncSettings()
    }
}
