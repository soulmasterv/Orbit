class Capture extends AudioWorkletProcessor {
  constructor(){super();this.pending=[];this.position=0;}
  process(inputs,outputs){
    const input=inputs[0]?.[0];if(!input)return true;
    // Streaming linear resampler retains fractional position across render quanta.
    this.pending.push(...input);const step=sampleRate/16000;
    const samples=[];
    while(this.position+1<this.pending.length){const n=Math.floor(this.position),f=this.position-n;const v=this.pending[n]*(1-f)+this.pending[n+1]*f;samples.push(Math.max(-1,Math.min(1,v)));this.position+=step;}
    const consumed=Math.min(Math.floor(this.position),this.pending.length);this.pending.splice(0,consumed);this.position-=consumed;
    if(samples.length){const bytes=new ArrayBuffer(samples.length*2),view=new DataView(bytes);samples.forEach((s,i)=>view.setInt16(i*2,s<0?s*32768:s*32767,true));this.port.postMessage(bytes,[bytes]);}
    return true;
  }
}
registerProcessor('capture',Capture);
