/// One photo's edit and its undo and redo steps. Each step is a whole recipe, so undo restores
/// every control at once, whichever one changed.
public struct EditHistory: Equatable, Sendable {
    public private(set) var recipe: EditRecipe
    private var undoSteps: [EditRecipe] = []
    private var redoSteps: [EditRecipe] = []

    public init(_ recipe: EditRecipe) {
        self.recipe = recipe
    }

    public var canUndo: Bool { !undoSteps.isEmpty }
    public var canRedo: Bool { !redoSteps.isEmpty }

    /// Makes `recipe` the current edit as one undo step and clears redo. Returns `false`, and
    /// records nothing, when it is the current edit already.
    @discardableResult
    public mutating func record(_ recipe: EditRecipe) -> Bool {
        guard recipe != self.recipe else { return false }
        undoSteps.append(self.recipe)
        redoSteps = []
        self.recipe = recipe
        return true
    }

    /// Returns to the edit before the last step; `nil` when there is none.
    @discardableResult
    public mutating func undo() -> EditRecipe? {
        guard let previous = undoSteps.popLast() else { return nil }
        redoSteps.append(recipe)
        recipe = previous
        return recipe
    }

    /// Repeats the last undone step; `nil` when there is none.
    @discardableResult
    public mutating func redo() -> EditRecipe? {
        guard let next = redoSteps.popLast() else { return nil }
        undoSteps.append(recipe)
        recipe = next
        return recipe
    }
}
