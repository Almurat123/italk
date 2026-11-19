import Foundation
import AgentRuntime
import NaturalLanguage
import Translation
import WidgetKit
#if os(iOS)
import HomeKit
import WatchConnectivity
#endif

enum HomeSkills {
    #if os(iOS)
    static let secureTypes: Set<String> = [HMServiceTypeLockMechanism, HMServiceTypeGarageDoorOpener, HMServiceTypeSecuritySystem, HMServiceTypeDoor, HMServiceTypeWindow]
    static func find(_ id: String, in homes: [HMHome]) -> HMAccessory? { homes.flatMap(\.accessories).first { $0.uniqueIdentifier.uuidString == id } }
    @MainActor static func describe(_ a: HMAccessory) -> JSONValue {
        let services = a.services.filter { $0.isUserInteractive }.map { s -> JSONValue in
            var o: [String: JSONValue] = ["type": .string(s.localizedDescription), "name": .string(s.name)]
            for c in s.characteristics where c.properties.contains(HMCharacteristicPropertyReadable) {
                switch c.characteristicType {
                case HMCharacteristicTypePowerState: o["on"] = (c.value as? Bool).map(JSONValue.bool) ?? .null
                case HMCharacteristicTypeBrightness: o["brightness"] = (c.value as? NSNumber).map { .number($0.doubleValue) } ?? .null
                case HMCharacteristicTypeCurrentTemperature: o["temperature"] = (c.value as? NSNumber).map { .number($0.doubleValue) } ?? .null
                case HMCharacteristicTypeTargetTemperature: o["targetTemperature"] = (c.value as? NSNumber).map { .number($0.doubleValue) } ?? .null
                case HMCharacteristicTypeCurrentLockMechanismState: o["locked"] = (c.value as? NSNumber).map { .bool($0.intValue == 1) } ?? .null
                default: break
                }
            }
            return .object(o)
        }
        return .object(["id": .string(a.uniqueIdentifier.uuidString), "name": .string(a.name), "room": .string(a.room?.name ?? ""),
                        "reachable": .bool(a.isReachable), "services": .array(services),
                        "secure": .bool(a.services.contains { secureTypes.contains($0.serviceType) })])
    }
    @MainActor static func write(_ a: HMAccessory, characteristic: String, value: Any) async throws {
        guard let c = a.services.flatMap(\.characteristics).first(where: { $0.characteristicType == characteristic && $0.properties.contains(HMCharacteristicPropertyWritable) })
        else { throw fail("「\(a.name)」不支持这个操作") }
        try await c.writeValue(value)
    }
    @MainActor static func apply(_ args: JSONValue, secure: Bool) async throws -> ToolOutput {
        let homes = await HomeAccess.shared.homes()
        guard let id = args.str("accessoryId"), let a = find(id, in: homes) else { throw fail("找不到这个设备，请先用 home_list 查看") }
        let isSecure = a.services.contains { secureTypes.contains($0.serviceType) }
        if isSecure && !secure { throw fail("门锁、车库门、安防设备需用 home_control_secure（会请用户确认）") }
        guard a.isReachable else { throw fail("「\(a.name)」当前无响应", retry: true) }
        if let on = args.flag("on") { try await write(a, characteristic: HMCharacteristicTypePowerState, value: on) }
        if let b = args.num("brightness") { try await write(a, characteristic: HMCharacteristicTypeBrightness, value: Int(b)) }
        if let t = args.num("targetTemperature") { try await write(a, characteristic: HMCharacteristicTypeTargetTemperature, value: t) }
        if let lock = args.flag("lock") { try await write(a, characteristic: HMCharacteristicTypeTargetLockMechanismState, value: lock ? 1 : 0) }
        if let open = args.flag("open") { try await write(a, characteristic: HMCharacteristicTypeTargetDoorState, value: open ? 0 : 1) }
        return out(["accessory": describe(a)], "已控制「\(a.name)」")
    }
    #endif

