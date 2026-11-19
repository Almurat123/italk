import Foundation
import AgentRuntime
import EventKit
import Contacts
import Photos
import CoreLocation
import AVFoundation
import CoreBluetooth
import UserNotifications
#if os(iOS)
import HealthKit
import HomeKit
import MediaPlayer
import CoreMotion
import AlarmKit
import CoreNFC
#endif

/// Live authorization for every `SystemPermission`, read from the frameworks on every call (never cached), plus iTalk's
/// own switches. HealthKit read access is unknowable by design and reported as such.
public final class ApplePermissionAuthority: PermissionAuthority, @unchecked Sendable {
    private let switches: @Sendable (Capability) async -> Bool
    public init(switches: @escaping @Sendable (Capability) async -> Bool) { self.switches = switches }

    public func isEnabled(_ c: Capability) async -> Bool { c == .runtime ? true : await switches(c) }

    public func status(_ p: SystemPermission) async -> PermissionState {
        switch p {
        case .none, .localNetwork: return .granted
        case .calendar: return Self.ek(EKEventStore.authorizationStatus(for: .event))
        case .reminders: return Self.ek(EKEventStore.authorizationStatus(for: .reminder))
        case .contacts:
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .authorized: return .granted
            case .limited: return .limited
            case .notDetermined: return .notDetermined
            case .restricted: return .restricted
            default: return .denied
            }
        case .photos, .photosAddOnly:
            switch PHPhotoLibrary.authorizationStatus(for: p == .photos ? .readWrite : .addOnly) {
            case .authorized: return .granted
            case .limited: return .limited
            case .notDetermined: return .notDetermined
            case .restricted: return .restricted
            default: return .denied
            }
        case .location:
            let s = CLLocationManager().authorizationStatus
            if locationAuthorized(s) { return .granted }
            switch s {
            case .notDetermined: return .notDetermined
            case .restricted: return .restricted
            default: return CLLocationManager.locationServicesEnabled() ? .denied : .unsupported("定位服务已在系统中关闭：设置 › 隐私与安全性 › 定位服务。")
            }
        case .camera: return Self.av(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone: return Self.av(AVCaptureDevice.authorizationStatus(for: .audio))
        case .speechRecognition: return .granted          // SpeechAnalyzer runs on device without the legacy recognizer prompt
        case .bluetooth:
            switch CBManager.authorization {
            case .allowedAlways: return .granted
            case .notDetermined: return .notDetermined
            case .restricted: return .restricted
            default: return .denied
            }
        case .notifications:
            let s = await UNUserNotificationCenter.current().notificationSettings()
            switch s.authorizationStatus {
            case .authorized, .provisional, .ephemeral: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        #if os(iOS)
        case .health:
            guard HKHealthStore.isHealthDataAvailable() else { return .unsupported("此设备没有健康数据。") }
            // Never report "granted" when the question itself failed: an unanswered status must lead to a request, not silence.
            do {
                let status = try await HKHealthStore().statusForAuthorizationRequest(toShare: [], read: HealthTypes.read)
                return status == .unnecessary ? .unknownByDesign : .notDetermined
            } catch { Self.healthError = error.localizedDescription; return .notDetermined }
        case .homeKit:
            guard Self.capability("ITalkHomeKitEnabled") else { return .unsupported("此版本尚未开通 HomeKit 能力（需开发者在 Xcode 中为 App 启用“家庭”）。") }
            return await MainActor.run { HomeAccess.shared.state }
        case .mediaLibrary:
            switch MPMediaLibrary.authorizationStatus() {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            case .restricted: return .restricted
            default: return .denied
            }
        case .motion:
            guard CMPedometer.isStepCountingAvailable() else { return .unsupported("此设备不支持计步。") }
            switch CMPedometer.authorizationStatus() {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            case .restricted: return .restricted
            default: return .denied
            }
        case .alarms:
            switch AlarmManager.shared.authorizationState {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .nfc:
            guard Self.capability("ITalkNFCEnabled") else { return .unsupported("此版本尚未开通 NFC 读取能力（需开发者在 Xcode 中启用 NFC Tag Reading）。") }
            return NFCNDEFReaderSession.readingAvailable ? .granted : .unsupported("此设备不支持读取 NFC 标签。")
        #else
        case .health, .homeKit, .mediaLibrary, .motion, .alarms, .nfc: return .unsupported("此平台不支持。")
        #endif
        }
    }

    public func request(_ p: SystemPermission) async -> PermissionState {
        switch p {
        case .calendar: _ = try? await EKEventStore().requestFullAccessToEvents()
        case .reminders: _ = try? await EKEventStore().requestFullAccessToReminders()
        case .contacts: _ = try? await CNContactStore().requestAccess(for: .contacts)
        case .photos: _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        case .photosAddOnly: _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        case .location: await LocationAuthorizer.request()
        case .camera: _ = await AVCaptureDevice.requestAccess(for: .video)
        case .microphone: _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .bluetooth: await BluetoothAuthorizer.request()
        case .notifications: _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        #if os(iOS)
        case .health:
            do { try await HKHealthStore().requestAuthorization(toShare: [], read: HealthTypes.read); Self.healthError = nil }
            catch { Self.healthError = error.localizedDescription }
        case .homeKit:
            guard Self.capability("ITalkHomeKitEnabled") else { break }
            await MainActor.run { HomeAccess.shared.start() }; try? await Task.sleep(for: .seconds(1))
        case .mediaLibrary: _ = await withCheckedContinuation { c in MPMediaLibrary.requestAuthorization { c.resume(returning: $0) } }
        case .motion:
            // No explicit request API: the first query shows the prompt.
            _ = await withCheckedContinuation { c in CMPedometer().queryPedometerData(from: .now.addingTimeInterval(-60), to: .now) { _, _ in c.resume() } }
        case .alarms: _ = try? await AlarmManager.shared.requestAuthorization()
        #endif
        default: break
        }
        return await status(p)
    }

    nonisolated(unsafe) public static var healthError: String?

    /// Capabilities that need an App ID entitlement are declared in Info.plist by the project generator when signed with them.
    static func capability(_ key: String) -> Bool { Bundle.main.object(forInfoDictionaryKey: key) as? Bool ?? false }

    static func ek(_ s: EKAuthorizationStatus) -> PermissionState {
        switch s {
        case .fullAccess: return .granted
        case .writeOnly: return .limited
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        default: return .denied
        }
    }
    static func av(_ s: AVAuthorizationStatus) -> PermissionState {
        switch s {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        default: return .denied
        }
    }
}

func locationAuthorized(_ s: CLAuthorizationStatus) -> Bool {
    #if os(iOS)
    return s == .authorizedWhenInUse || s == .authorizedAlways
    #else
    return s == .authorizedAlways
    #endif
}

/// Location prompt needs a retained manager and its delegate callback.
@MainActor final class LocationAuthorizer: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var done: CheckedContinuation<Void, Never>?
    static func request() async {
        let a = LocationAuthorizer()
        await withCheckedContinuation { c in
            a.done = c; a.manager.delegate = a
            if a.manager.authorizationStatus != .notDetermined { a.finish(); return }
            #if os(iOS)
            a.manager.requestWhenInUseAuthorization()
            #else
            a.manager.requestAlwaysAuthorization()
            #endif
        }
    }
    private func finish() { done?.resume(); done = nil }
    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let s = m.authorizationStatus
        Task { @MainActor in if s != .notDetermined { self.finish() } }
    }
}

