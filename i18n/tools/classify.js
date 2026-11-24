// Classify candidates: keep only strings that belong to PentAGI business chunks.
const fs = require('fs');
const path = require('path');

const SRC = 'C:/pentagi/i18n/candidates.json';
const OUT = 'C:/pentagi/i18n/business.json';

// Third-party / infrastructure bundles: their strings are library internals.
const LIB = [
  'pdf-', 'terminal-', 'tiptap-', 'charts-', 'markdown-', 'apollo-client-',
  'react-vendor-', 'radix-ui-', 'schemas-', 'workerBundle', 'rolldown-runtime-',
  'marked-', 'data-table-', 'dist-', 'chunk-', 'utils-', 'format-', 'log-',
  'spinner-', 'resizable-', 'scrollable-region-', 'use-page-storage-keys-',
  'use-app-form-', 'list-filter-', 'text-filter-', 'autocomplete-', 'command-',
  'dropdown-menu-', 'popover-', 'select-', 'switch-', 'toggle-', 'form-',
  'input-group-', 'collapsible-', 'card-', 'alert-', 'table-', 'local-storage-',
  'regex-', 'marked', 'pencil', 'trash', 'eye-', 'code-', 'clipboard-',
  'chevron', 'circle-', 'bot-', 'wrench-', 'rotate-ccw-', 'platform-',
  'provider-icon-', 'flow-status-icon-', 'form-submit-button-', 'inline-edit-',
];

function isLib(file) {
  return LIB.some(p => file.startsWith(p));
}

const rows = JSON.parse(fs.readFileSync(SRC, 'utf8'));

// A candidate survives if ANY of its source files is a business chunk.
const business = [];
const skipped = [];
for (const r of rows) {
  const bizFiles = r.files.filter(f => !isLib(f));
  if (bizFiles.length > 0) {
    business.push({ s: r.s, n: r.n, files: bizFiles });
  } else {
    skipped.push(r);
  }
}

// Drop obvious non-copy leftovers: css values, font stacks, react internals
const dropRe = [
  /^use[A-Z]\w* must be used within/,
  /^React\./,
  /^(?:ui-monospace|monospace|sans-serif)/,
  /^[a-z-]+:\s/,
  /^[a-z0-9\s:./[\]()-]+$/,
];
const clean = business.filter(x => !dropRe.some(re => re.test(x.s)));

fs.writeFileSync(OUT, JSON.stringify(clean, null, 2), 'utf8');

const byFile = new Map();
for (const c of clean) for (const f of c.files) byFile.set(f, (byFile.get(f) || 0) + 1);

console.log('total candidates :', rows.length);
console.log('business kept    :', clean.length);
console.log('dropped          :', rows.length - clean.length);
console.log('--- business chunks ---');
[...byFile.entries()].sort((a, b) => b[1] - a[1]).forEach(([f, n]) => console.log(String(n).padStart(4), f));
