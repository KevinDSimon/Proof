/// One photo's edit and its undo and redo steps. Each step is a whole recipe, so undo restores
/// every control at once, whichever one changed. The History panel lists the same steps.
public struct EditHistory: Equatable, Sendable {
    /// One entry in the History panel: the edit after a change, and the change's name.
    public struct Step: Equatable, Sendable {
        public var recipe: EditRecipe
        /// Such as "Exposure +0.30"; "Opened" for the edit the photo opened with.
        public var label: String
    }

    public static let openedLabel = "Opened"
    public static let originalLabel = "Original"

    /// Every step, oldest first: the photo's original, the edit as opened when it differs, then
    /// each change, including those undone.
    public private(set) var steps: [Step]
    /// The step shown. Steps after it are the ones Redo brings back.
    public private(set) var currentIndex = 0

    /// `original` is the photo with no edit. It comes first, so it can be reached however the
    /// photo was edited before it was opened; it is the only step when it is the edit opened.
    public init(_ recipe: EditRecipe, original: EditRecipe? = nil) {
        guard let original else {
            steps = [Step(recipe: recipe, label: Self.openedLabel)]
            return
        }
        steps = [Step(recipe: original, label: Self.originalLabel)]
        if recipe != original {
            steps.append(Step(recipe: recipe, label: Self.openedLabel))
            currentIndex = 1
        }
    }

    public var recipe: EditRecipe { steps[currentIndex].recipe }
    public var canUndo: Bool { currentIndex > 0 }
    public var canRedo: Bool { currentIndex < steps.count - 1 }

    /// Makes `recipe` the current edit as one undo step and drops the steps after the current
    /// one. `label` names the change; without it the label says what differs from the current
    /// edit. Returns `false`, and records nothing, when it is the current edit already.
    @discardableResult
    public mutating func record(_ recipe: EditRecipe, label: String? = nil) -> Bool {
        guard recipe != self.recipe else { return false }
        let label = label ?? recipe.changeLabel(from: self.recipe)
        steps.removeSubrange((currentIndex + 1)...)
        steps.append(Step(recipe: recipe, label: label))
        currentIndex += 1
        return true
    }

    /// Returns to the edit before the last step; `nil` when there is none.
    @discardableResult
    public mutating func undo() -> EditRecipe? {
        guard canUndo else { return nil }
        currentIndex -= 1
        return recipe
    }

    /// Repeats the last undone step; `nil` when there is none.
    @discardableResult
    public mutating func redo() -> EditRecipe? {
        guard canRedo else { return nil }
        currentIndex += 1
        return recipe
    }

    /// Shows the edit as it was at step `index`, keeping the later steps for Redo; `nil` when
    /// there is no such step or it is shown already.
    @discardableResult
    public mutating func go(to index: Int) -> EditRecipe? {
        guard steps.indices.contains(index), index != currentIndex else { return nil }
        currentIndex = index
        return recipe
    }
}
