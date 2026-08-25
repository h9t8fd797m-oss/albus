import Foundation
import AlbusCore

// Choosing which tools to put in front of a student.
//
// The catalogue and this file are deliberately separate: `StudyTool.swift` is
// generated data saying what exists and what it is for, this is the judgement
// about when it helps. Regenerating the catalogue never touches the reasoning.
//
// **What this replaces.** The previous version matched seven keyword buckets in
// the step's title against fourteen hard-coded tools. Every essay step got
// Notion and Grammarly, every research step JSTOR and Google Scholar, every
// maths step Wolfram and Symbolab — for every student, every subject, every
// deadline. 211 of the 225 tools were unreachable. It was not that the ranking
// was poor; there was no ranking.
//
// **No AI call happens here.** The planner already decided what each step is
// for and recorded it; this turns that into tools with arithmetic. Instant,
// free, offline, and inspectable — a student can be told why a tool appeared.

extension StudyTool {

    /// Tools worth opening for one step of a plan.
    ///
    /// `limit` is what the step row can show without wrapping.
    static func suggested(for step: Subtask, limit: Int = 3, now: Date = .now) -> [StudyTool] {
        suggestions(for: step, limit: limit, now: now, excluding: toolsUsedEarlier(than: step, now: now))
    }

    private static func suggestions(for step: Subtask, limit: Int, now: Date,
                                    excluding alreadyUsed: Set<StudyTool>) -> [StudyTool] {
        let assignment = step.assignment
        let need = step.need ?? inferredNeed(for: step)
        guard let need else { return [] }

        let areas = assignment.map { SubjectArea.of($0) } ?? []
        let runway = assignment.map { Runway(assignment: $0, step: step, now: now) }
            ?? Runway.comfortable

        let scored = StudyTool.allCases.compactMap { tool -> (StudyTool, Int)? in
            guard tool.needs.contains(need) else { return nil }
            var score = 100

            // Subject fit. A tool that names its subjects and does not name this
            // one is actively wrong — Overleaf for a history essay, Stellarium
            // for a biology practical — so it is pushed below the general tools
            // rather than merely not boosted.
            //
            // A subject maps to several areas (History is humanities *and*
            // social science), and a tool to several too, so this is an
            // intersection rather than an equality.
            if !tool.areas.isEmpty {
                if areas.isEmpty {
                    // Subject unknown — a student who typed something Albus does
                    // not recognise. A tool that names its subjects is then a
                    // guess, so generalists go first. Mild, because it might
                    // still be right: this is a preference, not a verdict.
                    score -= 15
                } else {
                    score += tool.areas.contains(where: areas.contains) ? 40 : -60
                }
            }

            // Setup has to be affordable. A reference manager is the right answer
            // for a three-week project and the wrong one for a 20-minute step due
            // tomorrow, and the tool itself does not change between those.
            if tool.setup == .heavy { score += runway.heavyToolAdjustment }

            // Variety, without randomness. A tool already suggested earlier in
            // this same plan is demoted, so a six-step essay does not read as
            // "Grammarly" six times — but it can still win if nothing else
            // serves the need, which is better than an irrelevant alternative.
            if alreadyUsed.contains(tool) { score -= 45 }

            return (tool, score)
        }

        return scored
            // Catalogue order is the tiebreak, so the same context always yields
            // the same tools. Two students with the same step get the same
            // answer, and so does the same student twice.
            .sorted { $0.1 == $1.1 ? order(of: $0.0) < order(of: $1.0) : $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    private static func order(of tool: StudyTool) -> Int {
        StudyTool.allCases.firstIndex(of: tool) ?? 0
    }

    /// What earlier steps in this plan already sent the student to.
    ///
    /// Computed by actually asking what each earlier step would suggest, rather
    /// than by taking the first catalogue entry that serves its need. The cheap
    /// version demoted a tool that was never shown: a maths plan with three
    /// practice steps suggested Numbas at every one, because the penalty was
    /// aimed at Khan Academy — first in the catalogue for that need, and not
    /// what the scorer had actually picked for a maths student.
    ///
    /// Iterative rather than recursive, and each earlier step is asked only for
    /// its top pick: demoting everything an earlier step *could* have used
    /// would empty the catalogue by the third step. Bounded by the 12-step plan
    /// cap, so this is a few thousand comparisons and no allocation worth
    /// caching.
    private static func toolsUsedEarlier(than step: Subtask, now: Date) -> Set<StudyTool> {
        guard let assignment = step.assignment else { return [] }
        var used: Set<StudyTool> = []
        for earlier in assignment.subtasks.sorted(by: { $0.ordinal < $1.ordinal })
        where earlier.ordinal < step.ordinal {
            if let top = suggestions(for: earlier, limit: 1, now: now, excluding: used).first {
                used.insert(top)
            }
        }
        return used
    }

    /// The need a plan written before the planner recorded one.
    ///
    /// Keyword matching, but only as a fallback for old rows — and it maps onto
    /// the same vocabulary the planner uses, so there is one selection path
    /// rather than two. New plans never reach this.
    static func inferredNeed(for step: Subtask) -> Need? {
        let text = (step.title + " " + (step.guidance ?? "")).lowercased()
        func any(_ words: [String]) -> Bool { words.contains { text.contains($0) } }

        // Ordered most specific first: "check your working" is error analysis,
        // not practice, and both contain "work".
        if any(["cite", "citation", "bibliograph", "referenc"]) { return .citation }
        if any(["proofread", "spelling", "grammar", "typo"]) { return .proofreading }
        if any(["mistake", "error", "check your", "where you went wrong"]) { return .errorAnalysis }
        if any(["outline", "structure", "plan the", "brainstorm", "mind map"]) { return .outlining }
        if any(["source", "research", "evidence", "find papers", "literature"]) { return .sourceResearch }
        if any(["read ", "reading", "skim", "chapter", "textbook"]) { return .reading }
        if any(["note", "annotat", "summar"]) { return .noteTaking }
        if any(["draft", "write", "essay", "paragraph", "introduction"]) { return .drafting }
        if any(["edit", "revise", "polish", "tighten", "cut"]) { return .editing }
        if any(["worked example", "example", "how to solve", "method", "watch"]) { return .workedExamples }
        if any(["past paper", "practice question", "exercise", "problem set", "problems"]) { return .problemPractice }
        if any(["graph", "plot", "sketch the curve"]) { return .graphing }
        if any(["calculate", "solve", "equation", "integral", "derivativ"]) { return .computation }
        if any(["data", "statistic", "regression", "analyse results"]) { return .dataAnalysis }
        if any(["experiment", "simulat", "lab "]) { return .simulation }
        if any(["diagram", "label", "draw"]) { return .diagramming }
        if any(["translat"]) { return .translation }
        if any(["vocabular", "conjugat", "word list"]) { return .vocabulary }
        if any(["pronunc", "listening", "speaking", "oral"]) { return .listeningSpeaking }
        if any(["flashcard", "memoris", "memoriz", "learn the"]) { return .memorisation }
        if any(["quiz", "test yourself", "recall"]) { return .selfTesting }
        if any(["code", "program", "implement", "function"]) { return .coding }
        if any(["debug", "fix the"]) { return .debugging }
        if any(["slide", "present", "deck"]) { return .presentation }
        if any(["design", "layout", "poster"]) { return .design }
        return nil
    }
}

/// How much room the student has before this is due.
///
/// Two axes, because they fail differently: a step can be short inside a long
/// project (fine to set a tool up once), or the whole assignment can be due
/// tomorrow (nothing with a setup cost is worth it).
struct Runway {
    let daysToDeadline: Int
    let stepMinutes: Int

    static let comfortable = Runway(daysToDeadline: 14, stepMinutes: 60)

    init(assignment: Assignment, step: Subtask, now: Date) {
        let days = Calendar.current.dateComponents(
            [.day], from: Calendar.current.startOfDay(for: now),
            to: Calendar.current.startOfDay(for: assignment.deadline)
        ).day ?? 0
        daysToDeadline = max(0, days)
        stepMinutes = step.estimatedMinutes
    }

    init(daysToDeadline: Int, stepMinutes: Int) {
        self.daysToDeadline = daysToDeadline
        self.stepMinutes = stepMinutes
    }

    /// Positive when there is room to learn a tool, sharply negative when there
    /// is not. Installing a reference manager the night before is not a plan.
    ///
    /// The positive end is deliberately small. At +20 a heavy tool outranked a
    /// better-suited light one — a Visual Arts presentation step recommended
    /// OBS Studio over Canva purely because OBS costs more to set up. Runway
    /// should decide between comparable tools, never override fit.
    var heavyToolAdjustment: Int {
        switch (daysToDeadline, stepMinutes) {
        case (0...1, _):      -70   // due today or tomorrow: no time to set up
        case (2...4, ..<30):  -40   // days left, but this step is a quick one
        case (2...4, _):      -10
        default:                8   // a week or more: worth doing once, properly
        }
    }
}

/// Which subject areas the student's course belongs to.
///
/// Read from the curriculum subject when Albus knows it, and from the subject's
/// name when it does not — a student who typed "Biology" gets the same tools as
/// one who picked it from the corpus.
///
/// Returns a set, because subjects genuinely span areas: History is humanities
/// and social science, and a source-research step in it should reach both JSTOR
/// and SSRN.
enum SubjectArea {
    static func of(_ assignment: Assignment) -> Set<StudyTool.Area> {
        if let subject = assignment.course?.curriculum?.subject {
            let areas = fromName(subject)
            if !areas.isEmpty { return areas }
        }
        if let name = assignment.course?.displayName {
            let areas = fromName(name)
            if !areas.isEmpty { return areas }
        }
        // With no subject at all, the task type is the only signal left, and it
        // is a weak one — deliberately no science guess from "lab_report",
        // since which science matters more than that it is one.
        return switch assignment.taskType {
        case "problem_set": [.maths]
        default: []
        }
    }

    /// Order matters. "Computer Science" contains "science", and checking the
    /// sciences first classified every computing course as a science — so a
    /// coding step was offered Khan Academy and Physics & Maths Tutor while
    /// LeetCode and Stack Overflow sat unreachable in the catalogue. The
    /// specific disciplines are tested before the words that appear inside
    /// other subjects' names.
    private static func fromName(_ raw: String) -> Set<StudyTool.Area> {
        let n = raw.lowercased()
        func any(_ words: [String]) -> Bool { words.contains { n.contains($0) } }

        if any(["computer", "computing", "programming", "software", "informatics"]) {
            return [.computing]
        }
        if any(["language b", "language ab initio", "spanish", "french", "german",
                "mandarin", "chinese", "latin", "italian", "japanese", "arabic",
                "portuguese", "russian"]) {
            return [.languages]
        }
        if any(["math", "calculus", "statistic"]) { return [.maths] }
        if any(["biolog", "medicine", "anatomy", "physiolog"]) { return [.biology] }
        if any(["chemist", "biochem"]) { return [.chemistry] }
        if any(["physics", "mechanic"]) { return [.physics] }
        if any(["geolog", "earth", "astronom", "climate"]) { return [.earthScience] }
        if any(["environmental", "ess"]) { return [.biology, .earthScience] }
        if any(["economic", "business", "politic", "psycholog", "sociolog",
                "geograph", "global politics", "management"]) {
            return [.socialScience, .humanities]
        }
        if any(["literature", "english", "language a"]) { return [.literature, .humanities] }
        if any(["history", "philosoph", "religio", "anthropolog", "classic",
                "theory of knowledge"]) {
            // Humanities only. Adding social science here looked harmless and
            // sent a history source-research step to Our World in Data and
            // Statista ahead of Google Scholar.
            return [.humanities]
        }
        if any(["art", "music", "theatre", "film", "drama", "dance", "design"]) {
            return [.arts]
        }
        return []
    }
}
