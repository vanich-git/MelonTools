#!/usr/bin/env node
// Real account templates, CSS, delegated events and actions in Chromium.
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const { spawnSync } = require("node:child_process");
const { pathToFileURL } = require("node:url");
const ui = path.resolve(__dirname, "../ui");
const chrome = [process.env.CHROME_BIN, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/usr/bin/google-chrome", "/usr/bin/chromium"].find(p => p && fs.existsSync(p));
if (!chrome) throw new Error("Set CHROME_BIN to Chromium");
const out = fs.mkdtempSync(path.join(os.tmpdir(), "melon-account-parity-"));
const source = name => fs.readFileSync(path.join(ui, name), "utf8");
const files = ["mt-state.js", "mt-i18n.js", "mt-utils.js", "mt-api.js", "mt-hf.js", "mt-pages.js", "mt-actions.js", "mt-redesign.js", "app.js", "mt-redesign-actions.js"];
const scripts = files.map(name => `<script>${(name === "app.js" ? source(name).split("(async function boot() {")[0] : source(name)).replace(/<\/script/gi, "<\\/script")}</script>`).join("\n");
let failed = false;
for (const mode of ["card", "settings", "disabled", "narrow"]) {
  const setup = `
const checks = [], calls = []; const check = (yes, msg) => {if (!yes) checks.push(msg)};
window.confirm = () => true;
S.lang='ru'; S.section='accounts'; S.pool={models:[{slug:'gpt-test'},{slug:'gpt-other'}]}; S.settings={};
S.accounts=[{id:'a',displayName:'example@icloud.com',email:'example@icloud.com',planType:'plus',hourlyRemaining:87,weeklyRemaining:64,hourlyWindowPresent:true,weeklyWindowPresent:true,hourlyResetAt:Date.now()/1000+17100,weeklyResetAt:Date.now()/1000+484000,quotaUpdatedAt:Date.now()/1000-12,quotaSource:'usage',subscriptionActiveUntil:'2026-11-28T00:00:00Z',hourlyReservePercent:2,weeklyReservePercent:2,resetCreditsAvailable:2,modelAvailability:[{model:'gpt-test',available:true}]}];
S.routing={orderedIds:['a']}; S.history=[{key:'a',hourlyLeft:43,weeklyLeft:67},{key:'a',hourlyLeft:90,weeklyLeft:64}];
const mode=${JSON.stringify(mode)}; if(mode==='disabled') {S.accounts[0].poolEnabled=false;S.accounts[0].blocked=true;S.accounts[0].blockInfo={code:'manual_disabled'};}
S.accountSettings=mode==='settings'||mode==='narrow'?'a':null;
render=function(){document.getElementById('main').innerHTML=S.poolModal?poolModal():S.accountSettings?accountSettingsModal():accountCard(S.accounts[0]);};
inv=async(command,args)=>{calls.push([command,args]);if(command==='save_reserves') return S.accounts;if(command==='set_account_role'||command==='routing_state') return {accounts:S.accounts,orderedIds:S.accounts.map(a=>a.id)};if(command==='quota_refresh')return {accounts:S.accounts};if(command==='delete_account'){S.accounts=S.accounts.filter(a=>a.id!==args.id);return S.accounts;}return {};};
A.historyLoad=async()=>{}; render();
(async()=>{try {
 const root=document.querySelector('.modal-card,.account-card');
 check(root.scrollWidth<=root.clientWidth+1,'root horizontal overflow');
 if(S.accountSettings){
  check(document.querySelectorAll('input[role=switch]').length===5,'all five switches');
  const hourly=document.getElementById('account-res-h-enabled');hourly.click();
  check(document.getElementById('account-res-h').closest('.account-limit-value').hidden,'hourly switch hides threshold');
  document.getElementById('account-res-w').value='7';document.getElementById('account-res-w').dispatchEvent(new Event('input',{bubbles:true}));
  document.getElementById('account-pool-enabled').click();
  document.querySelector('[data-action=accountSettingsModels]').click(); await Promise.resolve();
  check(S.poolModal&&S.poolModal.mode==='account','opens real account picker');
  A.poolClose();
  check(S.accountSettings==='a','picker returns to settings');
  check(!document.getElementById('account-pool-enabled').checked,'membership draft retained');
  check(document.getElementById('account-res-w').value==='7','threshold draft retained');
  document.getElementById('account-res-w').value='101';
  await A.accountSettingsSave('a'); check(calls.length===0,'invalid threshold never sent');
  document.getElementById('account-res-w').value='100';
  await A.accountSettingsSave('a');
  const save=calls.find(c=>c[0]==='save_reserves');check(save&&save[1].hourly===null&&save[1].weekly===100&&save[1].poolEnabled===false,'atomic membership and enabled limits; threshold 100 matches macOS');
  check(S.accountSettings===null,'save closes settings');
  A.accountSettingsOpen('a');
 }else{
  check(document.querySelectorAll('.account-actions button').length===5,'five macOS actions');
  check(document.querySelector('.account-history svg'),'history visible');
  check(!document.querySelector('[data-action=movePriority]'),'ordering arrows stay in queue, not account header');
  if(mode==='disabled'){check(getComputedStyle(root).filter.includes('grayscale'),'disabled card gray');check(!document.querySelector('[data-action=launchAccountInCodex]').disabled,'manual exclusion retains actions');}
  const box=document.querySelector('.account-select');box.click();check(S.selectedAccounts.includes('a'),'real change event selects account');
  check(document.querySelector('.account-select').checked,'selected state survives rerender');
  await A.accountsRefreshSelected();check(calls.some(c=>c[0]==='quota_refresh'&&c[1].id==='a'),'selected refresh IPC');
  check(calls.some(c=>c[0]==='routing_state'),'selected refresh updates effective queue');
  const queue=priorityList();check(mode==='disabled'?!queue.includes('data-action="movePriority"'):queue.includes('data-action="movePriority"'),'only enabled queue has ordering controls');
 }
 const panel=document.querySelector('.modal-card,.account-card');check(panel.scrollWidth<=panel.clientWidth+1,'final overflow');
 const bounds=panel.getBoundingClientRect();check(bounds.left>=0&&bounds.right<=window.innerWidth+1,'panel stays within viewport');
 }catch(error){checks.push(error.stack||String(error));}
 const pre=document.createElement('pre');pre.id='result';pre.textContent=JSON.stringify(checks);pre.hidden=true;document.body.append(pre);
})();`;
  const html = `<!doctype html><html lang="ru"><meta charset="utf-8"><style>${source("mt.css")}body{overflow:auto}#main{width:${mode === "narrow" ? 345 : 460}px;margin:16px auto}.modal{position:static;padding:0}.modal-card{max-height:none;width:100%}.account-settings-card{background:var(--bg)}</style><div id="main"></div><div id="toast"></div>${scripts}<script>${setup}</script></html>`;
  const fixture = path.join(out, mode + ".html"); fs.writeFileSync(fixture, html);
  const run = spawnSync(chrome, ["--headless=new", "--no-sandbox", "--disable-gpu", "--allow-file-access-from-files", "--no-pdf-header-footer", "--user-data-dir=" + path.join(out, "profile-" + mode), "--window-size=560,1000", "--virtual-time-budget=2500", "--screenshot=" + path.join(out, mode + ".png"), "--dump-dom", pathToFileURL(fixture).href], {encoding:"utf8",maxBuffer:10*1024*1024});
  const match = run.stdout?.match(/<pre id="result"[^>]*>([\s\S]*?)<\/pre>/);
  const errors = match ? JSON.parse(match[1].replace(/&quot;/g,'"').replace(/&amp;/g,'&').replace(/&lt;/g,'<').replace(/&gt;/g,'>')) : ["browser did not finish: " + run.stderr];
  console.log(mode + ": " + (errors.length ? errors.join("; ") : "PASS (rendering, controls, IPC)"));
  failed ||= run.status !== 0 || errors.length > 0;
}
console.log("Browser fixtures: " + out);
if(failed) process.exitCode=1;
