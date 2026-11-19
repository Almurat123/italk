import Testing
import Foundation
import CryptoKit
import AgentRuntime
@testable import RemoteAgent

@Suite struct RemoteTaskRequestTests {
    @Test func personalMemoryIsAbsentUnlessExplicitlyProvided() throws {
        let encoder = JSONEncoder()
        let normal = try #require(JSONSerialization.jsonObject(with: encoder.encode(NewRemoteTask(prompt: "hello"))) as? [String: Any])
        #expect(normal["sharedMemory"] == nil)
        let shared = try #require(JSONSerialization.jsonObject(with: encoder.encode(NewRemoteTask(prompt: "hello", sharedMemory: ["short answers"]))) as? [String: Any])
        #expect(shared["sharedMemory"] as? [String] == ["short answers"])
    }
}

@Suite struct PairingLinkTests {
    // Values produced by the Mac agent (remote/agent/src/identity.mjs) for the same keys: both sides must show the same codes.
    @Test func identityCodesMatchTheMacAgent() {
        #expect(RemoteIdentity.deviceId(for: Data(repeating: 1, count: 32)) == "olgw5bbcyqd7w3ij")
        #expect(RemoteIdentity.fingerprint(of: Data(repeating: 1, count: 32)) == "72CD-6E84-22C4")
        let sequential = Data((0..<32).map { UInt8($0) })
        #expect(RemoteIdentity.deviceId(for: sequential) == "mmg42klgyqzwneis")
        #expect(RemoteIdentity.fingerprint(of: sequential) == "630D-CD29-66C4")
        #expect(sequential.base64URLString == "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
    }

    private let good = "italk-pair://v1?k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&p=\(String(repeating: "P", count: 43))&i=AYRfIILjyBQD5ppXyhuztA&s=d9BgTw2jpFrFY7uDODkF7g&n=Almurat%27s%20MacBook%20Pro&e=Almurats-MacBook-Pro.local%3A47321&e=192.168.3.32%3A47321"

    @Test func parsesWhatTheComputerShows() throws {
        let link = try RemotePairingLink(parsing: "  \(good)\n")
        #expect(link.name == "Almurat's MacBook Pro")
        #expect(link.endpoints == ["Almurats-MacBook-Pro.local:47321", "192.168.3.32:47321"])
        #expect(link.agentId == "mmg42klgyqzwneis")
        #expect(link.fingerprint == "630D-CD29-66C4")
        #expect(link.pairingId == "AYRfIILjyBQD5ppXyhuztA")
    }

    @Test func rejectsAnythingElse() {
        #expect(throws: RemotePairingLink.ParseError.notAPairingLink) { try RemotePairingLink(parsing: "https://example.com/?k=1") }
        #expect(throws: RemotePairingLink.ParseError.notAPairingLink) { try RemotePairingLink(parsing: "hello") }
        #expect(throws: RemotePairingLink.ParseError.unsupportedVersion) { try RemotePairingLink(parsing: good.replacingOccurrences(of: "//v1", with: "//v9")) }
        #expect(throws: RemotePairingLink.ParseError.malformed) { try RemotePairingLink(parsing: good.replacingOccurrences(of: "k=AAEC", with: "k=AA")) }
        #expect(throws: RemotePairingLink.ParseError.malformed) { try RemotePairingLink(parsing: "italk-pair://v1?k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&p=short&i=a&s=b&e=h%3A1") }
        #expect(throws: RemotePairingLink.ParseError.malformed) { try RemotePairingLink(parsing: good.replacingOccurrences(of: "&e=Almurats-MacBook-Pro.local%3A47321&e=192.168.3.32%3A47321", with: "")) }
        // an endpoint that smuggles a path is dropped
        #expect(throws: RemotePairingLink.ParseError.malformed) { try RemotePairingLink(parsing: good.replacingOccurrences(of: "&e=Almurats-MacBook-Pro.local%3A47321&e=192.168.3.32%3A47321", with: "&e=evil.example%2Fx%3A1")) }
    }

    @Test func phoneIdentityPersistsAndSigns() throws {
        let store = InMemorySecretStore()
        let a = try PhoneIdentity.loadOrCreate(in: store), b = try PhoneIdentity.loadOrCreate(in: store)
        #expect(a.publicKey == b.publicKey); #expect(a.deviceId == b.deviceId); #expect(a.fingerprint.count == 14)
        let message = Data("hello".utf8)
        let signature = try a.sign(message)
        #expect(try Curve25519.Signing.PublicKey(rawRepresentation: a.publicKey).isValidSignature(signature, for: message))
        #expect(try PhoneIdentity.loadOrCreate(in: InMemorySecretStore()).publicKey != a.publicKey)
    }
}

