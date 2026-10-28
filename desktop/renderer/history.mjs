// A browsing pass freezes the submitted history and retains edits in temporary copies.
export class PromptHistory {
  constructor(){this.reset();}
  reset(){this.index=null;this.values=[];this.original=null;}
  step(direction,{text,start,end,history,atBoundary=true,composing=false,modified=false}){
    if(composing||modified||start!==end||!atBoundary)return null;
    if(this.index===null){if(direction>0||!history.length)return null;this.values=[...history];this.original={text,start,end};this.index=this.values.length;}
    if(this.index<this.values.length)this.values[this.index]=text;
    else this.original={text,start,end};
    const next=Math.max(0,Math.min(this.values.length,this.index+direction));
    if(next===this.index)return null;this.index=next;
    if(next===this.values.length){const value=this.original;this.reset();return value;}
    const value=this.values[next];return {text:value,start:value.length,end:value.length};
  }
}
