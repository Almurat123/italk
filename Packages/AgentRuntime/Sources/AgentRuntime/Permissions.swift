import Foundation

/// An operating-system authorization a tool needs at execution time. Checked live on every call, never cached.
public enum SystemPermission: String, Codable, Sendable, CaseIterable {
    case none
    case calendar, reminders, contacts, photos, photosAddOnly, location, health, camera, microphone, speechRecognition
    case homeKit, mediaLibrary, motion, bluetooth, notifications, alarms, nfc, localNetwork

    /// Where the person re-enables it (shown in recovery cards).
    public var settingsLabel: String {
        switch self {
        case .none: ""
        case .calendar: "日历"
        case .reminders: "提醒事项"
        case .contacts: "通讯录"
        case .photos: "照片"
        case .photosAddOnly: "照片（仅添加）"
        case .location: "位置"
        case .health: "健康"
        case .camera: "相机"
        case .microphone: "麦克风"
        case .speechRecognition: "语音识别"
        case .homeKit: "家庭"
        case .mediaLibrary: "媒体与 Apple Music"
        case .motion: "运动与健身"
        case .bluetooth: "蓝牙"
        case .notifications: "通知"
        case .alarms: "闹钟"
        case .nfc: "NFC"
        case .localNetwork: "本地网络"
        }
    }
}

public enum PermissionState: Codable, Sendable, Equatable {
    case granted
    /// Partial access (e.g. limited photo library, write-only calendar). The tool decides what it can do.
    case limited
    case notDetermined
    case denied
    /// Blocked by device management or parental controls; the person cannot change it in Settings.
    case restricted
    /// This device or OS cannot do it at all.
    case unsupported(String)
    /// The system deliberately hides the answer (HealthKit read access). Execution proceeds; "no data" may mean "not allowed".
    case unknownByDesign
}

public enum PermissionRecovery: String, Codable, Sendable {
    case none
    /// Open Settings › iTalk.
    case openSystemSettings
    /// Turn the capability back on inside iTalk (Settings › 隐私与权限).
    case enableInITalk
    case notPossible
    /// The failure may be transient; trying again is reasonable.
    case retry
}

public struct PermissionVerdict: Codable, Sendable, Equatable {
    public var allowed: Bool
    public var permission: SystemPermission
    public var state: PermissionState
    public var recovery: PermissionRecovery
    /// One sentence for the person and the model: what is blocked and how to fix it.
    public var message: String
    public init(allowed: Bool, permission: SystemPermission, state: PermissionState, recovery: PermissionRecovery, message: String) {
        self.allowed = allowed; self.permission = permission; self.state = state; self.recovery = recovery; self.message = message
    }

    /// Structured result handed back to the model in place of tool output.
    public var asToolResult: JSONValue {
        .object(["error": .string("permission_unavailable"), "permission": .string(permission.rawValue),
                 "recovery": .string(recovery.rawValue), "message": .string(message)])
    }
}

/// The single source of truth for "may this run now": system authorization plus iTalk's own user switches.
/// The app implements it with the real frameworks; tests use `StaticPermissionAuthority`.
public protocol PermissionAuthority: Sendable {
    func status(_ permission: SystemPermission) async -> PermissionState
    /// Shows the system prompt when the state is `.notDetermined`; returns the new state.
    func request(_ permission: SystemPermission) async -> PermissionState
    /// iTalk's user-controlled switch for a capability domain (e.g. web access, health answers).
    func isEnabled(_ capability: Capability) async -> Bool
}

public enum PermissionGate {
    /// Live check right before execution. `mayRequest`: the app is in the foreground and a system prompt may appear.
    public static func evaluate(_ spec: ToolSpec, authority: any PermissionAuthority, mayRequest: Bool = true) async -> PermissionVerdict {
        if !(await authority.isEnabled(spec.capability)) {
            return PermissionVerdict(allowed: false, permission: spec.systemPermission, state: .denied, recovery: .enableInITalk,
                                     message: "你已在 iTalk 中关闭「\(spec.capability.label)」。可在 iTalk 设置 › 隐私与权限 中重新开启。")
        }
        let p = spec.systemPermission
        guard p != .none else { return PermissionVerdict(allowed: true, permission: p, state: .granted, recovery: .none, message: "") }
        var state = await authority.status(p)
        if state == .notDetermined, mayRequest { state = await authority.request(p) }
        switch state {
        case .granted, .limited, .unknownByDesign:
            return PermissionVerdict(allowed: true, permission: p, state: state, recovery: .none, message: "")
        case .notDetermined:
            return PermissionVerdict(allowed: false, permission: p, state: state, recovery: .none,
                                     message: "需要「\(p.settingsLabel)」权限，请回到 iTalk 前台后再试，系统会询问你。")
        case .denied:
            return PermissionVerdict(allowed: false, permission: p, state: state, recovery: .openSystemSettings,
                                     message: "iTalk 没有「\(p.settingsLabel)」权限。可前往 设置 › iTalk › \(p.settingsLabel) 开启后再试。")
        case .restricted:
            return PermissionVerdict(allowed: false, permission: p, state: state, recovery: .notPossible,
                                     message: "「\(p.settingsLabel)」受设备管理或屏幕使用时间限制，iTalk 无法更改。")
        case .unsupported(let why):
            return PermissionVerdict(allowed: false, permission: p, state: state, recovery: .notPossible, message: why)
        }
    }
}

/// Deterministic authority for tests and previews.
public struct StaticPermissionAuthority: PermissionAuthority {
    public var enabled: Set<Capability>
    public var system: [SystemPermission: PermissionState]
    /// State a `.notDetermined` permission becomes after the (simulated) prompt.
    public var afterPrompt: PermissionState
    public init(enabled: Set<Capability> = Set(Capability.allCases), system: [SystemPermission: PermissionState] = [:], afterPrompt: PermissionState = .granted) {
        self.enabled = enabled; self.system = system; self.afterPrompt = afterPrompt
    }
    public func status(_ p: SystemPermission) async -> PermissionState { system[p] ?? .granted }
    public func request(_ p: SystemPermission) async -> PermissionState { (system[p] ?? .granted) == .notDetermined ? afterPrompt : (system[p] ?? .granted) }
    public func isEnabled(_ c: Capability) async -> Bool { c == .runtime || enabled.contains(c) }
}

/// Wraps the legacy `granted` closure (capability switches only; every system permission treated as granted).
struct ClosurePermissionAuthority: PermissionAuthority {
    let granted: @Sendable () -> Set<Capability>
    func status(_ p: SystemPermission) async -> PermissionState { .granted }
    func request(_ p: SystemPermission) async -> PermissionState { .granted }
    func isEnabled(_ c: Capability) async -> Bool { c == .runtime || granted().contains(c) }
}
