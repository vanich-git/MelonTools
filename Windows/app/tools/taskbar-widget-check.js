#!/usr/bin/env node
// Settings persistence contract + actual widget DOM/CSS/events in Chromium.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const vm = require('node:vm');
const {spawnSync} = require('node:child_process');
const {pathToFileURL} = require('node:url');
const ui = path.resolve(__dirname, '../ui');
const source = name => fs.readFileSync(path.join(ui,name),'utf8');
async function settingsCheck() {
  const calls=[];
  const context={window:{},render:()=>{},S:{busy:{},settings:{islandVisible:false,taskbarWidgetVisible:false,port:18317}},run:(_key,fn)=>fn(),inv:async(command,args)=>{calls.push([command,args]);return args.settings;}};
  vm.createContext(context);vm.runInContext(source('mt-actions.js'),context);
  await vm.runInContext('A.taskbarWidgetToggle(true)',context);
  assert.equal(context.S.settings.taskbarWidgetVisible,true);
  assert.equal(context.S.settings.islandVisible,false,'island and taskbar toggle independent');
  assert.equal(calls[0][0],'settings_set');assert.equal(calls[0][1].settings.port,18317);
  await vm.runInContext('A.taskbarWidgetToggle(false)',context);
  assert.equal(context.S.settings.taskbarWidgetVisible,false);
  let finishSave;context.inv=(_command,args)=>new Promise(resolve=>{finishSave=()=>resolve(args.settings)});
  const saving=vm.runInContext('A.taskbarWidgetToggle(true)',context);
  assert.equal(context.S.settings.taskbarWidgetVisible,true,'sibling saves see the pending widget value');
  context.inv=async(command,args)=>{assert.equal(args.settings.taskbarWidgetVisible,true,'island must not turn widget back off');return args.settings;};
  context.render=()=>{};vm.runInContext('A.islandToggle(true)',context);
  finishSave();await saving;
  context.inv=async(_command,args)=>args.settings;
  await vm.runInContext('A.taskbarWidgetToggle(false)',context);
  context.inv=async()=>{throw Error('save failed')};
  await assert.rejects(vm.runInContext('A.taskbarWidgetToggle(true)',context),/save failed/);
  assert.equal(context.S.settings.taskbarWidgetVisible,false,'failed save leaves persisted state untouched');
  const app=source('app.js');
  vm.runInContext(app.slice(app.indexOf('function actionArgs('),app.indexOf('function dispatchAction(')),context);
  assert.equal(vm.runInContext("actionArgs('taskbarWidgetToggle',{checked:true})[0]",context),true);
  context.DICT={ru:{},en:{}};context.t=key=>key;context.S.busy={};context.pageHead=()=>'';
  vm.runInContext(source('mt-utils.js'),context);vm.runInContext(source('mt-redesign.js'),context);
  const settings=vm.runInContext('settingsPage()',context);
  assert(settings.indexOf('data-action="taskbarWidgetToggle"')>settings.indexOf('data-action="islandToggle"'));
  assert(settings.indexOf('data-action="taskbarWidgetToggle"')<settings.indexOf('data-action="dashboardCardToggle"'));
  console.log('settings: PASS (toggle IPC, independent state, failure, placement)');
}
async function main(){
 await settingsCheck();
 const chrome=[process.env.CHROME_BIN,'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome','/usr/bin/google-chrome','/usr/bin/chromium'].find(p=>p&&fs.existsSync(p));
 if(!chrome)throw Error('Set CHROME_BIN to Chromium');
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'melon-taskbar-check-'));
 let failed=false;
 for(const mode of ['dark','light','compact','vertical','narrow','error']){
  const setup=`window.calls=[];window.handlers={};window.failed=${mode==='error'};window.melon={available:true,listen:(event,fn)=>{handlers[event]=fn;return Promise.resolve()},invoke:async(command)=>{calls.push(command);if(command==='island_open_main')return; if(window.failed)throw Error('offline');return {lang:${mode==='light'?"'en'":"'ru'"},gateway:{running:true},codex:{accounts:3,hourly:245,weekly:187,max:300}};}};`;
  const checks=`(async()=>{const errors=[],check=(yes,msg)=>{if(!yes)errors.push(msg)};await Promise.resolve();await Promise.resolve();
  const button=document.getElementById('widget');
  check(document.documentElement.scrollWidth<=innerWidth,'no viewport overflow');
  check(button.scrollWidth<=button.clientWidth,'no button overflow');
  ${mode==='error'?`check(document.getElementById('hour-value').textContent==='—','failed snapshot never leaves stale quota');check(document.getElementById('api-dot').className==='failed','error state');`:`check(document.getElementById('hour-value').textContent==='245%','pooled quota not clamped to 100');check(document.getElementById('week-value').textContent==='187%','weekly quota');check(button.title.includes('3'),'account count tooltip');check(document.getElementById('api-dot').className==='running','real API status');check(document.getElementById('api-dot').getBoundingClientRect().width>0,'API indicator visible at every size');`}
  button.click();await Promise.resolve();check(calls.includes('island_open_main'),'click opens main via IPC');
  handlers['taskbar-widget-visibility']({payload:false});const count=calls.filter(c=>c==='island_snapshot').length;
  setTimeout(()=>{check(calls.filter(c=>c==='island_snapshot').length===count,'hidden window stops polling');handlers['taskbar-widget-visibility']({payload:true});setTimeout(()=>{check(calls.filter(c=>c==='island_snapshot').length===count+1,'show resumes snapshot');const pre=document.createElement('pre');pre.id='result';pre.hidden=true;pre.textContent=JSON.stringify(errors);document.body.append(pre)},10)},3100);
  })();`;
  const width=mode==='vertical'?76:mode==='narrow'?32:174,height=mode==='compact'?28:40;
  // Exercise the light-palette branch independently of the host macOS theme.
  const css=mode==='light'?source('taskbar-widget.css').replace('@media (prefers-color-scheme: light)','@media all'):source('taskbar-widget.css');
  const html='<!doctype html><html lang="ru"><meta charset="utf-8"><style>'+css+`html,body{width:${width}px;height:${height}px}body{margin:20px}html{background:#777}`+'</style><script>'+setup+'</script>'+source('taskbar-widget.html').split('<body>')[1].split('<script src="mt-bridge.js">')[0]+`<script>${source('taskbar-widget.js')}</script><script>${checks}</script></body></html>`;
  const file=path.join(dir,mode+'.html');fs.writeFileSync(file,html);
  // Copy the bundled app logo into the isolated fixture directory, not user data.
  if(!fs.existsSync(path.join(dir,'logo.png')))fs.copyFileSync(path.join(ui,'logo.png'),path.join(dir,'logo.png'));
  const result=spawnSync(chrome,['--headless=new','--no-sandbox','--disable-gpu','--force-prefers-reduced-motion',...(mode==='light'?[]:['--force-dark-mode']),'--user-data-dir='+path.join(dir,'profile-'+mode),'--window-size=560,180','--virtual-time-budget=3500','--screenshot='+path.join(dir,mode+'.png'),'--dump-dom',pathToFileURL(file).href],{encoding:'utf8',maxBuffer:5*1024*1024});
  const match=result.stdout?.match(/<pre id="result"[^>]*>([\s\S]*?)<\/pre>/);
  const errors=match?JSON.parse(match[1].replace(/&quot;/g,'"').replace(/&amp;/g,'&').replace(/&lt;/g,'<').replace(/&gt;/g,'>')):['browser test did not finish: '+result.stderr];
  console.log(mode+': '+(errors.length?errors.join('; '):'PASS (DOM, rendering, IPC, visibility polling)'));failed ||= result.status!==0||errors.length>0;
 }
 console.log('Browser fixtures: '+dir);if(failed)process.exitCode=1;
}
main().catch(error=>{console.error(error);process.exitCode=1});
