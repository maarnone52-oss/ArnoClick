import Foundation

/// Piccolo script iniettato nella pagina all'avvio: dove il motore web non ha il microfono (prima di macOS 12)
/// crea al suo posto un "getUserMedia" che si fa dare l'audio dall'app (LiveCapture). Dove il microfono
/// del motore web c'è già, non fa nulla.
enum LiveShim {
    static let source = #"""
(function(){
try{
var wk=window.webkit,h=wk&&wk.messageHandlers&&wk.messageHandlers.inputs;
if(!h)return;
var md=navigator.mediaDevices;
if(md&&typeof md.getUserMedia==='function')return;
var AC=window.AudioContext||window.webkitAudioContext;
if(!AC)return;
var sinks=[],pending=null,active=false,rate=44100;
function mkErr(k){var e=new Error('capture '+k);e.name=k==='denied'?'NotAllowedError':k==='nodev'?'NotFoundError':'NotReadableError';return e;}
function mkStream(){
  var tr={kind:'audio',label:'ARNOCLICK',readyState:'live',enabled:true,
    stop:function(){if(active){active=false;sinks.length=0;try{h.postMessage({cap:'stop'});}catch(e){}}},
    addEventListener:function(){},removeEventListener:function(){}};
  return {__arnoNative:true,active:true,getTracks:function(){return [tr];},getAudioTracks:function(){return [tr];}};
}
window.__arnoCapStart=function(ok,sr,err){
  var p=pending;pending=null;if(!p)return;clearTimeout(p.t);
  if(ok){rate=sr;active=true;p.res(mkStream());}else p.rej(mkErr(err));
};
function feed(s,L,R,fr){
  try{
    var c=s.ctx,b=c.createBuffer(2,fr,rate);b.getChannelData(0).set(L);b.getChannelData(1).set(R);
    var src=c.createBufferSource();src.buffer=b;src.connect(s.node);
    var t=c.currentTime;if(s.next<t+0.02)s.next=t+0.08;if(s.next>t+0.6)return;
    src.start(s.next);s.next+=b.duration;
  }catch(e){}
}
window.__arnoCap=function(b64){
  if(!active||!sinks.length)return;
  var bin=atob(b64),n=bin.length,u=new Uint8Array(n);
  for(var i=0;i<n;i++)u[i]=bin.charCodeAt(i);
  var s16=new Int16Array(u.buffer),fr=s16.length>>1,L=new Float32Array(fr),R=new Float32Array(fr);
  for(var j=0;j<fr;j++){L[j]=s16[2*j]/32768;R[j]=s16[2*j+1]/32768;}
  for(var k=0;k<sinks.length;k++)feed(sinks[k],L,R,fr);
};
var proto=AC.prototype,orig=proto.createMediaStreamSource;
proto.createMediaStreamSource=function(st){
  if(st&&st.__arnoNative){var g=this.createGain();sinks.push({ctx:this,node:g,next:0});return g;}
  return orig?orig.apply(this,arguments):undefined;
};
var gum=function(){return new Promise(function(res,rej){
  if(pending){rej(mkErr('busy'));return;}
  var p={res:res,rej:rej,t:setTimeout(function(){if(pending===p){pending=null;rej(mkErr('timeout'));}},60000)};
  pending=p;
  try{h.postMessage({cap:'start'});}catch(e){pending=null;clearTimeout(p.t);rej(mkErr('error'));}
});};
if(md){try{md.getUserMedia=gum;}catch(e){}}
else{Object.defineProperty(navigator,'mediaDevices',{configurable:true,value:{getUserMedia:gum,enumerateDevices:function(){return Promise.resolve([]);},addEventListener:function(){},removeEventListener:function(){}}});}
}catch(e){}
})();
"""#
}
