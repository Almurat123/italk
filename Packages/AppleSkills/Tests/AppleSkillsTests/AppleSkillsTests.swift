import Foundation
import Testing
import CoreText
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import AppleSkills
@testable import AgentRuntime

struct NoUI: SystemPresenter {
    @MainActor func open(_ url: URL) async -> Bool { false }
    @MainActor func canOpen(_ url: URL) -> Bool { false }
    @MainActor func composeMessage(recipients: [String], body: String) async -> String { "unavailable" }
    @MainActor func composeMail(to: [String], subject: String, body: String) async -> String { "unavailable" }
    @MainActor func capturePhoto() async -> URL? { nil }
    @MainActor func pickDocument() async -> URL? { nil }
    @MainActor func share(_ file: URL) async -> Bool { false }
    @MainActor func setScreenBrightness(_ value: Double) -> Bool { false }
    @MainActor func screenBrightness() -> Double? { nil }
}

func tempRoot() -> URL {
    let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("italk-files-\(UUID())")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
func installed(_ root: URL = tempRoot()) -> (ToolRegistry, SkillCatalog, AppleSkillContext) {
    var reg = ToolRegistry(), cat = SkillCatalog([])
    let ctx = AppleSkillContext(presenter: NoUI(), filesRoot: root)
    AppleSkills.install(into: &reg, catalog: &cat, context: ctx)
    return (reg, cat, ctx)
}
let tctx = ToolContext(runId: UUID(), callId: "c1", idempotencyKey: "test/\(UUID())", now: .now)

@Test func everyAdvertisedToolHasAnExecutorAndEveryToolIsInASkill() {
    let (reg, cat, _) = installed()
    var advertised = Set<String>()
    for s in cat.skills {
        #expect(!s.toolNames.isEmpty && !s.summary.isEmpty && !s.instructions.isEmpty, "\(s.id)")
        for t in s.toolNames { advertised.insert(t); #expect(reg.tool(named: t) != nil, "\(s.id) advertises \(t) without an executor") }
    }
    for name in reg.names { #expect(advertised.contains(name), "\(name) is registered but no skill explains it") }
    #expect(cat.skills.count >= 28 && reg.names.count >= 60)
    // Personal/sensitive data is classified so it can be withheld from cloud models.
    for name in ["calendar_list_events", "contacts_search", "location_current", "photos_search", "files_read"] {
        #expect(reg.tool(named: name)?.spec.dataClass == .personal, "\(name)")
    }
    #expect(reg.tool(named: "health_query")?.spec.dataClass == .sensitive)
    // Destructive or outward actions need confirmation.
    for name in ["calendar_create_event", "calendar_delete_event", "contacts_create", "phone_call", "files_delete", "home_control_secure", "shortcut_run", "open_link"] {
        #expect(reg.tool(named: name)?.spec.permission == .confirmBeforeAction, "\(name)")
    }
}

@Test func catalogTextFitsInEveryPromptAndReadingShowsSchemas() {
    let (reg, cat, _) = installed()
    var all = SkillCatalog.standard; all.add(WebSkill.skill); all.add(cat.skills)
    let text = all.catalogText()
    print("CATALOG skills=\(all.skills.count) appleTools=\(reg.names.count) chars=\(text.count)")
    #expect(text.count < 2600, "catalog is always in context: \(text.count) chars")
    let read = all.readText(all.skill("calendar")!, tools: reg)
    #expect(read.contains("calendar_create_event（执行前需用户确认）") && read.contains("start: string"))
}

@Test func alarmSkillExplainsTimerAndClockArguments() throws {
    let (registry, catalog, _) = installed()
    let skill = try #require(catalog.skill("alarms"))
    let text = catalog.readText(skill, tools: registry)
    #expect(text.contains("timer_start") && text.contains("\"seconds\":15"))
    #expect(text.contains("alarm_set") && text.contains("\"time\":\"07:00\""))
    try registry.tool(named: "timer_start")!.spec.validate(.object(["seconds": .number(15)]))
    try registry.tool(named: "alarm_set")!.spec.validate(.object(["time": .string("07:00")]))
}

@Test func argumentDatesAreParsedInLocalTime() {
    let tz = TimeZone(identifier: "Asia/Shanghai")!
    let now = ISO8601DateFormatter().date(from: "2026-10-27T10:00:00+08:00")!
    #expect(ArgDate.iso(ArgDate.parse("2026-10-28 15:30", now: now, tz: tz)!, tz: tz) == "2026-10-28T15:30:00+08:00")
    #expect(ArgDate.iso(ArgDate.parse("09:00", now: now, tz: tz)!, tz: tz) == "2026-10-28T09:00:00+08:00", "past clock time → tomorrow")
    #expect(ArgDate.iso(ArgDate.parse("2026-10-27T18:00:00+08:00", now: now)!, tz: tz) == "2026-10-27T18:00:00+08:00")
    #expect(ArgDate.parse("下周", now: now) == nil)
    #expect(stableUUID("a/b") == stableUUID("a/b") && stableUUID("a/b") != stableUUID("a/c"))
}

@Test func fileToolsNeverLeaveTheITalkFolder() async throws {
    let root = tempRoot()
    for bad in ["../etc/passwd", "a/../../x", "", ".", "./x"] { #expect(throws: ToolFailure.self) { try FileSkills.resolve(bad, root: root) } }
    // An absolute-looking path is taken relative to the iTalk folder, never the real system path.
    #expect(try FileSkills.resolve("/etc/hosts", root: root).path.hasPrefix(root.resolvingSymlinksInPath().path))
    let (reg, _, _) = installed(root)
    _ = try await reg.tool(named: "files_write")!.execute(.object(["path": .string("笔记/清单.md"), "content": .string("牛奶\n鸡蛋")]), context: tctx)
    let r = try await reg.tool(named: "files_read")!.execute(.object(["path": .string("笔记/清单.md")]), context: tctx)
    #expect(r.value["text"]?.string == "牛奶\n鸡蛋")
    let l = try await reg.tool(named: "files_list")!.execute(.object(["folder": .string("笔记")]), context: tctx)
    #expect(l.value["files"]?.array?.first?["path"]?.string == "笔记/清单.md")
    _ = try await reg.tool(named: "files_delete")!.execute(.object(["path": .string("笔记/清单.md")]), context: tctx)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("笔记/清单.md").path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("最近删除").path).count == 1, "recoverable, not destroyed")
}

@Test func pdfIsCreatedReadAndSearched() async throws {
    let root = tempRoot()
    let (reg, _, _) = installed(root)
    let body = (1...80).map { "第\($0)条：会议纪要内容，讨论预算与排期。" }.joined(separator: "\n") + "\n结论：周五前提交方案。"
    let c = try await reg.tool(named: "pdf_create")!.execute(.object(["name": .string("纪要"), "title": .string("项目会议纪要"), "text": .string(body)]), context: tctx)
    #expect((c.value["pages"]?.number ?? 0) >= 2)
    let r = try await reg.tool(named: "pdf_read")!.execute(.object(["path": .string("文档/纪要.pdf")]), context: tctx)
    #expect(r.value["text"]?.string?.contains("项目会议纪要") == true)
    let s = try await reg.tool(named: "pdf_search")!.execute(.object(["path": .string("文档/纪要.pdf"), "query": .string("周五前提交")]), context: tctx)
    #expect(s.value["matches"]?.array?.isEmpty == false)
}

func renderText(_ text: String) -> Data {
    let w = 900, h = 260
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, 56, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1)]))
    ctx.textPosition = CGPoint(x: 40, y: 100); CTLineDraw(line, ctx)
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
    return data as Data
}

