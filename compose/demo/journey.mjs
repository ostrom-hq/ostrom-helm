// SPDX-License-Identifier: AGPL-3.0-only
// The customer's journey on the local demo stack, from outside, through Caddy, as a browser and the CLI would call it:
// sign-up by e-mailed link (read in Mailpit), sign-in with the fake GitHub, an organization, an invitation accepted,
// the CLI's device login, a cloud session on this machine's Docker with its terminal, the TeamCode import and its
// cutover, the yes end to end (a push to main waiting, the second member's yes, its receipt), isolation between two
// organizations, billing. Each step is green, red, or not possible yet (a route main does not serve, or a step it needs
// failed), with what it saw. Writes a Markdown report (REPORT, default demo-report.md) and exits 1 on a red step.
// Node 22 or later (fetch, WebSocket), no dependency. Usage: node demo/journey.mjs
import { execFileSync } from 'node:child_process';
import { randomBytes, randomUUID } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { dockerQuery, readTables, teamCodeImport } from './teamcode/export.mjs';
import { demoKey, TEAM } from './teamcode/seed.mjs';

const env = (k, d) => (process.env[k] ?? '').trim() || d;
const API = env('OSTROM_DEMO_API_URL', 'http://api.localhost');
const APP = env('OSTROM_DEMO_APP_URL', 'http://app.localhost');
const MAIL = env('OSTROM_DEMO_MAIL_URL', 'http://mail.localhost');
const ORIGIN = env('OSTROM_DEMO_CONSOLE_ORIGIN', 'http://app.localhost');
const REPORT = env('REPORT', 'demo-report.md');
const CLOUD_TIMEOUT_S = Number(env('OSTROM_DEMO_CLOUD_TIMEOUT', '240'));
const run = randomBytes(3).toString('hex');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const results = [];
const GREEN = 'vert';
const RED = 'rouge';
const NOT_YET = 'pas encore possible';
function record(id, title, state, detail) {
  results.push({ id, title, state, detail });
  const mark = state === GREEN ? 'OK ' : state === RED ? 'RED' : '-- ';
  console.log(`[${mark}] ${id} ${title}: ${detail}`);
}

/** A person: their cookies (as a browser keeps them for the console's origin) and CSRF token. */
class Browser {
  constructor(name) {
    this.name = name;
    this.jar = new Map();
    this.csrf = '';
    this.org = '';
  }
  keep(r) {
    for (const c of r.headers.getSetCookie()) {
      const [pair] = c.split(';');
      const eq = pair.indexOf('=');
      const name = pair.slice(0, eq).trim();
      const value = pair.slice(eq + 1).trim();
      if (value === '' || /max-age=0/i.test(c)) this.jar.delete(name);
      else this.jar.set(name, value);
    }
  }
  get cookie() {
    return [...this.jar].map(([k, v]) => `${k}=${v}`).join('; ');
  }
  async call(method, path, body, { base = APP, org = this.org, redirect = 'follow' } = {}) {
    const headers = { origin: ORIGIN };
    if (this.jar.size) headers.cookie = this.cookie;
    if (this.csrf && method !== 'GET') headers['x-csrf-token'] = this.csrf;
    if (org) headers['ostrom-org'] = org;
    if (body !== undefined) headers['content-type'] = 'application/json';
    const r = await fetch(base + path, { method, headers, redirect, body: body === undefined ? undefined : JSON.stringify(body) });
    this.keep(r);
    const text = await r.text();
    let json;
    try {
      json = text ? JSON.parse(text) : undefined;
    } catch {
      json = undefined;
    }
    return { status: r.status, json: json ?? {}, text, headers: r.headers };
  }
}

const brief = (r) => `${r.status} ${r.text.slice(0, 160).replace(/\s+/g, ' ')}`;

