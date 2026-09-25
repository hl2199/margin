import { EditorSelection, EditorState, Transaction } from '@codemirror/state';
import { EditorView, keymap, highlightSpecialChars } from '@codemirror/view';
import { history, historyKeymap, defaultKeymap, undo, redo, indentWithTab, cursorLineDown, cursorLineUp, selectLineDown, selectLineUp } from '@codemirror/commands';
import { markdown, markdownKeymap, insertNewlineContinueMarkupCommand } from '@codemirror/lang-markdown';
import { syntaxTree } from '@codemirror/language';
import { markdownExtensions } from './markdown-syntax.js';
import { search, searchKeymap, openSearchPanel } from '@codemirror/search';
import { editingField, editingEffect, refreshEffect, livePreview, specialBlocks, tableElement, wrapCellSelection } from './live-preview.js';
import './style.css';
import 'katex/dist/katex.min.css';
import welcome from './welcome.md';

const native = window.webkit?.messageHandlers?.margin;
const continueMarkup = insertNewlineContinueMarkupCommand({ nonTightLists: false });
let info = { name: 'Untitled', path: null, dirty: false };
let pristine = '';
let noticeTimer;
function post(type, detail = {}) { native?.postMessage({ type, documentID: info.documentID || '', ...detail }); }
function notice(message) {
  const element = document.querySelector('#notice');
  element.textContent = message; element.hidden = false;
  clearTimeout(noticeTimer); noticeTimer = setTimeout(() => { element.hidden = true; }, 3500);
}
function wrapSelection(marker, end = marker) {
  if (wrapCellSelection(marker, end)) return true;
  const selection = view.state.selection.main;
  view.dispatch({ changes: { from: selection.from, to: selection.to, insert: marker + view.state.sliceDoc(selection.from, selection.to) + end }, selection: { anchor: selection.from + marker.length, head: selection.to + marker.length }, userEvent: 'input' });
  return true;
}
// Line commands act on the rows the reader sees, so a wrapped paragraph behaves
// like several lines. At a wrap point the caret's side decides which row it is on.
function rowEdges(range = view.state.selection.main) {
  const caret = EditorSelection.cursor(range.head, range.assoc);
  return { start: view.moveToLineBoundary(caret, false, true), end: view.moveToLineBoundary(caret, true, true) };
}
function rowBoundary(end, extend = false) {
  const current = view.state.selection.main;
  const target = rowEdges()[end ? 'end' : 'start'];
  const range = extend ? EditorSelection.range(current.anchor, target.head, undefined, undefined, target.assoc) : target;
  view.dispatch({ selection: EditorSelection.create([range]), effects: editingEffect.of(true), scrollIntoView: true, userEvent: 'select' });
  return true;
}
function selectRow() {
  const { start, end } = rowEdges();
  view.dispatch({ selection: EditorSelection.create([EditorSelection.range(start.head, end.head, undefined, undefined, -1)]), effects: editingEffect.of(true), userEvent: 'select' });
  return true;
}
function deleteRange(from, to, userEvent) {
  if (from === to) return false;
  view.dispatch({ changes: { from, to }, selection: { anchor: from }, scrollIntoView: true, userEvent });
  return true;
}
function deleteToRowEnd() {
  const current = view.state.selection.main;
  if (!current.empty) return deleteRange(current.from, current.to, 'delete.forward');
  const end = rowEdges().end.head;
  // At the end of a paragraph, join the next line, as Control-K does elsewhere.
  return deleteRange(current.head, end > current.head ? end : Math.min(end + 1, view.state.doc.length), 'delete.forward');
}
function deleteRow() {
  const { start, end } = rowEdges();
  const line = view.state.doc.lineAt(start.head);
  // Removing a paragraph's only or final row also removes its line break.
  if (end.head < line.to || start.head > line.from) return deleteRange(start.head, end.head, 'delete.line');
  if (line.to < view.state.doc.length) return deleteRange(line.from, line.to + 1, 'delete.line');
  return deleteRange(Math.max(0, line.from - 1), line.to, 'delete.line');
}
// Up and Down move by displayed rows and keep a horizontal goal. Entering a line
// reveals its markup (a heading's `##`), which shifts its text, so the goal is
// applied after that line has been revealed. A table is a widget, so crossing
// into one enters its nearest cell instead of skipping it.
function verticalLine(direction, extend = false) {
  const { state } = view;
  const current = state.selection.main;
  const line = state.doc.lineAt(current.head);
  const moved = view.moveVertically(current, direction > 0);
  let target = state.doc.lineAt(moved.head);
  // A rendered equation or diagram is one widget, which vertical motion would
  // step over. Stop on its nearest line instead, which reveals its source.
  const skipped = specialBlocks(state).find(block => block.type === 'preview'
    && (direction > 0 ? block.from > line.to && block.from <= moved.head : block.to < line.from && block.to >= moved.head));
  if (skipped) target = state.doc.lineAt(direction > 0 ? skipped.from : skipped.to);
  if (!skipped && (target.number === line.number || moved.head === current.head))
    return (direction > 0 ? (extend ? selectLineDown : cursorLineDown) : (extend ? selectLineUp : cursorLineUp))(view);
  const next = state.doc.line(Math.max(1, Math.min(state.doc.lines, line.number + direction)));
  const table = !extend && specialBlocks(state).find(block => block.type === 'table' && (direction > 0 ? block.from === next.from : block.to === next.to));
  const element = table && tableElement(view, table.from);
  if (element) { element.enterCell(direction > 0 ? 0 : Infinity, 0); return true; }
  const caret = view.coordsAtPos(current.head, current.assoc || 1);
  const left = view.contentDOM.getBoundingClientRect().left;
  const goal = current.goalColumn ?? (caret ? caret.left - left : 0);
  const edge = direction > 0 ? target.from : target.to;
  view.dispatch({ selection: extend ? EditorSelection.range(current.anchor, edge) : EditorSelection.cursor(edge) });
  const coords = view.coordsAtPos(edge, direction > 0 ? 1 : -1);
  let head = edge, assoc = direction > 0 ? 1 : -1;
  if (coords) {
    const y = (coords.top + coords.bottom) / 2;
    head = Math.max(target.from, Math.min(target.to, view.posAtCoords({ x: left + goal, y }, false) ?? edge));
    // At a soft wrap, the same offset has two visual positions; pick this row's.
    const before = view.coordsAtPos(head, -1), after = view.coordsAtPos(head, 1);
    if (before && after) assoc = Math.abs((before.top + before.bottom) / 2 - y) < Math.abs((after.top + after.bottom) / 2 - y) ? -1 : 1;
  }
  const range = extend ? EditorSelection.range(current.anchor, head, goal, undefined, assoc) : EditorSelection.cursor(head, assoc, undefined, goal);
  view.dispatch({ selection: EditorSelection.create([range]), effects: editingEffect.of(true), scrollIntoView: true, userEvent: 'select.vertical' });
  return true;
}
const extensions = () => [
  history(), highlightSpecialChars(), markdown({ extensions: markdownExtensions, addKeymap: false }),
  EditorView.lineWrapping, search({ top: true }), livePreview,
  EditorView.contentAttributes.of({ 'aria-label': 'Markdown editor', spellcheck: 'true', autocapitalize: 'off', autocorrect: 'off' }),
  keymap.of([
    { key: 'ArrowDown', run: () => verticalLine(1), shift: () => verticalLine(1, true) },
    { key: 'ArrowUp', run: () => verticalLine(-1), shift: () => verticalLine(-1, true) },
    { key: 'Ctrl-n', run: () => verticalLine(1), shift: () => verticalLine(1, true) },
    { key: 'Ctrl-p', run: () => verticalLine(-1), shift: () => verticalLine(-1, true) },
    { key: 'Mod-ArrowRight', run: () => rowBoundary(true), shift: () => rowBoundary(true, true) },
    { key: 'Mod-ArrowLeft', run: () => rowBoundary(false), shift: () => rowBoundary(false, true) },
    { key: 'Ctrl-e', run: () => rowBoundary(true), shift: () => rowBoundary(true, true) },
    { key: 'Ctrl-a', run: () => rowBoundary(false), shift: () => rowBoundary(false, true) },
    { key: 'End', run: () => rowBoundary(true), shift: () => rowBoundary(true, true) },
    { key: 'Home', run: () => rowBoundary(false), shift: () => rowBoundary(false, true) },
    { key: 'Ctrl-k', run: deleteToRowEnd },
    { key: 'Ctrl-l', run: selectRow },
    { key: 'Shift-Mod-k', run: deleteRow },
    { key: 'Mod-s', run: () => { save(); return true; } },
    { key: 'Mod-Shift-s', run: () => { save(true); return true; } },
    { key: 'Mod-o', run: () => { native ? post('open') : openBrowserFile(); return true; } },
    { key: 'Mod-n', run: () => { if (native) post('new'); return !!native; } },
    { key: 'Mod-b', run: () => wrapSelection('**') },
    { key: 'Mod-i', run: () => wrapSelection('*') },
    { key: 'Mod-k', run: () => wrapSelection('[', '](url)') },
    { key: 'Escape', run: () => { view.dispatch({ effects: editingEffect.of(false) }); view.contentDOM.blur(); return true; } },
    ...historyKeymap, ...searchKeymap,
    ...markdownKeymap.map(binding => binding.key === 'Enter' ? { ...binding, run: continueMarkup } : binding),
    ...defaultKeymap, indentWithTab
  ]),
  EditorView.domEventHandlers({
    focus: () => { if (!view.state.field(editingField)) view.dispatch({ effects: editingEffect.of(true) }); },
    blur: () => { setTimeout(() => { if (!view.hasFocus && !view.dom.contains(document.activeElement)) view.dispatch({ effects: editingEffect.of(false) }); }, 0); },
    // Focusing turns editing on. Doing it at mousedown would reveal markup at the
    // old selection and shift the text before the click position is measured.
    mousedown: () => false
  }),
  EditorView.updateListener.of(update => {
    if (update.docChanged) {
      const text = getText();
      info.dirty = text !== pristine;
      document.title = info.name + (info.dirty ? ' — Edited' : '') + ' — Margin';
      post('change', { text });
    }
    if (update.docChanged || update.selectionSet) schedulePanels();
  })
];
const view = new EditorView({ state: EditorState.create({ doc: '', extensions: extensions() }), parent: document.querySelector('#editor') });
function getText() { return view.state.sliceDoc(); }
function loadDocument(document) {
  info = { ...info, ...document };
  pristine = document.text ?? '';
  view.setState(EditorState.create({ doc: pristine, extensions: [...extensions(), EditorState.lineSeparator.of(pristine.includes('\r\n') ? '\r\n' : '\n')] }));
  documentTitle();
  view.scrollDOM.scrollTop = 0;
  schedulePanels();
}
// Another app changed the file while this window had no unsaved edits. Apply
// only the differing span so scroll position, selection and history survive.
function reloadDocument(document) {
  info = { ...info, ...document };
  const current = view.state.doc.toString(), next = document.text ?? '';
  pristine = next;
  if (current !== next) {
    const max = Math.min(current.length, next.length);
    let start = 0, end = 0;
    while (start < max && current.charCodeAt(start) === next.charCodeAt(start)) start++;
    while (end < max - start && current.charCodeAt(current.length - 1 - end) === next.charCodeAt(next.length - 1 - end)) end++;
    view.dispatch({ changes: { from: start, to: current.length - end, insert: next.slice(start, next.length - end) },
      annotations: Transaction.addToHistory.of(false) });
  }
  documentTitle();
}
function documentTitle() { document.title = info.name + (info.dirty ? ' — Edited' : '') + ' — Margin'; }
function setDocumentInfo(document) {
  const previousPath = info.path;
  info = { ...info, ...document };
  if (!document.dirty) pristine = getText();
  documentTitle();
  if (previousPath !== info.path) view.dispatch({ effects: refreshEffect.of(true) });
}
function save(as = false) {
  if (native) { post(as ? 'saveAs' : 'save', { text: getText() }); return; }
  const a = document.createElement('a');
  const url = URL.createObjectURL(new Blob([getText()], { type: 'text/markdown;charset=utf-8' }));
  a.href = url; a.download = info.name === 'Untitled' ? 'Untitled.md' : info.name; a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  notice('Downloaded a Markdown copy. Use the Mac app to save directly to your file.');
}
function openBrowserFile() {
  const input = document.createElement('input'); input.type = 'file'; input.accept = '.md,.markdown,.mdown,.txt';
  input.onchange = async () => { if (input.files[0]) loadDocument({ text: await input.files[0].text(), name: input.files[0].name, dirty: false }); };
  if (!info.dirty || confirm('Discard unsaved changes and open another file?')) input.click();
}
function openLink(href) {
  if (!href) return;
  if (href.startsWith('#')) { scrollToAnchor(href.slice(1)); return; }
  if (native) post('openLink', { url: href });
  else if (/^https?:\/\//.test(href)) window.open(href, '_blank', 'noopener');
}
// Selection access for native checks.
const selectionState = () => ({ anchor: view.state.selection.main.anchor, head: view.state.selection.main.head, length: view.state.doc.length, editing: view.state.field(editingField) });
const setSelection = (anchor, head = anchor) => { view.focus(); view.dispatch({ selection: { anchor, head }, effects: editingEffect.of(true), scrollIntoView: true }); };
window.margin = { loadDocument, reloadDocument, setDocumentInfo, setPanels, selectionState, setSelection, getText, openLink, assetRoot: () => info.path || '', command(command) {
  switch (command) {
    case 'undo': undo(view); break;
    case 'redo': redo(view); break;
    case 'find': view.dispatch({ effects: editingEffect.of(true) }); openSearchPanel(view); break;
    case 'save': save(); break;
    case 'saveAs': save(true); break;
    case 'selectAll': view.dispatch({ selection: { anchor: 0, head: view.state.doc.length }, effects: editingEffect.of(true) }); view.focus(); break;
    case 'bold': wrapSelection('**'); break;
    case 'italic': wrapSelection('*'); break;
    case 'link': wrapSelection('[', '](url)'); break;
  }
} };
// Optional outline and word count. Both are hidden unless enabled in the View menu.
const panels = { outline: false, wordCount: false };
const outlineElement = document.querySelector('#outline');
const wordCountElement = document.querySelector('#word-count');
let panelTimer;
// Markup inside a heading that is not part of its readable text.
const headingMarkup = new Set(['HeaderMark', 'EmphasisMark', 'CodeMark', 'LinkMark', 'URL', 'LinkTitle', 'StrikethroughMark', 'InlineMathMark', 'Escape']);
function headings() {
  const { state } = view;
  const seen = new Map();
  const entries = [];
  syntaxTree(state).iterate({ enter(node) {
    const heading = node.name.match(/^(?:ATX|Setext)Heading([1-6])$/);
    if (!heading) return !['Paragraph', 'FencedCode', 'CodeBlock', 'Table', 'BlockMath', 'Frontmatter', 'HTMLBlock'].includes(node.name);
    // Readable text: the heading without its markers (setext: first line only).
    const end = node.name.startsWith('Setext') ? state.doc.lineAt(node.from).to : node.to;
    let text = '', pos = node.from;
    node.node.toTree().iterate({ enter(child) {
      if (child.type.name === 'Escape') { text += state.sliceDoc(pos, node.from + child.from); pos = node.from + child.from + 1; return false; }
      if (!headingMarkup.has(child.type.name)) return;
      const from = node.from + child.from, to = Math.min(end, node.from + child.to);
      if (from >= end) return false;
      text += state.sliceDoc(pos, from); pos = Math.max(pos, to);
      return false;
    } });
    text = (text + state.sliceDoc(pos, end)).trim();
    // GitHub-style anchors: lowercase, punctuation removed, spaces to hyphens.
    const base = text.toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, '').replace(/\s/g, '-');
    const count = seen.get(base) ?? 0;
    seen.set(base, count + 1);
    entries.push({ text, level: Number(heading[1]), line: state.doc.lineAt(node.from).number - 1, slug: count ? `${base}-${count}` : base });
    return false;
  } });
  return entries;
}
function scrollToLine(index) {
  const line = view.state.doc.line(Math.min(index + 1, view.state.doc.lines));
  view.dispatch({ effects: EditorView.scrollIntoView(line.from, { y: 'start', yMargin: 12 }) });
  setTimeout(markCurrentHeading, 100);
}
function scrollToAnchor(anchor) {
  let target = anchor;
  try { target = decodeURIComponent(anchor); } catch { /* Keep the literal anchor. */ }
  const heading = headings().find(entry => entry.slug === target.toLowerCase());
  if (heading) scrollToLine(heading.line);
}
function renderOutline() {
  const entries = headings();
  const top = Math.min(...entries.map(entry => entry.level));
  outlineElement.replaceChildren(...entries.map(entry => {
    const link = document.createElement('a');
    link.textContent = entry.text || 'Untitled heading';
    link.title = entry.text;
    link.dataset.line = String(entry.line);
    link.style.paddingLeft = `${8 + (entry.level - top) * 12}px`;
    return link;
  }));
  if (!entries.length) {
    const empty = document.createElement('div');
    empty.className = 'empty'; empty.textContent = 'No headings';
    outlineElement.append(empty);
  }
  markCurrentHeading();
}
function markCurrentHeading() {
  if (!panels.outline) return;
  // The section at the top of the viewport, from CodeMirror's height map. At the
  // end of the document, later headings can never reach the top; use the bottom.
  const scroller = view.scrollDOM;
  const atEnd = scroller.scrollTop + scroller.clientHeight >= scroller.scrollHeight - 2;
  const rect = scroller.getBoundingClientRect();
  const block = view.lineBlockAtHeight((atEnd ? rect.bottom - 24 : rect.top + 24) - view.documentTop);
  const topLine = view.state.doc.lineAt(block.from).number - 1;
  const links = [...outlineElement.querySelectorAll('a')];
  const current = links.filter(link => Number(link.dataset.line) <= topLine).pop() ?? links[0];
  for (const link of links) link.classList.toggle('current', link === current);
}
function countWords(text) {
  // Link targets and image tags are not prose. CJK characters count individually.
  const prose = text.replace(/\]\([^)]*\)/g, ']').replace(/<img\b[^>]*>/gi, '');
  return prose.match(/[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]|[\p{L}\p{N}][\p{L}\p{N}\p{M}'’_-]*/gu)?.length ?? 0;
}
function renderWordCount() {
  const format = number => number.toLocaleString();
  const total = countWords(view.state.doc.toString());
  const selected = view.state.selection.ranges.filter(range => !range.empty)
    .reduce((sum, range) => sum + countWords(view.state.sliceDoc(range.from, range.to)), 0);
  wordCountElement.textContent = selected ? `${format(selected)} of ${format(total)} words` : `${format(total)} ${total === 1 ? 'word' : 'words'}`;
}
function schedulePanels() {
  if (!panels.outline && !panels.wordCount) return;
  clearTimeout(panelTimer);
  panelTimer = setTimeout(() => {
    if (panels.outline) renderOutline();
    if (panels.wordCount) renderWordCount();
  }, 120);
}
function setPanels(settings) {
  Object.assign(panels, settings);
  outlineElement.hidden = !panels.outline;
  wordCountElement.hidden = !panels.wordCount;
  if (panels.outline) renderOutline();
  if (panels.wordCount) renderWordCount();
  view.requestMeasure();
}
outlineElement.addEventListener('mousedown', event => {
  const link = event.target.closest('a');
  if (!link) return;
  event.preventDefault();
  scrollToLine(Number(link.dataset.line));
});
let headingTimer = 0;
view.scrollDOM.addEventListener('scroll', () => {
  if (!panels.outline || headingTimer) return;
  headingTimer = setTimeout(() => { headingTimer = 0; markCurrentHeading(); }, 50);
});
// Show the link cursor only while Command-click would follow a link.
const trackCommand = event => document.body.classList.toggle('command-down', event.metaKey);
for (const type of ['keydown', 'keyup', 'mousemove']) window.addEventListener(type, trackCommand, true);
window.addEventListener('blur', () => document.body.classList.remove('command-down'));
window.addEventListener('beforeunload', event => { if (!native && info.dirty) { event.preventDefault(); event.returnValue = ''; } });
if (native) post('ready');
else loadDocument({ text: welcome, name: 'Welcome.md', dirty: false });
