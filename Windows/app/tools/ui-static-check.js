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

if (errors.length) {
  for (const error of errors) console.error(`ui-static-check: ${error}`);
  process.exit(1);
}
console.log(`ui-static-check ok: ${files.length} scripts, ${allowed.size} whitelisted commands`);