/** A call with a personal token, as the CLI and the hooks make them (no cookie, no CSRF). */
async function bearer(token, method, path, body, org) {
  const headers = { authorization: `Bearer ${token}` };
  if (org) headers['ostrom-org'] = org;
  if (body !== undefined) headers['content-type'] = 'application/json';
  const r = await fetch(API + path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await r.text();
  let json;
  try {
    json = text ? JSON.parse(text) : undefined;
  } catch {
    json = undefined;
  }
  return { status: r.status, json: json ?? {}, text };
}

/** The receipt id an answer names (`receiptId`, `approval.receiptId`, `receipt.id`, `gate.receiptId`), or ''. */
const receiptIn = (text) => /"receiptId"\s*:\s*"([^"]+)"/.exec(text)?.[1] ?? /"receipt"\s*:\s*\{[^{}]*"id"\s*:\s*"([^"]+)"/.exec(text)?.[1] ?? '';

/** The newest mail to `to` in Mailpit whose text holds `marker`, polled for up to 20 s. */
async function mailTo(to, marker) {
  for (let i = 0; i < 40; i++) {
    const list = await fetch(`${MAIL}/api/v1/search?query=${encodeURIComponent(`to:"${to}"`)}`).then((r) => r.json()).catch(() => ({}));
    for (const m of list.messages ?? []) {
      const full = await fetch(`${MAIL}/api/v1/message/${m.ID}`).then((r) => r.json()).catch(() => ({}));
      if ((full.Text ?? '').includes(marker)) return full;
    }
    await sleep(500);
  }
  return undefined;
}
const tokenIn = (text, page) => new RegExp(`${page}#token=([A-Za-z0-9._~%-]+)`).exec(text ?? '')?.[1];

async function signInByMail(p, email) {
  const asked = await p.call('POST', '/api/v1/auth/email', { email });
  if (asked.status >= 300) return { ok: false, detail: `POST /auth/email → ${brief(asked)}` };
  const mail = await mailTo(email, '/auth/email#token=');
  const token = tokenIn(mail?.Text, '/auth/email');
  if (!token) return { ok: false, detail: `no sign-in mail for ${email} in Mailpit` };
  const verified = await p.call('POST', '/api/v1/auth/email/verify', { token: decodeURIComponent(token) });
  if (verified.status !== 200 || !verified.json.csrfToken) return { ok: false, detail: `verify → ${brief(verified)}` };
  p.csrf = verified.json.csrfToken;
  const me = await p.call('GET', '/api/v1/auth/me');
  return { ok: me.status === 200, detail: `mail « ${mail.Subject} » read in Mailpit, link used once, /auth/me ${me.status}` };
}

async function main() {
  try {
    await journey();
  } catch (e) {
    record('X', 'Le parcours s’est arrêté sur une erreur', RED, `${e.message}${e.cause ? ` (${e.cause.message ?? e.cause})` : ''}`);
  }
  writeReport();
}

async function journey() {
  // 0. The stack answers through Caddy.
  const health = await fetch(`${API}/health`).then((r) => r.json()).catch((e) => ({ error: e.message }));
  const appHealth = await fetch(`${APP}/api/v1/health`).then((r) => r.status).catch(() => 0);
  record('S0', 'Pile debout derrière Caddy', health.status === 'ok' && appHealth === 200 ? GREEN : RED, `api /health ${JSON.stringify(health)}, app /api/v1/health ${appHealth}`);
  const instance = await fetch(`${API}/api/v1/instance`).then((r) => r.json()).catch(() => ({}));
  console.log(`instance: ${JSON.stringify(instance).slice(0, 200)}`);

  // (a) Sign-up and sign-in by e-mailed link (Mailpit), then with GitHub (fake).
  const owner = new Browser('owner');
  const ownerEmail = `alice-${run}@acme.demo`;
  const a1 = await signInByMail(owner, ownerEmail);
  record('A1', `Inscription par lien e-mail (${ownerEmail})`, a1.ok ? GREEN : RED, a1.detail);

  const gh = new Browser('github');
  let a2 = { ok: false, detail: '' };
  try {
    const start = await gh.call('GET', '/api/v1/auth/github/start?redirect=%2F', undefined, { redirect: 'manual' });
    const authorize = new URL(start.headers.get('location') ?? 'about:blank');
    if (start.status !== 302 || !authorize.pathname.endsWith('/login/oauth/authorize')) throw new Error(`start → ${brief(start)}`);
    const page = await fetch(authorize).then((r) => r.text());
    if (!page.includes('Authorize Ostrom')) throw new Error('fake GitHub authorize page not shown');
    const form = new URLSearchParams(Object.fromEntries(['client_id', 'redirect_uri', 'state', 'code_challenge', 'code_challenge_method', 'scope'].map((k) => [k, authorize.searchParams.get(k) ?? ''])));
    form.set('login', `bob-${run}`);
    const back = await fetch(new URL('/login/oauth/authorize', authorize), { method: 'POST', body: form, redirect: 'manual' });
    const callback = new URL(back.headers.get('location') ?? 'about:blank');
    const done = await gh.call('GET', callback.pathname + callback.search, undefined, { redirect: 'manual' });
    if (done.status >= 400) throw new Error(`callback → ${brief(done)}`);
    const me = await gh.call('GET', '/api/v1/auth/me');
    gh.csrf = gh.jar.get('__Host-ostrom_csrf') ?? gh.jar.get('ostrom_csrf') ?? '';
    a2 = { ok: me.status === 200 && me.text.includes(`bob-${run}`), detail: `authorize page → code → callback ${done.status} → /auth/me ${me.status} ${me.text.includes(`bob-${run}`) ? `as bob-${run}` : brief(me)}` };
  } catch (e) {
    a2 = { ok: false, detail: e.message };
  }
  record('A2', 'Connexion avec GitHub (faux GitHub local)', a2.ok ? GREEN : RED, a2.detail);

  // (b) An organization, then a second member invited by e-mail who accepts.
  let orgId = '';
  if (a1.ok) {
    const made = await owner.call('POST', '/api/v1/orgs', { name: `Acme ${run}` });
    orgId = made.json.id ?? '';
    record('B1', 'Création de l’organisation', made.status < 300 && orgId ? GREEN : RED, `POST /orgs → ${brief(made)}`);
  } else record('B1', 'Création de l’organisation', NOT_YET, 'A1 a échoué');
  owner.org = orgId;

  const reviewer = new Browser('reviewer');
  const reviewerEmail = `rev-${run}@acme.demo`;
  let joined = false;
  if (orgId) {
    const invited = await owner.call('POST', `/api/v1/orgs/${orgId}/members/invites`, { invites: [{ email: reviewerEmail, role: 'approver' }] });
    const mail = await mailTo(reviewerEmail, '/invite#token=');
    const token = tokenIn(mail?.Text, '/invite');
    const signed = token ? await signInByMail(reviewer, reviewerEmail) : { ok: false, detail: 'no invitation mail' };
    const accepted = signed.ok ? await reviewer.call('POST', '/api/v1/invitations/accept', { token: decodeURIComponent(token) }) : { status: 0, text: signed.detail };
    reviewer.org = orgId;
    const members = await owner.call('GET', `/api/v1/orgs/${orgId}/members`);
    joined = accepted.status < 300 && (members.text.includes(reviewerEmail) || members.text.includes(reviewerEmail.split('@')[0]));
    record('B2', 'Invitation d’un second membre, acceptée', joined ? GREEN : RED, `invites → ${invited.status}, mail ${token ? 'reçu' : 'absent'}, accept → ${accepted.status}, members → ${members.status}`);
  } else record('B2', 'Invitation d’un second membre, acceptée', NOT_YET, 'pas d’organisation');

  // (c) The CLI's device login (RFC 8628), the browser saying yes: the calls `ostrom login` makes.
  if (a1.ok) {
    const device = await fetch(`${API}/api/v1/auth/device`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ clientName: 'ostrom demo' }) });
    const code = await device.json().catch(() => ({}));
    const answered = code.userCode ? await owner.call('POST', '/api/v1/auth/device/answer', { userCode: code.userCode, approve: true }) : { status: 0, text: '' };
    let token = '';
    let polled = 0;
    for (let i = 0; i < 10 && !token && code.deviceCode; i++) {
      const r = await fetch(`${API}/api/v1/auth/device/token`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ deviceCode: code.deviceCode }) });
      polled = r.status;
      const text = await r.text();
      token = /"(?:secret|accessToken|access_token|token)"\s*:\s*"(o[a-z]*_[A-Za-z0-9_-]{10,})"/.exec(text)?.[1] ?? '';
      if (!token) await sleep(1000);
    }
    const me = token ? await fetch(`${API}/api/v1/auth/me`, { headers: { authorization: `Bearer ${token}` } }) : { status: 0 };
    record('C1', 'Connexion d’appareil de la CLI (les appels de `ostrom login`)', token && me.status === 200 ? GREEN : RED, `device ${device.status} (code ${code.userCode ?? '?'}), oui navigateur ${answered.status}, token ${polled}${token ? ', jeton reçu' : ''}, /auth/me ${me.status}`);
  } else record('C1', 'Connexion d’appareil de la CLI', NOT_YET, 'A1 a échoué');

  // (d) A cloud session on this machine's Docker: created, running, its terminal answering, then stopped.
  let sessionId = '';
  if (orgId) {
    const made = await owner.call('POST', '/api/v1/cloud/sessions', { agent: 'shell', name: `demo-${run}` });
    sessionId = made.json.id ?? '';
    if (!sessionId) {
      record('D1', 'Session cloud créée', made.status === 404 && /organization/i.test(made.text) ? NOT_YET : RED, `POST /cloud/sessions (Ostrom-Org ${orgId}) → ${brief(made)}${made.status === 404 ? ' — le serveur ne résout pas encore l’org d’une session navigateur (ostrom-server#64)' : ''}`);
    } else {
      let status = made.json.status;
      let last = made;
      const t0 = Date.now();
      while (status !== 'running' && Date.now() - t0 < CLOUD_TIMEOUT_S * 1000 && !['failed', 'terminated'].includes(status)) {
        await sleep(2000);
        last = await owner.call('GET', `/api/v1/cloud/sessions/${sessionId}`);
        status = last.json.status;
      }
      record('D1', 'Session cloud créée et démarrée sur Docker', status === 'running' ? GREEN : RED, `${sessionId}: ${status} (phase ${last.json.phase ?? '?'}) en ${Math.round((Date.now() - t0) / 1000)} s${last.json.failure ? `, failure ${JSON.stringify(last.json.failure)}` : ''}`);
      if (status === 'running') {
        const ticket = await owner.call('POST', `/api/v1/cloud/sessions/${sessionId}/terminal/ticket`, {});
        const echoed = await terminalEcho(sessionId, ticket.json.ticket);
        record('D2', 'Terminal de la session cloud (WebSocket, PTY de l’agent)', echoed.ok ? GREEN : RED, `ticket ${ticket.status}; ${echoed.detail}`);
        const check = env('OSTROM_DEMO_SESSION_CHECK', '');
        if (check) {
          try {
            const out = execFileSync('sh', ['-c', check], { env: { ...process.env, SESSION_ID: sessionId }, encoding: 'utf8' });
            record('D4', 'Isolation de la session cloud (réseau, UID)', GREEN, out.trim());
          } catch (e) {
            record('D4', 'Isolation de la session cloud (réseau, UID)', RED, `${e.stdout ?? ''}${e.stderr ?? ''}`.trim() || e.message);
          }
        }
      } else record('D2', 'Terminal de la session cloud', NOT_YET, 'session pas démarrée');
    }
  } else record('D1', 'Session cloud', NOT_YET, 'pas d’organisation');

  // TeamCode import: the fake TeamCode base the CLI reads (`ostrom import teamcode` itself runs on the laptop, in the film).
  const teamcodeCheck = env('OSTROM_DEMO_TEAMCODE_CHECK', '');
  if (teamcodeCheck) {
    try {
      const out = execFileSync('sh', ['-c', teamcodeCheck], { encoding: 'utf8' });
      record('I1', 'Base TeamCode factice (MySQL) lue comme par `ostrom import teamcode`', GREEN, out.trim());
    } catch (e) {
      record('I1', 'Base TeamCode factice (MySQL)', RED, `${e.stdout ?? ''}${e.stderr ?? ''}`.trim() || e.message);
    }
  }

  // (i) The TeamCode import, as `ostrom import teamcode` posts it: the plan, the import, then the owner's cutover, which
  // renews the shared accounts' tokens at their provider (the fake's token endpoints) and revives those left waiting.
  if (orgId && joined && teamcodeCheck) {
    try {
      const members = (await owner.call('GET', `/api/v1/orgs/${orgId}/members`)).json.items ?? [];
      // As the CLI maps them: by e-mail, else by login (an e-mail sign-up's login is the e-mail's local part).
      const idOf = (email) => members.find((m) => m.email === email || m.login === email.split('@')[0])?.id;
      const memberMap = Object.fromEntries([['m-alice', idOf(ownerEmail)], ['m-rev', idOf(reviewerEmail)]].filter(([, id]) => id));
      const tables = readTables(dockerQuery(env('TEAMCODE_DB_CONTAINER', 'ostrom-teamcode-db-1')), TEAM);
      const { body } = teamCodeImport(tables, demoKey(), TEAM, memberMap);
      const count = (r, action) => (r.json.items ?? []).filter((i) => i.action === action).length;
      const plan = await owner.call('POST', '/api/v1/import/teamcode?dryRun=true', body);
      const done = plan.status === 200 ? await owner.call('POST', '/api/v1/import/teamcode', body) : plan;
      const again = done.status === 200 ? await owner.call('POST', '/api/v1/import/teamcode?dryRun=true', body) : done;
      const imported = done.status === 200 && done.json.created > 0 && again.json.created === 0;
      record('I2', 'Import TeamCode (plan, import, second passage sans changement)', imported ? GREEN : RED,
        imported
          ? `${Object.keys(memberMap).length} membres associés ; plan ${plan.status} (${count(plan, 'planned')} lignes prévues), import : ${done.json.created} créées, ${done.json.skipped} sautées, ${done.json.reviveAtCutover} compte(s) en attente de la bascule ; second plan : ${again.json.created} à créer`
          : `plan → ${brief(plan)} ; import → ${brief(done)} ; second plan → ${brief(again)}`);
      const cutPlan = imported ? await owner.call('POST', '/api/v1/import/teamcode?dryRun=true&cutover=true', body) : { status: 0, text: 'I2 a échoué', json: {} };
      const cut = cutPlan.status === 200 ? await owner.call('POST', '/api/v1/import/teamcode?cutover=true', body) : cutPlan;
      const accounts = (cut.json.items ?? []).filter((i) => i.kind === 'account');
      const kept = accounts.filter((i) => i.action !== 'skipped');
      // The cutover is recorded in the audit log in the owner's name, before anything is written (ostrom-server#86).
      const audit = cut.status === 200 ? await owner.call('GET', '/api/v1/auth/me/audit?limit=50') : { status: 0, text: '' };
      const audited = audit.status === 200 && audit.text.includes('import.teamcode.cutover');
      const cutOk = cut.status === 200 && cut.json.reviveAtCutover === 0 && kept.length === accounts.length && accounts.length > 0 && (audit.status !== 200 || audited);
      const cutState = cut.status === 503 ? NOT_YET : cutOk ? GREEN : RED;
      // A revival needs an account Ostrom already holds as `reconnect_required`; the demo's are fresh, so the cutover
      // finds them up to date. The revival through the provider's token endpoint is covered by the server's tests.
      record('I3', 'Bascule de l’import par l’owner (cutover)', cutState,
        `plan ${cutPlan.status}, bascule ${cut.status} : comptes ${accounts.map((a) => `${a.name} ${a.action}`).join(', ') || 'aucun'}, ${cut.json.reviveAtCutover ?? '?'} en attente ; journal d’audit ${audit.status === 200 ? (audited ? 'avec la bascule au nom de l’owner' : 'SANS la bascule') : `non lu (${audit.status})`}${cutOk ? '' : ` ; ${brief(cut)}`}`);
    } catch (e) {
      record('I2', 'Import TeamCode', RED, e.message);
    }
  } else record('I2', 'Import TeamCode', NOT_YET, 'pas d’organisation, de second membre ou de base TeamCode');

  // (y) The yes, end to end: a workflow whose push-main gate names the second member; the owner's token asks a push to
  // main, which waits; the second member says yes from their browser with the digest they were shown; the receipt.
  if (orgId && joined) {
    const who = (await reviewer.call('GET', '/api/v1/auth/me', undefined, { org: '' })).json;
    const members = (await owner.call('GET', `/api/v1/orgs/${orgId}/members`)).json.items ?? [];
    const login = who.login ?? who.dev?.login ?? '';
    const repo = `acme/api-${run}`;
    const flow = await owner.call('POST', '/api/v1/workflows', {
      id: `demo-${run}`, name: 'Demo delivery', domain: 'delivery', status: 'accepted', foundAt: new Date().toISOString(),
      nodes: [{ id: 'push-main', kind: 'gate', label: 'Push to main', approvers: [login], actions: [{ class: 'push-main', label: 'Push to the main branch', patterns: [], repos: [repo] }] }],
      edges: [],
    });
    const pat = flow.status < 300 ? await owner.call('POST', '/api/v1/tokens', { name: `demo asker ${run}`, scopes: ['gates:ask', 'gates:read'], expiresInDays: 1 }) : flow;
    const secret = pat.json.secret ?? '';
    const sha = randomUUID().replaceAll('-', '').padEnd(40, '0').slice(0, 40);
    const ask = { repo, class: 'push-main', tool: 'Bash', command: 'git push origin main', push: { remote: 'origin', refs: [{ ref: 'refs/heads/main', sha }] } };
    const asked = secret ? await bearer(secret, 'POST', '/api/v1/gates', ask, orgId) : pat;
    const gate = asked.json.gate ?? {};
    const pending = gate.status === 'pending';
    record('Y1', 'Porte en attente d’un oui (push sur main)', pending ? GREEN : RED,
      `workflow ${flow.status}, jeton ${pat.status}, POST /gates → ${asked.status}, porte ${gate.status ?? '?'}${pending ? ` (${gate.id}), approbateur ${login}` : ` : ${brief(asked)}`}`);
    let yes = { status: 0, text: '', json: {} };
    if (pending) {
      const list = await reviewer.call('GET', '/api/v1/approvals?mine=true&status=pending&limit=50');
      const mine = (list.json.items ?? []).find((a) => a.group === gate.id || a.gate === gate.id);
      yes = mine ? await reviewer.call('POST', `/api/v1/approvals/${encodeURIComponent(mine.id)}/answer`, { answer: 'approve', shownDigest: mine.shownDigest }) : { status: 0, text: `aucune demande pour ${login} : ${brief(list)}`, json: {} };
      record('Y2', 'Le second membre dit oui depuis son navigateur', yes.status === 200 ? GREEN : RED, mine ? `demande ${mine.id}, oui → ${brief(yes)}` : yes.text);
    } else record('Y2', 'Le second membre dit oui', NOT_YET, 'aucune porte en attente (Y1)');
    if (yes.status === 200) {
      // The yes lets exactly that SHA through; another commit is a new request. The receipt is signed, names the gate
      // and who said yes; it binds the push (its refs and SHA) through the subject's digest, checked by `ostrom verify`.
      const after = await bearer(secret, 'POST', '/api/v1/gates', ask, orgId);
      const other = { ...ask, push: { ...ask.push, refs: [{ ref: 'refs/heads/main', sha: sha.replace(/^./, (c) => (c === 'f' ? '0' : 'f')) }] } };
      const next = await bearer(secret, 'POST', '/api/v1/gates', other, orgId);
      const receipt = receiptIn(yes.text) || receiptIn(after.text);
      const kept = receipt ? await owner.call('GET', `/api/v1/receipts/${encodeURIComponent(receipt)}`) : { status: 0, text: '', json: {} };
      const decision = kept.json.decisions?.[0] ?? {};
      const reviewerIds = [login, who.id, who.dev?.id, members.find((m) => m.email === reviewerEmail)?.id].filter(Boolean);
      const checks = {
        'même SHA laissé passer': after.json.gate?.status === 'approved',
        'autre SHA de nouveau en attente': next.json.gate?.status === 'pending' && next.json.gate?.id !== gate.id,
        'reçu signé': kept.status === 200 && typeof kept.json.signature === 'string',
        'porte du reçu': kept.json.subject?.kind === 'gate' && kept.json.subject?.id === gate.id && /^[0-9a-f]{64}$/.test(kept.json.subject?.digest ?? ''),
        'oui du second membre': decision.result === 'approved' && reviewerIds.includes(decision.by),
      };
      const failed = Object.entries(checks).filter(([, ok]) => !ok).map(([k]) => k);
      record('Y3', 'Le oui ne vaut que pour ce SHA, et son reçu signé nomme le second membre', failed.length === 0 ? GREEN : RED,
        failed.length === 0
          ? `même push → porte ${after.json.gate.status}, autre SHA → porte ${next.json.gate.status} (nouvelle demande) ; reçu ${receipt} signé : porte ${gate.id.slice(0, 8)}, digest ${kept.json.subject.digest.slice(0, 12)}…, oui de ${decision.by} (${decision.at})`
          : `en défaut : ${failed.join(', ')} ; même push → ${after.status} ${after.json.gate?.status ?? ''}, autre SHA → ${next.status} ${next.json.gate?.status ?? ''}, reçu ${receipt || 'absent'} → ${kept.status}, décision ${JSON.stringify(decision)}`);
    } else record('Y3', 'Reçu du oui', NOT_YET, 'pas de oui (Y2)');
  } else record('Y1', 'Porte en attente d’un oui', NOT_YET, 'pas d’organisation ou de second membre');

  // (g) Isolation: the GitHub person (no membership of Acme) sees nothing of it.
  if (orgId && a2.ok) {
    const probes = [
      ['GET', `/api/v1/orgs/${orgId}`],
      ['GET', `/api/v1/orgs/${orgId}/members`],
      ['GET', `/api/v1/orgs/${orgId}/billing`],
      ...(sessionId ? [['GET', `/api/v1/cloud/sessions/${sessionId}`]] : []),
    ];
    const leaks = [];
    for (const [m, p] of probes) {
      const r = await gh.call(m, p, undefined, { org: orgId });
      if (![401, 403, 404].includes(r.status) || r.text.includes(`Acme ${run}`) || r.text.includes(ownerEmail)) leaks.push(`${m} ${p} → ${r.status}`);
    }
    const mine = await gh.call('POST', '/api/v1/orgs', { name: `Beta ${run}` });
    const theirs = mine.json.id ? await gh.call('GET', '/api/v1/orgs', undefined, { org: '' }) : { text: '' };
    if (theirs.text.includes(`Acme ${run}`)) leaks.push('GET /orgs lists Acme');
    record('G1', 'Isolation : une autre organisation ne voit rien de la première', leaks.length === 0 ? GREEN : RED, leaks.length ? leaks.join('; ') : `${probes.length} routes de Acme refusées à bob (401/403/404), sa propre org Beta créée (${mine.status}), Acme absente de sa liste`);
  } else record('G1', 'Isolation entre organisations', NOT_YET, 'A2 ou B1 a échoué');

  // (h) Billing: the overview, then a Checkout session on Stripe's test mode (when the stack has a test key).
  if (orgId) {
    const overview = await owner.call('GET', `/api/v1/orgs/${orgId}/billing`);
    record('H1', 'Page d’abonnement (plan gratuit)', overview.status === 200 ? GREEN : RED, `GET billing → ${brief(overview)}`);
    const checkout = await owner.call('POST', `/api/v1/orgs/${orgId}/billing/checkout`, { plan: 'team', interval: 'month' });
    const url = checkout.json.url ?? '';
    const state = url.startsWith('https://checkout.stripe.com/') ? GREEN : /not configured|not enabled on this instance/i.test(checkout.text) ? NOT_YET : RED;
    record('H2', 'Checkout Stripe (mode test)', state, url ? `session Checkout ouverte (${url.slice(0, 48)}…) : payer avec 4242 4242 4242 4242 dans le navigateur` : `checkout → ${brief(checkout)}`);
  }

  // Stop the cloud session: its containers and volumes go.
  if (sessionId) {
    const stopped = await owner.call('DELETE', `/api/v1/cloud/sessions/${sessionId}`);
    let status = stopped.json.status;
    // The contract's final state is `terminated`; a 404 (the row gone) counts as deleted too.
    for (let i = 0; i < 30 && !['terminated', 'deleted'].includes(status) && stopped.status < 300; i++) {
      await sleep(2000);
      const r = await owner.call('GET', `/api/v1/cloud/sessions/${sessionId}`);
      status = r.status === 404 ? 'deleted' : r.json.status;
    }
    record('D3', 'Session cloud arrêtée et supprimée', ['terminated', 'deleted'].includes(status) ? GREEN : RED, `DELETE → ${stopped.status}, puis ${status}`);
  }

}

