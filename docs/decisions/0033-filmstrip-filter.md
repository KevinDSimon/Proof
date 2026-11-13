# 0033. One filter for Browse and the filmstrip

Date: 2026-11-13
Status: Accepted

## Context
Issue #160 asks for a way to narrow the filmstrip in Edit, such as to flagged or 4-star photos, so moving between photos skips the rest. The filmstrip already showed the photos that pass the Browse filter, but the filter couldn't be changed in Edit. The project rules keep browsing controls out of Edit. The filmstrip could have had a filter of its own, but then the grid and the filmstrip could show different photos, and returning to Browse could select a photo the grid hides.

## Decision
- The filmstrip and the Browse grid share one filter (`Library.filter`). The owner chose this: filtering in either mode narrows both.
- In Edit, the filter is the same toolbar button as in Browse, grouped with a Hide Filmstrip button, which replaces the chevron between the photo and the card. While a filter is on, the button shows how many parts are set, so it reads as on without an accent color. The card holds only thumbnails. A header row inside the card, with small capsule buttons, was tried first; it made the card heavy and pushed the thumbnails down. The Filter menu in the menu bar works in Edit too.
- While a sidebar filter row is selected, the button shows the row's name and can't be changed, as in Browse.
- The filter gains Unedited: the Edits part is Edited or Not, Edited, or Unedited (`FilterCriteria.Edits`), replacing Edited Only.
- In Edit, a photo that stops matching, because its rating, flag or edit changed or because the filter changed, stays in the filmstrip until another photo is shown. When no photo matches, Edit stays open on the photo shown, and the filmstrip card shows only a centered message with Clear Filter. Keeping that photo in the strip beside the message was tried first; it read as a match for a filter it fails.

## Consequences
- The filter is the one browsing control that also appears in Edit, and only next to the filmstrip, which belongs to Edit.
- Photos kept after a change disappear sooner in Edit than in Browse, where they stay until the filter or folder changes.
