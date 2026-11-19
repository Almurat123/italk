import Foundation
import AgentRuntime
import Network
import CoreBluetooth
import AVFoundation
#if os(iOS)
import UIKit
import CoreMotion
import CoreNFC
#endif

enum DeviceSkills {
    static let info = FnTool(ToolSpec(name: "device_status", description: "设备状态：电量与充电、低电量模式、存储空间、温度状态、系统版本、机型", permission: .readOnly, capability: .device)) { _, _ in
        var o: [String: JSONValue] = [:]
        #if os(iOS)
        let ui: [String: JSONValue] = await MainActor.run {
            let d = UIDevice.current; d.isBatteryMonitoringEnabled = true
            return ["batteryPercent": .number(d.batteryLevel < 0 ? -1 : (Double(d.batteryLevel) * 100).rounded()),
                    "charging": .string(["unknown", "unplugged", "charging", "full"][d.batteryState.rawValue]),
                    "system": .string("\(d.systemName) \(d.systemVersion)")]
        }
        o.merge(ui) { a, _ in a }
        #endif
        var size = 0; sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: max(size, 1)); sysctlbyname("hw.machine", &machine, &size, nil, 0)
        o["model"] = .string(String(cString: machine))
        let p = ProcessInfo.processInfo
        o["lowPowerMode"] = .bool(p.isLowPowerModeEnabled)
        o["thermalState"] = .string(["nominal", "fair", "serious", "critical"][p.thermalState.rawValue])
        o["memoryGB"] = .number((Double(p.physicalMemory) / 1_073_741_824).rounded())
        if let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            o["freeGB"] = .number((Double(v.volumeAvailableCapacityForImportantUsage ?? 0) / 1e9 * 10).rounded() / 10)
            o["totalGB"] = .number((Double(v.volumeTotalCapacity ?? 0) / 1e9).rounded())
        }
        return out(o, "设备状态")
    }

    static let steps = FnTool(ToolSpec(name: "motion_activity", description: "iPhone 运动传感器：今天/指定时段的步数、距离、楼层，以及当前活动（静止/步行/跑步/驾车）", parameters: [
        "start": ParamSpec(.string, "开始时间，默认今天 0 点", required: false, maxLength: 40)
    ], permission: .readOnly, capability: .sensors, systemPermission: .motion, dataClass: .personal)) { a, ctx in
        #if os(iOS)
        let start = ArgDate.parse(a.str("start"), now: ctx.now) ?? Calendar.current.startOfDay(for: ctx.now)
        // Values are copied out on the callback queue; CoreMotion objects never cross into async code.
        let data: [String: JSONValue] = await withCheckedContinuation { c in
            CMPedometer().queryPedometerData(from: start, to: ctx.now) { d, _ in
                var o: [String: JSONValue] = [:]
                if let d {
                    o["steps"] = .number(d.numberOfSteps.doubleValue)
                    if let m = d.distance { o["km"] = .number((m.doubleValue / 10).rounded() / 100) }
                    if let f = d.floorsAscended { o["floorsUp"] = .number(f.doubleValue) }
                }
                c.resume(returning: o)
            }
        }
        var o = data; o["from"] = .string(ArgDate.iso(start))
        if CMMotionActivityManager.isActivityAvailable() {
            let kind: String? = await withCheckedContinuation { c in
                CMMotionActivityManager().queryActivityStarting(from: ctx.now.addingTimeInterval(-600), to: ctx.now, to: .main) { a, _ in
                    c.resume(returning: a?.last.map { l in l.automotive ? "driving" : l.cycling ? "cycling" : l.running ? "running" : l.walking ? "walking" : l.stationary ? "stationary" : "unknown" })
                }
            }
            if let kind { o["activity"] = .string(kind) }
        }
        return out(o, "步数 \(o["steps"]?.number.map { Int($0) } ?? 0)")
        #else
        throw fail("此平台没有运动传感器")
        #endif
    }

    static func brightness(_ ctx: AppleSkillContext) -> FnTool {
        FnTool(ToolSpec(name: "screen_brightness", description: "读取或设置屏幕亮度（0–1）", parameters: [
            "value": ParamSpec(.number, "要设置的亮度 0–1；省略则只读取", required: false, minimum: 0, maximum: 1)
        ], permission: .lowRiskAction, capability: .device)) { a, _ in
            if let v = a.num("value") {
                let ok = await ctx.presenter.setScreenBrightness(v)
                return out(["brightness": .number(v), "set": .bool(ok)], ok ? "亮度已设为 \(Int(v * 100))%" : "无法设置亮度")
            }
            let v = await ctx.presenter.screenBrightness() ?? -1
            return out(["brightness": .number(v)], "当前亮度 \(Int(v * 100))%")
        }
    }

    static let flashlight = FnTool(ToolSpec(name: "flashlight", description: "打开或关闭手电筒", parameters: [
        "on": ParamSpec(.boolean, "true 打开 / false 关闭"),
        "level": ParamSpec(.number, "亮度 0.1–1，默认 1", required: false, minimum: 0.1, maximum: 1)
    ], permission: .lowRiskAction, capability: .device)) { a, _ in
        #if os(iOS)
        guard let dev = AVCaptureDevice.default(for: .video), dev.hasTorch else { throw fail("此设备没有手电筒") }
        try dev.lockForConfiguration(); defer { dev.unlockForConfiguration() }
        if a.flag("on") == true { try dev.setTorchModeOn(level: Float(a.num("level") ?? 1)) } else { dev.torchMode = .off }
        return out(["on": .bool(dev.torchMode == .on)], dev.torchMode == .on ? "手电筒已打开" : "手电筒已关闭")
        #else
        throw fail("此平台没有手电筒")
        #endif
    }

    static let network = FnTool(ToolSpec(name: "network_status", description: "当前网络：是否联网、Wi-Fi/蜂窝、是否低数据模式或按流量计费", permission: .readOnly, capability: .network)) { _, _ in
        let path: NWPath = await withCheckedContinuation { c in
            let m = NWPathMonitor()
            let once = OnceBox()
            m.pathUpdateHandler = { p in if once.claim() { m.cancel(); c.resume(returning: p) } }
            m.start(queue: .global())
        }
        let kind = path.usesInterfaceType(.wifi) ? "wifi" : path.usesInterfaceType(.cellular) ? "cellular" : path.usesInterfaceType(.wiredEthernet) ? "ethernet" : "other"
        return out(["online": .bool(path.status == .satisfied), "interface": .string(path.status == .satisfied ? kind : "none"),
                    "expensive": .bool(path.isExpensive), "lowDataMode": .bool(path.isConstrained),
                    "note": .string("Wi-Fi 名称和开关、蜂窝数据开关不对第三方 App 开放。")], path.status == .satisfied ? "已联网（\(kind)）" : "未联网")
    }

    static let bluetoothScan = FnTool(ToolSpec(name: "bluetooth_scan", description: "扫描附近的低功耗蓝牙设备（名称、信号强度）", parameters: [
        "seconds": ParamSpec(.integer, "扫描时长，默认 5，最多 15", required: false, minimum: 1, maximum: 15)
    ], permission: .readOnly, capability: .bluetooth, systemPermission: .bluetooth, timeoutSeconds: 20)) { a, _ in
        let found = try await BLEScanner.scan(seconds: Double(a.int("seconds") ?? 5))
        return out(["devices": .array(found.map { .object(["name": .string($0.name), "rssi": .number(Double($0.rssi))]) }),
                    "note": .string("只能发现正在广播的 BLE 设备；已配对的耳机、键盘等经典蓝牙设备和系统蓝牙开关不对第三方开放。")], "发现 \(found.count) 个蓝牙设备")
    }

    static let nfcRead = FnTool(ToolSpec(name: "nfc_read_tag", description: "读取 NFC 标签（NDEF：网址、文字）。会弹出系统扫描界面，请把 iPhone 顶部靠近标签", permission: .readOnly,
                                         capability: .nfc, systemPermission: .nfc, timeoutSeconds: 70)) { _, _ in
        #if os(iOS)
        let records = try await NFCReader.read()
        return out(["records": .array(records.map(JSONValue.string))], records.isEmpty ? "标签为空" : "读到 \(records.count) 条记录")
        #else
        throw fail("此平台不支持 NFC")
        #endif
    }

    static let clipboardRead = FnTool(ToolSpec(name: "clipboard_read", description: "读取剪贴板里已有的文字（粘贴的来源；不能写入，系统会询问是否允许粘贴）", permission: .readOnly, capability: .clipboard, dataClass: .personal)) { _, _ in
        #if os(iOS)
        let s = await MainActor.run { UIPasteboard.general.string }
        return out(["text": .string(String((s ?? "").prefix(10_000))), "hasText": .bool(s != nil)], s == nil ? "剪贴板中没有文字" : "已读取剪贴板")
        #else
        throw fail("此平台不支持")
        #endif
    }

    static let clipboardWrite = FnTool(ToolSpec(name: "clipboard_write", description: "把给定的文字复制到剪贴板（写入、拷贝）", parameters: [
        "text": ParamSpec(.string, "文字", maxLength: 20_000)
    ], permission: .lowRiskAction, capability: .clipboard)) { a, _ in
        #if os(iOS)
        let t = a.str("text") ?? ""
        await MainActor.run { UIPasteboard.general.string = t }
        return out(["copied": .bool(true)], "已复制到剪贴板")
        #else
        throw fail("此平台不支持")
        #endif
    }
}