    static let list = FnTool(ToolSpec(name: "home_list", description: "列出“家庭”App 中的家、房间、配件及其状态（灯、开关、插座、空调、门锁等）和场景", permission: .readOnly,
                                      capability: .home, systemPermission: .homeKit, dataClass: .personal, timeoutSeconds: 15)) { _, _ in
        #if os(iOS)
        return await MainActor.run { () -> Task<ToolOutput, Never> in Task { @MainActor in
            let homes = await HomeAccess.shared.homes()
            let list: [JSONValue] = homes.map { h in .object(["name": .string(h.name), "primary": .bool(h.isPrimary),
                "accessories": .array(h.accessories.map(describe)),
                "scenes": .array(h.actionSets.map { .object(["id": .string($0.uniqueIdentifier.uuidString), "name": .string($0.name)]) })]) }
            return out(["homes": .array(list)], homes.isEmpty ? "没有可用的家庭（或尚未授权）" : "\(homes.count) 个家庭")
        } }.value
        #else
        throw fail("此平台不支持“家庭”")
        #endif
    }

    static let control = FnTool(ToolSpec(name: "home_control", description: "控制灯、开关、插座、风扇、空调等（开关、亮度、目标温度）；门锁和车库门请用 home_control_secure", parameters: [
        "accessoryId": ParamSpec(.string, "home_list 返回的 id", maxLength: 60),
        "on": ParamSpec(.boolean, "开/关", required: false),
        "brightness": ParamSpec(.integer, "亮度 0–100", required: false, minimum: 0, maximum: 100),
        "targetTemperature": ParamSpec(.number, "目标温度 °C", required: false, minimum: 10, maximum: 38)
    ], permission: .lowRiskAction, capability: .home, systemPermission: .homeKit, dataClass: .personal, timeoutSeconds: 20)) { a, _ in
        #if os(iOS)
        return try await MainActor.run { Task { @MainActor in try await apply(a, secure: false) } }.value
        #else
        throw fail("此平台不支持“家庭”")
        #endif
    }

    static let controlSecure = FnTool(ToolSpec(name: "home_control_secure", description: "开锁/上锁、开关车库门等安全相关操作（需要用户确认）", parameters: [
        "accessoryId": ParamSpec(.string, "home_list 返回的 id", maxLength: 60),
        "lock": ParamSpec(.boolean, "true 上锁 / false 开锁", required: false),
        "open": ParamSpec(.boolean, "true 打开 / false 关闭（车库门）", required: false)
    ], permission: .confirmBeforeAction, capability: .home, systemPermission: .homeKit, dataClass: .personal, timeoutSeconds: 20),
    describe: { a in "\(a.flag("lock").map { $0 ? "上锁" : "开锁" } ?? a.flag("open").map { $0 ? "打开" : "关闭" } ?? "控制") 设备 \(a.str("accessoryId") ?? "")" }) { a, _ in
        #if os(iOS)
        return try await MainActor.run { Task { @MainActor in try await apply(a, secure: true) } }.value
        #else
        throw fail("此平台不支持“家庭”")
        #endif
    }

    static let scene = FnTool(ToolSpec(name: "home_run_scene", description: "执行“家庭”场景（需要用户确认）", parameters: [
        "sceneId": ParamSpec(.string, "home_list 返回的场景 id", maxLength: 60)
    ], permission: .confirmBeforeAction, capability: .home, systemPermission: .homeKit, dataClass: .personal, timeoutSeconds: 30),
    describe: { a in "执行家庭场景 \(a.str("sceneId") ?? "")" }) { a, _ in
        #if os(iOS)
        return try await MainActor.run { Task { @MainActor in
            let homes = await HomeAccess.shared.homes()
            guard let id = a.str("sceneId"), let (home, set) = homes.lazy.compactMap({ h in h.actionSets.first { $0.uniqueIdentifier.uuidString == id }.map { (h, $0) } }).first
            else { throw fail("找不到这个场景") }
            try await home.executeActionSet(set)
            return out(["scene": .string(set.name)], "已执行场景「\(set.name)」")
        } }.value
        #else
        throw fail("此平台不支持“家庭”")
        #endif
    }
}

