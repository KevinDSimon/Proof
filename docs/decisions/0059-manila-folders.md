# 0059. Folders are shown as manila folders

Date: 2026-11-28
Status: Accepted

## Context
Folders were shown with the system's gray folder symbol. A folder's subfolders now also show as tiles at the start of its grid, beside the photos (#313), where a thin gray symbol read as a placeholder rather than a folder. The person wanted folders to look like the manila folders a darkroom keeps prints in. That puts a warm color in the interface, which is otherwise black, white and gray with one highlight color for small marks of state (decision 0041).

## Decision
Every folder in Proof, in the sidebar on the Mac and iPad, the library on iPhone and the folder tiles at the start of every grid, is drawn with one image of a tan manila folder with papers in it. It is a PNG, 480 pixels wide with a transparent background, in an asset catalog in `ProofUI`'s resources (`Image.manilaFolder`), so the Mac and iOS apps use the same image. It was made from a generated illustration, cut out of its white background and cropped to the folder.

In a list row it is about as wide as a row's symbol, 18 points on the Mac and 26 on iPad and iPhone, larger with the text size. In a grid tile it is about three quarters of the tile's width, centered in the square a photo sits in. A folder that can't be reached shows it at half opacity.

The exception is for folder artwork only. The rows that aren't folders, such as All Photos and the filters, keep their gray symbols, and the highlight color keeps the uses decision 0041 gives it.

## Consequences
- Folders and photos are told apart at a glance, in lists and in the grid.
- The folder's tan sits beside the photos in the grid and the sidebar. It is a small, flat area, but it is a color the person sees while judging photos' colors.
- An image doesn't take a selected row's text color as a symbol does, so a selected folder row keeps the tan folder.
- The image is a bitmap: at very large text sizes it is scaled up past 480 pixels and softens a little.
