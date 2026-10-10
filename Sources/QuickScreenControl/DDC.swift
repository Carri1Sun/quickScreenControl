import Foundation
import IOKit

// MARK: - 私有 IOAVService 接口（Apple Silicon 外接屏 DDC/CI）

private typealias CreateWithServiceFn = @convention(c) (CFAllocator?, io_service_t) -> UnsafeMutableRawPointer?
private typealias I2CReadFn = @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, UnsafeMutableRawPointer?, UInt32) -> Int32
private typealias I2CWriteFn = @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, UnsafeRawPointer?, UInt32) -> Int32

private enum IOAVAPI {
    static let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)

    private static func load<T>(_ name: String) -> T? {
        guard let h = handle, let sym = dlsym(h, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    static let createWithService: CreateWithServiceFn? = load("IOAVServiceCreateWithService")
    static let readI2C: I2CReadFn? = load("IOAVServiceReadI2C")
    static let writeI2C: I2CWriteFn? = load("IOAVServiceWriteI2C")
    static var available: Bool { createWithService != nil && readI2C != nil && writeI2C != nil }
}

/// EDID 中解析出的显示器身份（与 CGDisplay 的 vendor / model / serial 一致）
struct DisplayIdentity: Hashable {
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32

    var key: String { "\(vendor)-\(model)-\(serial)" }

    init(vendor: UInt32, model: UInt32, serial: UInt32) {
        self.vendor = vendor; self.model = model; self.serial = serial
    }

    /// 两个身份是否指向同一型号；序列号任一方未知（0）时忽略序列号
    func matches(_ other: DisplayIdentity) -> Bool {
        vendor == other.vendor && model == other.model
            && (serial == 0 || other.serial == 0 || serial == other.serial)
    }

    /// 解析 IORegistry DisplayHints 中的 "EDID UUID"，形如 "05E324B3-0000-0000-1323-0103803C2278"
    /// 前 4 字节为厂商号（大端），接着 2 字节为型号（小端）；UUID 不含序列号，记为 0
    init?(edidUUID: String) {
        let hex = edidUUID.replacingOccurrences(of: "-", with: "")
        guard hex.count >= 8 else { return nil }
        var bytes: [UInt8] = []
        for i in stride(from: 0, to: 8, by: 2) {
            let start = hex.index(hex.startIndex, offsetBy: i)
            let end = hex.index(start, offsetBy: 2)
            guard let b = UInt8(hex[start..<end], radix: 16) else { return nil }
            bytes.append(b)
        }
        vendor = UInt32(bytes[0]) << 8 | UInt32(bytes[1])
        model = UInt32(bytes[3]) << 8 | UInt32(bytes[2])
        serial = 0
    }

    init?(edid: Data) {
        guard edid.count >= 16 else { return nil }
        let b = [UInt8](edid)
        vendor = UInt32(b[8]) << 8 | UInt32(b[9])
        model = UInt32(b[11]) << 8 | UInt32(b[10])
        serial = UInt32(b[15]) << 24 | UInt32(b[14]) << 16 | UInt32(b[13]) << 8 | UInt32(b[12])
    }
}

/// 一块外接显示器对应的 DDC 通道
final class DDCDevice {
    let service: UnsafeMutableRawPointer
    let registryPath: String

    init(service: UnsafeMutableRawPointer, registryPath: String) {
        self.service = service
        self.registryPath = registryPath
    }

    private func writeI2C(_ data: [UInt8]) -> Bool {
        guard let fn = IOAVAPI.writeI2C else { return false }
        return data.withUnsafeBytes { raw in
            fn(service, 0x37, 0x51, raw.baseAddress, UInt32(data.count)) == 0
        }
    }

    private func readI2C(count: Int) -> [UInt8]? {
        guard let fn = IOAVAPI.readI2C else { return nil }
        var buf = [UInt8](repeating: 0, count: count)
        let r = buf.withUnsafeMutableBytes { raw in
            fn(service, 0x37, 0, raw.baseAddress, UInt32(count))
        }
        return r == 0 ? buf : nil
    }

    /// 读取 VCP 特性，返回 (当前值, 最大值)
    func read(vcp: UInt8, attempts: Int = 5) -> (current: Int, max: Int)? {
        var req: [UInt8] = [0x82, 0x01, vcp]
        req.append(0x6E ^ 0x51 ^ req.reduce(0, ^))
        for _ in 0..<attempts {
            // 请求连发两次，与写入一致，提高显示器接收成功率
            _ = writeI2C(req)
            usleep(20_000)
            guard writeI2C(req) else { usleep(40_000); continue }
            usleep(50_000)
            guard let buf = readI2C(count: 12) else { usleep(40_000); continue }
            // 回复格式：0x02(opcode) result vcp type maxH maxL curH curL
            for i in 0..<(buf.count - 8) where buf[i] == 0x02 && buf[i + 2] == vcp {
                let max = Int(buf[i + 4]) << 8 | Int(buf[i + 5])
                let cur = Int(buf[i + 6]) << 8 | Int(buf[i + 7])
                if max > 0 { return (cur, max) }
            }
            // 显示器未就绪时会回复空包（6e 80 be ...），稍等后重试
            usleep(100_000)
        }
        return nil
    }

    /// 写入 VCP 特性
    @discardableResult
    func write(vcp: UInt8, value: Int) -> Bool {
        let v = UInt16(clamping: value)
        var payload: [UInt8] = [0x84, 0x03, vcp, UInt8(v >> 8), UInt8(v & 0xFF)]
        payload.append(0x6E ^ 0x51 ^ payload.reduce(0, ^))
        var ok = false
        for _ in 0..<2 {
            ok = writeI2C(payload) || ok
            usleep(40_000)
        }
        return ok
    }
}

enum DDCDiscovery {
    /// 枚举所有外接 DCPAVServiceProxy，并尝试从祖先节点中读取 EDID 得到身份
    static func discover() -> [(device: DDCDevice, identity: DisplayIdentity?)] {
        guard IOAVAPI.available, let create = IOAVAPI.createWithService else { return [] }

        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iter) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iter) }

        var result: [(device: DDCDevice, identity: DisplayIdentity?)] = []
        var entry = IOIteratorNext(iter)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iter) }

            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External" else { continue }

            guard let svc = create(kCFAllocatorDefault, entry) else { continue }
            let identity = findHintsIdentity(from: entry) ?? findEDIDIdentity(from: entry)
            result.append((DDCDevice(service: svc, registryPath: "DCPAVServiceProxy"), identity))
        }
        return result
    }

    /// Apple Silicon 上 DDC 代理与 DisplayHints 同挂在 iop-dcpextN-nub 下，据此关联
    private static func findHintsIdentity(from start: io_registry_entry_t) -> DisplayIdentity? {
        guard let nub = findAncestor(from: start, where: { name in
            name.hasPrefix("iop-dcpext") && name.hasSuffix("-nub")
        }) else { return nil }
        defer { IOObjectRelease(nub) }
        var budget = 20_000
        return findDisplayHints(under: nub, depth: 0, budget: &budget)
    }

    private static func findDisplayHints(under root: io_registry_entry_t, depth: Int, budget: inout Int) -> DisplayIdentity? {
        guard depth < 40, budget > 0 else { return nil }
        var iter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(root, kIOServicePlane, &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }

        var child = IOIteratorNext(iter)
        while child != 0 {
            defer { IOObjectRelease(child); child = IOIteratorNext(iter) }
            budget -= 1

            if let hints = IORegistryEntryCreateCFProperty(child, "DisplayHints" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let uuid = hints["EDID UUID"] as? String,
               let id = DisplayIdentity(edidUUID: uuid) {
                // 顺便缓存产品名（镜像时 NSScreen 会缺失，名称就靠这个缓存）
                if let product = hints["ProductName"] as? String {
                    UserDefaults.standard.set(product, forKey: "displayName.\(id.vendor)-\(id.model)")
                }
                return id
            }
            if let found = findDisplayHints(under: child, depth: depth + 1, budget: &budget) {
                return found
            }
        }
        return nil
    }

    private static func findAncestor(from start: io_registry_entry_t, where match: (String) -> Bool) -> io_registry_entry_t? {
        var current = start
        IOObjectRetain(current)
        for _ in 0..<40 {
            var nameBuf = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(current, &nameBuf)
            if match(String(cString: nameBuf)) { return current }

            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 else { break }
            IOObjectRelease(current)
            current = parent
        }
        IOObjectRelease(current)
        return nil
    }

    /// 沿父节点向上查找 EDID 属性
    private static func findEDIDIdentity(from start: io_registry_entry_t) -> DisplayIdentity? {
        var current = start
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }

        for _ in 0..<30 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 else { break }
            IOObjectRelease(current)
            current = parent

            if let edid = IORegistryEntryCreateCFProperty(current, "EDID" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Data,
               let id = DisplayIdentity(edid: edid) {
                return id
            }
        }
        return nil
    }
}
