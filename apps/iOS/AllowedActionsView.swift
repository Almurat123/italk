import SwiftUI
import AgentRuntime

/// What the person has allowed to keep happening, plus a digest-only activity log. Data comes from AgentPlatform / the approval policy.
struct AllowedActionsView: View {
    @State private var platform = AgentPlatform.shared
    @State private var grants: [ApprovalGrant] = []
    @State private var activity: [AuditRecord] = []
    @State private var confirmRevokeAll = false

    var body: some View {
        List {
            Section {
                if grants.isEmpty { Text("没有长期允许的操作。每次敏感操作都会先询问你。").font(.footnote).foregroundStyle(.secondary) }
                ForEach(grants) { grant in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(grant.summary)
                            Text(grant.scope.title).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("撤销", role: .destructive) { Task { await platform.revokeGrant(grant.id); await load() } }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                if !grants.isEmpty { Button("撤销全部", role: .destructive) { confirmRevokeAll = true } }
            } header: { Text("已允许") }
            Section {
                if activity.isEmpty { Text("还没有记录。").font(.footnote).foregroundStyle(.secondary) }
                ForEach(Array(activity.enumerated()), id: \.offset) { _, record in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.tool).font(.subheadline.monospaced())
                            Text(Self.outcome(record.outcome) + (record.tainted ? " · 读取过不可信内容" : "")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(record.time, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !activity.isEmpty { Button("清空记录", role: .destructive) { Task { await platform.clearActivityLog(); await load() } } }
            } header: { Text("最近操作") } footer: { Text("只记录工具名称和结果，不保存具体内容。") }
        }
        .navigationTitle("已允许的操作").navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .confirmationDialog("撤销所有长期允许？", isPresented: $confirmRevokeAll, titleVisibility: .visible) {
            Button("撤销全部", role: .destructive) { Task { await platform.revokeAllGrants(); await load() } }
        }
    }

    private func load() async { grants = await platform.standingGrants(); activity = await platform.recentActivity(limit: 50) }

    static func outcome(_ o: AuditRecord.Outcome) -> String {
        switch o {
        case .autoAllowed: "自动允许"; case .grantAllowed: "按已允许规则执行"; case .userApproved: "你已允许"; case .userDeclined: "你已拒绝"; case .expired: "已过期"
        case .blockedByPermission: "缺少权限"; case .blockedBySkillSwitch: "技能已关闭"; case .executed: "已执行"; case .failed: "失败"; case .outcomeUnknown: "结果未知"
        }
    }
}
