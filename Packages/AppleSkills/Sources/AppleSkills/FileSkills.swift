import Foundation
import AgentRuntime
import PDFKit
import CoreText
import AVFoundation
import Speech
import UniformTypeIdentifiers

enum FileSkills {
    /// A path inside the iTalk files folder. Never escapes it (no "..", no absolute paths, no symlinks out).
    static func resolve(_ path: String, root: URL) throws -> URL {
        let clean = path.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        guard !clean.isEmpty, !clean.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { throw fail("路径无效") }
        let url = root.appendingPathComponent(clean).standardizedFileURL.resolvingSymlinksInPath()
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard url.path == base || url.path.hasPrefix(base + "/") else { throw fail("只能访问 iTalk 文件夹中的文件") }
        return url
    }
    static func rel(_ url: URL, root: URL) -> String {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        return String(url.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    static let textTypes: Set<String> = ["txt", "md", "markdown", "csv", "tsv", "json", "xml", "html", "htm", "log", "yaml", "yml", "swift", "py", "js", "ts", "srt", "vtt"]

    static func list(_ ctx: AppleSkillContext) -> FnTool {
        FnTool(ToolSpec(name: "files_list", description: "列出 iTalk 文件夹（“文件”App › 我的 iPhone › iTalk）中的文件", parameters: [
            "folder": ParamSpec(.string, "子文件夹，默认根目录", required: false, maxLength: 200),
            "query": ParamSpec(.string, "按文件名筛选", required: false, maxLength: 60)
        ], permission: .readOnly, capability: .files, dataClass: .personal)) { a, _ in
            let dir = a.str("folder").map { try? resolve($0, root: ctx.filesRoot) } ?? ctx.filesRoot
            guard let dir else { throw fail("文件夹无效") }
            try FileManager.default.createDirectory(at: ctx.filesRoot, withIntermediateDirectories: true)
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
            var items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            if let q = a.str("query")?.lowercased() { items = items.filter { $0.lastPathComponent.lowercased().contains(q) } }
            let list: [JSONValue] = items.prefix(200).map { u in
                let v = try? u.resourceValues(forKeys: Set(keys))
                return .object(["path": .string(rel(u, root: ctx.filesRoot)), "folder": .bool(v?.isDirectory ?? false),
                                "bytes": .number(Double(v?.fileSize ?? 0)), "modified": .string(v?.contentModificationDate.map { ArgDate.iso($0) } ?? "")])
            }
            return out(["files": .array(list), "note": .string("其他 App 的文件需用户通过 files_import 选择后才可访问。")], "\(list.count) 个项目")
        }
    }

    static func readText(_ ctx: AppleSkillContext) -> FnTool {
        FnTool(ToolSpec(name: "files_read", description: "读取 iTalk 文件夹中的文本文件或 PDF 的文字", parameters: [
            "path": ParamSpec(.string, "相对路径", maxLength: 300),
            "offset": ParamSpec(.integer, "起始字符", required: false, minimum: 0)
        ], permission: .readOnly, capability: .files, dataClass: .personal)) { a, _ in
            let url = try resolve(a.str("path") ?? "", root: ctx.filesRoot)
            let ext = url.pathExtension.lowercased()
            let text: String
            if ext == "pdf" { text = try PDFSkills.text(url, pages: nil) }
            else if textTypes.contains(ext) || ext.isEmpty {
                let data = try Data(contentsOf: url)
                guard data.count <= 20_000_000 else { throw fail("文件太大") }
                text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            } else if ["rtf", "rtfd", "doc", "docx", "odt", "webarchive"].contains(ext),
                      let s = try? NSAttributedString(url: url, options: [:], documentAttributes: nil).string { text = s }
            else { throw fail("不支持读取 .\(ext) 文件的文字") }
            let chars = Array(text), start = min(a.int("offset") ?? 0, chars.count), end = min(chars.count, start + 6000)
            var o: [String: JSONValue] = ["path": .string(rel(url, root: ctx.filesRoot)), "text": .string(String(chars[start..<end])), "totalCharacters": .number(Double(chars.count))]
            if end < chars.count { o["more"] = .string("继续：offset \(end)") }
            return out(o, "已读取 \(url.lastPathComponent)")
        }
    }

    static func write(_ ctx: AppleSkillContext) -> FnTool {
        FnTool(ToolSpec(name: "files_write", description: "在 iTalk 文件夹中新建或覆盖一个文本文件（覆盖已有文件需用户确认）", parameters: [
            "path": ParamSpec(.string, "相对路径，如 笔记/购物清单.md", maxLength: 300),
            "content": ParamSpec(.string, "内容", maxLength: 200_000),
            "append": ParamSpec(.boolean, "追加到末尾", required: false)
        ], permission: .confirmBeforeAction, capability: .files, dataClass: .personal),
        describe: { a in "\(a.flag("append") == true ? "追加到" : "写入")文件「\(a.str("path") ?? "")」（\(a.str("content")?.count ?? 0) 字）" }) { a, _ in
            let url = try resolve(a.str("path") ?? "", root: ctx.filesRoot)
            guard textTypes.contains(url.pathExtension.lowercased()) || url.pathExtension.isEmpty else { throw fail("只能写入文本文件") }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let content = a.str("content") ?? ""
            if a.flag("append") == true, let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }; _ = try h.seekToEnd(); try h.write(contentsOf: Data(("\n" + content).utf8))
            } else { try Data(content.utf8).write(to: url, options: .atomic) }
            return out(["path": .string(rel(url, root: ctx.filesRoot))], "已保存 \(url.lastPathComponent)")
        }
    }

