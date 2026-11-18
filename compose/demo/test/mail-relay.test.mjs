// SPDX-License-Identifier: Apache-2.0
import assert from 'node:assert/strict';
import { mkdtempSync, readdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { mailpitMessage, parseMail, relayOnce, SETTLE_MS } from '../mail-relay.mjs';

const from = { email: 'login@mail.ostrom.run', name: 'Ostrom' };
const mail = 'To: a@b.c\nSubject: Sign in to Ostrom\n\nUse http://app/auth/email#token=abc\n';

test('parseMail reads the server’s mail files and refuses anything else', () => {
  assert.deepEqual(parseMail(mail), { to: 'a@b.c', subject: 'Sign in to Ostrom', text: 'Use http://app/auth/email#token=abc' });
  assert.equal(parseMail('no blank line'), null);
  assert.equal(parseMail('Subject: x\n\nbody'), null);
  assert.equal(parseMail('To: a@b.c\n\nbody'), null);
  assert.deepEqual(mailpitMessage(parseMail(mail), from), { From: { Email: from.email, Name: from.name }, To: [{ Email: 'a@b.c' }], Subject: 'Sign in to Ostrom', Text: 'Use http://app/auth/email#token=abc' });
});

test('relayOnce sends each new mail once, keeps one Mailpit refused, sets aside a file that is no mail', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'relay-'));
  writeFileSync(join(dir, '1-a.txt'), mail);
  writeFileSync(join(dir, '2-b.txt'), mail.replace('a@b.c', 'refused@b.c'));
  writeFileSync(join(dir, '3-c.txt'), 'garbage');
  writeFileSync(join(dir, 'other.log'), 'ignored');
  const calls = [];
  const logs = [];
  const fetchImpl = async (url, init) => {
    calls.push([url, JSON.parse(init.body).To[0].Email]);
    return { ok: !init.body.includes('refused'), status: init.body.includes('refused') ? 500 : 200 };
  };
  const later = () => Date.now() + SETTLE_MS + 1000;
  const sent = await relayOnce({ dir, mailpitUrl: 'http://mailpit:8025/', from, fetchImpl, log: (m) => logs.push(m), now: later });
  assert.deepEqual(sent, ['1-a.txt']);
  assert.deepEqual(calls, [['http://mailpit:8025/api/v1/send', 'a@b.c'], ['http://mailpit:8025/api/v1/send', 'refused@b.c']]);
  assert.deepEqual(readdirSync(dir).sort(), ['1-a.txt.sent', '2-b.txt', '3-c.txt.invalid', 'other.log']);
  assert.equal(logs.length, 3);
  assert.deepEqual(await relayOnce({ dir, mailpitUrl: 'http://m', from, fetchImpl: async () => ({ ok: true }) }), ['2-b.txt']);
});

test('relayOnce leaves a file the server is still writing, and sets it aside once it has settled', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'relay-'));
  writeFileSync(join(dir, '1-half.txt'), 'To: a@b.c\n');
  const fetchImpl = async () => assert.fail('nothing to send');
  assert.deepEqual(await relayOnce({ dir, mailpitUrl: 'http://m', from, fetchImpl }), []);
  assert.deepEqual(readdirSync(dir), ['1-half.txt']);
  await relayOnce({ dir, mailpitUrl: 'http://m', from, fetchImpl, now: () => Date.now() + SETTLE_MS + 1000 });
  assert.deepEqual(readdirSync(dir), ['1-half.txt.invalid']);
});
