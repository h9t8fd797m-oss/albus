import SwiftData

/// The model list, in one place.
///
/// It was duplicated in the app and in two test targets, which is a drift bug
/// waiting to happen: adding a model and forgetting one copy fails at runtime
/// with a relationship error rather than at compile time. Now there is one list
/// and three call sites that cannot disagree with it.
enum AlbusSchema {
    static let models: [any PersistentModel.Type] = [
        Course.self,
        Assignment.self,
        Subtask.self,
        PlanSessionRecord.self,
        CompletionRecord.self,
        Rubric.self,
        RubricItem.self,
        Grading.self
    ]

    static var schema: Schema { Schema(models) }
}