    static func importFile(_ ctx: AppleSkillContext) -> FnTool {
        FnTool(ToolSpec(name: "files_import", description: "让用户从“文件”App（iCloud 云盘、其他 App 的文件）选择一个文件导入 iTalk", permission: .lowRiskAction,
                        capability: .files, dataClass: .personal, timeoutSeconds: 600)) { _, _ in
            guard let picked = await ctx.presenter.pickDocument() else { return out(["imported": .bool(false)], "用户取消了选择") }
            let dir = ctx.filesRoot.appendingPathComponent("导入", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var dest = dir.appendingPathComponent(picked.lastPathComponent)
            var n = 1
            while FileManager.default.fileExists(atPath: dest.path) { n += 1; dest = dir.appendingPathComponent("\(picked.deletingPathExtension().lastPathComponent) \(n).\(picked.pathExtension)") }
            try FileManager.default.copyItem(at: picked, to: dest)
            return out(["imported": .bool(true), "path": .string(rel(dest, root: ctx.filesRoot))], "已导入 \(dest.lastPathComponent)")
        }
    }

    static func share(_ ctx: AppleSkillContext) -> FnTool {
        FnTool(ToolSpec(name: "files_share", description: "用系统分享面板分享 iTalk 文件夹中的文件（发给微信、AirDrop、存储到其他位置等）", parameters: [
            "path": ParamSpec(.string, "相对路径", maxLength: 300)
        ], permission: .lowRiskAction, capability: .files, dataClass: .personal, timeoutSeconds: 600)) { a, _ in
            let url = try resolve(a.str("path") ?? "", root: ctx.filesRoot)
            guard FileManager.default.fileExists(atPath: url.path) else { throw fail("文件不存在") }
            let ok = await ctx.presenter.share(url)
            return out(["shared": .bool(ok)], ok ? "已分享" : "未分享")
        }
    }

    static func delete(_ ctx: AppleSkillContext) -> FnTool {
        FnTool(ToolSpec(name: "files_delete", description: "把 iTalk 文件夹中的文件移到“最近删除”（需要用户确认，可恢复）", parameters: [
            "path": ParamSpec(.string, "相对路径", maxLength: 300)
        ], permission: .confirmBeforeAction, capability: .files, dataClass: .personal),
        describe: { a in "删除文件「\(a.str("path") ?? "")」（移到 iTalk › 最近删除，可恢复）" }) { a, _ in
            let url = try resolve(a.str("path") ?? "", root: ctx.filesRoot)
            guard FileManager.default.fileExists(atPath: url.path) else { return out(["deleted": .bool(true), "note": .string("文件已不存在")], "文件已不存在") }
            let bin = ctx.filesRoot.appendingPathComponent("最近删除", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let dest = bin.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(url.lastPathComponent)")
            try FileManager.default.moveItem(at: url, to: dest)
            return out(["deleted": .bool(true), "recoverableAt": .string(rel(dest, root: ctx.filesRoot))], "已移到最近删除")
        }
    }
}

enum PDFSkills {
    static func text(_ url: URL, pages: ClosedRange<Int>?) throws -> String {
        guard let doc = PDFDocument(url: url) else { throw fail("无法打开 PDF（可能已加密）") }
        let range = pages.map { max(1, $0.lowerBound)...min(doc.pageCount, $0.upperBound) } ?? 1...max(1, doc.pageCount)
        guard doc.pageCount > 0 else { return "" }
        return range.compactMap { doc.page(at: $0 - 1)?.string.map { "【第\($0)页】\n" + $0 } }.joined(separator: "\n")
    }

    static func source(_ a: JSONValue, ctx: AppleSkillContext) async throws -> URL {
        if let id = a.str("attachment").flatMap(UUID.init(uuidString:)), let u = await ctx.attachmentURL(id) { return u }
        return try FileSkills.resolve(a.str("path") ?? "", root: ctx.filesRoot)
    }

    static func extract(_ ctx: AppleSkillContext) -> FnTool {
        FnTool(ToolSpec(name: "pdf_read", description: "读取 PDF 的页数、标题和指定页的文字", parameters: [
            "path": ParamSpec(.string, "iTalk 文件中的 PDF 路径", required: false, maxLength: 300),
            "attachment": ParamSpec(.string, "或：对话附件 id", required: false, maxLength: 40),
            "fromPage": ParamSpec(.integer, "起始页，默认 1", required: false, minimum: 1),
            "toPage": ParamSpec(.integer, "结束页，默认起始页后 9 页", required: false, minimum: 1)
        ], permission: .readOnly, capability: .documents, dataClass: .personal, timeoutSeconds: 30)) { a, _ in
            let url = try await source(a, ctx: ctx)
            guard let doc = PDFDocument(url: url) else { throw fail("无法打开 PDF") }
            let from = a.int("fromPage") ?? 1, to = a.int("toPage") ?? from + 9
            let t = try text(url, pages: from...max(from, to))
            return out(["pages": .number(Double(doc.pageCount)), "title": .string(doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String ?? url.lastPathComponent),
                        "text": .string(String(t.prefix(12_000))), "range": .string("\(from)-\(min(to, doc.pageCount))")], "已读取 PDF（共 \(doc.pageCount) 页）")
        }
    }

    static func search(_ ctx: AppleSkillContext) -> FnTool {
        FnTool(ToolSpec(name: "pdf_search", description: "在 PDF 中查找文字，返回所在页和上下文", parameters: [
            "path": ParamSpec(.string, "PDF 路径", required: false, maxLength: 300),
            "attachment": ParamSpec(.string, "或：附件 id", required: false, maxLength: 40),
            "query": ParamSpec(.string, "要查找的文字", maxLength: 100)
        ], permission: .readOnly, capability: .documents, dataClass: .personal, timeoutSeconds: 30)) { a, _ in
            let url = try await source(a, ctx: ctx)
            guard let doc = PDFDocument(url: url), let q = a.str("query") else { throw fail("无法打开 PDF 或缺少查找内容") }
            let hits = doc.findString(q, withOptions: [.caseInsensitive]).prefix(20).compactMap { sel -> JSONValue? in
                guard let page = sel.pages.first else { return nil }
                let ext = sel.copy() as! PDFSelection; ext.extend(atStart: 60); ext.extend(atEnd: 60)
                return .object(["page": .number(Double(doc.index(for: page) + 1)), "context": .string(ext.string ?? "")])
            }
            return out(["matches": .array(hits)], "找到 \(hits.count) 处")
        }
    }

    /// Text → paginated A4 PDF with CoreText (works on iPhone and Mac; no UIKit).
    static func render(title: String, body: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let pdf = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle: title] as CFDictionary) else { return Data() }
        let full = NSMutableAttributedString()
        let titleFont = CTFontCreateWithName("PingFangSC-Semibold" as CFString, 20, nil), bodyFont = CTFontCreateWithName("PingFangSC-Regular" as CFString, 12, nil)
        full.append(NSAttributedString(string: title + "\n\n", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): titleFont]))
        full.append(NSAttributedString(string: body, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): bodyFont]))
        let setter = CTFramesetterCreateWithAttributedString(full)
        var pos = 0
        while pos < full.length {
            pdf.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: pos, length: 0), CGPath(rect: box.insetBy(dx: 56, dy: 64), transform: nil), nil)
            CTFrameDraw(frame, pdf)
            pdf.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame).length
            if visible == 0 { break }
            pos += visible
        }
        pdf.closePDF()
        return data as Data
    }

    static func create(_ ctx: AppleSkillContext) -> FnTool {
        FnTool(ToolSpec(name: "pdf_create", description: "把文字生成 PDF 保存到 iTalk 文件夹（之后可用 files_share 分享）", parameters: [
            "name": ParamSpec(.string, "文件名（不含扩展名）", maxLength: 80),
            "title": ParamSpec(.string, "标题", maxLength: 120),
            "text": ParamSpec(.string, "正文", maxLength: 200_000)
        ], permission: .lowRiskAction, capability: .documents, dataClass: .personal)) { a, _ in
            guard let name = a.str("name"), !name.contains("/") else { throw fail("文件名无效") }
            let url = try FileSkills.resolve("文档/\(name).pdf", root: ctx.filesRoot)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = render(title: a.str("title") ?? name, body: a.str("text") ?? "")
            try data.write(to: url, options: .atomic)
            let pages = PDFDocument(data: data)?.pageCount ?? 0
            return out(["path": .string(FileSkills.rel(url, root: ctx.filesRoot)), "pages": .number(Double(pages))], "已生成 \(name).pdf（\(pages) 页）")
        }
    }
}