enum AppLinks {
    struct App { let id: String; let name: String; let open: String; let search: String?; let scan: String? }
    /// Public URL schemes of common apps in China. Opening another app is the only supported integration path; their data
    /// and in-app actions are not readable by iTalk.
    static let apps: [App] = [
        .init(id: "wechat", name: "微信", open: "weixin://", search: nil, scan: "weixin://scanqrcode"),
        .init(id: "alipay", name: "支付宝", open: "alipay://", search: nil, scan: "alipays://platformapi/startapp?saId=10000007"),
        .init(id: "amap", name: "高德地图", open: "iosamap://", search: "iosamap://poi?sourceApplication=iTalk&name=%@", scan: nil),
        .init(id: "baidumap", name: "百度地图", open: "baidumap://", search: "baidumap://map/place/search?query=%@&src=ios.italk.assistant", scan: nil),
        .init(id: "taobao", name: "淘宝", open: "taobao://", search: "taobao://s.taobao.com/search?q=%@", scan: nil),
        .init(id: "jd", name: "京东", open: "openapp.jdmobile://", search: nil, scan: nil),
        .init(id: "meituan", name: "美团", open: "imeituan://", search: nil, scan: nil),
        .init(id: "dianping", name: "大众点评", open: "dianping://", search: nil, scan: nil),
        .init(id: "eleme", name: "饿了么", open: "eleme://", search: nil, scan: nil),
        .init(id: "didi", name: "滴滴出行", open: "diditaxi://", search: nil, scan: nil),
        .init(id: "douyin", name: "抖音", open: "snssdk1128://", search: nil, scan: nil),
        .init(id: "bilibili", name: "哔哩哔哩", open: "bilibili://", search: "bilibili://search?keyword=%@", scan: nil),
        .init(id: "weibo", name: "微博", open: "sinaweibo://", search: nil, scan: nil),
        .init(id: "xiaohongshu", name: "小红书", open: "xhsdiscover://", search: "xhsdiscover://search/result?keyword=%@", scan: nil),
        .init(id: "zhihu", name: "知乎", open: "zhihu://", search: "zhihu://search?q=%@", scan: nil),
        .init(id: "qq", name: "QQ", open: "mqq://", search: nil, scan: nil),
        .init(id: "qqmusic", name: "QQ 音乐", open: "qqmusic://", search: nil, scan: nil),
        .init(id: "neteasemusic", name: "网易云音乐", open: "orpheus://", search: nil, scan: nil),
        .init(id: "dingtalk", name: "钉钉", open: "dingtalk://", search: nil, scan: nil),
        .init(id: "feishu", name: "飞书", open: "lark://", search: nil, scan: nil),
        .init(id: "ctrip", name: "携程", open: "ctrip://", search: nil, scan: nil),
        .init(id: "pinduoduo", name: "拼多多", open: "pinduoduo://", search: nil, scan: nil),
        .init(id: "settings", name: "iTalk 设置", open: "app-settings:", search: nil, scan: nil),
        .init(id: "shortcuts", name: "快捷指令", open: "shortcuts://", search: nil, scan: nil),
        .init(id: "music", name: "音乐", open: "music://", search: "music://music.apple.com/search?term=%@", scan: nil),
        .init(id: "maps", name: "地图", open: "maps://", search: "maps://?q=%@", scan: nil),
        .init(id: "camera", name: "相机", open: "camera://", search: nil, scan: nil),
    ]
    /// For Info.plist `LSApplicationQueriesSchemes` (canOpenURL needs them declared).
    public static var querySchemes: [String] { apps.compactMap { URL(string: $0.open)?.scheme }.filter { !["app-settings", "music", "maps"].contains($0) } + ["alipays", "facetime-audio"] }

