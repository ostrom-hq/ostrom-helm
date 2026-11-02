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
const AT = 1793318400000; // 2026-10-30T00:00:00Z, every created_at and updated_at

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

/** The team: three members, four MCP servers (one Ostrom cannot install), their policies, three accounts. */
export function seedSql(key) {
  const member = (id, username, role) => ({ id, team_id: TEAM, username, password_hash: '$argon2id$demo', role, is_owner: role === 'OWNER', disabled: false, must_change_password: false });
  const members = [member('m-alice', 'alice', 'OWNER'), member('m-rev', 'rev', 'MEMBER'), member('m-dev', 'dev-2', 'MEMBER')];
  const variant = (id, target, name, binding, endpoint, config, secret) => ({
    id, team_id: TEAM, kind: 'MCP', target, name, binding, version: 1, endpoint, config: JSON.stringify(config),
    shared_secret: secret === null ? null : seal(key, secret, `variant:${TEAM}:${id}`), created_at: AT, updated_at: AT,
  });
  const variants = [
    variant('v-github', 'github', 'GitHub (team)', 'SHARED', 'https://api.githubcopilot.com/mcp/', { transport: 'http', CREDENTIAL_HEADER: 'Authorization' }, 'Bearer ghp_demo_not_a_real_token'),
    variant('v-files', 'filesystem', 'Workspace files', 'SHARED', null, { transport: 'stdio', command: 'npx', args: ['-y', '@modelcontextprotocol/server-filesystem', '/workspace'] }, null),
    variant('v-linear', 'linear', 'Linear (each member)', 'PER_MEMBER', null, { transport: 'stdio', command: 'npx', args: ['-y', 'linear-mcp-server'] }, null),
    variant('v-docker', 'postgres', 'Local Postgres in Docker', 'SHARED', null, { transport: 'stdio', command: 'docker', args: ['run', '-i', 'mcp/postgres'] }, null),
  ];
  const policy = (variant_id, mode, tools) => ({ variant_id, team_id: TEAM, mode, tools: JSON.stringify(tools), updated_at: AT });
  const policies = [
    policy('v-github', 'ALLOWLIST', ['get_issue', 'list_pull_requests', 'create_pull_request']),
    policy('v-files', 'ALL', []),
    policy('v-linear', 'ALLOWLIST', ['list_issues', 'create_issue']),
    policy('v-docker', 'ALL', []),
  ];
  const assign = (member_id, variant_id, target, secret) => ({
    member_id, kind: 'MCP', target, team_id: TEAM, variant_id, source: 'ADMIN',
    member_secret: secret === null ? null : seal(key, secret, `variant:${TEAM}:${variant_id}:${member_id}`), assigned_at: AT,
  });
  const assignments = [
    assign('m-alice', 'v-github', 'github', null),
    assign('m-rev', 'v-github', 'github', null),
    assign('m-alice', 'v-files', 'filesystem', null),
    assign('m-alice', 'v-linear', 'linear', JSON.stringify({ LINEAR_API_KEY: 'lin_api_demo_alice' })),
    assign('m-dev', 'v-linear', 'linear', JSON.stringify({ LINEAR_API_KEY: 'lin_api_demo_dev' })),
  ];
  const account = (id, display_name, email, credential, disabled = false) => ({
    id, team_id: TEAM, provider: 'anthropic', provider_account_id: credential ? `acct-${id}` : '', organization_id: 'org-demo', display_name, email,
    credential_version: 1, credential_envelope: credential ? seal(key, JSON.stringify(credential), `${TEAM}:${id}`) : '', disabled,
    pool_id: null, priority: 0, state: 'ACTIVE', cooldown_until: 0, refresh_pending: false, refresh_started_at: 0, enrolled_by: 'm-alice',
  });
  const accounts = [
    account('a-max-1', 'Claude Max 1', 'max1@acme.demo', { accessToken: 'sk-ant-oat-demo-1', refreshToken: 'sk-ant-ort-demo-1', expiresAtMillis: AT + 30 * 86400000 }),
    account('a-max-2', 'Claude Max 2 (paused)', 'max2@acme.demo', { accessToken: 'sk-ant-oat-demo-2', refreshToken: 'sk-ant-ort-demo-2', expiresAtMillis: AT + 30 * 86400000 }, true),
    account('a-never', 'Never finished', null, null),
  ];
  return [
    '-- Generated by seed.mjs from key.txt (fake, public): do not edit, run `node demo/teamcode/seed.mjs`.',
    insert('teams', [{ id: TEAM, name: 'Acme (TeamCode)' }]),
    insert('members', members),
    insert('variants', variants),
    insert('mcp_tool_policies', policies),
    insert('variant_assignments', assignments),
    insert('accounts', accounts),
  ].join('\n');
}

/** The demo key: key.txt, 32 bytes in base64, as TeamCode's TEAMCODE_ENCRYPTION_KEY. */
export const demoKey = () => Buffer.from(readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'key.txt'), 'utf8').trim(), 'base64');

// The process entry point, run by hand to regenerate 02-seed.sql; the unit tests check the file it wrote.
/* node:coverage disable */
if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) process.stdout.write(seedSql(demoKey()));
/* node:coverage enable */
