// SPDX-License-Identifier: AGPL-3.0-only
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { COLUMNS, openEnvelope, readTables, tableQuery, teamCodeImport, toolModeOf } from '../teamcode/export.mjs';
import { demoKey, seal, seedRows, TEAM } from '../teamcode/seed.mjs';

const TABLE_OF = { members: 'members', variants: 'variants', mcp_tool_policies: 'policies', variant_assignments: 'assignments', accounts: 'accounts' };

/** MySQL's answer to [tableQuery], from the seed rows: booleans as MySQL's JSON gives them (0/1). */
function fakeQuery(key) {
  const rows = seedRows(key);
  const seen = [];
  const query = (sql) => {
    seen.push(sql);
    const table = /FROM `([a-z_]+)`/.exec(sql)[1];
    const name = TABLE_OF[table];
    const picked = rows[table].map((r) => Object.fromEntries(COLUMNS[name].map((c) => [c, typeof r[c] === 'boolean' ? Number(r[c]) : r[c]])));
    return `${JSON.stringify(picked)}\n`;
  };
  return { query, seen };
}

test('the import body of the demo team is the one `ostrom import teamcode` builds', () => {
  const key = demoKey();
  const { query, seen } = fakeQuery(key);
  const tables = readTables(query, TEAM);
  assert.equal(seen.length, 5);
  assert.match(seen.find((s) => s.includes('`variants`')), /WHERE kind = 'MCP' AND team_id = 'default'/);
  assert.match(seen.find((s) => s.includes('`members`')), /^SELECT COALESCE\(JSON_ARRAYAGG\(JSON_OBJECT\('id', `id`, 'username', `username`\)\), JSON_ARRAY\(\)\) FROM `members` WHERE team_id = 'default'$/);

  const { body, skipped } = teamCodeImport(tables, key, TEAM, { 'm-alice': 'o-alice', 'm-rev': 'o-rev' });
  assert.deepEqual(body.members, [{ id: 'm-alice', username: 'alice' }, { id: 'm-rev', username: 'rev' }, { id: 'm-dev', username: 'dev-2' }]);
  assert.deepEqual(body.mcpServers.map((s) => [s.id, s.perMember, s.sharedSecret, s.credentialHeader, s.toolMode, s.tools.length]), [
    ['v-github', false, 'ghp_demo_not_a_real_token', null, 'allow', 3],
    ['v-linear', true, null, null, 'allow', 2],
    ['v-sentry', false, 'sntrys_demo_not_a_real_token', 'X-Sentry-Token', null, 0],
    ['v-docs', false, null, null, null, 0],
  ]);
  // m-dev has no Ostrom member: its assignment (and its secret) stays out.
  assert.deepEqual(body.assignments, [
    { memberId: 'm-alice', serverId: 'v-github', memberSecret: null },
    { memberId: 'm-rev', serverId: 'v-github', memberSecret: null },
    { memberId: 'm-alice', serverId: 'v-linear', memberSecret: 'lin_api_demo_alice' },
    { memberId: 'm-rev', serverId: 'v-linear', memberSecret: 'lin_api_demo_rev' },
  ]);
  assert.deepEqual(body.accounts.map((a) => [a.provider, a.providerAccountId, a.label, a.disabled, a.refreshToken]), [
    ['claude', 'acct-a-max-1', 'Claude Max 1', false, 'sk-ant-ort-demo-1'],
    ['claude', 'acct-a-max-2', 'Claude Max 2 (paused)', true, 'sk-ant-ort-demo-2'],
  ]);
  assert.equal(body.accounts[0].expiresAt, '2036-10-30T00:00:00.000Z');
  assert.deepEqual(skipped, ['account Never finished: no provider, account id, tokens or expiry in TeamCode']);
});

