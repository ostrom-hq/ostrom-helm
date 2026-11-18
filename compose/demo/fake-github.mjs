// SPDX-License-Identifier: Apache-2.0
// A stand-in for GitHub's OAuth web flow, for the local demo stack only: the browser is sent to its authorize page,
// picks a login, and comes back to the server with a one-time code; the server exchanges the code and reads the user.
// It never reaches the real GitHub and knows no real account. Routes (the server's OSTROM_GITHUB_WEB_URL and
// OSTROM_GITHUB_API_URL = <web>/api):
//   GET  /login/oauth/authorize       the page with the login to sign in as
//   POST /login/oauth/authorize       back to redirect_uri with code and state
//   POST /login/oauth/access_token    the code (once) for a token; checks client_id, client_secret, code_verifier (S256)
//   GET  /api/user, /api/user/emails  who the token is
// It also stands in for the token endpoints of the shared accounts' providers (the server's
// OSTROM_SHARING_CLAUDE_TOKEN_URL and OSTROM_SHARING_CODEX_TOKEN_URL), for the import's cutover:
//   POST /claude/oauth/token, /codex/oauth/token   a refresh token for a new pair, naming the account it is of when
//                                                  the fake knows it (the seeded TeamCode accounts); `invalid_grant`
//                                                  for a revoked one
//   GET  /_demo/refreshed                          the providers renewed so far, in order (read by the journey)
import { createHash, randomBytes } from 'node:crypto';
import { createServer } from 'node:http';
import { pathToFileURL } from 'node:url';
import { SEED_ACCOUNT_OF } from './teamcode/seed.mjs';

const LOGIN = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$/;

const escapeHtml = (s) => String(s).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

