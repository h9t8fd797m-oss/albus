import Foundation

// MARK: - Dormancy, back-off and momentum
//
// The Duolingo half of the taxonomy, with one deliberate difference: there is
// no streak. A streak is a punishment the app invents and then threatens the
// student with. Albus already has real stakes — the deadlines are not made up
// — so momentum here is a number that goes up or down and never something you
// can lose.

extension Corpus {
    static let engagement: [CopyTemplate] = [

        // — dormant, day 3 —
        .init("dorm3.chaos.01", .dormantSoft, nil, .chaos,
              "Still here",
              "I've been standing in the same spot for three days. Cacti are good at that."),
        .init("dorm3.chaos.02", .dormantSoft, nil, .chaos,
              "Three days",
              "{assignment} is in {days} and hasn't moved either."),
        .init("dorm3.chaos.03", .dormantSoft, nil, .chaos,
              "Checking in",
              "Your plan is exactly where you left it. That's the problem."),
        .init("dorm3.chaos.04", .dormantSoft, nil, .chaos,
              "It's been a minute",
              "{count} assignments still open. I've been keeping them warm."),
        .init("dorm3.chaos.05", .dormantSoft, nil, .chaos,
              "No pressure",
              "Well. Some pressure. {assignment} is {days} out."),
        .init("dorm3.chaos.06", .dormantSoft, nil, .chaos,
              "Hello",
              "Nothing has happened in three days. I would have noticed."),

        .init("dorm3.plain.01", .dormantSoft, nil, .plain,
              "It's been a few days",
              "{count} assignments are still open."),
        .init("dorm3.plain.02", .dormantSoft, nil, .plain,
              "Your plan is waiting",
              "{assignment} is due in {days}."),

        // — dormant, day 7 —
        .init("dorm7.chaos.01", .dormantFinal, nil, .chaos,
              "Week one of being a houseplant",
              "Your deadlines have been less relaxed about it than I have."),
        .init("dorm7.chaos.02", .dormantFinal, nil, .chaos,
              "A whole week",
              "{assignment} is now {days} away. It was further."),
        .init("dorm7.chaos.03", .dormantFinal, nil, .chaos,
              "Seven days",
              "I'm not going anywhere. Neither is the work, unfortunately."),
        .init("dorm7.chaos.04", .dormantFinal, nil, .chaos,
              "Still {count} open",
              "One evening would fix most of this. I've costed it."),
        .init("dorm7.chaos.05", .dormantFinal, nil, .chaos,
              "Long time",
              "The plan still works. It just needs someone to open it."),
        .init("dorm7.chaos.06", .dormantFinal, nil, .chaos,
              "One week",
              "{assignment} in {days}. I'll stop counting if you'd rather."),

        .init("dorm7.plain.01", .dormantFinal, nil, .plain,
              "A week since you last opened Albus",
              "{count} assignments are still open."),
        .init("dorm7.plain.02", .dormantFinal, nil, .plain,
              "Your plan is still here",
              "{assignment} is due in {days}."),

        // — back-off —
        //
        // Duolingo's most effective notification is the one saying it will stop.
        // The honest version keeps the warnings: reminders pause, deadlines do
        // not, and anything genuinely at risk still gets through.
        .init("off.chaos.01", .backOff, nil, .chaos,
              "These clearly aren't working",
              "I'll stop. Your deadlines won't, so I'll still shout if something breaks."),
        .init("off.chaos.02", .backOff, nil, .chaos,
              "Taking the hint",
              "No more nudges for a while. Real problems still get a word."),
        .init("off.chaos.03", .backOff, nil, .chaos,
              "Going quiet",
              "You know where I am. Open the app and I'll start again."),
        .init("off.chaos.04", .backOff, nil, .chaos,
              "Enough from me",
              "Pausing the reminders. Overdue work will still reach you."),
        .init("off.chaos.05", .backOff, nil, .chaos,
              "Fair enough",
              "I'll be a plant for a bit. Deadlines will still get through."),
        .init("off.chaos.06", .backOff, nil, .chaos,
              "Last one",
              "Reminders off until you're back. Nothing urgent will be silent."),

        .init("off.plain.01", .backOff, nil, .plain,
              "Pausing reminders",
              "You'll still hear about anything overdue or at risk."),
        .init("off.plain.02", .backOff, nil, .plain,
              "Going quiet for now",
              "Open Albus any time to turn reminders back on."),

        // — momentum —
        .init("mom.chaos.01", .momentum, nil, .chaos,
              "{weekMinutes} last week",
              "Genuinely respectable. Don't tell anyone I said that."),
        .init("mom.chaos.02", .momentum, nil, .chaos,
              "Week in review",
              "{weekMinutes} of real focus. I counted every one."),
        .init("mom.chaos.03", .momentum, nil, .chaos,
              "Quieter week",
              "{weekMinutes}. Not a crisis. Just an observation."),
        .init("mom.chaos.04", .momentum, nil, .chaos,
              "Your week",
              "{weekMinutes} of focus. The plan noticed."),
        .init("mom.chaos.05", .momentum, nil, .chaos,
              "For the record",
              "{weekMinutes} last week. That's the number, no judgement."),
        .init("mom.chaos.06", .momentum, nil, .chaos,
              "Tally",
              "{weekMinutes} of measured focus. Onwards."),

        .init("mom.plain.01", .momentum, nil, .plain,
              "Last week: {weekMinutes}",
              "Measured focus time across all your sessions."),
        .init("mom.plain.02", .momentum, nil, .plain,
              "Your week in focus",
              "{weekMinutes} recorded."),
    ]
}
