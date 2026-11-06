#!/usr/bin/env node
// Regression guards for remote catalog state, compatible selection and Markdown.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const ui = path.resolve(__dirname, "../ui");
const sandbox = {
  window: {}, URL, console, setTimeout, clearTimeout,
  S: { lang: "ru", localAi: { catalogResults: [], catalogGeneration: 0 } },
  t: key => key, A: {}, hfTokenArg: () => null, errorText: error => String(error),
  document: { getElementById: () => null, querySelector: () => null },
};
vm.createContext(sandbox);
for (const file of ["mt-utils.js", "mt-hf.js"]) vm.runInContext(fs.readFileSync(path.join(ui, file), "utf8"), sandbox);
const run = expression => vm.runInContext(expression, sandbox);
let html = run('renderMarkdown("| Quant | Notes |\\n| --- | --- |\\n| Q4 | **balanced** |\\n\\n`**literal**`\\n\\n[site](https://example.com/?q=**x**)\\n[blocked](data:text/html,test)\\n<script>alert(1)</script>")');
assert.match(html, /<table/);
assert.match(html, /<strong>balanced<\/strong>/);
assert.match(html, /<code class="md-code">\*\*literal\*\*<\/code>/);
assert.match(html, /href="https:\/\/example.com/);
assert.doesNotMatch(html, /href="data:|<script>/);
assert.match(html, /&lt;script&gt;/);
assert.match(run('renderMarkdown("| A | B |\\n| --- | --- |\\n| <img src=x> | <svg> |")'), /&lt;img/);
sandbox.repo = { ggufFiles: [
  { name: "model-Q8_0.gguf", quantization: "Q8_0", size: 12, estimation: { recommendation: "May not fit" } },
  { name: "model-Q4_K_M.gguf", quantization: "Q4_K_M", size: 5, estimation: { recommendation: "Recommended" } },
  { name: "model-Q4_K_M-00001-of-00002.gguf", quantization: "Q4_K_M", size: 3, estimation: { recommendation: "Recommended" } },
] };
assert.equal(run('hfRecommendedFile(repo).name'), "model-Q4_K_M.gguf");
assert.match(run('hfDownloadIssue(repo.ggufFiles[2])'), /GGUF/);
run('S.localAi.hfCompatibleOnly = true');
assert.equal(run('hfVariants(repo).length'), 1);
assert.equal(run('hfFits({size:0,estimation:{recommendation:"Recommended"}})'), false);
assert.equal(run('hfRecommendedFile({ggufFiles:[{name:"mmproj.gguf",size:1,estimation:{recommendation:"Recommended"}}]})'), undefined);
assert.equal(run('hfRepositoryID("https://huggingface.co/org/repo/tree/main")'), "org/repo");
assert.equal(run('hfRepositoryID("https://other.example/org/repo")'), null);

// Evaluate only catalog actions; the full action table owns unrelated app state.
const source = fs.readFileSync(path.join(ui, "mt-actions.js"), "utf8");
const actions = source.slice(source.indexOf("  localAiHfSearchInput(val) {"), source.indexOf("  async localAiDownloadQuant("));
vm.runInContext(`Object.assign(A, {${actions}})`, sandbox);
const deferred = () => { let resolve, reject; const promise = new Promise((a,b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
async function main() {
  const first = deferred(), second = deferred();
  let calls = 0;
  sandbox.window.api = { localAi: { hfSearch: () => (++calls === 1 ? first.promise : second.promise) } };
  run('S.localAi.catalogQuery = "old"');
  const old = run('A.localAiHfSearch()');
  run('S.localAi.catalogQuery = "new"');
  const current = run('A.localAiHfSearch()');
  second.resolve([{ id: "org/new" }]); await current;
  first.resolve([{ id: "org/old" }]); await old;
  assert.equal(run('S.localAi.catalogResults[0].id'), "org/new");
  const detailsA = deferred(), detailsB = deferred();
  sandbox.window.api.localAi.hfModelDetails = id => id === "org/A" ? detailsA.promise : detailsB.promise;
  const a = run('A.localAiSelectRepo("org/A")');
  const b = run('A.localAiSelectRepo("org/B")');
  detailsB.resolve({ id: "org/B" }); await b;
  detailsA.resolve({ id: "org/A" }); await a;
  assert.equal(run('S.localAi.repoDetails.id'), "org/B");
  // Pagination advances by API rows, not by deduplicated visible count.
  const offsets = [];
  sandbox.window.api.localAi.hfSearch = (_query, _limit, _token, _sort, offset) => {
    offsets.push(offset);
    return Promise.resolve(Array.from({length:30}, (_, i) => ({id:`org/${offset === 30 && i === 0 ? 0 : offset + i}`})));
  };
  run('S.localAi.catalogQuery = "paging"');
  await run('A.localAiHfSearch()');
  await run('A.localAiHfSearch(true)');
  await run('A.localAiHfSearch(true)');
  assert.deepEqual(offsets, [0,30,60]);
  run('S.localAi.catalogQuery = "changed-before-debounce"');
  await run('A.localAiHfSearch(true)');
  assert.equal(offsets.length, 3, "must not append another query to visible results");
  sandbox.window.api.localAi.hfSearch = () => Promise.reject(new Error("network unavailable"));
  await run('A.localAiHfSearch()');
  assert.match(run('S.localAi.catalogError'), /network unavailable/);
  assert.equal(run('S.localAi.catalogLoading'), false);
  console.log("hf-catalog-check ok: Markdown safety/tables/code, variants, search/detail races, inline errors");
}
main().catch(error => { console.error(error); process.exitCode = 1; });
