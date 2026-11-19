import Foundation
import Testing
@testable import AgentRuntime

func artifact(files: [ModelFile] = [], resident: Int64 = 1_500_000_000, autonomy: AutonomyLevel = .restrictedTools) -> ModelArtifact {
    ModelArtifact(id: "qwen3.5-2b-4bit", displayName: "Qwen3.5 2B", version: "1", license: "apache-2.0", baseModelLicense: "apache-2.0", files: files,
                  residentBytes: resident, kvBytesPerToken: 50_000, contextTokens: 4096, maxAutonomy: autonomy, autonomySource: "unmeasured default")
}
let gb: Int64 = 1_000_000_000

@Test func advisorShrinksContextBeforeRefusing() {
    let roomy = DeviceProfile(physicalMemory: 8 * gb, availableMemory: 4 * gb, freeDisk: 20 * gb)
    #expect(ResourceAdvisor.canRun(artifact(), roomy) == .ok(contextTokens: 4096))
    let tight = DeviceProfile(physicalMemory: 6 * gb, availableMemory: 2_200_000_000, freeDisk: 20 * gb)
    if case .degraded(let ctx, _) = ResourceAdvisor.canRun(artifact(), tight) { #expect(ctx < 4096 && ctx >= 512) } else { Issue.record("expected degraded") }
    let starved = DeviceProfile(physicalMemory: 6 * gb, availableMemory: 2_020_000_000, freeDisk: 20 * gb)
    #expect(ResourceAdvisor.canRun(artifact(), starved) == .refuse(reason: "可用内存不足以保留最小对话上下文"))
    #expect({ if case .refuse = ResourceAdvisor.canRun(artifact(), .init(physicalMemory: 8 * gb, availableMemory: gb, freeDisk: gb)) { true } else { false } }())
}

@Test func thermalAndPowerReduceAutonomyAndLoad() {
    let hot = DeviceProfile(physicalMemory: 8 * gb, availableMemory: 4 * gb, freeDisk: 20 * gb, thermal: .serious)
    #expect(ResourceAdvisor.effectiveAutonomy(artifact(autonomy: .fullAgent), hot) == .restrictedTools)
    if case .degraded(let c, _) = ResourceAdvisor.canRun(artifact(), hot) { #expect(c <= 1024) } else { Issue.record("expected degraded") }
    let critical = DeviceProfile(physicalMemory: 8 * gb, availableMemory: 4 * gb, freeDisk: 20 * gb, thermal: .critical)
    #expect({ if case .refuse = ResourceAdvisor.canRun(artifact(), critical) { true } else { false } }())
}

@Test func downloadNeedsDiskHeadroom() {
    let a = artifact(files: [ModelFile(name: "w", bytes: 1_742_000_000, sha256: "")])
    #expect({ if case .refuse = ResourceAdvisor.canDownload(a, .init(physicalMemory: 8 * gb, availableMemory: 4 * gb, freeDisk: 2 * gb)) { true } else { false } }())
    #expect(ResourceAdvisor.canDownload(a, .init(physicalMemory: 8 * gb, availableMemory: 4 * gb, freeDisk: 5 * gb)) == .ok(contextTokens: 4096))
}

@Test func residencyUnloadsLeastRecentlyUsedOnly() throws {
    let t = Date(timeIntervalSince1970: 100)
    let resident = [ResidencyPlanner.Component(name: "asr", bytes: gb, lastUsed: t), .init(name: "tts", bytes: gb / 2, lastUsed: t.addingTimeInterval(5))]
    let p = ResidencyPlanner()
    #expect(try p.unloads(resident: resident, needed: .init(name: "llm", bytes: 2 * gb, lastUsed: t), budget: 4 * gb) == [])
    #expect(try p.unloads(resident: resident, needed: .init(name: "llm", bytes: 2 * gb, lastUsed: t), budget: 3 * gb) == ["asr"])
    #expect(throws: ResidencyPlanner.PlanError.wontFit) { try p.unloads(resident: resident, needed: .init(name: "llm", bytes: 4 * gb, lastUsed: t), budget: 3 * gb) }
}

func tempDir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("italk-\(UUID())") }

@Test func catalogIsPinnedAndConservative() {
    #expect(ModelCatalog.manifest.schemaVersion == 1 && !ModelCatalog.manifest.manifestVersion.isEmpty)
    for a in ModelCatalog.all {
        #expect(a.files.allSatisfy { $0.sha256.count == 64 && $0.bytes > 0 })
        #expect(a.files.contains { $0.name == "model.safetensors" } && a.files.contains { $0.name == "tokenizer.json" } && a.files.contains { $0.name == "config.json" })
        #expect(a.license.contains("apache") && a.baseModelLicense.contains("apache"))
        #expect(a.maxAutonomy < .fullAgent)
        // Only sources whose bytes were actually confirmed may be verified; pinned revision, never a moving branch.
        for s in a.sources where s.trust == .verified {
            if case .huggingFace(_, _, let rev) = s.layout { #expect(rev.count == 40) }
        }
        #expect(a.sources.contains { $0.trust == .verified })
        #expect(a.sources.filter { $0.region == .mainlandChina }.allSatisfy { $0.trust == .candidate }, "no mainland source has been verified yet")
    }
    #expect(ModelCatalog.qwen35_0_8b_4bit.maxAutonomy == .chatOnly)
}

@Test func plannerPrefersRegionAndUsesHashGatedMirrors() {
    let a = ModelCatalog.qwen35_2b_4bit
    // Verified-only mode still exists (Debug toggle).
    #expect(SourcePlanner.order(a, policy: .init(preferMainlandChina: true, allowCandidates: false)).map(\.id) == ["huggingface"])
    // Default: in China, mainland mirrors first, verified global source last.
    #expect(SourcePlanner.order(a, policy: .init(preferMainlandChina: true)).map(\.id) == ["hf-mirror", "modelscope", "huggingface"])
    #expect(SourcePlanner.order(a, policy: .init(preferMainlandChina: false)).first?.id == "huggingface")
    let cdn = URL(string: "https://cdn.example.test/models")!
    #expect(SourcePlanner.order(a, policy: .init(preferMainlandChina: true, cdnBase: cdn)).first?.id == "italk-cdn")
    #expect(SourcePlanner.cdnSource(cdn).url(for: "config.json", artifact: a)?.absoluteString == "https://cdn.example.test/models/qwen3.5-2b-4bit/\(a.version)/config.json")
    // The mainland iPhone result from 2026-10-26: HF timed out, both mirrors reachable and identical → HF dropped, faster mirror first.
    let mainland = ["huggingface": SourceProbe(sourceId: "huggingface", reachable: false, error: "URLError -1001"),
                    "modelscope": SourceProbe(sourceId: "modelscope", reachable: true, latencyMs: 1317, contentMatches: true),
                    "hf-mirror": SourceProbe(sourceId: "hf-mirror", reachable: true, latencyMs: 1355, contentMatches: true)]
    #expect(SourcePlanner.order(a, policy: .init(preferMainlandChina: true), probes: mainland).map(\.id) == ["modelscope", "hf-mirror"])
    // Regression: verified-only + unreachable verified source must not produce an empty plan.
    #expect(SourcePlanner.order(a, policy: .init(preferMainlandChina: true, allowCandidates: false), probes: mainland).map(\.id) == ["huggingface"])
    // Different bytes are never used, even if that leaves nothing.
    let lying = ["huggingface": SourceProbe(sourceId: "huggingface", reachable: true, contentMatches: false)]
    #expect(SourcePlanner.order(a, policy: .init(preferMainlandChina: false, allowCandidates: false), probes: lying).isEmpty)
    #expect(ModelSourcePolicy.current(locale: Locale(identifier: "zh_CN"), timeZone: TimeZone(identifier: "America/New_York")!).preferMainlandChina)
    #expect(!ModelSourcePolicy.current(locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "America/New_York")!).preferMainlandChina)
}

// MARK: - Multi-source download with a stub network

/// Per-host behaviour: serve bytes (honouring Range), fail, corrupt, or drop after N bytes.
final class StubNet: URLProtocol, @unchecked Sendable {
    enum Mode { case serve, unreachable, http(Int), corrupt, dropAfter(Int), ignoreRange }
    nonisolated(unsafe) static var files: [String: Data] = [:]          // path suffix → bytes
    nonisolated(unsafe) static var modes: [String: Mode] = [:]          // host → mode
    nonisolated(unsafe) static var log: [String] = []                   // "host path range"
    static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!, host = url.host()!
        let range = request.value(forHTTPHeaderField: "Range")
        let (mode, body) = Self.lock.withLock { () -> (Mode, Data?) in
            Self.log.append("\(host) \(url.lastPathComponent) \(range ?? "-")")
            return (Self.modes[host] ?? .serve, Self.files.first { url.path.hasSuffix($0.key) }?.value)
        }
        func fail() { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)) }
        guard let body else { return respond(404, Data()) }
        switch mode {
        case .unreachable: return fail()
        case .http(let c): return respond(c, Data())
        case .corrupt: var d = body; d[d.startIndex] ^= 0xFF; return respond(200, d)
        case .ignoreRange: return respond(200, body)
        case .serve, .dropAfter:
            var start = 0
            if let r = range, let s = Int(r.dropFirst(6).split(separator: "-").first ?? "") { start = s }
            let slice = body.subdata(in: start..<body.count)
            let headers = start > 0 ? ["Content-Range": "bytes \(start)-\(body.count - 1)/\(body.count)", "Content-Length": "\(slice.count)"] : ["Content-Length": "\(slice.count)"]
            let resp = HTTPURLResponse(url: url, statusCode: start > 0 ? 206 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            if case .dropAfter(let n) = mode, n < slice.count {
                client?.urlProtocol(self, didLoad: slice.prefix(n))
                // Real connections drop after bytes were delivered; give URLSession time to hand them to the delegate.
                let c = client
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { c?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
                return
            }
            client?.urlProtocol(self, didLoad: slice)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    private func respond(_ code: Int, _ data: Data) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "\(data.count)"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [StubNet.self]; return URLSession(configuration: c)
    }
}

func src(_ id: String, host: String, region: ModelSource.Region = .global) -> ModelSource {
    ModelSource(id: id, displayName: id, region: region, trust: .verified, layout: .huggingFace(host: host, repo: "org/model", revision: String(repeating: "a", count: 40)), verifiedNote: "test")
}
func stubArtifact() -> (ModelArtifact, Data, Data) {
    let weights = Data((0..<300_000).map { UInt8(($0 * 7) % 251) }), config = Data("{\"model_type\":\"qwen3_5\"}".utf8)
    func h(_ d: Data) -> String { SHA256Hex.of(d) }
    let a = artifact(files: [ModelFile(name: "config.json", bytes: Int64(config.count), sha256: h(config)), ModelFile(name: "model.safetensors", bytes: Int64(weights.count), sha256: h(weights))])
    StubNet.lock.withLock { StubNet.files = ["config.json": config, "model.safetensors": weights]; StubNet.modes = [:]; StubNet.log = [] }
    return (a, weights, config)
}

import CryptoKit
enum SHA256Hex { static func of(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() } }

@Suite(.serialized) struct MultiSourceDownloadTests {
    @Test func failsOverFromUnreachableSource() async throws {
        let (a, _, _) = stubArtifact()
        StubNet.lock.withLock { StubNet.modes["down.test"] = .unreachable }
        let store = try ModelStore(root: tempDir(), session: StubNet.session()); await store.setRetryBackoff([0])
        try await store.install(a, sources: [src("a", host: "down.test"), src("b", host: "ok.test")])
        #expect(try await store.verify(a))
    }

    @Test func corruptSourceIsRejectedAndSkipped() async throws {
        let (a, _, _) = stubArtifact()
        StubNet.lock.withLock { StubNet.modes["bad.test"] = .corrupt }
        let store = try ModelStore(root: tempDir(), session: StubNet.session()); await store.setRetryBackoff([0])
        let events = EventLog()
        try await store.install(a, sources: [src("bad", host: "bad.test"), src("good", host: "ok.test")]) { events.add($0) }
        #expect(try await store.verify(a))
        #expect(events.items.contains(.switchingSource(from: "bad", reason: "hash mismatch")))
        // After the first mismatch the corrupt source is not asked for later files.
        let badRequests = StubNet.lock.withLock { StubNet.log.filter { $0.hasPrefix("bad.test") } }
        #expect(badRequests.count == 1)
    }

    @Test func resumesAcrossSourcesWithRange() async throws {
        let (a, w, _) = stubArtifact()
        StubNet.lock.withLock { StubNet.modes["flaky.test"] = .dropAfter(100_000) }
        let store = try ModelStore(root: tempDir(), session: StubNet.session()); await store.setRetryBackoff([])
        try await store.install(a, sources: [src("flaky", host: "flaky.test"), src("good", host: "ok.test")])
        #expect(try await store.verify(a))
        let log = StubNet.lock.withLock { StubNet.log }
        #expect(log.contains("ok.test model.safetensors bytes=100000-"), "second source must continue from the bytes already on disk: \(log)")
        _ = w
    }

    @Test func serverIgnoringRangeRestartsCleanly() async throws {
        let (a, _, _) = stubArtifact()
        StubNet.lock.withLock { StubNet.modes["flaky.test"] = .dropAfter(50_000); StubNet.modes["plain.test"] = .ignoreRange }
        let store = try ModelStore(root: tempDir(), session: StubNet.session()); await store.setRetryBackoff([])
        try await store.install(a, sources: [src("flaky", host: "flaky.test"), src("plain", host: "plain.test")])
        #expect(try await store.verify(a))
    }

    @Test func allSourcesFailingInstallsNothing() async throws {
        let (a, _, _) = stubArtifact()
        StubNet.lock.withLock { StubNet.modes = ["x.test": .unreachable, "y.test": .http(403)] }
        let root = tempDir()
        let store = try ModelStore(root: root, session: StubNet.session()); await store.setRetryBackoff([0])
        do {
            try await store.install(a, sources: [src("x", host: "x.test"), src("y", host: "y.test")])
            Issue.record("should fail")
        } catch ModelStoreError.allSourcesFailed(let file, let reasons) {
            #expect(file == "config.json" && reasons["y"] == "HTTP 403" && reasons["x"] != nil)
        }
        let installed = await store.installed(), flag = await store.isInstalled(a)
        #expect(installed.isEmpty && !flag)
    }

    @Test func refusesWhenStorageIsShort() async throws {
        let (a, _, _) = stubArtifact()
        let store = try ModelStore(root: tempDir(), session: StubNet.session(), freeSpace: { 1_000 })
        await #expect(throws: ModelStoreError.self) { try await store.install(a, sources: [src("b", host: "ok.test")]) }
    }

    @Test func interruptedDownloadResumesAfterRelaunch() async throws {
        let (a, _, _) = stubArtifact()
        let root = tempDir()
        StubNet.lock.withLock { StubNet.modes["ok.test"] = .dropAfter(120_000) }
        let first = try ModelStore(root: root, session: StubNet.session()); await first.setRetryBackoff([])
        await #expect(throws: ModelStoreError.self) { try await first.install(a, sources: [src("b", host: "ok.test")]) }
        // "Relaunch": new store instance, network healthy again.
        StubNet.lock.withLock { StubNet.modes = [:]; StubNet.log = [] }
        let second = try ModelStore(root: root, session: StubNet.session())
        try await second.install(a, sources: [src("b", host: "ok.test")])
        #expect(try await second.verify(a))
        #expect(StubNet.lock.withLock { StubNet.log }.contains("ok.test model.safetensors bytes=120000-"))
    }

    @Test func importPackageVerifiesEveryFile() async throws {
        let (a, w, c) = stubArtifact()
        let pkg = tempDir(); try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try c.write(to: pkg.appendingPathComponent("config.json"))
        let store = try ModelStore(root: tempDir(), session: StubNet.session())
        await #expect(throws: ModelStoreError.importMissing(file: "model.safetensors")) { try await store.importPackage(a, from: pkg) }
        var bad = w; bad[0] ^= 1; try bad.write(to: pkg.appendingPathComponent("model.safetensors"))
        await #expect(throws: ModelStoreError.integrityFailure(file: "model.safetensors")) { try await store.importPackage(a, from: pkg) }
        try w.write(to: pkg.appendingPathComponent("model.safetensors"))
        try await store.importPackage(a, from: pkg)
        #expect(try await store.verify(a))
    }

    @Test func damagedInstallIsDetectedAtLaunch() async throws {
        let (a, w, c) = stubArtifact()
        let pkg = tempDir(); try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try c.write(to: pkg.appendingPathComponent("config.json")); try w.write(to: pkg.appendingPathComponent("model.safetensors"))
        let store = try ModelStore(root: tempDir(), session: StubNet.session())
        try await store.importPackage(a, from: pkg)
        let dir = await store.directory(for: a.id)!
        try Data(w.prefix(10)).write(to: dir.appendingPathComponent("model.safetensors"))
        #expect(await store.validateInstalled(a) == false)
        #expect(await store.isInstalled(a) == false)
    }

    @Test func proberFlagsDifferentBytes() async throws {
        let (a, _, _) = stubArtifact()
        StubNet.lock.withLock { StubNet.modes = ["bad.test": .corrupt, "down.test": .unreachable] }
        let r = await SourceProber.probe([src("ok", host: "ok.test"), src("bad", host: "bad.test"), src("down", host: "down.test")], artifact: a, session: StubNet.session())
        #expect(r["ok"]?.contentMatches == true && r["bad"]?.contentMatches == false && r["down"]?.reachable == false)
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock(); private var _items: [DownloadState] = []
    func add(_ e: DownloadState) { lock.withLock { _items.append(e) } }
    var items: [DownloadState] { lock.withLock { _items } }
}