final class OnceBox: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

@MainActor final class BLEScanner: NSObject, CBCentralManagerDelegate {
    struct Device { let name: String; let rssi: Int }
    private var manager: CBCentralManager?
    private var found: [UUID: Device] = [:]
    private var ready: CheckedContinuation<Void, Error>?

    static func scan(seconds: Double) async throws -> [Device] {
        let s = BLEScanner()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in s.ready = c; s.manager = CBCentralManager(delegate: s, queue: nil) }
        s.manager?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        try? await Task.sleep(for: .seconds(seconds))
        s.manager?.stopScan()
        return s.found.values.sorted { $0.rssi > $1.rssi }.prefix(30).map { $0 }
    }
    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        let state = c.state
        Task { @MainActor in
            guard let r = self.ready else { return }
            switch state {
            case .poweredOn: self.ready = nil; r.resume()
            case .poweredOff: self.ready = nil; r.resume(throwing: fail("蓝牙已关闭，请在控制中心打开"))
            case .unauthorized: self.ready = nil; r.resume(throwing: fail("没有蓝牙权限：设置 › iTalk › 蓝牙"))
            case .unsupported: self.ready = nil; r.resume(throwing: fail("此设备不支持低功耗蓝牙"))
            default: break
            }
        }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name
        let id = p.identifier, r = rssi.intValue
        guard let name, !name.isEmpty else { return }
        Task { @MainActor in self.found[id] = Device(name: name, rssi: r) }
    }
}

