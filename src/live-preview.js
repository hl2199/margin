import { EditorSelection, EditorState, StateEffect, StateField, RangeSetBuilder, Transaction } from '@codemirror/state';
import { Decoration, EditorView, ViewPlugin, WidgetType } from '@codemirror/view';
import { syntaxTree, ensureSyntaxTree } from '@codemirror/language';
import DOMPurify from 'dompurify';
import hljs from 'highlight.js/lib/common';
import katex from 'katex';
import { md } from './markdown.js';

// Obsidian-style live preview. The document is always its own Markdown source,
// styled in place. Markup is hidden except where the selection touches it, and
// elements whose rendering differs from their text (images, math, diagrams,
// tables, rules, checkboxes) are drawn as widgets until the cursor enters them.

export const editingEffect = StateEffect.define();
export const refreshEffect = StateEffect.define();
// Whether the editor is focused. Unfocused documents render every element.
export const editingField = StateField.define({
  create: () => false,
  update(value, transaction) {
    for (const effect of transaction.effects) if (effect.is(editingEffect)) value = effect.value;
    return value;
  }
});

function touches(state, from, to) {
  return state.field(editingField) && state.selection.ranges.some(range => range.from <= to && range.to >= from);
}

const sanitize = html => DOMPurify.sanitize(html, { ADD_ATTR: ['data-source-line'], ADD_TAGS: ['input'] });
// Bumped when the app sees an image file appear or change on disk, so the page
// requests fresh copies instead of reusing what WebKit loaded (or failed) first.
let imageVersion = 0;
export const bumpImageVersion = () => ++imageVersion;
// Local images (relative, `../`, absolute or file: paths) load through the
// native asset scheme. Web images stay blocked.
function rewriteImages(element) {
  if (!window.webkit?.messageHandlers?.margin) return;
  for (const img of element.querySelectorAll('img')) {
    const source = img.getAttribute('src') || '';
    const file = /^file:\/\//i.test(source);
    if (source && (file || !/^(?:[a-z][\w+.-]*:|\/\/)/i.test(source))) {
      try {
        const path = file ? new URL(source).pathname : source.split(/[?#]/)[0];
        img.src = `margin-asset://document/?path=${encodeURIComponent(decodeURIComponent(path))}&v=${imageVersion}`;
      } catch { img.removeAttribute('src'); }
    }
  }
}
const assetRoot = () => `${window.margin?.assetRoot() ?? ''}#${imageVersion}`;

// Diagrams --------------------------------------------------------------------

let diagramID = 0;
let diagramQueue = Promise.resolve();
const darkScheme = matchMedia('(prefers-color-scheme: dark)');
const diagramTheme = () => darkScheme.matches ? 'dark' : 'default';
// Mermaid is most of the editor's JavaScript. Load its separate bundle only
// when a document first shows a diagram.
let mermaidLoaded = null;
function loadMermaid() {
  mermaidLoaded ??= new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.src = 'mermaid.js';
    script.onload = () => resolve(window.mermaid);
    script.onerror = () => { mermaidLoaded = null; reject(new Error('Mermaid unavailable')); };
    document.head.append(script);
  });
  return mermaidLoaded.then(mermaid => {
    mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: diagramTheme(), htmlLabels: false, suppressErrorRendering: true });
    return mermaid;
  });
}
// Diagrams are drawn in the current appearance; redraw them when it changes.
export const diagramAppearance = ViewPlugin.fromClass(class {
  constructor(view) {
    this.change = () => view.dispatch({ effects: refreshEffect.of(true) });
    darkScheme.addEventListener('change', this.change);
  }
  destroy() { darkScheme.removeEventListener('change', this.change); }
});
function drawDiagrams(element, view) {
  for (const diagram of element.querySelectorAll('.diagram')) {
    const id = `diagram-${++diagramID}`;
    const source = diagram.textContent;
    diagramQueue = diagramQueue.then(async () => {
      if (!diagram.isConnected) return;
      try {
        const result = await (await loadMermaid()).render(id, source);
        if (diagram.isConnected) { diagram.innerHTML = DOMPurify.sanitize(result.svg); view.requestMeasure(); }
      } catch {
        diagram.textContent = 'Diagram could not render. Click to edit its source.';
        diagram.classList.add('render-error');
      }
    });
  }
}

// Block widgets: display math and diagrams --------------------------------------

/** Rendered display math or diagram. Clicking it reveals its source. */
class BlockPreview extends WidgetType {
  constructor(kind, content, target) {
    super(); this.kind = kind; this.content = content; this.target = target;
    this.theme = kind === 'diagram' ? diagramTheme() : '';
  }
  eq(other) { return other.kind === this.kind && other.content === this.content && other.target === this.target && other.theme === this.theme; }
  toDOM(view) {
    const element = document.createElement('div');
    element.className = 'block-preview prose';
    const inner = document.createElement('div');
    if (this.kind === 'math') {
      inner.className = 'math-display';
      inner.innerHTML = katex.renderToString(this.content, { displayMode: true, throwOnError: false, trust: false, strict: 'ignore', output: 'html' });
    } else {
      inner.className = 'diagram';
      inner.textContent = this.content;
    }
    element.append(inner);
    drawDiagrams(element, view);
    element.addEventListener('mousedown', event => {
      if (event.button !== 0) return;
      event.preventDefault();
      view.focus();
      view.dispatch({ selection: { anchor: Math.min(this.target, view.state.doc.length) }, effects: editingEffect.of(true) });
    });
    return element;
  }
  ignoreEvent() { return true; }
}

