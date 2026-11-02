// SPDX-License-Identifier: AGPL-3.0-only
import assert from 'node:assert/strict';
import { createDecipheriv } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { demoKey, seal, seedSql, TEAM } from '../teamcode/seed.mjs';

/** Opens an envelope as `ostrom import teamcode` does (TeamCodeKey): null when it does not open for that context. */
function open(key, envelope, context) {
  const bytes = Buffer.from(envelope.replace(/^v1:/, ''), 'base64url');
  const decipher = createDecipheriv('aes-256-gcm', key, bytes.subarray(0, 12));
  decipher.setAAD(Buffer.from(context, 'utf8'));
  decipher.setAuthTag(bytes.subarray(bytes.length - 16));
  try {
    return Buffer.concat([decipher.update(bytes.subarray(12, bytes.length - 16)), decipher.final()]).toString('utf8');
  } catch {
    return null;
  }
}

test('the committed 02-seed.sql is what seed.mjs writes from key.txt', () => {
  const key = demoKey();
  assert.equal(key.length, 32);
  assert.equal(readFileSync(new URL('../teamcode/02-seed.sql', import.meta.url), 'utf8'), seedSql(key));
});

test('every envelope opens with the demo key for its own context only, as TeamCode sealed it', () => {
  const key = demoKey();
  const sql = seedSql(key);
  const envelope = (needle) => new RegExp(`'${needle}'[^\\n]*?'(v1:[A-Za-z0-9_-]+)'`).exec(sql)[1];
  assert.equal(open(key, envelope('v-github'), `variant:${TEAM}:v-github`), 'ghp_demo_not_a_real_token');
  assert.equal(open(key, envelope('v-github'), `variant:${TEAM}:v-sentry`), null);
  assert.equal(open(key, envelope('v-sentry'), `variant:${TEAM}:v-sentry`), 'sntrys_demo_not_a_real_token');
  assert.equal(open(key, envelope('m-rev'), `variant:${TEAM}:v-linear:m-rev`), 'lin_api_demo_rev');
  const max = JSON.parse(open(key, envelope('a-max-1'), `${TEAM}:a-max-1`));
  assert.deepEqual(Object.keys(max), ['accessToken', 'refreshToken', 'expiresAtMillis']);
  assert.equal(open(Buffer.alloc(32), envelope('a-max-1'), `${TEAM}:a-max-1`), null);
  assert.equal(sql.match(/v1:/g).length, 6);
  assert.doesNotMatch(sql, /'ALL'|stdio|Bearer /);
  assert.match(sql, /'a-never', 'default', 'anthropic', '', 'org-demo', 'Never finished', NULL, 1, '', 0/);
  assert.equal(seal(key, 'x', 'c'), seal(key, 'x', 'c'));
});
