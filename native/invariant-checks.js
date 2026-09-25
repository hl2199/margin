(() => {
  // Invariants that must hold for any document, checked at every caret position.
  const pause = () => new Promise(resolve => { window.invariantContinue = resolve; });
  const errors = [];
  window.addEventListener('error', event => errors.push(String(event.message)));
  window.addEventListener('unhandledrejection', event => errors.push('rejection: ' + String(event.reason)));
  const originalError = console.error;
  console.error = (...args) => { errors.push(args.map(String).join(' ')); originalError(...args); };
  const key = (key, modifiers = {}) => (document.activeElement || document.querySelector('.cm-content'))
    .dispatchEvent(new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true, ...modifiers }));
  const state = () => window.margin.selectionState();

  // Rendered text must not show markup that the preview hides.
  function visibleMarkup() {
    const problems = [];
    for (const line of document.querySelectorAll('.cm-content > .cm-line')) {
      if (line.classList.contains('md-code-line')) continue;
      const copy = line.cloneNode(true);
      copy.querySelectorAll('.md-code, .md-math-source, .md-marker, .md-url, .katex').forEach(element => element.remove());
      const text = copy.textContent;
      if (/\*\*|~~|\]\(|^#{1,6} |^> ?|\$(?![\d\s$])[^$\n]*?[^\s$]\$(?!\d)/.test(text)) problems.push(text);
    }
    return problems;
  }
  // Inline widgets must not overlap the text or widgets beside them.
  function overlaps(scope = document) {
    const problems = [];
    for (const widget of scope.querySelectorAll('.cm-line .md-math, .cm-line .md-image, .cm-line .md-bullet, .cm-line .md-task')) {
      const box = widget.getBoundingClientRect();
      if (!box.width) continue;
      for (const neighbour of [widget.previousSibling, widget.nextSibling]) {
        if (!neighbour || neighbour.nodeName === 'IMG') continue;
        const range = document.createRange();
        range.selectNodeContents(neighbour);
        for (const rect of range.getClientRects()) {
          const vertical = Math.min(rect.bottom, box.bottom) - Math.max(rect.top, box.top);
          const horizontal = Math.min(rect.right, box.right) - Math.max(rect.left, box.left);
          if (rect.width > 1 && vertical > 4 && horizontal > 1.5) problems.push({ widget: widget.className, text: neighbour.textContent.slice(0, 30), horizontal });
        }
      }
    }
    return problems;
  }

  window.invariantRun = async (width, zoom, documents) => {
    window.invariantResult = null;
    const results = [];
    const check = (name, passed, evidence) => results.push({ name, passed: !!passed, width, zoom, ...evidence });
    for (const [name, source] of documents) {
      errors.length = 0;
      window.margin.loadDocument({ text: source, name, dirty: false });
      await pause(); await pause();
      check(`${name}: renders without markup showing`, visibleMarkup().length === 0, { problems: visibleMarkup().slice(0, 5) });
      check(`${name}: rendered widgets do not overlap text`, overlaps().length === 0, { problems: overlaps().slice(0, 5) });
      // Punctuation touching a formula is drawn with it, so no row starts with it.
      const dangling = [...document.querySelectorAll('.md-math')].map(math => {
        let next = math.nextSibling; while (next && next.nodeName === 'IMG') next = next.nextSibling;
        return next?.nodeType === 3 && /^[,.;:!?)]/.test(next.data) ? next.data.slice(0, 10) : null;
      }).filter(Boolean);
      check(`${name}: punctuation after inline math stays with the formula`, !dangling.length, { dangling: dangling.slice(0, 5) });
      // Scrolling brings new lines into view already rendered.
      const scroller = document.querySelector('.cm-scroller'), unstyled = [];
      for (let top = 0; top <= scroller.scrollHeight; top += scroller.clientHeight * 0.6) {
        scroller.scrollTop = top; scroller.dispatchEvent(new Event('scroll'));
        await pause(); await pause();
        const problems = visibleMarkup();
        if (problems.length) unstyled.push({ top: Math.round(top), problems: problems.slice(0, 2) });
      }
      scroller.scrollTop = 0; await pause();
      check(`${name}: lines scrolled into view are already rendered`, !unstyled.length, { unstyled: unstyled.slice(0, 3) });

      // Horizontal sweep: every Right/Left moves the caret one way until the end.
      const anomalies = [], layout = [];
      window.margin.setSelection(0);
      await pause();
      for (let steps = 0, previous = state(); steps < 20000 && previous.head < previous.length; steps++) {
        key('ArrowRight'); await pause();
        const now = state();
        if (now.head <= previous.head) { anomalies.push({ direction: 'right', from: previous.head, to: now.head }); break; }
        const problems = overlaps(document.querySelector('.cm-content'));
        if (problems.length && layout.length < 5) layout.push({ at: now.head, problems });
        previous = now;
      }
      for (let steps = 0, previous = state(); steps < 20000 && previous.head > 0; steps++) {
        key('ArrowLeft'); await pause();
        const now = state();
        if (now.head >= previous.head) { anomalies.push({ direction: 'left', from: previous.head, to: now.head }); break; }
        const problems = overlaps(document.querySelector('.cm-content'));
        if (problems.length && layout.length < 5) layout.push({ at: now.head, problems });
        previous = now;
      }
      check(`${name}: Right and Left reach every position in order`, !anomalies.length, { anomalies });
      check(`${name}: nothing overlaps while the caret moves`, !layout.length, { layout });
      check(`${name}: caret movement leaves the Markdown unchanged`, window.margin.getText() === source, {});

      // Vertical sweep: Down never moves back and reaches the end; Up returns.
      const vertical = [];
      const lineOf = pos => source.slice(0, pos).split('\n').length;
      const visited = new Set([1]);
      window.margin.setSelection(0);
      await pause();
      for (let steps = 0, stalls = 0, previous = state(); steps < 4000; steps++) {
        key('ArrowDown'); await pause();
        const now = state();
        visited.add(lineOf(now.head));
        const inCell = document.activeElement?.closest?.('.table-widget');
        if (now.head < previous.head && !inCell) { vertical.push({ direction: 'down', from: previous.head, to: now.head }); break; }
        stalls = now.head === previous.head ? stalls + 1 : 0;
        if (stalls > 30) break;
        previous = now;
      }
      const bottom = state().head;
      // Every line is a stop on the way down, except table rows (entered by cell).
      const lines = source.split('\n');
      const skippedLines = lines.map((text, i) => i + 1).filter(number => !visited.has(number) && !/(?<!\\)\|/.test(lines[number - 1]) && number <= lineOf(bottom));
      check(`${name}: Down stops on every line`, !skippedLines.length, { skippedLines: skippedLines.slice(0, 10) });
      check(`${name}: Down reaches the last line`, !vertical.length && window.margin.getText().lastIndexOf('\n') < bottom + 1, { vertical, bottom, length: source.length });
      for (let steps = 0, stalls = 0, previous = state(); steps < 4000 && !(previous.head === 0); steps++) {
        key('ArrowUp'); await pause();
        const now = state();
        const inCell = document.activeElement?.closest?.('.table-widget');
        if (now.head > previous.head && !inCell) { vertical.push({ direction: 'up', from: previous.head, to: now.head }); break; }
        stalls = now.head === previous.head ? stalls + 1 : 0;
        if (stalls > 30) { vertical.push({ direction: 'up', stuckAt: now.head }); break; }
        previous = now;
      }
      if (document.activeElement?.closest?.('.table-widget')) key('Escape');
      check(`${name}: Up and Down move monotonically through the document`, !vertical.length, { vertical });
      check(`${name}: vertical movement leaves the Markdown unchanged`, window.margin.getText() === source, {});

      // Typing at sampled positions changes exactly that position; undo restores.
      const edits = [];
      const positions = new Set([0, source.length]);
      for (let i = 1; i < 40; i++) positions.add(Math.floor(source.length * i / 40));
      for (const position of [...positions].sort((a, b) => a - b)) {
        window.margin.loadDocument({ text: source, name, dirty: false });
        window.margin.setSelection(position);
        await pause();
        const at = state().head;
        document.execCommand('insertText', false, 'x');
        await pause();
        const typed = window.margin.getText();
        // Exactly one 'x' inserted on the caret's line (in a table: into the cell
        // there), or on a new line beside a table.
        const lineOf = pos => source.slice(0, pos).split('\n').length;
        // A table's hidden separator row has no cell; its text goes to the next row up.
        const lineText = pos => source.slice(source.lastIndexOf('\n', pos - 1) + 1, (source.indexOf('\n', pos) + 1 || source.length + 1) - 1);
        const inTable = (a, b) => Math.abs(lineOf(a) - lineOf(b)) === 1 && /^\s*\|?\s*:?-{3,}/.test(lineText(b)) && lineText(a).includes('|');
        let first = 0;
        while (first < source.length && typed[first] === source[first]) first++;
        const onLine = typed.length === source.length + 1 && typed[first] === 'x' && typed.slice(0, first) + typed.slice(first + 1) === source && (lineOf(first) === lineOf(at) || inTable(first, at));
        const newLine = [source.slice(0, at) + '\nx' + source.slice(at), source.slice(0, at) + 'x\n' + source.slice(at)].includes(typed);
        document.activeElement?.closest?.('.table-widget') && key('Escape');
        window.margin.command('undo');
        await pause();
        if (!(onLine || newLine) || window.margin.getText() !== source) edits.push({ position, at, typed: typed.slice(Math.max(0, at - 20), at + 20), restored: window.margin.getText() === source });
      }
      check(`${name}: typing inserts at the caret and undo restores`, !edits.length, { edits: edits.slice(0, 5) });

      // Backspace and Delete remove exactly one character beside the caret.
      const deletions = [];
      for (const position of [...positions].sort((a, b) => a - b)) {
        for (const [keyName, offset] of [['Backspace', -1], ['Delete', 0]]) {
          window.margin.loadDocument({ text: source, name, dirty: false });
          window.margin.setSelection(position);
          await pause();
          const at = state().head;
          if ((offset < 0 && at === 0) || (offset === 0 && at === source.length)) continue;
          key(keyName); await pause();
          const after = window.margin.getText();
          let first = 0;
          while (first < after.length && after[first] === source[first]) first++;
          const removedOne = after.length === source.length - 1 && source.slice(0, first) + source.slice(first + 1) === after;
          const beside = Math.abs(first - (at + offset)) <= 1 || source.slice(Math.min(first, at + offset), Math.max(first, at + offset)).split('').every(c => c === source[first]);
          // Backspace right after list or quote markup removes that markup.
          const markup = offset < 0 && /^(?:[ \t]*(?:[-*+]|\d+[.)])[ \t]+(?:\[[ xX]\][ \t]+)?|[ \t]*>[ \t]?)$/.test(source.slice(source.lastIndexOf('\n', at - 1) + 1, at)) && after === source.slice(0, source.lastIndexOf('\n', at - 1) + 1) + source.slice(at);
          if (!(removedOne && beside) && !markup && after !== source) deletions.push({ key: keyName, at, removed: JSON.stringify(source.slice(first, first + source.length - after.length)), near: JSON.stringify(source.slice(Math.max(0, at - 15), at + 15)) });
        }
      }
      check(`${name}: Backspace and Delete remove one character beside the caret`, !deletions.length, { deletions: deletions.slice(0, 5) });

      // Clicking a character places the caret right after it; double-click selects its word.
      const clicks = [];
      window.margin.loadDocument({ text: source, name, dirty: false });
      key('Escape'); await pause();
      const glyphs = [];
      for (const line of document.querySelectorAll('.cm-content > .cm-line')) {
        const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
        for (let node; (node = walker.nextNode());) {
          if (node.parentElement.closest('.md-math, .md-image, .md-bullet, .md-fence-label, .cm-widgetBuffer')) continue;
          for (let i = 0; i < node.length; i++) if (/[A-Za-z]/.test(node.data[i]) && /[A-Za-z]/.test(node.data[i + 1] || '')) glyphs.push({ node, i });
        }
      }
      const step = Math.max(1, Math.floor(glyphs.length / 25));
      for (let g = 0; g < glyphs.length; g += step) {
        window.margin.loadDocument({ text: source, name, dirty: false });
        key('Escape'); await pause();
        // Locate the same glyph again in the fresh DOM by line and text.
        const { node, i } = glyphs[g];
        const lineIndex = [...document.querySelectorAll('.cm-content > .cm-line')].findIndex(line => line.textContent === node.parentElement?.closest('.cm-line')?.textContent);
        const line = document.querySelectorAll('.cm-content > .cm-line')[lineIndex];
        if (!line) continue;
        const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
        let target = null;
        for (let n; (n = walker.nextNode());) if (n.data === node.data) { target = n; break; }
        if (!target) continue;
        const range = document.createRange(); range.setStart(target, i); range.setEnd(target, i + 1);
        // After a soft wrap WebKit adds an empty box at the previous row's end.
        const box = [...range.getClientRects()].sort((a, b) => b.width - a.width)[0] ?? range.getBoundingClientRect();
        // Only glyphs a person could click: at least 6px wide and inside the visible area.
        const visible = document.querySelector('.cm-scroller').getBoundingClientRect();
        if (box.width < 6 || box.top < visible.top || box.bottom > visible.bottom) continue;
        const point = { button: 0, buttons: 1, detail: 1, clientX: box.right - box.width * 0.25, clientY: box.top + box.height / 2, bubbles: true, cancelable: true };
        const element = document.elementFromPoint(point.clientX, point.clientY);
        if (!element || element.closest('.md-link-rendered, .table-widget, .block-preview')) continue;
        element.dispatchEvent(new MouseEvent('mousedown', point)); document.dispatchEvent(new MouseEvent('mouseup', { ...point, buttons: 0 }));
        await pause();
        const head = state().head;
        if (source[head - 1] !== target.data[i]) clicks.push({ kind: 'click', char: target.data[i], word: target.data.slice(Math.max(0, i - 8), i + 8), got: JSON.stringify(source.slice(head - 5, head + 5)) });
        element.dispatchEvent(new MouseEvent('mousedown', { ...point, detail: 2 })); document.dispatchEvent(new MouseEvent('mouseup', { ...point, detail: 2, buttons: 0 }));
        await pause();
        const selection = state();
        const selected = source.slice(Math.min(selection.anchor, selection.head), Math.max(selection.anchor, selection.head));
        const word = (target.data.slice(0, i + 1).match(/[\p{L}\p{N}_]+$/u)?.[0] || '') + (target.data.slice(i + 1).match(/^[\p{L}\p{N}_]+/u)?.[0] || '');
        if (word && selected !== word) clicks.push({ kind: 'double-click', expected: word, selected });
      }
      check(`${name}: clicks place the caret and double-clicks select the clicked word`, !clicks.length, { clicks: clicks.slice(0, 5), sampled: Math.ceil(glyphs.length / step) });

      window.margin.loadDocument({ text: source, name, dirty: false });
      window.margin.setSelection(Math.floor(source.length / 2));
      await pause();
      key('Escape'); await pause(); await pause();
      check(`${name}: leaving the editor renders every element`, visibleMarkup().length === 0, { problems: visibleMarkup().slice(0, 5) });
      check(`${name}: no script errors`, errors.length === 0, { errors: errors.slice(0, 5) });
    }
    window.invariantResult = results;
  };
})(); void 0;
