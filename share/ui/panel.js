'use strict';
/* panel.js — The Merge Goblin's control panel.
 *
 * Two rules hold this file together, and both are structural rather than
 * conventional:
 *
 *  1. No HTML string ever exists. Every node is built with el() and every
 *     untrusted value lands in .textContent. There is no escaping function to
 *     forget to call, because there is no place a value could be parsed as
 *     markup. PR titles, repo slugs, GitHub logins, provider notes, doctor
 *     details and failure reasons are all attacker-supplied in practice —
 *     anyone who can open a PR in a watched repo can choose that text.
 *
 *  2. No inline handlers and no untrusted href. Listeners are attached with
 *     addEventListener over the already-parsed value, and links are opened by
 *     asking the host app (openURL), which re-validates the scheme. So a
 *     javascript: or data: URL never reaches an attribute at all.
 *
 * The transport is the native bridge, not HTTP: no session token, no polling.
 * The app pushes state into window.__goblin._state() whenever ~/.goblin changes.
 */
(function () {

  /* =====================================================================
   * 1. bridge — window.goblin.call(cmd, argsObject) -> Promise<reply>
   * ===================================================================== */

  const handler =
    (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.goblin) || null;
  const MOCK = !handler;

  function normalizeReply(raw) {
    let r = raw;
    if (typeof r === 'string') {
      try { r = JSON.parse(r); } catch (_e) { return { ok: true, data: raw }; }
    }
    if (!r || typeof r !== 'object') return { ok: true, data: r };
    if (typeof r.ok !== 'boolean') r = Object.assign({}, r, { ok: !r.error });
    if (!r.ok && (!r.error || typeof r.error !== 'object')) {
      r = Object.assign({}, r, { error: { code: 'unknown', message: String(r.error || 'failed') } });
    }
    return r;
  }

  async function call(cmd, args) {
    const payload = {
      v: 1,
      cmd: String(cmd),
      // always an object: the Swift side reads named keys, and an array would
      // silently decode as nothing
      args: (args && typeof args === 'object' && !Array.isArray(args)) ? args : {},
    };
    try {
      const reply = await (MOCK ? mockCall(payload) : handler.postMessage(payload));
      const r = normalizeReply(reply);
      if (r.state) applyState(r.state);
      return r;
    } catch (e) {
      return { ok: false, error: { code: 'bridge', message: String((e && e.message) || e) } };
    }
  }

  window.goblin = window.goblin || {};
  window.goblin.call = call;

  /* ---- state pushes from the app ------------------------------------- */
  let booted = false;
  let queuedPush = null;

  window.__goblin = window.__goblin || {};
  window.__goblin._state = function (obj) {
    let raw = obj;
    if (typeof raw === 'string') {
      try { raw = JSON.parse(raw); } catch (_e) { return; }
    }
    // An array is `typeof "object"` but is not a state blob; letting one through
    // normalises to {} and silently blanks the whole panel.
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return;
    if (!booted) { queuedPush = raw; return; }
    applyState(raw);
  };

  /* The menu's "Settings… / Set-up wizard… / Health check…" items call this
   * (WebPanel.request(view:)). The view name is a Swift literal, but treat it as
   * input anyway: an unknown value scrolls nowhere rather than throwing. */
  window.__goblin._open = function (arg) {
    const view = lower(obj(arg).view);
    const target = view === 'health' ? 'h-health'
      : view === 'wizard' ? 'wizard'
        : view === 'settings' ? 'h-behaviour' : '';
    if (view === 'wizard') { startWizard({ complete: false }); return; }
    const node = target ? $(target) : null;
    if (node && typeof node.scrollIntoView === 'function') {
      node.scrollIntoView({ block: 'start', behavior: 'smooth' });
    }
  };

  /* =====================================================================
   * 2. DOM kit
   * ===================================================================== */

  const $ = (id) => document.getElementById(id);
  const str = (v) => (v == null ? '' : String(v));
  const lower = (v) => str(v).toLowerCase();

  const SAFE_HOSTS = /^(github\.com|[a-z0-9-]+\.githubusercontent\.com)$/i;

  // Only ever used for attributes we set ourselves; untrusted URLs go through
  // openURL instead of becoming an attribute.
  function isSafeUrl(u) {
    const s = str(u);
    if (!s || s.startsWith('//')) return false;
    if (!/^[a-z][a-z0-9+.-]*:/i.test(s)) return true;      // relative, same origin
    try {
      const url = new URL(s);
      return url.protocol === 'https:' && SAFE_HOSTS.test(url.host);
    } catch (_e) { return false; }
  }

  /* el(tag, {cls, text, attrs, on}, children)
   * The only DOM constructor in the panel. It refuses event-handler attributes
   * and style attributes outright, and validates href/src, so a careless call
   * site cannot reintroduce an injection sink. */
  function el(tag, opts, children) {
    const node = document.createElement(tag);
    const o = opts || {};
    if (o.cls) node.className = o.cls;
    if (o.text != null) node.textContent = str(o.text);
    if (o.attrs) {
      for (const key of Object.keys(o.attrs)) {
        const v = o.attrs[key];
        if (v == null || v === false) continue;
        const k = key.toLowerCase();
        if (k.indexOf('on') === 0 || k === 'style' || k === 'srcdoc') continue;
        if ((k === 'href' || k === 'src') && !isSafeUrl(v)) continue;
        node.setAttribute(key, v === true ? '' : str(v));
      }
    }
    if (o.on) {
      for (const ev of Object.keys(o.on)) {
        if (typeof o.on[ev] === 'function') node.addEventListener(ev, o.on[ev]);
      }
    }
    const kids = children == null ? [] : (Array.isArray(children) ? children : [children]);
    for (const kid of kids) {
      if (kid == null || kid === false) continue;
      node.appendChild(kid instanceof Node ? kid : document.createTextNode(str(kid)));
    }
    return node;
  }

  const fill = (id, nodes) => {
    const host = $(id);
    if (!host) return;
    host.replaceChildren.apply(host, [].concat(nodes).filter((n) => n));
  };
  const setText = (id, v) => { const n = $(id); if (n) n.textContent = str(v); };

  /* =====================================================================
   * 3. formatting
   * ===================================================================== */

  const TITLE_MAX = 140;

  // matches Pattern.searchQuery on the Swift side: ^[A-Za-z0-9 ._/-]{0,80}$
  const searchable = (v) => str(v).replace(/[^A-Za-z0-9 ._/-]/g, '').trim().slice(0, 80);

  // Pattern.repoSlug. Search results are GitHub-supplied, so they get checked
  // against the same rule the bridge uses instead of a loose "has a slash" test.
  const SLUG_RE = /^[A-Za-z0-9._-]{1,100}\/[A-Za-z0-9._-]{1,100}$/;
  const isSlug = (v) => SLUG_RE.test(str(v));

  function truncate(v, n) {
    const s = str(v).replace(/\s+/g, ' ').trim();
    const max = n || TITLE_MAX;
    return s.length > max ? s.slice(0, max - 1) + '…' : s;
  }

  const num = (v, fallback) => {
    const n = typeof v === 'number' ? v : parseFloat(v);
    return Number.isFinite(n) ? n : fallback;
  };

  function clampInt(v, min, max, fallback) {
    let n = Math.round(num(v, NaN));
    if (!Number.isFinite(n)) n = fallback;
    return Math.min(max, Math.max(min, n));
  }

  // The CLI writes epoch seconds; tolerate milliseconds in case a newer writer
  // switches, so a timestamp never renders as 1970.
  function ms(v) {
    const n = num(v, 0);
    if (!n) return 0;
    return n < 1e11 ? n * 1000 : n;
  }

  const money = (v) => '$' + (Math.round(num(v, 0) * 100) / 100).toFixed(2);
  const clock = (t) => new Date(t).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  const stamp = (t) => new Date(t).toLocaleString([], {
    month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit',
  });

  function ago(t) {
    const secs = Math.round((Date.now() - t) / 1000);
    if (secs < 0) return 'just now';
    if (secs < 90) return secs + 's ago';
    const mins = Math.round(secs / 60);
    if (mins < 90) return mins + ' min ago';
    const hrs = Math.round(mins / 60);
    if (hrs < 36) return hrs + 'h ago';
    return Math.round(hrs / 24) + 'd ago';
  }

  /* =====================================================================
   * 4. state
   * ===================================================================== */

  let S = null;             // normalized snapshot
  let raw = null;           // last raw push, for diagnostics
  let doctorResult = null;  // structured JSON from the doctor verb
  let accounts = null;      // lazily fetched
  let accountsOpen = false;
  // The pushed state carries no provider list — it comes from the providers
  // verb — so it has to survive every state push instead of being reset to [].
  let providerCache = [];
  /* Flags the panel has itself saved successfully, consulted ONLY when the pushed
   * state says nothing at all about that key.
   *
   * ui_state_write projects a fixed list of settings, so a newly added flag is
   * writable (config + setFlag) before it is reported back. Without this, turning
   * such a switch off would spend a click, save correctly, and then be sprung back
   * to the build default by the next 5-second push — a switch that lies about the
   * config, which is exactly what this panel exists to stop. The push always wins
   * the moment it carries an opinion. */
  const savedFlags = {};

  const obj = (v) => (v && typeof v === 'object' && !Array.isArray(v) ? v : {});
  const arr = (v) => (Array.isArray(v) ? v : []);
  const has = (v) => Object.keys(obj(v)).length > 0;
  // first non-empty candidate; every state read goes through one of these so a
  // missing or renamed key degrades instead of throwing
  const firstArr = function () {
    for (let i = 0; i < arguments.length; i += 1) {
      if (Array.isArray(arguments[i]) && arguments[i].length) return arguments[i];
    }
    return [];
  };
  const firstObj = function () {
    for (let i = 0; i < arguments.length; i += 1) {
      if (has(arguments[i])) return arguments[i];
    }
    return {};
  };
  // booleans default to on, matching the CLI's "!== false" convention
  const flagOn = function () {
    for (let i = 0; i < arguments.length; i += 1) {
      if (arguments[i] !== undefined) return arguments[i] !== false;
    }
    return true;
  };

  /* `provider list --json` rows, mapped once. The cache holds the RAW rows so
   * this stays idempotent: mapping an already-mapped row would look at `state`,
   * not find it, and quietly decide nothing is ready. */
  function mapProviders(list, providerId) {
    return arr(list).map((p) => {
      const o = obj(p);
      const id = str(o.id || o.name || '');
      const ready = o.state === 'ready' || (o.available === true && o.authed === true);
      const state = lower(o.state);
      // "installed but not logged in" and "not installed at all" need entirely
      // different advice, so they are kept apart instead of collapsing into one
      // "not ready". `provider list --json` carries the booleans; the mock and
      // older writers only carry the display string, so both are read. When
      // neither says, assume it IS installed: offering a sign-in command for
      // something already on the machine is a smaller mistake than telling
      // someone to reinstall a CLI they have.
      const available = o.available !== undefined
        ? o.available === true
        : !/missing|not installed|not found/.test(state);
      const authed = o.authed !== undefined ? o.authed === true : ready;
      return {
        id,
        ready,
        available,
        authed,
        label: o.state
          ? str(o.state)
          : (o.available === false ? 'missing' : (o.authed === false ? 'no auth' : 'unknown')),
        detail: str(o.detail || o.note || ''),
        costKnown: o.costKnown,
        // the configured id wins: the provider list is fetched and cached
        // independently of the state file, so its own `current` flag can be
        // stale, and two rows claiming to be current makes the cost note lie
        current: providerId !== '' ? id === providerId : o.current === true,
      };
    }).filter((p) => p.id);
  }

  /* The documented push payload is
   *     { v:1, status: <uistate.json>, inbox: <inbox.json>, app: {...} }
   * (StateStore.pushPayload). Note what that does NOT contain: a `config`
   * object, a provider list, or a review history. So every setting is read as
   * "config if a config ever appears, else the flattened uistate", the provider
   * list is kept from the providers verb, and the history is synthesised from
   * lastReview + recentFailures when no list is supplied.
   *
   * ui_state_write is being extended right now, so no key is assumed present. */
  function normalizeState(input) {
    const s = obj(input);
    const status = has(s.status) ? obj(s.status) : s;   // tolerate a flattened blob
    const config = firstObj(s.config, status.config);
    const app = obj(s.app);

    // One setting, three plausible homes, in precedence order: the config blob if
    // one is ever pushed, then the flattened uistate, then a `settings` object
    // (newer keys such as skipIfHumanReviewed are surfaced as status.settings.*).
    const settings = firstObj(config.settings, status.settings);
    const cfg = (key) => (config[key] !== undefined ? config[key]
      : (status[key] !== undefined ? status[key] : settings[key]));

    const providerId = str(obj(status.provider).id || cfg('provider') || '');
    const providers = mapProviders(firstArr(s.providers, status.providers, providerCache), providerId);

    // inbox.json is pushed as its own key; uistate may also carry rolled-up
    // counts (status.inbox.waiting / .mine / .stale) with no PR list at all
    const inboxRaw = firstObj(s.inbox, status.inbox);
    const inboxCounts = firstObj(obj(inboxRaw).counts, obj(status.inbox));
    const prs = firstArr(inboxRaw.prs, inboxRaw.items, inboxRaw.pulls);

    const notify = firstObj(config.notify, status.notify);
    const flagsObj = firstObj(config.flags, status.flags);
    /* One boolean, read from every home in precedence order. Extra legacy homes
     * (notify.started and friends) are passed in by the caller and sit ahead of
     * savedFlags, which is only reached when nothing in the push has an opinion. */
    const flag = function (key) {
      const homes = [cfg(key), flagsObj[key]];
      for (let i = 1; i < arguments.length; i += 1) homes.push(arguments[i]);
      homes.push(savedFlags[key]);
      return flagOn.apply(null, homes);
    };
    const intervalMinutes = (() => {
      const direct = num(cfg('intervalMinutes'), NaN);
      if (Number.isFinite(direct) && direct > 0) return Math.round(direct);
      const secs = num(cfg('intervalSeconds'), NaN);
      if (Number.isFinite(secs) && secs > 0) return Math.max(1, Math.round(secs / 60));
      return 15;
    })();

    // No events list is pushed. Show what the state does carry rather than an
    // empty section: the last posted review plus the recent failures.
    const history = (() => {
      const supplied = firstArr(s.history, s.events, status.history, status.events);
      if (supplied.length) return supplied;
      const rows = [];
      const last = obj(status.lastReview);
      if (num(last.number, 0) > 0) {
        rows.push({
          at: last.at, number: last.number, title: last.title,
          url: last.url, status: 'posted',
        });
      }
      for (const f of arr(status.recentFailures)) {
        const o = obj(f);
        rows.push({ at: o.at, number: o.number, reason: o.reason, status: 'failed' });
      }
      return rows.sort((a, b) => num(b.at, 0) - num(a.at, 0));
    })();

    return {
      status,
      config,
      providers,
      provider: providers.find((p) => p.current) || null,
      providerId,
      history,
      home: str(app.home || s.home || status.home || ''),
      goblin: obj(status.goblin),
      // absent means "assume the install is fine": trapping a month-old user in
      // a first-run wizard is far worse than never showing it
      setupComplete: app.setupComplete !== undefined
        ? app.setupComplete !== false
        : obj(status.setup).complete !== false,
      cliConfigured: app.cliConfigured !== false,
      appVersion: str(app.version || ''),
      identity: obj(status.identity),
      agent: obj(status.agent),
      reviews: obj(status.reviews),
      spend: obj(status.spendUsd || status.spend),
      recentFailures: arr(status.recentFailures),
      // attempts_stuck_json: PRs that have failed maxAttempts times and will not
      // be retried — invisible until now, which is how "nothing happens" felt
      // like a mystery instead of a fact
      stuck: arr(status.stuck),
      doctorBadge: obj(status.doctor),
      // Which settings the state actually reported. Showing a default as though
      // it were the live value is the same class of lie as the old power switch.
      reported: {
        verdict: cfg('verdictMode') !== undefined,
        limits: cfg('maxReviewsPerRun') !== undefined || cfg('maxFindings') !== undefined,
        schedule: cfg('intervalSeconds') !== undefined || cfg('intervalMinutes') !== undefined,
        notifications: has(notify) || has(flagsObj),
      },
      stateName: lower(status.state || 'idle'),
      pausedReason: lower(status.pausedReason || ''),
      activity: str(status.activity || ''),
      lastRunFinished: ms(status.lastRunFinished),
      nextRunEstimate: ms(status.nextRunEstimate || status.nextRun),
      snoozeUntil: ms(cfg('snoozeUntil')),
      enabled: flagOn(cfg('enabled')),
      repos: arr(cfg('repos')).map((r) => {
        const o = obj(r);
        return { slug: str(o.slug || o.name || r), enabled: o.enabled !== false };
      }).filter((r) => r.slug),
      fleet: arr(cfg('fleet')).map((f) => str(obj(f).login || f)).filter((f) => f),
      inbox: {
        prs,
        counts: inboxCounts,
        stale: obj(status.inbox).stale === true,
        refreshedAt: ms(inboxRaw.refreshedAt || inboxRaw.at || inboxRaw.checkedAt),
        error: str(inboxRaw.error || ''),
      },
      limits: {
        // 0 = unlimited. The dollar cap this replaces could never fire on codex
        // or cursor, which report no cost at all.
        perDay: clampInt(cfg('maxReviewsPerDay'), 0, 500, 0),
        perRun: clampInt(cfg('maxReviewsPerRun'), 1, 50, 5),
        findings: clampInt(cfg('maxFindings'), 1, 200, 25),
      },
      intervalMinutes,
      verdictMode: str(cfg('verdictMode') || 'comment'),
      allowApprove: cfg('allowApprove') === true,
      // every flag has several plausible homes while the config shape settles: a
      // top-level key, a settings object, a flags object, the legacy notify
      // object, and last of all whatever this panel itself saved
      flags: {
        incrementalReview: flag('incrementalReview'),
        // absent everywhere means ON, which is the CLI default and the cautious
        // reading: never spend quota on a PR a human has already reviewed
        skipIfHumanReviewed: flag('skipIfHumanReviewed'),
        postCommitStatus: flag('postCommitStatus'),
        fleetAssignment: flag('fleetAssignment'),
        notifyStarted: flag('notifyStarted', notify.started),
        notifyPosted: flag('notifyPosted', notify.posted),
        notifyFailed: flag('notifyFailed', notify.failed),
        notifyBudget: flag('notifyBudget', notify.budget),
        notifySound: flag('notifySound', notify.sound),
      },
      // null = unknown, so the switch can sit indeterminate instead of claiming
      // "off" for something we were never told about
      loginItem: (() => {
        const v = app.loginItem !== undefined ? app.loginItem
          : (s.loginItem !== undefined ? s.loginItem
            : (status.loginItem !== undefined ? status.loginItem : cfg('loginItem')));
        return v === undefined ? null : v === true;
      })(),
      model: str(obj(obj(cfg('providers'))[providerId]).model || obj(status.provider).model || ''),
    };
  }

  function applyState(input) {
    raw = input;
    try {
      S = normalizeState(input);
    } catch (e) {
      pushError('panel could not read the Goblin\'s state', String((e && e.message) || e));
      return;
    }
    render();
  }

  /* ---- the single precedence chain ----------------------------------
   * The old panel derived on/off/paused from three sources and could show the
   * switch ON, a pill saying "paused" and a hint about the schedule all at
   * once. Everything below reads this one function. */
  function derive() {
    const now = Date.now();
    const off = S.agent.disabled === true || S.enabled === false
      || S.stateName === 'disabled' || S.stateName === 'off';

    if (off) {
      return {
        key: 'off', tone: 'off', label: 'off duty', on: false,
        hint: 'switched off — stays off across restarts',
        actions: [{ id: 'turnOn', text: 'Turn on', primary: true }],
      };
    }
    if (S.stateName === 'error') {
      return {
        key: 'error', tone: 'bad', label: 'error', on: true,
        hint: S.activity || 'the last run could not finish',
        actions: [{ id: 'doctor', text: 'Run checks' }],
      };
    }
    if (S.stateName === 'reviewing') {
      return {
        key: 'reviewing', tone: 'busy', label: 'reviewing', on: true,
        hint: S.activity || 'a review is running right now',
        actions: [{ id: 'pause', text: 'Pause' }],
      };
    }
    if (S.snoozeUntil > now || S.stateName === 'snoozed') {
      const until = S.snoozeUntil > now ? ' until ' + clock(S.snoozeUntil) : '';
      return {
        key: 'snoozed', tone: 'warn', label: 'snoozed', on: true,
        hint: 'quiet' + until + ' — nothing is reviewed meanwhile',
        actions: [{ id: 'wake', text: 'Wake up now', primary: true }],
      };
    }
    if (S.stateName === 'paused') {
      const quota = /budget|quota|cap|limit/.test(S.pausedReason);
      return {
        key: quota ? 'quota' : 'paused',
        tone: 'warn',
        label: quota ? 'daily cap reached' : 'paused',
        on: true,
        hint: quota
          ? 'today\'s review cap is used up — it resets at midnight'
          : 'paused' + (S.pausedReason ? ' (' + S.pausedReason + ')' : ''),
        actions: quota
          ? [{ id: 'raiseCap', text: 'Raise the cap' }, { id: 'resume', text: 'Resume', primary: true }]
          : [{ id: 'resume', text: 'Resume', primary: true }],
      };
    }
    if (S.agent.running === false) {
      return {
        key: 'unscheduled', tone: 'warn', label: 'not scheduled', on: true,
        hint: 'on duty, but nothing is waking it up',
        actions: [{ id: 'startAgent', text: 'Start the schedule', primary: true }],
      };
    }
    return {
      key: 'on', tone: 'on', label: 'on duty', on: true,
      hint: 'checks every ' + S.intervalMinutes + ' min for review requests',
      actions: [{ id: 'pause', text: 'Pause' }],
    };
  }

  /* =====================================================================
   * 5. chrome: toast, confirm, errors
   * ===================================================================== */

  let toastTimer = 0;
  function toast(msg, bad) {
    const t = $('toast');
    if (!t) return;
    t.textContent = str(msg);
    t.classList.toggle('bad', !!bad);
    t.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => t.classList.remove('show'), 3200);
  }

  /* Copy a short string to the clipboard.
   *
   * There is no bridge verb for this on purpose: `copyDiagnostics` copies a blob
   * the app builds itself, and adding a "copy this arbitrary text" verb would
   * hand the web layer the pasteboard. So it happens in-page.
   *
   * The panel is served over goblin://, which is NOT a secure context, so
   * navigator.clipboard is usually absent — hence the execCommand path. Both are
   * best-effort: the command is always rendered as selectable text as well, so a
   * failure here is an inconvenience, never a dead end. Returns a Promise<bool>. */
  function copyText(text) {
    const s = str(text);
    if (!s) return Promise.resolve(false);

    function legacy() {
      try {
        if (typeof document.execCommand !== 'function' || !document.body) return false;
        const pad = el('input', { attrs: { type: 'text', 'aria-hidden': 'true', tabindex: '-1' }, cls: 'offscreen' });
        pad.value = s;
        document.body.appendChild(pad);
        if (typeof pad.focus === 'function') pad.focus();
        if (typeof pad.select === 'function') pad.select();
        if (typeof pad.setSelectionRange === 'function') pad.setSelectionRange(0, s.length);
        const ok = document.execCommand('copy') === true;
        if (typeof pad.remove === 'function') pad.remove();
        else if (pad.parent && typeof pad.parent.removeChild === 'function') pad.parent.removeChild(pad);
        return ok;
      } catch (_e) { return false; }
    }

    const nav = typeof navigator !== 'undefined' ? navigator : null;
    const api = nav && nav.clipboard;
    if (api && typeof api.writeText === 'function') {
      try {
        return Promise.resolve(api.writeText(s)).then(() => true, () => legacy());
      } catch (_e) { return Promise.resolve(legacy()); }
    }
    return Promise.resolve(legacy());
  }

  function confirmAsk(o) {
    const box = $('confirm');
    const yes = $('confirmYes');
    const no = $('confirmNo');
    if (!box || !yes || !no) return Promise.resolve(false);
    setText('confirmTitle', o.title);
    setText('confirmBody', o.body || '');
    yes.textContent = o.yes || 'Do it';
    yes.classList.toggle('danger', o.tone === 'danger');
    box.hidden = false;
    const prev = document.activeElement;
    yes.focus();
    return new Promise((resolve) => {
      function done(v) {
        box.hidden = true;
        yes.removeEventListener('click', onYes);
        no.removeEventListener('click', onNo);
        document.removeEventListener('keydown', onKey, true);
        if (prev && typeof prev.focus === 'function') prev.focus();
        resolve(v);
      }
      function onYes() { done(true); }
      function onNo() { done(false); }
      function onKey(e) {
        if (e.key === 'Escape') { e.preventDefault(); done(false); }
        if (e.key === 'Tab') {
          e.preventDefault();
          (document.activeElement === yes ? no : yes).focus();
        }
      }
      yes.addEventListener('click', onYes);
      no.addEventListener('click', onNo);
      document.addEventListener('keydown', onKey, true);
    });
  }

  const transientErrors = [];
  function pushError(title, detail) {
    transientErrors.length = 0;
    transientErrors.push({ title: str(title), detail: str(detail) });
    renderBanners();
  }

  /* =====================================================================
   * 6. actions
   * ===================================================================== */

  const inflight = new Set();

  // Runs a verb with the clicked control disabled, so a slow verb cannot be
  // double-fired, without the old global lock that swallowed every other click.
  async function act(node, cmd, args, opts) {
    const o = opts || {};
    if (node) {
      if (node.dataset.busy === '1') return { ok: false, error: { code: 'busy', message: 'busy' } };
      node.dataset.busy = '1';
      node.disabled = true;
      node.setAttribute('aria-busy', 'true');
    }
    try {
      const r = await call(cmd, args);
      if (r.ok) {
        transientErrors.length = 0;
        if (!o.quiet) toast(o.done || 'done');
      } else {
        const e = obj(r.error);
        const msg = str(e.message || e.code || 'that did not work');
        if (!o.quiet) toast(msg, true);
        if (e.code === 'bridge') pushError('lost contact with the Goblin', msg);
      }
      return r;
    } finally {
      if (node) {
        delete node.dataset.busy;
        node.disabled = false;
        node.removeAttribute('aria-busy');
      }
    }
  }

  /* A PR "url" is GitHub-supplied data that also passes through the state file,
   * so treat it as hostile. Swift refuses anything that is not https, and this
   * is the second gate: a link that cannot be opened is never even rendered as
   * something clickable (see renderInbox / renderHistory). Host is deliberately
   * NOT restricted here — GitHub Enterprise lives on its own domain — only the
   * scheme is, which is what kills javascript: and data:. */
  function isOpenable(u) {
    const s = str(u);
    if (!s) return false;
    try { return new URL(s).protocol === 'https:'; } catch (_e) { return false; }
  }

  async function openLink(url) {
    if (!isOpenable(url)) { toast('that link is not a normal https link', true); return; }
    const r = await call('openURL', { url: str(url) });
    if (!r.ok) toast('could not open that link', true);
  }

  async function runPowerAction(id, node) {
    if (id === 'turnOn') {
      const ok = await confirmAsk({
        title: 'Put the Goblin back on duty?',
        body: 'It starts reviewing the PRs waiting on you, which spends your own '
          + 'AI subscription quota right away.',
        yes: 'Turn on',
      });
      if (!ok) return;
      await act(node, 'power', { on: true }, { done: 'on duty' });
      return;
    }
    if (id === 'pause') { await act(node, 'pause', {}, { done: 'paused' }); return; }
    if (id === 'resume') { await act(node, 'resume', {}, { done: 'back on duty' }); return; }
    if (id === 'wake') { await act(node, 'snooze', { kind: 'clear' }, { done: 'awake' }); return; }
    if (id === 'startAgent') { await act(node, 'agent', { action: 'start' }, { done: 'schedule started' }); return; }
    if (id === 'fixAccount') { await act(node, 'fixAccount', {}, { done: 'switched' }); return; }
    if (id === 'doctor') { await runDoctor(node, false); return; }
    if (id === 'raiseCap') {
      const current = S ? S.limits.perDay : 0;
      const next = clampInt((current || 10) + 10, 1, 500, 20);
      const ok = await confirmAsk({
        title: 'Raise today\'s cap?',
        body: 'Reviews per day goes from ' + (current || 'no cap') + ' to ' + next
          + ', and the Goblin goes straight back to work. That spends more of your quota.',
        yes: 'Raise and resume',
      });
      if (!ok) return;
      const r = await act(node, 'setMaxReviewsPerDay', { value: next }, { quiet: true });
      if (r.ok) await act(node, 'resume', {}, { done: 'cap raised, back on duty' });
      return;
    }
  }

  async function runDoctor(node, fix) {
    fill('doctorList', el('div', { cls: 'empty', text: fix ? 'fixing…' : 'checking…' }));
    const r = await act(node, 'doctor', { fix: !!fix }, { quiet: true });
    if (!r.ok) {
      doctorResult = null;
      fill('doctorList', el('div', { cls: 'empty', text: str(obj(r.error).message || 'checks could not run') }));
      return;
    }
    // structured JSON, so there is no ✓/!/✗ text to scrape any more
    const d = obj(r.data);
    doctorResult = {
      pass: num(d.pass, 0), warn: num(d.warn, 0), fail: num(d.fail, 0),
      checks: arr(d.checks).map((c) => {
        const o = obj(c);
        return {
          status: lower(o.status || 'ok'),
          name: str(o.name || o.check || ''),
          detail: str(o.detail || ''),
          fix: str(o.fix || ''),
        };
      }),
    };
    renderDoctor();
    toast(fix ? 'fixed what could be fixed' : 'checks done');
  }

  /* =====================================================================
   * 7. render
   * ===================================================================== */

  function render() {
    if (!S) return;
    const d = derive();
    renderHeader(d);
    renderBanners(d);
    renderPower(d);
    renderInbox();
    renderActivity();
    renderProviders();
    renderLimits();
    renderRepos();
    renderBehaviour();
    renderNotifications();
    renderDoctor();
    renderHistory();
    renderAccount();
    const version = str(S.goblin.version || S.appVersion);
    setText('foot', [
      str(S.goblin.name || 'The Merge Goblin'),
      version ? 'v' + version : '',
      S.home,
    ].filter((x) => x).join(' · '));
  }

  function renderHeader(d) {
    setText('appName', S.goblin.name || 'The Merge Goblin');
    setText('stateTx', d.label);
    const dot = $('dot');
    if (dot) dot.className = 'dot ' + d.tone;
    const who = str(S.identity.login);
    const line = S.activity
      || (d.key === 'on' && S.providerId
        ? 'reviewing as @' + (who || '?') + ' with ' + S.providerId
        : d.hint);
    setText('activity', truncate(line, 90));
    const pill = $('statePill');
    if (pill) pill.setAttribute('title', truncate(d.hint, 120));
  }

  function bannerNode(o) {
    return el('div', { cls: 'banner ' + (o.tone || '') }, [
      el('span', { cls: 'ic', text: o.icon || '⚠️', attrs: { 'aria-hidden': 'true' } }),
      el('span', { cls: 'grow' }, [
        el('b', { text: o.title }),
        o.detail ? el('span', { cls: 'hint', text: o.detail }) : null,
        o.actions && o.actions.length
          ? el('span', { cls: 'acts' }, o.actions.map((a) =>
            el('button', {
              cls: 'small' + (a.primary ? ' primary' : ''),
              text: a.text,
              attrs: { type: 'button' },
              on: { click: (ev) => a.run(ev.currentTarget) },
            })))
          : null,
      ]),
      // Dismissal is visual and per-session only: no verb is called, no config
      // is touched, and reopening the panel brings the banner back if the
      // problem is still there. See dismiss().
      typeof o.dismiss === 'function'
        ? el('button', {
          cls: 'x', text: '×',
          attrs: { type: 'button', 'aria-label': 'Dismiss: ' + str(o.title), title: 'hide this until it changes' },
          on: { click: () => o.dismiss() },
        })
        : null,
    ]);
  }

  /* ---- per-session banner dismissal ----------------------------------
   * A dismissal keyed on nothing at all would be undone by the next 5-second
   * state push, so each of these holds ONE signature of what was dismissed. A
   * changed signature is a different problem and shows again; the same
   * signature is the same problem and stays hidden.
   *
   * Single-slot rather than a growing set, because "until the agent state
   * flips" has to mean off -> on -> off shows the banner again. */
  let dismissedFailures = '';   // newest failure: count + number + timestamp
  let dismissedAgentKey = '';   // derive().key of the not-working banner

  function failureSignature() {
    let newest = -1;
    let which = '';
    for (const f of S.recentFailures) {
      const o = obj(f);
      const at = ms(o.at);
      if (at >= newest) { newest = at; which = str(o.number || '?') + '@' + at; }
    }
    return S.recentFailures.length + ':' + which;
  }

  function renderBanners(derived) {
    const d = derived || (S ? derive() : null);
    const errs = [];
    const notes = [];

    if (MOCK) {
      const ribbon = $('mockRibbon');
      if (ribbon) ribbon.hidden = false;
    }

    for (const t of transientErrors) {
      errs.push(bannerNode({ title: t.title, detail: t.detail, icon: '⛔' }));
    }

    if (S) {
      if (d && d.key === 'error') {
        errs.push(bannerNode({
          title: 'The last run failed',
          detail: S.activity || 'run the checks to see why',
          icon: '⛔',
          actions: [{ text: 'Run checks', run: (n) => runDoctor(n, false) }],
        }));
      }

      // Failures used to be written to state and never shown anywhere. Reviews
      // could fail every single run with nothing on screen.
      const failSig = S.recentFailures.length ? failureSignature() : '';
      if (!failSig) dismissedFailures = '';
      if (failSig && dismissedFailures !== failSig) {
        errs.push(bannerNode({
          title: S.recentFailures.length === 1 ? 'A review failed' : S.recentFailures.length + ' recent reviews failed',
          detail: S.recentFailures.map((f) => {
            const o = obj(f);
            return '#' + str(o.number || '?') + ' ' + truncate(o.reason || 'unknown reason', 70);
          }).join(' · '),
          icon: '⛔',
          dismiss: () => { dismissedFailures = failSig; renderBanners(); },
        }));
      }

      if (S.stuck.length) {
        errs.push(bannerNode({
          title: S.stuck.length === 1 ? 'A pull request is stuck' : S.stuck.length + ' pull requests are stuck',
          detail: S.stuck.map((x) => {
            const o = obj(x);
            return '#' + str(o.number || '?') + ' ' + str(o.kind || 'failed')
              + (o.msg ? ' — ' + truncate(o.msg, 60) : '')
              + ' after ' + num(o.attempts, 0) + ' tries';
          }).join(' · '),
          icon: '⛔',
          actions: [{ text: 'Run checks', run: (n) => runDoctor(n, false) }],
        }));
      }

      if (S.providers.length && !S.providers.some((p) => p.ready)) {
        errs.push(bannerNode({
          title: 'No usable AI CLI',
          detail: 'nothing can review until one of them is installed and logged in',
          icon: '⛔',
          actions: [{ text: 'Re-check', run: (n) => act(n, 'providers', { refresh: true }, { done: 'checked' }) }],
        }));
      }

      if (S.identity.ok === false) {
        notes.push(bannerNode({
          title: 'GitHub account mismatch',
          detail: 'your active account is ' + (str(S.identity.ghActive) || '?')
            + ', the Goblin reviews as ' + (str(S.identity.login) || '?')
            + '. Reviews still work — this only affects your own terminal.',
          tone: 'warn', icon: '👤',
          actions: [{ text: 'Switch', run: (n) => runPowerAction('fixAccount', n) }],
        }));
      }

      if (!S.repos.length) {
        notes.push(bannerNode({
          title: 'No repositories yet',
          detail: 'add one below and the Goblin starts watching for review requests',
          tone: 'warn', icon: '📁',
        }));
      }

      // Rather than presenting a default as the live value, say which settings
      // this CLI build does not report. Clears itself once it does.
      const unreported = Object.keys(S.reported).filter((k) => S.reported[k] === false);
      if (unreported.length) {
        notes.push(bannerNode({
          title: 'Some settings are not reported yet',
          detail: unreported.join(', ') + ' show this build\'s defaults until the CLI '
            + 'includes them in its state. Changing one still saves.',
          tone: 'info', icon: 'ℹ️',
        }));
      }

      const notWorking = d && (d.key === 'off' || d.key === 'quota' || d.key === 'paused'
        || d.key === 'unscheduled' || d.key === 'snoozed') ? d.key : '';
      // the state moved on, so an old dismissal no longer applies — including a
      // move away and back, which is a fresh occurrence of the same problem
      if (dismissedAgentKey && dismissedAgentKey !== notWorking) dismissedAgentKey = '';
      if (notWorking && dismissedAgentKey !== notWorking) {
        notes.push(bannerNode({
          title: d.key === 'off' ? 'The Goblin has left his post'
            : d.key === 'unscheduled' ? 'Nothing is waking the Goblin up'
              : d.key === 'snoozed' ? 'Snoozing' : 'Not reviewing right now',
          detail: d.hint,
          tone: d.key === 'snoozed' ? 'info' : 'warn',
          icon: d.key === 'off' ? '⏻' : '⏸',
          actions: d.actions.map((a) => ({
            text: a.text, primary: a.primary, run: (n) => runPowerAction(a.id, n),
          })),
          // the switch and the pill still say so — this only hides the banner,
          // and only until the state changes
          dismiss: () => { dismissedAgentKey = notWorking; renderBanners(); },
        }));
      }
    }

    fill('errors', errs);
    fill('banners', notes);
  }

  function renderPower(d) {
    setChk('power', d.on);
    setText('powerHint', d.hint);

    fill('powerActions', d.actions
      .filter((a) => a.id !== 'pause' || d.key === 'on' || d.key === 'reviewing')
      .map((a) => el('button', {
        cls: 'small' + (a.primary ? ' primary' : ''),
        text: a.text,
        attrs: { type: 'button' },
        on: { click: (ev) => runPowerAction(a.id, ev.currentTarget) },
      })));

    const snoozed = S.snoozeUntil > Date.now();
    const clear = $('clearSnooze');
    if (clear) clear.hidden = !snoozed;
    setText('snoozeHint', snoozed
      ? 'quiet until ' + clock(S.snoozeUntil)
      : 'temporarily stop, then resume by itself');

    setText('nextRun', nextRunText(d));
  }

  function nextRunText(d) {
    if (d.key === 'off') return 'nothing is scheduled while the Goblin is off';
    if (d.key === 'reviewing') return 'a review is running now';
    const now = Date.now();
    let next = S.nextRunEstimate;
    if (!next && S.lastRunFinished) next = S.lastRunFinished + S.intervalMinutes * 60000;
    if (d.key === 'snoozed' && S.snoozeUntil > now) {
      return 'next check after ' + clock(S.snoozeUntil);
    }
    if (!next) return 'next check within ' + S.intervalMinutes + ' min';
    if (next <= now) return 'next check due now';
    const mins = Math.round((next - now) / 60000);
    return 'next check ' + clock(next) + (mins <= 90 ? ' (in ' + Math.max(1, mins) + ' min)' : '');
  }

  /* ---- awaiting review ---------------------------------------------- */

  const INBOX_ROWS_MAX = 25;

  /* inbox.sh classifies each PR as draft | not_ours | reviewed |
   * reviewed_by_other | blocked | assigned_elsewhere | waiting.
   *
   * Only `waiting` belongs under a heading that says "Awaiting review". The old
   * list rendered every state it was given with a badge, so a section whose whole
   * job is "what still needs you" was padded out with drafts, PRs a teammate
   * owns, and PRs already reviewed — and the count came from a different source
   * than the rows, so the number and the list disagreed.
   *
   * A missing state means an older inbox.json that never had the field, and is
   * read as waiting. An UNRECOGNISED state is also read as waiting: silently
   * hiding a review request is the one failure mode worse than showing a row
   * that did not need to be there. The substring tests below mean a future
   * `reviewed_by_bot` still lands in a reviewed bucket rather than the list. */
  function inboxState(p, myLogin) {
    const o = obj(p);
    const s = lower(o.state || o.status || o.kind || '');
    const assignee = str(o.assignee || o.assignedTo || o.claimedBy || o.owner || '');
    const mine = inboxMine(o, myLogin);

    if (s) {
      if (/draft/.test(s)) return 'draft';
      if (/not_ours|not ours/.test(s)) return 'not_ours';
      // by_other before the plain reviewed test, or the prefix would swallow it
      if (/by_other|by other|by_teammate|reviewed_by/.test(s)) return 'reviewed_by_other';
      if (/reviewed|posted|done|complete/.test(s)) return 'reviewed';
      if (/blocked|stuck|failed|error/.test(s)) return 'blocked';
      if (/elsewhere|teammate|assigned_to_other|claimed/.test(s)) return 'assigned_elsewhere';
      if (/skip|ignored|dismissed/.test(s)) return 'not_ours';
      return 'waiting';
    }
    // no state field at all: fall back to the flags an older file did carry
    if (o.reviewed === true) return 'reviewed';
    if (o.draft === true) return 'draft';
    if (assignee !== '' && !mine) return 'assigned_elsewhere';
    return 'waiting';
  }

  /* Only ever asked about rows that are already `waiting`. An unassigned PR with
   * no `mine` field is counted as yours, which is what inbox.sh means by
   * waiting: it only reaches that state for a PR the fleet gave to you. */
  function inboxMine(o, myLogin) {
    const assignee = str(o.assignee || o.assignedTo || o.claimedBy || o.owner || '');
    if (o.mine === true || o.assignedToMe === true) return true;
    if (assignee !== '' && myLogin !== '' && lower(assignee) === lower(myLogin)) return true;
    return o.mine === undefined && o.assignedToMe === undefined && assignee === '';
  }

  function renderInbox() {
    const myLogin = str(S.identity.login);
    const items = S.inbox.prs;
    const counts = S.inbox.counts;

    const rows = [];
    const other = {
      draft: 0, reviewed: 0, reviewed_by_other: 0, blocked: 0, assigned_elsewhere: 0, not_ours: 0,
    };
    /* "why is this one not being reviewed" is the question this section actually
     * gets asked, and inbox.sh answers it per PR: a `reviewed_by_other` row
     * carries a reason like "reviewed by flexipie", a `blocked` row carries the
     * failure. Keep the distinct reasons per bucket so the summary can name one
     * outright, and every reason so the tooltip can name them all.
     *
     * Reasons are GitHub-supplied text (a login, a failure string) reaching us
     * through a state file, so they are truncated and only ever land in
     * textContent or a title attribute — never anything parsed as markup. */
    const reasons = {};
    const whyLines = [];
    for (const p of items) {
      const state = inboxState(p, myLogin);
      if (state === 'waiting') { rows.push(p); continue; }
      other[state] = (other[state] || 0) + 1;
      const o = obj(p);
      const why = truncate(o.reason || o.note || o.detail || '', 60);
      if (!why) continue;
      const list = reasons[state] || (reasons[state] = []);
      if (list.indexOf(why) < 0 && list.length < 6) list.push(why);
      if (whyLines.length < 8) whyLines.push('#' + str(o.number || o.pr || '?') + ' ' + why);
    }

    /* The headline number is the length of the list under it, never a count from
     * somewhere else — the rolled-up counts in uistate.json can be a run behind,
     * and "7 waiting" over two rows is worse than no number at all. The counts
     * are only trusted when there is no list to disagree with. */
    const listed = items.length > 0;
    const waiting = listed ? rows.length : clampInt(counts.waiting, 0, 9999, 0);
    setText('inboxWaiting', waiting);
    setText('inboxMine', listed
      ? rows.filter((p) => inboxMine(obj(p), myLogin)).length
      : clampInt(counts.mine, 0, 9999, 0));

    if (!rows.length) {
      fill('inboxList', el('div', {
        cls: 'empty',
        text: S.inbox.error ? truncate(S.inbox.error, 120)
          : (!listed && waiting > 0
            ? waiting + ' waiting at the last check — refresh to list them'
            : 'nothing is waiting on you right now'),
      }));
    } else {
      const shown = rows.slice(0, INBOX_ROWS_MAX);
      const nodes = shown.map((p) => {
        const o = obj(p);
        const number = str(o.number || o.pr || '?');
        const repo = str(o.repo || o.nameWithOwner || o.slug || '');
        const url = str(o.url || o.htmlUrl || o.html_url || '');
        const author = str(o.author || '');
        const label = '#' + number + ' ' + truncate(o.title, 60) + (repo ? ' in ' + repo : '');
        const body = el('span', { cls: 'item' }, [
          el('span', { cls: 'num', text: '#' + number }),
          el('span', { cls: 'grow' }, [
            el('span', { cls: 'ttl', text: truncate(o.title, TITLE_MAX) || '(no title)' }),
            el('span', {
              cls: 'sub',
              text: [repo, author ? 'by ' + truncate(author, 24) : ''].filter((x) => x).join(' — '),
            }),
          ]),
          el('span', { cls: 'badge warn', text: 'waiting' }),
        ]);
        // no openable link => not a button. Nothing to click, nothing to route.
        if (!isOpenable(url)) return el('span', { cls: 'block' }, body);
        return el('button', {
          cls: 'link',
          attrs: { type: 'button', 'aria-label': 'Open ' + label },
          on: { click: () => openLink(url) },
        }, body);
      });
      // truncation is disclosed rather than silent, so the count still matches
      // what the section says about itself
      if (rows.length > shown.length) {
        nodes.push(el('div', {
          cls: 'empty',
          text: 'and ' + (rows.length - shown.length) + ' more waiting — open GitHub to see them all',
        }));
      }
      fill('inboxList', nodes);
    }

    // Everything that is deliberately NOT a row. Counted from the list when it
    // carries them, and from the rolled-up counts once inbox.json narrows `prs`
    // to waiting only.
    /* One distinct reason for a bucket beats the generic label: "1 reviewed by
     * flexipie" answers the question outright. A reason that starts with the same
     * word as the label replaces it rather than being appended, so nobody reads
     * "reviewed by a teammate (reviewed by flexipie)". */
    const named = (state, base) => {
      const list = reasons[state] || [];
      if (list.length !== 1) return base;
      const why = list[0];
      const head = (v) => lower(v).split(/[^a-z]+/).filter((x) => x)[0] || '';
      return head(why) === head(base) ? why : base + ' (' + why + ')';
    };
    // [count, singular, plural] — a third entry only where the plural differs
    const summary = [
      [other.draft || clampInt(counts.drafts, 0, 9999, 0), 'draft', 'drafts'],
      [other.reviewed || clampInt(counts.reviewed, 0, 9999, 0), named('reviewed', 'already reviewed')],
      [other.reviewed_by_other || clampInt(counts.reviewedByOther, 0, 9999, 0),
        named('reviewed_by_other', 'reviewed by a teammate')],
      [other.blocked || clampInt(counts.blocked, 0, 9999, 0), named('blocked', 'blocked')],
      [other.assigned_elsewhere || clampInt(counts.assignedElsewhere, 0, 9999, 0),
        named('assigned_elsewhere', 'with a teammate')],
    ].filter((x) => x[0] > 0).map((x) => x[0] + ' ' + (x[0] === 1 ? x[1] : (x[2] || x[1])));
    setText('inboxOther', summary.length ? 'not listed: ' + summary.join(' · ') : '');
    // and the per-PR detail as a tooltip, so several different reasons are not
    // flattened into one summary phrase
    const otherNode = $('inboxOther');
    if (otherNode) {
      if (summary.length && whyLines.length) otherNode.setAttribute('title', whyLines.join(' · '));
      else otherNode.removeAttribute('title');
    }

    const checked = S.inbox.refreshedAt ? 'checked ' + ago(S.inbox.refreshedAt) : '';
    setText('inboxMeta', S.inbox.stale
      ? (checked ? checked + ' — out of date, refresh to ask GitHub again' : 'out of date — refresh to ask GitHub')
      : (checked || (rows.length ? '' : 'refresh to ask GitHub now')));
  }

  /* ---- activity ------------------------------------------------------ */

  function renderActivity() {
    setText('rToday', num(S.reviews.today, 0));
    setText('rTotal', num(S.reviews.total, 0));

    // Two of the three providers report no cost at all, so a dollar figure of
    // $0.00 would be a lie rather than a number. Say so instead.
    const tracked = !(S.provider && S.provider.costKnown === false);
    if (tracked) {
      setText('sToday', money(S.spend.today));
      setText('sTotal', money(S.spend.total));
      setText('costNote', 'dollars are informational — the real limit is reviews per day');
    } else {
      setText('sToday', '—');
      setText('sTotal', '—');
      setText('costNote', (S.providerId || 'this provider')
        + ' does not report cost — reviews per day is the real cap');
    }

    setText('lastRun', S.lastRunFinished
      ? 'last checked ' + ago(S.lastRunFinished)
      : 'hasn\'t run yet');
  }

  /* ---- providers ----------------------------------------------------- */

  /* What to actually DO about a provider that cannot review yet.
   *
   * Hardcoded here, and deliberately NOT read out of the probe JSON. That JSON
   * carries a `note` which frequently contains the very command a user needs —
   * and it is provider-controlled text that reaches the panel through a state
   * file. A command a human is invited to paste into their shell is the one
   * string that must never come from data, so this table is the only source.
   *
   * None of these can be run for the user: `claude` opens a browser and then
   * waits on a TTY, `codex login` and `cursor-agent login` do the same. Running
   * them from a menu bar app would hang on a prompt nobody can see, so the panel
   * hands over the command and says so. */
  const PROVIDER_HELP = {
    claude: {
      signIn: 'claude',
      signInNote: 'run it once, then follow the browser prompt it opens',
      installUrl: 'https://claude.com/claude-code',
    },
    codex: { signIn: 'codex login', install: 'npm i -g @openai/codex' },
    cursor: { signIn: 'cursor-agent login', install: 'curl https://cursor.com/install -fsS | bash' },
  };

  /* A model picker beats a text field because the exact string matters: a typo
   * used to be saved happily and only turned up as a failed review. Short lists
   * on purpose — these are suggestions, and Custom… covers everything else. */
  const MODEL_CHOICES = {
    claude: ['', 'sonnet', 'opus', 'haiku'],
    codex: ['', 'gpt-5.6-sol', 'o4-mini'],
    // ids verified against `cursor-agent models`. The list here was previously
    // guessed, and the guesses were not ids cursor knows — so choosing one saved
    // happily and only failed later, at review time, as an opaque provider error.
    cursor: ['cursor-grok-4.5-high', 'claude-4.5-sonnet-thinking', 'gpt-5.3-codex', 'composer-2.5', ''],
  };
  /* Sentinel for the Custom… option. Provably impossible as a real model name:
   * the bridge's pattern is ^[A-Za-z0-9._:-]{0,64}$, which has no underscore, so
   * this can never collide with something a user could actually save. */
  const CUSTOM_MODEL = '__custom__';
  let customModelOpen = false;

  function recheckProviders(node) {
    return act(node, 'providers', { refresh: true }, { quiet: true }).then((r) => {
      if (r.ok && r.data) mergeProviders(r.data);
      toast(r.ok ? 'providers re-checked' : str(obj(r.error).message || 'could not re-check'), !r.ok);
      return r;
    });
  }

  // one copy button, used by every command the panel shows
  function copyButton(text, what) {
    return el('button', {
      cls: 'small', text: 'Copy',
      attrs: { type: 'button', 'aria-label': 'Copy the ' + what + ' command' },
      on: {
        click: async (ev) => {
          const node = ev.currentTarget;
          node.disabled = true;
          const ok = await copyText(text);
          node.disabled = false;
          toast(ok ? 'copied — paste it into a terminal'
            : 'could not reach the clipboard — select the command and copy it', !ok);
        },
      },
    });
  }

  /* The block under a provider that is not usable. Before this, the card said
   * "no auth" and stopped there: a dead end with no way forward.
   *
   * `after` is handed the Re-check reply. The main panel needs nothing (its own
   * render is driven by mergeProviders) but the wizard keeps a private copy of
   * the list and has to be told, or its Re-check would silently do nothing. */
  function providerHelp(p, after) {
    const help = PROVIDER_HELP[p.id] || {};
    const signIn = !p.available ? '' : str(help.signIn);
    const install = p.available ? '' : str(help.install);
    const command = signIn || install;
    const url = p.available ? '' : str(help.installUrl);

    const lead = p.available
      ? 'installed, but not signed in. The panel cannot sign in for you — '
        + p.id + ' opens a browser and waits on a terminal prompt, so run this yourself:'
      : (command
        ? 'not installed. The panel cannot install it for you — run this yourself:'
        : (url
          ? 'not installed. The panel cannot install it for you — the instructions are here:'
          : 'not installed, and the panel cannot install it for you — see that CLI\'s own docs.'));
    const lines = [el('span', { cls: 'hint', text: lead })];

    if (command) {
      lines.push(el('span', { cls: 'cmd' }, [
        el('code', { cls: 'mono grow', text: '$ ' + command }),
        copyButton(command, p.available ? 'sign-in' : 'install'),
      ]));
    }
    if (signIn && help.signInNote) lines.push(el('span', { cls: 'hint', text: help.signInNote }));
    // shown as text as well as behind the button: a link nobody can read is not
    // much better than no link
    if (url) lines.push(el('span', { cls: 'hint mono', text: url }));

    const acts = [el('button', {
      cls: 'small', text: 'Re-check',
      attrs: { type: 'button', 'aria-label': 'Re-check ' + p.id },
      on: {
        click: (ev) => recheckProviders(ev.currentTarget).then((r) => {
          if (typeof after === 'function') after(r);
        }),
      },
    })];
    if (url) {
      acts.unshift(el('button', {
        cls: 'small', text: 'Open the install page',
        attrs: { type: 'button' },
        on: { click: () => openLink(url) },
      }));
    }
    lines.push(el('span', { cls: 'acts' }, acts));

    return el('div', { cls: 'prov-help' }, lines);
  }

  function renderProviders() {
    if (!S.providers.length) {
      fill('provs', el('div', { cls: 'empty', text: 'no AI CLIs found' }));
    } else {
      const nodes = [];
      for (const p of S.providers) {
        const id = 'prov-' + p.id;
        const input = el('input', {
          attrs: {
            type: 'radio', name: 'provider', id,
            checked: p.current, disabled: !p.ready,
            'aria-describedby': id + '-meta',
          },
          on: {
            change: (ev) => {
              if (!ev.currentTarget.checked) return;
              act(ev.currentTarget, 'setProvider', { id: p.id }, { done: p.id + ' will do the reviewing' });
            },
          },
        });
        nodes.push(el('label', {
          cls: 'prov' + (p.current ? ' sel' : '') + (p.ready ? '' : ' dead'),
          attrs: { for: id },
        }, [
          input,
          el('span', { cls: 'grow' }, [
            el('span', { cls: 'nm', text: p.id }),
            el('span', {
              cls: 'meta', text: p.detail ? p.label + ' · ' + truncate(p.detail, 60) : p.label,
              attrs: { id: id + '-meta' },
            }),
          ]),
          p.ready ? null : el('span', { cls: 'badge', text: p.label }),
        ]));
        // the help sits OUTSIDE the label: a <button> inside a <label for=...>
        // would toggle the radio as well as run its own handler
        if (!p.ready) nodes.push(providerHelp(p));
      }
      fill('provs', nodes);
    }

    renderModelPicker();
  }

  function renderModelPicker() {
    const sel = $('modelSelect');
    const input = $('model');
    const row = $('modelCustomRow');
    const id = S.providerId;
    const model = S.model;

    const choices = (MODEL_CHOICES[id] || ['']).slice();
    // A model that is already configured but not on the list must never be
    // silently replaced by whatever the select happens to land on, so it becomes
    // an option of its own.
    if (model && choices.indexOf(model) < 0) choices.push(model);

    if (sel) {
      const sig = id + '|' + choices.join(',');
      if (sel.dataset.modelSig !== sig) {
        sel.dataset.modelSig = sig;
        customModelOpen = false;
        fill('modelSelect', choices.map((m) => el('option', {
          text: m === '' ? 'the CLI\'s default' : m,
          attrs: { value: m },
        })).concat([el('option', { text: 'Custom…', attrs: { value: CUSTOM_MODEL } })]));
      }
      // never move the picker while someone is using it
      if (document.activeElement !== sel && !customModelOpen) sel.value = model;
    }
    if (row) row.hidden = !customModelOpen;
    if (input) {
      input.placeholder = 'a model name ' + (id || 'that CLI') + ' accepts';
      if (!customModelOpen) setVal('model', model);
    }
    setText('modelHint', id
      ? 'blank lets ' + id + ' pick its own default'
      : 'pick a provider first');
  }

  // what Save should send: the picker's value, or the box when Custom… is chosen
  function chosenModel() {
    const sel = $('modelSelect');
    const input = $('model');
    if (sel && sel.value === CUSTOM_MODEL) return input ? str(input.value).trim() : '';
    if (sel && sel.value !== undefined && sel.value !== null) return str(sel.value).trim();
    return input ? str(input.value).trim() : '';
  }

  async function saveModel(node) {
    const id = S ? S.providerId : '';
    if (!id) { toast('pick a provider first', true); return; }
    const input = $('model');
    const model = chosenModel();
    // the arg is named `provider` (Command.swift), and the model must match
    // ^[A-Za-z0-9._:-]{0,64}$ or the whole call is refused
    if (!/^[A-Za-z0-9._:-]{0,64}$/.test(model)) {
      toast('model names can only use letters, numbers . _ : -', true);
      if (input) input.classList.add('bad');
      return;
    }
    if (input) input.classList.remove('bad');
    const r = await act(node, 'setProviderModel', { provider: id, model }, { quiet: true });
    if (!r.ok) {
      toast(str(obj(r.error).message || 'could not save the model'), true);
      // put the picker back on what the config actually says, so it cannot sit
      // there showing a model that was never saved
      renderModelPicker();
      return;
    }
    dirty.delete('model');
    // it is a saved model now, so it belongs in the list rather than in the box
    customModelOpen = false;
    if (S) S.model = model;
    renderModelPicker();
    toast(model ? 'model saved: ' + model : 'using ' + id + '\'s own default');
  }

  /* ---- limits -------------------------------------------------------- */

  function renderLimits() {
    setVal('capDay', S.limits.perDay);
    setVal('maxRun', S.limits.perRun);
    setVal('maxFind', S.limits.findings);
    setVal('interval', S.intervalMinutes);
  }

  /* ---- repos --------------------------------------------------------- */

  function renderRepos() {
    if (!S.repos.length) {
      fill('repos', el('div', { cls: 'empty', text: 'none yet' }));
      return;
    }
    fill('repos', S.repos.map((r, i) => {
      const id = 'repo-' + i;
      return el('div', { cls: 'row' }, [
        el('label', { cls: 'grow lbl', attrs: { for: id } },
          el('span', { cls: 'label mono ell', text: r.slug })),
        el('span', { cls: 'switch' }, [
          el('input', {
            attrs: { type: 'checkbox', id, checked: r.enabled, 'aria-label': 'Watch ' + r.slug },
            on: {
              // {slug, on}: Command.swift refuses an unknown argument name
              // outright, so "enabled" here would be a silent dead toggle
              change: (ev) => act(ev.currentTarget, 'repoEnable',
                { slug: r.slug, on: ev.currentTarget.checked },
                { done: r.slug + (ev.currentTarget.checked ? ' watched' : ' ignored') }),
            },
          }),
          el('span', { cls: 'slider', attrs: { 'aria-hidden': 'true' } }),
        ]),
        el('button', {
          cls: 'small danger', text: 'Remove',
          attrs: { type: 'button', 'aria-label': 'Remove ' + r.slug },
          on: { click: (ev) => act(ev.currentTarget, 'repoRemove', { slug: r.slug }, { done: r.slug + ' removed' }) },
        }),
      ]);
    }));
  }

  /* ---- behaviour ----------------------------------------------------- */

  function renderBehaviour() {
    setVal('verdict', S.verdictMode);
    setText('verdictHint', S.verdictMode === 'comment'
      ? 'reviews post as comments — the Goblin never approves or blocks'
      : S.verdictMode === 'request-changes'
        ? 'the Goblin can formally request changes under your account'
        : 'the Goblin may approve — that counts as YOUR approval on GitHub');

    setChk('fIncr', S.flags.incrementalReview);
    setChk('fSkipReviewed', S.flags.skipIfHumanReviewed);
    setChk('fCommit', S.flags.postCommitStatus);
    setChk('fFleet', S.flags.fleetAssignment);

    if (!S.fleet.length) {
      fill('fleet', el('div', { cls: 'empty', text: 'just you — teammates are added with the CLI' }));
    } else {
      fill('fleet', S.fleet.map((who) => el('span', { cls: 'tag' }, [
        el('span', { cls: 'who', text: '@' + who }),
      ])));
    }
  }

  function renderNotifications() {
    setChk('nStart', S.flags.notifyStarted);
    setChk('nPost', S.flags.notifyPosted);
    setChk('nFail', S.flags.notifyFailed);
    setChk('nBudget', S.flags.notifyBudget);
    setChk('nSound', S.flags.notifySound);
  }

  /* ---- doctor -------------------------------------------------------- */

  function renderDoctor() {
    if (!doctorResult) {
      const badge = S ? S.doctorBadge : {};
      const at = ms(badge.at);
      setText('doctorSummary', at
        ? 'last checked ' + ago(at) + ' — ' + num(badge.fail, 0) + ' failures, ' + num(badge.warn, 0) + ' warnings'
        : '');
      const host = $('doctorList');
      if (host && !host.childElementCount) {
        fill('doctorList', el('div', { cls: 'empty', text: 'run the checks to see how things look' }));
      }
      return;
    }
    setText('doctorSummary', doctorResult.pass + ' passed · ' + doctorResult.warn
      + ' warnings · ' + doctorResult.fail + ' failures');
    if (!doctorResult.checks.length) {
      fill('doctorList', el('div', { cls: 'empty', text: 'no checks reported' }));
      return;
    }
    fill('doctorList', doctorResult.checks.map((c) => {
      const cls = c.status === 'ok' ? 'ok' : c.status === 'warn' ? 'warn' : 'fail';
      const icon = cls === 'ok' ? '✓' : cls === 'warn' ? '!' : '✗';
      return el('div', { cls: 'chk ' + cls }, [
        el('span', { cls: 'ic', text: icon, attrs: { 'aria-hidden': 'true' } }),
        el('span', { cls: 'grow' }, [
          el('span', { cls: 'nm', text: c.name || c.status }),
          c.detail ? el('span', { cls: 'fx', text: truncate(c.detail, 200) }) : null,
          c.fix && cls !== 'ok' ? el('span', { cls: 'fx mono', text: '→ ' + truncate(c.fix, 200) }) : null,
        ]),
      ]);
    }));
  }

  /* ---- history ------------------------------------------------------- */

  /* "Clear" hides rows in this panel and does nothing else.
   *
   * There is no verb that deletes events.jsonl and there must not be: the ledger
   * is the audit trail for reviews posted under the user's own GitHub account.
   * So this is a filter, remembered for the session only.
   *
   * Two parts, because either alone is wrong: the newest timestamp cleared lets
   * genuinely newer reviews through, and the exact keys cleared cover rows that
   * carry no usable timestamp at all. */
  let historyClearedAt = 0;
  const historyClearedKeys = new Set();

  function historyKey(e) {
    const o = obj(e);
    return str(o.number || '?') + '@' + ms(o.at) + ':' + lower(o.status);
  }

  function visibleHistory() {
    // Clear and the pager are wired before the first push ever lands, so this has
    // to answer for "no state yet" rather than throwing on S.history.
    if (!S) return [];
    if (!historyClearedAt && !historyClearedKeys.size) return S.history;
    return S.history.filter((e) => {
      if (historyClearedKeys.has(historyKey(e))) return false;
      const at = ms(obj(e).at);
      return at ? at > historyClearedAt : true;
    });
  }

  async function clearHistory(node) {
    const rows = visibleHistory();
    if (!rows.length) { toast('the list is already empty'); return; }
    const ok = await confirmAsk({
      title: 'Hide these ' + rows.length + (rows.length === 1 ? ' entry?' : ' entries?'),
      body: 'This only clears the list in this panel. Nothing is deleted — every review '
        + 'stays in the Goblin\'s ledger, and newer reviews will appear here as they happen.',
      yes: 'Hide them',
    });
    if (!ok) return;
    for (const r of rows) {
      historyClearedKeys.add(historyKey(r));
      historyClearedAt = Math.max(historyClearedAt, ms(obj(r).at));
    }
    // the timestamp does the real work, so the key set can be dropped rather
    // than grown without limit over a long session
    if (historyClearedKeys.size > 200) historyClearedKeys.clear();
    if (node) node.blur();
    renderHistory();
    toast('hidden in this panel — the ledger still has them');
  }

  /* ---- how many rows are on screen -----------------------------------
   *
   * A few rows by default, the rest behind "View more". The number revealed is
   * session state and MUST survive the 5-second state pushes: collapsing the list
   * back to three while someone is reading it is the same bug as a push clobbering
   * a half-typed field.
   *
   * So it is never reset by a push on its own. It is reset when the list under it
   * is genuinely a different list — nothing on screen appears in the new one, or
   * the list has emptied (a Clear). A push that prepends a new review, appends an
   * older one, or trims the tail shares keys with what was shown, so the reader
   * keeps their place. */
  const HISTORY_FIRST = 3;
  const HISTORY_STEP = 10;
  let historyShown = HISTORY_FIRST;
  let historyKeysSeen = new Set();

  function historyPage(all) {
    const keys = all.map(historyKey);
    const sameList = keys.some((k) => historyKeysSeen.has(k));
    if (!keys.length || (historyKeysSeen.size && !sameList)) historyShown = HISTORY_FIRST;
    historyKeysSeen = new Set(keys);
    historyShown = Math.max(HISTORY_FIRST, Math.min(historyShown, all.length || HISTORY_FIRST));
    return all.slice(0, historyShown);
  }

  function stepHistory(by, node) {
    const total = visibleHistory().length;
    historyShown = by > 0
      ? Math.min(total, historyShown + HISTORY_STEP)
      : HISTORY_FIRST;
    renderHistory();
    // the button that was just pressed can end up hidden (nothing left to
    // reveal), so hand focus to the one that replaced it rather than dropping it
    if (node && node.hidden) {
      const other = $(by > 0 ? 'histLess' : 'histMore');
      if (other && !other.hidden && typeof other.focus === 'function') other.focus();
    }
  }

  function renderHistory() {
    const cleared = historyClearedAt > 0 || historyClearedKeys.size > 0;
    const all = visibleHistory();
    const rows = historyPage(all);
    const remaining = all.length - rows.length;
    setText('histHint', cleared
      ? 'hidden in this panel — the ledger still has every review'
      : 'what the Goblin has posted lately');
    const clearBtn = $('clearHist');
    if (clearBtn) clearBtn.disabled = !all.length;

    // the count is the honest one: 3 of 15 says 3 of 15, never just "3"
    const pager = $('histPager');
    const more = $('histMore');
    const less = $('histLess');
    const pageable = all.length > HISTORY_FIRST;
    if (pager) pager.hidden = !pageable;
    if (more) {
      more.hidden = !pageable || remaining <= 0;
      more.textContent = 'View more (' + remaining + ')';
      more.setAttribute('aria-label', 'View more reviews — ' + remaining + ' not shown');
    }
    if (less) less.hidden = !pageable || rows.length <= HISTORY_FIRST;
    const countText = !pageable ? ''
      : (remaining > 0
        ? 'showing ' + rows.length + ' of ' + all.length
        : 'showing all ' + all.length);
    // aria-live: only write when it actually changed, so a 5-second push that
    // says the same thing is not announced again every 5 seconds
    const countNode = $('histCount');
    if (countNode && countNode.textContent !== countText) countNode.textContent = countText;

    if (!rows.length) {
      fill('hist', el('div', {
        cls: 'empty',
        text: cleared ? 'cleared here — new reviews will show up as they happen' : 'no reviews yet',
      }));
      return;
    }
    const head = el('thead', null, el('tr', null, [
      el('th', { text: 'PR' }),
      el('th', { cls: 'right', text: 'Cost' }),
      el('th', { cls: 'right', text: 'Status' }),
    ]));
    const body = el('tbody', null, rows.map((e) => {
      const o = obj(e);
      const number = str(o.number || '?');
      const url = str(o.url || '');
      const posted = lower(o.status) === 'posted';
      const cost = num(o.costUsd, 0);
      const costKnown = o.costUsd !== undefined && o.costUsd !== null && cost > 0;
      const sub = [
        ms(o.at) ? stamp(ms(o.at)) : '',
        str(o.repo || ''),
        str(o.model || o.provider || ''),
      ].filter((x) => x).join(' · ');
      const title = truncate(o.title, TITLE_MAX);
      const lines = [
        el('span', { cls: 'ttl', text: '#' + number + (title ? ' ' + title : '') }),
        el('span', { cls: 'sub', text: sub }),
      ];
      return el('tr', null, [
        el('td', null, isOpenable(url)
          ? el('button', {
            cls: 'link',
            attrs: { type: 'button', 'aria-label': 'Open #' + number },
            on: { click: () => openLink(url) },
          }, lines)
          : el('span', { cls: 'block' }, lines)),
        el('td', { cls: 'right mono', text: costKnown ? money(cost) : '—' }),
        el('td', { cls: 'right' }, el('span', {
          cls: 'badge ' + (posted ? 'ok' : 'bad'),
          text: posted ? 'posted' : truncate(o.reason || 'failed', 24),
        })),
      ]);
    }));
    fill('hist', el('table', null, [head, body]));
  }

  /* ---- account ------------------------------------------------------- */

  function renderAccount() {
    const login = str(S.identity.login);
    setText('identityLine', login ? '@' + login : 'no GitHub account chosen');
    setText('identityHint', S.identity.ok === false
      ? 'your terminal\'s active account is ' + (str(S.identity.ghActive) || '?')
      : 'the account reviews are posted from');

    const li = $('loginItem');
    if (li) {
      li.indeterminate = S.loginItem === null;
      setChk('loginItem', S.loginItem === true);
    }

    if (!accountsOpen) { fill('accountList', []); return; }
    if (!accounts) {
      fill('accountList', el('div', { cls: 'empty', text: 'looking for logged-in accounts…' }));
      return;
    }
    if (!accounts.length) {
      fill('accountList', el('div', { cls: 'empty', text: 'no gh accounts found — run gh auth login' }));
      return;
    }
    fill('accountList', accounts.map((a) => {
      const o = obj(a);
      const who = str(o.login || a);
      const active = o.active === true;
      return el('button', {
        cls: 'small' + (lower(who) === lower(login) ? ' primary' : ''),
        attrs: { type: 'button' },
        text: '@' + who + (active ? ' (active in your terminal)' : ''),
        on: {
          click: async (ev) => {
            accountsOpen = false;
            await act(ev.currentTarget, 'setIdentity', { login: who }, { done: 'reviewing as @' + who });
            render();
          },
        },
      });
    }));
  }

  /* =====================================================================
   * 8. per-field edit protection
   *
   * The old panel had ONE global `dirty` flag: any edit anywhere froze every
   * field, and any commit unfroze them, so a state push could still overwrite
   * what you were typing. Track it per field instead, and never write to a
   * field that has focus or uncommitted edits.
   * ===================================================================== */

  const dirty = new Set();

  function watch(id) {
    const n = $(id);
    if (!n) return;
    n.addEventListener('input', () => dirty.add(id));
    n.addEventListener('focus', () => dirty.add(id));
    n.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') { dirty.delete(id); n.blur(); render(); }
    });
  }

  function setVal(id, v) {
    const n = $(id);
    if (!n) return;
    if (document.activeElement === n || dirty.has(id) || inflight.has(id)) return;
    const s = str(v);
    if (n.value !== s) n.value = s;
  }

  function setChk(id, v) {
    const n = $(id);
    if (!n) return;
    if (inflight.has(id)) return;
    n.checked = !!v;
  }

  async function commitNumber(id, cmd, o) {
    const n = $(id);
    if (!n) return;
    const value = clampInt(n.value, o.min, o.max, o.fallback);
    n.value = String(value);
    n.classList.remove('bad');
    inflight.add(id);
    try {
      const r = await call(cmd, { value });
      if (r.ok) { dirty.delete(id); toast(o.done || 'saved'); } else {
        n.classList.add('bad');
        toast(str(obj(r.error).message || 'could not save'), true);
      }
    } finally {
      inflight.delete(id);
    }
  }

  /* opts.confirmOff: a confirmAsk payload shown ONLY when the switch is being
   * turned off. That is the asymmetry a guard needs — loosening it costs money or
   * risk, tightening it back never does, so re-arming a guard must not nag.
   *
   * The id is held in `inflight` across the confirm as well as the call, so a
   * state push landing mid-dialog cannot flip the switch back under the dialog. */
  function wireFlag(id, key, opts) {
    const n = $(id);
    if (!n) return;
    const o = opts || {};
    n.addEventListener('change', async () => {
      const value = n.checked;
      inflight.add(id);
      try {
        if (o.confirmOff && value === false) {
          const ok = await confirmAsk(o.confirmOff);
          if (!ok) { n.checked = true; return; }
        }
        const r = await call('setFlag', { key, value });
        if (r.ok) {
          // remembered in case the state file does not report this key back yet
          savedFlags[key] = value;
          if (S) S.flags[key] = value;
          toast('saved');
        } else { n.checked = !value; toast(str(obj(r.error).message || 'could not save'), true); }
      } finally {
        inflight.delete(id);
      }
    });
  }

  /* =====================================================================
   * 9. wiring — every listener is attached here, none in markup
   * ===================================================================== */

  let searchTimer = 0;

  function wire() {
    const power = $('power');
    if (power) {
      power.addEventListener('change', async () => {
        const want = power.checked;
        if (want) {
          const ok = await confirmAsk({
            title: 'Put the Goblin on duty?',
            body: 'It starts reviewing the PRs waiting on you, which spends your own '
              + 'AI subscription quota right away.',
            yes: 'Turn on',
          });
          if (!ok) { power.checked = false; render(); return; }
        }
        inflight.add('power');
        try {
          const r = await call('power', { on: want });
          if (r.ok) toast(want ? 'on duty' : 'off duty');
          else { power.checked = !want; toast(str(obj(r.error).message || 'could not switch'), true); }
        } finally {
          inflight.delete('power');
        }
      });
    }

    for (const b of document.querySelectorAll('[data-snooze]')) {
      // data-* is fine here: the value is a literal in panel.html, never state
      b.addEventListener('click', (ev) => {
        const kind = ev.currentTarget.dataset.snooze;
        act(ev.currentTarget, 'snooze', { kind }, {
          done: kind === 'clear' ? 'awake' : kind === 'hour' ? 'quiet for an hour' : 'quiet until tomorrow',
        });
      });
    }

    const review = $('reviewNow');
    if (review) {
      review.addEventListener('click', async (ev) => {
        const ok = await confirmAsk({
          title: 'Review now?',
          body: 'This runs straight away and spends your AI subscription quota on '
            + 'every PR currently waiting on you.',
          yes: 'Review now',
        });
        if (!ok) return;
        act(ev.currentTarget, 'reviewNow', {}, { done: 'review started' });
      });
    }

    const dry = $('dryRun');
    if (dry) {
      dry.addEventListener('click', (ev) =>
        act(ev.currentTarget, 'dryRun', {}, { done: 'dry run started — nothing will be posted' }));
    }

    const inboxBtn = $('inboxRefresh');
    if (inboxBtn) {
      inboxBtn.addEventListener('click', async (ev) => {
        const r = await act(ev.currentTarget, 'inbox', { refresh: true }, { quiet: true });
        if (r.ok && r.data) mergeInbox(r.data);
        if (r.ok) toast('inbox refreshed');
      });
    }

    const refreshProv = $('refreshProviders');
    if (refreshProv) {
      refreshProv.addEventListener('click', (ev) => recheckProviders(ev.currentTarget));
    }

    const saveModelBtn = $('saveModel');
    if (saveModelBtn) saveModelBtn.addEventListener('click', (ev) => saveModel(ev.currentTarget));

    const modelSel = $('modelSelect');
    if (modelSel) {
      modelSel.addEventListener('change', (ev) => {
        const node = ev.currentTarget;
        if (node.value === CUSTOM_MODEL) {
          // Custom… is not a model, it is a request for the text box. Nothing is
          // saved until there is something to save.
          customModelOpen = true;
          const input = $('model');
          const row = $('modelCustomRow');
          if (row) row.hidden = false;
          if (input && typeof input.focus === 'function') input.focus();
          return;
        }
        customModelOpen = false;
        const row = $('modelCustomRow');
        if (row) row.hidden = true;
        // picking from the list is an explicit choice, so save it straight away
        saveModel($('saveModel'));
      });
    }
    const modelInput = $('model');
    if (modelInput) {
      modelInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') saveModel($('saveModel')); });
    }

    ['model', 'capDay', 'maxRun', 'maxFind', 'interval', 'verdict', 'newRepo'].forEach(watch);

    const nums = [
      ['capDay', 'setMaxReviewsPerDay', { min: 0, max: 500, fallback: 0, done: 'daily cap saved' }],
      ['maxRun', 'setMaxReviewsPerRun', { min: 1, max: 50, fallback: 5, done: 'saved' }],
      ['maxFind', 'setMaxFindings', { min: 1, max: 200, fallback: 25, done: 'saved' }],
      ['interval', 'setIntervalMinutes', { min: 1, max: 1440, fallback: 15, done: 'schedule saved' }],
    ];
    for (const [id, cmd, o] of nums) {
      const n = $(id);
      if (!n) continue;
      n.addEventListener('change', () => commitNumber(id, cmd, o));
      n.addEventListener('blur', () => { if (dirty.has(id)) commitNumber(id, cmd, o); });
    }

    const verdict = $('verdict');
    if (verdict) {
      verdict.addEventListener('change', async () => {
        const value = verdict.value;
        const previous = S ? S.verdictMode : 'comment';
        if (value === 'full') {
          const ok = await confirmAsk({
            title: 'Let the Goblin approve pull requests?',
            body: 'Reviews post from your own GitHub account, so an approval counts as '
              + 'yours and clears the review request. Only do this if you are happy '
              + 'signing off on what it approves.',
            yes: 'Allow approvals',
            tone: 'danger',
          });
          if (!ok) { verdict.value = previous; dirty.delete('verdict'); return; }
        }
        inflight.add('verdict');
        try {
          const r = await call('setVerdictMode', { value });
          if (!r.ok) {
            verdict.value = previous;
            toast(str(obj(r.error).message || 'could not save'), true);
            return;
          }
          // full mode is meaningless without the approve permission, and
          // leaving it set behind a downgrade would be a nasty surprise
          const allow = await call('setAllowApprove', { value: value === 'full' });
          dirty.delete('verdict');
          toast(allow.ok ? 'saved' : 'mode saved, but the approve permission did not stick');
        } finally {
          inflight.delete('verdict');
        }
      });
    }

    wireFlag('fIncr', 'incrementalReview');
    wireFlag('fSkipReviewed', 'skipIfHumanReviewed', {
      confirmOff: {
        title: 'Review PRs a teammate has already reviewed?',
        body: 'Right now the Goblin leaves those alone. Turn this off and he will '
          + 'also review PRs someone has already looked at, so he reviews more '
          + 'often and spends more of your AI subscription quota.',
        yes: 'Review them too',
      },
    });
    wireFlag('fCommit', 'postCommitStatus');
    wireFlag('fFleet', 'fleetAssignment');
    wireFlag('nStart', 'notifyStarted');
    wireFlag('nPost', 'notifyPosted');
    wireFlag('nFail', 'notifyFailed');
    wireFlag('nBudget', 'notifyBudget');
    wireFlag('nSound', 'notifySound');

    const addRepo = $('addRepo');
    const newRepo = $('newRepo');
    if (addRepo && newRepo) {
      const add = async (node) => {
        const slug = newRepo.value.trim();
        if (!isSlug(slug)) { toast('use owner/name', true); newRepo.focus(); return; }
        const r = await act(node, 'repoAdd', { slug }, { quiet: true });
        if (r.ok) {
          newRepo.value = '';
          dirty.delete('newRepo');
          fill('repoSuggest', []);
          toast(slug + ' added');
        } else {
          toast(str(obj(r.error).message || 'could not add that repo'), true);
        }
      };
      addRepo.addEventListener('click', (ev) => add(ev.currentTarget));
      newRepo.addEventListener('keydown', (e) => { if (e.key === 'Enter') add(addRepo); });
      newRepo.addEventListener('input', () => {
        clearTimeout(searchTimer);
        // the search verb only accepts ^[A-Za-z0-9 ._/-]{0,80}$; strip locally
        // rather than sending something the bridge will refuse
        const query = searchable(newRepo.value);
        if (query.length < 3 || query.indexOf('/') === 0) { fill('repoSuggest', []); return; }
        searchTimer = setTimeout(async () => {
          const r = await call('repoSearch', { query, limit: 6 });
          if (!r.ok) { fill('repoSuggest', []); return; }
          const found = arr(obj(r.data).repos || obj(r.data).results || r.data)
            .map((x) => str(obj(x).slug || obj(x).nameWithOwner || obj(x).full_name || x))
            .filter(isSlug)
            .slice(0, 6);
          fill('repoSuggest', found.map((slug) => el('button', {
            cls: 'small', text: slug, attrs: { type: 'button' },
            on: {
              click: async (ev) => {
                const res = await act(ev.currentTarget, 'repoAdd', { slug }, { quiet: true });
                if (res.ok) {
                  newRepo.value = '';
                  dirty.delete('newRepo');
                  fill('repoSuggest', []);
                  toast(slug + ' added');
                } else {
                  toast(str(obj(res.error).message || 'could not add that repo'), true);
                }
              },
            },
          })));
        }, 260);
      });
    }

    const runD = $('runDoctor');
    if (runD) runD.addEventListener('click', (ev) => runDoctor(ev.currentTarget, false));
    const fixD = $('fixDoctor');
    if (fixD) {
      fixD.addEventListener('click', async (ev) => {
        const ok = await confirmAsk({
          title: 'Fix what can be fixed?',
          body: 'This changes things on your machine: reloading the schedule, '
            + 'resetting the scratch clone, re-pinning the GitHub token.',
          yes: 'Fix it',
        });
        if (ok) runDoctor(ev.currentTarget, true);
      });
    }

    const clearHist = $('clearHist');
    if (clearHist) clearHist.addEventListener('click', (ev) => clearHistory(ev.currentTarget));

    // paging is view state only: no verb, nothing written, nothing fetched
    const histMore = $('histMore');
    if (histMore) histMore.addEventListener('click', (ev) => stepHistory(1, ev.currentTarget));
    const histLess = $('histLess');
    if (histLess) histLess.addEventListener('click', (ev) => stepHistory(-1, ev.currentTarget));

    const pick = $('pickAccount');
    if (pick) {
      pick.addEventListener('click', async (ev) => {
        accountsOpen = !accountsOpen;
        if (!accountsOpen) { render(); return; }
        accounts = null;
        render();
        const r = await act(ev.currentTarget, 'accounts', {}, { quiet: true });
        accounts = r.ok
          ? arr(obj(r.data).accounts || r.data).map((a) => (typeof a === 'string' ? { login: a } : obj(a)))
          : [];
        render();
      });
    }

    const li = $('loginItem');
    if (li) {
      li.addEventListener('change', async () => {
        const on = li.checked;
        inflight.add('loginItem');
        try {
          const r = await call('loginItem', { on });
          if (r.ok) toast(on ? 'opens at login' : 'no longer opens at login');
          else { li.checked = !on; toast(str(obj(r.error).message || 'could not change that'), true); }
        } finally {
          inflight.delete('loginItem');
        }
      });
    }

    const log = $('openLog');
    if (log) log.addEventListener('click', (ev) => act(ev.currentTarget, 'openLog', {}, { quiet: true }));
    const conf = $('openConfig');
    if (conf) conf.addEventListener('click', (ev) => act(ev.currentTarget, 'openConfig', {}, { quiet: true }));
    const diag = $('copyDiag');
    if (diag) {
      diag.addEventListener('click', (ev) =>
        act(ev.currentTarget, 'copyDiagnostics', {}, { done: 'diagnostics copied to the clipboard' }));
    }
  }

  /* Merge a verb's payload into the snapshot when the app answers with data but
   * no full state (inbox/providers are refreshed independently of ~/.goblin). */
  function mergeInbox(data) {
    if (!S) return;
    const d = obj(data);
    const box = Object.keys(obj(d.inbox)).length ? obj(d.inbox) : d;
    S.inbox = {
      prs: arr(box.prs || box.items),
      counts: obj(box.counts),
      refreshedAt: ms(box.refreshedAt || box.at) || Date.now(),
      error: str(box.error || ''),
    };
    renderInbox();
  }

  function mergeProviders(data) {
    if (!S) return;
    const d = obj(data);
    const list = arr(d.providers || data);
    if (!list.length) return;
    providerCache = list;                       // raw, so it survives re-mapping
    S.providers = mapProviders(list, S.providerId);
    S.provider = S.providers.find((p) => p.current) || null;
    renderProviders();
    renderActivity();
    renderBanners();
  }

  /* =====================================================================
   * 10. boot
   * ===================================================================== */

  function showWizard(on) {
    const wiz = $('wizard');
    const main = $('main');
    if (wiz) wiz.hidden = !on;
    if (main) main.hidden = !!on;
    const banners = $('banners');
    if (banners) banners.hidden = !!on;
  }

  async function boot() {
    wire();
    booted = true;

    if (queuedPush) { applyState(queuedPush); queuedPush = null; }

    const initial = await call('state', {});
    if (initial.ok) applyState(initial.state || initial.data);
    else pushError('the Goblin did not answer', str(obj(initial.error).message || ''));

    // cheap read, no GitHub round trip unless the app decides to
    const box = await call('inbox', { refresh: false });
    if (box.ok && box.data) mergeInbox(box.data);

    // the pushed state carries no provider list, so ask for one
    const provs = await call('providers', { refresh: false });
    if (provs.ok && provs.data) mergeProviders(provs.data);

    // First run takes over the panel. Two independent signals, and BOTH have to
    // fail open: if the verb is missing and setup.complete is absent, show the
    // normal panel rather than trapping a long-time user in a wizard.
    const wz = await call('wizardState', {});
    const wdata = obj(wz.data);
    const saysDone = wdata.complete === true || wdata.done === true
      || (wdata.step !== undefined && lower(wdata.step) === 'done');
    const saysFirstRun = wdata.complete === false || wdata.done === false
      || wdata.firstRun === true || (S && S.setupComplete === false);
    const firstRun = saysFirstRun && !saysDone;
    if (!firstRun || !startWizard(wdata)) showWizard(false);
  }

  /* Returns false if the wizard could not be shown, so the caller can fall back
   * to the normal panel instead of leaving a blank popover. */
  function startWizard(wdata) {
    if (!window.GoblinWizard || typeof window.GoblinWizard.start !== 'function') return false;
    showWizard(true);
    window.GoblinWizard.start({
      state: () => S,
      data: obj(wdata),
      finish: async () => {
        await call('wizardComplete', {});
        showWizard(false);
        const s = await call('state', {});
        if (s.ok) applyState(s.state || s.data);
        toast('all set — the Goblin is watching');
      },
    });
    return true;
  }

  /* Public kit for wizard.js. Deliberately small: the wizard gets the same
   * el()/call() so it cannot invent its own DOM or transport. */
  window.Goblin = {
    el, call, toast, confirmAsk, truncate, openLink, fill, setText, searchable,
    snapshot: () => S,
    isSlug,
    // shared with the wizard so first run gets the same sign-in help, from the
    // same hardcoded command table, instead of a second copy that drifts
    mapProviders, providerHelp,
    isMock: () => MOCK,
    refresh: async () => {
      const r = await call('state', {});
      if (r.ok) applyState(r.state || r.data);
      return r;
    },
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot, { once: true });
  } else {
    boot();
  }

  /* =====================================================================
   * 11. mock bridge — browser-only, for checking layout
   *
   * Never reachable when window.webkit exists, and when it is reachable the
   * panel wears a red MOCK ribbon. The fake data deliberately includes a
   * hostile PR title and a javascript: URL: if either ever renders as anything
   * but literal text, rule 1 has been broken and it will be obvious.
   * ===================================================================== */

  function mockCall(payload) {
    if (!mockCall.state) mockCall.state = buildMock();
    const st = mockCall.state;
    const cmd = payload.cmd;
    const args = payload.args;
    const cfg = st.config;

    const setters = {
      setMaxReviewsPerDay: () => { cfg.maxReviewsPerDay = args.value; },
      setMaxReviewsPerRun: () => { cfg.maxReviewsPerRun = args.value; },
      setMaxFindings: () => { cfg.maxFindings = args.value; },
      setIntervalMinutes: () => { cfg.intervalSeconds = args.value * 60; },
      setVerdictMode: () => { cfg.verdictMode = args.value; },
      setAllowApprove: () => { cfg.allowApprove = args.value; },
      setProvider: () => { cfg.provider = args.id; st.status.provider = { id: args.id, model: '' }; },
      // the arg is `provider`, not `id` — reading args.id here wrote
      // cfg.providers.undefined, so a saved model never came back
      setProviderModel: () => {
        cfg.providers[args.provider] = { model: args.model };
        if (args.provider === cfg.provider) st.status.provider = { id: args.provider, model: args.model };
      },
      setIdentity: () => { st.status.identity = { login: args.login, ghActive: args.login, ok: true }; },
      setFlag: () => {
        const map = {
          notifyStarted: 'started', notifyPosted: 'posted', notifyFailed: 'failed',
          notifyBudget: 'budget', notifySound: 'sound',
        };
        if (map[args.key]) cfg.notify[map[args.key]] = args.value;
        else cfg[args.key] = args.value;
      },
      power: () => {
        st.status.agent.disabled = !args.on;
        cfg.enabled = !!args.on;
        st.status.state = args.on ? 'idle' : 'disabled';
      },
      pause: () => { st.status.state = 'paused'; st.status.pausedReason = 'manual'; },
      resume: () => { st.status.state = 'idle'; st.status.pausedReason = ''; },
      snooze: () => {
        const secs = Math.floor(Date.now() / 1000);
        cfg.snoozeUntil = args.kind === 'clear' ? 0 : secs + (args.kind === 'hour' ? 3600 : 43200);
        st.status.state = args.kind === 'clear' ? 'idle' : 'snoozed';
      },
      repoAdd: () => { cfg.repos.push({ slug: args.slug, enabled: true }); },
      repoRemove: () => { cfg.repos = cfg.repos.filter((r) => r.slug !== args.slug); },
      repoEnable: () => {
        cfg.repos = cfg.repos.map((r) => (r.slug === args.slug ? { slug: r.slug, enabled: args.enabled } : r));
      },
      loginItem: () => { st.loginItem = !!args.on; },
    };

    const reply = { ok: true };
    if (setters[cmd]) setters[cmd]();

    if (cmd === 'doctor') {
      reply.data = {
        pass: 6, warn: 1, fail: args.fix ? 0 : 1,
        checks: [
          { status: 'ok', check: 'gh', detail: 'MOCK gh 2.0.0' },
          { status: 'warn', check: 'scratch clone', detail: 'MOCK dirty tree', fix: 'goblin doctor --fix' },
          {
            status: args.fix ? 'ok' : 'fail',
            check: 'provider bin',
            detail: 'MOCK "><img src=x onerror=1> \' " </script>',
            fix: 'goblin provider use claude',
          },
        ],
      };
    } else if (cmd === 'accounts') {
      reply.data = { accounts: [{ login: 'mock-user', active: true }, { login: 'mock-teammate' }] };
    } else if (cmd === 'providers') {
      reply.data = { providers: st.providers };
    } else if (cmd === 'inbox') {
      reply.data = st.inbox;
    } else if (cmd === 'repoSearch') {
      reply.data = { repos: ['mockorg/mock-one', 'mockorg/mock-two'] };
    } else if (cmd === 'wizardState') {
      reply.data = { complete: true };
    } else if (cmd === 'copyDiagnostics') {
      reply.data = { copied: true };
    }
    reply.state = st;
    return new Promise((resolve) => setTimeout(() => resolve(reply), 90));
  }

  function buildMock() {
    const secs = Math.floor(Date.now() / 1000);
    const nasty = 'MOCK "><img src=x onerror=1> \' " </script> title';
    const history = [
      {
        at: secs - 900, number: 128, title: nasty, url: 'javascript:alert(1)',
        costUsd: 0.42, status: 'posted', repo: 'mockorg/mock-repo', model: 'sonnet',
      },
      {
        at: secs - 5400, number: 127, title: 'MOCK ordinary pull request title',
        url: 'https://github.com/mockorg/mock-repo/pull/127',
        costUsd: 0, status: 'failed', reason: 'MOCK quota', repo: 'mockorg/mock-repo', model: 'sonnet',
      },
    ];
    // enough rows that the browser preview shows the pager, which is the part of
    // this section carrying state of its own
    for (let i = 1; i <= 12; i += 1) {
      history.push({
        at: secs - 7200 - i * 900, number: 126 - i,
        title: 'MOCK older review ' + i,
        url: 'https://github.com/mockorg/mock-repo/pull/' + (126 - i),
        costUsd: 0.05 * i, status: 'posted', repo: 'mockorg/mock-repo', model: 'sonnet',
      });
    }
    return {
      home: '/tmp/mock-goblin',
      loginItem: false,
      status: {
        state: 'idle', pausedReason: '', activity: 'MOCK — idle',
        lastRunFinished: secs - 420, nextRunEstimate: secs + 480,
        reviews: { today: 3, week: 11, total: 128 },
        spendUsd: { today: 1.42, week: 6.1, total: 88.4 },
        recentFailures: [{ number: 41, reason: nasty, at: secs - 900 }],
        goblin: { name: 'The Merge Goblin', version: '0.0.0-mock' },
        provider: { id: 'claude', model: 'sonnet' },
        identity: { login: 'mock-user', ghActive: 'mock-other', ok: false },
        agent: { running: true, disabled: false },
        doctor: { fail: 1, warn: 1, at: secs - 3600 },
      },
      config: {
        enabled: true, snoozeUntil: 0, intervalSeconds: 900,
        provider: 'claude',
        providers: { claude: { model: 'sonnet' }, codex: { model: '' }, cursor: { model: '' } },
        repos: [{ slug: 'mockorg/mock-repo', enabled: true }, { slug: 'mockorg/other', enabled: false }],
        fleet: ['mock-teammate'],
        fleetAssignment: true, verdictMode: 'comment', allowApprove: false,
        maxReviewsPerDay: 20, maxReviewsPerRun: 5, maxFindings: 25,
        postCommitStatus: true, incrementalReview: true, skipIfHumanReviewed: true,
        notify: { started: true, posted: true, failed: true, budget: true, sound: false },
      },
      providers: [
        { id: 'claude', current: true, state: 'ready', detail: 'MOCK subscription', costKnown: true },
        { id: 'codex', state: 'no auth', detail: 'MOCK run codex login', costKnown: false },
        { id: 'cursor', state: 'missing', detail: 'MOCK not installed', costKnown: false },
      ],
      history,
      // one of every state inbox.sh can write, so the browser preview shows what
      // the "Awaiting review" list does and does NOT list
      inbox: {
        refreshedAt: secs - 120,
        counts: {
          waiting: 2, mine: 2, drafts: 1, reviewed: 1, reviewedByOther: 1, assignedElsewhere: 1,
        },
        prs: [
          {
            number: 130, title: nasty, repo: 'mockorg/mock-repo',
            url: 'javascript:alert(2)', state: 'waiting', mine: true,
          },
          {
            number: 132, title: 'MOCK also waiting on you', repo: 'mockorg/mock-repo',
            url: 'https://github.com/mockorg/mock-repo/pull/132',
            state: 'waiting', mine: true, author: 'mock-author',
          },
          {
            number: 131, title: 'MOCK teammate has this one', repo: 'mockorg/other',
            url: 'https://github.com/mockorg/other/pull/131',
            state: 'assigned_elsewhere', assignee: 'mock-teammate',
          },
          {
            number: 129, title: 'MOCK already reviewed', repo: 'mockorg/mock-repo',
            url: 'https://github.com/mockorg/mock-repo/pull/129', state: 'reviewed', reviewed: true,
          },
          {
            number: 128, title: 'MOCK a human reviewed this one', repo: 'mockorg/mock-repo',
            url: 'https://github.com/mockorg/mock-repo/pull/128', state: 'reviewed_by_other',
            // the "why is this not being reviewed" answer, as inbox.sh writes it
            reason: 'reviewed by mock-teammate',
          },
          {
            number: 127, title: 'MOCK still a draft', repo: 'mockorg/other',
            url: 'https://github.com/mockorg/other/pull/127', state: 'draft',
          },
        ],
      },
    };
  }

}());
