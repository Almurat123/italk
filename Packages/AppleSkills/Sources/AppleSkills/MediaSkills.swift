import Foundation
import AgentRuntime
import Photos
import Vision
import ImageIO
import CoreLocation
#if os(iOS)
import MediaPlayer
#endif

/// On-device image understanding with Vision. Nothing leaves the device.
public enum ImageAnalysis {
    public static func cgImage(_ data: Data, maxPixel: Int = 2048) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    public static func analyze(_ image: CGImage, tasks: Set<String>) throws -> JSONValue {
        var result: [String: JSONValue] = ["width": .number(Double(image.width)), "height": .number(Double(image.height))]
        let handler = VNImageRequestHandler(cgImage: image)
        var requests: [VNRequest] = []
        let text = VNRecognizeTextRequest(); text.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]; text.recognitionLevel = .accurate; text.usesLanguageCorrection = true
        let labels = VNClassifyImageRequest()
        let codes = VNDetectBarcodesRequest()
        let faces = VNDetectFaceRectanglesRequest()
        if tasks.contains("text") { requests.append(text) }
        if tasks.contains("labels") { requests.append(labels) }
        if tasks.contains("barcodes") { requests.append(codes) }
        if tasks.contains("faces") { requests.append(faces) }
        try handler.perform(requests)
        if tasks.contains("text") {
            let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            result["text"] = .string(String(lines.joined(separator: "\n").prefix(4000)))
        }
        if tasks.contains("labels") {
            let top = (labels.results ?? []).filter { $0.confidence > 0.25 }.prefix(10)
            result["labels"] = .array(top.map { .object(["label": .string($0.identifier), "confidence": .number((Double($0.confidence) * 100).rounded() / 100)]) })
        }
        if tasks.contains("barcodes") {
            result["codes"] = .array((codes.results ?? []).compactMap { b in b.payloadStringValue.map { .object(["type": .string(b.symbology.rawValue), "payload": .string($0)]) } })
        }
        if tasks.contains("faces") { result["faceCount"] = .number(Double(faces.results?.count ?? 0)) }
        return .object(result)
    }

    static func load(_ source: String, ctx: AppleSkillContext) async throws -> Data {
        if source.hasPrefix("attachment:"), let id = UUID(uuidString: String(source.dropFirst(11))), let u = await ctx.attachmentURL(id) { return try Data(contentsOf: u) }
        if source.hasPrefix("file:") { return try Data(contentsOf: try FileSkills.resolve(String(source.dropFirst(5)), root: ctx.filesRoot)) }
        if source.hasPrefix("photo:") { return try await PhotoSkills.imageData(localId: String(source.dropFirst(6))) }
        throw fail("source 应为 attachment:<id>、file:<路径> 或 photo:<id>")
    }
}