// Tables ----------------------------------------------------------------------

/** Cell source ranges for each row of a pipe table, read from its lines. */
function tableRows(doc, from, to) {
  const rows = [];
  for (let number = doc.lineAt(from).number; number <= doc.lineAt(to).number; number++) {
    const line = doc.line(number);
    const prefix = line.text.match(/^(?:\s*>)*\s*/)[0].length;
    const text = line.text.slice(prefix);
    const pipes = [...text.matchAll(/(?<!\\)\|/g)].map(match => match.index);
    const edges = [-1, ...pipes, text.length];
    let cells = edges.slice(0, -1).map((start, index) => ({ from: start + 1, to: edges[index + 1] }));
    if (text.trimStart().startsWith('|')) cells.shift();
    if (text.trimEnd().endsWith('|') && cells.length && !text.slice(cells.at(-1).from).trim()) cells.pop();
    cells = cells.map(cell => {
      const raw = text.slice(cell.from, cell.to);
      const lead = raw.length - raw.trimStart().length;
      const content = raw.trim();
      const start = line.from + prefix + cell.from + (content ? lead : Math.min(1, raw.length));
      return { from: start, to: start + content.length, text: content };
    });
    rows.push({ line, cells, end: line.to });
  }
  return rows;
}

function alignments(delimiter) {
  return delimiter.cells.map(cell => {
    const text = cell.text;
    return text.startsWith(':') && text.endsWith(':') ? 'center' : text.endsWith(':') ? 'right' : text.startsWith(':') ? 'left' : '';
  });
}

/**
 * A rendered table whose cells are edited in place, as in Obsidian. The focused
 * cell shows its Markdown; typing replaces that cell's source text.
 */
class TableWidget extends WidgetType {
  constructor(from, to, source, selected) { super(); this.from = from; this.to = to; this.source = source; this.selected = selected; this.assetRoot = assetRoot(); }
  eq(other) { return other.source === this.source && other.from === this.from && other.selected === this.selected && other.assetRoot === this.assetRoot; }
  toDOM(view) {
    const wrap = document.createElement('div');
    wrap.className = 'table-widget prose';
    // Native selection is not drawn over widgets; show a covering selection.
    wrap.classList.toggle('md-widget-selected', this.selected);
    wrap.tableWidget = this;
    wrap.view = view;
    render(wrap);
    wrap.addEventListener('mousedown', event => {
      if (event.button !== 0) return;
      const cell = event.target.closest('th, td');
      if (!cell) return;
      if (cell.isContentEditable) {
        if (event.detail >= 2) { event.preventDefault(); selectInCell(cell, { x: event.clientX, y: event.clientY, detail: event.detail }); }
        return;
      }
      if (event.metaKey && event.target.closest('a')) { event.preventDefault(); window.margin?.openLink(event.target.closest('a').getAttribute('href')); return; }
      event.preventDefault();
      startEditing(wrap, Number(cell.dataset.row), Number(cell.dataset.column), { x: event.clientX, y: event.clientY, detail: event.detail });
    });
    wrap.enterCell = (row, column) => startEditing(wrap, row, column, null);
    // Text typed at a position inside the table's source goes into that cell.
    wrap.typeAt = (pos, text) => {
      const rows = rowsOf(wrap);
      let row = rows.findIndex(r => pos >= r.line.from && pos <= r.line.to);
      if (row < 0) row = 0;
      const cells = rows[row].cells;
      let column = cells.findIndex(cell => pos <= cell.to);
      if (column < 0) column = cells.length - 1;
      startEditing(wrap, row, column, null);
      const cell = document.activeElement, node = cell.firstChild;
      if (node?.nodeType === Node.TEXT_NODE) {
        const offset = Math.max(0, Math.min(node.length, pos - cells[column].from));
        getSelection().collapse(node, offset);
      }
      document.execCommand('insertText', false, text);
    };
    return wrap;
  }
  updateDOM(dom) {
    dom.tableWidget = this;
    dom.classList.toggle('md-widget-selected', this.selected);
    const editing = dom.querySelector('[contenteditable="true"]');
    if (editing) {
      // Keep the focused cell's DOM (and caret); refresh everything else.
      const row = Number(editing.dataset.row), column = Number(editing.dataset.column);
      const cell = cellSource(dom, row, column);
      if (!cell || rowsOf(dom).length !== dom.querySelectorAll('tr').length) { render(dom); return true; }
      if (editing.textContent !== cell.text) { editing.textContent = cell.text; placeCaretAtEnd(editing); }
      for (const other of dom.querySelectorAll('th, td')) {
        if (other === editing) continue;
        const source = cellSource(dom, Number(other.dataset.row), Number(other.dataset.column));
        renderCell(other, source?.text ?? '');
      }
      return true;
    }
    render(dom);
    return true;
  }
  ignoreEvent() { return true; }
}

