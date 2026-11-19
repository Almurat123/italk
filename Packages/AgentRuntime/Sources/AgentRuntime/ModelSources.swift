import Foundation
import CryptoKit

/// Where model bytes may come from. A source is only a URL rule: correctness is decided by the manifest's
/// size + SHA-256 for every file, never by which host served it.
public struct ModelSource: Codable, Sendable, Equatable, Identifiable {
    public enum Region: String, Codable, Sendable { case mainlandChina, global }
    /// `verified`: the exact pinned bytes were confirmed from this source (see `verifiedNote`).
    /// `candidate`: a mirror whose full contents are not yet confirmed. Usable because every file is still hash-checked;
    /// ranked after verified sources of the same region.
    public enum Trust: String, Codable, Sendable { case verified, candidate }
    public enum Layout: Codable, Sendable, Equatable {
        /// `https://<host>/<repo>/resolve/<revision>/<file>` (Hugging Face and HF-compatible mirrors).
        case huggingFace(host: String, repo: String, revision: String)
        /// `https://www.modelscope.cn/models/<repo>/resolve/<revision>/<file>`.
        case modelScope(repo: String, revision: String)
        /// `<base>/<artifactId>/<version>/<file>`: iTalk-controlled CDN / object storage.
        case flat(base: URL)
    }
    public var id: String
    public var displayName: String
    public var region: Region
    public var trust: Trust
    public var layout: Layout
    public var verifiedNote: String
    public init(id: String, displayName: String, region: Region, trust: Trust, layout: Layout, verifiedNote: String) {
        self.id = id; self.displayName = displayName; self.region = region; self.trust = trust; self.layout = layout; self.verifiedNote = verifiedNote
    }

    public func url(for file: String, artifact: ModelArtifact) -> URL? {
        let path = file.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        switch layout {
        case .huggingFace(let host, let repo, let rev): return URL(string: "https://\(host)/\(repo)/resolve/\(rev)/\(path)")
        case .modelScope(let repo, let rev): return URL(string: "https://www.modelscope.cn/models/\(repo)/resolve/\(rev)/\(path)")
        case .flat(let base): return base.appendingPathComponent(artifact.id).appendingPathComponent(artifact.version).appendingPathComponent(file)
        }
    }
}

/// Runtime knobs. The iTalk CDN is not deployed: `cdnBase` stays nil until production infrastructure exists.
public struct ModelSourcePolicy: Sendable, Equatable {
    public var preferMainlandChina: Bool
    public var allowCandidates: Bool
    public var cdnBase: URL?
    public init(preferMainlandChina: Bool, allowCandidates: Bool = true, cdnBase: URL? = nil) {
        self.preferMainlandChina = preferMainlandChina; self.allowCandidates = allowCandidates; self.cdnBase = cdnBase
    }
    /// Region guess from settings only (no IP lookup, no network): China-mainland region or China time zone.
    public static func current(allowCandidates: Bool = true, cdnBase: URL? = nil, locale: Locale = .current, timeZone: TimeZone = .current) -> ModelSourcePolicy {
        let cn = locale.region?.identifier == "CN" || ["Asia/Shanghai", "Asia/Urumqi", "Asia/Chongqing", "Asia/Harbin"].contains(timeZone.identifier)
        return ModelSourcePolicy(preferMainlandChina: cn, allowCandidates: allowCandidates, cdnBase: cdnBase)
    }
}

public enum SourcePlanner {
    public static func cdnSource(_ base: URL) -> ModelSource {
        ModelSource(id: "italk-cdn", displayName: "iTalk 下载服务", region: .mainlandChina, trust: .verified, layout: .flat(base: base),
                    verifiedNote: "iTalk publishes the exact manifest files; every byte is still hash-checked on device.")
    }
    /// Ordered list to try. Preferred region first; within a region verified before candidate; probe latency breaks ties.
    public static func order(_ artifact: ModelArtifact, policy: ModelSourcePolicy, probes: [String: SourceProbe] = [:]) -> [ModelSource] {
        var all = artifact.sources
        if let cdn = policy.cdnBase { all.insert(cdnSource(cdn), at: 0) }
        let allowed = all.filter { policy.allowCandidates || $0.trust == .verified }
        // A source that served different bytes is never used. Unreachable ones are dropped only if something else is left:
        // a probe is a snapshot and the network may have changed since.
        let honest = allowed.filter { probes[$0.id]?.contentMatches != false }
        let reachable = honest.filter { probes[$0.id]?.reachable ?? true }
        let usable = reachable.isEmpty ? honest : reachable
        func rank(_ s: ModelSource) -> (Int, Int, Int, Int) {
            let regionRank = (s.region == .mainlandChina) == policy.preferMainlandChina ? 0 : 1
            let cdnRank = s.id == "italk-cdn" ? 0 : 1
            let trustRank = s.trust == .verified ? 0 : 1
            let latency = probes[s.id]?.latencyMs ?? 9_999
            return (cdnRank, regionRank, trustRank, latency)
        }
        return usable.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }
}

/// Result of checking one source from the device's current network.
public struct SourceProbe: Codable, Sendable, Equatable {
    public var sourceId: String
    public var reachable: Bool
    public var latencyMs: Int?
    /// Smallest manifest file downloaded and hashed: true = identical bytes, false = different bytes, nil = not checked.
    public var contentMatches: Bool?
    public var finalHost: String?
    public var error: String?
}

public enum SourceProber {
    /// Downloads the smallest manifest file from each source and compares its SHA-256. Short timeout; no retries.
    public static func probe(_ sources: [ModelSource], artifact: ModelArtifact, session: URLSession, timeout: TimeInterval = 8) async -> [String: SourceProbe] {
        guard let file = artifact.files.min(by: { $0.bytes < $1.bytes }) else { return [:] }
        return await withTaskGroup(of: SourceProbe.self) { group in
            for s in sources {
                group.addTask {
                    guard let url = s.url(for: file.remotePath, artifact: artifact) else { return SourceProbe(sourceId: s.id, reachable: false, error: "bad url") }
                    var req = URLRequest(url: url, timeoutInterval: timeout)
                    req.cachePolicy = .reloadIgnoringLocalCacheData
                    let start = ContinuousClock.now
                    do {
                        let (data, response) = try await session.data(for: req)
                        let d = ContinuousClock.now - start
                        let ms = Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
                        let http = response as? HTTPURLResponse
                        guard let http, (200..<300).contains(http.statusCode) else {
                            return SourceProbe(sourceId: s.id, reachable: false, latencyMs: ms, finalHost: response.url?.host(), error: "HTTP \(http?.statusCode ?? -1)")
                        }
                        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                        return SourceProbe(sourceId: s.id, reachable: true, latencyMs: ms, contentMatches: hash == file.sha256 && Int64(data.count) == file.bytes, finalHost: response.url?.host())
                    } catch {
                        return SourceProbe(sourceId: s.id, reachable: false, error: (error as? URLError).map { "URLError \($0.code.rawValue)" } ?? "\(error)")
                    }
                }
            }
            var out: [String: SourceProbe] = [:]
            for await p in group { out[p.sourceId] = p }
            return out
        }
    }
}
