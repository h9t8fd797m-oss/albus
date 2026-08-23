import re, importlib.util, pathlib
spec = importlib.util.spec_from_file_location("gen", "gen.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
T, CATS = m.T, m.CATS

def ident(name):
    s = re.sub(r"[^A-Za-z0-9]+", " ", name).title().replace(" ", "")
    s = s[0].lower() + s[1:]
    if s[0].isdigit(): s = "t" + s
    return s

ids = [ident(t[0]) for t in T]
assert len(ids) == len(set(ids)), [i for i in ids if ids.count(i) > 1]

out = ['''import Foundation
import AlbusCore

/// The tool library.
///
/// A fixed catalogue rather than anything fetched: every destination is a
/// compile-time constant, so nothing a model wrote or a student typed can
/// become a URL the app opens, and the whole list works offline.
///
/// **On logos.** Each tool carries an SF Symbol chosen to say what the tool is
/// *for*, plus its tint — meaningful iconography rather than the initial letters
/// this replaced. Real brand artwork is supported and simply not bundled yet:
/// `icon` prefers an image asset named `logo-<id>` when one exists in the
/// asset catalogue and falls back to the symbol otherwise, so dropping logos in
/// later is an additive change that touches no call site.
///
/// Runtime favicon fetching was considered and rejected: it would tell two
/// hundred companies when a student opens this tab, cost a request per tile,
/// and leave the screen broken offline.
enum StudyTool: String, CaseIterable, Identifiable, Sendable {
''']

for t, i in zip(T, ids):
    out.append(f"    case {i}\n")

out.append('''
    var id: String { rawValue }

    enum Category: String, CaseIterable, Identifiable, Sendable {
        case all
''')
for key, _ in CATS:
    out.append(f"        case {key}\n")
out.append('''        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All"
''')
for key, label in CATS:
    out.append(f'            case .{key}: "{label}"\n')
out.append('''            }
        }
    }

    /// Name, host, category, symbol, tint and the one line explaining why you
    /// would open it. Kept in one table so a new tool is a single edit.
    private var spec: (name: String, host: String, category: Category,
                       symbol: String, tint: Tokens.Tint, reason: String) {
        switch self {
''')

for t, i in zip(T, ids):
    name, host, cat, sym, tint, why = t
    out.append(f'        case .{i}: ("{name}", "{host}", .{cat}, "{sym}", .{tint}, "{why}")\n')

out.append('''        }
    }

    var name: String { spec.name }
    var category: Category { spec.category }
    var reason: String { spec.reason }
    var tint: Tokens.Tint { spec.tint }
    /// SF Symbol fallback. Prefer `icon`, which checks for real artwork first.
    var symbolName: String { spec.symbol }
    /// Asset name a bundled brand logo would use.
    var logoAssetName: String { "logo-\\(rawValue)" }

    /// Shown to a student when asked where a tap will take them.
    var host: String { spec.host }

    /// Every string here is a literal this file controls, so it cannot fail —
    /// and a typo is caught by `ToolCatalogTests`, not by a student tapping a
    /// dead tile.
    var url: URL { URL(string: "https://\\(spec.host)")! }

    /// Matches a search across name, reason and category.
    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        return name.lowercased().contains(q)
            || reason.lowercased().contains(q)
            || category.title.lowercased().contains(q)
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
        if any(["research", "source", "read", "find", "evidence", "cite"]) {
            out += [.jstor, .googleScholar]
        }
        if any(["outline", "plan", "structure", "draft", "write", "brainstorm", "argument", "essay"]) {
            out += [.notion, .grammarly]
        }
        if any(["review", "edit", "proofread", "revise", "polish"]) {
            out += [.grammarly, .hemingwayEditor]
        }
        if any(["solve", "equation", "calculate", "problem set", "derive", "integral"]) {
            out += [.wolframAlpha, .symbolab]
        }
        if any(["code", "program", "implement", "debug"]) {
            out += [.github, .replit]
        }
        if any(["translate", "vocabulary", "conjugat"]) {
            out += [.deepl, .linguee]
        }
        if any(["memoris", "memoriz", "revise", "flashcard", "recall", "learn"]) {
            out += [.anki, .quizlet]
        }
        // Three is the most a step row can show without wrapping.
        var seen = Set<StudyTool>()
        return out.filter { seen.insert($0).inserted }.prefix(3).map { $0 }
    }
}
''')

pathlib.Path("StudyTool.swift").write_text("".join(out))
print("emitted StudyTool.swift", len("".join(out)), "bytes,", len(T), "tools")
