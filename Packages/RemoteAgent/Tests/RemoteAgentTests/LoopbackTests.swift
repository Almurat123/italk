import Testing
import Foundation
import AgentRuntime
@testable import RemoteAgent

// These tests start the real Mac agent (remote/agent) and a scripted stand-in for the iTalk gateway as separate processes and talk to them with the real client:
// pinned TLS, QR pairing, signed requests, durable task streams, approvals, cancel, revocation.

private let repoRoot: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let nodePath: String? = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) }
    ?? ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map { "\($0)/node" }.first { FileManager.default.isExecutableFile(atPath: $0) }

final class Child: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var text = ""
    init(node: String, args: [String], environment: [String: String] = [:]) throws {
        process.executableURL = URL(fileURLWithPath: node); process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData; guard !d.isEmpty, let self else { return }
            self.lock.withLock { self.text += String(decoding: d, as: UTF8.self) }
        }
        try process.run()
    }
    var output: String { lock.withLock { text } }
    func waitForLine(containing needle: String, timeout: TimeInterval = 20) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let line = output.split(separator: "\n").first(where: { $0.contains(needle) }) { return String(line) }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "Child", code: 1, userInfo: [NSLocalizedDescriptionKey: "timed out waiting for \(needle). Output:\n\(output)"])
    }
    func stop() { if process.isRunning { process.terminate(); process.waitUntilExit() } }
}

private struct Harness {
    let agent: Child, model: Child, root: URL, workspace: URL, link: String, port: Int, gateway: String
    static func start(maxMode: String = "ask", withAccess: Bool = true) async throws -> Harness {
        let node = nodePath!
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ra-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        let state = root.appendingPathComponent("s"), home = root.appendingPathComponent("home"), workspace = home.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let agentDir = repoRoot.appendingPathComponent("remote/agent")
        let model = try Child(node: node, args: [agentDir.appendingPathComponent("fixtures/fake-gateway.mjs").path])
        let url = try JSONSerialization.jsonObject(with: Data(try await model.waitForLine(containing: "\"url\"").utf8)) as! [String: String]
        let config: [String: Any] = ["name": "Swift Test Mac", "roots": [home.path], "maxPermissionMode": maxMode, "approvalTimeoutMinutes": 1]
        try JSONSerialization.data(withJSONObject: config).write(to: state.appendingPathComponent("config.json"))
        // What the phone's credential hand-over leaves on disk when there is no login keychain (the test process has none).
        if withAccess {
            let access: [String: Any] = ["gateway": url["url"]!, "issuedAt": Date().timeIntervalSince1970 * 1000, "accountHint": "tester", "stored": "file"]
            try JSONSerialization.data(withJSONObject: access).write(to: state.appendingPathComponent("cloud.json"))
            try Data("test-credential-0123456789abcdef\n".utf8).write(to: state.appendingPathComponent("cloud.secret"))
        }
        let agent = try Child(node: node, args: ["--disable-warning=ExperimentalWarning", agentDir.appendingPathComponent("bin/italk-agent.mjs").path, "run", "--state-dir", state.path, "--port", "0", "--no-bonjour", "--json", "--insecure-auto-approve-pairing"],
                              environment: ["ITALK_AGENT_INSECURE_TEST": "1", "HOME": home.path])
        let ready = try JSONSerialization.jsonObject(with: Data(try await agent.waitForLine(containing: "\"ready\":true").utf8)) as! [String: Any]
        return Harness(agent: agent, model: model, root: root, workspace: workspace, link: ready["pairingLink"] as! String, port: ready["port"] as! Int, gateway: url["url"]!)
    }
    func stop() { agent.stop(); model.stop(); try? FileManager.default.removeItem(at: root) }
}

private func drain(_ stream: AsyncThrowingStream<RemoteEvent, Error>, into transcript: inout RemoteTranscript, until stop: ((RemoteEvent) -> Bool)? = nil) async throws -> [RemoteEvent] {
    var seen: [RemoteEvent] = []
    for try await e in stream { seen.append(e); transcript.apply(e); if stop?(e) == true { break } }
    return seen
}

