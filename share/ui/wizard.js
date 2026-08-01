'use strict';
/* wizard.js — first run.
 *
 * Loaded as a second classic script (no inline block, no module) so panel.html
 * can keep script-src 'self' with no unsafe-inline. It borrows panel.js's kit
 * through window.Goblin, which means it uses the same el() builder and the same
 * bridge: it cannot invent its own DOM sink or its own transport.
 *
 * Nothing here writes markup. Every GitHub-supplied value (account logins, repo
 * slugs, provider notes) arrives as .textContent.
 */
(function () {

  const STEPS = ['welcome', 'account', 'provider', 'repos', 'finish'];

  let ctx = null;       // { state(), data, finish() }
  let step = 0;
  let accounts = null;  // null = not fetched yet
  let provs = null;
  let suggestions = [];
  let repoInput = null; // kept across renders so typing survives a re-render
  let searchTimer = 0;

  const kit = () => window.Goblin || null;
  const snap = () => {
    const k = kit();
    const s = k && k.snapshot ? k.snapshot() : null;
    return s || null;
  };
  const str = (v) => (v == null ? '' : String(v));
  const arr = (v) => (Array.isArray(v) ? v : []);
  const obj = (v) => (v && typeof v === 'object' && !Array.isArray(v) ? v : {});

  function start(c) {
    ctx = c || {};
    step = 0;
    accounts = null;
    provs = null;
    suggestions = [];
    render();
  }

  function go(n) {
    step = Math.max(0, Math.min(STEPS.length - 1, n));
    render();
    const host = document.getElementById('wizard');
    const focusable = host && host.querySelector('button:not(:disabled), input');
    if (focusable) focusable.focus();
  }

  /* ---- pieces -------------------------------------------------------- */

  function dots() {
    const k = kit();
    return k.el('div', { cls: 'steps', attrs: { 'aria-hidden': 'true' } },
      STEPS.map((_name, i) => k.el('span', {
        cls: 'step' + (i < step ? ' done' : i === step ? ' now' : ''),
      })));
  }

  function nav(o) {
    const k = kit();
    const buttons = [];
    if (step > 0) {
      buttons.push(k.el('button', {
        cls: 'small', text: 'Back', attrs: { type: 'button' },
        on: { click: () => go(step - 1) },
      }));
    }
    if (o.skip) {
      buttons.push(k.el('button', {
        cls: 'small ghost', text: o.skip, attrs: { type: 'button' },
        on: { click: () => go(step + 1) },
      }));
    }
    if (o.next) {
      buttons.push(k.el('button', {
        cls: 'small primary', text: o.next,
        attrs: { type: 'button', disabled: o.nextDisabled === true },
        on: { click: (ev) => (o.onNext ? o.onNext(ev.currentTarget) : go(step + 1)) },
      }));
    }
    return k.el('div', { cls: 'btns end' }, buttons);
  }

  function card(title, blurb, body, navNode) {
    const k = kit();
    return k.el('section', { cls: 'card' }, [
      k.el('h3', { text: title }),
      blurb ? k.el('p', { cls: 'hint', text: blurb }) : null,
      body,
      navNode,
      dots(),
    ]);
  }

  /* ---- steps --------------------------------------------------------- */

  function welcome() {
    const k = kit();
    return card(
      'The Goblin guards the merge button',
      'He watches the pull requests that ask for your review, reads the diff with '
      + 'the AI CLI you already pay for, and posts the findings as you. Four short '
      + 'questions and he is on duty.',
      k.el('div', { cls: 'tags' }, [
        k.el('span', { cls: 'tag' }, k.el('span', { cls: 'who', text: 'nothing leaves your Mac' })),
        k.el('span', { cls: 'tag' }, k.el('span', { cls: 'who', text: 'your own subscription' })),
        k.el('span', { cls: 'tag' }, k.el('span', { cls: 'who', text: 'comments only, by default' })),
      ]),
      nav({ next: 'Start' })
    );
  }

  function account() {
    const k = kit();
    const s = snap();
    const chosen = str(obj(s && s.identity).login);

    if (accounts === null) {
      accounts = [];
      k.call('accounts', {}).then((r) => {
        accounts = r.ok
          ? arr(obj(r.data).accounts || r.data).map((a) => (typeof a === 'string' ? { login: a } : obj(a)))
          : [];
        if (STEPS[step] === 'account') render();
      });
    }

    const list = accounts.length
      ? k.el('div', { cls: 'pickable' }, accounts.map((a) => {
        const who = str(obj(a).login || a);
        return k.el('button', {
          cls: 'small' + (who && who === chosen ? ' sel' : ''),
          text: '@' + who + (obj(a).active === true ? ' — active in your terminal' : ''),
          attrs: { type: 'button' },
          on: {
            click: async (ev) => {
              const r = await k.call('setIdentity', { login: who });
              if (!r.ok) { k.toast(str(obj(r.error).message || 'could not use that account'), true); return; }
              await k.refresh();
              k.toast('reviewing as @' + who);
              render();
            },
          },
        });
      }))
      : k.el('div', { cls: 'empty', text: 'no logged-in GitHub accounts found' });

    return card(
      'Which GitHub account?',
      'Reviews are posted from this account, so pick the one your teammates expect '
      + 'to hear from.',
      k.el('div', null, [
        list,
        k.el('button', {
          cls: 'small ghost', text: 'Not listed? Log in with the gh CLI',
          attrs: { type: 'button' },
          on: { click: () => k.openLink('https://cli.github.com/') },
        }),
      ]),
      nav({ next: 'Next', nextDisabled: chosen === '', skip: chosen === '' ? 'Later' : '' })
    );
  }

  function provider() {
    const k = kit();
    const s = snap();
    const currentId = str(s && s.providerId);

    if (provs === null) {
      provs = arr(s && s.providers);
      k.call('providers', { refresh: true }).then((r) => {
        if (r.ok && r.data) {
          const list = arr(obj(r.data).providers || r.data);
          // the panel's own mapper, so `available` vs `authed` is read the same
          // way here as it is there — the sign-in help depends on the difference
          if (list.length) provs = k.mapProviders(list, currentId);
        }
        if (STEPS[step] === 'provider') render();
      });
    }

    const ready = provs.filter((p) => p.ready);
    /* A greyed-out row with no way forward was the whole problem: first run is
     * exactly when a CLI is most likely to be missing or not logged in. Same
     * help block as the main panel, same hardcoded commands. */
    const cards = [];
    const body = provs.length
      ? k.el('div', null, provs.reduce((out, p) => {
        const id = 'wiz-prov-' + p.id;
        out.push(k.el('label', {
          cls: 'prov' + (p.id === currentId ? ' sel' : '') + (p.ready ? '' : ' dead'),
          attrs: { for: id },
        }, [
          k.el('input', {
            attrs: {
              type: 'radio', name: 'wiz-provider', id,
              checked: p.id === currentId, disabled: !p.ready,
            },
            on: {
              change: async (ev) => {
                if (!ev.currentTarget.checked) return;
                const r = await k.call('setProvider', { id: p.id });
                if (!r.ok) { k.toast(str(obj(r.error).message || 'could not pick that one'), true); return; }
                await k.refresh();
                render();
              },
            },
          }),
          k.el('span', { cls: 'grow' }, [
            k.el('span', { cls: 'nm', text: p.id }),
            k.el('span', {
              cls: 'meta',
              text: p.detail ? p.label + ' · ' + k.truncate(p.detail, 60) : p.label,
            }),
          ]),
        ]));
        // outside the label: a button inside <label for=...> toggles the radio
        if (!p.ready && typeof k.providerHelp === 'function') {
          out.push(k.providerHelp(p, (r) => {
            // Re-check has to update THIS list, not just the panel behind us
            const list = arr(obj(r && r.data).providers || (r && r.data));
            provs = list.length ? k.mapProviders(list, currentId) : arr(snap() && snap().providers);
            if (STEPS[step] === 'provider') render();
          }));
        }
        return out;
      }, cards))
      : k.el('div', { cls: 'empty', text: 'looking for AI CLIs…' });

    return card(
      'Who does the reviewing?',
      ready.length
        ? 'Each one bills your own subscription. Greyed-out ones are not installed or not logged in.'
        : 'None of them are ready yet. The commands below install or sign in to one — '
          + 'run one in a terminal, then press Re-check.',
      body,
      nav({ next: 'Next', nextDisabled: currentId === '' })
    );
  }

  function repos() {
    const k = kit();
    const s = snap();
    const list = arr(s && s.repos);

    if (!repoInput) {
      repoInput = k.el('input', {
        attrs: {
          type: 'text', id: 'wizRepo', placeholder: 'owner/name',
          autocomplete: 'off', autocapitalize: 'off', spellcheck: 'false',
          'aria-label': 'Repository to watch',
        },
        on: {
          input: (ev) => search(ev.currentTarget.value),
          keydown: (ev) => { if (ev.key === 'Enter') addRepo(ev.currentTarget.value, ev.currentTarget); },
        },
      });
    }

    const added = list.length
      ? k.el('div', { cls: 'tags' }, list.map((r) => k.el('span', { cls: 'tag' },
        k.el('span', { cls: 'who mono', text: str(r.slug) }))))
      : k.el('div', { cls: 'empty', text: 'none yet — the Goblin needs at least one' });

    return card(
      'Which repositories?',
      'He only looks at repos you list here, and only at PRs that request your review.',
      k.el('div', null, [
        added,
        k.el('div', { cls: 'field tight' }, [
          repoInput,
          k.el('button', {
            cls: 'small', text: 'Add', attrs: { type: 'button' },
            on: { click: (ev) => addRepo(repoInput.value, ev.currentTarget) },
          }),
        ]),
        k.el('div', { cls: 'suggest' }, suggestions.map((slug) => k.el('button', {
          cls: 'small', text: slug, attrs: { type: 'button' },
          on: { click: (ev) => addRepo(slug, ev.currentTarget) },
        }))),
      ]),
      nav({ next: 'Next', nextDisabled: list.length === 0, skip: list.length ? '' : 'Later' })
    );
  }

  function search(query) {
    const k = kit();
    // repoSearch only accepts ^[A-Za-z0-9 ._/-]{0,80}$; strip locally instead of
    // sending something the bridge will refuse
    const q = k.searchable ? k.searchable(query) : str(query).trim();
    clearTimeout(searchTimer);
    if (q.length < 3) { suggestions = []; return; }
    searchTimer = setTimeout(async () => {
      const r = await k.call('repoSearch', { query: q, limit: 6 });
      suggestions = r.ok
        ? arr(obj(r.data).repos || obj(r.data).results || r.data)
          .map((x) => str(obj(x).slug || obj(x).nameWithOwner || obj(x).full_name || x))
          // GitHub-supplied: check against the bridge's own slug rule
          .filter((slug) => (k.isSlug ? k.isSlug(slug) : slug.indexOf('/') > 0))
          .slice(0, 6)
        : [];
      if (STEPS[step] === 'repos') render();
    }, 260);
  }

  async function addRepo(value, node) {
    const k = kit();
    const slug = str(value).trim();
    const ok = k.isSlug ? k.isSlug(slug) : /^[\w.-]+\/[\w.-]+$/.test(slug);
    if (!ok) { k.toast('use owner/name', true); return; }
    if (node) node.disabled = true;
    try {
      const r = await k.call('repoAdd', { slug });
      if (!r.ok) { k.toast(str(obj(r.error).message || 'could not add that repo'), true); return; }
      if (repoInput) repoInput.value = '';
      suggestions = [];
      await k.refresh();
      k.toast(slug + ' added');
      render();
    } finally {
      if (node) node.disabled = false;
    }
  }

  function finish() {
    const k = kit();
    const s = snap();
    const running = obj(s && s.agent).running === true;
    const loginOn = s && s.loginItem === true;

    return card(
      'Let him out',
      'He wakes up every ' + ((s && s.intervalMinutes) || 15) + ' minutes, reviews what is '
      + 'waiting, and posts comments only. You can change any of that in the panel.',
      k.el('div', null, [
        k.el('div', { cls: 'row' }, [
          k.el('label', { cls: 'grow lbl', attrs: { for: 'wizLogin' } }, [
            k.el('span', { cls: 'label', text: 'Open at login' }),
            k.el('span', { cls: 'hint', text: 'keeps him in your menu bar after a restart' }),
          ]),
          k.el('span', { cls: 'switch' }, [
            k.el('input', {
              attrs: { type: 'checkbox', id: 'wizLogin', checked: loginOn },
              on: {
                change: async (ev) => {
                  const on = ev.currentTarget.checked;
                  const r = await k.call('loginItem', { on });
                  if (!r.ok) {
                    ev.currentTarget.checked = !on;
                    k.toast(str(obj(r.error).message || 'could not change that'), true);
                  }
                },
              },
            }),
            k.el('span', { cls: 'slider', attrs: { 'aria-hidden': 'true' } }),
          ]),
        ]),
        k.el('div', { cls: 'row' }, [
          k.el('span', { cls: 'grow' }, [
            k.el('span', { cls: 'label', text: 'Schedule' }),
            k.el('span', {
              cls: 'hint',
              text: running ? 'already loaded and waking him up' : 'not loaded yet',
            }),
          ]),
          running ? null : k.el('button', {
            cls: 'small', text: 'Start it', attrs: { type: 'button' },
            on: {
              click: async (ev) => {
                const node = ev.currentTarget;
                node.disabled = true;
                const r = await k.call('agent', { action: 'start' });
                node.disabled = false;
                if (!r.ok) { k.toast(str(obj(r.error).message || 'could not start it'), true); return; }
                await k.refresh();
                render();
              },
            },
          }),
        ]),
        k.el('button', {
          cls: 'small ghost', text: 'Run the health checks first',
          attrs: { type: 'button' },
          on: {
            click: async (ev) => {
              const node = ev.currentTarget;
              node.disabled = true;
              const r = await k.call('doctor', { fix: false });
              node.disabled = false;
              const d = obj(r.data);
              k.toast(r.ok
                ? (d.fail ? d.fail + ' problems — see Health in the panel' : 'all good')
                : 'checks could not run', !r.ok || d.fail > 0);
            },
          },
        }),
      ]),
      nav({
        next: 'Done',
        onNext: async (node) => {
          node.disabled = true;
          try {
            if (ctx && typeof ctx.finish === 'function') await ctx.finish();
          } finally {
            node.disabled = false;
          }
        },
      })
    );
  }

  /* ---- render -------------------------------------------------------- */

  function render() {
    const k = kit();
    const host = document.getElementById('wizard');
    if (!k || !host) return;
    const builders = { welcome, account, provider, repos, finish };
    let node;
    try {
      node = builders[STEPS[step]]();
    } catch (e) {
      node = k.el('section', { cls: 'card' }, [
        k.el('h3', { text: 'Setup hit a snag' }),
        k.el('p', { cls: 'hint', text: String((e && e.message) || e) }),
        k.el('div', { cls: 'btns end' }, k.el('button', {
          cls: 'small primary', text: 'Skip setup', attrs: { type: 'button' },
          on: { click: () => (ctx && ctx.finish ? ctx.finish() : null) },
        })),
      ]);
    }
    host.replaceChildren(node);
  }

  window.GoblinWizard = { start, render };

}());
