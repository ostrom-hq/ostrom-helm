// SPDX-License-Identifier: Apache-2.0
import assert from 'node:assert/strict';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { CARD, chromiumFrom, cookiesOf, payAndSeeThePlan } from '../pay.mjs';

/** A page that records what is done to it; `card` says whether Checkout lists a card accordion first. */
function fakePage({ manualAddress = false, linkChecked = false, backAfter = 1, hidden = [], failedClicks = 0, busy = false } = {}) {
  const log = [];
  let submits = 0;
  const locator = (sel) => {
    const self = {
      sel,
      first: () => self,
      or: () => locator('either'),
      waitFor: async () => { log.push(['wait', sel]); if (hidden.includes(sel)) throw new Error('not shown'); },
      click: async () => { if (sel.includes('submit')) { submits += 1; if (submits <= failedClicks) throw new Error('no button'); } log.push(['click', sel]); },
      fill: async (v) => { log.push(['fill', sel, v]); },
      selectOption: async (v) => { log.push(['select', sel, v]); },
      press: async (k) => { log.push(['press', sel, k]); },
      getAttribute: async () => 'false',
      isEditable: async () => true,
      isEnabled: async () => !busy,
      inputValue: async () => '',
      isVisible: async () => !manualAddress,
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
    frames: () => [{ url: () => 'https://checkout.stripe.com/x' }, { url: () => 'about:blank' }],
    $$eval: async () => ['#cardNumber', '[hosted-payment-submit-button]'],
    goto: async (u) => { log.push(['goto', u]); },
    locator,
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
  assert.ok(page.log.some((e) => e[0] === 'fill' && e[1] === '#cardNumber' && e[2] === CARD.number));
  assert.ok(page.log.some((e) => e[0] === 'fill' && e[1] === '#email' && e[2] === 'o@acme.demo'));
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
  await assert.rejects(payAndSeeThePlan({ chromium, checkoutUrl: 'https://checkout.stripe.com/x', cookies: [], app: 'http://app.localhost', email: 'o@acme.demo', plan: 'Team' }), /did not send the payer back.*page https:\/\/checkout\.stripe\.com\/x; frames 1: .*fields: #cardNumber \[hosted-payment-submit-button\]/);
  assert.equal(chromium.state.closed, true);
});

test('Subscribe is not clicked again while Checkout is still confirming the payment (the button is disabled)', async () => {
  const page = fakePage({ backAfter: 99, busy: true });
  const chromium = fakeChromium(page);
  await assert.rejects(payAndSeeThePlan({ chromium, checkoutUrl: 'https://checkout.stripe.com/x', cookies: [], app: 'http://app.localhost', email: 'o@acme.demo', plan: 'Team' }), /did not send the payer back/);
  assert.equal(page.log.filter((e) => e[0] === 'click' && e[1].includes('submit')).length, 1);
});