    static func open(_ ctx: AppleSkillContext) -> FnTool {
        FnTool(ToolSpec(name: "app_open", description: "打开其他 App（可直接进入搜索或扫一扫）。支持：" + apps.map { "\($0.id)（\($0.name)）" }.joined(separator: "、"), parameters: [
            "app": ParamSpec(.string, "App id", enumValues: apps.map(\.id)),
            "action": ParamSpec(.string, "默认 open", required: false, enumValues: ["open", "search", "scan"]),
            "query": ParamSpec(.string, "搜索内容（action=search）", required: false, maxLength: 100)
        ], permission: .lowRiskAction, capability: .apps)) { a, _ in
            guard let app = apps.first(where: { $0.id == a.str("app") }) else { throw fail("不支持这个 App") }
            var link = app.open
            switch a.str("action") ?? "open" {
            case "search":
                guard let tpl = app.search else { throw fail("\(app.name) 不提供公开的搜索入口，只能打开 App") }
                link = String(format: tpl, (a.str("query") ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
            case "scan":
                guard let s = app.scan else { throw fail("\(app.name) 不提供公开的扫一扫入口") }
                link = s
            default: break
            }
            let url = app.id == "settings" ? URL(string: "app-settings:")! : URL(string: link)!
            let builtIn = ["settings", "music", "maps", "camera", "shortcuts"].contains(app.id)
            let installed = await ctx.presenter.canOpen(url)
            guard builtIn || installed else { throw fail("没有安装\(app.name)") }
            let ok = await ctx.presenter.open(url)
            return out(["opened": .bool(ok), "app": .string(app.name)], ok ? "已打开\(app.name)" : "未能打开\(app.name)")
        }
    }

    static func openURL(_ ctx: AppleSkillContext) -> FnTool {
        FnTool(ToolSpec(name: "open_link", description: "在 Safari 或对应 App 中打开一个网址/通用链接（需要用户确认）", parameters: [
            "url": ParamSpec(.string, "https 网址", maxLength: 2000)
        ], permission: .confirmBeforeAction, capability: .apps),
        describe: { a in "打开链接 \(a.str("url") ?? "")" }) { a, _ in
            guard let s = a.str("url"), let url = URL(string: s), url.scheme == "https" || url.scheme == "http" else { throw fail("只能打开 http/https 链接") }
            if let why = WebSafety.check(url) { throw fail(why) }
            let ok = await ctx.presenter.open(url)
            return out(["opened": .bool(ok)], ok ? "已打开链接" : "未能打开")
        }
    }

    static func shortcut(_ ctx: AppleSkillContext) -> FnTool {
        FnTool(ToolSpec(name: "shortcut_run", description: "运行用户“快捷指令”App 中的一条快捷指令（需要用户确认，快捷指令可执行任何操作）", parameters: [
            "name": ParamSpec(.string, "快捷指令名称（必须与“快捷指令”App 中一致）", maxLength: 100),
            "input": ParamSpec(.string, "传入的文字", required: false, maxLength: 2000)
        ], permission: .confirmBeforeAction, capability: .shortcuts),
        describe: { a in "运行快捷指令「\(a.str("name") ?? "")」" }) { a, _ in
            guard let name = a.str("name") else { throw fail("缺少名称") }
            var c = URLComponents(string: "shortcuts://run-shortcut")!
            c.queryItems = [URLQueryItem(name: "name", value: name)]
            if let input = a.str("input") { c.queryItems! += [URLQueryItem(name: "input", value: "text"), URLQueryItem(name: "text", value: input)] }
            let ok = await ctx.presenter.open(c.url!)
            return out(["started": .bool(ok), "note": .string("快捷指令在“快捷指令”App 中运行，结果不会自动返回给 iTalk；找不到同名指令时“快捷指令”会提示。")],
                       ok ? "已运行快捷指令「\(name)」" : "无法打开快捷指令")
        }
    }
}

enum LanguageSkills {
    static let translate = FnTool(ToolSpec(name: "translate_text", description: "用 Apple 设备端翻译把文字译成目标语言（离线，需已下载对应语言）", parameters: [
        "text": ParamSpec(.string, "要翻译的文字", maxLength: 5000),
        "to": ParamSpec(.string, "目标语言代码，如 zh-Hans、en、ja、ko、fr、de、es", maxLength: 10),
        "from": ParamSpec(.string, "源语言代码，省略则自动识别", required: false, maxLength: 10)
    ], permission: .readOnly, capability: .translation, timeoutSeconds: 30)) { a, _ in
        guard let text = a.str("text"), let to = a.str("to") else { throw fail("需要文字和目标语言") }
        let source: Locale.Language
        if let f = a.str("from") { source = Locale.Language(identifier: f) }
        else {
            let r = NLLanguageRecognizer(); r.processString(text)
            guard let l = r.dominantLanguage else { throw fail("无法识别源语言，请指定 from") }
            source = Locale.Language(identifier: l.rawValue)
        }
        let target = Locale.Language(identifier: to)
        switch await LanguageAvailability().status(from: source, to: target) {
        case .unsupported: throw fail("Apple 翻译不支持 \(source.minimalIdentifier) → \(to)")
        case .supported: throw fail("需要先下载翻译语言：设置 › App › 翻译 › 下载语言（\(source.minimalIdentifier)、\(to)）。下载后离线可用。")
        default: break
        }
        let session = TranslationSession(installedSource: source, target: target)
        let r = try await session.translate(text)
        return out(["translation": .string(r.targetText), "from": .string(r.sourceLanguage.minimalIdentifier), "to": .string(r.targetLanguage.minimalIdentifier)], "已翻译")
    }

    static let analyze = FnTool(ToolSpec(name: "text_analyze", description: "设备端文本分析：识别语言、分词、情感倾向、人名/地名/机构名", parameters: [
        "text": ParamSpec(.string, "文字", maxLength: 10_000),
        "tasks": ParamSpec(.array, "language / tokens / sentiment / entities，默认全部", required: false)
    ], permission: .readOnly, capability: .language)) { a, _ in
        guard let text = a.str("text") else { throw fail("缺少文字") }
        let tasks = Set(a.strings("tasks").isEmpty ? ["language", "tokens", "sentiment", "entities"] : a.strings("tasks"))
        var o: [String: JSONValue] = [:]
        let rec = NLLanguageRecognizer(); rec.processString(text)
        if tasks.contains("language") {
            o["languages"] = .array(rec.languageHypotheses(withMaximum: 3).sorted { $0.value > $1.value }.map { .object(["language": .string($0.key.rawValue), "p": .number((Double($0.value) * 100).rounded() / 100)]) })
        }
        if tasks.contains("tokens") {
            let tok = NLTokenizer(unit: .word); tok.string = text
            o["tokens"] = .array(tok.tokens(for: text.startIndex..<text.endIndex).prefix(300).map { .string(String(text[$0])) })
        }
        if tasks.contains("sentiment") {
            let t = NLTagger(tagSchemes: [.sentimentScore]); t.string = text
            let (tag, _) = t.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore)
            o["sentiment"] = .number(Double(tag?.rawValue ?? "0") ?? 0)
        }
        if tasks.contains("entities") {
            let t = NLTagger(tagSchemes: [.nameType]); t.string = text
            if let l = rec.dominantLanguage { t.setLanguage(l, range: text.startIndex..<text.endIndex) }
            var ents: [JSONValue] = []
            t.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, r in
                if let tag, [NLTag.personalName, .placeName, .organizationName].contains(tag) {
                    ents.append(.object(["text": .string(String(text[r])), "type": .string(tag.rawValue)]))
                }
                return ents.count < 100
            }
            o["entities"] = .array(ents)
        }
        return out(o, "已分析文本")
    }
}

