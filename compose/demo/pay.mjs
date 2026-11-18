// SPDX-License-Identifier: Apache-2.0
// The demo's payment: the owner pays for a plan on Stripe's hosted Checkout with the TEST card 4242, in a real browser
// (Playwright's Chromium), then the console is read for the paid plan. Stripe is in test mode, never live: the stack
// refuses any key that is not a test key (docker-compose.demo-stripe.yml). Journey.mjs calls it only when
// OSTROM_DEMO_PLAYWRIGHT_DIR names an install of Playwright (the demo workflow's), so a laptop without a browser keeps
// the Checkout link to pay by hand.
import { createRequire } from 'node:module';
import { join } from 'node:path';

/** Stripe's test card that always succeeds, without 3-D Secure. */
export const CARD = { number: '4242424242424242', expiry: '12 / 34', cvc: '123' };

/**
 * Playwright's Chromium from the install in `dir`, or undefined when no `dir` is given. A `dir` that does not load
 * throws: the run asked for a browser, so a broken install is an error, not a missing browser.
 */
export function chromiumFrom(dir) {
  if (!dir) return undefined;
  try {
    return createRequire(join(dir, 'pay.mjs'))('playwright').chromium;
  } catch (error) {
    throw new Error(`OSTROM_DEMO_PLAYWRIGHT_DIR=${dir}: Playwright does not load (${error.message})`);
  }
}

/** The cookies a person's jar holds, as Playwright takes them for the console's origin. */
export function cookiesOf(jar, origin) {
  // A `__Host-` or `__Secure-` cookie is refused unless Secure; Chromium keeps Secure cookies on *.localhost over http.
  return [...jar].map(([name, value]) => ({ name, value, url: origin, ...(/^__(Host|Secure)-/.test(name) ? { secure: true } : {}) }));
}

/**
 * The frame of `page` that shows `selector` within `timeout` ms: Checkout draws its form in the page itself or, in
 * some layouts, in a frame of Stripe's (the payment Element).
 */
