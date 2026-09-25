(() => {
  const pause=()=>new Promise(resolve=>{window.newlineContinue=resolve;});
  const key=(key,shiftKey=false)=>document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key,shiftKey,bubbles:true,cancelable:true}));
  const rows=()=>Array.from(document.querySelectorAll('.cm-content > .cm-line')).map(e=>({text:e.textContent,cls:e.className,height:e.getBoundingClientRect().height,top:e.getBoundingClientRect().top}));
  function glyph(word) {
    const walker=document.createTreeWalker(document.querySelector('.cm-content'),NodeFilter.SHOW_TEXT);let n;
    while(n=walker.nextNode()) {const at=n.textContent.indexOf(word);if(at<0)continue;const r=document.createRange();r.setStart(n,at);r.setEnd(n,at+1);const box=r.getBoundingClientRect();return {x:box.x,y:box.y,height:box.height};}return null;
  }
  const snapshot=()=>({source:window.margin.getText(),rows:rows(),alpha:glyph('Alpha'),beta:glyph('Beta'),html:document.querySelector('.cm-content').innerHTML});
  window.newlineRun=async(width,zoom)=>{
    window.newlineResult=null;const results=[];
    const check=(name,passed,evidence)=>results.push({name,passed:!!passed,width,zoom,...evidence});
    async function setup(source,edit=false){window.margin.loadDocument({text:source,name:'newlines.md',dirty:false});if(edit){window.margin.command('selectAll');key('ArrowRight');}await pause();}
    for (const [name,source] of [['paragraph','Alpha\nBeta'],['quote','> Alpha\n> Beta'],['list continuation','- Alpha\n  Beta'],['hard break spaces','Alpha  \nBeta'],['hard break slash','Alpha\\\nBeta'],['table hard break','| Text |\n| --- |\n| Alpha<br>Beta |']]) {
      await setup(source);let after=snapshot();check(name+' shows a line break in preview',after.beta?.y>after.alpha?.y+10,{source,after});
      check(name+' preserves source on preview',after.source===source,{source,after});
    }
    for(const [name,source,count] of [['empty document','',1],['only newlines','\n\n',3],['leading blank lines','\n\nAlpha',2],['trailing blank line','Alpha\n',1],['trailing blank lines','Alpha\n\n\n',3],['extra paragraph blanks','Alpha\n\n\n\nBeta',3],['spaces-only separators','Alpha\n  \n\t\n\nBeta',3]]) {
      await setup(source);let after=snapshot();const visible=after.rows.filter(r=>!r.text.trim()&&r.height>10).length;
      check(name+' preserves visible blank rows',visible===count,{source,expectedVisibleBlankRows:count,visible,after});
      window.margin.command('selectAll');key('ArrowRight');key('Escape');await pause();after=snapshot();
      check(name+' survives editing-to-preview round trip',after.source===source&&after.rows.filter(r=>!r.text.trim()&&r.height>10).length===count,{source,after});
    }
    for(const [name,base,extra] of [['loose list','- Alpha\n\n- Beta','- Alpha\n\n\n- Beta'],['quote paragraphs','> Alpha\n>\n> Beta','> Alpha\n>\n>\n> Beta'],['nested list','- Outer\n  - Alpha\n\n  - Beta','- Outer\n  - Alpha\n\n\n  - Beta'],['nested quote','> > Alpha\n> >\n> > Beta','> > Alpha\n> >\n> >\n> > Beta'],['code inside quote','> ```text\n> Alpha\n>\n> Beta\n> ```','> ```text\n> Alpha\n>\n>\n> Beta\n> ```'],['code fence','```text\nAlpha\n\nBeta\n```','```text\nAlpha\n\n\nBeta\n```'],['indented code','    Alpha\n\n    Beta','    Alpha\n\n\n    Beta']]) {
      await setup(base);const before=snapshot();await setup(extra);const after=snapshot();
      check(name+' preserves additional internal blank row',after.beta?.y-after.alpha?.y>before.beta?.y-before.alpha?.y+10,{source:extra,before,after});
    }
    for(const [name,base,extra] of [['leading quote rows','> Alpha','>\n>\n> Alpha'],['trailing quote rows','> Alpha','> Alpha\n>\n>']]) {
      await setup(base);const before=snapshot();const oldHeight=before.rows.reduce((sum,row)=>sum+row.height,0);
      await setup(extra);const after=snapshot();const newHeight=after.rows.reduce((sum,row)=>sum+row.height,0);
      check(name+' remain visible',newHeight-oldHeight>35&&after.source===extra,{source:extra,before,after,oldHeight,newHeight});
    }
    for(const source of ['Alpha','# Alpha','- Alpha','1. Alpha','> Alpha','```text\nAlpha\n```','| Alpha |\n| --- |\n| Beta |','Alpha\r\n']) {
      await setup(source,true);const states=[];
      for(let i=0;i<3;i++){key('Enter');await pause();states.push(snapshot());}
      check('Enter advances new rows and exits empty markup in place: '+source.split('\n')[0],states.every((s,i)=>{
        const r=s.rows.at(-1),previous=i?states[i-1].rows.at(-1):null;
        const addedRow=i && s.source.split('\n').length>states[i-1].source.split('\n').length;
        const exitedMarkup=previous && /^(?:[-*+] |\d+[.)] |> ?)$/.test(previous.text) && !r.text;
        return r?.height>10&&(!previous||(addedRow?r.top>previous.top+10:exitedMarkup&&Math.abs(r.top-previous.top)<1.5));
      }),{source,states});
      const final=window.margin.getText();key('Escape');await pause();const after=snapshot();
      check('Typed line breaks survive preview: '+source.split('\n')[0],after.source===final&&after.rows.filter(r=>!r.text.trim()&&r.height>10).length>=2,{source,after});
      window.margin.command('undo');window.margin.command('redo');await pause();check('Undo/redo retains line breaks: '+source.split('\n')[0],window.margin.getText()===final,{source,final,actual:window.margin.getText()});
    }
    window.newlineResult=results;
  };
})();
