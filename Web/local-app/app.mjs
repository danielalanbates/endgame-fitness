import {tiersFor} from "./seasons.mjs";
import {TALENT_TREE, validateSpend} from "./talents.mjs";
// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
import { catalog, recipes } from "./native-programs.mjs";
import * as E from "./engine.mjs";
const $ = (s) => document.querySelector(s),
  root = $("#app");
const esc = (v) =>
  String(v ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ],
  );
let state = E.fresh(),
  user = null,
  revision = 0,
  tab = "home",
  cloudStatus = "Checking connection",
  social = null,
  timerEnd = 0,
  saving = false,
  dirty = false,
  saveTimer = null,
  noticeTimer = null,
  storageIssue = false,
  saveEpoch = 0;
let nativeExercises = [];
const tabs = [
  ["home", "◈", "Home"],
  ["workout", "↗", "Workout"],
  ["social", "♧", "Community"],
  ["progress", "⌁", "Progress"],
  ["program", "▦", "Programs"],
  ["mesocycle", "▦", "Mesocycle"],
  ["library", "⌕", "Tools"],
  ["settings", "⚙", "Settings"],
];
const player = () => state.players.find((p) => p.id === state.selected);
const fmt = (n) =>
  new Intl.NumberFormat(undefined, { maximumFractionDigits: 1 }).format(n);
const button = (label, action, cls = "", extra = "") =>
  `<button class="${cls}" data-action="${action}" ${extra}>${label}</button>`;
const progress = (n, total) =>
  `<div class="progress"><span style="width:${Math.max(0, Math.min(100, (n / Math.max(total, 1)) * 100))}%"></span></div>`;
