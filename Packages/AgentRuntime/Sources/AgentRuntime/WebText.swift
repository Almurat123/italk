import Foundation

/// Tolerant HTML → readable text. No scripts are run and nothing hidden is kept: hidden elements, comments, scripts,
/// styles and zero-width characters are removed so instructions planted in invisible markup never reach the model.
public enum WebText {
    public struct Link: Codable, Sendable, Equatable { public var text: String; public var url: String }
    public struct Page: Sendable, Equatable {
        /// `<meta http-equiv="refresh" content="0; url=…">` destination (redirect pages).
        public var refresh: URL?
        public var title: String
        public var description: String
        public var text: String
        public var links: [Link]
    }

    public static func extract(html raw: String, baseURL: URL?) -> Page {
        var html = raw
        // 1. Drop non-content and invisible regions entirely.
        html = html.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
        for tag in ["script", "style", "noscript", "template", "svg", "canvas", "iframe", "object"] {
            html = html.replacingOccurrences(of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)\\s*>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        let title = decode(firstMatch(html, "<title[^>]*>([\\s\\S]*?)</title>") ?? "").collapsed
        let refresh = firstMatch(html, "<meta[^>]+http-equiv=[\"']refresh[\"'][^>]*content=[\"'][^\"']*url=([^\"'>\\s]+)")
            .flatMap { URL(string: decode($0), relativeTo: baseURL)?.absoluteURL }
        let description = decode(firstMatch(html, "<meta[^>]+name=[\"']description[\"'][^>]*content=[\"']([^\"']*)") ??
                                 firstMatch(html, "<meta[^>]+property=[\"']og:description[\"'][^>]*content=[\"']([^\"']*)") ?? "").collapsed
        html = html.replacingOccurrences(of: "<head\\b[^>]*>[\\s\\S]*?</head\\s*>", with: " ", options: [.regularExpression, .caseInsensitive])
        html = removeHidden(html)
        for tag in ["nav", "footer", "aside", "form", "button", "select"] {
            html = html.replacingOccurrences(of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)\\s*>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        // 2. Prefer the main content region when the page marks one.
        if let main = firstMatch(html, "<main\\b[^>]*>([\\s\\S]*?)</main\\s*>") ?? firstMatch(html, "<article\\b[^>]*>([\\s\\S]*?)</article\\s*>"),
           plain(main).count > 200 { html = main }
        let links = extractLinks(html, baseURL: baseURL)
        return Page(refresh: refresh, title: title, description: description, text: plain(html), links: links)
    }

    /// Markup → text with paragraph breaks.
    public static func plain(_ html: String) -> String {
        var t = html
        t = t.replacingOccurrences(of: "<(br|hr)\\b[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "</?(p|div|section|article|main|h[1-6]|li|ul|ol|tr|table|blockquote|pre|dd|dt|figcaption|header)\\b[^>]*>",
                                   with: "\n", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "<li\\b[^>]*>", with: "\n• ", options: [.regularExpression, .caseInsensitive])
        // Inline formatting joins words (Chinese has no spaces: <em>杭州</em>市 → 杭州市).
        t = t.replacingOccurrences(of: "</?(em|strong|b|i|u|span|a|font|mark|small|sub|sup|abbr|code)\\b[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        t = decode(t)
        let lines = t.components(separatedBy: "\n").map(\.collapsed).filter { !$0.isEmpty }
        // Remove consecutive duplicates (menus repeated for mobile/desktop).
        var out: [String] = []
        for l in lines where out.last != l { out.append(l) }
        return out.joined(separator: "\n")
    }

    static func removeHidden(_ html: String) -> String {
        var t = html
        let hidden = "<(\\w+)\\b[^>]*(?:\\shidden(?:[\\s>=])|aria-hidden=[\"']true[\"']|style=[\"'][^\"']*(?:display\\s*:\\s*none|visibility\\s*:\\s*hidden|font-size\\s*:\\s*0)[^\"']*[\"'])[^>]*>"
        // Remove the element and its content (non-greedy to the matching close tag of the same name).
        for _ in 0..<40 {
            guard let r = t.range(of: hidden, options: [.regularExpression, .caseInsensitive]) else { break }
            let open = String(t[r])
            let name = (firstMatch(open, "^<(\\w+)") ?? "").lowercased()
            if ["input", "img", "br", "meta", "link"].contains(name) { t.replaceSubrange(r, with: " "); continue }
            if let close = t.range(of: "</\(name)\\s*>", options: [.regularExpression, .caseInsensitive], range: r.upperBound..<t.endIndex) {
                t.replaceSubrange(r.lowerBound..<close.upperBound, with: " ")
            } else { t.replaceSubrange(r, with: " ") }
        }
        return t
    }

    static func extractLinks(_ html: String, baseURL: URL?) -> [Link] {
        guard let re = try? NSRegularExpression(pattern: "<a\\b[^>]*href=[\"']([^\"'#][^\"']*)[\"'][^>]*>([\\s\\S]*?)</a\\s*>", options: .caseInsensitive) else { return [] }
        let ns = html as NSString
        var seen = Set<String>(), out: [Link] = []
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let href = decode(ns.substring(with: m.range(at: 1)))
            guard let u = URL(string: href, relativeTo: baseURL)?.absoluteURL, ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { continue }
            let text = plain(ns.substring(with: m.range(at: 2))).replacingOccurrences(of: "\n", with: " ").collapsed
            guard !text.isEmpty, text.count <= 120, seen.insert(u.absoluteString).inserted else { continue }
            out.append(Link(text: text, url: u.absoluteString))
            if out.count >= 200 { break }
        }
        return out
    }

    static func firstMatch(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    static let entities: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ensp": " ", "emsp": " ",
        "mdash": "—", "ndash": "–", "hellip": "…", "middot": "·", "laquo": "«", "raquo": "»", "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’",
        "copy": "©", "reg": "®", "times": "×", "yen": "¥", "deg": "°"]

    public static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s.strippingInvisible }
        var out = "", i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let name = String(s[s.index(after: i)..<semi])
                var rep: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") { rep = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } }
                else if name.hasPrefix("#") { rep = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) } }
                else { rep = entities[name] }
                if let rep { out += rep; i = s.index(after: semi); continue }
            }
            out.append(s[i]); i = s.index(after: i)
        }
        return out.strippingInvisible
    }
}

