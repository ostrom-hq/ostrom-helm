// SPDX-License-Identifier: AGPL-3.0-only
// Local demo only: the rows of a fake TeamCode team (team `default`), for `ostrom import teamcode` against the demo's
// MySQL (teamcode-db). Secrets are sealed the way TeamCode's CredentialCipher seals them: `v1:` then base64url without
// padding of a 12-byte nonce, the AES-256-GCM ciphertext and its tag, the context as associated data
// (`variant:<team>:<variant>`, `variant:<team>:<variant>:<member>`, `<team>:<account>`). The key is the demo's own
// (key.txt, fake, public): nothing here is a real secret. Nonces come from the context so the file is the same at
// every run. Usage: node demo/teamcode/seed.mjs > demo/teamcode/02-seed.sql
import { createCipheriv, createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

export const TEAM = 'default';

/** The tokens of the team's Claude accounts; an account's provider id is `acct-<id>`. */
const SEED_TOKENS = {
  'a-max-1': { accessToken: 'sk-ant-oat-demo-1', refreshToken: 'sk-ant-ort-demo-1' },
  'a-max-2': { accessToken: 'sk-ant-oat-demo-2', refreshToken: 'sk-ant-ort-demo-2' },
};

/**
 * Whose each seeded refresh token is, as the provider knows it (refresh token → provider account id): the fake's token
 * endpoint names that account when it renews them, as Claude's does (`account.uuid`, ostrom-server#134).
 */
export const SEED_ACCOUNT_OF = Object.fromEntries(Object.entries(SEED_TOKENS).map(([id, t]) => [t.refreshToken, `acct-${id}`]));
const AT = 1793318400000; // 2026-10-30T00:00:00Z, every created_at and updated_at
const EXPIRES = 2108937600000; // 2036-10-30T00:00:00Z: the demo's tokens never expire during a demo

/** TeamCode's envelope of `plaintext` for `context` under the 32-byte `key`. */
export function seal(key, plaintext, context) {
  const nonce = createHash('sha256').update(`nonce:${context}`).digest().subarray(0, 12);
  const cipher = createCipheriv('aes-256-gcm', key, nonce);
  cipher.setAAD(Buffer.from(context, 'utf8'));
  const sealed = Buffer.concat([nonce, cipher.update(plaintext, 'utf8'), cipher.final(), cipher.getAuthTag()]);
  return `v1:${sealed.toString('base64url')}`;
}

const q = (v) => (v === null ? 'NULL' : typeof v === 'number' || typeof v === 'boolean' ? String(Number(v)) : `'${String(v).replaceAll('\\', '\\\\').replaceAll("'", "''")}'`);
const insert = (table, rows) =>
  `INSERT INTO \`${table}\` (${Object.keys(rows[0]).map((c) => `\`${c}\``).join(', ')}) VALUES\n` +
  rows.map((r) => `  (${Object.values(r).map(q).join(', ')})`).join(',\n') +
  ';\n';

/** The team's rows by table: three members, four remote MCP servers, two tool allowlists, five assignments, three accounts. */
export function seedRows(key) {
  const member = (id, username, role) => ({ id, team_id: TEAM, username, password_hash: '$argon2id$demo', role, is_owner: role === 'OWNER', disabled: false, must_change_password: false });
  const members = [member('m-alice', 'alice', 'OWNER'), member('m-rev', 'rev', 'MEMBER'), member('m-dev', 'dev-2', 'MEMBER')];
  // TeamCode's MCP servers are remote (HTTP) only; config is a flat map of strings (`credentialHeader`, else
  // Authorization with `Bearer <secret>`); a secret is the bare token, shared or one per member.
  const variant = (id, target, name, binding, endpoint, config, secret) => ({
    id, team_id: TEAM, kind: 'MCP', target, name, binding, version: 1, endpoint, config: JSON.stringify(config),
    shared_secret: secret === null ? null : seal(key, secret, `variant:${TEAM}:${id}`), created_at: AT, updated_at: AT,
  });
  const variants = [
    variant('v-github', 'github', 'GitHub (team)', 'SHARED', 'https://api.githubcopilot.com/mcp/', {}, 'ghp_demo_not_a_real_token'),
    variant('v-linear', 'linear', 'Linear (each member)', 'PER_MEMBER', 'https://mcp.linear.app/mcp', {}, null),
    variant('v-sentry', 'sentry', 'Sentry', 'SHARED', 'https://mcp.sentry.dev/mcp', { credentialHeader: 'X-Sentry-Token' }, 'sntrys_demo_not_a_real_token'),
    variant('v-docs', 'docs', 'Public docs', 'SHARED', 'https://mcp.context7.com/mcp', {}, null),
  ];
  // TeamCode stores a row only for an allowlist: a server without one exposes every tool.
  const policy = (variant_id, tools) => ({ variant_id, team_id: TEAM, mode: 'ALLOWLIST', tools: JSON.stringify(tools), updated_at: AT });
  const policies = [
    policy('v-github', ['get_issue', 'list_pull_requests', 'create_pull_request']),
    policy('v-linear', ['list_issues', 'create_issue']),
  ];
  const assign = (member_id, variant_id, target, secret) => ({
    member_id, kind: 'MCP', target, team_id: TEAM, variant_id, source: 'DIRECT',
    member_secret: secret === null ? null : seal(key, secret, `variant:${TEAM}:${variant_id}:${member_id}`), assigned_at: AT,
  });
  const assignments = [
    assign('m-alice', 'v-github', 'github', null),
    assign('m-rev', 'v-github', 'github', null),
    assign('m-alice', 'v-linear', 'linear', 'lin_api_demo_alice'),
    assign('m-rev', 'v-linear', 'linear', 'lin_api_demo_rev'),
    assign('m-dev', 'v-sentry', 'sentry', null),
  ];
  const account = (id, display_name, email, credential, disabled = false) => ({
    id, team_id: TEAM, provider: 'anthropic', provider_account_id: credential ? `acct-${id}` : '', organization_id: 'org-demo', display_name, email,
    credential_version: 1, credential_envelope: credential ? seal(key, JSON.stringify(credential), `${TEAM}:${id}`) : '', disabled,
    pool_id: null, priority: 0, state: credential ? 'ACTIVE' : 'PENDING', cooldown_until: 0, refresh_pending: false, refresh_started_at: 0, enrolled_by: 'm-alice',
  });
  const accounts = [
    account('a-max-1', 'Claude Max 1', 'max1@acme.demo', { ...SEED_TOKENS['a-max-1'], expiresAtMillis: EXPIRES }),
    account('a-max-2', 'Claude Max 2 (paused)', 'max2@acme.demo', { ...SEED_TOKENS['a-max-2'], expiresAtMillis: EXPIRES }, true),
    account('a-never', 'Never finished', null, null),
  ];
  return { teams: [{ id: TEAM, name: 'Acme (TeamCode)' }], members, variants, mcp_tool_policies: policies, variant_assignments: assignments, accounts };
}

/** The SQL that inserts [seedRows], table by table in the order of their foreign keys. */
export function seedSql(key) {
  const rows = seedRows(key);
  return [
    '-- Generated by seed.mjs from key.txt (fake, public): do not edit, run `node demo/teamcode/seed.mjs`.',
    ...['teams', 'members', 'variants', 'mcp_tool_policies', 'variant_assignments', 'accounts'].map((t) => insert(t, rows[t])),
  ].join('\n');
}

/** The demo key: key.txt, 32 bytes in base64, as TeamCode's TEAMCODE_ENCRYPTION_KEY. */
export const demoKey = () => Buffer.from(readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'key.txt'), 'utf8').trim(), 'base64');

// The process entry point, run by hand to regenerate 02-seed.sql; the unit tests check the file it wrote.
/* node:coverage disable */
if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) process.stdout.write(seedSql(demoKey()));
/* node:coverage enable */
