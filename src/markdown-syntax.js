import { GFM } from '@lezer/markdown';

// Lezer grammar extensions. This parse tree is the single source of document
// structure: live-preview styling, rendered widgets, the outline and anchors
// all read it, so they cannot disagree about where an element begins or ends.

const unescapedPipe = /(?<!\\)\|/;
const isSpace = code => code === 32 || code === 9 || code === 10 || code === 13;

/** A table ends at the first line without a pipe (as in Obsidian), instead of
 *  absorbing plain lines typed below it as rows. */
const TableEnd = {
  parseBlock: [{
    name: 'TableEnd',
    endLeaf: (_cx, line, leaf) => leaf.parsers.some(parser => Array.isArray(parser.rows)) && !unescapedPipe.test(line.text.slice(line.pos))
  }]
};

/** `$…$` inline math. Currency is not math: the opening `$` must be followed by
 *  a non-space, and the closing `$` preceded by a non-space and not followed by
 *  a digit. `$$` is never inline math. */
const InlineMath = {
  defineNodes: ['InlineMath', 'InlineMathMark'],
  parseInline: [{
    name: 'InlineMath',
    parse(cx, next, pos) {
      if (next !== 36 || cx.char(pos + 1) === 36 || cx.char(pos - 1) === 36 || cx.char(pos + 1) < 0 || isSpace(cx.char(pos + 1))) return -1;
      for (let end = pos + 1; end < cx.end; end++) {
        const code = cx.char(end);
        if (code === 10) return -1;
        if (code === 92) { end++; continue; }
        if (code !== 36) continue;
        const after = cx.char(end + 1);
        if (isSpace(cx.char(end - 1)) || (after >= 48 && after <= 57)) return -1;
        return cx.addElement(cx.elt('InlineMath', pos, end + 1, [cx.elt('InlineMathMark', pos, pos + 1), cx.elt('InlineMathMark', end, end + 1)]));
      }
      return -1;
    },
    before: 'Escape'
  }]
};

/** `$$…$$` display math, on one line or across lines. The closing `$$` must come
 *  before the next blank line, so a stray `$$` cannot swallow the document, and
 *  there must be something between the delimiters: `$$$$` stays plain text. */
const BlockMath = {
  defineNodes: [{ name: 'BlockMath', block: true }, 'BlockMathMark'],
  parseBlock: [{
    name: 'BlockMath',
    parse(cx, line) {
      const text = line.text.slice(line.pos);
      if (!text.startsWith('$$')) return false;
      const from = cx.lineStart + line.pos;
      const marks = [cx.elt('BlockMathMark', from, from + 2)];
      const rest = text.slice(2).trimEnd();
      if (rest.length >= 2 && rest.endsWith('$$')) {
        if (!rest.slice(0, -2).trim()) return false;
        const close = cx.lineStart + line.pos + 2 + rest.length - 2;
        marks.push(cx.elt('BlockMathMark', close, close + 2));
        cx.nextLine();
        cx.addElement(cx.elt('BlockMath', from, cx.prevLineEnd(), marks));
        return true;
      }
      // Look ahead for the closing line without consuming anything.
      const lineEnd = cx.lineStart + line.text.length;
      const ahead = cx.input.read(lineEnd, Math.min(cx.input.length, lineEnd + 100000)).split('\n').slice(1);
      const closing = ahead.findIndex(next => !next.replace(/^(?:\s*>)*/, '').trim() || next.trimEnd().endsWith('$$'));
      if (closing < 0 || !ahead[closing].replace(/^(?:\s*>)*/, '').trim()) return false;
      const inside = [text.slice(2), ...ahead.slice(0, closing), ahead[closing].trimEnd().slice(0, -2)];
      if (!inside.some(part => part.replace(/^(?:\s*>)*/, '').trim())) return false;
      for (let i = 0; i <= closing; i++) {
        if (!cx.nextLine()) return false;
        marks.push(...line.markers);
      }
      const close = cx.lineStart + line.text.trimEnd().length - 2;
      marks.push(cx.elt('BlockMathMark', close, close + 2));
      cx.nextLine();
      cx.addElement(cx.elt('BlockMath', from, cx.prevLineEnd(), marks));
      return true;
    },
    // Like Obsidian, a `$$` line may begin display math right after text.
    endLeaf: (_cx, line) => /^\$\$(?!\s*\$\$\s*$)/.test(line.text.slice(line.pos)),
    before: 'FencedCode'
  }]
};

/** YAML (`---`) or TOML (`+++`) frontmatter at the very start of a document. */
const Frontmatter = {
  defineNodes: [{ name: 'Frontmatter', block: true }],
  parseBlock: [{
    name: 'Frontmatter',
    parse(cx, line) {
      if (cx.lineStart !== 0 || !/^(---|\+\+\+)\s*$/.test(line.text)) return false;
      const fence = line.text.trim();
      const ahead = cx.input.read(line.text.length, Math.min(cx.input.length, 100000)).split('\n').slice(1);
      const closing = ahead.findIndex(next => next.trim() === fence);
      if (closing < 0) return false;
      for (let i = 0; i <= closing; i++) if (!cx.nextLine()) return false;
      cx.nextLine();
      cx.addElement(cx.elt('Frontmatter', 0, cx.prevLineEnd()));
      return true;
    },
    before: 'HorizontalRule'
  }]
};

export const markdownExtensions = [GFM, TableEnd, InlineMath, BlockMath, Frontmatter];
