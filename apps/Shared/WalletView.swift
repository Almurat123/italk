import SwiftUI
import StoreKit

struct WalletView: View {
    @Environment(AppModel.self) private var model
    @State private var products: [Product] = []
    @State private var purchasing = false
    @State private var notice: String?
    var body: some View {
        List {
            Section("账户额度") {
                if let account = model.account {
                    if let name = account.model { LabeledContent("云端模型", value: name) }
                    LabeledContent("余额", value: credits(account.balance))
                    LabeledContent("可用额度", value: credits(account.available))
                    Text("额度按实际调用用量扣除，调用前会暂时预占上限。最终计费以服务端账本为准。").font(.caption).foregroundStyle(.secondary)
                    if account.usage.contains(where: { $0.status == "uncertain" }) {
                        Text("有一笔调用中断，预留额度正在等待核对；完成核对后才会结算或释放。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let rates = account.rates {
                        LabeledContent("每百万输入 token", value: credits(rates.input))
                        LabeledContent("每百万输出 token", value: credits(rates.output))
                        LabeledContent("每次联网搜索", value: credits(rates.search))
                        Text("以上费率由 iTalk 服务提供，并以服务端账本为准。").font(.caption).foregroundStyle(.secondary)
                    }
                    if let voice = account.voice, let rate = voice.characters {
                        LabeledContent("每百万语音字符", value: credits(rate))
                        if !voice.configured { Text("情绪语音尚未连接或未获账户授权。").font(.caption).foregroundStyle(.secondary) }
                    }
                } else { Text("服务未连接或账户信息暂不可用。连接后可查看余额与用量。").foregroundStyle(.secondary) }
                Button("刷新账户") { Task { await refresh() } }
            }
            Section("充值") {
                ForEach(products, id: \.id) { product in
                    Button { Task { await purchase(product) } } label: {
                        HStack { Text(product.displayName); Spacer(); Text(product.displayPrice) }
                    }.disabled(purchasing)
                }
                if products.isEmpty { Text("充值商品尚未配置或当前不可购买。").foregroundStyle(.secondary) }
                Button("重试待验证的购买") { Task { await retryUnfinished() } }.disabled(purchasing)
                Text("只有 Apple 验证通过且后端确认到账后，交易才会完成。客户端不能自行增加余额。").font(.caption).foregroundStyle(.secondary)
            }
            if let notice { Section { Text(notice).foregroundStyle(.secondary) } }
            if let message = model.message { Section { Text(message).foregroundStyle(.secondary) } }
            Section("最近用量") {
                ForEach(model.account?.usage ?? []) { usage in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(usage.model); Spacer(); Text(usage.status == "uncertain" ? "待核对" : credits(usage.charged)) }
                        if usage.status == "uncertain", let reserved = usage.reserved {
                            Text("预留 \(credits(reserved)) · 尚未扣除").font(.caption).foregroundStyle(.secondary)
                        }
                        if usage.kind == "voice" {
                            Text("语音 \(usage.characters ?? 0) 字符 · \(usageStatus(usage.status))").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("输入 \(usage.inputTokens) · 输出 \(usage.outputTokens) · \(usageStatus(usage.status))").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(Date(timeIntervalSince1970: usage.createdAt / 1000), format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("账户与用量")
        .task { await refresh() }
    }
    private func credits(_ value: Int) -> String { String(format: "%.4f 额度", Double(value) / 1_000_000) }
    private func usageStatus(_ status: String) -> String {
        switch status {
        case "pending": "处理中"
        case "uncertain": "等待核对"
        case "completed": "已完成"
        case "failed", "interrupted": "未完成"
        case "reconciled_void": "已释放"
        default: status
        }
    }
    private func refresh() async {
        await model.refreshAccount()
        guard let account = model.account else { return }
        do { products = try await Product.products(for: account.products).sorted { $0.price < $1.price } }
        catch { notice = "无法获取 App Store 商品。" }
    }
    private func purchase(_ product: Product) async {
        guard let account = model.account, !purchasing else { return }
        purchasing = true; defer { purchasing = false }
        do {
            let result = try await product.purchase(options: [.appAccountToken(account.appAccountToken)])
            switch result {
            case .success(let verification): try await deliver(verification)
            case .pending: notice = "购买正在等待批准。"
            case .userCancelled: break
            @unknown default: notice = "购买状态暂不可用。"
            }
        } catch { notice = error.localizedDescription }
        await refresh()
    }
    private func deliver(_ verification: VerificationResult<StoreKit.Transaction>) async throws {
        guard case .verified(let transaction) = verification else { throw AppFailure.message("Apple 购买验证未通过。") }
        try await model.gateway.submitPurchase(endpoint: model.archive.preferences.endpoint, token: model.token, jws: verification.jwsRepresentation)
        await transaction.finish(); notice = "购买已验证，额度已更新。"
    }
    private func retryUnfinished() async {
        purchasing = true; defer { purchasing = false }
        for await transaction in StoreKit.Transaction.unfinished {
            do { try await deliver(transaction) } catch { notice = error.localizedDescription; return }
        }
        await refresh()
    }
}
