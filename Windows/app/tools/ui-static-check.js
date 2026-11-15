#!/usr/bin/env node
// Static UI guard (W3/W9). Run from the repository root:
//   node Windows/app/tools/ui-static-check.js
// It fails when an inline handler or a direct Tauri global reappears, when a
// renderer command is missing from the bridge whitelist, or when a hostile
// account id escapes a data attribute.

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const ui = path.resolve(__dirname, "../ui");
const files = fs.readdirSync(ui).filter((name) => name.endsWith(".js"));
const errors = [];

for (const name of files) {
  const source = fs.readFileSync(path.join(ui, name), "utf8");
  if (/\bon(?:click|change|input|submit)\s*=/.test(source)) {
    errors.push(`${name}: inline event handler attribute`);
  }
  if (/javascript\s*:/i.test(source)) {
    errors.push(`${name}: javascript: URL`);
  }
  if (/\beval\s*\(|new\s+Function\s*\(/.test(source)) {
    errors.push(`${name}: dynamic code evaluation`);
  }
  if (name !== "mt-bridge.js" && /__TAURI_(?:INTERNALS__|__)/.test(source)) {
    errors.push(`${name}: direct Tauri global outside mt-bridge.js`);
  }
}

const html = fs.readFileSync(path.join(ui, "index.html"), "utf8");
if (/\bon(?:click|change|input|submit)\s*=/.test(html)) {
  errors.push("index.html: inline event handler attribute");
}

const bridge = fs.readFileSync(path.join(ui, "mt-bridge.js"), "utf8");
const allowed = new Set(
  [...bridge.matchAll(/^\s*"([a-z0-9:|_-]+)",?\s*$/gim)].map((match) => match[1]),
);
for (const name of files) {
  const source = fs.readFileSync(path.join(ui, name), "utf8");
  for (const match of source.matchAll(/\binv(?:Timed)?\(\s*"([^"]+)"/g)) {
    if (!allowed.has(match[1])) {
      errors.push(`${name}: inv("${match[1]}") is not in the bridge whitelist`);
    }
  }
}

const sandbox = { window: {}, S: { lang: "ru" }, t: (key) => key };
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(path.join(ui, "mt-utils.js"), "utf8"), sandbox);
const hostile = "');alert(1);//";
const escaped = vm.runInContext(`esc(${JSON.stringify(hostile)})`, sandbox);
if (escaped.includes("'") || escaped.includes('"')) {
  errors.push("esc() leaves a quote in a data attribute");
}
const button = `<button data-action="deleteAccount" data-id="${escaped}">`;
if (!button.includes("&#39;") || button.includes("');alert")) {
  errors.push("hostile id survives attribute escaping");
}

// W2/W4/W7: the browser-preview mock must emit the same keys the Rust DTOs
// serialize. The preview used `filename`/`sizeBytes`/`progressPercentage`
// while the backend sent `name`/`size`/`progress`, so nobody noticed the
// field-name drift until a real download produced an empty card.
const preview = {
  window: {
    // `IS_TAURI` is read at load time, so the recorder has to exist before
    // mt-api.js is evaluated.
    melon: {
      available: true,
      invoke: (cmd, args) => {
        preview.window.__calls.push([cmd, args]);
        return Promise.resolve(null);
      },
    },
    __calls: [],
  },
  S: { lang: "ru", localAi: {} },
  t: (key) => key,
  inv: () => Promise.resolve(null),
  console,
};
vm.createContext(preview);
vm.runInContext(fs.readFileSync(path.join(ui, "mt-api.js"), "utf8"), preview);

function expectKeys(label, value, keys) {
  if (!value || typeof value !== "object") {
    errors.push(`${label} is missing from the preview mock`);
    return;
  }
  for (const key of keys) {
    if (!(key in value)) errors.push(`${label} is missing \`${key}\``);
  }
}

const hfFile = vm.runInContext('demoHfDetails("org/repo").ggufFiles[0]', preview);
expectKeys("demo HF file", hfFile, ["name", "size", "downloadUrl", "quantization", "sha256"]);
if (hfFile && ("rfilename" in hfFile || "filename" in hfFile || "sizeBytes" in hfFile)) {
  errors.push("demo HF file still uses rfilename/filename/sizeBytes");
}

vm.runInContext('demoStartDownload({ repoId: "org/repo", filename: "model.gguf" })', preview);
const download = vm.runInContext("DEMO_LOCAL_AI_DOWNLOADS[0]", preview);
expectKeys("demo download", download, [
  "modelId",
  "repoId",
  "filename",
  "bytesDownloaded",
  "totalBytes",
  "progress",
  "speedFormatted",
  "etaSeconds",
  "status",
]);
if (download && !["queued", "downloading", "paused", "completed", "failed", "canceled"].includes(download.status)) {
  errors.push(`demo download status \`${download.status}\` is not a lower-case wire value`);
}

const runtime = vm.runInContext("DEMO_LOCAL_AI_RUNTIME", preview);
expectKeys("demo runtime status", runtime, ["currentModel", "modelId", "revision", "isRunning", "appliedSettings"]);

// W5: the shim used to accept five positional arguments while the caller
// passed the LFS digest sixth, so the backend never received a SHA-256.
const sha = "a".repeat(64);
vm.runInContext(
  `api.localAi.downloadStart({
    repoId: "org/repo",
    filename: "model.gguf",
    downloadUrl: "https://huggingface.co/org/repo/resolve/main/model.gguf",
    quantization: "Q4_K_M",
    token: null,
    sha256: "${sha}",
  })`,
  preview,
);
const downloadCall = vm.runInContext(
  'window.__calls.find((call) => call[0] === "local_ai_download_start")',
  preview,
);
if (!downloadCall) {
  errors.push("downloadStart never invoked local_ai_download_start");
} else {
  const request = downloadCall[1] && downloadCall[1].request;
  expectKeys("local_ai_download_start request", request, [
    "repoId",
    "filename",
    "downloadUrl",
    "quantization",
    "sha256",
  ]);
  if (request && request.sha256 !== sha) {
    errors.push("downloadStart drops the SHA-256 before it reaches Rust");
  }
}

const estimate = vm.runInContext("demoMemoryEstimate({})", preview);
expectKeys("demo memory estimate", estimate, [
  "weightsBytes",
  "kvCacheBytes",
  "computeBuffersBytes",
  "totalBytes",
  "fitsInMemory",
  "confidence",
]);
if (estimate && ("totalRequired" in estimate || "kvCacheSize" in estimate)) {
  errors.push("demo memory estimate still uses totalRequired/kvCacheSize");
}

if (errors.length) {
  for (const error of errors) console.error(`ui-static-check: ${error}`);
  process.exit(1);
}
console.log(`ui-static-check ok: ${files.length} scripts, ${allowed.size} whitelisted commands`);
