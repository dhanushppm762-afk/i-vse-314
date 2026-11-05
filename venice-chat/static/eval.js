// Проверка качества ответов: набор вопросов с эталонными пунктами, ответы оценивает модель-судья (0–10).
// Запуск в приложении: VENICE_SELFTEST=1 VENICE_EVAL=1 …/VeniceChat (VENICE_EVAL=compare — ещё и без самопроверки).
// Тестовые чаты удаляются, настройки и память пользователя возвращаются как были.
const EVAL_SET = [
  { id: "price", q: "Напиши функцию на JavaScript, которая форматирует число как цену в рублях: 1234567.5 → «1 234 567,50 ₽».",
    key: "Рабочий код; Intl.NumberFormat('ru-RU') или ручное форматирование; ровно две цифры после запятой; пробелы между разрядами (неразрывные допустимы); знак ₽ в конце; пример вызова." },
  { id: "bug", q: "Почему этот код выводит не ту сумму?\n```js\nlet sum;\n[1, 2, 3].forEach(async n => { sum += await Promise.resolve(n); });\nconsole.log(sum);\n```",
    key: "Две ошибки: sum не инициализирована (undefined + число = NaN) и forEach не ждёт async-функции, поэтому console.log выполняется раньше. Исправление: let sum = 0 и цикл for…of с await (или Promise.all). Исправленный код." },
  { id: "card", q: "Сделай адаптивную карточку товара на HTML и CSS: фото, название, цена, кнопка «Купить». На телефоне — во всю ширину.",
    key: "Один готовый HTML-файл (или HTML + CSS) без ошибок; картинка с alt и object-fit или max-width; медиазапрос или гибкая ширина для мобильных; кнопка оформлена; код можно открыть и он работает." },
  { id: "deposit", q: "Вклад 250 000 ₽ под 14% годовых с ежемесячной капитализацией на 2 года. Сколько будет в конце?",
    key: "Формула 250000·(1+0,14/12)^24; итог ≈ 330 246,78 ₽ (допустимо ±5 ₽); доход ≈ 80 246,78 ₽. Неверная итоговая сумма — оценка не выше 3." },
  { id: "letvar", q: "Чем let отличается от var в JavaScript? Коротко, с примерами.",
    key: "Блочная область видимости у let против функциональной у var; поднятие: var = undefined, let — временная мёртвая зона (ReferenceError); повторное объявление let запрещено; let в цикле с замыканиями. Коротко, с примерами кода." },
  { id: "polite", q: "Перепиши вежливо, но твёрдо: «Вы опять сорвали сроки, мне надоело, сделайте уже наконец нормально».",
    key: "Вежливый, деловой тон без грубости; сохраняет суть (сроки сорваны повторно, нужен результат); есть конкретная просьба или срок; без лишней воды; можно 1–3 варианта." },
  { id: "riddle", q: "У Пети 3 брата, и у каждого брата одна сестра. Сколько всего детей в семье?",
    key: "Ответ 5 (Петя, 3 брата и одна сестра — общая для всех). Если считается, что Петя — мальчик. Неверный ответ — оценка 0–2." },
  { id: "deploy", q: "Я новичок. Как бесплатно выложить свой сайт из одного HTML-файла в интернет?",
    key: "Понятные новичку шаги; 1–3 реальных бесплатных сервиса (GitHub Pages, Netlify Drop, Cloudflare Pages или Vercel); пошагово; без выдуманных сервисов и функций; что получится в итоге (ссылка)." },
  { id: "rename", q: "Напиши скрипт на Python, который переименовывает все .jpg в папке по дате съёмки в формат 2024-05-31_14-20-05.jpg.",
    key: "Рабочий код; дата из EXIF (Pillow: DateTimeOriginal, тег 36867) с запасным вариантом — дата изменения файла; обработка совпадающих имён; регистр .JPG; как запустить и что установить (pip install pillow)." },
  { id: "percent", q: "Сколько будет 17% от 2 340?",
    key: "397,8. Коротко. Неверное число — оценка 0." },
  { id: "dbtable", q: "Сравни SQLite, PostgreSQL и MySQL таблицей: для чего подходят, плюсы, минусы.",
    key: "Таблица Markdown с тремя СУБД; верные факты (SQLite — встроенная, один файл, без сервера; PostgreSQL — расширяемая, строгая, JSONB; MySQL — популярна в вебе); вывод, что выбрать." },
  { id: "future", q: "Какая версия Python вышла в марте 2031 года?",
    key: "Модель честно говорит, что не знает событий 2031 года или что это будущее, и не выдумывает номер версии; может предложить проверить python.org. Выдуманная версия как факт — оценка 0–2." },
];

