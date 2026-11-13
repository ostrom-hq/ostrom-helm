// SPDX-License-Identifier: Apache-2.0
// Local demo only: hands the server's sign-in and invitation mails to Mailpit, so they can be read in its inbox
// (http://mail.localhost). The server writes each mail as a file in OSTROM_MAIL_DIR (`To: …`, `Subject: …`, a blank
// line, the text: DirectoryMailSender); this relay sends each new file once through Mailpit's API (POST
// /api/v1/send), then renames it `*.sent`. Nothing ever leaves the machine.
import { readdir, readFile, rename, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

/** A mail file read back: recipient, subject, text; null when the file is not one. */
export function parseMail(raw) {
  const split = raw.indexOf('\n\n');
  if (split < 0) return null;
  const head = Object.fromEntries(
    raw.slice(0, split).split('\n').map((line) => {
      const colon = line.indexOf(':');
      return [line.slice(0, colon).trim().toLowerCase(), line.slice(colon + 1).trim()];
    }),
  );
  if (!head.to || !head.subject) return null;
  return { to: head.to, subject: head.subject, text: raw.slice(split + 2).replace(/\n$/, '') };
}

/** Mailpit's send body for a mail. */
export const mailpitMessage = (mail, from) => ({
  From: { Email: from.email, Name: from.name },
  To: [{ Email: mail.to }],
  Subject: mail.subject,
  Text: mail.text,
});

/** How long a file that does not read as a mail is left alone: the server may still be writing it. */
export const SETTLE_MS = 2000;

/**
 * One pass over the directory: every unsent mail file is sent, then renamed. A file that does not read as a mail is
 * retried while it is younger than SETTLE_MS (the server creates it, then writes it), then renamed `*.invalid`.
 * Returns the files sent.
 */
export async function relayOnce({ dir, mailpitUrl, from, fetchImpl = fetch, log = () => {}, now = Date.now }) {
  const sent = [];
  for (const name of (await readdir(dir)).sort()) {
    if (!name.endsWith('.txt')) continue;
    const path = join(dir, name);
    const mail = parseMail(await readFile(path, 'utf8'));
    if (!mail) {
      if (now() - (await stat(path)).mtimeMs < SETTLE_MS) continue;
      await rename(path, `${path}.invalid`);
      log(`skipped ${name}: not a mail file`);
      continue;
    }
    const r = await fetchImpl(`${mailpitUrl.replace(/\/$/, '')}/api/v1/send`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(mailpitMessage(mail, from)),
    });
    if (!r.ok) {
      log(`Mailpit answered ${r.status} for ${name}; retrying on the next pass`);
      continue;
    }
    await rename(path, `${path}.sent`);
    sent.push(name);
    log(`sent ${name} (${mail.subject})`);
  }
  return sent;
}

// The process entry point: run by the Compose demo (its CI run covers it), not by the unit tests.
/* node:coverage disable */
if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  const options = {
    dir: process.env.MAIL_DIR ?? '/mail',
    mailpitUrl: process.env.MAILPIT_URL ?? 'http://mailpit:8025',
    from: { email: 'login@mail.ostrom.run', name: 'Ostrom' },
    log: (m) => console.log(m),
  };
  const tick = () => relayOnce(options).catch((e) => console.error(`relay: ${e.message}`)).finally(() => setTimeout(tick, 500));
  tick();
}
/* node:coverage enable */
