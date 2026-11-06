// Правка архивов: план распаковки в рабочую копию и сборка готового архива. Чистые функции, JSZip передаётся снаружи.
// Подключается в index.html перед app.js; в Node — require() для тестов.
"use strict";
const AW = (() => {
  const MB = 1 << 20;
  const LIMITS = { zip: 100 * MB, entries: 65_000, files: 10_000, bytes: 300 * MB, file: 50 * MB };
  const utf8 = new TextDecoder("utf-8", { fatal: true });
  let cp866 = null; try { cp866 = new TextDecoder("ibm866"); } catch {}
  // имена без флага UTF-8: архивы с Mac — в UTF-8, из Проводника Windows — в cp866
  const zipName = b => { try { return utf8.decode(b); } catch { return (cp866 || new TextDecoder("utf-8")).decode(b); } };
  const enc = new TextEncoder();
  // код (а не документы): по нему решаем, распаковывать ли архив для правки
  const CODE_FILE = /\.(html?|xhtml|css|scss|sass|less|m?js|cjs|jsx|tsx?|vue|svelte|astro|php|phtml|py|rb|go|java|kt|swift|c|cc|cpp|h|hpp|cs|rs|json|xml|svg|ya?ml|toml|ini|cfg|conf|sh|sql|liquid|twig|ejs|hbs|njk|pug|tpl)$/i;
  const JUNK = /(^|\/)(__MACOSX(\/|$)|\.DS_Store$|Thumbs\.db$|desktop\.ini$|\._[^/]*$)/;
  // не распаковываются (тяжёлые, их не правят) — в готовом архиве остаются как были.
  // Всё, что пропускает операция files на сервере (WORK_SKIP), обязано быть здесь, иначе исходные файлы сочтутся удалёнными.
  const UNPACK_SKIP = /(^|\/)(\.git|\.svn|\.hg|node_modules|bower_components|jspm_packages|\.venv|venv|__pycache__|\.pytest_cache|\.mypy_cache|\.ruff_cache|\.parcel-cache|\.turbo|\.cache|\.gradle|\.next|\.nuxt|\.svelte-kit|Pods|DerivedData)(\/|$)/;
  // новые файлы, которые в готовый архив не попадают
  const PACK_SKIP = /(^|\/)(node_modules|bower_components|\.venv|venv|__pycache__|\.pytest_cache|\.mypy_cache|\.ruff_cache|\.ipynb_checkpoints|\.git|\.svn|\.hg|\.next|\.nuxt|\.svelte-kit|\.parcel-cache|\.turbo|\.cache)(\/|$)|\.(pyc|pyo|log|zip)$/i;
  const BUILD_DIR = /^(.*?(?:^|\/)(?:dist|build|out|coverage|target))\//;   // новая папка сборки — только если такая была в архиве
  const HIDDEN_BUILD = /^(dist|build|out|coverage|target|\.build)\//;          // эти папки list_files/grep/code_map пропускают

  // «./a» и «a//b» безопасны (JSZip их просто нормализует); «../», «/abs», «C:\», NUL и слишком длинные имена — нет
  const rawName = e => (e.unsafeOriginalName ?? e.name).replace(/\\/g, "/");
  // архивы из PowerShell/.NET пишут пути через «\» — в готовом архиве они станут обычными «/»
  const slashed = n => n.replace(/\\/g, "/").replace(/\/\/+$/, "/");
  const num = n => n.toLocaleString("ru-RU");
  const filesN = n => { const m10 = n % 10, m100 = n % 100;
    return `${num(n)} ${m10 === 1 && m100 !== 11 ? "файл" : m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14) ? "файла" : "файлов"}`; };
  const isUnsafe = e => { const raw = rawName(e); return /^(\/|[A-Za-z]:)/.test(raw) || raw.split("/").some(s => s === ".." || s.includes("\0") || enc.encode(s).length > 255); };
  const isLink = e => ((e.unixPermissions || 0) & 0o170000) === 0o120000;
  const sameBytes = (a, b) => { if (a.length !== b.length) return false; for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false; return true; };

  function planUnpack(zip) {
    const files = [], deps = new Set(), skipped = { links: 0, unsafe: 0, dup: 0, big: 0 };
    const taken = new Map();   // путь в нижнем регистре → "f" | "d" (на Mac «A.txt» и «a.txt» — один файл)
    let entries = 0;
    for (const e of Object.values(zip.files)) {
      entries++;
      if (e.dir || /\\$/.test(e.name)) continue;
      if (isUnsafe(e)) { skipped.unsafe++; continue; }
      const parts = e.name.replace(/\\/g, "/").split("/").filter(s => s && s !== ".");
      if (!parts.length) continue;
      const p = parts.join("/");
      if (JUNK.test(p)) continue;
      const dep = UNPACK_SKIP.exec(p);
      if (dep) { deps.add(dep[2]); continue; }
      if (isLink(e)) { skipped.links++; continue; }
      const size = e._data?.uncompressedSize ?? 0;
      if (size > LIMITS.file) { skipped.big++; continue; }
      const low = p.normalize("NFC").toLowerCase().split("/");
      const ups = low.slice(0, -1).map((_, i) => low.slice(0, i + 1).join("/"));
      const key = low.join("/");
      if (taken.has(key) || ups.some(d => taken.get(d) === "f")) { skipped.dup++; continue; }
      ups.forEach(d => taken.set(d, "d"));
      taken.set(key, "f");
      files.push({ entry: e.name, parts, size, x: !!((e.unixPermissions || 0) & 0o111) });
    }
    // всё лежит в одной общей папке (Finder «site/», GitHub «repo-main/») — в копии её нет, в готовом архиве она вернётся
    const tops = new Set(files.map(f => f.parts[0]));
    const wrapName = tops.size === 1 && files.every(f => f.parts.length > 1) ? files[0].parts[0] : "";
    const out = files.map(f => ({ entry: f.entry, rel: f.parts.slice(wrapName ? 1 : 0).join("/").normalize("NFC"), size: f.size, x: f.x }))
      // сервер срезает пробелы по краям пути — такие файлы не распаковываем, в готовом архиве они останутся как были
      .filter(f => !/^[\s\x1c-\x1f\x85]|[\s\x1c-\x1f\x85]$/.test(f.rel));
    // почти весь код — в папке, которую обход папки пропускает (собранный сайт в dist/), а исходников рядом нет — подскажем модели
    const code = out.filter(f => CODE_FILE.test(f.rel)), per = {};
    for (const f of code) { const t = HIDDEN_BUILD.exec(f.rel)?.[1]; if (t && t !== "coverage" && t !== "target") per[t] = (per[t] || 0) + 1; }
    const outside = code.filter(f => !HIDDEN_BUILD.test(f.rel) && !/\.(json|ya?ml|toml|ini|cfg|conf|xml|svg)$/i.test(f.rel)).length;
    const [codeDir = "", n = 0] = Object.entries(per).sort((a, b) => b[1] - a[1])[0] || [];
    return { files: out, prefix: wrapName ? wrapName + "/" : "", wrapName, entries, bytes: out.reduce((s, f) => s + f.size, 0),
      deps: [...deps], skipped, codeDir: n > code.length / 2 && outside <= 2 ? codeDir : "" };
  }

  // "" — можно править; иначе причина простыми словами
  function checkLimits(plan, zipSize) {
    const mb = n => Math.max(1, Math.round(n / MB));
    if (zipSize > LIMITS.zip) return `архив ${mb(zipSize)} МБ — править можно до ${mb(LIMITS.zip)} МБ`;
    if (plan.entries > LIMITS.entries) return `в нём больше ${num(LIMITS.entries)} записей`;
    if (plan.files.length > LIMITS.files || plan.bytes > LIMITS.bytes)
      return `слишком большой: ${filesN(plan.files.length)}, ${mb(plan.bytes)} МБ (можно до ${num(LIMITS.files)} файлов и ${mb(LIMITS.bytes)} МБ)`;
    if (!plan.files.length) return "в архиве нет файлов, которые можно править";
    return "";
  }

  // Перед сборкой: мусор и опасные пути — вон (точечно, без zip.remove: тот на папке удаляет всё содержимое);
  // файлы, лежавшие без сжатия, так и остаются — их байты копируются как есть.
  // Имена в готовом архиве JSZip берёт из ключей zip.files — поэтому «\» меняем в ключах
  function prepareOutput(zip) {
    const files = Object.create(null);
    for (const name of Object.keys(zip.files)) {
      const e = zip.files[name];
      if (isUnsafe(e) || JUNK.test(rawName(e))) continue;
      if (!e.dir && e._data?.compression?.magic === "\x00\x00") e.options.compression = "STORE";
      let n = slashed(name);
      if (n !== name && (n in files || n in zip.files)) n = name;
      e.name = n;
      files[n] = e;
    }
    zip.files = files;
  }

  // Готовый архив = исходный, где изменённые файлы заменены, новые добавлены, удалённые убраны.
  // snap — снимок сразу после распаковки { prefix, files: [[путь, запись в zip, версия]] }; now — ответ операции files;
  // get(путь) → Uint8Array с байтами файла рабочей копии
  async function applyChanges(zip, { snap, now, get }) {
    const nfc = p => p.normalize("NFC");
    const ent = n => n && (zip.files[n] ? n : slashed(n));   // запись снимка — до prepareOutput, с «\»
    const was = new Map(snap.files.map(([p, entry, v]) => [nfc(p), { entry: ent(entry), v }]));
    const cur = new Map(now.map(f => [nfc(f.path), f]));
    const snapDirs = new Set();
    for (const k of was.keys()) { const a = k.split("/"); for (let i = 1; i < a.length; i++) snapDirs.add(a.slice(0, i).join("/")); }
    const report = { changed: [], added: [], deleted: [], skipped: [] };
    const gone = [];
    // JSZip пишет время в архив по UTC-часам даты — сдвигаем, чтобы в архиве было местное время правки
    const stamp = new Date(Date.now() - new Date().getTimezoneOffset() * 60_000);
    for (const [k, b] of was) {
      if (cur.has(k) || !b.entry || !zip.files[b.entry] || zip.files[b.entry].dir) continue;
      delete zip.files[b.entry]; gone.push(b.entry); report.deleted.push(k);
    }
    // папки, опустевшие из-за удаления, тоже убираем (самые глубокие — первыми)
    const dirs = Object.keys(zip.files).filter(n => zip.files[n].dir && gone.some(g => g.startsWith(n))).sort((a, b) => b.length - a.length);
    for (const d of dirs) if (!Object.keys(zip.files).some(n => n !== d && n.startsWith(d))) delete zip.files[d];
    for (const [k, f] of cur) {
      const b = was.get(k);
      if (b && b.v === f.version) continue;   // не трогали
      if (!b) {
        const bd = BUILD_DIR.exec(k);
        if (PACK_SKIP.test(k) || UNPACK_SKIP.test(k) || JUNK.test(k) || (bd && !snapDirs.has(bd[1])) || f.size > LIMITS.file) { report.skipped.push(k); continue; }
      }
      const data = await get(f.path);
      const old = b?.entry && zip.files[b.entry] && !zip.files[b.entry].dir ? zip.files[b.entry] : null;
      if (old && sameBytes(await old.async("uint8array"), data)) continue;   // правку отменили — файл как был
      zip.file(old ? b.entry : snap.prefix + k, data, { date: stamp, createFolders: false,
        unixPermissions: old?.unixPermissions ?? (f.x ? 0o100755 : 0o100644) });
      report[old ? "changed" : "added"].push(k);
    }
    return report;
  }

  const stemOf = name => String(name || "").normalize("NFC").split("/").pop().replace(/\.zip$/i, "").replace(/ \(\d+\)$/, "")
    .replace(/[\\/:*?"<>|\u0000-\u001f]+/g, "-").trim().slice(0, 60) || "архив";
  const readyName = name => `${stemOf(name)} (готово).zip`;

  return { LIMITS, CODE_FILE, zipName, isUnsafe, planUnpack, checkLimits, prepareOutput, applyChanges, stemOf, readyName };
})();
if (typeof module !== "undefined") module.exports = AW; else window.AW = AW;