/// Bluetooth prompt appears when a central manager is created.
@MainActor final class BluetoothAuthorizer: NSObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private var done: CheckedContinuation<Void, Never>?
    static func request() async {
        let a = BluetoothAuthorizer()
        await withCheckedContinuation { c in a.done = c; a.manager = CBCentralManager(delegate: a, queue: nil) }
    }
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) { Task { @MainActor in self.done?.resume(); self.done = nil } }
}

/// One row of the permission center: iTalk's own switch next to the real iOS state, in plain words.
public struct PermissionRow: Identifiable, Sendable, Equatable {
    public enum Action: Sendable, Equatable { case none, request, openSettings, enableSwitch }
    public var id: String { capability.rawValue }
    public var capability: Capability
    public var title: String
    public var symbol: String
    public var switchOn: Bool
    public var system: SystemPermission
    public var state: PermissionState
    /// What iOS currently says, as the person should read it.
    public var statusText: String
    public var action: Action
    public var tools: [String]
}

public enum PermissionReport {
    /// Capabilities that touch the system get a row; pure-software capabilities only have the iTalk switch.
    public static func rows(registry: ToolRegistry, authority: any PermissionAuthority, switches: [Capability]) async -> [PermissionRow] {
        var rows: [PermissionRow] = []
        for c in switches {
            let specs = registry.names.compactMap { registry.tool(named: $0)?.spec }.filter { $0.capability == c }
            let system = specs.map(\.systemPermission).first { $0 != .none } ?? .none
            let on = await authority.isEnabled(c)
            let state = system == .none ? PermissionState.granted : await authority.status(system)
            let (text, action) = describe(system: system, state: state, on: on)
            rows.append(PermissionRow(capability: c, title: c.label, symbol: c.symbol, switchOn: on, system: system, state: state, statusText: text, action: action, tools: specs.map(\.name)))
        }
        return rows
    }

    public static func describe(system: SystemPermission, state: PermissionState, on: Bool) -> (String, PermissionRow.Action) {
        if !on { return ("已在 iTalk 中关闭：开启后 iTalk 才会使用", .enableSwitch) }
        guard system != .none else { return ("无需系统权限", .none) }
        let name = system.settingsLabel
        switch state {
        case .granted: return ("已允许", .none)
        case .limited: return ("部分允许（\(name)）", .openSettings)
        case .notDetermined:
            if system == .health { return ("尚未请求。点“请求权限”后，iOS 会让你选择允许读取哪些健康数据", .request) }
            return ("尚未请求。点“请求权限”后 iOS 会询问你", .request)
        case .denied:
            if system == .health { return ("你没有允许读取健康数据。请在 设置 › 健康 › 数据访问与设备 › iTalk 中打开", .openSettings) }
            return ("已被拒绝。请在 设置 › iTalk › \(name) 中开启", .openSettings)
        case .restricted: return ("受屏幕使用时间或设备管理限制，iTalk 无法更改", .none)
        case .unsupported(let why): return (why, .none)
        case .unknownByDesign:
            return ("已请求过。iOS 不会告诉 App 健康数据是否被允许读取；如果问到的数据读不出来，请到 设置 › 健康 › 数据访问与设备 › iTalk 检查", .openSettings)
        }
    }
}