function rowsOf(wrap) {
  const widget = wrap.tableWidget;
  const rows = tableRows(wrap.view.state.doc, widget.from, widget.to);
  return [rows[0], ...rows.slice(2)];
}
function cellSource(wrap, row, column) {
  const rows = rowsOf(wrap);
  if (!rows[row]) return null;
  const cell = rows[row].cells[column];
  return cell ?? { from: rows[row].end, to: rows[row].end, text: '', missing: true };
}
function renderCell(cell, text) {
  cell.innerHTML = sanitize(md.renderInline(text));
  rewriteImages(cell);
}
function render(wrap) {
  const widget = wrap.tableWidget;
  const all = tableRows(wrap.view.state.doc, widget.from, widget.to);
  const align = all[1] ? alignments(all[1]) : [];
  const columns = all[0].cells.length;
  const table = document.createElement('table');
  const head = table.createTHead(), body = table.createTBody();
  [all[0], ...all.slice(2)].forEach((row, index) => {
    const tr = (index ? body : head).insertRow();
    for (let column = 0; column < columns; column++) {
      const cell = document.createElement(index ? 'td' : 'th');
      cell.dataset.row = String(index);
      cell.dataset.column = String(column);
      if (align[column]) cell.style.textAlign = align[column];
      renderCell(cell, row.cells[column]?.text ?? '');
      tr.append(cell);
    }
  });
  wrap.replaceChildren(table);
}
function placeCaretAtEnd(element) {
  const range = document.createRange();
  range.selectNodeContents(element);
  range.collapse(false);
  const selection = getSelection();
  selection.removeAllRanges(); selection.addRange(range);
}
/** Caret at the clicked point; a double or triple click selects a word or the cell. */
function selectInCell(cell, point) {
  const caret = point && document.caretRangeFromPoint?.(point.x, point.y);
  const selection = getSelection();
  if (caret && cell.contains(caret.startContainer)) { selection.removeAllRanges(); selection.addRange(caret); }
  else placeCaretAtEnd(cell);
  if (point?.detail === 2) { selection.modify('move', 'backward', 'word'); selection.modify('extend', 'forward', 'word'); }
  else if (point?.detail >= 3) selection.selectAllChildren(cell);
}
function startEditing(wrap, row, column, point) {
  const rows = rowsOf(wrap);
  if (!rows.length) return;
  row = Math.max(0, Math.min(row, rows.length - 1));
  column = Math.max(0, Math.min(column, rows[0].cells.length - 1));
  const cell = wrap.querySelector(`[data-row="${row}"][data-column="${column}"]`);
  if (!cell) return;
  const view = wrap.view;
  // Keep the document selection beside the table so nothing else reveals.
  view.dispatch({ selection: { anchor: wrap.tableWidget.from }, effects: editingEffect.of(true) });
  cell.contentEditable = 'true';
  cell.spellcheck = true;
  cell.textContent = cellSource(wrap, row, column)?.text ?? '';
  cell.focus();
  selectInCell(cell, point);
  if (cell.editingHandlers) return;
  cell.editingHandlers = true;
  cell.addEventListener('input', () => commitCell(wrap, cell));
  cell.addEventListener('keydown', event => cellKey(wrap, cell, event));
  cell.addEventListener('paste', event => {
    event.preventDefault();
    document.execCommand('insertText', false, event.clipboardData.getData('text/plain').replace(/\r?\n/g, ' '));
  });
  cell.addEventListener('focusout', () => setTimeout(() => {
    if (document.activeElement === cell) return;
    cell.contentEditable = 'false';
    const source = cellSource(wrap, Number(cell.dataset.row), Number(cell.dataset.column));
    renderCell(cell, source?.text ?? '');
  }, 0));
}
function commitCell(wrap, cell) {
  const view = wrap.view;
  const source = cellSource(wrap, Number(cell.dataset.row), Number(cell.dataset.column));
  if (!source) return;
  // A cell is one source line; a literal pipe must be escaped.
  const text = cell.textContent.replace(/\n/g, ' ').replace(/(?<!\\)\|/g, '\\|');
  const insert = !source.missing ? text
    : view.state.doc.sliceString(source.from - 1, source.from) === '|' ? ` ${text} |` : ` | ${text}`;
  view.dispatch({ changes: { from: source.from, to: source.to, insert }, userEvent: 'input.table' });
}
function leaveTable(wrap, forward) {
  const view = wrap.view, doc = view.state.doc, widget = wrap.tableWidget;
  const anchor = forward ? Math.min(widget.to + 1, doc.length) : Math.max(0, widget.from - 1);
  view.focus();
  view.dispatch({ selection: { anchor }, effects: editingEffect.of(true), scrollIntoView: true });
}
function cellKey(wrap, cell, event) {
  const row = Number(cell.dataset.row), column = Number(cell.dataset.column);
  const rows = rowsOf(wrap).length, columns = rowsOf(wrap)[0].cells.length;
  const go = (r, c) => { event.preventDefault(); cell.blur(); startEditing(wrap, r, c, null); };
  if (event.key === 'Tab') {
    const next = row * columns + column + (event.shiftKey ? -1 : 1);
    if (next < 0) { event.preventDefault(); leaveTable(wrap, false); }
    else if (next >= rows * columns) { event.preventDefault(); leaveTable(wrap, true); }
    else go(Math.floor(next / columns), next % columns);
  } else if (event.key === 'Enter' || (event.key === 'ArrowDown' && !event.shiftKey)) {
    if (row + 1 < rows) go(row + 1, column); else { event.preventDefault(); leaveTable(wrap, true); }
  } else if (event.key === 'ArrowUp' && !event.shiftKey) {
    if (row > 0) go(row - 1, column); else { event.preventDefault(); leaveTable(wrap, false); }
  } else if (event.key === 'Escape') {
    event.preventDefault(); leaveTable(wrap, true);
  } else if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'z') {
    event.preventDefault();
    window.margin?.command(event.shiftKey ? 'redo' : 'undo');
  } else if (event.metaKey && event.key.toLowerCase() === 'a') {
    // Select All inside a cell selects that cell, not the document.
    event.preventDefault();
    getSelection().selectAllChildren(cell);
  } else if (event.metaKey && ['b', 'i', 'k'].includes(event.key.toLowerCase())) {
    event.preventDefault();
    window.margin?.command({ b: 'bold', i: 'italic', k: 'link' }[event.key.toLowerCase()]);
  }
  event.stopPropagation();
}

