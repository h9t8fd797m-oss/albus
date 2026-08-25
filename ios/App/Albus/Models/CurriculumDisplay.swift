import Foundation

// How curriculum data is worded on screen.
//
// A separate file because `Curriculum.swift` is generated: anything written by
// hand in there is lost the next time the corpus grows. Presentation is not
// data, so it belongs here rather than in the generator.

extension CurriculumSubject {
    /// "AQA A-Level Biology" — enough for a student to recognise their own
    /// course, including the board, which is the part that actually changes
    /// how the subject is assessed.
    var displayName: String {
        [board, qualification.title, subject].compactMap { $0 }.joined(separator: " ")
    }

    /// What a subject is called once the student has already chosen the board
    /// and qualification, so repeating them would just be noise.
    var shortName: String { subject }
}

extension CurriculumSubject.Component {
    /// "2h" / "1h 30m" / "45m". Nil when the specification does not give one —
    /// coursework often has no fixed duration, and inventing one would be worse
    /// than leaving it out.
    var durationText: String? {
        guard let minutes, minutes > 0 else { return nil }
        let (h, m) = (minutes / 60, minutes % 60)
        return switch (h, m) {
        case (0, let m): "\(m)m"
        case (let h, 0): "\(h)h"
        case (let h, let m): "\(h)h \(m)m"
        }
    }

    /// "35%", with the fraction dropped when it is a whole number — most are,
    /// and "35.0%" reads like a rounding error nobody made.
    var weightingText: String {
        weighting == weighting.rounded()
            ? "\(Int(weighting))%"
            : String(format: "%.1f%%", weighting)
    }

    /// "Paper 3 · 2h · 30%" — the three things that decide how much revision a
    /// component is worth, on one line.
    var pickerTitle: String {
        [name, durationText, weightingText].compactMap { $0 }.joined(separator: " · ")
    }

    /// The one-line explanation under the picker: what the paper covers and how
    /// it is structured, where the specification says.
    var detailText: String? {
        let parts = [covers, format].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }
}