enum PhotoSkills {
    static func imageData(localId: String) async throws -> Data {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil).firstObject else { throw fail("找不到这张照片") }
        let opts = PHImageRequestOptions(); opts.isNetworkAccessAllowed = true; opts.deliveryMode = .highQualityFormat; opts.version = .current
        return try await withCheckedThrowingContinuation { c in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: opts) { data, _, _, info in
                if let data { c.resume(returning: data) } else { c.resume(throwing: fail("无法读取照片（可能在 iCloud 中且无网络）", retry: true)) }
            }
        }
    }

    static let search = FnTool(ToolSpec(name: "photos_search", description: "按时间、类型、收藏查找照片和视频（返回数量、日期、地点和 id）", parameters: [
        "start": ParamSpec(.string, "开始日期", required: false, maxLength: 40),
        "end": ParamSpec(.string, "结束日期", required: false, maxLength: 40),
        "kind": ParamSpec(.string, "类型", required: false, enumValues: ["photo", "video", "screenshot", "selfie", "live", "any"]),
        "favorites": ParamSpec(.boolean, "只看收藏", required: false),
        "limit": ParamSpec(.integer, "默认 12", required: false, minimum: 1, maximum: 50)
    ], permission: .readOnly, capability: .photos, systemPermission: .photos, dataClass: .personal)) { a, ctx in
        let opts = PHFetchOptions()
        var preds: [NSPredicate] = []
        if let s = ArgDate.parse(a.str("start"), now: ctx.now) { preds.append(NSPredicate(format: "creationDate >= %@", s as NSDate)) }
        if let e = ArgDate.parse(a.str("end"), now: ctx.now) { preds.append(NSPredicate(format: "creationDate <= %@", e as NSDate)) }
        if a.flag("favorites") == true { preds.append(NSPredicate(format: "favorite == YES")) }
        switch a.str("kind") ?? "any" {
        case "photo": preds.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue))
        case "video": preds.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue))
        case "screenshot": preds.append(NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue))
        case "live": preds.append(NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoLive.rawValue))
        default: break
        }
        opts.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: preds)
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var result: PHFetchResult<PHAsset>
        if a.str("kind") == "selfie", let album = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumSelfPortraits, options: nil).firstObject {
            result = PHAsset.fetchAssets(in: album, options: opts)
        } else { result = PHAsset.fetchAssets(with: opts) }
        var items: [JSONValue] = []
        result.enumerateObjects { asset, i, stop in
            if i >= (a.int("limit") ?? 12) { stop.pointee = true; return }
            var o: [String: JSONValue] = ["id": .string(asset.localIdentifier), "kind": .string(asset.mediaType == .video ? "video" : "photo"),
                                          "date": .string(asset.creationDate.map { ArgDate.iso($0) } ?? ""), "favorite": .bool(asset.isFavorite)]
            if asset.mediaType == .video { o["seconds"] = .number(asset.duration.rounded()) }
            if let l = asset.location { o["latitude"] = .number((l.coordinate.latitude * 1000).rounded() / 1000); o["longitude"] = .number((l.coordinate.longitude * 1000).rounded() / 1000) }
            items.append(.object(o))
        }
        return out(["total": .number(Double(result.count)), "items": .array(items),
                    "note": .string("要看照片内容，用 vision_analyze_image（source: photo:<id>）")], "共 \(result.count) 项")
    }

    static func saveToLibrary(_ ctx: AppleSkillContext) -> FnTool { FnTool(ToolSpec(name: "photos_save", description: "把 iTalk 文件夹中的图片或视频存入相册", parameters: [
        "path": ParamSpec(.string, "iTalk 文件中的相对路径", maxLength: 300)
    ], permission: .lowRiskAction, capability: .photos, systemPermission: .photosAddOnly)) { a, _ in
        let url = try FileSkills.resolve(a.str("path") ?? "", root: ctx.filesRoot)
        let isVideo = ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased())
        try await PHPhotoLibrary.shared().performChanges {
            if isVideo { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) } else { PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url) }
        }
        return out(["saved": .bool(true)], "已存入相册")
    } }

    static func vision(_ ctx: AppleSkillContext) -> FnTool {
        FnTool(ToolSpec(name: "vision_analyze_image", description: "在设备上识别图片：文字（OCR）、物体/场景标签、二维码条码、人脸数量", parameters: [
            "source": ParamSpec(.string, "attachment:<id>（对话图片）、photo:<id>（相册）或 file:<路径>", maxLength: 300),
            "tasks": ParamSpec(.array, "text / labels / barcodes / faces，默认全部", required: false)
        ], permission: .readOnly, capability: .vision, dataClass: .personal, timeoutSeconds: 30)) { a, _ in
            guard let src = a.str("source") else { throw fail("缺少图片来源") }
            if src.hasPrefix("photo:"), PHPhotoLibrary.authorizationStatus(for: .readWrite) != .authorized, PHPhotoLibrary.authorizationStatus(for: .readWrite) != .limited {
                throw fail("读取相册需要照片权限：设置 › iTalk › 照片")
            }
            let data = try await ImageAnalysis.load(src, ctx: ctx)
            guard let img = ImageAnalysis.cgImage(data) else { throw fail("无法解码图片") }
            let tasks = Set(a.strings("tasks").isEmpty ? ["text", "labels", "barcodes", "faces"] : a.strings("tasks"))
            return out(["analysis": try ImageAnalysis.analyze(img, tasks: tasks)], "已识别图片")
        }
    }

    static func camera(_ ctx: AppleSkillContext) -> FnTool {
        FnTool(ToolSpec(name: "camera_take_photo", description: "打开相机让用户拍一张照片，保存到 iTalk 文件并可直接识别", parameters: [
            "analyze": ParamSpec(.boolean, "拍完立即识别，默认 true", required: false)
        ], permission: .lowRiskAction, capability: .camera, systemPermission: .camera, dataClass: .personal, timeoutSeconds: 600)) { a, _ in
            guard let url = await ctx.presenter.capturePhoto() else { return out(["taken": .bool(false)], "用户取消了拍照") }
            var o: [String: JSONValue] = ["taken": .bool(true), "file": .string(url.lastPathComponent)]
            if a.flag("analyze") ?? true, let img = ImageAnalysis.cgImage(try Data(contentsOf: url)) {
                o["analysis"] = try ImageAnalysis.analyze(img, tasks: ["text", "labels", "barcodes", "faces"])
            }
            return out(o, "已拍照")
        }
    }
}