// Block decorations (state field: they replace whole lines) ---------------------

const containers = new Set(['Document', 'Blockquote', 'BulletList', 'OrderedList', 'ListItem']);
const blockLanguages = { math: 'math', latex: 'math', mermaid: 'diagram' };
/** Text between a block's opening and closing marks, without quote markers. */
function blockContent(state, node, from, to) {
  let text = state.sliceDoc(from, to);
  for (let parent = node.parent; parent; parent = parent.parent)
    if (parent.name === 'Blockquote') { text = text.replace(/^[ \t]*(?:>[ \t]?)+/gm, ''); break; }
  return text;
}
// Long documents are parsed gradually. Parse synchronously within a small budget
// so elements render with the text; the rest arrives as the parser catches up.
const parsedTree = (state, upto) => ensureSyntaxTree(state, upto, 30) ?? syntaxTree(state);
function blockDecorations(state) {
  const builder = new RangeSetBuilder();
  const ranges = [];
  parsedTree(state, state.doc.length).iterate({ enter(node) {
    const name = node.name;
    if (containers.has(name)) return;
    const from = state.doc.lineAt(node.from).from, to = state.doc.lineAt(node.to).to;
    if (name === 'Table') {
      const selected = state.selection.ranges.some(range => !range.empty && range.from <= from && range.to >= to);
      builder.add(from, to, Decoration.replace({ widget: new TableWidget(from, to, state.sliceDoc(from, to), selected), block: true }));
      ranges.push({ from, to, type: 'table' });
    } else if (name === 'Frontmatter') {
      ranges.push({ from, to, type: 'frontmatter' });
    } else if (name === 'BlockMath' || name === 'FencedCode') {
      let kind = 'math', content, target;
      if (name === 'BlockMath') {
        const marks = node.node.getChildren('BlockMathMark');
        content = marks.length >= 2 ? blockContent(state, node.node, marks[0].to, marks.at(-1).from) : '';
        target = state.doc.lineAt(node.from).number === state.doc.lineAt(node.to).number ? marks[0].to : Math.min(state.doc.lineAt(node.from).to + 1, to);
      } else {
        const info = node.node.getChild('CodeInfo');
        kind = info && blockLanguages[state.sliceDoc(info.from, info.to).trim().split(/\s/)[0].toLowerCase()];
        if (!kind) return false;
        const code = node.node.getChild('CodeText');
        content = code ? blockContent(state, node.node, code.from, code.to) : '';
        target = Math.min(state.doc.lineAt(node.from).to + 1, to);
      }
      const shown = touches(state, from, to);
      if (!shown) builder.add(from, to, Decoration.replace({ widget: new BlockPreview(kind, content, target), block: true }));
      ranges.push({ from, to, type: shown ? 'source' : 'preview' });
    }
    return false;
  } });
  return { decorations: builder.finish(), ranges };
}
export const blockField = StateField.define({
  create: blockDecorations,
  update(value, transaction) {
    if (transaction.docChanged || transaction.selection || syntaxTree(transaction.startState) !== syntaxTree(transaction.state)
      || transaction.effects.some(e => e.is(editingEffect) || e.is(refreshEffect))) return blockDecorations(transaction.state);
    return value;
  },
  provide: field => EditorView.decorations.from(field, value => value.decorations)
});
/** Top-level table, math, diagram and frontmatter ranges. */
export const specialBlocks = state => state.field(blockField).ranges;

// Inline widgets -----------------------------------------------------------------

