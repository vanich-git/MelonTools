import AppKit
import SwiftUI
import XCTest
@testable import MelonTools

/// Pure-logic tests for the Local AI UI defects from the audit (U1–U5).
///
/// Nothing here needs a window: the keyboard mapping, type-ahead matcher, panel
/// sizing, search-request identity, text batcher, Markdown cache and response
/// parsers are plain values. Interaction and snapshot coverage is still missing
/// and is not claimed.
@MainActor
final class LocalAIUITests: XCTestCase {

    // MARK: - U1: picker keyboard contract

    func testTypeAheadJumpsToTheNextMatchingLabel() {
        let labels = ["Apple", "Banana", "Blueberry", "Cherry"]
        XCTAssertEqual(MTSelectList<String>.typeAheadTarget(input: "b", labels: labels, from: 0), 1)
        XCTAssertEqual(MTSelectList<String>.typeAheadTarget(input: "bl", labels: labels, from: 0), 2)
        XCTAssertEqual(MTSelectList<String>.typeAheadTarget(input: "c", labels: labels, from: 0), 3)
        XCTAssertNil(MTSelectList<String>.typeAheadTarget(input: "z", labels: labels, from: 0))
        XCTAssertNil(MTSelectList<String>.typeAheadTarget(input: "", labels: labels, from: 0))
    }

    func testTypeAheadWrapsAroundAndIsCaseInsensitive() {
        let labels = ["Apple", "Banana", "Blueberry", "Cherry"]
        XCTAssertEqual(MTSelectList<String>.typeAheadTarget(input: "a", labels: labels, from: 2), 0)
        XCTAssertEqual(MTSelectList<String>.typeAheadTarget(input: "BLU", labels: labels, from: 3), 2)
    }

    func testPickerKeyResolvesNavigationAndCharacters() {
        XCTAssertEqual(MTSelectKey.resolve(keyCode: 125, characters: nil, modifiers: []), .down)
        XCTAssertEqual(MTSelectKey.resolve(keyCode: 126, characters: nil, modifiers: []), .up)
        XCTAssertEqual(MTSelectKey.resolve(keyCode: 115, characters: nil, modifiers: []), .home)
        XCTAssertEqual(MTSelectKey.resolve(keyCode: 119, characters: nil, modifiers: []), .end)
        XCTAssertEqual(MTSelectKey.resolve(keyCode: 36, characters: "\r", modifiers: []), .commit)
        XCTAssertEqual(MTSelectKey.resolve(keyCode: 53, characters: "\u{1b}", modifiers: []), .cancel)
        XCTAssertEqual(MTSelectKey.resolve(keyCode: 0, characters: "q", modifiers: []), .character("q"))
        // Chords belong to the app, not to the picker.
        XCTAssertNil(MTSelectKey.resolve(keyCode: 0, characters: "f", modifiers: .command))
        XCTAssertNil(MTSelectKey.resolve(keyCode: 3, characters: nil, modifiers: []))
    }

    func testPickerPanelWidthFollowsLabelsButStaysOnScreen() {
        XCTAssertEqual(
            MTSelectList<String>.panelWidth(labels: ["a"], minimum: 220, maximum: 460),
            220
        )
        let long = String(repeating: "W", count: 200)
        XCTAssertEqual(
            MTSelectList<String>.panelWidth(labels: [long], minimum: 220, maximum: 460),
            460
        )
        XCTAssertEqual(MTSelectList<String>.screenCap(visibleWidth: 600), 460)
        XCTAssertEqual(MTSelectList<String>.screenCap(visibleWidth: 320), 240)
    }

    /// The shared list body must build and lay out with pathological labels
    /// without growing past the cap it was given.
    func testSelectListLaysOutLongLabelsInsideTheCap() {
        let long = String(repeating: "Long label ", count: 40)
        let view = MTSelectList(
            options: [(value: "a", label: long), (value: "b", label: "Short")],
            selection: "a",
            searchable: false,
            minimumWidth: 220,
            maximumWidth: 460,
            onSelect: { _ in },
            onCancel: {}
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 300)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        XCTAssertLessThanOrEqual(host.fittingSize.width, 460)
    }

    // MARK: - U2: immutable search identity

    func testSearchSnapshotDoesNotFollowTheTextField() {
        let request = HFSearchRequest(query: "qwen", sort: .downloads, offset: 0, generation: 1)
        let shown = HFSearchRequest(query: "qwen", sort: .downloads, offset: 0, generation: 1)
        let typed = HFSearchRequest(query: "llama", sort: .downloads, offset: 0, generation: 1)
        XCTAssertTrue(request.belongs(to: shown))
        XCTAssertFalse(request.belongs(to: typed))
    }

