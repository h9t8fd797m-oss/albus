import Foundation
import AlbusCore

/// The external tools Albus can point a student at.
///
/// A fixed set rather than free text, for three reasons: each is rendered with
/// a monogram and a tint that only exist here; the destination URL is a
/// constant, so nothing user-supplied ever reaches `openURL`; and "is this a
/// tool we endorse" gets answered once, at the point someone adds a case,
/// rather than implicitly by whatever a model happened to name.
enum StudyTool: String, CaseIterable, Identifiable, Sendable {
    case claude, grammarly, hemingway
    case jstor, googleScholar, perplexity
    case wolframAlpha, symbolab
    case github, replit
    case deepL, linguee

    var id: String { rawValue }

    enum Category: String, CaseIterable, Identifiable, Sendable {
        case all, writing, research, math, coding, languages
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All"
            case .writing: "Writing"
            case .research: "Research"
            case .math: "Math"
            case .coding: "Coding"
            case .languages: "Languages"
            }
        }
    }

    var category: Category {
        switch self {
        case .claude, .grammarly, .hemingway: .writing
        case .jstor, .googleScholar, .perplexity: .research
        case .wolframAlpha, .symbolab: .math
        case .github, .replit: .coding
        case .deepL, .linguee: .languages
        }
    }

    var name: String {
        switch self {
        case .claude: "Claude"
        case .grammarly: "Grammarly"
        case .hemingway: "Hemingway"
        case .jstor: "JSTOR"
        case .googleScholar: "Google Scholar"
        case .perplexity: "Perplexity"
        case .wolframAlpha: "Wolfram Alpha"
        case .symbolab: "Symbolab"
        case .github: "GitHub"
        case .replit: "Replit"
        case .deepL: "DeepL"
        case .linguee: "Linguee"
        }
    }

    var monogram: String {
        switch self {
        case .claude: "C"
        case .grammarly: "G"
        case .hemingway: "H"
        case .jstor: "J"
        case .googleScholar: "GS"
        case .perplexity: "P"
        case .wolframAlpha: "W"
        case .symbolab: "S"
        case .github: "GH"
        case .replit: "R"
        case .deepL: "D"
        case .linguee: "L"
        }
    }

    /// Short enough to sit on one line inside a chip.
    var reason: String {
        switch self {
        case .claude: "Think it through"
        case .grammarly: "Clarity pass"
        case .hemingway: "Tighten prose"
        case .jstor: "Primary sources"
        case .googleScholar: "Citations"
        case .perplexity: "Sourced answers"
        case .wolframAlpha: "Computational math"
        case .symbolab: "Step-by-step solving"
        case .github: "Code hosting"
        case .replit: "Code in the browser"
        case .deepL: "Precise translation"
        case .linguee: "Words in context"
        }
    }

    /// The longer line used on the Tools library card.
    var summary: String {
        switch self {
        case .claude: "AI writing and reasoning partner"
        case .grammarly: "Grammar and clarity checks"
        case .hemingway: "Tighten bold, clear prose"
        case .jstor: "Academic journals and primary sources"
        case .googleScholar: "Scholarly articles and citations"
        case .perplexity: "Answer engine with sources"
        case .wolframAlpha: "Computational math answers"
        case .symbolab: "Step-by-step equation solver"
        case .github: "Code hosting and collaboration"
        case .replit: "Code in the browser, instantly"
        case .deepL: "Precise machine translation"
        case .linguee: "Translations in real context"
        }
    }

    var tint: Tokens.Tint {
        switch self {
        case .claude: .violet
        case .grammarly: .green
        case .hemingway: .amber
        case .jstor: .neutral
        case .googleScholar: .blue
        case .perplexity: .teal
        case .wolframAlpha: .red
        case .symbolab: .orange
        case .github: .slate
        case .replit: .blue
        case .deepL: .blue
        case .linguee: .green
        }
    }

    /// Compile-time constants. Nothing here is built from user input or model
    /// output, which is what makes opening one safe.
    var url: URL {
        let raw = switch self {
        case .claude: "https://claude.ai"
        case .grammarly: "https://www.grammarly.com"
        case .hemingway: "https://hemingwayapp.com"
        case .jstor: "https://www.jstor.org"
        case .googleScholar: "https://scholar.google.com"
        case .perplexity: "https://www.perplexity.ai"
        case .wolframAlpha: "https://www.wolframalpha.com"
        case .symbolab: "https://www.symbolab.com"
        case .github: "https://github.com"
        case .replit: "https://replit.com"
        case .deepL: "https://www.deepl.com/translator"
        case .linguee: "https://www.linguee.com"
        }
        // Every string above is a literal this file controls, so this cannot
        // fail. Force-unwrapping a constant is honest; a silent fallback would
        // hide a typo until a student tapped it.
        return URL(string: raw)!
    }

    /// Maps a plan step to the tools worth opening for it.
    ///
    /// Keyword matching on purpose: instant, free, works offline, and wrong in
    /// ways a student can see and ignore. A model call here would cost money
    /// per step to produce a guess of the same quality.
    static func suggested(for step: Subtask) -> [StudyTool] {
        let text = (step.title + " " + (step.guidance ?? "")).lowercased()
        func any(_ words: [String]) -> Bool { words.contains { text.contains($0) } }

        var out: [StudyTool] = []
        if any(["research", "source", "read", "find", "evidence"]) {
            out += [.jstor, .googleScholar]
        }
        if any(["outline", "plan", "structure", "draft", "write", "brainstorm", "argument"]) {
            out.append(.claude)
        }
        if any(["review", "edit", "proofread", "cite", "revise", "polish"]) {
            out += [.grammarly, .hemingway]
        }
        if any(["solve", "equation", "calculate", "problem set", "derive"]) {
            out += [.wolframAlpha, .symbolab]
        }
        if any(["code", "program", "implement", "debug"]) {
            out += [.github, .replit]
        }
        if any(["translate", "vocabulary", "conjugat"]) {
            out += [.deepL, .linguee]
        }
        // Three is the most a step row can show without wrapping.
        return Array(out.prefix(3))
    }
}
