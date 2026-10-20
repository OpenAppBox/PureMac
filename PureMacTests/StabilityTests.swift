import Foundation
import PureMacKit
import Testing
@testable import PureMac

/// Regression tests for app-side bugs found in the 0.13 stability review.
@MainActor
@Suite("Stability 0.13")
struct StabilityTests {
    // A Live run started while another sample was still finishing looped on the main actor
    // without suspending, so that sample could never resume: the app hung.
    @Test(.timeLimit(.minutes(1))) func liveRunWaitsForASampleInProgress() async throws {
        let model = PerformanceModel()
        model.isLive = true
        let manual = Task { await model.refresh() }        // a 1-second sample
        try await Task.sleep(for: .milliseconds(50))
        let live = Task { await model.run() }               // starts while it is still running
        try await Task.sleep(for: .milliseconds(1_500))
        model.isLive = false
        await manual.value
        await live.value
        #expect(model.snapshot != nil)
        #expect(!model.history.isEmpty)
    }

    // Paths in headers and notices went through Markdown: "*draft*" showed as an italic "draft".
    @Test func markdownInNamesIsShownLiterally() throws {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        for name in ["~/Projects/*draft*/a", "~/x/**old**.txt", "~/a/[b](c)", "~/a/`b`", "~/my_file_name", #"~/back\slash"#, "~/~tmp~/x"] {
            let rendered = try AttributedString(markdown: name.markdownEscaped, options: options)
            #expect(String(rendered.characters) == name)
            #expect(rendered.runs.allSatisfy { $0.inlinePresentationIntent == nil && $0.link == nil }, "\(name) must not be styled")
        }
    }

    // The selection total counted a location twice when another selected location contained it.
    @Test func nestedDeveloperSelectionIsCountedOnce() {
        var outer = SizeSummary(); outer.allocatedSize = 10_000
        var inner = SizeSummary(); inner.allocatedSize = 4_000
        let model = DeveloperModel()
        model._testSet(items: [
            DeveloperItem(id: "xdg", group: .mlModels, title: "~/.cache", detail: "", path: "/u/.cache", size: outer, risk: .review, handling: .selectItem),
            DeveloperItem(id: "hf", group: .mlModels, title: "Hugging Face", detail: "", path: "/u/.cache/huggingface", size: inner, risk: .review, handling: .selectItem),
        ])
        model.selection = ["/u/.cache", "/u/.cache/huggingface"]
        #expect(model.selectedBytes == 10_000)
        model.selection = ["/u/.cache/huggingface"]
        #expect(model.selectedBytes == 4_000)
    }
}
