// SPDX-License-Identifier: Apache-2.0
import assert from 'node:assert/strict';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { CARD, chromiumFrom, cookiesOf, describe, payAndSeeThePlan } from '../pay.mjs';

/** A page that records what is done to it; `card` says whether Checkout lists a card accordion first. */
function fakePage({ manualAddress = false, linkChecked = false, backAfter = 1, hidden = [], failedClicks = 0, busy = false } = {}) {
  const log = [];
  let submits = 0;
  let manualClicked = false;
  // A selector lists alternatives: it shows when one of them does.
  const shows = (sel) => sel.split(', ').some((one) => !hidden.some((h) => one.startsWith(h))
    && !(manualAddress && !manualClicked && /AddressLine1|address-line1/.test(one)));
  const locator = (sel) => {
    const self = {
      sel,
      first: () => self,
      or: () => locator('either'),
      waitFor: async () => { log.push(['wait', sel]); if (hidden.includes(sel)) throw new Error('not shown'); },
      click: async () => { if (sel === 'button') manualClicked = true; if (sel.includes('submit')) { submits += 1; if (submits <= failedClicks) throw new Error('no button'); } log.push(['click', sel]); },
      fill: async (v) => { log.push(['fill', sel, v]); },
      selectOption: async (v) => { log.push(['select', sel, v]); },
      press: async (k) => { log.push(['press', sel, k]); },
      getAttribute: async () => 'false',
      isEditable: async () => true,
      // busy: Checkout confirming (the button disabled); 'gone': the button no longer readable.
      isEnabled: async () => { if (busy === 'gone') throw new Error('detached'); return !busy; },
      inputValue: async () => '',
      isVisible: async () => shows(sel),
      isChecked: async () => linkChecked,
      uncheck: async () => { log.push(['uncheck', sel]); },
      getByText: (t) => { log.push(['text', t]); return self; },
      filter: ({ hasText }) => { log.push(['filter', hasText]); return self; },
      innerText: async () => ' Team \n Active ',
    };
    return self;
  };
  const page = {
    log,
    url: () => 'https://checkout.stripe.com/x',
    // Checkout's form in a frame of its own (the payment Element), next to an empty one.
    frames: () => [{ url: () => 'about:blank', locator: () => ({ first: () => ({ isVisible: async () => { throw new Error('detached'); } }) }), $$eval: async () => [] }, form],
    goto: async (u) => { log.push(['goto', u]); },
    locator: () => { throw new Error('the form is in its frame, not in the page'); },
    getByRole: (role, o) => (log.push(['role', role, o.name]), locator(role)),
    waitForResponse: (match) => {
      assert.equal(match({ request: () => ({ method: () => 'POST' }), url: () => 'https://checkout.stripe.com/v1/payment_pages/cs_x/confirm' }), true);
      assert.equal(match({ request: () => ({ method: () => 'GET' }), url: () => 'https://x' }), false);
      return hidden.includes('#email') ? Promise.reject(new Error('timeout')) : Promise.resolve(undefined);
    },
    waitForURL: async (match) => {
      assert.equal(match(new URL('https://checkout.stripe.com/c/pay/x')), false);
      assert.equal(match(new URL('http://app.localhost/billing?checkout=success')), true);
      if (submits < backAfter) throw new Error('still on Stripe');
    },
  };
  const form = {
    url: () => 'https://js.stripe.com/v3/elements-inner-payment',
    locator,
    getByRole: (role, o) => (log.push(['role', role, o.name]), locator(role)),
    $$eval: async () => ['#cardNumber', '[hosted-payment-submit-button]'],
  };
  return page;
}

function fakeChromium(page) {
  const state = { closed: false, cookies: [] };
  return {
    state,
    launch: async () => ({
      newContext: async () => ({ addCookies: async (c) => { state.cookies = c; }, newPage: async () => page }),
      close: async () => { state.closed = true; },
    }),
  };
}

test('cookiesOf gives Playwright the jar for the console’s origin', () => {
  assert.deepEqual(cookiesOf(new Map([['ostrom_session', 'abc']]), 'http://app.localhost'), [{ name: 'ostrom_session', value: 'abc', url: 'http://app.localhost' }]);
  assert.deepEqual(cookiesOf(new Map([['__Host-ostrom_csrf', 'x']]), 'http://app.localhost'), [{ name: '__Host-ostrom_csrf', value: 'x', url: 'http://app.localhost', secure: true }]);
});

test('chromiumFrom is undefined when no install is named, and throws on an install that does not load', () => {
  assert.equal(chromiumFrom(''), undefined);
  assert.throws(() => chromiumFrom(mkdtempSync(join(tmpdir(), 'no-playwright-'))), /Playwright does not load/);
});

