# 0037. The toolbar filter narrows a sidebar filter row

Date: 2026-11-15
Status: Accepted

## Context
Decisions 0029 and 0033 hid the toolbar filter while a sidebar filter row was selected, in Browse and in Edit, since the row is already filtered. Issue #182 asks to narrow a row further, such as to flagged photos within 4 Stars, especially in the filmstrip. Checking the row and then the toolbar filter one after the other gave unexpected results: a rating leaves rejected photos out unless the flag is Rejected, so 3 Stars inside the Rejected row showed nothing.

## Decision
- The toolbar filter button and View › Filter appear on filter rows too, in Browse and in Edit, with every choice available.
- The row's criteria and the toolbar's are merged into one set of criteria (`FilterCriteria.narrowed(by:)`), and a photo shows only if it passes both. Because they are merged, the rejected-photo rule sees a flag from either side: Rejected with 3 Stars and 3 Stars with a Rejected flag show the same photos.
- Ratings merge to the narrower one: 5 Stars with 4+ Stars is 5 Stars, and 2+ with 4+ is 4+. Parts that can't both hold, such as the Flagged row with a Rejected flag, or 5 Stars with exactly 4 stars, match no photo: Browse shows No Matching Photos, and in Edit the filmstrip shows its message with Clear Filter.
- The toolbar filter stays set when the sidebar selection changes, as it already did between folders, and going back from Edit keeps it.

## Consequences
- A row with a toolbar filter on can show fewer photos than its sidebar count, which counts the row alone.
- The menu doesn't dim the choices a row already sets; picking one that contradicts the row shows no photos.