function notice(text) {
  $("#notice").textContent = text;
  clearTimeout(noticeTimer);
  noticeTimer = setTimeout(() => ($("#notice").textContent = ""), 6500);
}
async function api(path, method = "GET", body) {
  const r = await fetch("/api/endgame/" + path, {
    method,
    credentials: "same-origin",
    headers: body ? { "Content-Type": "application/json" } : {},
    body: body ? JSON.stringify(body) : undefined,
    cache: "no-store",
  });
  const data = await r.json();
  if (!r.ok) {
    const error = Error(
      data.error || "The server could not complete this request.",
    );
    error.status = r.status;
    throw error;
  }
  return data;
}
function localKey() {
  return E.key + "." + user.id;
}
function persist() {
  try {
    localStorage.setItem(
      localKey(),
      JSON.stringify({ state, revision, dirty: true }),
    );
    storageIssue = false;
  } catch {
    storageIssue = true;
    notice(
      "Device storage is full or unavailable. Keep this page open and export a backup.",
    );
  }
  dirty = true;
  saveEpoch++;
  cloudStatus = "Changes saved on this device";
  clearTimeout(saveTimer);
  saveTimer = setTimeout(sync, 1200);
}
async function sync() {
  if (saving || !dirty || !player() || !navigator.onLine) return;
  saving = true;
  const epoch = saveEpoch;
  try {
    const r = await api("state", "PUT", { state, revision });
    revision = r.revision;
    dirty = saveEpoch !== epoch;
    cloudStatus = dirty ? "Saving latest changes…" : "Saved to your account";
    try {
      localStorage.setItem(
        localKey(),
        JSON.stringify({ state, revision, dirty }),
      );
    } catch {
      storageIssue = true;
    }
    if (dirty) {
      clearTimeout(saveTimer);
      saveTimer = setTimeout(sync, 100);
    }
  } catch (e) {
    cloudStatus =
      e.status === 409
        ? "Cloud conflict · export a backup before reloading"
        : "Saved on this device · cloud unavailable";
    notice(e.message);
  } finally {
    saving = false;
    updateStatus();
  }
}
function updateStatus() {
  const el = $("#cloud");
  if (el) el.textContent = cloudStatus;
}
async function boot() {
  fetch("./exercise_library.json").then(r => r.json()).then(data => {
    nativeExercises = data.exercises;
    if ($("#guides")) $("#guides").innerHTML = guides($("#search").value);
  }).catch(() => {});

  root.innerHTML =
    '<div class="empty"><div class="glyph">◈</div><h1>Preparing your next level.</h1><p>Restoring your saved session…</p></div>';
  try {
    ({ user } = await api("me"));
    try {
      localStorage.setItem(E.key + ".last", JSON.stringify({ user }));
    } catch {
      storageIssue = true;
    }
    const cloud = await api("state");
    revision = cloud.revision;
    let cached = null;
    try {
      const raw = localStorage.getItem(localKey());
      if (raw) {
        cached = JSON.parse(raw);
        cached.state = E.validateState(cached.state);
        if (cached.state.selected !== user.id) cached = null;
      }
    } catch {
      storageIssue = true;
    }
    if (cached && cached.state.players.length !== 1) cached = null;
    if (cached?.dirty && cached.revision === revision) {
      state = cached.state;
      dirty = true;
      cloudStatus = "Recovered unsynced device changes";
    } else if (cloud.state) {
      state = E.validateState(cloud.state);
      cloudStatus = "Saved to your account";
      if (cached?.dirty) {
        localStorage.setItem(localKey() + ".recovery", JSON.stringify(cached));
        notice(
          "A newer cloud save was loaded. Your unsynced device backup is available in Settings.",
        );
      }
    } else if (cached) {
      state = cached.state;
      dirty = !!cached.dirty;
      cloudStatus = "Recovered device save";
    } else state = E.fresh();
  } catch (e) {
    if (!user && !navigator.onLine) {
      try {
        const last = JSON.parse(localStorage.getItem(E.key + ".last"));
        if (last?.user?.expires_at * 1000 > Date.now()) user = last.user;
      } catch {}
    }
    if (user) {
      try {
        const cached = JSON.parse(localStorage.getItem(localKey()));
        state = E.validateState(cached.state);
        revision = cached.revision;
        dirty = !!cached.dirty;
        cloudStatus = "Offline · using your device save";
      } catch {
        user = null;
        notice("Your cloud save could not be loaded. Retry when connected.");
      }
    }
  }
  render();
  if (dirty) sync();
  if ("serviceWorker" in navigator)
    navigator.serviceWorker.register("./sw.js").catch(() => {});
}
function welcome() {
  const authError = new URLSearchParams(location.search).get("auth");
  if (authError) {
    const clean = new URL(location.href);
    clean.searchParams.delete("auth");
    history.replaceState({}, "", clean.pathname + clean.search + clean.hash);
  }
  const errors = {
    cancelled: "Sign-in was cancelled. You can try again whenever you are ready.",
    state_mismatch: "That sign-in attempt expired. Please try again.",
    bad_response: "The sign-in provider returned an incomplete response. Please try again.",
    sign_in_failed: "Sign-in could not be completed. Please try again.",
    server_error: "The sign-in service is temporarily unavailable. Please try again.",
  };
  const error = errors[authError] || (authError ? "Sign-in could not be completed. Please try again." : "");
  const returnTo = encodeURIComponent("/endgamefitness/");
  return `<main class="welcome"><section><div class="brand">${dragonLogo()}<div>ENDGAME<small>FITNESS · LEVEL UP FOR LIFE</small></div></div><div class="eyebrow" style="margin-top:50px">Your strongest story starts here</div><h1>Real training.<br>Epic progress.<br><em>Your next level.</em></h1><p class="pitch">A smarter strength program. A party that shows up. Turn every workout into a little more of the person you want to become.</p><div class="benefits"><span>↗ Adaptive training</span><span>◈ Earn your progress</span><span>♧ Train with friends</span></div></section><section class="card"><span class="badge green">PUBLIC BETA · NO SUBSCRIPTION</span><h2 style="margin-top:25px">Your adventure, continued.</h2><p>Use your existing BatesAI account to save your program, remember your preferences, and build your training party.</p>${error ? `<p class="error">${esc(error)} Your training progress is safe.</p>` : ""}<a class="login primary" href="/api/auth/oauth/google?return_to=${returnTo}">Continue with Google →</a><a class="login" href="/api/auth/oauth/apple?return_to=${returnTo}">Continue with Apple →</a><p><small>Google and Apple authenticate your BatesAI account. Endgame never posts to those services or imports your contacts.</small></p><hr style="border:0;border-top:1px solid var(--line);margin:24px 0"><div class="row"><a href="./privacy.html">Privacy & data</a><a href="https://github.com/danielalanbates/endgame-fitness">Explore the source ↗</a></div><p><small>Your native Mac training profile and onboarding answers stay on this Mac. Native and web training logs currently use separate formats.</small></p></section></main>`;
}
function dragonLogo() {
  return '<picture><source media="(prefers-color-scheme: light)" srcset="./dragon-light.webp"><img src="./dragon-dark.webp" alt=""></picture>';
}
function onboarding() {
  return `<main class="welcome"><section><div class="brand">${dragonLogo()}ENDGAME FITNESS</div><span class="eyebrow" style="display:block;margin-top:45px">Welcome, ${esc(user.display_name)}</span><h1>Build your<br><em>starting point.</em></h1><p class="pitch">A plan that fits your equipment, your week, and your goals. These answers are saved to your account.</p><p>Start with comfortable loads, learn the movement, then progress. You can change your preferences anytime.</p>${button("Sign out", "logout", "quiet")}</section><section class="card"><h2>Make it yours</h2>${preferencesForm(null, "create")}<p><small>General strength training for adults. Adjust for your experience and health. Stop an exercise if it causes pain.</small></p></section></main>`;
}
const trainingTerms = [
  [
    "🏥 Medical Disclaimer",
    "Endgame Fitness and its developers are not medical professionals and do not provide medical advice, diagnosis, or treatment. The information and workout programs provided by this application are for educational and informational purposes only.\n\nBefore beginning any exercise program, you should consult with your primary care physician or other qualified healthcare provider to ensure that exercise is safe and appropriate for your individual circumstances.\n\nIf you experience any pain, discomfort, dizziness, or other adverse symptoms during exercise, stop immediately and consult a healthcare professional."
  ],
  [
    "⚠️ Assumption of Risk",
    "You acknowledge and agree that participation in physical exercise activities involves inherent risks, including but not limited to:\n\n• Risk of serious injury or death\n• Muscle strains, sprains, and tears\n• Joint injuries\n• Cardiovascular incidents\n• Equipment-related injuries\n\nYou voluntarily assume all such risks and agree to participate at your own risk."
  ],
  [
    "🛡️ Limitation of Liability",
    "TO THE FULLEST EXTENT PERMITTED BY LAW, Bates LLC, its owners, developers, and affiliates SHALL NOT BE LIABLE for any injuries, damages, or losses of any kind arising from:\n\n• Use of this application\n• Following workout programs or recommendations\n• Use of exercise equipment\n• Any direct, indirect, incidental, consequential, or punitive damages\n\nYou release and hold harmless Bates LLC and all associated parties from any and all claims, liabilities, damages, or expenses arising from your use of this application."
  ],
  [
    "🏢 Business Indemnification",
    "You agree to indemnify and hold harmless Bates LLC, its officers, directors, employees, contractors, and agents from any claims, lawsuits, damages, losses, or expenses (including attorney fees) arising from:\n\n• Your use of this application\n• Your breach of these terms\n• Your violation of any law or rights of third parties\n\nBates LLC provides this software \"AS IS\" without warranties of any kind, either express or implied."
  ],
  [
    "✅ Your Acknowledgment",
    "By checking the box below, you acknowledge that:\n\n• You have read and understood all waivers and disclaimers\n• You have been advised to consult with a physician before starting any exercise program\n• You voluntarily assume all risks associated with physical exercise\n• You release Bates LLC from all liability\n• You are of legal age to enter into this agreement\n• This agreement is legally binding"
  ]
];
const assessmentFields = [
  ["age", "Age in years", 1], ["weight", "Body weight (lb)", 0.1],
  ["height", "Height (in)", 0.1], ["bench", "Bench press five-rep weight (lb)", 0.5],
  ["squat", "Squat five-rep weight (lb)", 0.5], ["deadlift", "Deadlift five-rep weight (lb)", 0.5]
];
function trainingProfileForm(player) {
  const profile = player?.assessment || {};
  return `<fieldset><legend>Training profile</legend><label>Experience<select name="experience">
    ${["beginner","intermediate","advanced"].map(value => `<option ${value === profile.experience ? "selected" : ""}>${value}</option>`).join("")}</select></label>
    <div class="formgrid">${assessmentFields.map(([key,label,step]) => `<label>${label}<input name="${key}" type="number" min="${["age","weight","height"].includes(key) ? step : 0}" step="${step}" value="${esc(profile[key] ?? "")}" required></label>`).join("")}</div></fieldset>
    ${player?.assessment?.accepted ? "" : `<details><summary>Read the training terms</summary>${trainingTerms.map(([title,body]) => `<h3>${esc(title)}</h3><p style="white-space:pre-line">${esc(body)}</p>`).join("")}</details><label><input type="checkbox" name="accepted" required> I agree to the training terms.</label>`}`;
}
function preferencesForm(p, action) {
  return `<form data-form="${action}"><label>Player name<input name="name" required maxlength="40" value="${esc(p?.name || user.display_name.slice(0, 40))}" autocomplete="nickname"></label><label>Your main goal<select name="goal">${[
    ["balanced", "Build a balanced foundation"],
    ["strength", "Get stronger"],
    ["muscle", "Build muscle"],
  ]
    .map(
      ([v, t]) =>
        `<option value="${v}" ${p?.goal === v ? "selected" : ""}>${t}</option>`,
    )
    .join("")}</select></label><label>Your equipment<select name="equipment">${[
    ["dumbbells", "Dumbbells at home"],
    ["gym", "Full gym"],
    ["bodyweight", "Bodyweight only"],
  ]
    .map(
      ([v, t]) =>
        `<option value="${v}" ${p?.equipment === v ? "selected" : ""}>${t}</option>`,
    )
    .join(
      "",
    )}</select></label><div class="formgrid"><label>Sessions per week<select name="days">${[2, 3, 4, 5, 6].map((n) => `<option ${n === (p?.days || 3) ? "selected" : ""}>${n}</option>`).join("")}</select></label><label>Minutes per session<select name="minutes">${[20, 30, 45, 60].map((n) => `<option ${n === (p?.minutes || 45) ? "selected" : ""}>${n}</option>`).join("")}</select></label></div>${trainingProfileForm(p)}${button(p ? "Update preferences & rebuild plan" : "Build my program →", "submit", "primary", 'type="submit" style="width:100%"')}</form>`;
}
function frame(content) {
  const p = player(),
    s = E.stats(p);
  return `<div class="layout"><aside class="sidebar"><div class="brand">${dragonLogo()}<div>ENDGAME<small>FITNESS</small></div></div><nav aria-label="Main navigation">${tabs.map(([id, icon, label]) => button(`<span class="navicon" aria-hidden="true">${icon}</span>${label}`, "nav", "", 'data-tab="' + id + '" ' + (id === tab ? 'aria-current="page"' : ""))).join("")}</nav><div class="playerbox"><div class="playerline"><span class="avatar">${esc(p.name.slice(0, 1).toUpperCase())}</span><div><strong>${esc(p.name)}</strong><br><small>Level ${s.level} · Adventurer</small></div></div><span class="badge green">● BatesAI account connected</span></div></aside><main class="main"><div class="topline"><span>YOUR JOURNEY / ${esc(tabs.find((t) => t[0] === tab)?.[2].toUpperCase())}</span><span id="cloud">${esc(cloudStatus)}</span></div>${content}<footer class="footer"><span>© 2026 Daniel Bates / Bates LLC. All rights reserved.</span><span><a href="./privacy.html">Privacy</a> · <a href="mailto:help@batesai.org">Support</a> · <a href="https://github.com/danielalanbates/endgame-fitness">Source ↗</a> · Public beta 1.1</span></footer></main></div>`;
}
function heading(eyebrow, title, description) {
  return `<header class="pagehead"><div><span class="eyebrow">${eyebrow}</span><h1>${title}</h1><p>${description}</p></div><span class="badge green">✧ YOUR NEXT LEVEL IS EARNED</span></header>`;
}
function stat(label, value, detail) {
  return `<div class="card stat"><span class="eyebrow muted">${label}</span><div class="number">${value}</div><small>${detail}</small></div>`;
}
function questList(p) {
  return E.quests(p)
    .map(
      (q) =>
        `<div class="quest"><div class="row"><h3>${q.claimed ? "✓ " : ""}${q.title}</h3><small class="lime">+75 XP</small></div><small>${q.detail}</small>${progress(q.current, q.target)}<div class="row"><small>${Math.min(q.current, q.target)} / ${q.target}</small>${button(q.claimed ? "Claimed" : q.current >= q.target ? "Claim reward" : "In progress", "claim", "quiet", `data-id="${q.id}" ${q.claimed || q.current < q.target ? "disabled" : ""}`)}</div></div>`,
    )
    .join("");
}
function home() {
  const p = player(),
    s = E.stats(p),
    plan = p.plan || E.makePlan(p),
    next =
      plan.sessions[
        p.sessions.filter((w) => w.planId === plan.id).length %
          plan.sessions.length
      ],
    week = E.weeklySessions(p),
    thisLevel = E.xpForLevel(s.level),
    nextLevel = E.xpForLevel(s.level + 1);
  return `${heading("THE LONG GAME", `Ready for your next level, ${esc(p.name.split(" ")[0])}?`, "Small wins. Stronger habits. A little more you, every session.")}<div class="grid"><section class="card hero"><span class="badge">${p.active ? "SESSION IN PROGRESS" : "YOUR NEXT WORKOUT"}</span><h2>${esc(p.active?.name || next.name)}</h2><div class="hero-meta"><span>◷ ~${p.minutes} min</span><span>▦ ${p.active?.exercises.length || next.exercises.length} exercises</span><span>↗ ${esc(p.goal === "muscle" ? "Hypertrophy" : p.goal === "strength" ? "Strength" : "Balanced")}</span></div><p>${p.active ? "Your session is saved. Pick up where you left off." : "A purposeful session, with room to recover. Warm up first and let good technique lead."}</p>${button(p.active ? "Resume workout →" : "Let’s train →", "start", "primary")}</section><section class="card"><div class="row"><span class="eyebrow purple">Your character</span><span class="avatar">✧</span></div><h2 style="margin-top:20px">Level ${s.level} adventurer</h2><p>Consistency is your superpower.</p>${progress(s.xp - thisLevel, nextLevel - thisLevel)}<div class="row"><small>${fmt(s.xp)} XP total</small><small>${fmt(nextLevel - s.xp)} to level ${s.level + 1}</small></div><p><small>Training rewards effort and consistency, never lifting heavier than you should.</small></p></section></div><div class="cards">${stat("Training days", new Set(week.map((s) => s.day)).size + "/" + p.days, "This week’s rhythm")}${stat(
    "Working sets",
    week.reduce((n, s) => n + E.completedSets(s).length, 0),
    "Completed this week",
  )}${stat("Sessions", s.sessions, "All-time adventures")}${stat("Total XP", fmt(s.xp), "Earned, never bought")}</div><div class="grid"><section class="card"><div class="row"><h2>Your week, your pace</h2><small>Recovery counts too</small></div>${calendar(p)}<div class="sectiontitle"><h2>Recent adventures</h2>${button("View progress ↗", "nav", "quiet", 'data-tab="progress"')}</div>${
    p.sessions.length
      ? p.sessions
          .slice(-3)
          .reverse()
          .map(
            (s) =>
              `<div class="listrow row"><div><h3>${esc(s.name)}</h3><small>${esc(s.day)} · ${E.completedSets(s).length} sets</small></div><span class="lime">+${E.sessionXP(s)} XP</span></div>`,
          )
          .join("")
      : "<p>Your story starts with one workout. Your first completed session will appear here.</p>"
  }</section><section class="card"><div class="row"><h2>Your quests</h2><span class="purple">◈</span></div>${questList(p)}</section></div>`;
}
function calendar(p) {
  const days = ["M", "T", "W", "T", "F", "S", "S"],
    today = new Date(),
    mon = new Date(today);
  mon.setDate(mon.getDate() - ((mon.getDay() + 6) % 7));
  const done = new Set(p.sessions.map((s) => s.day));
  return `<div class="schedule">${days
    .map((d, i) => {
      const date = new Date(mon);
      date.setDate(date.getDate() + i);
      const k = E.dayKey(date);
      return `<div class="day ${done.has(k) ? "done" : ""} ${k === E.dayKey() ? "today" : ""}">${d}<strong>${date.getDate()}</strong>${done.has(k) ? "✓" : "·"}</div>`;
    })
    .join("")}</div>`;
}
function program() {
  const p = player(),
    plan = p.plan || E.makePlan(p);
  return `${heading("INTENTION BEFORE INTENSITY", "A plan with a purpose.", "Train the patterns. Build your base. Progress when you’re ready.")}<div class="grid"><div class="stack"><section class="card"><span class="eyebrow purple">${esc(plan.split)} · ${plan.sessions.length} SCHEDULED WORKOUTS</span><h2 style="margin-top:15px">Your next training block</h2><p>${esc(plan.explanation)}</p><div class="actions">${button(p.active ? "Resume your session" : "Start next session →", "start", "primary")}</div></section>${plan.sessions
    .map(
      (s) =>
        `<section class="card"><h2>${esc(s.name)}</h2>${s.exercises
          .map((e) => {
            const ex = E.byId(e.id),
              suggestion = E.nextLoad(p, e.id, e.low, e.high);
            return `<div class="listrow"><div class="row"><h3>${ex.name}</h3><small>${e.sets} × ${e.low}–${e.high}</small></div><small>${ex.muscle} · ${e.rest}s rest · ${suggestion.weight > 0 ? fmt(suggestion.weight) + " " + p.unit : "choose a comfortable load"}</small><details><summary>Why this load? / Movement guide</summary><p>${esc(suggestion.reason)}</p><p>${esc(ex.guide)}</p></details></div>`;
          })
          .join("")}</section>`,
    )
    .join(
      "",
    )}${programPicker()}</div><aside class="stack"><section class="card"><h2>The progression rule</h2><p>First, add good repetitions within your target range. When all sets at your heaviest load reach the top with at least one rep in reserve, the next session suggests more weight.</p><p>Otherwise, keep the weight and work toward another rep. Every fifth training week reduces volume; your readiness can trigger an earlier recovery session.</p><small>These are conservative programming rules, not a guarantee of individual outcomes. Bodyweight plans have limited pulling resistance.</small></section><section class="card"><h2>Fit your real life</h2><p>Sessions rotate by completion. Rest between hard sessions. A missed day never creates a debt you need to repay.</p>${button("Adjust preferences", "nav", "quiet", 'data-tab="settings"')}</section><section class="card"><h3>Built on evidence</h3><p><a href="https://pubmed.ncbi.nlm.nih.gov/19204579/" target="_blank" rel="noopener">ACSM progression guidance ↗</a><br><a href="https://pubmed.ncbi.nlm.nih.gov/38970765/" target="_blank" rel="noopener">Proximity to failure research ↗</a></p><small>Our specific rules are implementation choices. No study proves this app superior to every custom program.</small></section></aside></div>`;
}
function workout() {
  const p = player(),
    s = p.active;
  if (!s)
    return `${heading("SHOW UP. THAT’S STEP ONE.", "Your next adventure awaits.", "Choose your readiness, then start your next planned session.")}<div class="grid"><section class="card hero"><h2>Train with intention.</h2><p>Start light, warm up, and leave a few good repetitions in reserve. Nothing to prove. Progress to make.</p><label style="max-width:350px">How ready do you feel?<select id="readiness">${[
      [1, "1 · Very low"],
      [2, "2 · Need an easy day"],
      [3, "3 · Ready"],
      [4, "4 · Feeling good"],
      [5, "5 · Excellent"],
    ]
      .map(
        ([n, t]) =>
          `<option value="${n}" ${n === (p.recovery || 3) ? "selected" : ""}>${t}</option>`,
      )
      .join(
        "",
      )}</select></label>${button("Start workout →", "start", "primary")}</section><section class="card"><h2>Your recovery matters.</h2><p>Low readiness reduces your sets and suggested load. If you’re unwell or in pain, take a rest day.</p><small>Reps in reserve (RIR) means how many more clean repetitions you could have performed. It’s a useful estimate, not a test you must push to failure to check.</small></section></div>`;
  return `${heading(s.deload ? "RECOVERY SESSION" : "ONE GOOD SET AT A TIME", esc(s.name), "Your session saves as you go. Close the app and return when you’re ready.")}<div class="timer" ${timerEnd > Date.now() ? "" : "hidden"}><span>Rest · <strong id="countdown"></strong></span>${button("Skip rest", "skip", "quiet")}</div><div class="grid"><div class="stack">${s.exercises
    .map(
      (e, ei) =>
        `<section class="card"><div class="row"><div><span class="eyebrow purple">${String(ei + 1).padStart(2, "0")} / ${s.exercises.length}</span><h2 style="margin-top:8px">${E.byId(e.id).name}</h2></div><span class="badge">${e.low}–${e.high} REPS</span></div><small>${esc(e.reason)}</small><details><summary>Movement guide</summary><p>${esc(E.byId(e.id).guide)}</p></details><div class="settable heading"><span>SET</span><span>${p.unit.toUpperCase()}</span><span>REPS</span><span>RIR</span><span>DONE</span></div>${e.sets
          .map(
            (t, si) =>
              `<div class="settable"><span class="muted">${si + 1}</span>${[
                ["weight", t.weight, 0, 2000, 0.5],
                ["reps", t.reps, 1, 500, 1],
                ["rir", t.rir, 0, 10, 1],
              ]
                .map(
                  ([field, v, min, max, step]) =>
                    `<input type="number" inputmode="decimal" aria-label="${E.byId(e.id).name} set ${si + 1} ${field}" data-ex="${ei}" data-set="${si}" data-field="${field}" value="${v}" min="${min}" max="${max}" step="${step}" ${t.done ? "disabled" : ""}>`,
                )
                .join(
                  "",
                )}${button(t.done ? "✓" : "Log", "set", t.done ? "checked" : "", `data-ex="${ei}" data-set="${si}" aria-label="${t.done ? "Undo" : "Log"} ${E.byId(e.id).name} set ${si + 1}" aria-pressed="${t.done}"`)}</div>`,
          )
          .join("")}</section>`,
    )
    .join(
      "",
    )}</div><aside class="stack" style="align-content:start"><section class="card"><span class="eyebrow">Session progress</span><div class="number">${E.completedSets(s).length} / ${s.exercises.reduce((n, e) => n + e.sets.length, 0)} sets</div>${progress(
    E.completedSets(s).length,
    s.exercises.reduce((n, e) => n + e.sets.length, 0),
  )}<p>Only completed sets count. Bodyweight sets use 0 ${p.unit} of external load.</p>${button("Finish workout →", "finish", "primary", 'style="width:100%"')}<div class="actions">${button("Discard session", "discard", "danger quiet")}</div></section><section class="card"><h3>Keep a little in the tank.</h3><p>RIR 3 = about 3 more good reps possible. Your load suggestion adapts to reps and reserve, not just the biggest number you lifted.</p><small>Warm-up sets aren’t working sets. Take a few easier practice sets before logging your first working set.</small></section></aside></div>`;
}
function seasonAndTalents(p) {
  const {season, total, tier, claims} = E.seasonProgress(p);
  const streak = E.trainingStreak(p);
  const points = E.unspentPoints(p), ranks = p.ranks || {};
  return `<section class="card"><h2>${esc(season.name)}</h2><p>${esc(season.theme)}</p>
    <p>${fmt(total)} season XP · Tier ${tier} of 30</p>
    <details><summary>Season rewards</summary>${tiersFor(season.number).map(t => `<div class="listrow row"><span>Tier ${t.tier} · ${esc(t.reward.label)}</span>
    ${claims.includes(t.tier) ? "Claimed" : t.tier <= tier ? button("Claim tier "+t.tier,"claimTier","primary",'data-tier="'+t.tier+'"') : fmt(t.xp_required)+" XP"}</div>`).join("")}</details></section>
    <section class="card"><h2>Training streak</h2><p>${streak.current} days · Best ${streak.longest} · ${streak.freezes} available freezes</p></section><section class="card"><h2>Talents</h2><p>${points} unspent talent points</p>${TALENT_TREE.branches.map(branch => `<details><summary>${esc(branch.name)}</summary>${TALENT_TREE.nodes.filter(n => n.branch === branch.id).map(n => {
      const allowed = validateSpend(ranks, points, n.id);
      return `<div class="listrow"><h3>${esc(n.name)} · ${esc(ranks[n.id] || 0)}/${n.max_rank}</h3><p>${esc(n.description)}</p>${allowed.ok ? button("Spend one point","spendTalent","primary",'data-id="'+n.id+'"') : esc(allowed.error)}</div>`;
    }).join("")}</details>`).join("")}</section>`;
}
function progressPage() {
  const p = player(),
    s = E.stats(p),
    recent = p.sessions.slice(-8),
    vol = (w) => E.completedSets(w).reduce((n, t) => n + t.weight * t.reps, 0),
    max = Math.max(1, ...recent.map(vol));
  return `${heading("PROOF YOU’RE SHOWING UP", "Look how far you’ve come.", "Your own history is the benchmark that matters.")}<div class="cards">${stat("Training days", s.days, "Different days trained")}${stat("Working sets", s.sets, "Lifetime completed sets")}${stat("External volume", fmt(s.volume), p.unit + " × reps · not a score")}${stat("Character level", s.level, fmt(s.xp) + " total XP")}</div>${seasonAndTalents(p)}${recent.length ? `<section class="card" style="padding-bottom:48px"><h2>Recent external load volume</h2><small>Compare like-for-like sessions. Bodyweight difficulty and range of motion aren’t captured here.</small><div class="volumechart">${recent.map((w) => `<div class="bar" style="height:${Math.max(3, (vol(w) / max) * 100)}%" title="${esc(w.day)}: ${fmt(vol(w))} ${p.unit} × reps"><small>${esc(w.day.slice(5))}</small></div>`).join("")}</div></section>` : ""}<section class="card" style="margin-top:22px"><h2>Your training journal</h2>${
    p.sessions.length
      ? p.sessions
          .slice()
          .reverse()
          .map(
            (w) =>
              `<details class="listrow"><summary>${esc(w.name)} · ${esc(w.day)} · ${E.completedSets(w).length} sets · +${E.sessionXP(w)} XP</summary>${w.exercises
                .filter((e) => e.sets.some((t) => t.done))
                .map(
                  (e) =>
                    `<p class="historysets"><strong>${E.byId(e.id).name}</strong><br>${e.sets
                      .filter((t) => t.done)
                      .map(
                        (t) =>
                          `${fmt(t.weight)} ${p.unit} × ${t.reps} · ${t.rir} RIR`,
                      )
                      .join(" / ")}</p>`,
                )
                .join("")}</details>`,
          )
          .join("")
      : '<div class="empty"><div class="glyph">⌁</div><h3>Your future self will thank you.</h3><p>Finish your first session to start your training journal.</p>' +
        button("Start your journey →", "nav", "primary", 'data-tab="workout"') +
        "</div>"
  }</section>`;
}
function socialPage() {
  const p = player(),
    s = E.stats(p),
    week = E.weeklySessions(p),
    days = new Set(week.map((s) => s.day)).size;
  return `${heading("STRONGER TOGETHER", "Find your training party.", "Real friends. Shared consistency. A reason to show up for each other.")}<div class="grid"><div class="stack"><section class="card hero"><span class="eyebrow">WEEKLY PARTY QUEST</span><h2>Three days. One stronger party.</h2><p>Each party member aims to train on three different days this week. Every completed day is a step forward. The challenge resets on Monday.</p>${progress(days, 3)}<small>${days} / 3 training days · your contribution</small></section><section class="card"><h2>Your party this week</h2><p><small>Friends see your display name and aggregate training stats. These are self-reported logs, not independently verified results.</small></p><div class="listrow row"><div><h3>${esc(p.name)} <small>(you)</small></h3><small>Level ${s.level} · ${s.sessions} sessions</small></div><span class="lime">${days} / 3 days</span></div>${social ? social.friends.map((f) => `<div class="listrow row"><div><h3>${esc(f.name)}</h3><small>Level ${f.level} · ${f.sessions} sessions · ${f.weeklySets} sets this week</small></div><div><span class="lime">${f.weeklyDays} / 3 days</span><br>${button("Remove", "removeFriend", "quiet danger", `data-id="${esc(f.id)}"`)}</div></div>`).join("") : "<p>Loading party…</p>"}${social && !social.friends.length ? "<p>Your party is waiting to be formed. Share your friend code with someone you train with.</p>" : ""}</section>${social?.incoming.length ? `<section class="card"><h2>Party invitations</h2>${social.incoming.map((f) => `<div class="listrow row"><h3>${esc(f.name)}</h3><div class="actions">${button("Accept", "respond", "primary", `data-id="${esc(f.id)}" data-accept="true"`)}${button("Decline", "respond", "quiet", `data-id="${esc(f.id)}" data-accept="false"`)}</div></div>`).join("")}</section>` : ""}</div><aside class="stack"><section class="card"><span class="eyebrow purple">Your friend code</span><h2 class="readonlycode" style="font-size:20px;margin-top:16px;letter-spacing:2px">${esc(user.friend_code)}</h2><p>Share this code privately. A friend can send an invitation; you decide whether to accept.</p><div class="actions">${button("Copy invite link", "invite", "primary")}${button("Refresh party", "refresh", "quiet")}</div></section><section class="card"><h2>Add a friend</h2><form data-form="friend"><label>Friend code<input name="code" required maxlength="16" pattern="[a-fA-F0-9]{16}" placeholder="16-character code" autocomplete="off" value="${esc(new URLSearchParams(location.search).get("invite") || "")}"></label>${button("Send invitation →", "submit", "primary", 'type="submit"')}</form>${social?.outgoing.length ? `<p><small>${social.outgoing.length} invitation(s) awaiting acceptance.</small></p>` : ""}</section><section class="card"><h3>Your circle. Your choice.</h3><p>Your BatesAI account provides sign-in. Endgame friend codes build your party without importing your contacts or posting to your social feeds.</p><small>Workout detail and preferences stay private. No public global ranking, no pressure to lift beyond your ability.</small></section></aside></div>`;
}
function makePhases(goal, weeks) {
  const recipe = recipes[goal];
  const total = recipe.reduce((sum, row) => sum + Number(row[1]), 0);
  const phases = recipe.map(([name, share, reps, focus]) => ({
    name, weeks: Math.max(1, Math.floor(weeks * share / total)), reps, focus
  }));
  let remaining = weeks - phases.reduce((sum, p) => sum + p.weeks, 0);
  for (let i = 0; i < remaining; i++) phases[i % phases.length].weeks++;
  return phases;
}
function mesocycle() {
  const p = player();
  const phases = p.phases || makePhases("general", 12);
  const days = p.plan?.sessions.length || p.days;
  const total = phases.reduce((sum, phase) => sum + phase.weeks, 0) * days;
  const current = p.sessions.length % total;
  let end = 0;
  const active = phases.find(phase => current < (end += phase.weeks * days));
  return heading("Mesocycle", "Mesocycle Training", "Plan training phases and track your place in the cycle.") +
    `<section class="card"><h2>Current phase: ${esc(active.name)}</h2>${progress(current,total)}<p>Workout ${current} of ${total}</p></section>
    <form class="card" data-form="template"><h2>Start from a template</h2><label>Goal<select name="goal">${Object.keys(recipes).map(key => '<option value="'+key+'">'+esc(key === "fatLoss" ? "Fat loss" : key)+'</option>').join("")}</select></label><label>Cycle length in weeks<input name="weeks" type="number" min="4" max="24" step="2" value="12" required></label><button>Use template</button></form>
    <form class="card" data-form="phases"><h2>Your phases</h2>${phases.map(phase => `<fieldset><label>Phase name<input name="name" maxlength="60" value="${esc(phase.name)}" required></label><label>Weeks<input type="number" name="weeks" min="1" max="24" value="${phase.weeks}" required></label><label>Rep range<input name="reps" maxlength="30" value="${esc(phase.reps)}" required></label><label>Focus<input name="focus" maxlength="200" value="${esc(phase.focus)}"></label></fieldset>`).join("")}<button>Save phases</button></form>`;
}
function programPicker() {
  return `<section class="card"><h2>Pre-built programs</h2>${catalog.map((entry,i) => `<details class="listrow"><summary>${esc(entry.name)}</summary><p>${esc(entry.description)}</p>${entry.sessions.map(day => '<p><strong>'+esc(day.name)+'</strong> · '+esc(day.exercises.join(", "))+'</p>').join("")}<button data-action="useProgram" data-index="${i}">Use program</button></details>`).join("")}</section>
    <form class="card" data-form="custom"><h2>Build a custom program</h2><label>Program name<input required maxlength="80" name="name"></label><label>Workout days<textarea required rows="5" name="days" placeholder="Upper body: Bench Press, Pull-ups&#10;Lower body: Squats, Calf Raises"></textarea></label><details><summary>Available exercise names</summary><p>${E.availableMovements.map(e => esc(e.name)).join(", ")}</p></details><button>Use custom program</button></form>`;
}
function selectProgram(p, schedule) {
  if (p.active) throw Error("Finish or discard your active workout before changing programs.");
  const plan = E.makePlan({...p, schedule});
  p.schedule = schedule;
  p.plan = plan;
  persist();
  render();
}
function library() {
  const unit = player().unit;
  const bar = unit === "kg" ? 20 : 45;
  return heading("Tools", "Training tools", "Calculate plates per side or look up a movement.") +
    `<section class="card"><h2>Plate calculator</h2><label>Target weight (${esc(unit)})<input type="number" step="any" min="0" id="targetWeight"></label><label>Bar weight (${esc(unit)})<input type="number" step="any" min="0" id="barWeight" value="${bar}"></label><output id="plateResult" aria-live="polite"></output></section>
    <h2>Exercise guide</h2><label>Find an exercise<input id="search" placeholder="Exercise, muscle, or equipment" type="search"></label><div id="guides">${guides("")}</div>`;
}
function guides(query) {
  const list = nativeExercises.length ? nativeExercises : E.exercises.map(e => ({
    name: e.name, primary: [e.muscle], equipment: e.equipment, instructions: [e.guide]
  }));
  const matches = list.filter(e => [e.name, ...e.primary, e.equipment].join(" ").toLowerCase().includes(query.trim().toLowerCase()));
  return `<p>${matches.length} exercises</p>` + matches.map(e =>
    `<details class="listrow"><summary>${esc(e.name)}</summary><p>${esc(e.primary.join(", "))} · ${esc(e.equipment)}</p><ol>${e.instructions.map(line => "<li>" + esc(line) + "</li>").join("")}</ol></details>`
  ).join("");
}
function updatePlates() {
  const target = $("#targetWeight").valueAsNumber;
  const bar = $("#barWeight").valueAsNumber;
  const unit = player().unit;
  const output = $("#plateResult");
  if (!(target >= bar && bar >= 0)) {
    output.textContent = "Enter a target at or above the bar weight.";
    return;
  }
  let remaining = (target - bar) / 2;
  const plates = unit === "kg" ? [25,20,15,10,5,2.5,1.25] : [45,35,25,10,5,2.5];
  const parts = [];
  for (const plate of plates) {
    const count = Math.floor((remaining + 0.0001) / plate);
    if (count) parts.push(count + " × " + plate + " " + unit);
    remaining -= count * plate;
  }
  output.textContent = (parts.length ? "Per side: " + parts.join(", ") : "Bar only") +
    (remaining > 0.0001 ? ". Closest total: " + fmt(target - 2 * remaining) + " " + unit : "");
}
function settings() {
  const p = player();
  return `${heading("MAKE IT WORK FOR YOU", "Your setup. Your data.", "Preferences stay remembered across sessions and devices.")}<div class="two"><section class="card"><h2>Training preferences</h2>${preferencesForm(p, "preferences")}</section><div class="stack"><section class="card"><h2>Units & data</h2><label>External load unit<select id="unit"><option value="kg" ${p.unit === "kg" ? "selected" : ""}>Kilograms (kg)</option><option value="lb" ${p.unit === "lb" ? "selected" : ""}>Pounds (lb)</option></select></label><p>Changing units converts all stored loads and active sets.</p><div class="actions">${button("Export backup", "export", "primary")}${button("Import web backup", "import", "quiet")}${button("Export recovered device copy", "recovered", "quiet")}${button("Save to cloud now", "sync", "quiet")}</div><input type="file" id="importFile" accept="application/json,.json" hidden><p><small>Backups contain personal training data. Store them privately. Web backups restore to your BatesAI account. Mac backups use a separate format.</small></p></section><section class="card"><h2>BatesAI account</h2><p>Signed in as ${esc(user.display_name)}. Your shared BatesAI session lasts up to 30 days; Google or Apple may ask you to sign in again.</p>${button("Sign out", "logout", "quiet")}<p><small>Signing out keeps your device backup for recovery. Clearing site data removes device saves.</small></p></section><section class="card"><h2>Account deletion</h2><p>Delete your Endgame profile, cloud training log, friendships and current BatesAI session. This cannot be undone. Export a backup first.</p>${button("Delete my Endgame account", "deleteAccount", "quiet danger")}</section></div></div>`;
}
function render() {
  root.innerHTML = !user
    ? welcome()
    : !player()
      ? onboarding()
      : frame(
          (
            {
              home,
              workout,
              program,
              progress: progressPage,
              social: socialPage,
              mesocycle,
              library,
              settings,
            }[tab] || home
          )(),
        );
  if (user && player() && tab === "social" && !social) refreshSocial();
  tick();
}
async function refreshSocial() {
  try {
    social = await api("social");
    if (tab === "social") render();
  } catch (e) {
    social = { friends: [], incoming: [], outgoing: [] };
    notice(e.message);
    if (tab === "social") render();
  }
}
function download(content, name) {
  const url = URL.createObjectURL(
      new Blob([content], { type: "application/json" }),
    ),
    a = document.createElement("a");
  a.href = url;
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
function confirmAction(title, text, callback) {
  const d = document.createElement("dialog");
  d.innerHTML = `<h2>${esc(title)}</h2><p>${esc(text)}</p><div class="actions"><button data-ok class="danger">Confirm</button><button data-cancel>Cancel</button></div>`;
  document.body.append(d);
  d.querySelector("[data-cancel]").onclick = () => d.close();
  d.querySelector("[data-ok]").onclick = async () => {
    d.close();
    try {
      await callback();
    } catch (e) {
      notice(e.message);
    }
  };
  d.addEventListener("close", () => d.remove());
  d.showModal();
}
root.addEventListener("click", async (event) => {
  const b = event.target.closest("[data-action]");
  if (!b || b.disabled || (b.type === "submit" && b.closest("form"))) return;
  const p = player();
  try {
    switch (b.dataset.action) {
      case "useProgram": {
        const entry = catalog[Number(b.dataset.index)];
        const sessions = entry.sessions.map(day => ({ name: day.name,
          exercises: day.exercises.map(name => ({id: "catalog:" + name, sets: entry.sets, low: entry.low, high: entry.high, rest: 90})) }));
        selectProgram(p, {name: entry.name, sessions});
        break;
      }
      case "retry":
        await boot();
        break;
      case "nav":
        tab = b.dataset.tab;
        render();
        window.scrollTo(0, 0);
        break;
      case "start":
        if (!p.plan) p.plan = E.makePlan(p);
        p.recovery = Number($("#readiness")?.value || p.recovery || 3);
        E.startWorkout(p, p.recovery);
        persist();
        tab = "workout";
        render();
        window.scrollTo(0, 0);
        break;
      case "set": {
        if (
          ![...root.querySelectorAll("input[data-field]")].every((i) =>
            i.checkValidity(),
          )
        )
          throw Error("Correct invalid set values before logging.");
        const e = p.active.exercises[Number(b.dataset.ex)],
          s = e.sets[Number(b.dataset.set)];
        if (
          s.reps < 1 ||
          !Number.isInteger(s.reps) ||
          s.weight < 0 ||
          s.weight > 2000 ||
          s.rir < 0 ||
          s.rir > 10
        )
          throw Error("Enter valid load, repetitions, and RIR before logging.");
        s.done = !s.done;
        if (s.done) timerEnd = Date.now() + e.rest * 1000;
        persist();
        const y = window.scrollY;
        render();
        window.scrollTo(0, y);
        break;
      }
      case "skip":
        timerEnd = 0;
        render();
        break;
      case "finish": {
        const w = E.finishWorkout(p);
        timerEnd = 0;
        persist();
        tab = "home";
        render();
        window.scrollTo(0, 0);
        notice(
          `Workout saved. +${E.sessionXP(w)} XP. That’s another step forward.`,
        );
        break;
      }
      case "discard":
        confirmAction(
          "Discard this workout?",
          "Completed sets in this active workout will not enter your history.",
          () => {
            p.active = null;
            timerEnd = 0;
            persist();
            render();
          },
        );
        break;
      case "claimTier":
        notice(E.claimTier(p, Number(b.dataset.tier)));
        persist(); render(); break;
      case "spendTalent":
        E.spendTalent(p, b.dataset.id);
        persist(); render(); break;
      case "claim":
        E.claim(p, b.dataset.id);
        persist();
        render();
        notice("+75 XP · Quest complete.");
        break;
      case "sync":
        dirty = true;
        await sync();
        break;
      case "export":
        download(
          JSON.stringify(state, null, 2),
          "endgame-web-backup-" + E.dayKey() + ".json",
        );
        break;
      case "recovered": {
        const raw =
          localStorage.getItem(localKey() + ".recovery") ||
          localStorage.getItem(localKey());
        if (!raw) throw Error("No device recovery copy found.");
        download(raw, "endgame-device-recovery-" + E.dayKey() + ".json");
        break;
      }
      case "import":
        $("#importFile").click();
        break;
      case "invite": {
        const link =
          location.origin + "/endgamefitness/?invite=" + user.friend_code;
        try {
          await navigator.clipboard.writeText(link);
          notice("Invite link copied.");
        } catch {
          notice("Your friend code: " + user.friend_code);
        }
        break;
      }
      case "refresh":
        social = null;
        await refreshSocial();
        break;
      case "respond":
        await api("friends/respond", "POST", {
          id: b.dataset.id,
          accept: b.dataset.accept === "true",
        });
        await refreshSocial();
        break;
      case "removeFriend":
        confirmAction(
          "Remove this friend?",
          "Your aggregate training stats will no longer be shared with this player.",
          async () => {
            await api("friends/remove", "POST", { id: b.dataset.id });
            await refreshSocial();
          },
        );
        break;
      case "logout":
        await sync();
        if (dirty) {
          confirmAction(
            "Sign out with unsynced changes?",
            "Your device backup is kept. Export a backup if you want another copy.",
            async () => {
              await api("logout", "POST", {});
              user = null;
              localStorage.removeItem(E.key + ".last");
              render();
            },
          );
        } else {
          await api("logout", "POST", {});
          user = null;
          localStorage.removeItem(E.key + ".last");
          state = E.fresh();
          render();
        }
        break;
      case "deleteAccount":
        confirmAction(
          "Permanently delete your Endgame account?",
          "All cloud training data, invitations, friendships and sessions will be removed. This action cannot be undone.",
          async () => {
            await api("account", "DELETE", { confirm: "DELETE" });
            clearTimeout(saveTimer);
            localStorage.removeItem(localKey());
            localStorage.removeItem(E.key);
            localStorage.removeItem(E.key + ".last");
            user = null;
            state = E.fresh();
            dirty = false;
            render();
            notice("Your Endgame account has been deleted.");
          },
        );
        break;
    }
  } catch (e) {
    notice(e.message);
  }
});
root.addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.target,
    data = new FormData(form),
    p = player();
  try {
    if (form.dataset.form === "template") {
      p.phases = makePhases(data.get("goal"), Number(data.get("weeks")));
      persist(); render(); return;
    }
    if (form.dataset.form === "phases") {
      p.phases = data.getAll("name").map((name,i) => ({ name, weeks: Number(data.getAll("weeks")[i]), reps: data.getAll("reps")[i], focus: data.getAll("focus")[i] }));
      persist(); render(); return;
    }
    if (form.dataset.form === "custom") {
      const sessions = data.get("days").trim().split(/\r?\n/).map(line => {
        const [name, names] = line.split(":");
        if (!names) throw Error("Use one day per line: day name followed by a colon and exercises.");
        const exercises = names.split(",").map(text => {
          const e = E.availableMovements.find(item => item.name.toLowerCase() === text.trim().toLowerCase());
          if (!e) throw Error("Unknown exercise: " + text);
          return {id: e.id, sets: 3, low: 8, high: 12, rest: 90};
        });
        return {name: name.trim(), exercises};
      });
      selectProgram(p, {name: data.get("name").trim(), sessions}); return;
    }
    if (["create", "preferences"].includes(form.dataset.form)) {
      if (p?.active)
        throw Error(
          "Finish or discard your active workout before rebuilding your plan.",
        );
      const prefs = E.newPlayer(
        String(data.get("name")),
        String(data.get("goal")),
        String(data.get("equipment")),
        Number(data.get("days")),
        Number(data.get("minutes")),
      );
      prefs.assessment = Object.fromEntries(assessmentFields.map(([key]) => [key, Number(data.get(key))]));
      prefs.assessment.experience = data.get("experience");
      prefs.assessment.accepted = Boolean(p?.assessment?.accepted || data.has("accepted"));
      if (!p) {
        prefs.id = user.id;
        prefs.plan = E.makePlan(prefs);
        state = { version: 1, selected: user.id, players: [prefs], rivals: [] };
      } else {
        for (const k of ["name", "goal", "equipment", "days", "minutes", "assessment"])
          p[k] = prefs[k];
        p.plan = E.makePlan(p);
      }
      persist();
      render();
      notice("Your training preferences are saved.");
    } else if (form.dataset.form === "friend") {
      await api("friends", "POST", { code: data.get("code") });
      form.reset();
      await refreshSocial();
      notice("Invitation sent. Your friend can accept it in their party.");
    }
  } catch (e) {
    notice(e.message);
  }
});
root.addEventListener("input", (event) => {
  const t = event.target,
    p = player();
  if (["targetWeight", "barWeight"].includes(t.id)) updatePlates();
  if (t.id === "search") {
    $("#guides").innerHTML = guides(t.value);
    return;
  }
  if (t.dataset.field && p?.active) {
    const value = Number(t.value),
      limits = { weight: [0, 2000], reps: [1, 500], rir: [0, 10] },
      [min, max] = limits[t.dataset.field];
    if (
      t.value === "" ||
      !Number.isFinite(value) ||
      value < min ||
      value > max ||
      (t.dataset.field !== "weight" && !Number.isInteger(value))
    ) {
      t.setCustomValidity(
        `Enter ${min}–${max}${t.dataset.field === "weight" ? "" : " as a whole number"}.`,
      );
      t.reportValidity();
      return;
    }
    t.setCustomValidity("");
    p.active.exercises[+t.dataset.ex].sets[+t.dataset.set][t.dataset.field] =
      value;
    persist();
  }
});
root.addEventListener("change", async (event) => {
  const t = event.target,
    p = player();
  try {
    if (t.id === "unit" && t.value !== p.unit) {
      const factor = t.value === "lb" ? 2.2046226218 : 1 / 2.2046226218;
      for (const s of [...p.sessions, ...(p.active ? [p.active] : [])])
        for (const e of s.exercises)
          for (const set of e.sets)
            set.weight = Math.round(set.weight * factor * 100) / 100;
      p.unit = t.value;
      persist();
      notice("All logged and active loads converted.");
    }
    if (t.id === "importFile" && t.files[0]) {
      const file = t.files[0];
      if (file.size > 3000000) throw Error("Backup exceeds the 3 MB limit.");
      let incoming = JSON.parse(await file.text());
      if (incoming.state) incoming = incoming.state;
      incoming = E.validateState(incoming);
      if (incoming.players.length !== 1)
        throw Error("Import a single-player web backup.");
      confirmAction(
        "Restore this web backup?",
        "This replaces the training data in your current BatesAI account. Export your current data first.",
        () => {
          const imported = incoming.players[0];
          imported.id = user.id;
          state = {
            version: 1,
            selected: user.id,
            players: [imported],
            rivals: [],
          };
          persist();
          tab = "home";
          render();
          notice("Backup restored. Saving to your account.");
        },
      );
    }
  } catch (e) {
    notice(e.message);
  }
});
function tick() {
  const c = $("#countdown");
  if (c) {
    const sec = Math.max(0, Math.ceil((timerEnd - Date.now()) / 1000));
    c.textContent = `${Math.floor(sec / 60)}:${String(sec % 60).padStart(2, "0")}`;
    if (sec === 0) {
      timerEnd = 0;
      const t = $(".timer");
      if (t) t.hidden = true;
    }
  }
}
setInterval(tick, 1000);
window.addEventListener("online", () => {
  notice("You’re back online. Syncing your progress.");
  sync();
});
window.addEventListener("beforeunload", (e) => {
  if (storageIssue && dirty) {
    e.preventDefault();
    e.returnValue = "";
  }
});
boot();