@Test func visionReadsChineseTextOnDevice() async throws {
    let root = tempRoot()
    try renderText("杭州西湖 营业时间 9:00").write(to: root.appendingPathComponent("sign.png"))
    let (reg, _, _) = installed(root)
    let r = try await reg.tool(named: "vision_analyze_image")!.execute(.object(["source": .string("file:sign.png"), "tasks": .array([.string("text")])]), context: tctx)
    let text = r.value["analysis"]?["text"]?.string ?? ""
    print("OCR:", text)
    #expect(text.contains("西湖") && text.contains("9:00"))
}

@Test func textAnalysisDetectsLanguageAndNames() async throws {
    let (reg, _, _) = installed()
    let r = try await reg.tool(named: "text_analyze")!.execute(.object(["text": .string("明天我和王小明去北京开会。"), "tasks": .array([.string("language"), .string("tokens")])]), context: tctx)
    #expect(r.value["languages"]?.array?.first?["language"]?.string == "zh-Hans")
    #expect((r.value["tokens"]?.array?.count ?? 0) >= 5)
}

@Test func appLinksAreValidURLsAndDeclaredForQueries() {
    for app in AppLinks.apps { #expect(URL(string: app.open) != nil, "\(app.id)") }
    #expect(AppLinks.querySchemes.contains("weixin") && AppLinks.querySchemes.contains("iosamap") && AppLinks.querySchemes.count <= 50)
}

@Test func permissionAuthorityRespectsITalkSwitches() async {
    let auth = ApplePermissionAuthority(switches: { $0 != .health })
    let runtime = await auth.isEnabled(.runtime), calendar = await auth.isEnabled(.calendar), health = await auth.isEnabled(.health)
    let none = await auth.status(.none)
    #expect(runtime && calendar && !health && none == .granted)
    let v = await PermissionGate.evaluate(HealthSkills.query.spec, authority: auth, mayRequest: false)
    #expect(!v.allowed && v.recovery == .enableInITalk)
}

/// ITALK_LIVE_WEB=1 swift test --filter liveWeather
@Test(.enabled(if: ProcessInfo.processInfo.environment["ITALK_LIVE_WEB"] != nil))
func liveWeather() async throws {
    let (reg, _, _) = installed()
    let r = try await reg.tool(named: "weather_forecast")!.execute(.object(["place": .string("杭州"), "days": .number(2)]), context: tctx)
    print("WEATHER", r.summary, r.value["daily"]?.array?.count ?? 0, r.value["air"]?.compactString ?? "-")
    #expect(r.value["daily"]?.array?.count == 2)
}