/** The Markdown report (REPORT), written whatever happened; exit code 1 on a red step. */
function writeReport() {
  const red = results.filter((r) => r.state === RED).length;
  const lines = [
    `# Démo locale d'Ostrom : parcours (${new Date().toISOString()})`,
    '',
    `API ${API}, console ${APP}, boîte mail ${MAIL}. Exécution ${run}.`,
    '',
    '| Étape | Ce qui est prouvé | État | Ce qui a été vu |',
    '|---|---|---|---|',
    ...results.map((r) => `| ${r.id} | ${r.title} | ${r.state} | ${r.detail.replaceAll('|', '\\|').replace(/\s*\n\s*/g, ' · ')} |`),
    '',
    `${results.filter((r) => r.state === GREEN).length} vertes, ${red} rouges, ${results.filter((r) => r.state === NOT_YET).length} pas encore possibles.`,
    '',
  ];
  writeFileSync(REPORT, lines.join('\n'));
  console.log(`report: ${REPORT}`);
  process.exitCode = red ? 1 : 0;
}

/** Attaches to the session's terminal, waits for the runner, types an echo and waits for its output. */
function terminalEcho(sessionId, ticket) {
  const marker = `ostrom-cloud-${run}`;
  return new Promise((resolve) => {
    if (!ticket) return resolve({ ok: false, detail: 'no ticket' });
    const ws = new WebSocket(`${API.replace(/^http/, 'ws')}/api/v1/cloud/sessions/${sessionId}/terminal?ticket=${encodeURIComponent(ticket)}`);
    ws.binaryType = 'arraybuffer';
    let output = '';
    let connected = false;
    let typed = 0;
    // Typed when the runner says it is connected, then again every 5 s until the shell answers: a line typed before
    // the agent's terminal has a peer is lost.
    const type = () => {
      if (ws.readyState !== WebSocket.OPEN) return;
      typed += 1;
      ws.send(new TextEncoder().encode(`echo ${marker}-$((6*7))\r`));
    };
    const retype = setInterval(type, 5000);
    const end = (ok, detail) => {
      clearTimeout(timer);
      clearInterval(retype);
      try {
        ws.close();
      } catch {
        // already closed
      }
      resolve({ ok, detail });
    };
    const timer = setTimeout(() => end(false, `no echo within 60 s; runner ${connected ? 'connected' : 'never said connected'}, typed ${typed} times; output « ${output.slice(-200)} »`), 60_000);
    ws.addEventListener('message', (e) => {
      if (typeof e.data === 'string') {
        if (/"connected"\s*:\s*true/.test(e.data)) {
          connected = true;
          setTimeout(type, 500);
        }
        return;
      }
      output += new TextDecoder().decode(e.data);
      if (output.includes(`${marker}-42`)) end(true, `typed « echo ${marker}-$((6*7)) », the agent's shell answered « ${marker}-42 »`);
    });
    ws.addEventListener('close', (e) => end(output.includes(`${marker}-42`), `closed ${e.code} ${e.reason}`));
    ws.addEventListener('error', () => {});
  });
}

await main();