    func testLoadMoreBelongsToTheSameSearchIdentity() {
        let first = HFSearchRequest(query: "qwen", sort: .downloads, offset: 0, generation: 4)
        let next = HFSearchRequest(query: first.query, sort: first.sort, offset: 30, generation: first.generation)
        XCTAssertTrue(next.belongs(to: first))
    }

    func testStaleGenerationAndClearAreRejected() {
        let stale = HFSearchRequest(query: "qwen", sort: .downloads, offset: 0, generation: 1)
        // Clear drops the identity entirely.
        XCTAssertFalse(stale.belongs(to: nil))
        // A newer search invalidates the old one even for the same text.
        let newer = HFSearchRequest(query: "qwen", sort: .downloads, offset: 0, generation: 2)
        XCTAssertFalse(stale.belongs(to: newer))
        // A different sort order is a different list.
        let otherSort = HFSearchRequest(query: "qwen", sort: .likes, offset: 0, generation: 1)
        XCTAssertFalse(stale.belongs(to: otherSort))
    }

    // MARK: - U4: batched text updates and incremental Markdown

    func testBatcherCoalescesDeltasWithinTheInterval() {
        var batcher = MTTextBatcher(interval: 0.06)
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        XCTAssertEqual(batcher.append("Hel", now: start), "Hel")
        XCTAssertNil(batcher.append("lo", now: start.addingTimeInterval(0.01)))
        XCTAssertEqual(batcher.append("!", now: start.addingTimeInterval(0.08)), "Hello!")
        XCTAssertNil(batcher.flushIfDue(now: start.addingTimeInterval(0.09)))
        _ = batcher.append(" world", now: start.addingTimeInterval(0.09))
        XCTAssertEqual(batcher.flush(now: start.addingTimeInterval(0.10)), "Hello! world")
        XCTAssertNil(batcher.flush(now: start.addingTimeInterval(0.11)))
    }

    func testBatcherPublishesTheWholeStreamExactlyOnce() {
        var batcher = MTTextBatcher(interval: 0.05)
        var published = ""
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        for delta in ["a", "b", "c", "d", "e"] {
            clock = clock.addingTimeInterval(0.02)
            if let snapshot = batcher.append(delta, now: clock) { published = snapshot }
        }
        if let snapshot = batcher.flush(now: clock) { published = snapshot }
        XCTAssertEqual(published, "abcde")
    }

    func testMarkdownCacheMatchesAFullParseWhileGrowing() {
        let source = """
        ### Title
        Some **bold** text.

        - one
        - two

        ```
        let x = 1
        ```

        Final paragraph.
        """
        let cache = MTMarkdownCache()
        for end in stride(from: 0, through: source.count, by: 3) {
            let prefix = String(source.prefix(end))
            XCTAssertEqual(
                cache.blocks(for: prefix),
                MarkdownText.parse(prefix),
                "incremental parse diverged at prefix length \(end)"
            )
        }
        XCTAssertEqual(cache.blocks(for: source), MarkdownText.parse(source))
    }

    func testMarkdownCacheHandlesReplacedText() {
        let cache = MTMarkdownCache()
        XCTAssertEqual(cache.blocks(for: "first answer"), MarkdownText.parse("first answer"))
        XCTAssertEqual(cache.blocks(for: "second"), MarkdownText.parse("second"))
    }

    func testMarkdownStableBoundarySkipsAnOpenCodeFence() {
        let text = "para\n\n```\ncode\n\nmore code\n```\n"
        XCTAssertEqual(MarkdownText.stableBoundary(in: text), 6)
        XCTAssertNil(MarkdownText.stableBoundary(in: "still typing"))
    }

    // MARK: - U3: structured errors, usage and reasoning split

    func testErrorParserReadsStructuredMessageAndCode() {
        let body = #"{"error":{"message":"model not found","code":"model_not_found"}}"#
        let error = LocalAIRequestError.parse(status: 404, body: body)
        XCTAssertEqual(error.status, 404)
        XCTAssertEqual(error.code, "model_not_found")
        XCTAssertEqual(error.message, "model not found")
        XCTAssertEqual(error.errorDescription, "HTTP 404 · model_not_found · model not found")
    }

    func testErrorParserFallsBackToPlainBody() {
        let error = LocalAIRequestError.parse(status: 502, body: "Bad Gateway")
        XCTAssertEqual(error.message, "Bad Gateway")
        XCTAssertNil(error.code)
        XCTAssertEqual(error.errorDescription, "HTTP 502 · Bad Gateway")
    }

