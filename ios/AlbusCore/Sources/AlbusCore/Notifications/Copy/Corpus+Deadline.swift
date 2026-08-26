import Foundation

// MARK: - Deadline tiers

extension Corpus {
    static let deadline: [CopyTemplate] = [

        // — T-72h, chaos —
        .init("d72.chaos.01", .deadline72, nil, .chaos,
              "{assignment}",
              "Three days. That's three sleeps. I don't sleep."),
        .init("d72.chaos.02", .deadline72, nil, .chaos,
              "{assignment} — {days}",
              "{steps} left. Comfortable, if you start."),
        .init("d72.chaos.03", .deadline72, nil, .chaos,
              "Gentle reminder",
              "{assignment} is in {days} and {minutes} of work deep."),
        .init("d72.chaos.04", .deadline72, nil, .chaos,
              "{assignment}",
              "**{step}** now means no panic later. I'm told that's a feeling."),
        .init("d72.chaos.05", .deadline72, nil, .chaos,
              "Three days out",
              "{assignment}. {steps}. Still entirely fine."),
        .init("d72.chaos.06", .deadline72, nil, .chaos,
              "Not urgent yet",
              "{assignment} in {days}. I'm mentioning it, not nagging."),

        // — T-72h, plain —
        .init("d72.plain.01", .deadline72, nil, .plain,
              "{assignment} — {days}",
              "{steps} left, about {minutes} of work."),
        .init("d72.plain.02", .deadline72, nil, .plain,
              "Due in {days}",
              "{assignment}. **{step}** is next."),

        // — T-24h, chaos —
        .init("d24.chaos.01", .deadline24, nil, .chaos,
              "{assignment} — tomorrow",
              "{steps} left. Do the maths. I already did."),
        .init("d24.chaos.02", .deadline24, nil, .chaos,
              "Tomorrow",
              "{assignment}, {minutes} of work, one evening. Tight but real."),
        .init("d24.chaos.03", .deadline24, nil, .chaos,
              "This is the one",
              "{assignment} is due tomorrow. **{step}** is where you start."),
        .init("d24.chaos.04", .deadline24, nil, .chaos,
              "24 hours",
              "{assignment}. I've cleared the plan around it. Your move."),
        .init("d24.chaos.05", .deadline24, nil, .chaos,
              "{assignment}",
              "Tomorrow. {steps}. I believe in you, statistically."),
        .init("d24.chaos.06", .deadline24, nil, .chaos,
              "Due tomorrow",
              "{assignment}. Tonight is not free any more. Sorry."),

        // — T-24h, plain —
        .init("d24.plain.01", .deadline24, nil, .plain,
              "{assignment} — due tomorrow",
              "{steps} left, about {minutes}."),
        .init("d24.plain.02", .deadline24, nil, .plain,
              "Due tomorrow",
              "{assignment}. **{step}** is next."),

        // — T-3h, chaos —
        .init("d03.chaos.01", .deadline03, nil, .chaos,
              "{assignment} — {hours}",
              "{steps} left. This is the sprint."),
        .init("d03.chaos.02", .deadline03, nil, .chaos,
              "Three hours",
              "{assignment}. Whatever is done in three hours is what gets handed in."),
        .init("d03.chaos.03", .deadline03, nil, .chaos,
              "Final stretch",
              "{assignment} in {hours}. **{step}**. Nothing else."),
        .init("d03.chaos.04", .deadline03, nil, .chaos,
              "{hours} left",
              "{assignment}. I'd panic but I'm structurally incapable."),
        .init("d03.chaos.05", .deadline03, nil, .chaos,
              "Nearly there",
              "{assignment}, {hours}. Finish something rather than starting everything."),
        .init("d03.chaos.06", .deadline03, nil, .chaos,
              "Clock's going",
              "{assignment} in {hours}. Good enough and handed in beats perfect and late."),

        // — T-3h, plain —
        .init("d03.plain.01", .deadline03, nil, .plain,
              "{assignment} — {hours} left",
              "{steps} remaining."),
        .init("d03.plain.02", .deadline03, nil, .plain,
              "Due in {hours}",
              "{assignment}. **{step}** is next."),
    ]
}

