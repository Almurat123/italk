import Foundation
import Observation
import UIKit
import AgentRuntime
import AppleSkills

/// UI-facing view of the one global skill registry (the same catalog every local, cloud and remote model sees).
/// Built from the live registry, the live iOS authorization states and the person's switches; nothing is hard-coded per skill.
@MainActor @Observable final class SkillRegistryCenter {
    private(set) var skills: [SkillInfo] = []
    private(set) var isRefreshing = false
    @ObservationIgnored private let platform: AgentPlatform
    @ObservationIgnored private var tokens: [String: Int] = [:]

    init(platform: AgentPlatform = .shared) { self.platform = platform }

    var enabledCount: Int { skills.filter(\.enabled).count }
    func skill(_ id: String) -> SkillInfo? { skills.first { $0.id == id } }
    func instructions(_ id: String) -> String? { platform.catalog.skill(id)?.instructions }
    func hasCustomText(_ id: String) -> Bool { platform.hasSkillTextOverride(id) }

    func saveText(id: String, summary: String, instructions: String) async throws {
        try await platform.setSkillTextOverride(SkillTextOverride(summary: summary, instructions: instructions), for: id)
        await refresh()
    }

    func resetText(_ id: String) async throws {
        try await platform.setSkillTextOverride(nil, for: id)
        await refresh()
    }

