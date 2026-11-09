import Testing
@testable import ProofKit

struct EditHistoryTests {
    func recipe(exposure: Double, contrast: Double = 0) -> EditRecipe {
        var recipe = EditRecipe()
        recipe.basic.exposure = exposure
        recipe.basic.contrast = contrast
        return recipe
    }

    @Test("Undo and redo step through whole recipes")
    func undoRedo() {
        var history = EditHistory(EditRecipe())
        history.record(recipe(exposure: 1))
        history.record(recipe(exposure: 1, contrast: 20))

        // `#expect` can't call a mutating method, so each step's result is taken first.
        let firstUndo = history.undo()
        let secondUndo = history.undo()
        #expect(firstUndo == recipe(exposure: 1))
        #expect(secondUndo == EditRecipe())
        #expect(!history.canUndo)
        let firstRedo = history.redo()
        let secondRedo = history.redo()
        #expect(firstRedo == recipe(exposure: 1))
        #expect(secondRedo == recipe(exposure: 1, contrast: 20))
        #expect(!history.canRedo)
    }

    @Test("Recording the current edit adds no step")
    func unchangedAddsNoStep() {
        var history = EditHistory(recipe(exposure: 1))
        let recorded = history.record(recipe(exposure: 1))
        #expect(!recorded)
        #expect(!history.canUndo)
    }

    @Test("A new change after undo clears redo")
    func newChangeClearsRedo() {
        var history = EditHistory(EditRecipe())
        history.record(recipe(exposure: 1))
        history.undo()
        history.record(recipe(exposure: 2))
        #expect(!history.canRedo)
        let undone = history.undo()
        #expect(undone == EditRecipe())
    }

    @Test("Reverting a photo opened with an edit, and no steps yet, is one step that undo restores")
    func revertIsOneStep() {
        var history = EditHistory(recipe(exposure: 1, contrast: 20))
        history.record(EditRecipe())
        #expect(history.recipe == EditRecipe())
        let undone = history.undo()
        #expect(undone == recipe(exposure: 1, contrast: 20))
        #expect(!history.canUndo)
    }
}
