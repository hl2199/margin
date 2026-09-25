(() => {
  // Native driver resumes between WebKit turns; hidden-page JS timers are throttled.
  const pause = () => new Promise(resolve => { window.navigationContinue = resolve; });
  const key = (key, shiftKey = false) => document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown', {key,shiftKey,bubbles:true,cancelable:true}));
  const rect = value => ({x:value.x,y:value.y,width:value.width,height:value.height});
  function state() {
    const selection = window.getSelection();
    const point = (node,offset) => {
      const parent=node?.nodeType===Node.ELEMENT_NODE?node:node?.parentElement;
      const line=parent?.closest('.cm-line');
      if (!node) return null;
      const range=document.createRange();range.setStart(node,offset);range.collapse(true);
      let box=range.getBoundingClientRect();
      const cursor=document.querySelector('.cm-cursor');
      if (!box.height && line && !line.textContent) box=line.getBoundingClientRect();
      else if (!box.height && cursor) box=cursor.getBoundingClientRect();
      let prefix=null;
      if (line) {const preceding=document.createRange();preceding.selectNodeContents(line);preceding.setEnd(node,offset);prefix=preceding.toString().replace(/^(\s*)•/,'$1-');}
      const rows=[], rowBounds=[];
      if(line) {
        const walker=document.createTreeWalker(line,NodeFilter.SHOW_TEXT);let text;
        while(text=walker.nextNode()) for(let i=0;i<text.length;i++) {
          const glyph=document.createRange();glyph.setStart(text,i);glyph.setEnd(text,i+1);
          for(const r of glyph.getClientRects()) if(r.height>0) {
            let bounds=rowBounds.find(row=>Math.abs(row.y-r.top)<2);
            if(!bounds) {bounds={y:r.top,left:r.left,right:r.right};rowBounds.push(bounds);rows.push(r.top);}
            else {bounds.left=Math.min(bounds.left,r.left);bounds.right=Math.max(bounds.right,r.right);}
          }
        }
      }
      rows.sort((a,b)=>a-b);
      const source=window.margin.getText();
      // A rendered bullet stands in for its one-character list marker.
      const lineText=line?.textContent?.replace(/^(\s*)•/,'$1-')??null;
      const unique=lineText && source.indexOf(lineText)===source.lastIndexOf(lineText);
      return {line:lineText,prefix,offset:unique?source.indexOf(lineText)+prefix.length:null,rect:rect(box),rows,rowBounds,lineHeight:line?.getBoundingClientRect().height??null};
    };
    return {source:window.margin.getText(),head:point(selection.focusNode,selection.focusOffset),anchor:point(selection.anchorNode,selection.anchorOffset),selected:selection.toString(),active:document.activeElement?.className};
  }
  const nearX=(a,b)=>{
    const row=b.head.rowBounds.find(row=>Math.abs(row.y-b.head.rect.y)<3);
    const expected=row?Math.max(row.left,Math.min(row.right,a.head.rect.x)):a.head.rect.x;
    return Math.abs(expected-b.head.rect.x)<13;
  };
  const samePoint=(a,b)=>a.head?.offset!=null&&a.head.offset===b.head?.offset;
  const rowIndex=s=>s.head.rows.findIndex(y=>Math.abs(y-s.head.rect.y)<3);
  window.navigationRun=async(width,zoom)=>{
    window.navigationResult=null;const results=[];
    const check=(name,passed,evidence)=>results.push({name,passed:!!passed,width,zoom,...evidence});
    async function setup(source,offset=0,fromEnd=false) {
      window.margin.loadDocument({text:source,name:'visual-navigation.md',dirty:false});window.margin.command('selectAll');key(fromEnd?'ArrowRight':'ArrowLeft');
      for(let i=0;i<offset;i++)key(fromEnd?'ArrowLeft':'ArrowRight');
      await pause();return state();
    }
    async function move(direction,shift=false){key(direction,shift);await pause();return state();}
    async function moveToText(direction,shift=false){
      let next=await move(direction,shift), previous=null;
      while(next.head?.line==='' && !previous) {
        check('Paragraph separator is a visible editable row',next.head.lineHeight>10,{after:next});
        previous=next; next=await move(direction,shift);
      }
      return next;
    }
    const long='Opening '+('visual rows need natural keyboard movement and stable horizontal aim ').repeat(7)+'ending';
    let before=await setup(long,8),after=await move('ArrowDown');
    check('Down advances one wrapped row within a paragraph',after.head.line===before.head.line&&rowIndex(after)===rowIndex(before)+1&&nearX(before,after),{source:long,actions:['start','Right × 8','Down'],before,after});
    let back=await move('ArrowUp');
    check('Up returns to same wrapped-row caret',samePoint(before,back),{source:long,actions:['Up'],before,after:back});
    check('wrapped movement leaves Markdown unchanged',after.source===long&&back.source===long,{source:long,after:back});

    before=await setup(long,8);after=await move('ArrowDown',true);
    check('Shift-Down extends within a wrapped paragraph without moving its anchor',after.anchor.offset===before.anchor.offset&&rowIndex(after)===rowIndex(before)+1&&nearX(before,after)&&after.selected===long.slice(before.head.offset,after.head.offset)&&after.source===long,{source:long,actions:['start','Right × 8','Shift-Down'],before,after});

    const previous=long+'\nNext row has enough width for the desired horizontal position.';
    before=await setup(previous,previous.split('\n')[1].length-9,true);after=await move('ArrowUp');
    check('Up enters last wrapped row of preceding source line',after.head.line===long&&rowIndex(after)===after.head.rows.length-1&&nearX(before,after),{source:previous,actions:['end','Left to second-line column 9','Up'],before,after});
    before=await setup(previous,long.length);back=await move('ArrowDown');
    check('Down enters first row of following source line',back.head.line===previous.split('\n')[1]&&rowIndex(back)===0&&nearX(before,back),{source:previous,actions:['start','Right to first source-line end','Down'],before,after:back});

    const unequal='iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii\nWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW';
    before=await setup(unequal,12);after=await move('ArrowDown');
    check('vertical goal uses horizontal pixels instead of character column',after.head.line===unequal.split('\n')[1]&&nearX(before,after),{source:unequal,actions:['start','Right × 12','Down'],before,after});

    for (const [name,source] of [['paragraph','Narrow first paragraph words here.\n\nWide second paragraph words here.'],['heading','## Heading with readable words\n\nParagraph with ordinary smaller letters.'],['list','- iiiiiiiiiiiiiiiiiiiiiiiiiiiiiii\n- WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW']]) {
      before=await setup(source,9);after=await moveToText('ArrowDown');
      const expected=source.split('\n').at(-1);
      check('Down crosses '+name+' boundary to visible text',after.head.line===expected&&rowIndex(after)===0&&nearX(before,after),{source,actions:['start','Right × 9','Down'],before,after});
      back=await moveToText('ArrowUp');
      check('Up crosses '+name+' boundary through its visible separator',back.head.line===source.split('\n')[0]&&nearX(before,back),{source,actions:['Up'],before,after:back});
      check(name+' movement preserves exact Markdown',after.source===source&&back.source===source,{source,after:back});
    }
    const middle='Opening paragraph above a heading.\n\n## Heading between paragraphs\n\nFollowing paragraph below a heading.';
    before=await setup(middle,9);after=await moveToText('ArrowDown');
    check('Down enters a heading below a paragraph at the horizontal goal',after.head.line===middle.split('\n')[2]&&nearX(before,after),{source:middle,before,after});
    const below=await moveToText('ArrowDown');
    check('Down leaves an interior heading at the original horizontal goal',below.head.line===middle.split('\n')[4]&&nearX(before,below),{source:middle,before,after:below});
    await moveToText('ArrowUp');back=await moveToText('ArrowUp');
    check('Round trip across an interior heading returns to the original caret',samePoint(before,back)&&back.source===middle,{source:middle,before,after:back});

    const shift='Selection begins on this line.\n\nSelection continues on the next line.\n\nSelection ends on the final line.';
    before=await setup(shift,10);after=await moveToText('ArrowDown',true);
    check('Shift-Down preserves anchor across paragraph boundary',after.anchor?.offset===before.anchor?.offset&&after.head.line===shift.split('\n')[2]&&after.selected.length>0,{source:shift,actions:['start','Right × 10','Shift-Down'],before,after});
    const expanded=await moveToText('ArrowDown',true);
    check('Shift-Down extends a nonempty selection with the original anchor',expanded.anchor?.offset===before.anchor?.offset&&expanded.head.line===shift.split('\n')[4]&&nearX(before,expanded)&&expanded.selected.length>after.selected.length,{source:shift,actions:['Shift-Down again'],before,after:expanded});
    await moveToText('ArrowUp',true);
    back=await moveToText('ArrowUp',true);
    check('Shift-Up restores original caret and anchor',samePoint(before,back)&&back.selected===''&&back.source===shift,{source:shift,actions:['Shift-Up'],before,after:back});

    const blank='First visible paragraph.\n\n\n\nLast visible paragraph.';
    before=await setup(blank,6);const steps=[];
    for(let i=0;i<4;i++)steps.push(await move('ArrowDown'));
    check('every displayed blank row remains reachable in order',steps[0].head.line===''&&steps[0].head.lineHeight>5&&steps[1].head.line===''&&steps[1].head.lineHeight>5&&steps[2].head.line===''&&steps[2].head.lineHeight>5&&steps[3].head.line==='Last visible paragraph.'&&nearX(before,steps[3])&&steps[2].head.rect.y>steps[1].head.rect.y+5&&steps[1].head.rect.y>steps[0].head.rect.y+5,{source:blank,actions:['start','Right × 6','Down × 4'],before,steps});
    check('blank-row movement preserves all source newlines',steps.every(s=>s.source===blank),{source:blank,steps});

    before=await setup('Boundary row.',0);after=await move('ArrowUp');
    check('Up at document start stays at start',samePoint(before,after)&&after.source==='Boundary row.',{source:'Boundary row.',before,after,actions:['start','Up']});
    before=await setup('Boundary row.',0,true);after=await move('ArrowDown');
    check('Down at document end stays at end',samePoint(before,after)&&after.source==='Boundary row.',{source:'Boundary row.',before,after,actions:['end','Down']});
    // Line shortcuts act on displayed rows of a wrapped paragraph.
    // Shifted letters arrive uppercase with the letter's key code, as from a real keyboard.
    const press=async(key,modifiers={})=>{
      const letter=/^[a-z]$/i.test(key);
      const event=new KeyboardEvent('keydown',{key:letter&&modifiers.shiftKey?key.toUpperCase():key,bubbles:true,cancelable:true,...modifiers});
      if(letter)Object.defineProperty(event,'keyCode',{get:()=>key.toUpperCase().charCodeAt(0)});
      document.querySelector('.cm-content').dispatchEvent(event);await pause();return state();
    };
    const rowStart=(rows,index)=>rows.slice(0,index).join('').length;
    const withoutRow=(rows,index)=>long.slice(0,rowStart(rows,index))+long.slice(rowStart(rows,index+1));
    const rowTexts=()=>{
      const focus=getSelection().focusNode;const line=(focus?.nodeType===1?focus:focus?.parentElement)?.closest('.cm-line');const rows=[];
      const walker=document.createTreeWalker(line,NodeFilter.SHOW_TEXT);let text;
      while(text=walker.nextNode()) for(let i=0;i<text.length;i++){
        const glyph=document.createRange();glyph.setStart(text,i);glyph.setEnd(text,i+1);
        // After a soft wrap WebKit adds an empty box at the previous row's end.
        const r=[...glyph.getClientRects()].filter(r=>r.height>0).sort((a,b)=>b.width-a.width)[0];if(!r)continue;
        let row=rows.find(row=>Math.abs(row.y-r.top)<2);if(!row){row={y:r.top,text:''};rows.push(row);}
        row.text+=text.data[i];
      }
      return rows.sort((a,b)=>a.y-b.y).map(row=>row.text);
    };
    const inSecondRow=async()=>{await setup(long,8);return move('ArrowDown');};
    for (const [name,key,modifiers] of [['Control-A','a',{ctrlKey:true}],['Command-Left','ArrowLeft',{metaKey:true}],['Home','Home',{}]]) {
      before=await inSecondRow();after=await press(key,modifiers);
      const rows=rowTexts();
      check(name+' moves to the start of the displayed row',rowIndex(after)===1&&after.head.offset===rowStart(rows,1)&&after.source===long,{source:long,actions:['start','Right × 8','Down',name],before,after,rows});
    }
    for (const [name,key,modifiers] of [['Control-E','e',{ctrlKey:true}],['Command-Right','ArrowRight',{metaKey:true}],['End','End',{}]]) {
      before=await inSecondRow();await press('a',{ctrlKey:true});after=await press(key,{...modifiers,shiftKey:true});
      const rows=rowTexts();
      check('Shift-'+name+' selects to the end of the displayed row only',after.selected.trim()===rows[1].trim()&&after.source===long,{source:long,actions:['Down','Control-A','Shift-'+name],after,rows});
    }
    before=await inSecondRow();after=await press('l',{ctrlKey:true});
    let rows=rowTexts();
    check('Control-L selects the displayed row',after.selected.trim()===rows[1].trim()&&after.source===long,{source:long,after,rows});
    before=await inSecondRow();rows=rowTexts();await press('a',{ctrlKey:true});after=await press('k',{ctrlKey:true});
    check('Control-K deletes to the end of the displayed row only',after.source===withoutRow(rows,1)&&after.source.endsWith('ending'),{source:long,rows,after:after.source});
    before=await inSecondRow();rows=rowTexts();after=await press('Backspace',{metaKey:true});
    check('Command-Delete deletes to the start of the displayed row only',after.source.startsWith(rows[0])&&after.source.length<long.length&&after.source.length>long.length-rows[1].length,{source:long,rows,after:after.source});
    before=await inSecondRow();rows=rowTexts();after=await press('k',{metaKey:true,shiftKey:true});
    check('Shift-Command-K deletes only the displayed row',after.source===withoutRow(rows,1),{source:long,rows,after:after.source});
    before=await setup(long,8);after=await press('n',{ctrlKey:true});
    check('Control-N advances one displayed row',after.head.line===before.head.line&&rowIndex(after)===rowIndex(before)+1&&nearX(before,after),{source:long,before,after});
    back=await press('p',{ctrlKey:true});
    check('Control-P returns to the same displayed row',samePoint(before,back),{source:long,before,after:back});
    window.navigationResult=results;
  };
})(); void 0;
