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

    @Test("The steps start with Opened and name each change")
    func stepLabels() {
        var history = EditHistory(EditRecipe())
        history.record(recipe(exposure: 0.3))
        history.record(recipe(exposure: 0.3, contrast: -10))
        history.record(EditRecipe(), label: "Revert")
        #expect(history.steps.map(\.label) == ["Opened", "Exposure +0.30", "Contrast −10", "Revert"])
        #expect(history.currentIndex == 3)
    }

    @Test("Going to a step keeps the later ones for redo, and a new change drops them")
    func goToStep() {
        var history = EditHistory(EditRecipe())
        history.record(recipe(exposure: 1))
        history.record(recipe(exposure: 2))
        history.record(recipe(exposure: 3))
        let shown = history.go(to: 1)
        #expect(shown == recipe(exposure: 1))
        #expect(history.steps.count == 4)
        let redone = history.redo()
        #expect(redone == recipe(exposure: 2))
        history.go(to: 0)
        history.record(recipe(exposure: 0, contrast: 5))
        #expect(history.steps.map(\.label) == ["Opened", "Contrast +5"])
        #expect(!history.canRedo)
    }

    @Test("Going to the step shown, or one that doesn't exist, changes nothing")
    func goToNowhere() {
        var history = EditHistory(EditRecipe())
        history.record(recipe(exposure: 1))
        let same = history.go(to: 1)
        let missing = history.go(to: 5)
        #expect(same == nil)
        #expect(missing == nil)
        #expect(history.currentIndex == 1)
    }
}

struct EditChangeLabelTests {
    @Test("A change to several Basic sliders, or several cards, is named by its extent")
    func severalChanges() {
        var tone = EditRecipe()
        tone.basic.exposure = 0.5
        tone.basic.shadows = 20
        #expect(tone.changeLabel(from: EditRecipe()) == "Basic")
        var pasted = tone
        pasted.vignette.amount = -30
        #expect(pasted.changeLabel(from: EditRecipe()) == "Several Adjustments")
    }

    @Test("White balance names the preset, or the slider with its value")
    func whiteBalance() {
        var auto = EditRecipe()
        auto.basic.whiteBalance = .auto
        auto.basic.temperature = 5200
        auto.basic.tint = 4
        #expect(auto.changeLabel(from: EditRecipe()) == "White Balance: Auto")
        var warmer = auto
        warmer.basic.temperature = 5600
        #expect(warmer.changeLabel(from: auto) == "Temperature 5600")
    }

    @Test("Looks name the LUT, or the strength when only it changed")
    func looks() {
        var look = EditRecipe()
        look.look = Look(lut: "Film/Portra 400.cube")
        #expect(look.changeLabel(from: EditRecipe()) == "Look: Portra 400")
        var weaker = look
        weaker.look?.strength = 0.8
        #expect(weaker.changeLabel(from: look) == "Look Strength 80%")
        #expect(EditRecipe().changeLabel(from: look) == "Look: None")
    }
}