    func testErrorParserRedactsCredentials() {
        let token = "hf_" + String(repeating: "a", count: 40)
        let body = #"{"error":{"message":"invalid key Bearer \#(token)"}}"#
        let error = LocalAIRequestError.parse(status: 401, body: body)
        XCTAssertFalse(error.message.contains(token))
        XCTAssertTrue(error.message.contains("<redacted>"))
        XCTAssertTrue(LocalAIRequestError.sanitize("plain message").contains("plain message"))
        XCTAssertFalse(LocalAIRequestError.looksSecret("short"))
    }

    func testStreamChunkReadsReasoningTimingsAndUsage() {
        let reasoningLine = #"data: {"choices":[{"delta":{"reasoning_content":"think","content":""},"finish_reason":null}],"timings":{"predicted_n":42,"prompt_n":7,"predicted_per_second":12.5}}"#
        let chunk = LocalAIStreamChunk.parse(line: reasoningLine)
        XCTAssertEqual(chunk?.reasoning, "think")
        XCTAssertEqual(chunk?.content, "")
        XCTAssertEqual(chunk?.timings?.predictedN, 42)
        XCTAssertEqual(chunk?.timings?.promptN, 7)
        XCTAssertEqual(chunk?.timings?.predictedPerSecond, 12.5)

        let usageLine = #"data: {"choices":[],"usage":{"prompt_tokens":9,"completion_tokens":21}}"#
        let usageChunk = LocalAIStreamChunk.parse(line: usageLine)
        XCTAssertEqual(usageChunk?.usage?.promptTokens, 9)
        XCTAssertEqual(usageChunk?.usage?.completionTokens, 21)
    }

    func testStreamChunkParsesDoneMarkerAndIgnoresOtherLines() {
        XCTAssertEqual(LocalAIStreamChunk.parse(line: "data: [DONE]")?.done, true)
        XCTAssertNil(LocalAIStreamChunk.parse(line: "event: message"))
        XCTAssertNil(LocalAIStreamChunk.parse(line: "data: not json"))
    }

    func testTokenCountsPreferUsageThenTimingsThenDeltaEstimate() {
        var stats = LocalAIStreamStats()
        XCTAssertNil(stats.completionTokens)

        var deltaChunk = LocalAIStreamChunk()
        deltaChunk.content = "a"
        stats.note(deltaChunk)
        XCTAssertEqual(stats.completionTokens?.value, 1)
        XCTAssertEqual(stats.completionTokens?.approximate, true)
        XCTAssertNil(stats.promptTokens)

        var timingsChunk = LocalAIStreamChunk()
        timingsChunk.timings = LocalAITimings(promptN: 5, predictedN: 8, predictedPerSecond: 30)
        stats.note(timingsChunk)
        XCTAssertEqual(stats.completionTokens?.value, 8)
        XCTAssertEqual(stats.completionTokens?.approximate, false)
        XCTAssertEqual(stats.promptTokens?.value, 5)
        XCTAssertEqual(stats.tokensPerSecond, 30)

        var usageChunk = LocalAIStreamChunk()
        usageChunk.usage = LocalAIUsage(promptTokens: 11, completionTokens: 30)
        stats.note(usageChunk)
        XCTAssertEqual(stats.completionTokens?.value, 30)
        XCTAssertEqual(stats.completionTokens?.approximate, false)
        XCTAssertEqual(stats.promptTokens?.value, 11)
    }

    func testReasoningIsNotCopiedIntoAnEmptyAnswer() {
        let reasoningOnly = LocalAIResponseText(answer: "", reasoning: "step 1, step 2")
        XCTAssertFalse(reasoningOnly.hasAnswer)
        XCTAssertTrue(reasoningOnly.hasReasoning)

        let answered = LocalAIResponseText(answer: "Hello", reasoning: "step 1")
        XCTAssertTrue(answered.hasAnswer)
        XCTAssertTrue(answered.hasReasoning)

        let blank = LocalAIResponseText(answer: "  \n ", reasoning: "")
        XCTAssertFalse(blank.hasAnswer)
        XCTAssertFalse(blank.hasReasoning)
    }

    func testGatewayChecklistCoversThePublicPath() {
        let ids = LocalModelTestSheet.gatewayChecklist.map(\.id)
        XCTAssertEqual(ids, ["chat", "chatStream", "responses", "responsesStream", "tools", "cancel"])
    }
}