#if os(iOS)
@MainActor final class NFCReader: NSObject, NFCNDEFReaderSessionDelegate {
    private var session: NFCNDEFReaderSession?
    private var done: CheckedContinuation<[String], Error>?
    static func read() async throws -> [String] {
        let r = NFCReader()
        return try await withCheckedThrowingContinuation { c in
            r.done = c
            r.session = NFCNDEFReaderSession(delegate: r, queue: nil, invalidateAfterFirstRead: true)
            r.session?.alertMessage = "把 iPhone 顶部靠近 NFC 标签"
            r.session?.begin()
        }
    }
    private func finish(_ result: Result<[String], Error>) { guard let d = done else { return }; done = nil; d.resume(with: result); _ = self }
    nonisolated func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        let records = messages.flatMap(\.records).compactMap { r -> String? in
            if let u = r.wellKnownTypeURIPayload() { return u.absoluteString }
            let (t, _) = r.wellKnownTypeTextPayload(); return t
        }
        Task { @MainActor in self.finish(.success(records)) }
    }
    nonisolated func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        let code = (error as? NFCReaderError)?.code
        Task { @MainActor in
            self.finish(code == .readerSessionInvalidationErrorFirstNDEFTagRead ? .success([]) : .failure(fail(code == .readerSessionInvalidationErrorUserCanceled ? "用户取消了扫描" : "未读到标签")))
        }
    }
}
#endif