enum AudioSkills {
    static func transcribe(_ ctx: AppleSkillContext) -> FnTool {
        FnTool(ToolSpec(name: "audio_transcribe", description: "在设备上把录音/音频文件转成文字（普通话或英语）", parameters: [
            "path": ParamSpec(.string, "iTalk 文件中的音频路径（m4a/mp3/wav/caf）", maxLength: 300),
            "language": ParamSpec(.string, "默认 zh-CN", required: false, enumValues: ["zh-CN", "en-US", "zh-TW", "yue-CN"])
        ], permission: .readOnly, capability: .audio, dataClass: .personal, timeoutSeconds: 600)) { a, _ in
            let url = try FileSkills.resolve(a.str("path") ?? "", root: ctx.filesRoot)
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: a.str("language") ?? "zh-CN")) else { throw fail("不支持该语言的设备端转写") }
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await install.downloadAndInstall() }
            let file = try AVAudioFile(forReading: url)
            let collect = Task { () -> String in
                var text = ""
                for try await r in transcriber.results where r.isFinal { text += String(r.text.characters) }
                return text
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            let text = try await collect.value
            let seconds = Double(file.length) / file.processingFormat.sampleRate
            return out(["text": .string(String(text.prefix(20_000))), "seconds": .number(seconds.rounded())], "已转写 \(Int(seconds)) 秒音频")
        }
    }
}