class BulletWidget extends WidgetType {
  eq() { return true; }
  toDOM() { const span = document.createElement('span'); span.className = 'md-bullet'; span.textContent = '•'; return span; }
}
class CheckboxWidget extends WidgetType {
  constructor(checked, at) { super(); this.checked = checked; this.at = at; }
  eq(other) { return other.checked === this.checked && other.at === this.at; }
  toDOM(view) {
    const box = document.createElement('input');
    box.type = 'checkbox'; box.className = 'md-task'; box.checked = this.checked; box.tabIndex = -1;
    box.setAttribute('aria-label', this.checked ? 'Completed task' : 'Incomplete task');
    box.addEventListener('mousedown', event => {
      if (event.button !== 0) return;
      event.preventDefault();
      view.dispatch({ changes: { from: this.at, to: this.at + 1, insert: this.checked ? ' ' : 'x' }, userEvent: 'input.toggle' });
    });
    box.addEventListener('click', event => event.preventDefault());
    return box;
  }
  ignoreEvent() { return true; }
}
class HTMLWidget extends WidgetType {
  constructor(html, className, root) { super(); this.html = html; this.className = className; this.root = root; }
  eq(other) { return other.html === this.html && other.root === this.root; }
  // A newer image version reloads in place: the old picture stays until the
  // new one has loaded, so nothing collapses or flickers.
  updateDOM(dom) {
    if (dom.dataset.html !== this.html) return false;
    const fresh = document.createElement('span');
    fresh.innerHTML = sanitize(this.html);
    rewriteImages(fresh);
    const now = [...dom.querySelectorAll('img')], next = [...fresh.querySelectorAll('img')];
    if (now.length !== next.length) return false;
    now.forEach((img, i) => { if (next[i].src) img.src = next[i].src; });
    return true;
  }
  toDOM() {
    const span = document.createElement('span');
    span.className = this.className;
    span.dataset.html = this.html;
    span.innerHTML = sanitize(this.html);
    rewriteImages(span);
    return span;
  }
  ignoreEvent() { return false; }
}
/** Inline math, drawn with the punctuation touching it so that a line never
 *  breaks between a formula and its comma or bracket. */
class MathWidget extends WidgetType {
  constructor(source, before = '', after = '') { super(); this.source = source; this.before = before; this.after = after; }
  eq(other) { return other.source === this.source && other.before === this.before && other.after === this.after; }
  toDOM() {
    const span = document.createElement('span');
    span.className = 'md-math';
    span.innerHTML = katex.renderToString(this.source, { throwOnError: false, trust: false, strict: 'ignore', output: 'html' });
    if (this.before) span.prepend(this.before);
    if (this.after) span.append(this.after);
    return span;
  }
  ignoreEvent() { return false; }
}
class RuleWidget extends WidgetType {
  eq() { return true; }
  toDOM() { const hr = document.createElement('span'); hr.className = 'md-rule'; return hr; }
}
class FenceLabel extends WidgetType {
  constructor(language) { super(); this.language = language; }
  eq(other) { return other.language === this.language; }
  toDOM() { const span = document.createElement('span'); span.className = 'md-fence-label'; span.textContent = this.language; return span; }
}

// Inline decorations (view plugin: visible ranges only) --------------------------

const markClasses = { StrongEmphasis: 'md-strong', Emphasis: 'md-emphasis', Strikethrough: 'md-strike' };
const hiddenMarks = { StrongEmphasis: 'EmphasisMark', Emphasis: 'EmphasisMark', Strikethrough: 'StrikethroughMark', InlineCode: 'CodeMark' };
const hide = Decoration.replace({});
const muted = Decoration.mark({ class: 'md-marker' });

function highlightCode(builder, code, language, offset) {
  if (!language || !hljs.getLanguage(language) || code.length > 200000) return;
  const template = document.createElement('template');
  template.innerHTML = hljs.highlight(code, { language, ignoreIllegals: true }).value;
  let position = offset;
  const walk = (node, classes) => {
    for (const child of node.childNodes) {
      if (child.nodeType === Node.TEXT_NODE) {
        if (classes.length && child.data.length) builder.push(Decoration.mark({ class: classes.join(' ') }).range(position, position + child.data.length));
        position += child.data.length;
      } else walk(child, child.className ? [...classes, child.className] : classes);
    }
  };
  walk(template.content, []);
}

