"""Generate a self-contained, rotatable 3D wireframe HTML page from an .evm file
(an .evm is a MATLAB .mat file with a different extension).

Usage:  python 3d_wireframe.py [input.evm] [output.html]
Requires: numpy, scipy
"""
import json
import sys

import numpy as np
import scipy.io as sio

FLIP_Z = True  # reverse Z so the model isn't upside down


def scalar(v):
    a = np.asarray(v).ravel()
    return float(a[0]) if a.size else np.nan


def load_wireframe(path):
    m = sio.loadmat(path, squeeze_me=True, struct_as_record=False, appendmat=False)
    T = m["ThisStructure"]

    pts = np.array([[scalar(p.x), scalar(p.y), scalar(p.z)] for p in T.Points])
    if FLIP_Z:
        pts[:, 2] *= -1

    segs = []
    for s in T.Segments:
        idx = np.atleast_1d(s.Contains).astype(int) - 1  # MATLAB 1-based -> 0-based
        if len(idx) == 2 and not np.isnan(pts[idx]).any():
            segs.append((int(idx[0]), int(idx[1])))

    # keep only points that are actually used, and re-index the segments
    used = sorted({i for seg in segs for i in seg})
    remap = {old: new for new, old in enumerate(used)}
    P = np.round(pts[used], 2).tolist()
    S = [[remap[a], remap[b]] for a, b in segs]
    return P, S