    /// Re-reads the registry and every skill's live authorization. Cheap enough to call when a screen appears or the app returns
    /// to the foreground (the person may have changed Settings in between).
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true; defer { isRefreshing = false }
        let registry = platform.registry, catalog = platform.catalog, authority = platform.authority!
        let settings = platform.settings
        let grants = await platform.standingGrants()
        let installedRecords = Dictionary(uniqueKeysWithValues: (await platform.skillInstaller?.installed() ?? []).map { ($0.id, $0) })
        var out: [SkillInfo] = []
        for skill in catalog.skills {
            let specs = skill.toolNames.compactMap { registry.tool(named: $0)?.spec }
            var caps: [Capability] = []
            for s in specs where !caps.contains(s.capability) { caps.append(s.capability) }
            var worst: SkillPermission = .notRequired, detail = ""
            var seen = Set<SystemPermission>()
            for s in specs where s.systemPermission != .none && seen.insert(s.systemPermission).inserted {
                let state = await authority.status(s.systemPermission)
                let mapped = Self.map(state)
                if Self.severity(mapped) >= Self.severity(worst) {
                    worst = mapped
                    detail = PermissionReport.describe(system: s.systemPermission, state: state, on: true).0
                }
            }
            if specs.isEmpty { detail = "技能说明，无需系统权限" }
            else if worst == .notRequired { detail = "无需系统权限" }
            let blocked = caps.filter { !(settings.isOn($0)) }
            let tools = specs.map { s in
                let grant = grants.filter { $0.toolName == s.name }.map(\.scope).max()
                return SkillToolInfo(id: s.name, title: s.shortTitle, summary: s.description, risk: s.risk,
                                     asksBeforeRunning: s.permission == .confirmBeforeAction && grant == nil,
                                     maxScope: s.permission == .confirmBeforeAction ? ToolRiskTable.maxScope(for: s.risk) : .once,
                                     dataClass: s.dataClass, standingGrant: grant)
            }
            out.append(SkillInfo(id: skill.id, name: skill.name, summary: skill.summary, symbol: caps.first?.symbol ?? "sparkles",
                                 capabilities: caps, permission: worst, permissionDetail: detail, enabled: settings.isSkillOn(skill.id),
                                 tools: tools, limitations: skill.limitations, source: skill.trust == .builtIn ? .builtIn : .installed(skill.trust), blockedBy: blocked,
                                 version: skill.version, category: skill.category, author: skill.author, hosts: installedRecords[skill.id]?.approvedHosts ?? []))
        }
        // Installed skills that cannot run are still listed, with the reason, so the person can fix or remove them.
        for loaded in await platform.skillInstaller?.loadAll() ?? [] where loaded.status != .ready {
            let reason: String
            switch loaded.status {
            case .needsDependencies(let names): reason = "需要先具备这些工具：\(names.joined(separator: "、"))"
            case .broken(let why): reason = why
            case .ready: continue
            }
            out.append(SkillInfo(id: loaded.record.id, name: loaded.manifest?.name ?? loaded.record.id, summary: loaded.manifest?.summary ?? "", symbol: "exclamationmark.triangle",
                                 capabilities: [.thirdPartySkills], permission: .unavailable(reason), permissionDetail: reason, enabled: false, tools: [], limitations: "",
                                 source: .installed(loaded.record.trust), version: loaded.record.version, category: loaded.manifest?.category, author: loaded.manifest?.author,
                                 issue: reason, hosts: loaded.record.approvedHosts))
        }
        skills = out
    }

    /// Switch a whole skill off or on. Off = hidden from models and its tools refuse to run (even from a running conversation).
    func setEnabled(_ id: String, _ on: Bool) {
        platform.setSkillEnabled(id, on)
        if let i = skills.firstIndex(where: { $0.id == id }) { skills[i].enabled = on }
    }

    /// Shows the iOS permission prompt for a skill whose state is `.notDetermined` (no-op for anything iOS will not prompt for again).
    func requestPermission(for id: String) async {
        let registry = platform.registry
        guard let skill = platform.catalog.skill(id) else { return }
        let needed = Set(skill.toolNames.compactMap { registry.tool(named: $0)?.spec.systemPermission }.filter { $0 != .none })
        for p in needed.sorted(by: { $0.rawValue < $1.rawValue }) where await platform.authority.status(p) == .notDetermined {
            _ = await platform.authority.request(p)
        }
        await refresh()
    }

    /// Stops a standing approval: the tool asks again next time.
    func revokeStandingGrant(forTool toolId: String) async {
        for g in await platform.standingGrants() where g.toolName == toolId { await platform.revokeGrant(g.id) }
        await refresh()
    }

    // MARK: Installing skills from other people

    /// Reads and checks a skill without storing anything; the result is what the install sheet shows (hosts it can call, what changed, who signed it).
    func previewInstall(_ source: SkillInstallSource, markAsMine: Bool = false) async throws -> InstallPreview {
        guard let installer = platform.skillInstaller else { throw SkillPackageError.unreadable("技能安装暂不可用") }
        return try await installer.preview(source, markAsMine: markAsMine)
    }

    /// `approvedHosts` is what the person agreed to (it must cover every host the skill can call). `secrets` are API keys the skill asked for.
    func install(_ preview: InstallPreview, approvedHosts: Set<String>, secrets: [String: String] = [:]) async throws {
        guard let installer = platform.skillInstaller else { throw SkillPackageError.unreadable("技能安装暂不可用") }
        _ = try await installer.install(preview, approvedHosts: approvedHosts, secretValues: secrets)
        await platform.reloadInstalledSkills(); await refresh()
    }

    func removeInstalled(_ id: String) async throws {
        guard let installer = platform.skillInstaller else { return }
        try await installer.remove(id)
        for g in await platform.standingGrants() where g.toolName.hasPrefix("\(id)__") { await platform.revokeGrant(g.id) }
        platform.setSkillEnabled(id, true)
        await platform.reloadInstalledSkills(); await refresh()
    }

    func rollbackInstalled(_ id: String) async throws {
        _ = try await platform.skillInstaller?.rollback(id)
        await platform.reloadInstalledSkills(); await refresh()
    }

    func setSecret(skill: String, name: String, value: String) async throws {
        try await platform.skillInstaller?.setSecret(skill: skill, name: name, value: value)
    }

    /// Looks for newer versions at the places installed skills came from. Nothing is applied: the person reviews each result like a new install.
    func checkForUpdates() async -> [InstallPreview] {
        guard let installer = platform.skillInstaller else { return [] }
        var found: [InstallPreview] = []
        for r in await installer.installed() where r.sourceURL != nil { if let p = try? await installer.checkForUpdate(r.id) { found.append(p) } }
        return found
    }

    func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    /// Turns the iTalk-side privacy switches a skill depends on back on.
    func enableBlockedCapabilities(for id: String) {
        guard let s = skill(id) else { return }
        for c in s.blockedBy { platform.settings.set(c, true) }
        Task { await refresh() }
    }

    nonisolated static func map(_ s: PermissionState) -> SkillPermission {
        switch s {
        case .granted: .granted
        case .limited: .limited
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .unsupported(let why): .unavailable(why)
        case .unknownByDesign: .unknownByDesign
        }
    }

    nonisolated static func severity(_ p: SkillPermission) -> Int {
        switch p {
        case .notRequired: 0
        case .granted: 1
        case .unknownByDesign: 2
        case .limited: 3
        case .notDetermined: 4
        case .denied: 5
        case .restricted: 6
        case .unavailable: 7
        }
    }
}
