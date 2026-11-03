#!/usr/bin/env node
// Real HTML/CSS/JS in Chromium: visible panel, click IPC and 15-second timer.
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const { spawnSync } = require("node:child_process");
const { pathToFileURL } = require("node:url");
const ui = path.resolve(__dirname, "../ui");
const chrome = [process.env.CHROME_BIN,
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/usr/bin/google-chrome", "/usr/bin/chromium"].find(p => p && fs.existsSync(p));
if (!chrome) throw new Error("Set CHROME_BIN to a Chromium executable");
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "melon-island-check-"));
const html = fs.readFileSync(path.join(ui, "island.html"), "utf8");
const css = fs.readFileSync(path.join(ui, "island.css"), "utf8");
const js = fs.readFileSync(path.join(ui, "island.js"), "utf8");
let failed = false;
for (const mode of ["compact", "expanded", "reenter"]) {
  const setup = `window.__melonMode=${JSON.stringify(mode === "compact" ? "compact" : "expanded")};
    window.calls=[]; window.melon={available:true, listen:()=>Promise.resolve(), invoke:(cmd)=>{
      calls.push(cmd); return Promise.resolve(cmd==='island_snapshot'?{
        lang:'ru',islandAutoCollapseSeconds:15,gateway:{running:true,port:18317},codex:{accounts:5,hourly:500,weekly:900,max:500},
        antigravity:{accounts:2},scheduler:{due:0},providers:4}:{}); }};`;
  const checks = `(() => {
    const errors=[]; const check=(ok,msg)=>{if(!ok)errors.push(msg)};
    const count=c=>calls.filter(x=>x===c).length;
    const dispatch=t=>document.getElementById('island').dispatchEvent(new MouseEvent(t,{bubbles:true}));
    const finish=()=>{const pre=document.createElement('pre');pre.id='result';pre.textContent=JSON.stringify(errors);document.documentElement.append(pre)};
    setTimeout(()=>{
      const panel=document.querySelector('#island > .expanded');
      const compact=document.querySelector('#island > .compact');
      check(getComputedStyle(document.body).display!=='none','BODY IS HIDDEN by expanded CSS');
      if(${JSON.stringify(mode)}==='compact'){
        check(getComputedStyle(compact).display!=='none','compact hidden');
        check(getComputedStyle(panel).display==='none','panel visible in compact mode');
        check(document.getElementById('compact-hourly').textContent==='500%','wrong hourly total');
        check(document.getElementById('compact-weekly').textContent==='900%','wrong weekly total');
        check(document.getElementById('compact-accounts').textContent==='5','wrong account count');
        const order=['compact-hourly','compact-weekly','compact-accounts','compact-dot'].map(id=>document.getElementById(id));
        check(order.every((node,i)=>i===0||order[i-1].compareDocumentPosition(node)&Node.DOCUMENT_POSITION_FOLLOWING),'compact metrics out of order');
        if(innerWidth>0)order.forEach(node=>{const r=node.getBoundingClientRect();check(r.width>0&&r.right<=innerWidth,node.id+' clipped')});
        dispatch('click');check(count('island_expand')===1,'click must request panel exactly once');
        check(getComputedStyle(document.body).display!=='none','compact disappears on click');finish();return;
      }
      check(getComputedStyle(compact).display==='none','compact visible in panel');
      check(getComputedStyle(panel).display!=='none','panel content hidden');
      check(getComputedStyle(panel).display==='flex','panel is not display:flex');
      check(getComputedStyle(panel).opacity==='1','panel remains transparent');
      check(panel.getClientRects().length>0,'panel has no CSS box');
      dispatch('mouseleave');
      if(${JSON.stringify(mode)}==='reenter')setTimeout(()=>dispatch('mouseenter'),200);
      setTimeout(()=>{check(count('island_collapse')===0,'collapsed before the close button');
        document.getElementById('close-panel').click();},700);
      setTimeout(()=>{check(count('island_collapse')===1,'close button must collapse the panel');
        check(count('island_resize')===0,'fixed windows must not resize');finish()},1100);
    },400);
  })();`;
  const fixture = html.replace('<link rel="stylesheet" href="island.css" />', '<style>'+css+' *{animation:none!important;transition:none!important}</style>')
    .replace('<script src="mt-bridge.js"></script>', '<script>'+setup+'</script>')
    .replace('<script src="island.js"></script>', '<script>'+js+'</script><script>'+checks+'</script>');
  const file=path.join(dir,mode+'.html');fs.writeFileSync(file,fixture);
  const run=spawnSync(chrome,['--headless=new','--disable-gpu','--hide-scrollbars','--no-first-run',
    '--disable-background-networking','--window-size='+(mode==='compact'?'185,30':'420,242'),
    '--virtual-time-budget=6000','--dump-dom','--user-data-dir='+path.join(dir,mode+'-profile'),pathToFileURL(file).href],
    {encoding:'utf8',timeout:45000,maxBuffer:4*1024*1024});
  const result=run.stdout?.match(/<pre id="result">([\s\S]*?)<\/pre>/);
  const errors=result?JSON.parse(result[1].replace(/&quot;/g,'"').replace(/&amp;/g,'&').replace(/&lt;/g,'<').replace(/&gt;/g,'>')):['browser test did not finish: '+run.stderr];
  console.log(mode+': '+(errors.length?errors.join('; '):'PASS (computed styles, rendered bounds, IPC)'));
  failed ||= run.status!==0||errors.length>0;
}
console.log('Browser fixtures: '+dir);
if(failed)process.exit(1);
