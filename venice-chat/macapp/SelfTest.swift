// Самотесты: VENICE_SELFTEST=1 ./VeniceChat — печатает JSON со всеми проверками и выходит.
// VENICE_AGENTTEST="задание" — прогоняет модель в браузере на реальной задаче (тестовый чат удаляется).
enum SelfTest {
    static let agentScript = #"""
await new Promise(r => setTimeout(r, 2500));
const before = S.settings.agent;
S.settings.agent = true; setMode("chat"); newChat();
$("#input").value = task; autoGrow();
// в тесте на запросы разрешения отвечаем «запретить» (при VENICE_AGENTTEST_DENY)
const iv = deny ? setInterval(() => { for (const r of [...S.approvals.values()]) r(false); }, 300) : 0;
await send();
clearInterval(iv);
const m = S.chat.messages.at(-1);
const out = { steps: (m.steps || []).map(s => s.status + ": " + s.text), answer: (m.content || "").slice(0, 900), error: m.error || null, usage: m.usage || null };
await api.remove(S.chat.id);
S.settings.agent = before; saveSettings();
return JSON.stringify(out);
"""#

    static let script = #"""
const r = {};
await new Promise(res => setTimeout(res, 1500));
try { localStorage.setItem("t", "1"); r.localStorage = localStorage.getItem("t") === "1"; } catch (e) { r.localStorage = String(e); }
r.libs = !!(window.marked && window.hljs && window.katex && window.JSZip && window.pdfjsLib && window.mammoth);
r.key = await (await fetch("/api/key")).json();
r.models = (await (await fetch("/api/models")).json()).length;
r.chats = (await (await fetch("/api/chats")).json()).length;
r.imageModels = (await (await fetch("/api/models?type=image")).json()).length;
r.editModels = (await (await fetch("/api/models?type=inpaint")).json()).length;
const bad = await fetch("/api/image/generate", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
r.imageRoute = bad.status + " " + (await bad.text()).slice(0, 40);
r.modes = document.querySelectorAll("#modes button").length;
r.nativeTheme = !!window.webkit?.messageHandlers?.setTheme;
r.toolsFlag = (await (await fetch("/api/models")).json()).find(m => m.id === "deepseek-v4-1-flash-1017-uncensored")?.tools;
r.archiveTools = typeof archiveTool === "function" && typeof readZip === "function";
const b = window.webkit?.messageHandlers?.browser;
r.browserBridge = !!b;
if (b) {
  const opened = await b.postMessage({ cmd: "open", args: { url: "https://example.com" } });
  const snap = await b.postMessage({ cmd: "read" });
  r.browserOpen = opened.title + " | elements=" + snap.elementCount + " | " + (snap.elements || "").split("\n")[0];
  await b.postMessage({ cmd: "hide" });
}
const badKey = await fetch("/api/key", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ key: "not-a-real-key" }) });
r.badKeyRejected = badKey.status === 400 && (await (await fetch("/api/key")).json()).custom === false;
r.logo = (await fetch("/logo.svg")).status;
const gh = await fetch("/api/fetch", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ url: "https://raw.githubusercontent.com/octocat/Hello-World/master/README" }) });
r.fetchLink = gh.status + " " + (await gh.text()).trim();
r.fetchLocalBlocked = (await fetch("/api/fetch", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ url: "http://127.0.0.1:22" }) })).status;
r.title = document.title;
const usage = await (await fetch("/api/usage")).json();
r.usageRoute = Array.isArray(usage.events);
const pj = { id: "selftest_project", name: "t", files: [{ id: "f", name: "a.txt", kind: "text", data: "x" }], updated: 1 };
await fetch("/api/projects/" + pj.id, { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(pj) });
const listed = (await (await fetch("/api/projects")).json()).find(p => p.id === pj.id);
r.projectRoundtrip = listed?.fileCount === 1 && (await (await fetch("/api/projects/" + pj.id)).json()).files[0].data === "x";
await fetch("/api/projects/" + pj.id, { method: "DELETE" });
r.projectDeleted = !(await (await fetch("/api/projects")).json()).some(p => p.id === pj.id);
r.projectsUI = !!document.querySelector("#projectList") && !!document.querySelector("#chatProject");
r.nativeSave = !!window.webkit?.messageHandlers?.saveImage;
r.css = (await fetch("/app.css")).status;
const res = await fetch("/api/chat", { method: "POST", headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ messages: [{ role: "user", content: "Reply with: OK" }], venice_parameters: { include_venice_system_prompt: false } }) });
r.chatStatus = res.status;
const reader = res.body.getReader(); const dec = new TextDecoder(); let text = "", chunks = 0;
for (;;) { const { value, done } = await reader.read(); if (done) break; chunks++; text += dec.decode(value); }
r.chunks = chunks;
r.reply = text.split("\n").filter(l => l.startsWith("data:") && !l.includes("[DONE]"))
  .map(l => { try { return JSON.parse(l.slice(5)).choices[0].delta.content || ""; } catch { return ""; } }).join("");
r.ui = !!document.querySelector("#composer") && !!document.querySelector("#chatList");
const ac = new AbortController();
const long = await fetch("/api/chat", { method: "POST", signal: ac.signal, headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ messages: [{ role: "user", content: "Write a 600-word story." }] }) });
const lr = long.body.getReader(); let got = 0;
setTimeout(() => ac.abort(), 2500);
try { for (;;) { const { done } = await lr.read(); if (done) break; got++; } r.aborted = false; } catch (e) { r.aborted = e.name; }
r.chunksBeforeStop = got;
r.aliveAfterStop = (await fetch("/api/key")).status === 200;
const upd = await (await fetch("/api/update")).json();
r.update = upd.current + (upd.available ? " → " + upd.latest : " (новее нет" + (upd.error ? ": " + upd.error : "") + ")");
r.updateUI = typeof window.checkForUpdates === "function";
return JSON.stringify(r);
"""#
}