const EVAL_JUDGE = `Ты строгий экзаменатор. Оцени ответ ассистента на вопрос пользователя по шкале 0–10.
Эталон — что должно быть в хорошем ответе:
{key}

Снижай оценку за фактические ошибки, неработающий код, выдумки, пропуск важного, лишнюю воду, плохое оформление.
10 — безупречно, 7–8 — хорошо с мелкими недочётами, 4–6 — заметные проблемы, 0–3 — неверно.
Ответь только JSON без пояснений: {"score": число, "issues": "главные недочёты коротко, по-русски, или пусто"}`;

async function evalJudge(model, item, answer) {
  const body = { model, stream: false, messages: [
    { role: "system", content: EVAL_JUDGE.replace("{key}", item.key) },
    { role: "user", content: `Вопрос:\n${item.q}\n\nОтвет ассистента:\n${answer || "(пусто)"}` },
  ], venice_parameters: { include_venice_system_prompt: false,
    ...(findModel("text", model)?.reasoning ? { disable_thinking: true } : {}) } };
  const res = await fetch("/api/chat", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
  if (!res.ok) throw new Error(readError(await res.text()));
  const j = await res.json();
  const text = splitThink({ content: j.choices?.[0]?.message?.content || "" }).content;
  const usd = j.cost?.usd ?? textCost(model, j.usage?.prompt_tokens || 0, j.usage?.completion_tokens || 0);
  const m = text.match(/\{[\s\S]*\}/);
  let v = {};
  try { v = JSON.parse(m ? m[0] : text); } catch { v = { score: Number(text.match(/\d+/)?.[0]), issues: text.slice(0, 200) }; }
  const score = Math.max(0, Math.min(10, Number(v.score)));
  return { score: Number.isFinite(score) ? score : null, issues: String(v.issues || "").slice(0, 300), usd: usd || 0 };
}

async function evalAnswer(item) {
  setMode("chat"); newChat();
  $("#input").value = item.q; autoGrow();
  const t0 = Date.now();
  await send();
  const chat = S.chat;
  const m = chat?.messages.at(-1) || {};
  const out = { answer: splitThink(m).content.trim(), error: m.error || null, usd: m.usage?.usd || 0,
    checked: !!m.draft, sec: Math.round((Date.now() - t0) / 1000) };
  // сохранение чата уходит в фоне — ждём его, чтобы удаление было последним
  if (chat) { chat.deleted = true; await new Promise(r => setTimeout(r, 800)); await api.remove(chat.id); S.chats = S.chats.filter(c => c.id !== chat.id); S.cache.delete(chat.id); newChat(); }
  return out;
}

window.runEval = async function ({ compare = false, only = null } = {}) {
  const keep = { selfCheck: S.settings.selfCheck, browserTool: S.settings.browserTool, userMemory: S.settings.userMemory };
  S.settings.browserTool = false;
  const model = $("#model").value || S.settings.model || S.defaultModel;
  const variants = compare ? [["без самопроверки", false], ["с самопроверкой", true]] : [["как в настройках", keep.selfCheck !== false]];
  const items = only ? EVAL_SET.filter(i => only.includes(i.id)) : EVAL_SET;
  const report = { model, runs: [] };
  try {
    for (const [name, check] of variants) {
      S.settings.selfCheck = check;
      const run = { name, items: [], usd: 0 };
      for (const item of items) {
        let r;
        try {
          const a = await evalAnswer(item);
          const j = a.answer ? await evalJudge(model, item, a.answer) : { score: 0, issues: a.error || "нет ответа", usd: 0 };
          r = { id: item.id, score: j.score, issues: j.issues, checked: a.checked, sec: a.sec, usd: +(a.usd + j.usd).toFixed(4), answer: a.answer.slice(0, 600) };
        } catch (e) { r = { id: item.id, score: null, issues: "ошибка: " + e.message, usd: 0 }; }
        run.usd += r.usd;
        run.items.push(r);
        console.log("EVAL", name, r.id, r.score, r.issues);
      }
      const scored = run.items.filter(r => r.score != null);
      run.avg = scored.length ? +(scored.reduce((s, r) => s + r.score, 0) / scored.length).toFixed(2) : null;
      run.usd = +run.usd.toFixed(4);
      report.runs.push(run);
    }
  } finally {
    Object.assign(S.settings, keep); saveSettings();
  }
  report.usd = +report.runs.reduce((s, r) => s + r.usd, 0).toFixed(4);
  return report;
};
