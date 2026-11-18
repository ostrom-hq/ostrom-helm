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

/** Playwright's Chromium from the install in `dir`, or undefined when there is none. */
export function chromiumFrom(dir) {
  if (!dir) return undefined;
  try {
    return createRequire(join(dir, 'pay.mjs'))('playwright').chromium;
  } catch {
    return undefined;
  }
}

/** The cookies a person's jar holds, as Playwright takes them for the console's origin. */
export function cookiesOf(jar, origin) {
  return [...jar].map(([name, value]) => ({ name, value, url: origin }));
}

/** Whether `locator` shows within `timeout` ms (Checkout's layout differs between a phone and a computer). */
async function appears(locator, timeout = 5000) {
  return locator.first().waitFor({ state: 'visible', timeout }).then(() => true, () => false);
}

/** Fills Checkout with the test card and a French billing address, subscribes, and waits for the way back. */
async function pay(page, email) {
  const card = page.locator('[data-testid="card-accordion-item-button"]');
  const number = page.locator('#cardNumber');
  await card.or(number).first().waitFor({ state: 'visible', timeout: 60000 });
  if ((await appears(card, 1000)) && (await card.getAttribute('aria-expanded')) !== 'true') await card.click();
  const mail = page.locator('#email');
  if ((await appears(mail)) && (await mail.isEditable()) && (await mail.inputValue()) === '') await mail.fill(email);
  await number.fill(CARD.number);
  await page.locator('#cardExpiry').fill(CARD.expiry);
  await page.locator('#cardCvc').fill(CARD.cvc);
  await page.locator('#billingName').fill('Ostrom Demo');
  await page.locator('#billingCountry').selectOption('FR');
  const line1 = page.locator('#billingAddressLine1');
  const manual = page.getByRole('button', { name: /enter address manually/i });
  await line1.or(manual).first().waitFor({ state: 'visible', timeout: 30000 });
  if (!(await line1.isVisible())) await manual.click();
  await line1.fill('60 rue François 1er');
  await page.locator('#billingPostalCode').fill('75008');
  await page.locator('#billingLocality').fill('Paris');
  const link = page.locator('#enableStripePass');
  if ((await appears(link, 2000)) && (await link.isChecked())) await link.uncheck();
  // The French address changes the tax: Stripe updates the session when the field is left, and a click during the
  // update sends no payment. The field is left first and the update awaited, then Subscribe is clicked.
  const updated = page.waitForResponse((r) => r.request().method() === 'POST' && r.url().includes('/v1/payment_pages/'), { timeout: 10000 }).catch(() => undefined);
  await page.locator('#billingLocality').press('Tab');
  await updated;
  const submit = page.locator('[data-testid="hosted-payment-submit-button"]');
  for (let click = 1; click <= 3; click += 1) {
    await submit.click({ timeout: 10000 }).catch(() => undefined);
    const back = await page.waitForURL((u) => !u.hostname.endsWith('stripe.com'), { timeout: 45000 }).then(() => true, () => false);
    if (back) return;
  }
  throw new Error('Stripe did not send the payer back after three clicks on Subscribe');
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
    await pay(page, email);
    await page.goto(`${app}/billing`);
    const region = page.getByRole('region', { name: 'Plan', exact: true });
    await region.getByText(plan, { exact: true }).waitFor({ state: 'visible', timeout: 90000 });
    await region.filter({ hasText: 'Active' }).waitFor({ state: 'visible', timeout: 30000 });
    return (await region.innerText()).replace(/\s+/g, ' ').trim();
  } finally {
    await browser.close();
  }
}
