import XCTest

@MainActor final class AssistantUITests: XCTestCase {
    func testSkillInstructionsCanBeEditedAndRestored() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-chat", "-noAutoListen", "-chatLayoutFixture", "-showSettings"]
        app.launch()
        let entry = app.buttons["settings.skills"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
        let skill = app.buttons["skill.core"]
        XCTAssertTrue(skill.waitForExistence(timeout: 10)); skill.tap()
        let instructions = app.buttons["skill.instructions"]
        XCTAssertTrue(instructions.waitForExistence(timeout: 5)); instructions.tap()
        let summary = app.textFields["skill.editor.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        let reset = app.buttons["恢复原始说明"]
        if reset.exists { throw XCTSkip("the simulator already contains a custom skill override") }
        summary.tap(); summary.typeText(" QA")
        capture("skill-editor")
        app.buttons["skill.editor.save"].tap()
        XCTAssertTrue(instructions.waitForExistence(timeout: 5)); instructions.tap()
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        XCTAssertTrue((summary.value as? String ?? "").contains("QA"))
        reset.tap()
        XCTAssertTrue(instructions.waitForExistence(timeout: 5))
    }
    func testCloudServiceShowsTruthfulUnavailableState() {
        let app = XCUIApplication()
        app.launchArguments = ["-chat", "-noAutoListen", "-chatLayoutFixture", "-showSettings"]
        app.launch()
        let entry = app.buttons["settings.modelCenter"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
        XCTAssertTrue(app.navigationBars["模型中心"].waitForExistence(timeout: 5))
        let cloud = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "iTalk 云端")).firstMatch
        XCTAssertTrue(cloud.waitForExistence(timeout: 5)); cloud.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "云端模型和订阅")).firstMatch.waitForExistence(timeout: 5))
        capture("cloud-unavailable")
    }
    func testModelCenterNavigationAndVoiceCatalog() {
        let app = XCUIApplication()
        app.launchArguments = ["-chat", "-noAutoListen", "-chatLayoutFixture", "-showSettings"]
        app.launch()
        let entry = app.buttons["settings.modelCenter"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        entry.tap()
        XCTAssertTrue(app.navigationBars["模型中心"].waitForExistence(timeout: 5))
        app.buttons["models.local"].tap()
        XCTAssertTrue(app.staticTexts["Qwen3.5 2B"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        openDeviceVoices(app)
        XCTAssertTrue(app.navigationBars["声音"].waitForExistence(timeout: 5))
        // One engine, four voices (MOSS-TTS-Nano). The retired Kokoro voices must not come back.
        for name in ["云舒", "书瑶", "老傅", "阿京"] { XCTAssertTrue(app.buttons["voice.option.\(name)"].waitForExistence(timeout: 5), "voice \(name)") }
        for retired in ["小晴", "小悦", "小甜"] { XCTAssertFalse(app.staticTexts[retired].exists, "\(retired) was a Kokoro voice") }
        capture("model-center-voices")
    }
    /// Tapping a voice selects it, with or without the engine installed (it also previews when the engine is there). This is the "tapping does nothing" regression.
    func testTappingAVoiceSelectsIt() {
        let app = XCUIApplication()
        app.launchArguments = ["-chat", "-noAutoListen", "-chatLayoutFixture", "-showSettings"]
        app.launch()
        let entry = app.buttons["settings.voice"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
        XCTAssertTrue(app.navigationBars["声音"].waitForExistence(timeout: 5))
        let first = app.buttons["voice.option.云舒"], second = app.buttons["voice.option.书瑶"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        second.tap()
        expect(second, "isSelected == true", "书瑶 should be selected after tapping it")
        expect(first, "isSelected == false", "云舒 should no longer be selected")
        capture("voice-selected")
        first.tap()                                                         // leave the default selected for the other tests
        expect(first, "isSelected == true", "云舒 should be selected again")
    }
    /// The engine download can be paused and continued, and what a pause leaves behind can be cleared. Needs network access to the model mirrors.
    func testVoiceEngineDownloadCanBePausedAndCleared() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-chat", "-noAutoListen", "-chatLayoutFixture", "-showSettings"]
        app.launch()
        let center = app.buttons["settings.modelCenter"]
        XCTAssertTrue(center.waitForExistence(timeout: 15))
        center.tap()
        XCTAssertTrue(app.navigationBars["模型中心"].waitForExistence(timeout: 5))
        openDeviceVoices(app)
        let download = app.buttons["voice.engine.download"]
        if !download.waitForExistence(timeout: 10) {
            // Nothing to download: the engine is already installed on this simulator (delete it in 设置 › 声音 to run this check).
            XCTAssertTrue(app.descendants(matching: .any)["voice.engine.installed"].exists, "neither a download button nor an installed engine is shown")
            throw XCTSkip("the voice engine is already installed on this simulator")
        }
        download.tap()
        let pause = app.buttons["voice.engine.pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10), "a running download offers 暂停")
        pause.tap()
        XCTAssertTrue(download.waitForExistence(timeout: 30), "after pausing, the download can be continued")
        // Clean up what the pause left on the device, so repeated runs do not fill the simulator.
        let clear = app.buttons["voice.engine.clearPartial"]
        if !(clear.waitForExistence(timeout: 5) && clear.isHittable) { for _ in 0..<3 where !clear.isHittable { app.swipeUp() } }
        if clear.waitForExistence(timeout: 5) {
            clear.tap()
            for _ in 0..<3 where !download.exists { app.swipeDown() }      // the download button is at the top of the page, off screen after scrolling down to the clear button
            XCTAssertTrue(download.waitForExistence(timeout: 10), "the download can be started again from scratch")
            XCTAssertFalse(app.buttons["voice.engine.clearPartial"].waitForExistence(timeout: 3), "no unfinished download is left after clearing")
        }
    }
    func testModelDetailsShowRuntimeMetadata() {
        let app = XCUIApplication()
        app.launchArguments = ["-chat", "-noAutoListen", "-chatLayoutFixture", "-showSettings"]
        app.launch()
        let center = app.buttons["settings.modelCenter"]
        XCTAssertTrue(center.waitForExistence(timeout: 15))
        center.tap()
        XCTAssertTrue(app.navigationBars["模型中心"].waitForExistence(timeout: 5))
        app.buttons["models.local"].tap()
        let model = app.staticTexts["Qwen3.5 2B"]
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        model.tap()
        XCTAssertTrue(app.navigationBars["Qwen3.5 2B"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["下载大小"].exists)
        XCTAssertTrue(app.staticTexts["iTalk 上下文"].exists)
    }
    /// Waits until `element` satisfies the predicate (SwiftUI updates accessibility traits a moment after a tap).
    private func expect(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 5, _ message: String) {
        let waiting = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [waiting], timeout: timeout), .completed, message)
    }
    private func openDeviceVoices(_ app: XCUIApplication) {
        app.buttons["models.voice"].tap()
        let device = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "设备端声音")).firstMatch
        XCTAssertTrue(device.waitForExistence(timeout: 5)); device.tap()
    }
    func testAudioTapCanRunOnBackgroundThread() {
        let app = XCUIApplication()
        app.launchArguments = ["-orb", "-probeAudioCallback"]
        app.launch()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "音频回调检查通过")).firstMatch.waitForExistence(timeout: 10))
    }
    func testTypedLocalTimeAndSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-orb", "-noAutoListen"]
        app.launch()
        XCTAssertTrue(app.buttons["assistant.keyboard"].waitForExistence(timeout: 10))
        capture("home")
        app.buttons["assistant.keyboard"].tap()
        let field = app.descendants(matching: .any).matching(identifier: "assistant.input").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap(); field.typeText("现在几点")
        app.buttons["assistant.send"].tap()
        let answer = app.textViews.matching(NSPredicate(format: "value BEGINSWITH %@", "现在是")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 10))
        field.tap(); field.typeText("今天几号")
        app.buttons["assistant.send"].tap()
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value BEGINSWITH %@", "今天是")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(answer.exists)
        tapMessageBackground(app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        app.buttons["assistant.mode"].tap()
        XCTAssertTrue(app.otherElements["assistant.orb"].waitForExistence(timeout: 5))
        app.buttons["assistant.keyboard"].tap()
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        capture("local-time")
        app.buttons["assistant.more"].tap()
        app.buttons["settings.open"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        capture("settings")
    }
    func testHealthReadRequiresExplicitGrant() {
        let app = XCUIApplication()
        app.launchArguments = ["-orb", "-ask", "今天走了多少步"]
        app.launch()
        let message = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "请在设置中开启设备端健康查询")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        capture("health-permission-gate")
    }
    func testDictationComposerAndPhotoPicker() {
        let app = XCUIApplication()
        app.launchArguments = ["-dictation", "-noAutoListen"]
        app.launch()
        XCTAssertTrue(app.buttons["assistant.holdToTalk"].waitForExistence(timeout: 5))
        capture("hold-to-talk")
        app.buttons["composer.keyboard"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "assistant.input").firstMatch.waitForExistence(timeout: 3))
        capture("keyboard-composer")
        app.buttons["assistant.attach"].tap()
        XCTAssertTrue(app.buttons["attachment.photos"].waitForExistence(timeout: 3)); app.buttons["attachment.photos"].tap()
        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 5) || app.buttons["Cancel"].exists || app.buttons["取消"].exists)
        capture("photo-picker")
        let photo = app.images.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS %@", "Photo", "照片")).firstMatch
        if photo.waitForExistence(timeout: 20) {
            // CONTEXT MEMORY
            // Updated: 2026-10-26
            // Status: verified
            // Why: The iOS 26 picker exposes visible photos as non-hittable AX images.
            // Debug Goal: Exercise real selection and JPEG preparation, not a preview stub.
            // Search Tags: PhotosPicker non hittable image coordinate UI test
            // Invariants:
            // - The coordinate comes from the visible photo's accessibility frame.
            // - Selection must produce a removable attachment in the app.
            // Failure Modes:
            // - Image.tap fails even when the photo is fully visible.
            // - A picker-only test misses failures loading the selected photo.
            photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let done = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label IN %@", "Add", ["Done", "添加", "完成"])).firstMatch
            XCTAssertTrue(done.waitForExistence(timeout: 3))
            done.tap()
            XCTAssertTrue(app.buttons["移除图片"].waitForExistence(timeout: 5))
            capture("photo-preview")
        } else {
            print("PHOTO_PICKER_HIERARCHY", app.debugDescription)
            XCTFail("The simulator photo fixture was not exposed by the picker")
        }
    }
    func testLargeTextComposer() {
        let app = XCUIApplication()
        app.launchArguments = ["-chat", "-noAutoListen", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["assistant.attach"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["assistant.mode"].isHittable)
        capture("large-text-composer")
    }
    func testSidebarAndKeyboardDismissal() {
        let app = XCUIApplication()
        app.launchArguments = ["-chat", "-noAutoListen"]
        app.launch()
        let field = app.descendants(matching: .any).matching(identifier: "assistant.input").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.buttons["history.open"].tap()
        capture("sidebar-before-assert")
        XCTAssertTrue(app.buttons["history.close"].waitForExistence(timeout: 3))
        app.buttons["history.close"].tap()
        XCTAssertTrue(app.buttons["history.close"].waitForNonExistence(timeout: 3))
        field.tap(); field.typeText("现在几点"); app.buttons["assistant.send"].tap()
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value BEGINSWITH %@", "现在是")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        tapMessageBackground(app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        field.tap(); field.typeText("草稿")
        app.buttons["history.open"].tap()
        XCTAssertTrue(app.buttons["history.close"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.sheets.count, 0)
        capture("conversation-sidebar")
        let search = app.textFields["history.search"]
        search.tap(); search.typeText("unmatched-search-123")
        let clear = app.buttons.matching(identifier: "history.clearSearch").firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 3))
        clear.tap()
        app.buttons["history.close"].tap()
        XCTAssertTrue(app.buttons["history.close"].waitForNonExistence(timeout: 3))
        XCTAssertEqual(field.value as? String, "草稿")
        app.buttons["history.open"].tap()
        let current = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history.conversation.")).firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 3)); current.tap()
        XCTAssertTrue(app.buttons["history.close"].waitForNonExistence(timeout: 3))
        XCTAssertEqual(field.value as? String, "草稿")
        app.buttons["history.open"].tap(); app.buttons["history.new"].tap()
        XCTAssertTrue(app.buttons["history.close"].waitForNonExistence(timeout: 3))
        XCTAssertNotEqual(field.value as? String, "草稿")
    }
    func testModeTransitionMotion() {
        let app = XCUIApplication()
        app.launchArguments = ["-orb", "-noAutoListen"]
        app.launch()
        XCTAssertTrue(app.buttons["assistant.keyboard"].waitForExistence(timeout: 5))
        capture("voice-cloud")
        app.buttons["assistant.keyboard"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "assistant.input").firstMatch.waitForExistence(timeout: 3))
        capture("single-layer-composer")
        app.buttons["assistant.mode"].tap()
        XCTAssertTrue(app.buttons["assistant.keyboard"].waitForExistence(timeout: 3))
        capture("voice-cloud-return")
    }
    func testSoftHeaderWhileScrolling() {
        let app = XCUIApplication()
        app.launchArguments = ["-chat", "-noAutoListen"]
        app.launch()
        let field = app.descendants(matching: .any).matching(identifier: "assistant.input").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        for index in 0..<8 {
            field.tap(); field.typeText(index.isMultiple(of: 2) ? "现在几点" : "今天几号")
            app.buttons["assistant.send"].tap()
        }
        let messages = app.descendants(matching: .any).matching(identifier: "assistant.messages").firstMatch
        tapMessageBackground(app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        messages.swipeDown()
        messages.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)).press(forDuration: 0.1, thenDragTo: messages.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        capture("soft-header-scrolled")
        XCTAssertTrue(app.buttons["history.open"].isHittable)
        XCTAssertTrue(app.buttons["assistant.mode"].isHittable)
    }
    func testLongDraftAndExpandedEditor() {
        let app = XCUIApplication()
        app.launchArguments = ["-chat", "-noAutoListen"]
        app.launch()
        let field = app.descendants(matching: .any).matching(identifier: "assistant.input").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let draft = Array(repeating: "这是一段需要保留完整内容的长消息，展开编辑后仍然可以继续修改。", count: 20).joined(separator: "\n")
        field.tap(); field.typeText(draft)
        XCTAssertEqual(field.value as? String, draft)
        XCTAssertGreaterThan(field.frame.height, 60)
        XCTAssertLessThan(field.frame.height, app.frame.height * 0.45)
        XCTAssertTrue(app.buttons["assistant.send"].isEnabled)
        XCTAssertLessThan(app.buttons["assistant.send"].frame.maxY, app.frame.maxY)
        capture("long-draft-composer")
        app.buttons["composer.expand"].tap()
        let editor = app.textViews["draft.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertEqual(editor.value as? String, draft)
        capture("expanded-draft-editor")
        app.buttons["draft.done"].tap()
        XCTAssertEqual(field.value as? String, draft)
        tapMessageBackground(app)
        app.buttons["assistant.mode"].tap()
        XCTAssertTrue(app.buttons["assistant.keyboard"].waitForExistence(timeout: 3))
        app.buttons["assistant.keyboard"].tap()
        XCTAssertEqual(field.value as? String, draft)
        app.buttons["assistant.send"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == %@", draft)).firstMatch.waitForExistence(timeout: 5))
        capture("long-draft-sent")
    }
    func testCharacterMotionPreviewStates() {
        let app = XCUIApplication()
        app.launchArguments = ["-characterPreview", "-noAutoListen"]
        app.launch()
        let idle = app.buttons["character.preview.idle"]
        XCTAssertTrue(idle.waitForExistence(timeout: 8)); idle.tap()
        for (state, title) in [("idle", "待机"), ("listening", "倾听"), ("thinking", "思考"), ("speaking", "说话"), ("confirming", "等待确认"), ("failed", "出错")] {
            app.buttons["character.preview.\(state)"].tap()
            XCTAssertEqual(app.staticTexts["character.preview.status"].label, title)
            capture("character-\(state)")
        }
    }
    func testCharacterActualSpeechAndCancellation() {
        let app = XCUIApplication()
        app.launchArguments = ["-characterPreview", "-noAutoListen"]
        app.launch()
        XCTAssertTrue(app.buttons["character.preview.idle"].waitForExistence(timeout: 8))
        app.buttons["character.preview.idle"].tap()
        let sample = app.buttons["character.preview.sample"]
        let before = sample.value as? String ?? "0"
        sample.tap()
        XCTAssertEqual(app.staticTexts["character.preview.status"].label, "说话")
        let spoken = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", before), object: sample)
        XCTAssertEqual(XCTWaiter.wait(for: [spoken], timeout: 8), .completed)
        capture("character-real-speech")
        sample.tap()
        XCTAssertEqual(app.staticTexts["character.preview.status"].label, "待机")
        let stopped = sample.value as? String
        app.buttons["character.preview.listening"].tap()
        capture("character-after-speech-cancel")
        XCTAssertEqual(sample.value as? String, stopped)
    }
    func testCharacterEmotionPalettes() {
        let app = XCUIApplication()
        app.launchArguments = ["-characterPreview", "-noAutoListen"]
        app.launch()
        XCTAssertTrue(app.buttons["character.preview.speaking"].waitForExistence(timeout: 8))
        app.buttons["character.preview.speaking"].tap()
        for (emotion, title) in [("neutral", "自然"), ("happy", "开心"), ("calm", "温柔"), ("sad", "低落"), ("curious", "好奇"), ("serious", "认真")] {
            let button = app.buttons["character.emotion.\(emotion)"]
            button.tap()
            XCTAssertEqual(app.staticTexts["character.preview.emotion"].label, title)
            capture("emotion-\(emotion)")
        }
        app.buttons["character.preview.idle"].tap()
        capture("emotion-idle-circle")
    }
    func testSpokenClausesChangeExpressionAndCancellationStopsUpdates() {
        let app = XCUIApplication()
        app.launchArguments = ["-characterPreview", "-noAutoListen"]
        app.launch()
        XCTAssertTrue(app.buttons["character.preview.idle"].waitForExistence(timeout: 8))
        app.buttons["character.preview.idle"].tap()
        app.buttons["character.preview.expressionSample"].tap()
        let emotion = app.staticTexts["character.preview.emotion"]
        for title in ["开心", "温柔", "认真"] {
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", title), object: emotion)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 15), .completed)
            capture("spoken-expression-\(title)")
        }
        let sample = app.buttons["character.preview.sample"]
        XCTAssertEqual(sample.label, "停止播放")
        sample.tap()
        XCTAssertEqual(app.staticTexts["character.preview.status"].label, "待机")
        let stoppedBeat = sample.value as? String ?? "0"
        let lateWord = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", stoppedBeat), object: sample)
        XCTAssertEqual(XCTWaiter.wait(for: [lateWord], timeout: 2), .timedOut)
    }
    func testCharacterAutoplayChangesEmotion() {
        let app = XCUIApplication()
        app.launchArguments = ["-characterPreview", "-noAutoListen"]
        app.launch()
        let label = app.staticTexts["character.preview.performance"]
        XCTAssertTrue(label.waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["character.preview.runtime"].value as? String, "active")
        let first = label.label
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", first), object: label)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 8), .completed)
        capture("emotion-autoplay")
    }
    func testCharacterRichPerformances() {
        let app = XCUIApplication()
        app.launchArguments = ["-characterPreview", "-noAutoListen"]
        app.launch()
        XCTAssertTrue(app.buttons["character.performance.rest"].waitForExistence(timeout: 8))
        app.buttons["character.performance.rest"].tap()
        for (name, title) in [("rest", "自然回看"), ("listen", "专注倾听"), ("think", "思考中"), ("puzzled", "疑惑"), ("surprise", "惊讶"), ("delight", "开心"), ("reassure", "安慰"), ("disappointed", "低落"), ("speak", "讲述"), ("playful", "俏皮"), ("drowsy", "困倦"), ("confident", "认真"), ("blocked", "受阻")] {
            app.buttons["character.performance.\(name)"].tap()
            XCTAssertEqual(app.staticTexts["character.preview.performance"].label, title)
            capture("performance-\(name)")
        }
    }
    func testExpandedCharacterPerformances() {
        let app = XCUIApplication()
        app.launchArguments = ["-characterPreview", "-noAutoListen"]
        app.launch()
        XCTAssertTrue(app.buttons["character.performance.rest"].waitForExistence(timeout: 8))
        app.buttons["character.performance.rest"].tap()
        for (name, title) in [("explain", "展开讲述"), ("question", "追问"), ("laugh", "开怀"), ("encourage", "鼓励"), ("attentive", "侧耳听"), ("ponder", "斟酌"), ("amazed", "惊喜"), ("focus", "专注"), ("shy", "含蓄"), ("skeptical", "将信将疑")] {
            app.buttons["character.performance.\(name)"].tap()
            XCTAssertEqual(app.staticTexts["character.preview.performance"].label, title)
            capture("expanded-\(name)")
        }
    }
    func testFirstTextAndImageMessagesStartAtTop() {
        for image in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["-chat", "-noAutoListen", "-chatLayoutFixture"] + (image ? ["-fixtureImage"] : [])
            app.launch()
            let field = app.descendants(matching: .any).matching(identifier: "assistant.input").firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 8))
            if !image {
                XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistant.suggestion.")).firstMatch.waitForExistence(timeout: 3))
                capture("centered-prompt-suggestions")
                field.tap(); field.typeText("首条位置测试")
            }
            XCTAssertTrue(app.buttons["assistant.send"].waitForExistence(timeout: 4)); app.buttons["assistant.send"].tap()
            let prefix = image ? "message.image." : "message.question."
            let message = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
            XCTAssertTrue(message.waitForExistence(timeout: 5))
            let header = app.buttons["assistant.mode"]
            XCTAssertGreaterThanOrEqual(message.frame.minY, header.frame.maxY - 3)
            XCTAssertLessThan(message.frame.minY, header.frame.maxY + 120)
            capture(image ? "first-image-at-top" : "first-text-at-top")
            app.terminate()
        }
    }
    func testSidebarBatchDeleteUndoAndArchive() {
        let app = XCUIApplication()
        app.launchArguments = ["-chat", "-noAutoListen", "-chatLayoutFixture", "-historyFixture"]
        app.launch()
        XCTAssertTrue(app.buttons["history.open"].waitForExistence(timeout: 8)); app.buttons["history.open"].tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history.conversation."))
        XCTAssertTrue(app.buttons["history.sort"].waitForExistence(timeout: 4))
        XCTAssertEqual(rows.count, 3)
        XCTAssertLessThanOrEqual(app.buttons["history.new"].frame.width, 46)
        app.buttons["history.sort"].tap()
        app.buttons["名称"].tap()
        XCTAssertEqual(app.buttons["history.sort"].value as? String, "名称")
        app.buttons["history.sort"].tap(); app.buttons["选择"].tap(); app.buttons["history.selectAll"].tap()
        capture("sidebar-selected-all")
        app.buttons["history.batchDelete"].tap()
        XCTAssertTrue(app.buttons["history.undoBatchDelete"].waitForExistence(timeout: 5)); XCTAssertEqual(rows.count, 0)
        app.buttons["history.undoBatchDelete"].tap()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 3"), object: rows)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        app.buttons["history.sort"].tap(); app.buttons["选择"].tap(); app.buttons["history.selectAll"].tap(); app.buttons["history.batchArchive"].tap()
        XCTAssertTrue(app.buttons["history.archived"].waitForExistence(timeout: 5))
        app.buttons["history.archived"].tap()
        XCTAssertEqual(rows.count, 3)
        capture("sidebar-batch-archived")
    }
    func testStreamingContinuesBehindSidebarAndRespectsManualScroll() {
        let app = XCUIApplication()
        app.launchArguments = ["-chat", "-noAutoListen", "-chatLayoutFixture"]
        app.launch()
        let field = app.descendants(matching: .any).matching(identifier: "assistant.input").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8)); field.tap(); field.typeText("检查长流式布局")
        app.buttons["assistant.send"].tap()
        let answer = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH %@", "message.answer.")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        let before = answer.value as? String ?? ""
        app.buttons["history.open"].tap()
        XCTAssertTrue(app.buttons["history.close"].waitForExistence(timeout: 3)); app.buttons["history.close"].tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", before), object: answer)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 6), .completed)
        XCTAssertFalse(app.staticTexts["已停止"].exists)
        let enoughText = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value MATCHES %@", "(?s).{500,}"), object: answer)
        XCTAssertEqual(XCTWaiter.wait(for: [enoughText], timeout: 12), .completed)
        let messages = app.descendants(matching: .any).matching(identifier: "assistant.messages").firstMatch
        messages.swipeDown(); messages.swipeDown()
        XCTAssertTrue(app.buttons["assistant.scrollLatest"].waitForExistence(timeout: 3))
        let y = answer.frame.minY, text = answer.value as? String ?? ""
        let continued = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", text), object: answer)
        XCTAssertEqual(XCTWaiter.wait(for: [continued], timeout: 5), .completed)
        XCTAssertEqual(answer.frame.minY, y, accuracy: 8)
        capture("streaming-manual-scroll")
    }
    func testNativeMessageSelectionAndReadout() {
        let app = XCUIApplication()
        app.launchArguments = ["-chat", "-noAutoListen", "-chatLayoutFixture"]
        app.launch()
        let field = app.descendants(matching: .any).matching(identifier: "assistant.input").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8)); field.tap(); field.typeText("文字选取检查")
        app.buttons["assistant.send"].tap()
        let answer = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH %@", "message.answer.")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["assistant.stopResponse"].waitForNonExistence(timeout: 5))
        tapMessageBackground(app)
        answer.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: 24, dy: 12)).press(forDuration: 0.8)
        capture("native-message-selection-menu")
        let copy = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "复制全部")).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 3))
        copy.tap()
        answer.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: 24, dy: 12)).press(forDuration: 0.8)
        let read = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "朗读全文")).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 3)); read.tap()
        XCTAssertTrue(app.buttons["assistant.stopResponse"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["assistant.stopResponse"].label, "停止朗读")
        app.buttons["assistant.stopResponse"].tap()
        XCTAssertTrue(app.buttons["assistant.stopResponse"].waitForNonExistence(timeout: 3))
    }
    func testStreamingBubbleHasNoVerticalReboundsAndControlsStayInside() {
        let app = XCUIApplication()
        app.launchArguments = ["-chat", "-noAutoListen", "-chatLayoutFixture"]
        app.launch()
        let field = app.descendants(matching: .any).matching(identifier: "assistant.input").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        let mic = app.buttons["assistant.dictation"], send = app.buttons["assistant.send"]
        XCTAssertGreaterThanOrEqual(mic.frame.minX, field.frame.maxX - 2)
        XCTAssertGreaterThan(send.frame.midX, mic.frame.maxX)
        XCTAssertEqual(mic.frame.midY, send.frame.midY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(field.frame.minY, mic.frame.minY - 2)
        XCTAssertLessThanOrEqual(field.frame.maxY, mic.frame.maxY + 2)
        field.tap(); field.typeText("检查长流式抽动")
        send.tap(); tapMessageBackground(app)
        let answer = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH %@", "message.answer.")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        let stop = app.buttons["assistant.stopResponse"]
        XCTAssertTrue(stop.exists); XCTAssertEqual(mic.frame.midY, stop.frame.midY, accuracy: 1)
        XCTAssertGreaterThan(stop.frame.midX, field.frame.maxX)
        XCTAssertTrue(mic.exists); XCTAssertFalse(send.exists)
        var previous: CGRect?, samples: [[String: Double]] = []
        for length in stride(from: 120, through: 1000, by: 80) {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value MATCHES %@", "(?s).{\(length),}"), object: answer)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 4), .completed)
            let frame = answer.frame
            samples.append(["characters": Double((answer.value as? String ?? "").count), "y": frame.minY, "width": frame.width, "height": frame.height])
            if let previous {
                XCTAssertEqual(frame.width, previous.width, accuracy: 1)
                XCTAssertLessThanOrEqual(frame.minY, previous.minY + 2, "A growing reply must not rebound downward")
            }
            previous = frame
        }
        let measurements = XCTAttachment(data: try! JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted]), uniformTypeIdentifier: "public.json")
        measurements.name = "streaming-bubble-positions"; measurements.lifetime = .keepAlways; add(measurements)
        capture("stable-stream-and-inline-stop")
        stop.tap()
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        XCTAssertEqual(mic.frame.midY, send.frame.midY, accuracy: 1)
    }
    func testSidebarFocusedSearchAndBoundedContextPreview() {
        let app = XCUIApplication()
        app.launchArguments = ["-chat", "-noAutoListen", "-chatLayoutFixture", "-historyFixture"]
        app.launch()
        XCTAssertTrue(app.buttons["history.open"].waitForExistence(timeout: 8)); app.buttons["history.open"].tap()
        let search = app.textFields["history.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3)); search.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3)); capture("sidebar-search-focused-glass")
        app.buttons["history.close"].tap(); app.buttons["history.open"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history.conversation.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3)); row.press(forDuration: 0.8)
        let choose = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "选择")).firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 3))
        capture("sidebar-bounded-context-preview")
        let preview = app.descendants(matching: .any).matching(identifier: "history.preview").firstMatch
        if preview.exists { XCTAssertLessThanOrEqual(preview.frame.maxX, 320); XCTAssertGreaterThanOrEqual(preview.frame.minX, 0) }
        choose.tap()
        XCTAssertTrue(app.buttons["history.selectionDone"].waitForExistence(timeout: 3))
    }
    func testPlaybackMeterAndCancellation() {
        let app = XCUIApplication()
        app.launchArguments = ["-orb", "-probeCloudPlayback", "-noAutoListen"]
        app.launch()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "语音播放与音量检查通过")).firstMatch.waitForExistence(timeout: 10))
    }
    func testSendLayoutProbe() {
        let app = XCUIApplication()
        app.launchArguments = ["-chat", "-noAutoListen", "-chatLayoutFixture", "-sendLayoutProbe"]
        app.launch()
        let field = app.descendants(matching: .any).matching(identifier: "assistant.input").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8)); field.tap(); field.typeText("发送位置检查")
        let sendY = app.buttons["assistant.send"].frame.midY
        app.buttons["assistant.send"].tap()
        let question = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH %@", "message.question.")).firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["assistant.dictation"].frame.midY, sendY, accuracy: 2)
        XCTAssertTrue(app.buttons["assistant.stopResponse"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons["assistant.send"].frame.midY, sendY, accuracy: 2)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        capture("send-layout-keyboard-preserved")
    }
    func testHoldReleaseSendsAndDragSelectsEditOrCancel() {
        for (target, delta) in [("send", 0.0), ("edit", -62.0), ("cancel", -220.0)] {
            let app = XCUIApplication()
            app.launchArguments = ["-dictation", "-noAutoListen", "-chatLayoutFixture", "-dictationGestureFixture"]
            app.launch()
            let hold = app.buttons.matching(identifier: "assistant.holdToTalk").firstMatch
            XCTAssertTrue(hold.waitForExistence(timeout: 8))
            let start = hold.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            if delta == 0 { start.press(forDuration: 0.8) }
            else { start.press(forDuration: 0.6, thenDragTo: start.withOffset(CGVector(dx: 0, dy: delta))) }
            let question = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH %@", "message.question.")).firstMatch
            switch target {
            case "send": XCTAssertTrue(question.waitForExistence(timeout: 5)); XCTAssertEqual(question.value as? String, "按住说话测试")
            case "edit":
                let field = app.descendants(matching: .any).matching(identifier: "assistant.input").firstMatch
                XCTAssertTrue(field.waitForExistence(timeout: 4)); XCTAssertEqual(field.value as? String, "按住说话测试")
                XCTAssertFalse(question.exists)
            default: XCTAssertTrue(hold.exists); XCTAssertFalse(question.exists)
            }
            capture("hold-release-\(target)"); app.terminate()
        }
    }
    func testRecordingOverlayIsCompactAndReplacesComposer() {
        let app = XCUIApplication()
        app.launchArguments = ["-dictation", "-noAutoListen", "-chatLayoutFixture", "-recordingOverlayPreview"]
        app.launch()
        let edit = app.descendants(matching: .any).matching(identifier: "composer.recording.edit").firstMatch
        let cancel = app.descendants(matching: .any).matching(identifier: "composer.recording.cancel").firstMatch
        let transcript = app.staticTexts["composer.recording.transcript"]
        XCTAssertTrue(edit.waitForExistence(timeout: 8)); XCTAssertTrue(cancel.exists); XCTAssertTrue(transcript.exists)
        XCTAssertLessThanOrEqual(edit.frame.width, 140); XCTAssertLessThanOrEqual(cancel.frame.width, 140)
        XCTAssertLessThanOrEqual(edit.frame.height, 64); XCTAssertLessThanOrEqual(cancel.frame.height, 64)
        XCTAssertLessThan(cancel.frame.maxY, transcript.frame.minY)
        XCTAssertLessThan(transcript.frame.maxY, edit.frame.minY)
        XCTAssertFalse(app.buttons["assistant.attach"].exists && app.buttons["assistant.attach"].isEnabled)
        XCTAssertFalse(app.buttons["composer.keyboard"].exists && app.buttons["composer.keyboard"].isEnabled)
        capture("compact-recording-overlay")
    }
    func testActionCapsulesAppearOnlyInActiveConversationAndWork() {
        let empty = XCUIApplication()
        empty.launchArguments = ["-chat", "-noAutoListen", "-chatLayoutFixture"]
        empty.launch()
        XCTAssertTrue(empty.buttons["assistant.attach"].waitForExistence(timeout: 8))
        XCTAssertFalse(empty.buttons["conversation.action.skills"].exists)
        empty.terminate()

        let app = XCUIApplication()
        app.launchArguments = ["-chat", "-noAutoListen", "-chatLayoutFixture", "-ask", "简短回答"]
        app.launch()
        let skills = app.buttons["conversation.action.skills"], remote = app.buttons["conversation.action.remote"]
        XCTAssertTrue(skills.waitForExistence(timeout: 10)); XCTAssertTrue(remote.exists)
        let composer = app.descendants(matching: .any).matching(identifier: "assistant.input").firstMatch
        XCTAssertLessThan(skills.frame.maxY, composer.frame.minY)           // sits above the composer, never over it
        let answer = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH %@", "message.answer.")).firstMatch
        if answer.exists { XCTAssertLessThan(answer.frame.maxY, skills.frame.minY) }   // and below the messages
        remote.tap()
        XCTAssertTrue(app.navigationBars["我的电脑"].waitForExistence(timeout: 5))
        capture("action-capsule-remote")
    }
    private func tapMessageBackground(_ app: XCUIApplication) {
        let field = app.descendants(matching: .any).matching(identifier: "assistant.input").firstMatch
        let y = max(180, min(350, field.frame.minY - 64))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: y)).tap()
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
