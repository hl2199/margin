(() => {
  const pause = () => new Promise(resolve => { window.selectionContinue = resolve; });
  const key = (key, shiftKey = false) => document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown', {key,shiftKey,bubbles:true,cancelable:true}));
  const point = (word, edge='end', selector='.cm-content') => {
    const walker=document.createTreeWalker(document.querySelector(selector),NodeFilter.SHOW_TEXT);let node;
    while(node=walker.nextNode()) {
      const at=node.textContent.indexOf(word);if(at<0)continue;
      const range=document.createRange();range.setStart(node,edge==='start'?at:at+word.length-1);range.setEnd(node,edge==='start'?at+1:at+word.length);
      const r=range.getBoundingClientRect();
      return {rect:{left:r.left,right:r.right,top:r.top,bottom:r.bottom},text:node.textContent,at,element:node.parentElement,x:edge==='start'?r.left+1:r.right-1,y:r.top+r.height/2};
    }
    throw Error('Missing text: '+word);
  };
  function mouse(point,type='mousedown',detail=1,shiftKey=false) {
    const event={button:0,buttons:type==='mouseup'?0:1,detail,shiftKey,clientX:point.x,clientY:point.y,bubbles:true,cancelable:true};
    (type==='mouseup'?document:point.element).dispatchEvent(new MouseEvent(type,event));
  }
  // A drawn selection sits behind the text; shading at most half opaque shows it.
  const opaque=color=>{const m=color.match(/rgba?\(([^)]+)\)/);if(!m)return color!=='transparent';const parts=m[1].split(/[\s,\/]+/).filter(Boolean);return (parts.length>3?parseFloat(parts[3]):1)>=0.5;};
  let pointerEvidence=null;
  const click=(word,detail=1,shift=false,selector='.cm-content')=>{const p=point(word,'end',selector); const caret=document.caretRangeFromPoint(p.x,p.y); const root=p.element.closest('pre')?.querySelector('code') || p.element.closest('[data-source-line]'); let before=null; if(caret&&root?.contains(caret.startContainer)){const r=document.createRange();r.selectNodeContents(root);r.setEnd(caret.startContainer,caret.startOffset);before=r.toString();} pointerEvidence={rect:p.rect,text:p.text,at:p.at,word,x:p.x,y:p.y,root:root?.outerHTML,before,caretText:caret?.startContainer.textContent,caretOffset:caret?.startOffset}; mouse(p,'mousedown',detail,shift);mouse(p,'mouseup',detail,shift);};
  function snapshot() {
    const selection=window.getSelection(), parent=selection.focusNode?.parentElement;
    return {pointerEvidence,source:window.margin.getText(),selected:selection.toString(),focusText:selection.focusNode?.textContent,focusOffset:selection.focusOffset,anchorText:selection.anchorNode?.textContent,anchorOffset:selection.anchorOffset,nativeBackground:parent?getComputedStyle(parent,'::selection').backgroundColor:null,drawnHighlights:document.querySelectorAll('.cm-selectionBackground').length,selectionLayer:!!document.querySelector('.cm-selectionLayer'),opaqueTextBackgrounds:Array.from(document.querySelectorAll('.md-code-line,.md-code')).map(element=>({image:getComputedStyle(element).backgroundImage,color:getComputedStyle(element).backgroundColor})),sourceBackground:parent?getComputedStyle(parent.closest('.cm-line')||parent).backgroundImage:null};
  }
  window.selectionRun=async(width,zoom)=>{
    window.selectionResult=null;const results=[];
    const check=(name,passed,evidence)=>results.push({name,passed:!!passed,width,zoom,...evidence});
    async function setup(source,edit=false) {
      window.margin.loadDocument({text:source,name:'selection.md',dirty:false});
      if(edit){window.margin.command('selectAll');key('ArrowLeft');}
      await pause();
    }
    const fixtures=[
      ['paragraph','alpha beta gamma','beta'],
      ['heading','## alpha beta gamma','beta'],
      ['bold','alpha **beta** gamma','beta'],
      ['italic','alpha *beta* gamma','beta'],
      ['strike','alpha ~~beta~~ gamma','beta'],
      ['inline code','alpha `beta` gamma','beta'],
      ['after link','[alpha](https://beta.invalid) beta gamma','beta'],
      ['quote','> alpha beta gamma','beta'],
      ['list','- alpha\n- beta gamma','beta'],
      ['task','- [x] alpha\n- [ ] beta gamma','beta'],
      ['table header','| alpha | beta |\n| --- | --- |\n| gamma | delta |','beta'],
      ['table cell','| alpha | gamma |\n| --- | --- |\n| delta | beta |','beta'],
      ['formatted table cell','| alpha | gamma |\n| --- | --- |\n| delta | **beta** |','beta'],
      ['table repeated cell','| alpha | gamma |\n| --- | --- |\n| beta | beta |','beta','td:last-child'],
      ['table without outer pipes','alpha | gamma\n--- | ---\ndelta | beta','beta'],
      ['table escaped pipe','| alpha | gamma |\n| --- | --- |\n| del\\|ta | beta |','beta'],
      ['table empty first cell','| alpha | gamma |\n| --- | --- |\n| | beta |','beta'],
      ['table inline code','| alpha | gamma |\n| --- | --- |\n| delta | `beta` |','beta'],
      ['code fence','```text\nalpha\nbeta gamma\n```','beta'],
      ['indented code','    alpha\n    beta gamma','beta'],
      ['frontmatter','---\nname: beta\n---\n\nalpha','beta'],
      ['CRLF table','| alpha | gamma |\r\n| --- | --- |\r\n| delta | beta |','beta']
    ];
    for(const [name,source,word,selector] of fixtures) {
      await setup(source);click(word,2,false,selector);await pause();const after=snapshot();
      const at=name==='after link'||name==='table repeated cell'?source.lastIndexOf(word):source.indexOf(word);
      window.margin.command('bold');const edited=window.margin.getText();
      check('Double-click selects correct '+name+' word',edited===source.slice(0,at)+'**'+word+'**'+source.slice(at+word.length),{source,after,edited});
    }
    for(const [name,source] of [...fixtures.filter(([name])=>['table cell','code fence','frontmatter','inline code','bold','heading','quote','list'].includes(name)),['math','$$\nx^2 + y^2\n$$'],['diagram','```mermaid\ngraph LR\nAlpha --> Beta\n```']]) {
      await setup(source,true);window.margin.command('selectAll');await pause();
      const after=snapshot();
      // Tables stay rendered under a document selection; their source is still what is selected and copied.
      check('Select all preserves '+name+' source',after.source===source&&(name==='table cell'?after.selected.includes('delta'):after.selected.replace(/\r\n/g,'\n')===source.replace(/\r\n/g,'\n')),{source,after});
      if (['inline code','table cell','code fence','frontmatter','math','diagram'].includes(name)) check('Selection stays visible over '+name+' backgrounds',(after.nativeBackground!=='rgba(0, 0, 0, 0)'&&after.nativeBackground!=='transparent')||(after.selectionLayer&&!after.opaqueTextBackgrounds.some(bg=>bg.image!=='none'||opaque(bg.color))),{source,after});
    }
    const across='Before words.\n\n| Header | Column |\n| --- | --- |\n| Cell | Value |\n\nAfter words.';
    await setup(across);click('Before');click('After',1,true);await pause();let after=snapshot();
    window.margin.command('bold');let edited=window.margin.getText();
    check('Shift-click spans table and neighboring paragraphs',edited===across.replace('Before','Before**').replace('After','After**'),{source:across,after,edited});
    await setup(across);let start=point('Before');mouse(start);await pause();let end=point('After');mouse(end,'mousemove');mouse(end,'mouseup');await pause();after=snapshot();
    window.margin.command('bold');edited=window.margin.getText();
    check('Dragging spans table and neighboring paragraphs',edited===across.replace('Before','Before**').replace('After','After**'),{source:across,after,edited});
    await setup(across);click('Before');await pause();start=point('Before');mouse(start);end=point('After');mouse(end,'mousemove');mouse(end,'mouseup');await pause();after=snapshot();
    window.margin.command('bold');edited=window.margin.getText();
    check('Dragging from already editable text into preview retains exact endpoints',edited===across.replace('Before','Before**').replace('After','After**'),{source:across,after,edited});
    await setup(across);click('After');click('Before',1,true);await pause();after=snapshot();
    window.margin.command('bold');edited=window.margin.getText();
    check('Reverse Shift-click spans table and paragraphs',edited===across.replace('Before','Before**').replace('After','After**'),{source:across,after,edited});
    const header='| Item | Description |\n| --- | --- |\n| Apple | Fruit |';
    await setup(header);start=point('Description');mouse(start);mouse(start,'mouseup');await pause();
    end={...start,element:document.elementFromPoint(start.x,start.y)};mouse(end,'mousedown',2);mouse(end,'mouseup',2);await pause();after=snapshot();
    check('Real double-click sequence selects the word in the table cell being edited',after.selected==='Description'&&document.activeElement?.isContentEditable&&document.activeElement.closest('.table-widget')&&after.source===header,{source:header,after});
    end={...start,element:document.elementFromPoint(start.x,start.y)};mouse(end,'mousedown',3);mouse(end,'mouseup',3);await pause();after=snapshot();
    check('Triple-click selects the whole table cell',after.selected==='Description'&&after.source===header,{source:header,after});
    const table='| Header | Column |\n| --- | --- |\n| Cell | Value |';
    await setup(table);start=point('Cell');mouse(start);mouse(start,'mouseup');await pause();
    document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true}));await pause();
    document.execCommand('insertText',false,'s');await pause();after=snapshot();
    check('Tab moves to the next cell, where typing edits its Markdown',after.source===table.replace('Value','Values')&&document.activeElement?.textContent==='Values',{source:table,after});
    document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'a',metaKey:true,bubbles:true,cancelable:true}));await pause();after=snapshot();
    check('Command-A in a table cell selects only that cell',after.selected==='Values'&&window.margin.selectionState().anchor===window.margin.selectionState().head,{after});
    document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));await pause();await pause();after=snapshot();
    check('Escape leaves the table and renders every cell again',!document.querySelector('.table-widget [contenteditable="true"]')&&document.activeElement?.classList.contains('cm-content')&&after.source===table.replace('Value','Values'),{after});
    const linked='alpha [beta](https://example.com) gamma';
    await setup(linked);let opened=null;const openLink=window.margin.openLink;window.margin.openLink=href=>{opened=href;};
    start=point('beta');mouse(start);mouse(start,'mouseup');await pause();window.margin.openLink=openLink;
    check('Clicking a rendered link opens it without editing',opened==='https://example.com'&&window.margin.getText()===linked,{source:linked,opened});
    window.selectionResult=results;
  };
})();
