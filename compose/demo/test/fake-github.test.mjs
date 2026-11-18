// SPDX-License-Identifier: Apache-2.0
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { after, before, test } from 'node:test';
import { authorizePage, createFakeGitHub } from '../fake-github.mjs';

let base = '';
let server;
let fake;
before(async () => {
  fake = createFakeGitHub({ clientId: 'cid', clientSecret: 'csec', accountOf: { 'sk-ant-ort-demo-1': 'acct-a-max-1', 'rt-codex': 'acct-c-1' } });
  server = createServer(fake.listener);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${server.address().port}`;
});
after(() => server.close());

const verifier = 'v'.repeat(48);
const challenge = createHash('sha256').update(verifier).digest('base64url');
const form = (o) => ({ method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(o), redirect: 'manual' });
async function codeFor(login, extra = {}) {
  const r = await fetch(`${base}/login/oauth/authorize`, form({ login, client_id: 'cid', redirect_uri: 'http://app.test/cb', state: 's1', code_challenge: challenge, ...extra }));
  assert.equal(r.status, 302);
  const to = new URL(r.headers.get('location'));
  assert.equal(to.searchParams.get('state'), 's1');
  return to.searchParams.get('code');
}
const exchange = (code, o = {}) =>
  fetch(`${base}/login/oauth/access_token`, form({ code, client_id: 'cid', client_secret: 'csec', code_verifier: verifier, ...o })).then((r) => r.json());

test('authorize page: shown for the known client, escapes what it echoes, refused otherwise', async () => {
  const ok = await fetch(`${base}/login/oauth/authorize?client_id=cid&redirect_uri=http://app.test/cb&state=%22%3E%3Cx`);
  assert.equal(ok.status, 200);
  const html = await ok.text();
  assert.match(html, /Authorize Ostrom/);
  assert.ok(!html.includes('"><x'));
  assert.match(authorizePage(new URLSearchParams()), /value="octo-dev"/);
  assert.equal((await fetch(`${base}/login/oauth/authorize?client_id=other&redirect_uri=x`)).status, 400);
  assert.equal((await fetch(`${base}/login/oauth/authorize?client_id=cid`)).status, 400);
});

test('code once for a token, with the right client and verifier; the token reads the user and their e-mail', async () => {
  const code = await codeFor('octo-dev');
  const t = await exchange(code);
  assert.match(t.access_token, /^gho_demo_/);
  assert.deepEqual(await exchange(code), { error: 'bad_verification_code' });
  const auth = { headers: { authorization: `token ${t.access_token}` } };
  assert.deepEqual(await fetch(`${base}/api/user`, auth).then((r) => r.json()), { login: 'octo-dev', id: 5000, type: 'User', name: 'octo-dev' });
  assert.deepEqual(await fetch(`${base}/api/user/emails`, auth).then((r) => r.json()), [{ email: 'octo-dev@users.github.demo', primary: true, verified: true }]);
  assert.equal((await fetch(`${base}/api/user`)).status, 401);
});

