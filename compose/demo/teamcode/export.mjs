// SPDX-License-Identifier: AGPL-3.0-only
// Local demo only: the body `ostrom import teamcode` posts (contract `TeamCodeImportRequest`), built from the fake
// TeamCode base the way the CLI builds it (ostrom-cli `TeamCodePlan`): secrets opened with TeamCode's key, sent once
// in the body, never printed. TeamCode's MCP servers are remote, so only the HTTP shape is built here; a stdio variant
// is left out and said, as the CLI says a server it cannot install. The journey (journey.mjs, steps I2 and I3) posts
// it on a runner without the CLI binary; the film runs the real `ostrom import teamcode`.
import { createDecipheriv } from 'node:crypto';
import { execFileSync } from 'node:child_process';

/** The plaintext of TeamCode's envelope (`v1:` + base64url of nonce, ciphertext, tag) for `context`, or null. */
export function openEnvelope(key, envelope, context) {
  if (typeof envelope !== 'string' || !envelope.startsWith('v1:')) return null;
  const raw = Buffer.from(envelope.slice(3), 'base64url');
  if (raw.length < 12 + 16) return null;
  try {
    const decipher = createDecipheriv('aes-256-gcm', key, raw.subarray(0, 12));
    decipher.setAAD(Buffer.from(context, 'utf8'));
    decipher.setAuthTag(raw.subarray(raw.length - 16));
    return Buffer.concat([decipher.update(raw.subarray(12, raw.length - 16)), decipher.final()]).toString('utf8');
  } catch {
    return null;
  }
}

/** A JSON array of strings, as TeamCode stores tools: [] when absent, null when it is not one. */
function strings(text) {
  if (text === null || text === undefined) return [];
  try {
    const parsed = JSON.parse(text);
    return Array.isArray(parsed) && parsed.every((t) => typeof t === 'string') ? parsed : null;
  } catch {
    return null;
  }
}

/** The contract's tool mode of TeamCode's (`ALLOWLIST` → `allow`, `DENYLIST` → `deny`); `ALL` and none mean every tool. */
export function toolModeOf(mode) {
  const m = String(mode ?? '').trim().toUpperCase();
  return m === 'ALLOWLIST' || m === 'ALLOW' ? 'allow' : m === 'DENYLIST' || m === 'DENY' ? 'deny' : null;
}

/** `text` as JSON, or an error that says `what` was not the JSON expected. */
function jsonOf(text, what) {
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`${what} is not the JSON TeamCode writes`);
  }
}

const PROVIDERS = { anthropic: 'claude', claude: 'claude', openai: 'codex', codex: 'codex' };
const truthy = (v) => v === true || v === 1 || v === '1';

/**
 * The import body for `team`'s rows under `key`, and the rows it leaves out (one line each).
 *
 * @param tables `{ members, variants, policies, assignments, accounts }`, rows as the tables hold them.
 * @param memberMap TeamCode member id to Ostrom member id: assignments of an unmapped member are left out.
 * @throws Error When a secret does not open with the key (another key file, or another team).
 */