test('payAndSeeThePlan pays with the test card, then reads the paid plan in the console, and closes the browser', async () => {
  const page = fakePage();
  const chromium = fakeChromium(page);
  const seen = await payAndSeeThePlan({ chromium, checkoutUrl: 'https://checkout.stripe.com/c/pay/cs_test_x', cookies: [{ name: 'a', value: 'b', url: 'http://app.localhost' }], app: 'http://app.localhost', email: 'o@acme.demo', plan: 'Team' });
  assert.equal(seen, 'Team Active');
  assert.deepEqual(page.log.filter((e) => e[0] === 'goto'), [['goto', 'https://checkout.stripe.com/c/pay/cs_test_x'], ['goto', 'http://app.localhost/billing']]);
  assert.ok(page.log.some((e) => e[0] === 'fill' && e[1].startsWith('#cardNumber') && e[2] === CARD.number));
  assert.ok(page.log.some((e) => e[0] === 'fill' && e[1].startsWith('#email') && e[2] === 'o@acme.demo'));
  assert.ok(page.log.some((e) => e[0] === 'select' && e[2] === 'FR'));
  assert.deepEqual(chromium.state.cookies, [{ name: 'a', value: 'b', url: 'http://app.localhost' }]);
  assert.equal(chromium.state.closed, true);
});

test('the address may be typed by hand, the Link box is unchecked, and Subscribe is clicked again while Stripe has not sent the payer back', async () => {
  const page = fakePage({ manualAddress: true, linkChecked: true, backAfter: 2, hidden: ['#email', '[data-testid="card-accordion-item-button"]'], failedClicks: 1 });
  const chromium = fakeChromium(page);
  await payAndSeeThePlan({ chromium, checkoutUrl: 'https://checkout.stripe.com/x', cookies: [], app: 'http://app.localhost', email: 'o@acme.demo', plan: 'Team' });
  assert.ok(page.log.some((e) => e[0] === 'role' && e[1] === 'button'), 'the by-hand button was looked for');
  assert.ok(page.log.some((e) => e[0] === 'click' && e[1] === 'button'), 'and clicked');
  assert.ok(page.log.some((e) => e[0] === 'uncheck'));
  assert.equal(page.log.filter((e) => e[0] === 'click' && e[1].includes('submit')).length, 1, 'the first click found no button, the second paid');
});

test('a payer Stripe never sends back is an error, and the browser is closed anyway', async () => {
  const page = fakePage({ backAfter: 99 });
  const chromium = fakeChromium(page);
  await assert.rejects(payAndSeeThePlan({ chromium, checkoutUrl: 'https://checkout.stripe.com/x', cookies: [], app: 'http://app.localhost', email: 'o@acme.demo', plan: 'Team' }), /did not send the payer back.*page https:\/\/checkout\.stripe\.com\/x; frames 1: .*fields: https:\/\/js\.stripe\.com\/v3\/elements-inner-payment: #cardNumber \[hosted-payment-submit-button\]/);
  assert.equal(chromium.state.closed, true);
});

test('Subscribe is not clicked again while Checkout is still confirming the payment (the button is disabled)', async () => {
  const page = fakePage({ backAfter: 99, busy: true });
  const chromium = fakeChromium(page);
  await assert.rejects(payAndSeeThePlan({ chromium, checkoutUrl: 'https://checkout.stripe.com/x', cookies: [], app: 'http://app.localhost', email: 'o@acme.demo', plan: 'Team' }), /did not send the payer back/);
  assert.equal(page.log.filter((e) => e[0] === 'click' && e[1].includes('submit')).length, 1);
});

/** An element as describe() reads it in the browser. */
const el = ({ testid = null, id = '', name = null, shown = true }) => ({
  offsetParent: shown ? {} : null,
  id,
  getAttribute: (a) => ({ 'data-testid': testid, name })[a] ?? null,
});

test('describe names each frame\'s visible fields by test id, id or name, and skips a frame it cannot read', async () => {
  const elements = [el({ testid: 'card-accordion-item-button' }), el({ id: 'cardNumber' }), el({ name: 'number' }), el({}), el({ id: 'hidden', shown: false })];
  const page = {
    url: () => 'https://checkout.stripe.com/g/pay/cs_x#secret',
    frames: () => [
      { url: () => 'https://checkout.stripe.com/g/pay/cs_x', $$eval: async (_sel, fn) => fn(elements) },
      { url: () => 'https://js.stripe.com/v3/elements-inner', $$eval: async () => { throw new Error('detached'); } },
      { url: () => 'about:blank', $$eval: async (_sel, fn) => fn([]) },
    ],
  };
  assert.equal(await describe(page), 'page https://checkout.stripe.com/g/pay/cs_x; frames 2: https://checkout.stripe.com/g/pay/cs_x | https://js.stripe.com/v3/elements-inner; fields: https://checkout.stripe.com/g/pay/cs_x: [card-accordion-item-button] #cardNumber name=number');
});

test('describe says when no frame shows a field, and when the page cannot be read at all', async () => {
  assert.equal(await describe({ url: () => 'https://x', frames: () => [] }), 'page https://x; frames 0: ; fields: none');
  assert.equal(await describe({ frames: () => { throw new Error('closed'); } }), '(page not readable: closed)');
});

test('a Subscribe button that can no longer be read is not clicked again', async () => {
  const page = fakePage({ backAfter: 99, busy: 'gone' });
  await assert.rejects(payAndSeeThePlan({ chromium: fakeChromium(page), checkoutUrl: 'https://checkout.stripe.com/x', cookies: [], app: 'http://app.localhost', email: 'o@acme.demo', plan: 'Team' }), /did not send the payer back/);
  assert.equal(page.log.filter((e) => e[0] === 'click' && e[1].includes('submit')).length, 1);
});