export async function frameWith(page, selector, timeout) {
  const deadline = Date.now() + timeout;
  for (;;) {
    for (const frame of page.frames()) {
      if (await frame.locator(selector).first().isVisible().catch(() => false)) return frame;
    }
    if (Date.now() > deadline) throw new Error(`no frame of Checkout shows ${selector} after ${timeout / 1000} s`);
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
}

/**
 * Checkout's fields: Stripe's ids first, then the standard `autocomplete` of the same field, which every layout of
 * Checkout keeps (the hosted page's own form, or the payment Element in a frame).
 */
export const FIELDS = {
  cardButton: '[data-testid="card-accordion-item-button"]',
  number: '#cardNumber, input[autocomplete="cc-number"]',
  expiry: '#cardExpiry, input[autocomplete="cc-exp"]',
  cvc: '#cardCvc, input[autocomplete="cc-csc"]',
  email: '#email, input[autocomplete="email"]',
  name: '#billingName, input[autocomplete="cc-name"], input[autocomplete="billing name"]',
  country: '#billingCountry, select[autocomplete="billing country"], select[autocomplete="country"]',
  line1: '#billingAddressLine1, input[autocomplete="billing address-line1"], input[autocomplete="address-line1"]',
  postal: '#billingPostalCode, input[autocomplete="billing postal-code"], input[autocomplete="postal-code"]',
  city: '#billingLocality, input[autocomplete="billing address-level2"], input[autocomplete="address-level2"]',
  link: '#enableStripePass',
  submit: '[data-testid="hosted-payment-submit-button"], button[type="submit"]',
};

/** Fills Checkout with the test card and a French billing address, subscribes, and waits for the way back. */
async function pay(page, email) {
  /** `selector` in whichever frame shows it. */
  const at = async (selector, timeout = 30000) => (await frameWith(page, selector, timeout)).locator(selector).first();
  /** The same, or undefined when no frame shows it within `timeout`. */
  const maybe = (selector, timeout) => at(selector, timeout).catch(() => undefined);
  await frameWith(page, `${FIELDS.cardButton}, ${FIELDS.number}`, 60000);
  const card = await maybe(FIELDS.cardButton, 1000);
  if (card && (await card.getAttribute('aria-expanded')) !== 'true') await card.click();
  const mail = await maybe(FIELDS.email, 5000);
  if (mail && (await mail.isEditable()) && (await mail.inputValue()) === '') await mail.fill(email);
  await (await at(FIELDS.number)).fill(CARD.number);
  await (await at(FIELDS.expiry)).fill(CARD.expiry);
  await (await at(FIELDS.cvc)).fill(CARD.cvc);
  await (await at(FIELDS.name)).fill('Ostrom Demo');
  await (await at(FIELDS.country)).selectOption('FR');
  // The address line, or the button that shows it (Checkout first offers an address search).
  const manualButton = 'button:has-text("Enter address manually")';
  const form = await frameWith(page, `${FIELDS.line1}, ${manualButton}`, 30000);
  if (!(await form.locator(FIELDS.line1).first().isVisible())) await form.getByRole('button', { name: /enter address manually/i }).click();
  await (await at(FIELDS.line1)).fill('60 rue François 1er');
  await (await at(FIELDS.postal)).fill('75008');
  const city = await at(FIELDS.city);
  await city.fill('Paris');
  const link = await maybe(FIELDS.link, 2000);
  if (link && (await link.isChecked())) await link.uncheck();
  // The French address changes the tax: Stripe updates the session when the field is left, and a click during the
  // update sends no payment. The field is left first and the update awaited, then Subscribe is clicked.
  const updated = page.waitForResponse((r) => r.request().method() === 'POST' && r.url().includes('/v1/payment_pages/'), { timeout: 10000 }).catch(() => undefined);
  await city.press('Tab');
  await updated;
  const submit = await at(FIELDS.submit);
  for (let click = 1; click <= 3; click += 1) {
    // Clicked again only when Checkout is idle: while a payment is being confirmed, the button is disabled.
    if (click > 1 && !(await submit.isEnabled().catch(() => false))) continue;
    await submit.click({ timeout: 10000 }).catch(() => undefined);
    const back = await page.waitForURL((u) => !u.hostname.endsWith('stripe.com'), { timeout: 45000 }).then(() => true, () => false);
    if (back) return;
  }
  throw new Error('Stripe did not send the payer back after Subscribe (three waits of 45 s)');
}

/** What the page shows, for an error: its URL, its frames, and the ids and test ids of its fields and buttons. */
export async function describe(page) {
  try {
    const frames = page.frames().map((f) => f.url()).filter((u) => u && u !== 'about:blank');
    // The fields of each frame that has some (the order summary's test ids are left out).
    const fields = [];
    for (const frame of page.frames()) {
      const found = await frame.$$eval('input, select, button', (els) => els
        .filter((e) => e.offsetParent !== null)
        .map((e) => e.getAttribute('data-testid') ? `[${e.getAttribute('data-testid')}]` : e.id ? `#${e.id}` : e.getAttribute('name') ? `name=${e.getAttribute('name')}` : '')
        .filter(Boolean).slice(0, 30)).catch(() => []);
      if (found.length) fields.push(`${frame.url().slice(0, 50)}: ${found.join(' ')}`);
    }
    return `page ${page.url().split('#')[0]}; frames ${frames.length}: ${frames.map((u) => u.slice(0, 60)).join(' | ')}; fields: ${fields.join(' ; ') || 'none'}`;
  } catch (error) {
    return `(page not readable: ${error.message})`;
  }
}

/**
 * Pays `checkoutUrl` as the owner (`cookies`: the console's session, so the way back lands signed in), then opens the
 * console's billing page and waits for the paid plan: the plan card says `plan` and "Active".
 *
 * @returns {Promise<string>} What the console showed.
 */
export async function payAndSeeThePlan({ chromium, checkoutUrl, cookies, app, email, plan }) {
  const browser = await chromium.launch();
  try {
    const context = await browser.newContext();
    await context.addCookies(cookies);
    const page = await context.newPage();
    await page.goto(checkoutUrl);
    try {
      await pay(page, email);
    } catch (error) {
      throw new Error(`${error.message.split('\n')[0]} — ${await describe(page)}`);
    }
    await page.goto(`${app}/billing`);
    const region = page.getByRole('region', { name: 'Plan', exact: true });
    await region.getByText(plan, { exact: true }).waitFor({ state: 'visible', timeout: 90000 });
    await region.filter({ hasText: 'Active' }).waitFor({ state: 'visible', timeout: 30000 });
    return (await region.innerText()).replace(/\s+/g, ' ').trim();
  } finally {
    await browser.close();
  }
}