test('refusals: bad login or client, wrong secret, wrong verifier, no state carried, JSON body, unknown routes', async () => {
  assert.equal((await fetch(`${base}/login/oauth/authorize`, form({ login: '-bad', client_id: 'cid', redirect_uri: 'http://x/cb' }))).status, 400);
  assert.equal((await fetch(`${base}/login/oauth/authorize`, form({ login: 'ok', client_id: 'no', redirect_uri: 'http://x/cb' }))).status, 400);
  assert.equal((await fetch(`${base}/login/oauth/authorize`, form({ login: 'ok', client_id: 'cid' }))).status, 400);
  assert.deepEqual(await exchange(await codeFor('a1'), { client_secret: 'nope' }), { error: 'incorrect_client_credentials' });
  assert.equal((await exchange(await codeFor('a2'), { code_verifier: 'wrong' })).error, 'bad_verification_code');
  const noState = await fetch(`${base}/login/oauth/authorize`, form({ login: 'a3', client_id: 'cid', redirect_uri: 'http://x/cb' }));
  const code = new URL(noState.headers.get('location')).searchParams;
  assert.equal(code.get('state'), null);
  const json = await fetch(`${base}/login/oauth/access_token`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ code: code.get('code'), client_id: 'cid', client_secret: 'csec' }) }).then((r) => r.json());
  assert.match(json.access_token, /^gho_demo_/);
  assert.equal((await fetch(`${base}/login/oauth/access_token`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{' })).status, 400);
  assert.equal((await fetch(`${base}/nope`)).status, 404);
  assert.deepEqual(await fetch(`${base}/health`).then((r) => r.json()), { status: 'ok' });
  const raw = await fetch(`${base}/login/oauth/access_token`, { method: 'POST', body: 'code=zzz&client_id=cid&client_secret=csec' }).then((r) => r.json());
  assert.deepEqual(raw, { error: 'bad_verification_code' });
});

test('edge bodies: no content type, an empty JSON body, an authorize without login, a code without its verifier', async () => {
  const { request } = await import('node:http');
  const status = await new Promise((resolve) => {
    const r = request(`${base}/login/oauth/access_token`, { method: 'POST' }, (res) => {
      res.resume();
      resolve(res.statusCode);
    });
    r.end();
  });
  assert.equal(status, 200);
  const empty = await fetch(`${base}/login/oauth/access_token`, { method: 'POST', headers: { 'content-type': 'application/json' } }).then((r) => r.json());
  assert.deepEqual(empty, { error: 'incorrect_client_credentials' });
  assert.equal((await fetch(`${base}/login/oauth/authorize`, form({ client_id: 'cid', redirect_uri: 'http://x/cb' }))).status, 400);
  const code = await codeFor('a4');
  const noVerifier = await fetch(`${base}/login/oauth/access_token`, form({ code, client_id: 'cid', client_secret: 'csec' })).then((r) => r.json());
  assert.equal(noVerifier.error, 'bad_verification_code');
});

test('bodies that would crash a careless fake: a redirect_uri that is no URL, JSON that is not an object', async () => {
  assert.equal((await fetch(`${base}/login/oauth/authorize`, form({ login: 'ok', client_id: 'cid', redirect_uri: 'notaurl' }))).status, 400);
  for (const body of ['null', '[1]', '7']) {
    const r = await fetch(`${base}/login/oauth/access_token`, { method: 'POST', headers: { 'content-type': 'application/json' }, body });
    assert.equal(r.status, 400, body);
  }
  assert.deepEqual(await fetch(`${base}/health`).then((r) => r.json()), { status: 'ok' });
});

test('the providers\' token endpoints: a refresh token for a new pair, a revoked or missing one refused', async () => {
  const post = (path, body) => fetch(`${base}${path}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
  const claude = await post('/claude/oauth/token', { grant_type: 'refresh_token', refresh_token: 'sk-ant-ort-demo-1', client_id: 'x' });
  assert.equal(claude.status, 200);
  const pair = await claude.json();
  assert.match(pair.access_token, /^claude-access-demo-[0-9a-f]{16}$/);
  assert.match(pair.refresh_token, /^claude-refresh-demo-/);
  assert.equal(pair.expires_in, 28800);
  // Claude names the account its tokens are of (`account.uuid`), and the pair it issued stays that account's.
  assert.equal(pair.account.uuid, 'acct-a-max-1');
  const rotated = await post('/claude/oauth/token', { grant_type: 'refresh_token', refresh_token: pair.refresh_token }).then((r) => r.json());
  assert.equal(rotated.account.uuid, 'acct-a-max-1');
  const codex = await fetch(`${base}/codex/oauth/token`, form({ grant_type: 'refresh_token', refresh_token: 'rt' }));
  assert.equal(codex.status, 200);
  // A token the fake does not know is nobody's: the answer names no account.
  const nobody = await codex.json();
  assert.equal(nobody.account, undefined);
  assert.equal(nobody.id_token, undefined);
  // OpenAI names it in the id_token's claims.
  const known = await fetch(`${base}/codex/oauth/token`, form({ grant_type: 'refresh_token', refresh_token: 'rt-codex' })).then((r) => r.json());
  const claims = JSON.parse(Buffer.from(known.id_token.split('.')[1], 'base64url').toString('utf8'));
  assert.equal(claims['https://api.openai.com/auth'].chatgpt_account_id, 'acct-c-1');
  assert.deepEqual(fake.refreshed, ['claude', 'claude', 'codex', 'codex']);
  for (const body of [{ grant_type: 'refresh_token', refresh_token: 'revoked-1' }, { grant_type: 'refresh_token' }, { grant_type: 'password', refresh_token: 'rt' }]) {
    const r = await post('/claude/oauth/token', body);
    assert.equal(r.status, 400);
    assert.deepEqual(await r.json(), { error: 'invalid_grant' });
  }
  assert.deepEqual(fake.refreshed, ['claude', 'claude', 'codex', 'codex']);
  // The journey reads the renewals (providers only, never a token) to see the cutover's revival.
  assert.deepEqual(await fetch(`${base}/_demo/refreshed`).then((r) => r.json()), { refreshed: ['claude', 'claude', 'codex', 'codex'] });
});