// MARK: - Due today

extension Corpus {
    static let handIn: [CopyTemplate] = [
        .init("today.chaos.01", .handInToday, nil, .chaos,
              "Today",
              "{assignment}. It's today. That's the whole notification."),
        .init("today.chaos.02", .handInToday, nil, .chaos,
              "{assignment} — today",
              "{steps} between you and done."),
        .init("today.chaos.03", .handInToday, nil, .chaos,
              "Due today",
              "{assignment}. **{step}**, then hand it in and take the evening back."),
        .init("today.chaos.04", .handInToday, nil, .chaos,
              "It's the day",
              "{assignment} is due today. {minutes} of work left."),
        .init("today.chaos.05", .handInToday, nil, .chaos,
              "Today's the deadline",
              "{assignment}. Finish it and I'll stop talking about it."),
        .init("today.chaos.06", .handInToday, nil, .chaos,
              "Hand-in day",
              "{assignment}. Whatever's left, do it now rather than at 23:58."),

        .init("today.plain.01", .handInToday, nil, .plain,
              "{assignment} — due today",
              "{steps} left, about {minutes}."),
        .init("today.plain.02", .handInToday, nil, .plain,
              "Due today",
              "{assignment}. **{step}** is next."),
    ]
}

// MARK: - Overdue
//
// `.plain` only, and enforced by `NotificationKind.allowsChaos` rather than by
// asking authors to remember. There is nothing funny about work a student has
// already missed, and a mascot making a joke here would be the moment they
// delete the app.

extension Corpus {
    static let overdue: [CopyTemplate] = [
        .init("late.plain.01", .overdue, nil, .plain,
              "{assignment} was due {lateBy}",
              "What do you want to do about it?"),
        .init("late.plain.02", .overdue, nil, .plain,
              "{assignment} is overdue",
              "{steps} are still open. You can still finish it."),
        .init("late.plain.03", .overdue, nil, .plain,
              "Missed: {assignment}",
              "Open it and either finish it or move the deadline."),
        .init("late.plain.04", .overdue, nil, .plain,
              "{assignment} — {lateBy} late",
              "Albus will re-plan the rest around whatever you decide."),
        .init("late.plain.05", .overdue, nil, .plain,
              "Overdue",
              "{assignment}. Nothing is lost — the plan can be rebuilt."),
        .init("late.plain.06", .overdue, nil, .plain,
              "{assignment}",
              "The deadline has passed. Move it, or mark the work done."),
    ]
}

// MARK: - The plan stopped fitting
//
// The one notification no other study app can send, because it needs a
// scheduler that knows what will not fit rather than a list that does not.

extension Corpus {
    static let unfit: [CopyTemplate] = [
        .init("unfit.chaos.01", .planStoppedFitting, nil, .chaos,
              "The plan stopped fitting",
              "{count} steps have nowhere to go before their deadline."),
        .init("unfit.chaos.02", .planStoppedFitting, nil, .chaos,
              "I ran the numbers again",
              "They got worse. {count} steps no longer fit."),
        .init("unfit.chaos.03", .planStoppedFitting, nil, .chaos,
              "{assignment} doesn't fit",
              "{minutes} of work, not enough days. I'm not mad, I'm watching."),
        .init("unfit.chaos.04", .planStoppedFitting, nil, .chaos,
              "This won't fit",
              "{assignment}. Something has to move — the deadline or the plan."),
        .init("unfit.chaos.05", .planStoppedFitting, nil, .chaos,
              "Bad news, mathematically",
              "{count} steps can't be placed before they're due. Worth a look."),
        .init("unfit.chaos.06", .planStoppedFitting, nil, .chaos,
              "Out of room",
              "{assignment} needs more hours than there are. Re-plan or push it."),

        .init("unfit.plain.01", .planStoppedFitting, nil, .plain,
              "Your plan no longer fits",
              "{count} steps can't be scheduled before their deadline."),
        .init("unfit.plain.02", .planStoppedFitting, nil, .plain,
              "{assignment} doesn't fit",
              "About {minutes} of work has nowhere to go."),
    ]
}
