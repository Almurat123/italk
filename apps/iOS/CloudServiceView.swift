import SwiftUI
import AgentRuntime

/// Account, subscription and managed cloud models, driven entirely by AccountCenter. No hostnames, keys or developer controls.
/// Local features never need an account; this screen says so.
struct CloudServiceView: View {
    @Environment(AccountCenter.self) private var center
    @State private var showSignIn = false
    @State private var confirmSignOut = false
    @State private var period = PlanPeriod.monthly
    @State private var notice: String?

    static func statusText(_ availability: CloudAvailability) -> String {
        switch availability {
        case .notDeployed: "云端服务暂未开放"
        case .needsSignIn: "登录后使用云端服务"
        case .offline: "网络不可用"
        case .needsSubscription: "订阅后使用云端模型"
        case .available: "云端服务可用"
        case .serviceError: "云端服务暂时出错"
        }
    }

    var body: some View {
        List {
            accountSection
            switch center.availability {
            case .notDeployed:
                Section { Label("云端模型和订阅会在服务上线后开放。设备上的模型始终可以免费使用。", systemImage: "cloud.slash").font(.footnote).foregroundStyle(.secondary) }
                Section { NavigationLink { ModelCenterView() } label: { SettingsRow("使用设备端模型", "iphone") } }
            case .needsSignIn:
                Section { Label("登录后可使用云端模型。设备上的模型无需登录。", systemImage: "person.crop.circle").font(.footnote).foregroundStyle(.secondary) }
            case .offline:
                Section { Label("当前没有网络连接。设备上的模型仍可使用。", systemImage: "wifi.slash").foregroundStyle(.secondary) }
            case .serviceError(let why):
                Section { Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            case .needsSubscription, .available:
                subscriptionContent
            }
            if let notice { Section { Text(notice).font(.footnote).foregroundStyle(.orange) } }
        }
        .navigationTitle("账户").navigationBarTitleDisplayMode(.inline)
        .task { await center.refresh() }
        .refreshable { await center.refresh() }
        .sheet(isPresented: $showSignIn) { SignInSheet() }
        .confirmationDialog("退出登录后，云端模型将不可用；设备上的模型和数据不受影响。", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { center.signOut() }
        }
    }

    // MARK: Account

    @ViewBuilder private var accountSection: some View {
        Section {
            HStack(spacing: 14) {
                avatar
                VStack(alignment: .leading, spacing: 3) {
                    Text(center.profile?.displayName ?? center.profile?.email ?? "未登录").font(.headline)
                    Text(center.isSignedIn ? Self.statusText(center.availability) : "本机功能无需登录").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.vertical, 4)
            if let profile = center.profile {
                if let email = profile.email { LabeledContent("邮箱", value: email) }
                LabeledContent("登录方式", value: profile.method == .apple ? "通过 Apple" : "邮箱")
                LabeledContent("注册时间") { Text(profile.createdAt, style: .date) }
                Label("资料编辑暂未开放", systemImage: "person.text.rectangle").font(.footnote).foregroundStyle(.secondary)
                Button("退出登录", role: .destructive) { confirmSignOut = true }.accessibilityIdentifier("account.signOut")
            } else {
                Button { showSignIn = true } label: { Label("登录或注册", systemImage: "person.crop.circle.badge.plus") }
                    .accessibilityIdentifier("account.signIn")
            }
        }
    }

    private var avatar: some View {
        let initial = (center.profile?.displayName ?? center.profile?.email)?.first.map { String($0).uppercased() }
        return Group {
            if let initial {
                Text(initial).font(.title2.weight(.semibold)).foregroundStyle(.white).frame(width: 52, height: 52)
                    .background(Color.accentColor.gradient, in: Circle())
            } else {
                BrandAvatar(size: 52)
            }
        }
    }

    // MARK: Subscription and usage

    @ViewBuilder private var subscriptionContent: some View {
        Section("订阅") {
            let e = center.entitlement
            LabeledContent("当前方案", value: e.status == .active ? (e.tier ?? "已订阅") : e.status == .none ? "免费" : Self.status(e.status))
            if let renew = e.renewsAt { LabeledContent(e.cancelsAtPeriodEnd ? "到期" : "续订") { Text(renew, style: .date) } }
        }
        if !center.windows.isEmpty {
            Section {
                ForEach(center.windows) { window in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(window.title); Spacer(); Text("\(Int((window.fraction * 100).rounded()))% 已用").foregroundStyle(.secondary) }
                        ProgressView(value: window.fraction).tint(window.fraction > 0.9 ? .orange : .accentColor)
                        Text("剩余 \(Int(window.remaining)) · 重置于 \(window.resetsAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("用量额度") } footer: {
                Text("额度是你在每个周期内可以使用云端模型的总量，与单个模型一次能读取的内容长度（上下文窗口）是两回事。")
            }
        }
        if !center.cloudModels.isEmpty {
            Section("云端模型") {
                ForEach(center.cloudModels) { model in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(model.name)
                            Spacer()
                            HStack(spacing: 6) {
                                if model.supportsImages { Image(systemName: "photo") }
                                if model.supportsTools { Image(systemName: "wrench.and.screwdriver") }
                                if model.supportsReasoning { Image(systemName: "brain") }
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                        Text(model.available ? model.summary : (model.unavailableReason ?? "暂不可用")).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        let shown = center.plans.filter { $0.period == period }
        if !center.plans.isEmpty {
            Section {
                Picker("计费周期", selection: $period) { Text("按月").tag(PlanPeriod.monthly); Text("按年").tag(PlanPeriod.annual) }.pickerStyle(.segmented)
                ForEach(shown) { plan in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) { Text(plan.name); Text(plan.includedSummary).font(.footnote).foregroundStyle(.secondary) }
                        Spacer()
                        Button(plan.priceText) { Task { await purchase(plan) } }.buttonStyle(.bordered).controlSize(.small)
                            .disabled(center.purchaseBlockedReason != nil)
                    }
                }
            } header: { Text("订阅方案") } footer: { if let why = center.purchaseBlockedReason { Text(why) } }
        }
        if center.isDeveloperGateway { Section { Label("当前连接的是测试服务。", systemImage: "testtube.2").font(.footnote).foregroundStyle(.secondary) } }
    }

    private func purchase(_ plan: SubscriptionPlan) async {
        do { try await center.purchase(plan); notice = nil } catch { notice = error.localizedDescription }
    }

    private static func status(_ s: EntitlementStatus) -> String {
        switch s { case .none: "免费"; case .active: "已订阅"; case .gracePeriod: "宽限期"; case .billingRetry: "扣款重试中"; case .expired: "已过期"; case .revoked: "已撤销"; case .refunded: "已退款" }
    }
}
