import Foundation
import AgentRuntime
#if os(iOS)
import HomeKit

/// HomeKit: one manager for the app's lifetime; homes load asynchronously after creation (which also shows the prompt).
@MainActor final class HomeAccess: NSObject, HMHomeManagerDelegate {
    static let shared = HomeAccess()
    private(set) var manager: HMHomeManager?
    private var loaded = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func start() { if manager == nil { let m = HMHomeManager(); m.delegate = self; manager = m } }

    var state: PermissionState {
        guard let m = manager else { return .notDetermined }
        let s = m.authorizationStatus
        if s.contains(.authorized) { return .granted }
        if s.contains(.restricted) { return .restricted }
        return s.contains(.determined) ? .denied : .notDetermined
    }

    func homes() async -> [HMHome] {
        start()
        if !loaded {
            await withCheckedContinuation { c in waiters.append(c)
                Task { @MainActor in try? await Task.sleep(for: .seconds(6)); self.release() }
            }
        }
        return manager?.homes ?? []
    }
    private func release() { loaded = true; let w = waiters; waiters = []; w.forEach { $0.resume() } }
    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) { Task { @MainActor in self.release() } }
}
#endif