export function teamCodeImport(tables, key, team, memberMap) {
  const open = (envelope, context, what) => {
    const plain = openEnvelope(key, envelope, context);
    if (plain === null) throw new Error(`${what}: its secret does not open with this key file`);
    return plain;
  };
  const skipped = [];
  const left = new Set();
  const policies = new Map(tables.policies.map((p) => [p.variant_id, p]));
  const mcpServers = [];
  for (const v of tables.variants) {
    const policy = policies.get(v.id);
    const tools = strings(policy?.tools);
    const config = JSON.parse(v.config || '{}');
    const stdio = String(v.transport ?? config.transport ?? '').toLowerCase() === 'stdio';
    if (tools === null || stdio) {
      skipped.push(`MCP server ${v.target} (${v.name}): ${tools === null ? 'its tool policy is not a list of tool names' : 'stdio, not built by the demo'}`);
      left.add(v.id);
      continue;
    }
    mcpServers.push({
      id: v.id,
      target: v.target,
      variant: v.name,
      perMember: v.binding === 'PER_MEMBER',
      url: v.endpoint,
      credentialHeader: config.CREDENTIAL_HEADER ?? config.credentialHeader ?? null,
      sharedSecret: v.shared_secret ? open(v.shared_secret, `variant:${team}:${v.id}`, `MCP server ${v.target}`) : null,
      stdio: null,
      toolMode: toolModeOf(policy?.mode),
      tools,
    });
  }
  const assignments = tables.assignments
    .filter((a) => !left.has(a.variant_id) && a.member_id in memberMap)
    .map((a) => ({
      memberId: a.member_id,
      serverId: a.variant_id,
      memberSecret: a.member_secret ? open(a.member_secret, `variant:${team}:${a.variant_id}:${a.member_id}`, `the secret of member ${a.member_id}`) : null,
    }));
  const accounts = [];
  for (const row of tables.accounts) {
    const label = row.display_name ?? '';
    const credential = row.credential_envelope ? jsonOf(open(row.credential_envelope, `${team}:${row.id}`, `account ${label}`), `account ${label}: its credential`) : null;
    const provider = String(row.provider ?? '').trim().toLowerCase();
    const fields = [provider, row.provider_account_id, credential?.accessToken, credential?.refreshToken];
    if (typeof credential?.expiresAtMillis !== 'number' || fields.some((f) => !f)) {
      skipped.push(`account ${label}: no provider, account id, tokens or expiry in TeamCode`);
      continue;
    }
    accounts.push({
      provider: PROVIDERS[provider] ?? provider,
      providerAccountId: row.provider_account_id,
      label,
      email: row.email ?? null,
      accessToken: credential.accessToken,
      refreshToken: credential.refreshToken,
      expiresAt: new Date(credential.expiresAtMillis).toISOString(),
      disabled: truthy(row.disabled),
    });
  }
  const body = {
    members: tables.members.map((m) => ({ id: m.id, username: m.username })),
    mcpServers,
    assignments,
    accounts,
    memberMap,
  };
  return { body, skipped };
}

/** The SQL that reads one table of `team` as a single JSON array (MySQL 8 JSON_ARRAYAGG), `[]` when empty. */
export function tableQuery(table, columns, team, mcpOnly = false) {
  const pairs = columns.map((c) => `'${c}', \`${c}\``).join(', ');
  return `SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT(${pairs})), JSON_ARRAY()) FROM \`${table}\` WHERE ${mcpOnly ? "kind = 'MCP' AND " : ''}team_id = '${team.replaceAll("'", "''")}'`;
}

export const COLUMNS = {
  members: ['id', 'username'],
  variants: ['id', 'target', 'name', 'binding', 'endpoint', 'config', 'shared_secret'],
  policies: ['variant_id', 'mode', 'tools'],
  assignments: ['member_id', 'variant_id', 'member_secret'],
  accounts: ['id', 'provider', 'provider_account_id', 'display_name', 'email', 'credential_envelope', 'disabled'],
};
const TABLES = { members: 'members', variants: 'variants', policies: 'mcp_tool_policies', assignments: 'variant_assignments', accounts: 'accounts' };

/** The team's tables, each read by `query(sql)` (which returns MySQL's text answer), as `ostrom import teamcode` reads them. */
export function readTables(query, team) {
  return Object.fromEntries(Object.entries(TABLES).map(([name, table]) => {
    const sql = tableQuery(table, COLUMNS[name], team, name === 'variants' || name === 'assignments');
    return [name, jsonOf(query(sql).trim(), `the answer for table ${table}`)];
  }));
}

// The demo's query runner: the read-only user, inside the teamcode-db container. Run by the journey on the Compose
// stack (its CI run covers it), not by the unit tests.
/* node:coverage disable */
export const dockerQuery = (container) => (sql) =>
  execFileSync('docker', ['exec', '-e', 'MYSQL_PWD=demo-teamcode-ro', container, 'mysql', '-h127.0.0.1', '-uteamcode_ro', 'teamcode', '-N', '--raw', '-e', sql], { encoding: 'utf8' });
/* node:coverage enable */
