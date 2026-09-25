import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { parser } from '@lezer/markdown';
import { markdownExtensions } from '../src/markdown-syntax.js';
import { md } from '../src/markdown.js';

const markdown = parser.configure(markdownExtensions);
/** [node name, source text] for every node of interest, in document order. */
function nodes(text, names) {
  const found = [];
  markdown.parse(text).iterate({ enter(node) { if (names.includes(node.name)) found.push([node.name, text.slice(node.from, node.to)]); } });
  return found;
}

test('inline math follows the renderer rules and leaves currency and code alone', () => {
  const text = 'Cost $5 and $6, then $x^2$, `$y$`, \\$z$ and $ a $ and $$b$$.';
  assert.deepEqual(nodes(text, ['InlineMath']), [['InlineMath', '$x^2$']]);
  assert.deepEqual(nodes('Unclosed $x+1', ['InlineMath']), []);
});
test('display math on one line or several, including right after text', () => {
  assert.deepEqual(nodes('### S\n$$\\dot x$$\nAt $\\Omega$.', ['BlockMath', 'InlineMath']), [['BlockMath', '$$\\dot x$$'], ['InlineMath', '$\\Omega$']]);
  assert.deepEqual(nodes('Text\n$$\nx^2\n$$\nAfter $a$.', ['BlockMath', 'InlineMath']), [['BlockMath', '$$\nx^2\n$$'], ['InlineMath', '$a$']]);
  assert.deepEqual(nodes('> $$\n> y\n> $$', ['BlockMath']), [['BlockMath', '$$\n> y\n> $$']]);
});
test('display math needs content between its delimiters', () => {
  for (const text of ['$$$$', '$$ $$', 'Text\n$$$$\nMore', '$$\n$$', '$$\n   \n$$', '> $$\n> $$'])
    assert.deepEqual(nodes(text, ['BlockMath']), [], JSON.stringify(text));
  assert.deepEqual(nodes('Text\n$$$$\nMore', ['Paragraph']), [['Paragraph', 'Text\n$$$$\nMore']]);
  assert.equal(nodes('$$x$$', ['BlockMath']).length, 1);
});
test('an unclosed display math opener does not swallow the document', () => {
  assert.deepEqual(nodes('$$\nunclosed\n\nParagraph $b$.', ['BlockMath', 'InlineMath']), [['InlineMath', '$b$']]);
});
test('frontmatter is recognised only at the start of the document', () => {
  assert.deepEqual(nodes('---\ntitle: x\n---\n# Head', ['Frontmatter', 'ATXHeading1', 'HorizontalRule']), [['Frontmatter', '---\ntitle: x\n---'], ['ATXHeading1', '# Head']]);
  assert.deepEqual(nodes('Text\n\n---\n\nMore', ['Frontmatter', 'HorizontalRule']), [['HorizontalRule', '---']]);
});
test('a line without a pipe ends a table instead of becoming a row', () => {
  assert.deepEqual(nodes('| A | B |\n| --- | --- |\n| 1 | 2 |\ntyped $c$\nmore', ['Table', 'TableRow', 'Paragraph', 'InlineMath']),
    [['Table', '| A | B |\n| --- | --- |\n| 1 | 2 |'], ['TableRow', '| 1 | 2 |'], ['Paragraph', 'typed $c$\nmore'], ['InlineMath', '$c$']]);
  assert.equal(nodes('A | B\n--- | ---\n1 | 2\nplain', ['Paragraph']).length, 1);
});
test('tables and fences nest inside lists and quotes', () => {
  assert.deepEqual(nodes('- item\n\n  | a |\n  |---|\n  | 1 |', ['Table']).length, 1);
  assert.deepEqual(nodes('> ```mermaid\n> graph LR\n> ```', ['FencedCode']).length, 1);
});
test('code fences do not contain inline math or emphasis', () => {
  assert.deepEqual(nodes('```text\n**literal** $x$\n```', ['InlineMath', 'StrongEmphasis']), []);
});

test('table cells render inline Markdown, math and HTML images but never raw HTML', () => {
  assert.match(md.renderInline('**b** $x$'), /<strong>b<\/strong> <span class="katex">/);
  assert.doesNotMatch(md.renderInline('Costs $20 and $30.'), /class="katex"/);
  assert.match(md.renderInline(`<IMG src='fig.png' width=320 alt="a > b" />`), /<IMG src='fig.png' width=320 alt="a > b" \/>/);
  for (const source of ['\\<img src="fig.png">', '`<img src="fig.png">`']) assert.doesNotMatch(md.renderInline(source), /<img\b/);
  assert.doesNotMatch(md.renderInline('<iframe src="x"></iframe><script>alert(1)</script>'), /<iframe|<script>/);
  assert.doesNotMatch(md.renderInline('[x](javascript:alert(1))'), /href="javascript:/);
  assert.match(md.renderInline('Alpha<br><br />Beta'), /Alpha<br><br \/>Beta/);
});
test('the HTML image table fixture parses as one table with four image cells', () => {
  const source = readFileSync('src/fixtures/html-table-images.md', 'utf8');
  assert.equal(nodes(source, ['Table']).length, 1);
  const images = source.split('\n').slice(2).flatMap(row => row.split(/(?<!\\)\|/).slice(1, -1).map(cell => md.renderInline(cell.trim())));
  assert.equal(images.join('').match(/<img\b/g).length, 4);
});
test('roundtrip fixture parses without errors and covers every line', () => {
  const source = readFileSync('src/fixtures/roundtrip.md', 'utf8');
  const tree = markdown.parse(source);
  assert.equal(tree.length, source.length);
  let errors = 0;
  tree.iterate({ enter(node) { if (node.type.isError) errors++; } });
  assert.equal(errors, 0);
});
