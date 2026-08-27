import SwiftUI
import SwiftData
import AlbusCore

/// Ask Albus: a conversation grounded in one assignment.
///
/// This was a tab. It is not any more — a general chat surface competes with
/// the free frontier products every student already has, and loses; a
/// conversation that already knows the rubric, the plan and the deadline does
/// not. So the only way in is from the assignment itself, which is also what
/// makes the grounding free rather than something the student has to set up.
///
/// The tab version carried an assignment *picker*, which is the tell: it
/// existed because the surface had no context of its own and had to ask for it.

struct AskAlbusSheet: View {
    @Environment(\.dismiss) private var dismiss
    let assignment: Assignment

    var body: some View {
        NavigationStack {
            Screen {
                Conversation(assignment: assignment)
            }
            .navigationTitle(assignment.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Tokens.Palette.accent)
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(.clear)
    }
}

/// The conversation itself. Owns its transcript and nothing else.
struct Conversation: View {
    let assignment: Assignment?

    @State private var turns: [ChatService.Turn] = []
    /// 1-based, when the student narrowed the question to one step.
    @State private var focusStep: Int?
    @State private var draft = ""
    @State private var isSending = false
    @State private var failure: String?
    @FocusState private var isFocused: Bool

    private let service = ChatService()

    var body: some View {
        VStack(spacing: 0) {
            stepPicker
            transcript
            composer
        }
        // A new grounding is a new conversation; carrying turns across would
        // send one assignment's history as context for another.
        .onChange(of: assignment?.id) {
            turns.removeAll()
            failure = nil
            focusStep = nil
        }
    }

    /// Narrowing the question to one step.
    ///
    /// The whole plan still reaches the model either way — this says which part
    /// of it the question is about, which is the difference between "how do I
    /// start?" being answered about the essay and about the paragraph in front
    /// of them.
    @ViewBuilder private var stepPicker: some View {
        let steps = (assignment?.subtasks ?? []).sorted { $0.ordinal < $1.ordinal }
        if steps.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Tokens.Spacing.s) {
                    FilterChip(title: "Whole plan", isSelected: focusStep == nil) {
                        withAnimation(Tokens.Motion.quick) { focusStep = nil }
                    }
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        FilterChip(title: "\(index + 1). \(step.title)",
                                   isSelected: focusStep == index + 1) {
                            withAnimation(Tokens.Motion.quick) {
                                focusStep = focusStep == index + 1 ? nil : index + 1
                            }
                        }
                    }
                }
                .padding(.horizontal, Tokens.Spacing.xl)
            }
            .scrollClipDisabled()
            .padding(.bottom, Tokens.Spacing.m)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                    if turns.isEmpty { opener }
                    ForEach(turns) { turn in
                        Bubble(turn: turn).id(turn.id)
                    }
                    if isSending {
                        StatusBanner(tone: .working, message: "Albus is thinking…")
                            .id("thinking")
                    }
                    if let failure {
                        StatusBanner(tone: .error, message: failure, retryTitle: "Retry") {
                            Task { await retry() }
                        }
                    }
                }
                .padding(.horizontal, Tokens.Spacing.xl)
                .padding(.vertical, Tokens.Spacing.m)
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: turns.count) {
                withAnimation(Tokens.Motion.quick) {
                    proxy.scrollTo(turns.last?.id, anchor: .bottom)
                }
            }
        }
    }

    private var opener: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            AlbusNote(assignment == nil
                      ? "Ask me about planning and studying. Pick an assignment above and I can answer about that specific plan."
                      : "Ask me anything about **\(assignment?.title ?? "")** — where to start, how to structure it, what the rubric wants.")
            if assignment != nil {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    ForEach(Self.suggestions, id: \.self) { suggestion in
                        Button {
                            draft = suggestion
                            Task { await send() }
                        } label: {
                            HStack {
                                Text(suggestion)
                                    .font(Tokens.Typography.caption)
                                    .foregroundStyle(Tokens.Palette.accent)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, Tokens.Spacing.m)
                            .padding(.vertical, Tokens.Spacing.s)
                            .background(Tokens.Palette.accentWash,
                                        in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private static let suggestions = [
        "Where should I start?",
        "What does the rubric actually want?",
        "I'm stuck — break this down further."
    ]

    private var composer: some View {
        HStack(spacing: Tokens.Spacing.s) {
            TextField("Ask Albus…", text: $draft, axis: .vertical)
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Palette.ink)
                .lineLimit(1...4)
                .focused($isFocused)
                .submitLabel(.send)
                .padding(.horizontal, Tokens.Spacing.l)
                .padding(.vertical, Tokens.Spacing.m)
                .background(Tokens.Glass.fill,
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                        .strokeBorder(Tokens.Palette.hairline, lineWidth: 0.5)
                }

            Button {
                Task { await send() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(canSend ? Tokens.Palette.accent
                                : Tokens.Palette.inkMuted.opacity(0.4), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, Tokens.Spacing.xl)
        .padding(.vertical, Tokens.Spacing.m)
    }

    private var canSend: Bool {
        !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() async {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isSending else { return }

        draft = ""
        failure = nil
        turns.append(.init(role: .user, content: message))
        await deliver(message)
    }

    /// Re-sends the last question after a failure, without duplicating it in
    /// the transcript.
    private func retry() async {
        guard let last = turns.last(where: { $0.role == .user }) else { return }
        failure = nil
        await deliver(last.content)
    }

    private func deliver(_ message: String) async {
        isSending = true
        defer { isSending = false }

        // History excludes the message being sent — the server appends it.
        let history = Array(turns.dropLast())

        do {
            let reply = try await service.send(message, about: assignment?.remoteID,
                                               step: focusStep, history: history)
            turns.append(.init(role: .assistant, content: reply.reply))
        } catch let error as ChatService.Failure {
            failure = error.errorDescription ?? "Albus couldn't answer."
        } catch {
            failure = "Albus couldn't answer."
        }
    }

    private struct Bubble: View {
        let turn: ChatService.Turn

        private var isUser: Bool { turn.role == .user }

        var body: some View {
            HStack {
                if isUser { Spacer(minLength: Tokens.Spacing.xxl) }
                Text(turn.content)
                    .font(Tokens.Typography.body)
                    .foregroundStyle(isUser ? .white : Tokens.Palette.ink)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Tokens.Spacing.l)
                    .padding(.vertical, Tokens.Spacing.m)
                    .background {
                        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
                        if isUser {
                            shape.fill(Tokens.Palette.accent)
                        } else {
                            shape.fill(Tokens.Glass.fill)
                                .overlay { shape.strokeBorder(Tokens.Glass.stroke, lineWidth: 1) }
                        }
                    }
                if !isUser { Spacer(minLength: Tokens.Spacing.xxl) }
            }
            .accessibilityLabel(isUser ? "You said" : "Albus said")
            .accessibilityValue(turn.content)
        }
    }
}