/** The authorize page: one form, the login typed or picked, the OAuth parameters carried along. */
export function authorizePage(params) {
  const hidden = ['client_id', 'redirect_uri', 'state', 'code_challenge', 'code_challenge_method', 'scope']
    .map((k) => `<input type="hidden" name="${k}" value="${escapeHtml(params.get(k) ?? '')}">`)
    .join('');
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Sign in to GitHub (local demo)</title>
<style>body{font:15px -apple-system,Segoe UI,sans-serif;background:#f6f8fa;color:#1f2328;display:grid;place-items:center;min-height:100vh;margin:0}
form{background:#fff;border:1px solid #d1d9e0;border-radius:6px;padding:24px;width:320px}h1{font-size:20px;margin:0 0 4px}
p{color:#59636e;margin:0 0 16px}input[type=text]{width:100%;box-sizing:border-box;padding:8px;font:inherit;border:1px solid #d1d9e0;border-radius:6px}
button{margin-top:16px;width:100%;padding:8px;font:inherit;font-weight:600;color:#fff;background:#1f883d;border:0;border-radius:6px}</style></head>
<body><form method="post" action="/login/oauth/authorize"><h1>Authorize Ostrom</h1><p>Local demo GitHub: no real account.</p>
<label for="login">GitHub login</label><input type="text" id="login" name="login" value="${escapeHtml(params.get('login') ?? 'octo-dev')}" autofocus>
${hidden}<button type="submit" id="authorize">Authorize</button></form></body></html>`;
}

/** A JWT with [claims] and no signature: the server reads an id_token's claims, it does not verify them. */
function unsignedJwt(claims) {
  const part = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  return `${part({ alg: 'none', typ: 'JWT' })}.${part(claims)}.`;
}

/** The fake's state and request handler; `clientId` and `clientSecret` are the OAuth app the server is given. */
export function createFakeGitHub({ clientId, clientSecret, accountOf = {} }) {
  // Whose each refresh token is (refresh token → provider account id); a pair the fake issues stays its account's.
  const owners = new Map(Object.entries(accountOf));
  const codes = new Map();
  const tokens = new Map();
  const users = new Map();
  const refreshed = [];
  const userOf = (login) => {
    if (!users.has(login)) users.set(login, { login, id: 5000 + users.size, email: `${login.toLowerCase()}@users.github.demo` });
    return users.get(login);
  };
  const send = (res, status, body, headers = {}) => {
    const html = typeof body === 'string';
    res.writeHead(status, { 'content-type': html ? 'text/html; charset=utf-8' : 'application/json', 'cache-control': 'no-store', ...headers });
    res.end(html ? body : JSON.stringify(body));
  };

  const handle = (method, path, query, form, authorization, res) => {
    if (method === 'GET' && path === '/login/oauth/authorize') {
      if (query.get('client_id') !== clientId || !query.get('redirect_uri')) return send(res, 400, { message: 'unknown client or no redirect_uri' });
      return send(res, 200, authorizePage(query));
    }
    if (method === 'POST' && path === '/login/oauth/authorize') {
      const login = String(form.login ?? '').trim();
      if (!LOGIN.test(login) || form.client_id !== clientId || !URL.canParse(String(form.redirect_uri ?? ''))) {
        return send(res, 400, { message: 'bad login, client or redirect_uri' });
      }
      const code = randomBytes(16).toString('hex');
      codes.set(code, { login, challenge: form.code_challenge ?? '', redirectUri: form.redirect_uri });
      const back = new URL(form.redirect_uri);
      back.searchParams.set('code', code);
      if (form.state) back.searchParams.set('state', form.state);
      return send(res, 302, '', { location: back.toString() });
    }
    if (method === 'POST' && path === '/login/oauth/access_token') {
      const entry = codes.get(String(form.code));
      codes.delete(String(form.code));
      if (form.client_id !== clientId || form.client_secret !== clientSecret) return send(res, 200, { error: 'incorrect_client_credentials' });
      if (!entry) return send(res, 200, { error: 'bad_verification_code' });
      const verifier = String(form.code_verifier ?? '');
      if (entry.challenge && createHash('sha256').update(verifier).digest('base64url') !== entry.challenge) {
        return send(res, 200, { error: 'bad_verification_code', error_description: 'code_verifier does not match' });
      }
      const token = `gho_demo_${randomBytes(12).toString('hex')}`;
      tokens.set(token, userOf(entry.login));
      return send(res, 200, { access_token: token, token_type: 'bearer', scope: 'read:user,user:email' });
    }
    if (method === 'POST' && (path === '/claude/oauth/token' || path === '/codex/oauth/token')) {
      const refresh = String(form.refresh_token ?? '');
      if (form.grant_type !== 'refresh_token' || refresh === '' || refresh.startsWith('revoked')) return send(res, 400, { error: 'invalid_grant' });
      const provider = path.split('/')[1];
      refreshed.push(provider);
      const pair = { access_token: `${provider}-access-demo-${randomBytes(8).toString('hex')}`, refresh_token: `${provider}-refresh-demo-${randomBytes(8).toString('hex')}`, expires_in: 28800 };
      // The provider names the account the tokens are of, as the real ones do (Claude: `account.uuid`; OpenAI: the
      // `chatgpt_account_id` claim of the id_token); a token the fake does not know is nobody's, and named so: not at all.
      const owner = owners.get(refresh);
      if (owner) {
        owners.set(pair.refresh_token, owner);
        if (provider === 'claude') pair.account = { uuid: owner, email_address: `${owner}@users.provider.demo` };
        else pair.id_token = unsignedJwt({ 'https://api.openai.com/auth': { chatgpt_account_id: owner } });
      }
      return send(res, 200, pair);
    }
    const user = tokens.get(authorization.replace(/^(token|bearer)\s+/i, ''));
    if (method === 'GET' && (path === '/api/user' || path === '/api/user/emails')) {
      if (!user) return send(res, 401, { message: 'Bad credentials' });
      if (path === '/api/user') return send(res, 200, { login: user.login, id: user.id, type: 'User', name: user.login });
      return send(res, 200, [{ email: user.email, primary: true, verified: true }]);
    }
    if (method === 'GET' && path === '/health') return send(res, 200, { status: 'ok' });
    // The demo's journey reads which providers' tokens were renewed (the cutover's revival), never a token.
    if (method === 'GET' && path === '/_demo/refreshed') return send(res, 200, { refreshed });
    return send(res, 404, { message: 'Not Found' });
  };

  const listener = (req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      const url = new URL(req.url, 'http://fake');
      const type = req.headers['content-type'] ?? '';
      let form = {};
      try {
        form = type.includes('json') ? JSON.parse(raw || '{}') : Object.fromEntries(new URLSearchParams(raw));
      } catch {
        return send(res, 400, { message: 'Problems parsing JSON' });
      }
      // A JSON body that is not an object (null, an array, a number) is a bad request, never a crash.
      if (form === null || typeof form !== 'object' || Array.isArray(form)) return send(res, 400, { message: 'Body must be an object' });
      handle(req.method, url.pathname, url.searchParams, form, req.headers.authorization ?? '', res);
    });
  };
  return { listener, users, refreshed };
}

// The process entry point: run by the Compose demo (its CI run covers it), not by the unit tests.
/* node:coverage disable */
if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  const { listener } = createFakeGitHub({
    clientId: process.env.FAKE_GITHUB_CLIENT_ID ?? '',
    clientSecret: process.env.FAKE_GITHUB_CLIENT_SECRET ?? '',
    accountOf: SEED_ACCOUNT_OF,
  });
  const port = Number(process.env.PORT ?? 8080);
  createServer(listener).listen(port, '0.0.0.0', () => console.log(`fake GitHub on :${port}`));
}
/* node:coverage enable */
