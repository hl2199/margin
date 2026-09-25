(() => {
  const pause = () => new Promise(resolve => { window.layoutContinue = resolve; });
  const key = (key, shiftKey = false) => document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown', {key, shiftKey, bubbles:true, cancelable:true}));
  const rect = r => ({x:r.x,y:r.y,width:r.width,height:r.height});
  function snapshot() {
    const selection = window.getSelection();
    const line = (selection.focusNode?.nodeType === 1 ? selection.focusNode : selection.focusNode?.parentElement)?.closest('.cm-line');
    const range = document.createRange();
    if (selection.focusNode) range.setStart(selection.focusNode, selection.focusOffset);
    range.collapse(true);
    let caret = range.getBoundingClientRect();
    let rowY = line?.getBoundingClientRect().y;
    if (caret.height && line?.textContent) {
      const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
      let node; while ((node = walker.nextNode()) && !node.length) {}
      if (node) { const glyph = document.createRange(); glyph.setStart(node,0); glyph.setEnd(node,1); rowY += caret.y - glyph.getBoundingClientRect().y; }
    }
    if (!caret.height && line) caret = line.getBoundingClientRect();
    const prefix = document.createRange();
    if (line) { prefix.selectNodeContents(line); prefix.setEnd(selection.focusNode, selection.focusOffset); }
    return {renderedMath:document.querySelectorAll('.md-math .katex, .block-preview .katex').length,markers:document.querySelectorAll('.md-marker').length,source:window.margin.getText(),caret:rect(caret),rowY,line:line?.textContent,prefix:line ? prefix.toString() : null,
      lineHeight:line ? parseFloat(getComputedStyle(line).lineHeight) : null,
      scroll:document.querySelector('.cm-scroller').scrollTop,
      table:document.querySelector('.table-widget table') ? rect(document.querySelector('.table-widget table').getBoundingClientRect()) : null,
      rows:[...document.querySelectorAll('.cm-content > *')].map(el=>({text:el.textContent,cls:el.className,...rect(el.getBoundingClientRect())})),
      selected:selection.toString()};
  }
  const near = (a,b) => Number.isFinite(a) && Number.isFinite(b) && Math.abs(a-b)<1.5;
  window.layoutRun = async(width,zoom) => {
    window.layoutResult=null; const results=[];
    const check=(name,passed,evidence)=>results.push({name,passed:!!passed,width,zoom,...evidence});
    async function setup(source,offset) {
      window.margin.loadDocument({text:source,name:'editing-layout.md',dirty:false});window.margin.command('selectAll');key('ArrowLeft');
      for(let i=0;i<offset;i++) key('ArrowRight');
      await pause();return snapshot();
    }
    async function move(k,shift=false) {key(k,shift);await pause();return snapshot();}
    async function insert(text) {document.execCommand('insertText',false,text);await pause();await pause();return snapshot();}
    const first='Opening sentence of the first paragraph.';
    const math='Coupled model. '+('Each connection has coupling $\\alpha_{ij}$ and preferred difference $\\Psi_{ij} = \\chi_i - \\chi_j$ with compatible fitted phases. ').repeat(3);
    const table='| Fit | Result |\n| --- | --- |\n| Coupled | Example |';
    for (const [name,head] of [['plain paragraph',first],['math paragraph',math]]) {
      const source=head+'\n\nFollowing paragraph.\n\n'+table;
      const before=await setup(source,head.length);
      if(name==='plain paragraph'){window.layoutCapture='before-enter';await pause();}
      const empty=await move('Enter');
      if(name==='plain paragraph'){window.layoutCapture='empty-line';await pause();}
      const typed=await insert('F');
      if(name==='plain paragraph'){window.layoutCapture='typed-line';await pause();}
      check(name+': Enter advances exactly one text row',near(empty.rowY-before.rowY,before.lineHeight),{before,empty});
      check(name+': typing on the new line keeps caret height',near(empty.rowY,typed.rowY),{empty,typed});
      check(name+': typing on the new line keeps following blocks in place',near(empty.table?.y,typed.table?.y),{empty,typed});
      check(name+': Enter and typing preserve exact source',typed.source===head+'\nF\n\nFollowing paragraph.\n\n'+table,{typed});
      const empty2=await move('Enter'),typed2=await insert('Second');
      check(name+': repeated Enter and text keep their row',near(empty2.rowY,typed2.rowY)&&near(empty2.rowY-typed.rowY,typed.lineHeight),{typed,empty2,typed2});
    }
    const source=first+'\n\n'+math+'\n\n'+table;
    let before=await setup(source,8),steps=[];
    // Include blank separator destinations where visible, then enter math.
    while(steps.length<5 && !steps.at(-1)?.line?.includes('Coupled')) steps.push(await move('ArrowDown'));
    const entered=steps.at(-1),alternating=[];
    for(let i=0;i<4;i++){
      alternating.push(await move('ArrowUp'));
      if(i===0){window.layoutCapture='departed-math';await pause();}
      alternating.push(await move('ArrowDown'));
    }
    // Obsidian reveals only the element under the caret, never a whole paragraph.
    check('Inline math stays rendered while the caret is elsewhere in its paragraph',alternating.every(s=>s.renderedMath===6),{alternating});
    check('Repeated Up/Down retains rendered table height and position',alternating.every(s=>near(s.table?.y,entered.table?.y)),{before,steps,alternating});
    check('Repeated Up/Down returns to the same caret row and source position',alternating.filter((s,i)=>i%2).every(s=>s.line===entered.line&&s.prefix===entered.prefix&&near(s.rowY,entered.rowY)),{entered,alternating});
    window.layoutCapture='arrow-round-trip';await pause();
    check('Repeated Up/Down leaves Markdown unchanged',alternating.every(s=>s.source===source),{source,alternating});
    const inMath=await setup(source,first.length+2+'Coupled model. Each connection has coupling $'.length);
    check('Placing the caret inside inline math reveals only that formula',inMath.renderedMath===5&&!!document.querySelector('.md-math-source'),{inMath});
    const cell=document.querySelector('.table-widget td:last-child');
    const cellRange=document.createRange();cellRange.selectNodeContents(cell);const cellBox=cellRange.getBoundingClientRect();
    const event={button:0,buttons:1,detail:1,clientX:cellBox.x+3,clientY:cellBox.y+cellBox.height/2,bubbles:true,cancelable:true};
    cell.dispatchEvent(new MouseEvent('mousedown',event));document.dispatchEvent(new MouseEvent('mouseup',{...event,buttons:0}));await pause();
    check('Clicking a table cell edits it in place while math stays rendered',document.activeElement?.closest('.table-widget td')&&document.activeElement.textContent==='Example'&&snapshot().renderedMath===6,{after:snapshot()});
    check('Editing a table cell in place preserves Markdown',window.margin.getText()===source,{actual:window.margin.getText(),source});
    // Wrapped rows and a selection must remain reversible as well.
    before=await setup(math,8);const down=await move('ArrowDown',true),up=await move('ArrowUp',true);
    check('Shift-Up reverses Shift-Down on wrapped math source',down.selected.length>0&&up.selected===''&&up.prefix===before.prefix&&near(up.rowY,before.rowY),{before,down,up});
    // Blank separator caret must remain on the same displayed row after typing.
    before=await setup(source,first.length+1);const blankTyped=await insert('Note');
    check('Typing in an existing blank separator keeps the caret row',near(before.rowY,blankTyped.rowY),{before,blankTyped});
    await move('Escape');
    check('Leaving editing restores math preview without source changes',!!document.querySelector('.katex')&&window.margin.getText()===blankTyped.source,{source:window.margin.getText()});
    for (const [name,text,offset] of [
      ['CRLF',first+'\r\n\r\nNext paragraph.',first.length],
      ['code fence','```text\nAlpha\n```',13],
      ['trailing blank','Alpha\n',6],
      ['empty document','',0]]) {
      const start=await setup(text,offset),empty=await move('Enter'),typed=await insert('F');
      check(name+': typing preserves the inserted row',near(empty.rowY,typed.rowY),{start,empty,typed});
      window.margin.command('undo');window.margin.command('redo');await pause();
      check(name+': undo/redo preserves inserted text',window.margin.getText()===typed.source,{expected:typed.source,actual:window.margin.getText()});
      if(name==='CRLF')check('CRLF insertion retains line endings',typed.source===first+'\r\nF\r\n\r\nNext paragraph.',{typed});
    }
    for (const [direction,text,start,steps] of [
      ['ArrowDown','**First** paragraph.\n\nSecond paragraph.',3,2],
      ['ArrowUp','First paragraph.\n\n**Second** paragraph.',23,2],
      ['ArrowRight','**First** paragraph.\n\nSecond paragraph.',20,1],
      ['ArrowLeft','First paragraph.\n\n**Second** paragraph.',18,1]]) {
      await setup(text,start);
      for(let i=0;i<steps;i++)await move(direction);
      check(direction+': departed formatted paragraph hides its markup again',!!document.querySelector('.md-strong')&&snapshot().markers===0,{after:snapshot()});
      check(direction+': navigation preserves exact Markdown',window.margin.getText()===text,{actual:window.margin.getText(),text});
    }
    await setup('**First** paragraph.\n\n**Second** paragraph.',3);
    await move('ArrowDown',true);await move('ArrowDown',true);
    check('Shift-selection reveals the markup it touches',snapshot().markers===4&&snapshot().selected.length>0,{after:snapshot()});
    await setup(source,first.length+2+'Coupled model. Each connection has coupling $'.length);await move('Escape');
    check('Leaving editing renders every element',snapshot().markers===0&&snapshot().renderedMath===6&&window.margin.getText()===source,{after:snapshot()});
    // Obsidian-style reveal: only the element under the caret shows its Markdown.
    const lineTexts=()=>[...document.querySelectorAll('.cm-content > .cm-line')].map(line=>line.textContent);
    const inline='A **bold** and *italic* word.';
    let state=await setup(inline,5);
    check('Caret in bold reveals only its markers',state.markers===2&&lineTexts()[0]==='A **bold** and italic word.',{lines:lineTexts(),state});
    state=await setup('## Heading\n\nText',4);
    check('Caret on a heading reveals its hashes',lineTexts()[0]==='## Heading',{lines:lineTexts()});
    await move('ArrowDown');await move('ArrowDown');
    check('Leaving a heading hides its hashes',lineTexts()[0]==='Heading'&&snapshot().line==='Text',{lines:lineTexts()});
    await setup('- item text',4);
    check('Caret in list text keeps the rendered bullet',lineTexts()[0]==='• item text',{lines:lineTexts()});
    await move('Home');
    check('Caret at the list marker reveals it',lineTexts()[0]==='- item text',{lines:lineTexts()});
    const fence='```js\nlet x = 1;\n```\n\nAfter';
    await setup(fence,fence.length);
    check('Code fences are hidden while the caret is outside the block',!lineTexts().some(text=>text.includes('```'))&&!!document.querySelector('.md-fence-label'),{lines:lineTexts()});
    await move('ArrowUp');await move('ArrowUp');
    check('Entering a code block reveals its fences',lineTexts().filter(text=>text.includes('```')).length===2,{lines:lineTexts()});
    const block='$$\nx^2\n$$\n\nAfter';
    await setup(block,block.length);
    check('Display math renders while the caret is outside it',!!document.querySelector('.block-preview .katex')&&!lineTexts().includes('$$'),{lines:lineTexts()});
    await move('ArrowUp');await move('ArrowUp');
    check('Entering display math reveals its source',!document.querySelector('.block-preview')&&lineTexts().includes('$$'),{lines:lineTexts()});
    check('Revealing blocks never changes Markdown',window.margin.getText()===block,{actual:window.margin.getText()});
    const around='Above\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\nBelow';
    await setup(around,0);await move('ArrowDown');await move('ArrowDown');
    const cellKey=async k=>{document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:k,bubbles:true,cancelable:true}));await pause();};
    check('Down from the line above a table enters its header cell',document.activeElement?.closest('.table-widget th')&&document.activeElement.textContent==='A',{active:document.activeElement?.outerHTML});
    await cellKey('Enter');
    check('Enter moves to the cell below',document.activeElement?.closest('.table-widget td')&&document.activeElement.textContent==='1',{active:document.activeElement?.outerHTML});
    await cellKey('Enter');await pause();
    check('Enter in the last row leaves below the table',document.activeElement?.classList.contains('cm-content')&&snapshot().line===''&&window.margin.getText()===around,{after:snapshot()});
    await move('ArrowUp');
    check('Up from the line below a table enters its last row',document.activeElement?.closest('.table-widget td')&&document.activeElement.textContent==='1',{active:document.activeElement?.outerHTML});
    await cellKey('Escape');await pause();
    // Typing below a table never becomes table rows (reproduces a recorded bug).
    const tableRows=()=>document.querySelectorAll('.table-widget tr').length;
    const below='Intro\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\nThis example paragraph.\n\nExplained error.';
    window.margin.loadDocument({text:below,name:'table-typing.md',dirty:false});window.margin.command('selectAll');key('ArrowRight');await pause();
    for(let i=0;i<3;i++)await move('ArrowUp');
    for(const letter of 'sasdf'){document.execCommand('insertText',false,letter);await pause();}
    state=snapshot();
    check('Typing on the blank line below a table stays on that line',state.source===below.replace('| 1 | 2 |\n\n','| 1 | 2 |\nsasdf\n')&&state.line==='sasdf',{state});
    check('Typing below a table leaves its rows and the following paragraphs alone',tableRows()===2&&![...document.querySelectorAll('.table-widget td')].some(td=>/sasdf|This example|Explained/.test(td.textContent)),{rows:tableRows(),lines:lineTexts()});
    const last='Intro\n\n| A | B |\n| --- | --- |\n| 1 | 2 |';
    window.margin.loadDocument({text:last,name:'table-end.md',dirty:false});window.margin.command('selectAll');key('ArrowRight');await pause();
    document.execCommand('insertText',false,'t');await pause();document.execCommand('insertText',false,'yped');await pause();
    check('Typing after a table at the end of the document starts a new line',window.margin.getText()===last+'\ntyped'&&tableRows()===2&&lineTexts().includes('typed'),{source:window.margin.getText(),lines:lineTexts()});
    window.margin.loadDocument({text:last,name:'table-paste.md',dirty:false});window.margin.command('selectAll');key('ArrowRight');await pause();
    const transfer=new DataTransfer();transfer.setData('text/plain','pasted');
    document.querySelector('.cm-content').dispatchEvent(new ClipboardEvent('paste',{clipboardData:transfer,bubbles:true,cancelable:true}));await pause();
    check('Pasting after a table at the end of the document starts a new line',window.margin.getText()===last+'\npasted'&&tableRows()===2,{source:window.margin.getText()});
    const caption='| A | B |\n| --- | --- |\n| 1 | 2 |\nCaption in the $\\alpha$ plot and the $\\Psi$ plot.\n\nAfter.';
    await setup(caption,0);await move('Escape');
    check('Inline math renders in a caption directly below a table',document.querySelectorAll('.md-math .katex').length===2&&!lineTexts().some(text=>text.includes('$')),{lines:lineTexts()});
    const afterEquation='### Stability\n$$\\dot{\\phi_i} = \\omega_i$$\nIn the steady state, values settle at $\\Omega$. $\\alpha$\n\nAfter.';
    await setup(afterEquation,0);await move('Escape');
    check('Inline math renders on the line right after a one-line display equation',!!document.querySelector('.block-preview .katex')&&document.querySelectorAll('.md-math .katex').length===2&&!lineTexts().some(text=>text.includes('$')),{lines:lineTexts()});
    window.margin.command('selectAll');key('ArrowRight');await pause();await move('ArrowUp');await move('ArrowUp');await move('End');
    check('Revealed inline math beside an equation is styled once',!!document.querySelector('.md-math-source')&&!document.querySelector('.md-math-source .md-math-source')&&getComputedStyle(document.querySelector('.md-math')).display==='inline-block',{lines:lineTexts()});
    window.layoutResult=results;
  };
})();