test('a stdio server, an unreadable tool list and an account without email or label are said, not sent', () => {
  const key = demoKey();
  const tables = {
    members: [],
    variants: [
      { id: 'v-s', target: 'fs', name: 'Files', binding: 'SHARED', endpoint: null, config: '{"transport":"stdio"}', shared_secret: null },
      { id: 'v-b', target: 'bad', name: 'Bad', binding: 'SHARED', endpoint: 'https://x', config: '', shared_secret: null },
      { id: 'v-n', target: 'num', name: 'Num', binding: 'SHARED', endpoint: 'https://y', config: '{"CREDENTIAL_HEADER":"X-Key"}', shared_secret: null },
      { id: 'v-t', target: 'tr', name: 'Transport', binding: 'SHARED', endpoint: 'https://z', config: '{}', transport: 'HTTP', shared_secret: null },
    ],
    policies: [
      { variant_id: 'v-b', mode: 'ALLOWLIST', tools: 'not json' },
      { variant_id: 'v-n', mode: 'ALLOWLIST', tools: '[1]' },
    ],
    assignments: [{ member_id: 'm', variant_id: 'v-s', member_secret: null }],
    accounts: [{ id: 'a', provider: 'openai', provider_account_id: 'p', display_name: null, email: null, credential_envelope: seal(key, JSON.stringify({ accessToken: 'a', refreshToken: 'r', expiresAtMillis: 0 }), `${TEAM}:a`), disabled: '1' }],
  };
  const { body, skipped } = teamCodeImport(tables, key, TEAM, { m: 'o' });
  assert.deepEqual(body.mcpServers.map((s) => s.id), ['v-t']);
  assert.deepEqual(body.assignments, []);
  assert.deepEqual(body.accounts, [{ provider: 'codex', providerAccountId: 'p', label: '', email: null, accessToken: 'a', refreshToken: 'r', expiresAt: '1970-01-01T00:00:00.000Z', disabled: true }]);
  assert.equal(skipped.length, 3);
  assert.match(skipped[0], /stdio/);
  assert.match(skipped[1], /tool policy/);
  assert.match(skipped[2], /tool policy/);
  const other = { ...tables, variants: [], accounts: [{ ...tables.accounts[0], provider: 'mistral', credential_envelope: seal(key, '{"accessToken":"a","refreshToken":"r","expiresAtMillis":1}', `${TEAM}:a`) }] };
  assert.equal(teamCodeImport(other, key, TEAM, {}).body.accounts[0].provider, 'mistral');
  const noProvider = { ...other, accounts: [{ ...other.accounts[0], provider: null }] };
  assert.equal(teamCodeImport(noProvider, key, TEAM, {}).body.accounts.length, 0);
});

test('a secret that does not open with the key stops the import, never sends half of it', () => {
  const rows = seedRows(demoKey());
  const tables = { members: [], variants: rows.variants, policies: [], assignments: [], accounts: [] };
  assert.throws(() => teamCodeImport(tables, Buffer.alloc(32), TEAM, {}), /MCP server github: its secret does not open/);
});

test('an envelope opens only for its own context, and a malformed one is null', () => {
  const key = demoKey();
  const sealed = seal(key, 'hello', 'ctx');
  assert.equal(openEnvelope(key, sealed, 'ctx'), 'hello');
  assert.equal(openEnvelope(key, sealed, 'other'), null);
  assert.equal(openEnvelope(key, 'v2:abc', 'ctx'), null);
  assert.equal(openEnvelope(key, null, 'ctx'), null);
  assert.equal(openEnvelope(key, 'v1:AAAA', 'ctx'), null);
  assert.match(tableQuery('accounts', ['id'], "o'k"), /team_id = 'o''k'$/);
});

test('TeamCode\'s tool modes become the contract\'s: allow, deny, or none for every tool', () => {
  assert.equal(toolModeOf('ALLOWLIST'), 'allow');
  assert.equal(toolModeOf('allow'), 'allow');
  assert.equal(toolModeOf('DENYLIST'), 'deny');
  assert.equal(toolModeOf(' deny '), 'deny');
  assert.equal(toolModeOf('ALL'), null);
  assert.equal(toolModeOf(undefined), null);
});

test('an answer or a credential that is not JSON names what it was', () => {
  const key = demoKey();
  assert.throws(() => readTables(() => 'Warning: something\n[]', TEAM), /the answer for table members is not the JSON TeamCode writes/);
  const tables = { members: [], variants: [], policies: [], assignments: [], accounts: [{ id: 'a', provider: 'anthropic', provider_account_id: 'p', display_name: 'Max', email: null, credential_envelope: seal(key, 'not json', `${TEAM}:a`), disabled: 0 }] };
  assert.throws(() => teamCodeImport(tables, key, TEAM, {}), /account Max: its credential is not the JSON TeamCode writes/);
  assert.doesNotMatch(tableQuery('members', ['id'], TEAM), /kind/);
});