HTML = r'''<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>3D Wireframe</title>
<style>
:root{--bg:#f6f7f9;--fg:#1c2530;--line:31,78,121;--pt:#d62728;--btn:#fff;--bd:#c9d1da;box-sizing:border-box;padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#14181d;--fg:#e6ebf0;--line:120,180,230;--pt:#ff6b6b;--btn:#1f252c;--bd:#38424d}}
:root[data-theme="dark"]{--bg:#14181d;--fg:#e6ebf0;--line:120,180,230;--pt:#ff6b6b;--btn:#1f252c;--bd:#38424d}
html,body{height:100%;margin:0}
body{background:var(--bg);color:var(--fg);font:14px system-ui,-apple-system,Segoe UI,Roboto,sans-serif;display:flex;flex-direction:column}
header{display:flex;flex-wrap:wrap;gap:8px;align-items:center;padding:10px 12px}
h1{font-size:15px;margin:0 auto 0 0;font-weight:600}
button{background:var(--btn);color:var(--fg);border:1px solid var(--bd);border-radius:8px;padding:6px 12px;font:inherit;cursor:pointer}
canvas{flex:1;width:100%;min-height:0;touch-action:none;cursor:grab}
canvas:active{cursor:grabbing}
.hint{padding:6px 12px 10px;opacity:.65;font-size:12px}
</style></head><body>
<header><h1>3D Wireframe</h1>
<button id="spin">Auto-rotate: off</button><button id="pts">Points: on</button><button id="reset">Reset view</button></header>
<canvas id="c"></canvas>
<div class="hint">Drag to rotate · scroll or pinch to zoom · Z is up (pixel units)</div>
<script>
const D=__DATA__;
const cv=document.getElementById('c'),ctx=cv.getContext('2d');
let yaw,pitch,zoom,auto=false,showPts=true;
const reset=()=>{yaw=-0.9;pitch=0.55;zoom=1};reset();
const P=D.P,n=P.length;
const lo=[0,1,2].map(k=>Math.min(...P.map(p=>p[k]))),hi=[0,1,2].map(k=>Math.max(...P.map(p=>p[k])));
const ctr=lo.map((v,k)=>(v+hi[k])/2);
const R=Math.max(...hi.map((v,k)=>v-lo[k]))/2;
const Q=P.map(p=>[(p[0]-ctr[0])/R,(p[1]-ctr[1])/R,(p[2]-ctr[2])/R]);
function resize(){const r=devicePixelRatio||1;cv.width=cv.clientWidth*r;cv.height=cv.clientHeight*r;draw()}
function proj(p){
  const cy=Math.cos(yaw),sy=Math.sin(yaw),cp=Math.cos(pitch),sp=Math.sin(pitch);
  let x=p[0]*cy-p[1]*sy,y=p[0]*sy+p[1]*cy,z=p[2];
  const y2=y*cp-z*sp,z2=y*sp+z*cp;
  const s=Math.min(cv.width,cv.height)*0.42*zoom;
  return [cv.width/2+x*s,cv.height/2-z2*s,y2];
}
function draw(){
  ctx.clearRect(0,0,cv.width,cv.height);
  const T=Q.map(proj),dpr=devicePixelRatio||1;
  const css=getComputedStyle(document.documentElement),lc=css.getPropertyValue('--line').trim(),pc=css.getPropertyValue('--pt').trim();
  ctx.lineWidth=1.6*dpr;ctx.lineCap='round';
  for(const [a,b] of D.S){
    const d=(T[a][2]+T[b][2])/2;
    ctx.strokeStyle='rgba('+lc+','+(0.95-0.35*d).toFixed(2)+')';
    ctx.beginPath();ctx.moveTo(T[a][0],T[a][1]);ctx.lineTo(T[b][0],T[b][1]);ctx.stroke();
  }
  if(showPts){ctx.fillStyle=pc;for(const t of T){ctx.beginPath();ctx.arc(t[0],t[1],2.6*dpr,0,6.283);ctx.fill()}}
}
let drag=null;const pointers=new Map();let pinch=0;
cv.addEventListener('pointerdown',e=>{cv.setPointerCapture(e.pointerId);pointers.set(e.pointerId,[e.clientX,e.clientY]);drag=[e.clientX,e.clientY]});
cv.addEventListener('pointermove',e=>{
  if(!pointers.has(e.pointerId))return;pointers.set(e.pointerId,[e.clientX,e.clientY]);
  if(pointers.size==2){const [a,b]=[...pointers.values()];const d=Math.hypot(a[0]-b[0],a[1]-b[1]);if(pinch)zoom=Math.min(6,Math.max(.3,zoom*d/pinch));pinch=d;draw();return}
  yaw+=(e.clientX-drag[0])*0.008;pitch=Math.max(-1.5,Math.min(1.5,pitch+(e.clientY-drag[1])*0.008));drag=[e.clientX,e.clientY];draw()});
const up=e=>{pointers.delete(e.pointerId);pinch=0;drag=pointers.size?[...pointers.values()][0]:null};
cv.addEventListener('pointerup',up);cv.addEventListener('pointercancel',up);
cv.addEventListener('wheel',e=>{e.preventDefault();zoom=Math.min(6,Math.max(.3,zoom*Math.exp(-e.deltaY*0.0015)));draw()},{passive:false});
document.getElementById('spin').onclick=e=>{auto=!auto;e.target.textContent='Auto-rotate: '+(auto?'on':'off')};
document.getElementById('pts').onclick=e=>{showPts=!showPts;e.target.textContent='Points: '+(showPts?'on':'off');draw()};
document.getElementById('reset').onclick=()=>{reset();draw()};
(function loop(){if(auto&&!pointers.size){yaw+=0.006;draw()}requestAnimationFrame(loop)})();
addEventListener('resize',resize);
matchMedia('(prefers-color-scheme: dark)').addEventListener('change',draw);
resize();
</script></body></html>'''


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "test1.evm"
    dst = sys.argv[2] if len(sys.argv) > 2 else (src.rsplit(".", 1)[0] + "_wireframe.html")
    P, S = load_wireframe(src)
    html = HTML.replace("__DATA__", json.dumps({"P": P, "S": S}))
    with open(dst, "w", encoding="utf-8") as f:
        f.write(html)
    print(f"wrote {dst}  ({len(P)} points, {len(S)} segments)")


if __name__ == "__main__":
    main()
