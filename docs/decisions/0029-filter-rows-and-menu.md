# 0029. Filter rows in the sidebar and a filter menu in the toolbar

Date: 2026-11-12
Status: Accepted

## Context
Browse filtered the selected folder with a segmented control of All, 5 Stars and Edited, with ⌘1–⌘3 in the View menu. Issue #58 asks for flags and every star rating, which is too many choices for a segmented control or for number shortcuts. A single list of choices also can't combine them, such as flagged photos with four stars or more. Photos and Lightroom offer both ways to filter: views across the library in the sidebar, and a filter for the current folder in the toolbar.

## Decision
- Under All Photos, the sidebar lists Flagged, Rejected, Edited, then 5 to 1 stars. Each row is a view across every available saved folder, read like All Photos (decision 0006). Like All Photos, it changes nothing on disk.
- Each row shows how many photos read so far match, zero included, so the list keeps its shape.
- Star rows match the exact rating, not "at least", and leave out rejected photos, as 5 Stars did. A rejected photo appears only under Rejected. In the toolbar menu, a rating leaves rejected photos out too, unless the flag is Rejected.
- Each sidebar row is a fixed set of toolbar criteria (`PhotoFilter.criteria`), so both match photos the same way.
- For a folder or All Photos, a toolbar button with `line.3.horizontal.decrease.circle` opens a menu of separate parts that combine, as in Lightroom's filter bar: a flag (Flagged, Unflagged or Rejected), a rating (1 to 5 stars, exactly or with Include Higher Ratings), and Edited Only. Every part that is set must match (`FilterCriteria`). Choices within one part are exclusive, so the meaning of two ticked items is never in doubt.
- While a filter is on, the button's symbol is filled and it shows the filter's name, such as "Flagged · 4+ Stars", so the state shows without an accent color or a custom pill. Clear Filter, at the top of the menu, turns it off. A count badge was left out: the subtitle already says "4 of 119 photos", and macOS toolbar buttons have no standard badge.
- View › Filter has the same items and is bound to the same value.
- The toolbar button is hidden while a filter row is selected, since that view is already filtered.
- ⌘1–⌘3 are removed.

## Consequences
- Counts reflect the folders read so far. Until All Photos or a filter row has been opened, folders the sidebar hasn't shown are not counted, and ratings stored only inside photos without a sidecar are read only for what is selected. A count can rise when a row is opened.
- Counting walks every read photo each time the sidebar redraws. That is fast for tens of thousands of photos; a cached count can replace it if libraries grow larger.
- A filter row is remembered between launches, like All Photos and folders. The toolbar filter is not.
