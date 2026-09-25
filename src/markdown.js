import MarkdownIt from 'markdown-it';
import { HTML_TAG_RE } from 'markdown-it/lib/common/html_re.mjs';
import katex from 'katex';

// Renders the inline Markdown of table cells. Document structure comes from the
// Lezer grammar in markdown-syntax.js; this is only a cell's rendered HTML.
export const md = new MarkdownIt({ html: false, linkify: true, breaks: true, typographer: false });

// Accept images and explicit line breaks without enabling arbitrary raw HTML.
// Table cells sanitize the resulting HTML before it enters the document.
md.inline.ruler.before('html_inline', 'html_image_or_break', (state, silent) => {
  const remaining = state.src.slice(state.pos, state.posMax);
  if (!/^<(?:img|br)(?=[\s/>])/i.test(remaining)) return false;
  const match = remaining.match(HTML_TAG_RE);
  if (!match) return false;
  if (!silent) {
    const token = state.push('html_inline', '', 0);
    token.content = match[0];
  }
  state.pos += match[0].length;
  return true;
});


// Dollar math never consumes a currency expression with space after the opening dollar.
md.inline.ruler.before('escape', 'math_inline', (state, silent) => {
  const start = state.pos;
  if (state.src[start] !== '$' || state.src[start + 1] === '$' || /\s/.test(state.src[start + 1] || ' ')) return false;
  let end = start + 1;
  while ((end = state.src.indexOf('$', end)) >= 0) {
    if (state.src[end - 1] !== '\\') break;
    end++;
  }
  if (end < 0 || /\s/.test(state.src[end - 1]) || /\d/.test(state.src[end + 1] || '') || state.src.slice(start, end).includes('\n')) return false;
  if (!silent) { const token = state.push('math_inline', 'span', 0); token.content = state.src.slice(start + 1, end).replace(/^`|`$/g, ''); }
  state.pos = end + 1;
  return true;
});
md.renderer.rules.math_inline = (tokens, index) => katex.renderToString(tokens[index].content, { throwOnError: false, trust: false, strict: 'ignore', output: 'html' });