extension String {
    var collapsed: String {
        replacingOccurrences(of: "[\\s\\u00a0\\u3000]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
    /// Zero-width and bidi control characters (used to hide text from people but not from models).
    var strippingInvisible: String {
        String(String.UnicodeScalarView(unicodeScalars.filter { s in
            !(0x200B...0x200F).contains(s.value) && !(0x202A...0x202E).contains(s.value) && !(0x2060...0x2064).contains(s.value) && s.value != 0xFEFF
        }))
    }
}

/// Only public http(s) destinations. Blocks loopback, link-local, private networks and `.local` names (no SSRF into the
/// person's home network through a model-chosen URL).
public enum WebSafety {
    public static func check(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return "只能打开 http/https 网页" }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return "网址无效" }
        if url.user != nil || url.password != nil { return "不打开带账号信息的网址" }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") || host.hasSuffix(".internal") || host.hasSuffix(".lan") { return "不访问本地网络地址" }
        if isPrivateAddress(host) { return "不访问本地或内网地址" }
        return nil
    }

    static func isPrivateAddress(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h.contains(":") {   // IPv6 literal
            return h == "::1" || h == "::" || h.hasPrefix("fc") || h.hasPrefix("fd") || h.hasPrefix("fe80") || h.hasPrefix("::ffff:")
        }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, h.split(separator: ".").count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (0, _), (169, 254), (192, 168), (100, 64...127): return true
        case (172, 16...31): return true
        default: return parts[0] >= 224
        }
    }
}
