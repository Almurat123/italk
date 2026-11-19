import Foundation
import AssistantCore

struct UsageRow: Decodable, Identifiable {
    var id: String; var status: String; var charged: Int; var inputTokens: Int; var outputTokens: Int; var model: String; var createdAt: Double
    var kind: String?; var characters: Int?; var reserved: Int?
}
struct GatewayAccount: Decodable {
    var id: String; var appAccountToken: UUID; var balance: Int; var available: Int
    var products: [String] = []; var usage: [UsageRow] = []
    var rates: GatewayRates?
    var voice: GatewayVoiceInfo?
    var model: String?
    var modelConfigured: Bool?
    var supportsImages: Bool?
    var maxOutputTokens: Int?
    var models: [GatewayCloudModel]?
}
struct GatewayCloudModel: Decodable, Identifiable, Equatable {
    var id: String
    var name: String
    var available: Bool
    var supportsImages: Bool
    var note: String
}
struct GatewayVoiceInfo: Decodable { var configured: Bool; var model: String?; var characters: Int? }
struct GatewayRates: Decodable { var input: Int; var output: Int; var search: Int }
struct ResearchSource: Identifiable {
    var id: String { url.absoluteString }
    var title: String
    var url: URL
}
struct GatewayEvent: Decodable {
    var type: String; var text: String?; var error: String?; var charged: Int?; var title: String?; var url: String?; var turnId: UUID?
    var emotion: VoiceEmotion?
}

@MainActor final class GatewayClient {
    private var active: URLSession?
    private func request(endpoint: String, path: String, token: String) throws -> URLRequest {
        guard let base = URL(string: endpoint), base.scheme == "https", base.host != nil, base.user == nil, base.password == nil, base.query == nil, base.fragment == nil, !token.isEmpty else { throw AppFailure.message("请配置 HTTPS 网关地址及个人访问凭证。") }
        var request = URLRequest(url: base.appending(path: path))
        request.timeoutInterval = 25
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    func cancel() { active?.invalidateAndCancel(); active = nil }
    func respond(endpoint: String, token: String, turn: UUID, text: String, healthConsent: Bool, research: Bool, images: [ImageAttachment] = [], imageConsent: Bool = false, onText: @escaping (String) -> Void, onSource: @escaping (ResearchSource) -> Void, onDelivery: @escaping (VoiceEmotion) -> Void = { _ in }) async throws -> String {
        var request = try request(endpoint: endpoint, path: "v1/turns", token: token)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["turnId": turn.uuidString, "text": text, "locale": "zh-CN", "cloudConsent": true, "healthConsent": healthConsent, "research": research, "imageConsent": imageConsent, "images": images.map { ["mimeType": "image/jpeg", "data": $0.data.base64EncodedString()] }])
        let configuration = URLSessionConfiguration.ephemeral; configuration.urlCache = nil
        let session = URLSession(configuration: configuration); active = session
        defer { session.finishTasksAndInvalidate(); if active === session { active = nil } }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            if (response as? HTTPURLResponse)?.statusCode == 402 { throw AppFailure.message("可用额度不足，请查看余额与用量。") }
            throw AppFailure.message("网关请求未完成，请检查配置、授权和服务状态。")
        }
        var answer = "", completed = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.utf8.count <= 65536 else { throw AppFailure.message("服务返回内容过大。") }
            let event = try JSONDecoder().decode(GatewayEvent.self, from: Data(line.utf8))
            guard event.turnId == nil || event.turnId == turn else { continue }
            if event.type == "error" { throw AppFailure.message("服务未完成本次回答（\(event.error ?? "unknown")）。") }
            if event.type == "delta", let text = event.text {
                answer += text
                guard answer.count <= 16000 else { throw AppFailure.message("回答超出长度限制。") }
                onText(answer)
            }
            if event.type == "completed" { completed = true }
            if event.type == "delivery", let emotion = event.emotion { onDelivery(emotion) }
            if event.type == "source", let value = event.url, value.count < 2048, let url = URL(string: value), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil {
                onSource(ResearchSource(title: event.title?.isEmpty == false ? event.title! : url.host!, url: url))
            }
        }
        guard completed, !answer.isEmpty else { throw AppFailure.message("回答中断，未收到完成确认。") }
        return answer
    }
    func account(endpoint: String, token: String) async throws -> GatewayAccount {
        let request = try request(endpoint: endpoint, path: "v1/account", token: token)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 262144 else { throw AppFailure.message("无法读取账户，请检查网关凭证。") }
        return try JSONDecoder().decode(GatewayAccount.self, from: data)
    }
    func synthesize(endpoint: String, token: String, text: String, emotion: VoiceEmotion, healthConsent: Bool) async throws -> Data {
        guard !text.isEmpty, text.utf16.count <= 2000 else { throw AppFailure.message("这条回答较长，请先查看文字内容。") }
        var request = try request(endpoint: endpoint, path: "v1/speech", token: token)
        request.httpMethod = "POST"; request.timeoutInterval = 50
        request.httpBody = try JSONSerialization.data(withJSONObject: ["requestId": UUID().uuidString, "text": text,
            "emotion": emotion.rawValue, "voiceConsent": true, "healthConsent": healthConsent])
        let configuration = URLSessionConfiguration.ephemeral; configuration.urlCache = nil
        let session = URLSession(configuration: configuration); active = session
        defer { session.finishTasksAndInvalidate(); if active === session { active = nil } }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            switch (response as? HTTPURLResponse)?.statusCode {
            case 402: throw AppFailure.message("情绪语音额度不足，请查看余额。")
            case 403: throw AppFailure.message("情绪语音或相关内容尚未获准发送。请检查授权。")
            case 503: throw AppFailure.message("情绪语音服务尚未配置。文字回答已保留。")
            default: throw AppFailure.message("情绪语音未完成，文字回答已保留。")
            }
        }
        guard http.mimeType == "audio/mpeg", http.expectedContentLength <= 8_000_000 else { throw AppFailure.message("语音响应格式不支持。") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 8_000_000 else { throw AppFailure.message("语音内容过大。") }
            data.append(byte)
        }
        guard data.count >= 4 else { throw AppFailure.message("未收到可播放的语音。") }
        return data
    }
    func submitPurchase(endpoint: String, token: String, jws: String) async throws {
        var request = try request(endpoint: endpoint, path: "v1/store/purchases", token: token)
        request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: ["signedTransaction": jws])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppFailure.message("购买尚未完成服务端验证，交易将保留以便重试。") }
    }
}