enum MusicSkills {
    #if os(iOS)
    @MainActor static var player: MPMusicPlayerController { MPMusicPlayerController.systemMusicPlayer }
    @MainActor static func nowPlayingJSON() -> JSONValue {
        guard let i = player.nowPlayingItem else { return .object(["playing": .bool(false)]) }
        return .object(["title": .string(i.title ?? ""), "artist": .string(i.artist ?? ""), "album": .string(i.albumTitle ?? ""),
                        "playing": .bool(player.playbackState == .playing), "positionSeconds": .number(player.currentPlaybackTime.rounded()),
                        "durationSeconds": .number(i.playbackDuration.rounded())])
    }
    #endif

    static let play = FnTool(ToolSpec(name: "music_play", description: "用“音乐”App 播放资料库中的歌曲、歌手、专辑或播放列表；不填则继续播放", parameters: [
        "query": ParamSpec(.string, "歌名/歌手/专辑/播放列表", required: false, maxLength: 80),
        "shuffle": ParamSpec(.boolean, "随机播放", required: false)
    ], permission: .lowRiskAction, capability: .media, systemPermission: .mediaLibrary)) { a, _ in
        #if os(iOS)
        return try await MainActor.run {
            let p = player
            if let q = a.str("query") {
                var items: [MPMediaItem] = []
                for prop in [MPMediaItemPropertyTitle, MPMediaItemPropertyArtist, MPMediaItemPropertyAlbumTitle] where items.isEmpty {
                    let query = MPMediaQuery.songs()
                    query.addFilterPredicate(MPMediaPropertyPredicate(value: q, forProperty: prop, comparisonType: .contains))
                    items = query.items ?? []
                }
                if items.isEmpty, let list = (MPMediaQuery.playlists().collections ?? []).first(where: { ($0.value(forProperty: MPMediaPlaylistPropertyName) as? String)?.contains(q) == true }) {
                    items = list.items
                }
                guard !items.isEmpty else { throw fail("资料库中没有「\(q)」。Apple Music 曲库中的歌曲需在“音乐”App 中搜索；也可用 app_open 打开 QQ 音乐或网易云音乐。") }
                p.setQueue(with: MPMediaItemCollection(items: Array(items.prefix(200))))
                p.shuffleMode = a.flag("shuffle") == true ? .songs : .off
            }
            p.play()
            return out(["nowPlaying": nowPlayingJSON()], "正在播放\(p.nowPlayingItem?.title.map { "「\($0)」" } ?? "")")
        }
        #else
        throw fail("此平台不支持")
        #endif
    }

    static let control = FnTool(ToolSpec(name: "music_control", description: "控制“音乐”App：暂停、继续、下一首、上一首、从头播放", parameters: [
        "action": ParamSpec(.string, "动作", enumValues: ["pause", "play", "next", "previous", "restart"])
    ], permission: .lowRiskAction, capability: .media)) { a, _ in
        #if os(iOS)
        return await MainActor.run {
            let p = player
            switch a.str("action") {
            case "pause": p.pause()
            case "play": p.play()
            case "next": p.skipToNextItem()
            case "previous": p.skipToPreviousItem()
            default: p.skipToBeginning()
            }
            return out(["nowPlaying": nowPlayingJSON()], "已执行")
        }
        #else
        throw fail("此平台不支持")
        #endif
    }

    static let nowPlaying = FnTool(ToolSpec(name: "music_now_playing", description: "“音乐”App 当前播放的歌曲", permission: .readOnly, capability: .media)) { _, _ in
        #if os(iOS)
        return await MainActor.run { out(["nowPlaying": nowPlayingJSON(), "note": .string("只能读取系统“音乐”App 的播放状态，其他音乐 App 的播放信息不对第三方开放。")], "当前播放") }
        #else
        throw fail("此平台不支持")
        #endif
    }
}