function inlineDecorations(view) {
  const { state } = view;
  const decorations = [];
  const replaced = [];
  // Replacements may not overlap; the first (outermost) one wins.
  const replace = (from, to, decoration) => {
    if (from >= to && !decoration.spec.widget) return;
    if (replaced.some(r => from < r.to && to > r.from)) return;
    replaced.push({ from, to });
    decorations.push(decoration.range(from, to));
  };
  const special = specialBlocks(state);
  const inSpecial = (from, to) => special.find(block => from <= block.to && to >= block.from);
  const lineTouched = line => touches(state, line.from, line.to);
  // Everything CodeMirror draws: the viewport and its margin, plus the main
  // selection's line, which stays drawn even when scrolled out of view.
  const head = state.doc.lineAt(state.selection.main.head);
  const drawn = [view.viewport];
  if (head.to < view.viewport.from || head.from > view.viewport.to) drawn.push({ from: head.from, to: head.to });
  const tree = parsedTree(state, Math.max(...drawn.map(range => range.to)));
  for (const { from, to } of drawn.sort((a, b) => a.from - b.from)) {
    // Frontmatter and revealed math/diagram sources are shown as code.
    for (const block of special) {
      if (block.type === 'table' || block.type === 'preview' || block.to < from || block.from > to) continue;
      for (let pos = Math.max(block.from, from); pos <= Math.min(block.to, to);) {
        const line = state.doc.lineAt(pos);
        decorations.push(Decoration.line({ class: 'md-code-line' + (line.from === block.from ? ' md-code-first' : '') + (line.to === block.to ? ' md-code-last' : '') }).range(line.from));
        pos = line.to + 1;
      }
    }
    tree.iterate({ from, to, enter(node) {
      // Skip what a block widget covers; descend into nodes extending past one
      // (Lezer's table can run onto a line that renders as a paragraph).
      const block = inSpecial(node.from, node.to);
      if (block && node.from >= block.from && node.to <= block.to) return false;
      if (block) return undefined;
      const name = node.name;
      if (/^ATXHeading[1-6]$/.test(name)) {
        const line = state.doc.lineAt(node.from);
        decorations.push(Decoration.line({ class: `md-heading md-heading-${name.slice(-1)}` }).range(line.from));
        const mark = node.node.getChild('HeaderMark');
        if (mark && !lineTouched(line)) {
          const end = state.sliceDoc(mark.to, mark.to + 1) === ' ' ? mark.to + 1 : mark.to;
          replace(mark.from, end, hide);
          // Closing hashes of `# Title #`, with the spaces before them.
          const last = node.node.lastChild;
          if (last && last.name === 'HeaderMark' && last.from > mark.to) {
            let start = last.from;
            while (start > end && state.sliceDoc(start - 1, start) === ' ') start--;
            replace(start, last.to, hide);
          }
        } else if (mark) decorations.push(muted.range(mark.from, mark.to));
      } else if (/^SetextHeading[12]$/.test(name)) {
        const first = state.doc.lineAt(node.from);
        decorations.push(Decoration.line({ class: `md-heading md-heading-${name.slice(-1)}` }).range(first.from));
        const mark = node.node.getChild('HeaderMark');
        if (mark) {
          const line = state.doc.lineAt(mark.from);
          decorations.push(Decoration.line({ class: 'md-setext-mark' }).range(line.from));
          if (!touches(state, node.from, node.to)) replace(mark.from, mark.to, hide); else decorations.push(muted.range(mark.from, mark.to));
        }
      } else if (name === 'Blockquote') {
        for (let pos = node.from; pos <= node.to;) {
          const line = state.doc.lineAt(pos);
          decorations.push(Decoration.line({ class: 'md-quote' }).range(line.from));
          pos = line.to + 1;
        }
      } else if (name === 'QuoteMark') {
        const line = state.doc.lineAt(node.from);
        const end = state.sliceDoc(node.to, node.to + 1) === ' ' ? node.to + 1 : node.to;
        if (!lineTouched(line)) replace(node.from, end, hide); else decorations.push(muted.range(node.from, node.to));
      } else if (name === 'ListMark') {
        const item = node.node.parent;
        const task = item?.getChild('Task')?.getChild('TaskMarker');
        const ordered = item?.parent?.name === 'OrderedList';
        const zoneEnd = task ? task.to : node.to + 1;
        if (task) {
          const checked = /x/i.test(state.sliceDoc(task.from, task.to));
          if (!touches(state, node.from, zoneEnd)) {
            replace(node.from, task.from, hide);
            replace(task.from, task.to, Decoration.replace({ widget: new CheckboxWidget(checked, task.from + 1) }));
            if (checked) if (item.to > task.to + 1) decorations.push(Decoration.mark({ class: 'md-task-done' }).range(task.to + 1, item.to));
          } else decorations.push(muted.range(node.from, task.to));
        } else if (ordered) decorations.push(Decoration.mark({ class: 'md-list-number' }).range(node.from, node.to));
        else if (!touches(state, node.from, zoneEnd)) replace(node.from, node.to, Decoration.replace({ widget: new BulletWidget() }));
        else decorations.push(muted.range(node.from, node.to));
      } else if (name in markClasses || name === 'InlineCode') {
        const marks = node.node.getChildren(hiddenMarks[name]);
        const shown = touches(state, node.from, node.to);
        if (name === 'InlineCode') {
          const inner = marks.length >= 2 ? { from: marks[0].to, to: marks.at(-1).from } : node;
          if (inner.to > inner.from) decorations.push(Decoration.mark({ class: 'md-code' }).range(inner.from, inner.to));
        } else decorations.push(Decoration.mark({ class: markClasses[name] }).range(node.from, node.to));
        for (const mark of marks) shown ? decorations.push(muted.range(mark.from, mark.to)) : replace(mark.from, mark.to, hide);
        if (name === 'InlineCode') return false;
      } else if (name === 'Link' || name === 'Autolink') {
        const marks = node.node.getChildren('LinkMark');
        const url = node.node.getChild('URL');
        const href = url ? state.sliceDoc(url.from, url.to) : '';
        const shown = touches(state, node.from, node.to);
        const text = name === 'Autolink' ? (url ?? node) : marks.length >= 2 ? { from: marks[0].to, to: marks[1].from } : node;
        if (text.to > text.from) decorations.push(Decoration.mark({ class: 'md-link' + (shown ? '' : ' md-link-rendered'), attributes: href ? { 'data-href': href } : {} }).range(text.from, text.to));
        if (!shown) {
          if (name === 'Autolink') for (const mark of marks) replace(mark.from, mark.to, hide);
          else if (marks.length >= 2) { replace(marks[0].from, marks[0].to, hide); replace(marks[1].from, node.to, hide); }
        } else {
          for (const mark of marks) decorations.push(muted.range(mark.from, mark.to));
          if (url && name === 'Link') decorations.push(Decoration.mark({ class: 'md-url' }).range(url.from, url.to));
        }
      } else if (name === 'URL' && !['Link', 'Image', 'Autolink'].includes(node.node.parent?.name)) {
        decorations.push(Decoration.mark({ class: 'md-link md-link-rendered', attributes: { 'data-href': state.sliceDoc(node.from, node.to) } }).range(node.from, node.to));
      } else if (name === 'Image') {
        if (!touches(state, node.from, node.to)) {
          const url = node.node.getChild('URL');
          const marks = node.node.getChildren('LinkMark');
          const alt = marks.length >= 2 ? state.sliceDoc(marks[0].to, marks[1].from) : '';
          const img = document.createElement('img');
          img.setAttribute('src', url ? state.sliceDoc(url.from, url.to) : '');
          img.setAttribute('alt', alt);
          replace(node.from, node.to, Decoration.replace({ widget: new HTMLWidget(img.outerHTML, 'md-image', assetRoot()) }));
        }
        return false;
      } else if (name === 'Escape') {
        if (!touches(state, node.from, node.to)) replace(node.from, node.from + 1, hide);
      } else if (name === 'HorizontalRule') {
        const line = state.doc.lineAt(node.from);
        decorations.push(Decoration.line({ class: 'md-rule-line' }).range(line.from));
        if (!lineTouched(line)) replace(node.from, node.to, Decoration.replace({ widget: new RuleWidget() }));
        else decorations.push(muted.range(node.from, node.to));
      } else if (name === 'FencedCode' || name === 'CodeBlock') {
        const shown = touches(state, node.from, node.to);
        const info = node.node.getChild('CodeInfo');
        const language = info ? state.sliceDoc(info.from, info.to).trim().split(/\s/)[0] : '';
        for (let pos = node.from; pos <= node.to;) {
          const line = state.doc.lineAt(pos);
          const fence = name === 'FencedCode' && (line.from === state.doc.lineAt(node.from).from || line.to === node.to) && /^\s*(?:>\s*)*(```|~~~)/.test(line.text);
          decorations.push(Decoration.line({ class: 'md-code-line' + (line.from <= node.from ? ' md-code-first' : '') + (line.to >= node.to ? ' md-code-last' : '') + (fence ? ' md-fence' : '') }).range(line.from));
          if (fence && !shown) {
            const start = line.from + line.text.search(/\S/);
            replace(start, line.to, line.from <= node.from && language ? Decoration.replace({ widget: new FenceLabel(language) }) : hide);
          } else if (fence) decorations.push(muted.range(line.from + line.text.search(/\S/), line.to));
          pos = line.to + 1;
        }
        const code = node.node.getChild('CodeText');
        if (code) highlightCode(decorations, state.sliceDoc(code.from, code.to), language, code.from);
        return false;
      } else if (name === 'HTMLTag' || name === 'HTMLBlock') {
        const text = state.sliceDoc(node.from, node.to);
        for (const match of text.matchAll(/<(img|br)\b[^>]*>/gi)) {
          const start = node.from + match.index, end = start + match[0].length;
          if (touches(state, start, end)) continue;
          const widget = match[1].toLowerCase() === 'br' ? new HTMLWidget('<br>', 'md-break', '') : new HTMLWidget(match[0], 'md-image', assetRoot());
          replace(start, end, Decoration.replace({ widget }));
        }
      }
      else if (name === 'InlineMath') {
        const marks = node.node.getChildren('InlineMathMark');
        const line = state.doc.lineAt(node.from);
        const plain = pos => !/Mark$|Link|URL|Code|Math/.test(tree.resolveInner(pos, 1).name);
        let before = state.sliceDoc(line.from, node.from).match(/[(\[{"“‘]+$/)?.[0] ?? '';
        let after = state.sliceDoc(node.to, line.to).match(/^[,.;:!?)\]}"”’%]+/)?.[0] ?? '';
        while (before && !plain(node.from - before.length)) before = before.slice(1);
        while (after && !plain(node.to + after.length - 1)) after = after.slice(0, -1);
        if (!touches(state, node.from, node.to)) replace(node.from - before.length, node.to + after.length, Decoration.replace({ widget: new MathWidget(state.sliceDoc(marks[0].to, marks.at(-1).from), before, after) }));
        else decorations.push(Decoration.mark({ class: 'md-math-source' }).range(node.from, node.to));
        return false;
      }
    } });
  }
  return Decoration.set(decorations, true);
}

export const inlinePreview = ViewPlugin.fromClass(class {
  constructor(view) { this.decorations = inlineDecorations(view); }
  update(update) {
    if (update.docChanged || update.viewportChanged || update.selectionSet || update.focusChanged
      || syntaxTree(update.startState) !== syntaxTree(update.state)
      || update.transactions.some(t => t.effects.some(e => e.is(editingEffect) || e.is(refreshEffect)))) this.decorations = inlineDecorations(update.view);
  }
}, {
  decorations: plugin => plugin.decorations,
  eventHandlers: {
    // Rendered links open on click, as in Obsidian; Command-click opens any link.
    mousedown(event) {
      if (event.button !== 0) return false;
      const link = event.target.closest?.('.md-link');
      if (!link?.dataset.href || !(event.metaKey || link.classList.contains('md-link-rendered'))) return false;
      event.preventDefault();
      window.margin?.openLink(link.dataset.href);
      return true;
    }
  }
});

// Placing the caret reveals nearby markup and shifts the text. Keep the position
// measured at mousedown so a click selects what was clicked, and reuse the first
// click's position for the second and third clicks of a double or triple click
// (the first click has already revealed markup and moved the text under them).
const lastClicks = new WeakMap();
export const stableMouseSelection = EditorView.mouseSelectionStyle.of((view, start) => {
  if (start.button !== 0 || start.target.closest?.('.table-widget, .block-preview, .md-task')) return null;
  const last = lastClicks.get(view);
  const repeat = last && start.detail > 1 && last.doc === view.state.doc
    && Math.abs(start.clientX - last.x) < 5 && Math.abs(start.clientY - last.y) < 5;
  const initial = repeat ? last.initial : view.posAndSideAtCoords({ x: start.clientX, y: start.clientY }, false);
  if (!initial) return null;
  lastClicks.set(view, { x: start.clientX, y: start.clientY, initial, doc: view.state.doc });
  let anchor = initial.pos;
  let original = view.state.selection;
  const rangeAt = (pos, assoc = 1) => {
    if (start.detail === 2) return view.state.wordAt(pos) ?? EditorSelection.cursor(pos, assoc);
    if (start.detail >= 3) {
      const line = view.state.doc.lineAt(pos);
      return EditorSelection.range(line.from, Math.min(line.to + 1, view.state.doc.length));
    }
    return EditorSelection.cursor(pos, assoc);
  };
  return {
    get(event, extend, multiple) {
      let head = anchor, assoc = initial.assoc;
      const moved = event !== start && (Math.abs(event.clientX - start.clientX) > 3 || Math.abs(event.clientY - start.clientY) > 3);
      if (moved) {
        const point = view.posAndSideAtCoords({ x: event.clientX, y: event.clientY }, false);
        if (point) { head = point.pos; assoc = point.assoc; }
      }
      const first = rangeAt(anchor, initial.assoc), last = rangeAt(head, assoc);
      const range = extend ? original.main.extend(last.from, last.to)
        : head < anchor ? EditorSelection.range(first.to, last.from, undefined, undefined, assoc)
        : EditorSelection.range(first.from, last.to, undefined, undefined, assoc);
      return multiple ? original.addRange(range) : EditorSelection.create([range]);
    },
    update(update) {
      if (update.docChanged) { anchor = update.changes.mapPos(anchor); original = original.map(update.changes); }
    }
  };
});

// A table's hidden source has no caret of its own: its start is drawn above the
// table and its end below it. Text typed or pasted at the start goes on a new
// line above the table, at the end on a new line below; neither joins a row.
const tableAt = (state, pos) => specialBlocks(state).find(block => block.type === 'table' && pos >= block.from && pos <= block.to);
const newLinesAroundTables = EditorState.transactionFilter.of(tr => {
  if (!tr.docChanged || !tr.isUserEvent('input') || tr.isUserEvent('input.table') || tr.isUserEvent('input.toggle')) return tr;
  const changes = [];
  let moved = false;
  tr.changes.iterChanges((fromA, toA, _fromB, _toB, inserted) => {
    let insert = inserted.toString();
    const table = fromA === toA && insert && tableAt(tr.startState, fromA);
    if (table && fromA === table.to && !insert.startsWith('\n')) { insert = '\n' + insert; moved = true; }
    else if (table && fromA === table.from && !insert.endsWith('\n')) { insert = insert + '\n'; moved = true; }
    changes.push({ from: fromA, to: toA, insert });
  });
  if (!moved) return tr;
  const changeSet = tr.startState.changes(changes);
  const head = tr.newSelection.main.head;
  const start = tr.startState.selection.main.head;
  const table = tableAt(tr.startState, start);
  const cursor = table && start === table.from ? changeSet.mapPos(start, -1) + (head - start) : changeSet.mapPos(start, 1);
  return { changes: changeSet, selection: EditorSelection.cursor(cursor), scrollIntoView: true,
    annotations: Transaction.userEvent.of(tr.annotation(Transaction.userEvent)) };
});
// Handle typing before the browser inserts it: the DOM caret for a position in
// a table's source sits elsewhere, and native input would land there. Inside
// the source (for example after Find), the text goes into that cell.
const typingAtTables = EditorView.domEventHandlers({
  beforeinput(event, view) {
    const selection = view.state.selection.main;
    if (!/^insert(Text|ReplacementText)$/.test(event.inputType) || !event.data || !selection.empty) return false;
    const table = tableAt(view.state, selection.head);
    if (!table) return false;
    event.preventDefault();
    if (selection.head === table.from || selection.head === table.to) view.dispatch({ changes: { from: selection.head, insert: event.data }, userEvent: 'input.type' });
    else tableElement(view, table.from)?.typeAt(selection.head, event.data);
    return true;
  }
});

/** Wraps the selection in the table cell being edited, if there is one. */
export function wrapCellSelection(before, after = before) {
  const cell = document.activeElement?.closest?.('.table-widget [contenteditable="true"]');
  if (!cell) return false;
  const selected = getSelection().toString();
  document.execCommand('insertText', false, before + selected + after);
  return true;
}

/** The table widget element starting at `from`, if it is on screen. */
export function tableElement(view, from) {
  return [...view.contentDOM.querySelectorAll('.table-widget')].find(element => element.tableWidget?.from === from) ?? null;
}

export const livePreview = [editingField, blockField, inlinePreview, diagramAppearance, stableMouseSelection, newLinesAroundTables, typingAtTables];