enum MiscSkills {
    static func conversations(_ ctx: AppleSkillContext) -> FnTool {
        FnTool(ToolSpec(name: "conversations_search", description: "搜索用户以前在 iTalk 中的对话（标题与内容）", parameters: [
            "query": ParamSpec(.string, "关键词", maxLength: 100)
        ], permission: .readOnly, capability: .spotlight, dataClass: .personal)) { a, _ in
            guard let q = a.str("query") else { throw fail("缺少关键词") }
            let hits = await ctx.searchConversations(q)
            return out(["results": .array(hits.prefix(10).map { .object(["id": .string($0.id.uuidString), "title": .string($0.title), "snippet": .string($0.snippet)]) }),
                        "note": .string("只能搜索 iTalk 自己的内容；系统“聚焦”中其他 App 的内容不对第三方开放。")], "找到 \(hits.count) 段对话")
        }
    }

    static let widgets = FnTool(ToolSpec(name: "widgets_refresh", description: "刷新 iTalk 的小组件和控制中心控件", permission: .lowRiskAction, capability: .widgets)) { _, _ in
        WidgetCenter.shared.reloadAllTimelines()
        return out(["refreshed": .bool(true)], "已刷新小组件")
    }

    static let watch = FnTool(ToolSpec(name: "watch_status", description: "Apple Watch 状态：是否配对、是否安装 iTalk、当前能否连接", permission: .readOnly, capability: .watch)) { _, _ in
        #if os(iOS)
        guard WCSession.isSupported() else { return out(["supported": .bool(false)], "此设备不支持 Apple Watch") }
        let s = WCSession.default
        return out(["paired": .bool(s.isPaired), "iTalkInstalled": .bool(s.isWatchAppInstalled), "reachable": .bool(s.isReachable),
                    "note": .string("iPhone 锁定时 iTalk 的通知会显示在手表上（notification_schedule）。手表的健康数据通过 health_* 工具读取。")],
                   s.isPaired ? "已配对 Apple Watch" : "没有配对的 Apple Watch")
        #else
        throw fail("此平台不支持")
        #endif
    }
}