@Suite struct SSEParserTests {
    private func parse(_ text: String) -> [SSEParser.Event] { var p = SSEParser(); return text.utf8.compactMap { p.feed($0) } }

    @Test func blankLinesSeparateEventsAndCommentsAreIgnored() {
        let events = parse(": ok\n\nid: 1\nevent: text\ndata: {\"text\":\"a\"}\n\n: keep-alive\n\nid: 2\nevent: completed\ndata: {}\n\n")
        #expect(events.map(\.id) == [1, 2]); #expect(events.map(\.name) == ["text", "completed"]); #expect(events[0].data == "{\"text\":\"a\"}")
    }
    @Test func handlesCRLFAndMultilineData() {
        let events = parse("id: 7\r\nevent: x\r\ndata: a\r\ndata: b\r\n\r\n")
        #expect(events.count == 1); #expect(events[0].data == "a\nb"); #expect(events[0].id == 7)
    }
    @Test func splitAcrossChunksGivesTheSameResult() {
        let text = "id: 3\nevent: reasoning\ndata: {\"text\":\"héllo 你好\"}\n\n"
        var p = SSEParser(); var out: [SSEParser.Event] = []
        for byte in text.utf8 { if let e = p.feed(byte) { out.append(e) } }
        #expect(out.count == 1); #expect(out[0].data.contains("你好"))
    }
}

@Suite struct TranscriptTests {
    private func event(_ seq: Int, _ type: String, _ json: String) -> RemoteEvent { RemoteEvent(seq: seq, type: type, data: try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))) }

    @Test func buildsAChronologicalViewAndIgnoresRepeats() {
        var t = RemoteTranscript()
        let events = [
            event(1, "started", "{}"), event(2, "reasoning", "{\"text\":\"think \"}"), event(3, "reasoning", "{\"text\":\"more\"}"), event(4, "text", "{\"text\":\"Let me look. \"}"),
            event(5, "tool_call", "{\"id\":\"c1\",\"name\":\"read_file\",\"summary\":\"Read a.txt\",\"risk\":\"read\"}"), event(6, "tool_result", "{\"id\":\"c1\",\"ok\":true,\"preview\":\"3 lines\"}"),
            event(7, "approval_requested", "{\"approvalId\":\"a1\",\"tool\":\"write_file\",\"summary\":\"Write b.txt\",\"risk\":\"modify\",\"scopes\":[\"once\",\"task\"],\"tainted\":false,\"expiresAt\":4102444800000}"),
            event(8, "approval_resolved", "{\"approvalId\":\"a1\",\"outcome\":\"approved\",\"scope\":\"once\"}"),
            event(9, "text", "{\"text\":\"Done.\"}"), event(10, "usage", "{\"inputTokens\":10,\"outputTokens\":4}"), event(11, "completed", "{}"),
        ]
        for e in events { t.apply(e) }
        for e in events { t.apply(e) }                     // replaying the same events changes nothing
        #expect(t.answer == "Let me look. Done."); #expect(t.reasoning == "think more")
        #expect(t.items == [.reasoning("think more"), .text("Let me look. "), .step("c1"), .approval("a1"), .text("Done.")])
        #expect(t.steps["c1"]?.state == .succeeded); #expect(t.steps["c1"]?.risk == .read); #expect(t.steps["c1"]?.preview == "3 lines")
        #expect(t.approvals["a1"]?.state == .approved); #expect(t.pendingApproval == nil)
        #expect(t.inputTokens == 10 && t.outputTokens == 4); #expect(t.phase == .completed); #expect(t.lastSeq == 11)
    }

    @Test func pendingApprovalAndFailure() {
        var t = RemoteTranscript()
        t.apply(event(1, "approval_requested", "{\"approvalId\":\"a1\",\"tool\":\"run_command\",\"summary\":\"Run: rm x\",\"risk\":\"sensitive\",\"scopes\":[\"once\"],\"tainted\":true,\"expiresAt\":4102444800000}"))
        #expect(t.pendingApproval?.risk == .sensitive); #expect(t.pendingApproval?.tainted == true); #expect(!t.isFinished)
        t.apply(event(2, "failed", "{\"code\":\"interrupted\",\"message\":\"The agent restarted.\"}"))
        #expect(t.phase == .failed(code: "interrupted", message: "The agent restarted.")); #expect(t.isFinished)
    }
}
