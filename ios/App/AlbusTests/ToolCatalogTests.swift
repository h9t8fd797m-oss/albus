import Testing
import UIKit
@testable import Albus

/// The catalogue is generated data, and the two ways it can be quietly wrong —
/// a mistyped SF Symbol and a malformed host — both fail silently at runtime:
/// a blank tile, or a tap that goes nowhere. Neither shows up in a build.
@MainActor
@Suite("Tool catalogue")
struct ToolCatalogTests {

    @Test("every tool's SF Symbol exists")
    func symbolsResolve() {
        let missing = StudyTool.allCases.filter {
            UIImage(systemName: $0.symbolName) == nil
        }
        #expect(missing.isEmpty,
                "these symbols do not exist: \(missing.map { "\($0.name)=\($0.symbolName)" })")
    }

    @Test("every tool has a usable https URL")
    func urlsAreValid() {
        for tool in StudyTool.allCases {
            let url = tool.url
            #expect(url.scheme == "https", "\(tool.name) is not https")
            #expect(!(url.host() ?? "").isEmpty, "\(tool.name) has no host")
        }
    }

    @Test("names and hosts are unique")
    func noDuplicates() {
        let names = StudyTool.allCases.map(\.name)
        #expect(Set(names).count == names.count,
                "duplicate names: \(names.filter { n in names.filter { $0 == n }.count > 1 })")
    }

    @Test("the library is large enough to be worth searching")
    func hasEnoughTools() {
        #expect(StudyTool.allCases.count >= 200)
    }

    @Test("every category has tools, and every tool has a real category")
    func categoriesArePopulated() {
        for category in StudyTool.Category.allCases where category != .all {
            let count = StudyTool.allCases.filter { $0.category == category }.count
            #expect(count > 0, "\(category.title) is empty")
        }
        #expect(!StudyTool.allCases.contains { $0.category == .all },
                "`all` is a filter, never a tool's own category")
    }

    @Test("search finds tools by name, purpose and subject")
    func searchWorks() {
        #expect(StudyTool.allCases.filter { $0.matches("grammar") }.count >= 2)
        #expect(StudyTool.allCases.filter { $0.matches("cite") }.count >= 1)
        #expect(StudyTool.allCases.filter { $0.matches("zzzznope") }.isEmpty)
        // An empty query is "show everything", not "match nothing".
        #expect(StudyTool.allCases.filter { $0.matches("") }.count == StudyTool.allCases.count)
    }
}