@Suite(.serialized, .enabled(if: nodePath != nil, "node is not installed")) struct LoopbackTests {
    @Test func pairingSkipsDeadEndpointWithoutConsumingTheCode() async throws {
        let h = try await Harness.start(); defer { h.stop() }
        var components = try #require(URLComponents(string: h.link))
        components.queryItems?.insert(URLQueryItem(name: "e", value: "127.0.0.1:1"), at: 0)
        let link = try RemotePairingLink(parsing: try #require(components.string))
        let identity = try PhoneIdentity.loadOrCreate(in: InMemorySecretStore())
        let started = Date()
        let record = try await RemotePairing.pair(link: link, identity: identity, phoneName: "Endpoint test")
        #expect(record.id == link.agentId)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func pairingTimesOutAnEndpointThatAcceptsButNeverResponds() async throws {
        let h = try await Harness.start(); defer { h.stop() }
        let stall = try Child(node: try #require(nodePath), args: ["-e", "require('net').createServer(() => {}).listen(0, '127.0.0.1', function () { console.log(JSON.stringify({port:this.address().port})) })"])
        defer { stall.stop() }
        let result = try #require(try JSONSerialization.jsonObject(with: Data(try await stall.waitForLine(containing: "\"port\"").utf8)) as? [String: Int])
        var components = try #require(URLComponents(string: h.link))
        components.queryItems?.insert(URLQueryItem(name: "e", value: "127.0.0.1:\(try #require(result["port"]))"), at: 0)
        let link = try RemotePairingLink(parsing: try #require(components.string))
        let identity = try PhoneIdentity.loadOrCreate(in: InMemorySecretStore())
        let started = Date()
        let record = try await RemotePairing.pair(link: link, identity: identity, phoneName: "Timeout test")
        #expect(record.id == link.agentId)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func pairsRunsTasksApprovesCancelsAndRevokes() async throws {
        let h = try await Harness.start(); defer { h.stop() }
        let identity = try PhoneIdentity.loadOrCreate(in: InMemorySecretStore())

        // Pairing: the computer proves it is the one from the QR code; the code works once.
        let link = try RemotePairingLink(parsing: h.link)
        let record = try await RemotePairing.pair(link: link, identity: identity, phoneName: "Swift Test iPhone")
        #expect(record.id == link.agentId); #expect(record.name == "Swift Test Mac"); #expect(record.fingerprint == link.fingerprint)
        do { _ = try await RemotePairing.pair(link: link, identity: identity, phoneName: "again"); Issue.record("a pairing code must only work once") }
        catch let e as PairingError { #expect(e.failure == .expired) }

        let client = RemoteAgentClient(record: record, identity: identity)
        let hello = try await client.hello(); #expect(hello.agent.id == record.id)
        let status = try await client.status()
        #expect(status.agent.name == "Swift Test Mac"); #expect(status.backends.first?.available == true); #expect(status.limits.maxPermissionMode == "ask")

        // A plain task: streamed answer + reasoning, idempotent submission.
        let first = try await client.createTask(NewRemoteTask(backend: "italk", prompt: "hi"), idempotencyKey: "swift-key-0001")
        #expect(try await client.createTask(NewRemoteTask(backend: "italk", prompt: "hi"), idempotencyKey: "swift-key-0001").id == first.id)
        do { _ = try await client.createTask(NewRemoteTask(backend: "italk", prompt: "different"), idempotencyKey: "swift-key-0001"); Issue.record("expected a conflict") }
        catch let e as RemoteError { #expect(e == .http(status: 409, code: "idempotency_conflict")) }
        var t1 = RemoteTranscript()
        _ = try await drain(client.events(taskId: first.id), into: &t1)
        #expect(t1.answer == "Hello from the Mac."); #expect(t1.reasoning == "thinking about the greeting"); #expect(t1.phase == .completed)

        // Resume: stop reading half-way, come back later, nothing is repeated or missing.
        let second = try await client.createTask(NewRemoteTask(backend: "italk", prompt: "SLOW please"), idempotencyKey: "swift-key-0002")
        var partial = RemoteTranscript()
        let early = try await drain(client.events(taskId: second.id), into: &partial, until: { $0.type == "text" })
        try await Task.sleep(for: .seconds(1.2))                       // the phone is "away"; the task keeps running on the Mac
        var resumed = partial
        let rest = try await drain(client.events(taskId: second.id, after: partial.lastSeq), into: &resumed)
        #expect((early + rest).map(\.seq) == Array(1...(early + rest).count)); #expect(resumed.phase == .completed)
        var whole = RemoteTranscript(); _ = try await drain(client.events(taskId: second.id), into: &whole)
        #expect(whole.answer == resumed.answer); #expect(whole.answer.hasPrefix("part1 part2")); #expect(whole.answer.contains("part12"))

        // An edit needs the person: nothing is written until they approve on the phone.
        let target = h.workspace.appendingPathComponent("out.txt")
        let third = try await client.createTask(NewRemoteTask(backend: "italk", prompt: "WRITE:\(target.path)", cwd: h.workspace.path, permissionMode: "ask"), idempotencyKey: "swift-key-0003")
        var t3 = RemoteTranscript()
        _ = try await drain(client.events(taskId: third.id), into: &t3, until: { $0.type == "approval_requested" })
        let pending = try #require(t3.pendingApproval)
        #expect(pending.tool == "write_file"); #expect(pending.risk == .modify); #expect(pending.scopes == ["once", "task"])
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try await client.approvals().map(\.id) == [pending.id])
        try await client.resolveApproval(id: pending.id, approve: true)
        _ = try await drain(client.events(taskId: third.id, after: t3.lastSeq), into: &t3)
        #expect(t3.phase == .completed); #expect(try String(contentsOf: target, encoding: .utf8) == "written by the agent\n"); #expect(t3.answer.hasPrefix("Tool said:"))
        #expect(try await client.approvals().isEmpty)

        // Cancel.
        let fourth = try await client.createTask(NewRemoteTask(backend: "italk", prompt: "SLOW again"), idempotencyKey: "swift-key-0004")
        var t4 = RemoteTranscript()
        _ = try await drain(client.events(taskId: fourth.id), into: &t4, until: { $0.type == "text" })
        _ = try await client.cancel(taskId: fourth.id)
        _ = try await drain(client.events(taskId: fourth.id, after: t4.lastSeq), into: &t4)
        #expect(t4.phase == .cancelled)

        // History lives on the Mac.
        let listed = try await client.tasks()
        #expect(listed.count == 4); #expect(listed.contains { $0.id == third.id && $0.state == "completed" })
        let folders = try await client.folders(path: h.workspace.deletingLastPathComponent().path); #expect(folders.folders == ["work"])

        // Revocation from the phone: the computer stops accepting this phone at once.
        try await client.unpair()
        do { _ = try await client.status(); Issue.record("a removed phone must be refused") } catch let e as RemoteError { #expect(e == .revoked) }
    }

    @Test func theComputerGetsModelAccessFromThePhoneAndTellsWhatItCanDo() async throws {
        let h = try await Harness.start(withAccess: false); defer { h.stop() }
        let identity = try PhoneIdentity.loadOrCreate(in: InMemorySecretStore())
        let record = try await RemotePairing.pair(link: RemotePairingLink(parsing: h.link), identity: identity, phoneName: "Swift Test iPhone")
        let client = RemoteAgentClient(record: record, identity: identity)

        // The cloud backend stays unconfigured even if this Mac has an independently available local model.
        let before = try await client.status()
        #expect(before.backends.map(\.id).contains("ollama")); #expect(before.backends[0].id == "italk"); #expect(before.backends[0].available == false); #expect(before.backends[0].detail == "cloud_not_configured")
        #expect(try await client.cloud().cloud.configured == false)

        let token = "swift-session-0123456789ABCDEFGHIJKLMN"
        let state = try await client.provisionCloud(gateway: h.gateway, token: token, expiresAt: nil, accountHint: "t***@example.com", sessionName: "Mac · Swift")
        #expect(state.cloud.configured); #expect(state.cloud.gateway == h.gateway); #expect(state.verification?.ok == true)
        #expect(state.verification?.models?.map(\.id) == ["fake-model"]); #expect(state.verification?.subscription?.status == "active")
        let after = try await client.status()
        #expect(after.backends[0].available); #expect(after.backends[0].defaultModel == "fake-model"); #expect(after.backends[0].modelInfo?.first?.name == "Fake")
        #expect(try await client.verifyCloud().verification?.ok == true)

        // Discovery: tools with their risk, skills, and the project's own instructions.
        try "Always say hello first.".write(to: h.workspace.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let caps = try await client.capabilities(cwd: h.workspace.path)
        #expect(caps.tools.first { $0.name == "write_file" }?.risk == "modify"); #expect(caps.tools.contains { $0.name == "todo" }); #expect(caps.tools.contains { $0.name == "web_fetch" })
        #expect(caps.skills.contains { $0.name == "organize-folder" && $0.source == "bundled" }); #expect(caps.instructions?.file == "AGENTS.md")

        // A plan and a question travel through the event log and the phone answers it.
        let task = try await client.createTask(NewRemoteTask(prompt: "ASK me", cwd: h.workspace.path), idempotencyKey: "swift-ask-0001")
        var t = RemoteTranscript()
        _ = try await drain(client.events(taskId: task.id), into: &t, until: { $0.type == "question_requested" })
        #expect(t.plan.map(\.status) == ["in_progress", "pending"])
        let q = try #require(t.pendingQuestion); #expect(q.text == "Which folder?"); #expect(q.choices == ["Downloads", "Desktop"])
        try await client.answer(questionId: q.id, text: "Downloads")
        _ = try await drain(client.events(taskId: task.id, after: t.lastSeq), into: &t)
        #expect(t.phase == .completed); #expect(t.pendingQuestion == nil); #expect(t.answer.contains("The person answered: Downloads"))

        // Taking the access away again leaves nothing to run on.
        try await client.clearCloud()
        #expect(try await client.status().backends[0].available == false)
    }

    @Test func refusesAComputerThatIsNotTheOneInTheCode() async throws {
        let h = try await Harness.start(); defer { h.stop() }
        let identity = try PhoneIdentity.loadOrCreate(in: InMemorySecretStore())
        // Wrong certificate pin (as if another device answered at that address).
        var c = URLComponents(string: h.link)!
        c.queryItems = c.queryItems!.map { $0.name == "p" ? URLQueryItem(name: "p", value: String(repeating: "A", count: 43)) : $0 }
        do { _ = try await RemotePairing.pair(link: try RemotePairingLink(parsing: c.string!), identity: identity, phoneName: "x"); Issue.record("pin mismatch must stop pairing") }
        catch let e as PairingError { #expect(e.failure == .identityMismatch) }
        // Right certificate but a different identity key in the code: the computer cannot prove it holds that key.
        c = URLComponents(string: h.link)!
        c.queryItems = c.queryItems!.map { $0.name == "k" ? URLQueryItem(name: "k", value: Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64URLString) : $0 }
        do { _ = try await RemotePairing.pair(link: try RemotePairingLink(parsing: c.string!), identity: identity, phoneName: "x"); Issue.record("identity mismatch must stop pairing") }
        catch let e as PairingError { #expect(e.failure == .identityMismatch || e.failure == .invalidCode || e.failure == .expired) }
        // Nothing is listening there.
        var dead = URLComponents(string: h.link)!
        dead.queryItems = dead.queryItems!.map { $0.name == "e" ? URLQueryItem(name: "e", value: "127.0.0.1:1") : $0 }
        do { _ = try await RemotePairing.pair(link: try RemotePairingLink(parsing: dead.string!), identity: identity, phoneName: "x"); Issue.record("unreachable") }
        catch let e as PairingError { #expect(e.failure == .unreachable) }
    }

    @Test func modeAboveTheMacsCeilingIsLoweredAndTheCeilingIsVisible() async throws {
        let h = try await Harness.start(maxMode: "readOnly"); defer { h.stop() }
        let identity = try PhoneIdentity.loadOrCreate(in: InMemorySecretStore())
        let record = try await RemotePairing.pair(link: try RemotePairingLink(parsing: h.link), identity: identity, phoneName: "p")
        let client = RemoteAgentClient(record: record, identity: identity)
        #expect(try await client.status().limits.maxPermissionMode == "readOnly")
        let task = try await client.createTask(NewRemoteTask(backend: "italk", prompt: "hi", permissionMode: "auto"), idempotencyKey: "swift-key-9001")
        #expect(task.permissionMode == "readOnly")
    }
}
