# Margin

A small native Mac Markdown editor with MDV-style document rendering and always-on, Obsidian-style editing. The document is always its own Markdown, styled in place; only the element under the cursor shows its markup. No added toolbar, mode switch, or document buttons.

## Install

Margin is not yet signed with an Apple Developer ID, so build it from source (Apple Silicon, macOS 13+, Xcode command-line tools, Node/npm):

```sh
npm ci
npm run build:app
cp -R build/Margin.app ~/Applications/
open ~/Applications/Margin.app
```

Keep one installed copy; launching several builds can register older copies and icons with macOS.

Margin uses one running app instance with multiple windows. Opening the app creates a blank window; the first file opened reuses it if it has never been edited or saved. Later files open in new windows. Reopening the same file focuses its existing window.

**File → Open Recent** lists recently opened or saved documents using macOS's persistent history. Choose a document to reopen it, or **Clear Menu** to clear that history.

In **Margin → Settings…** (**⌘,**), turn on **Prefer tabs** to open additional documents in native tabs within the active document window. The preference is saved between launches and defaults to off. Turning it off sends future documents to separate windows; existing tabs stay together. The first file still reuses an untouched startup window.

Use **⌘O** to open, **⌘N** for a new document, **⌘S** to save, **⇧⌘S** for Save As, **⌘Z / ⇧⌘Z** for undo/redo, and **⌘F** to find. **⌘B / ⌘I** add bold/italic Markdown around a selection. **Escape** leaves editing and renders everything. Command-click opens a web link.

Use **⌘+** (or **⌘=**) to zoom in, **⌘−** to zoom out, and **⌘0** to return to the default 120% scale. These commands also appear in the View menu. Zoom changes in 10% steps between 50% and 300% and applies to the current window. New windows open at the most recently chosen zoom. Additional windows open slightly offset from the current one.

**View → Show Outline** (**⌃⌘S**) shows a heading sidebar; click a heading to scroll to it, and the current section is highlighted as you read. **View → Show Word Count** shows a small count in the corner, including the selected word count when text is selected. Both are hidden by default, and the choice is remembered for all windows.

Editing works like Obsidian's Live Preview. Text stays in place and markup is hidden until the cursor touches it: `**`, `*`, `~~`, backticks and a link's `[…](url)` appear only while the cursor is inside that span; a heading's `#` and a quote's `>` appear while the cursor is on that line; a bullet shows as `•` until the cursor reaches its `-`. Images, inline math, rules and checkboxes render until the cursor enters them. Code blocks hide their fences (showing the language) until the cursor is inside. Display equations and diagrams render until clicked or entered, then show only their own source. Tables stay rendered and are edited cell by cell: click a cell (or arrow into the table) to edit its Markdown; Tab / Shift-Tab and Enter move between cells, and Escape or moving past the edge leaves the table. Every blank line is a visible row. Leaving the editor (Escape) renders everything. Markdown is always the source of truth; rendered HTML is never written back into your file.

Click a task checkbox to tick or untick it. Click a rendered link to open it (Command-click works anywhere, including while its Markdown is shown); a `#heading` link to scroll to that heading, or a relative link to another Markdown file to open it; links to other local files reveal them in Finder. Drop Markdown files onto a window to open them.

Drag or Shift-click to select; double-click selects a word and triple-click a line, even when placing the cursor reveals markup nearby. Enter continues a list, and Enter on an empty list item exits it. Undo and Redo apply to the focused document or text field, including the Find query.

Line shortcuts act on the rows you see, so a wrapped paragraph behaves like several lines: **⌃A / ⌃E**, **⌘← / ⌘→** and **Home / End** go to the start or end of the displayed row (add Shift to select), **⌃N / ⌃P** move one row down or up, **⌃L** selects the row, **⌃K** and **⌘⌫** delete to the row's end or start, and **⇧⌘K** deletes the row. Up and Down follow the displayed rows of wrapped text and retain the cursor's horizontal position across blocks. Shift-Up and Shift-Down extend the selection along those rows. Moving onto a heading keeps your horizontal position after its `#` appears.

## Build and check

Requires an Apple Silicon Mac with macOS 13+, Swift command-line tools, and Node/npm.

```sh
npm ci
npm run build:app
npm test
bash native/test-files.sh
bash native/test-integration.sh dist build/integration-check
bash native/test-invariants.sh dist build/invariant-check
```

The invariant suite runs every document in `native/invariant-corpus/` and checks, at every caret position, that Right/Left and Up/Down move predictably, nothing overlaps, typing and deletion change only the character at the caret, clicks land where clicked, markup stays hidden when rendered, and no script errors occur. Add a document there to cover a new combination of elements. Use a fresh output directory for each integration run. `npm run dev` serves a browser preview at `http://127.0.0.1:4173`; the preview downloads copies, while the Mac app saves files directly. Build dependencies are locked in `package-lock.json`; normal editing/rendering needs no network connection. Third-party license notices are bundled in the app.

## Current scope

- Document font, colors, 800px column and 120% default zoom follow MDV. This is an independent implementation, not a patched MDV binary.
- Supports common Markdown, task lists, tables, syntax-highlighted fences, KaTeX math, and Mermaid diagrams. The Mermaid library loads only when a document contains a diagram, and diagrams follow light/dark appearance changes. Frontmatter is shown as code. Raw HTML is shown literally; MDV-specific callouts, footnotes, print/export, and its Quick Look extension are not implemented.
- Local images load from relative paths (including `../`), absolute paths and `file:` URLs; only image files are served, and relative paths need a saved document. Remote images are blocked and the editor page has no network access. Image URLs stay unchanged in the saved Markdown.
- Documents that already have a file autosave about a second after typing pauses, when the window loses focus, and on close or quit. Untitled documents still ask to save. When another app changes an open file, Margin shows the new version immediately if you have no unsaved edits; otherwise it asks whether to keep your version or use the disk version. No crash-recovery journal for untitled drafts.
- UTF-8 BOM and uniform line endings are preserved. A no-op save preserves mixed line endings; editing a mixed-ending file normalizes it to its first newline convention.
- Builds are signed locally, not notarized. Margin does not change default file associations.

Run `bash native/test-lifecycle.sh` and `bash native/test-single-instance.sh` for lifecycle checks, and `bash native/test-zoom.sh` for zoom shortcuts.

References: [MDV](https://www.mowglii.com/mdv/), [Clearance](https://github.com/prime-radiant-inc/clearance) (reviewed native/editor architecture), and [CodeMirror](https://codemirror.net/). No MDV, Obsidian, or Clearance source code is incorporated.

Text selection uses the native gold highlight so it stays visible over code and other shaded text; a table inside a selection is highlighted as a whole.

HTML `<img>` tags are supported in paragraphs and table cells, including `src`, `width`, `height`, and `alt` attributes. Relative image paths resolve against the saved Markdown file's folder, including `../` paths. Other raw HTML remains literal text, and escaped tags and code examples stay literal.

Every source line is a displayed row, including single line breaks and blank lines. Tables support `<br>` for line breaks within cells; source line endings stay unchanged.

## License

[MIT](LICENSE). Third-party notices for bundled packages are generated into `dist/ThirdPartyNotices.txt` and included in the app.
