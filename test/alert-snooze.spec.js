// Behavioural tests for the snooze UI in alert.html — especially the custom
// duration field, which is pure in-page JS and otherwise uncovered (the daemon
// and launcher contracts it relies on are tested in the .bats suite + Swift).
//
// The page talks to the snooze daemon through the native WebKit bridge
// (window.webkit.messageHandlers.adaSignal). There's no WKWebView here, so we
// inject a stub for that bridge before the page loads and capture what it would
// have sent. We also neutralise window.close so the helper "close" can't kill
// the test page out from under us.
const { test, expect } = require('@playwright/test');
const path = require('path');
const { pathToFileURL } = require('url');

const ALERT_FILE = pathToFileURL(path.join(__dirname, '..', 'alert.html')).href;

function alertURL(overrides = {}) {
  const params = new URLSearchParams({
    cmd: 'npm run build',
    duration: '2m 14s',
    code: '0',
    autoclose: '300', // long, so the countdown never auto-dismisses mid-test
    snooze: '1',
    snoozemins: '5,10,30',
    sport: '1',
    stoken: 'tok',
    focus: '0',
    ...overrides,
  });
  return `${ALERT_FILE}?${params.toString()}`;
}

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    window.__sig = [];
    window.webkit = {
      messageHandlers: { adaSignal: { postMessage: (p) => window.__sig.push(p) } },
    };
    window.close = () => { window.__closed = true; };
  });
});

const customBtn = (page) => page.locator('button.snooze-btn').filter({ hasText: /^Custom$/ });
const setBtn = (page) => page.locator('button.snooze-btn').filter({ hasText: /^Set$/ });
const input = (page) => page.locator('.snooze-custom-input');
const signals = (page) => page.evaluate(() => window.__sig);

test('custom field is hidden until the Custom pill is clicked', async ({ page }) => {
  await page.goto(alertURL());
  await expect(page.locator('.snooze-custom')).toBeHidden();
  await expect(input(page)).toBeHidden();
  await expect(customBtn(page)).toBeVisible();
});

test('clicking Custom reveals + focuses the input and hides the Custom pill', async ({ page }) => {
  await page.goto(alertURL());
  await customBtn(page).click();
  await expect(input(page)).toBeVisible();
  await expect(input(page)).toBeFocused();
  await expect(customBtn(page)).toBeHidden();
  expect(await signals(page)).toEqual([]); // opening must not dismiss/focus
});

test('Enter submits a valid custom duration as snooze/<n>', async ({ page }) => {
  await page.goto(alertURL());
  await customBtn(page).click();
  await input(page).fill('7');
  await page.keyboard.press('Enter');
  await expect(page.locator('.title')).toHaveText('Snoozed');
  await expect(page.locator('.subtitle')).toHaveText('Back in 7 minutes');
  expect(await signals(page)).toEqual(['snooze/7']);
});

test('the Set button submits the custom duration', async ({ page }) => {
  await page.goto(alertURL());
  await customBtn(page).click();
  await input(page).fill('15');
  await setBtn(page).click();
  await expect(page.locator('.subtitle')).toHaveText('Back in 15 minutes');
  expect(await signals(page)).toEqual(['snooze/15']);
});

test('a duration of 1 uses the singular "minute"', async ({ page }) => {
  await page.goto(alertURL());
  await customBtn(page).click();
  await input(page).fill('1');
  await page.keyboard.press('Enter');
  await expect(page.locator('.subtitle')).toHaveText('Back in 1 minute');
  expect(await signals(page)).toEqual(['snooze/1']);
});

test('the daemon upper bound (1440) is accepted', async ({ page }) => {
  await page.goto(alertURL());
  await customBtn(page).click();
  await input(page).fill('1440');
  await page.keyboard.press('Enter');
  expect(await signals(page)).toEqual(['snooze/1440']);
});

test('an out-of-range value is rejected: no signal, field stays open', async ({ page }) => {
  await page.goto(alertURL());
  await customBtn(page).click();
  await input(page).fill('9999');
  await page.keyboard.press('Enter');
  await expect(input(page)).toHaveClass(/invalid/);
  await expect(input(page)).toBeVisible();
  await expect(page.locator('.title')).toHaveText('Command Finished');
  expect(await signals(page)).toEqual([]);
});

test('zero is rejected the same way', async ({ page }) => {
  await page.goto(alertURL());
  await customBtn(page).click();
  await input(page).fill('0');
  await setBtn(page).click();
  await expect(input(page)).toHaveClass(/invalid/);
  expect(await signals(page)).toEqual([]);
});

test('Escape cancels the field without dismissing the alert', async ({ page }) => {
  await page.goto(alertURL());
  await customBtn(page).click();
  await input(page).fill('42');
  await page.keyboard.press('Escape');
  await expect(page.locator('.snooze-custom')).toBeHidden();
  await expect(customBtn(page)).toBeVisible();
  expect(await signals(page)).toEqual([]);
  expect(await page.evaluate(() => window.__closed || false)).toBe(false);
});

test('preset buttons still emit snooze/<n>', async ({ page }) => {
  await page.goto(alertURL());
  await page.locator('button.snooze-btn').filter({ hasText: /^5m$/ }).click();
  await expect(page.locator('.title')).toHaveText('Snoozed');
  expect(await signals(page)).toEqual(['snooze/5']);
});

test('snooze controls stay hidden when the daemon is disabled', async ({ page }) => {
  // No sport/stoken => daemonEnabled is false => the whole bar must not render.
  await page.goto(alertURL({ snooze: '0', sport: '', stoken: '' }));
  await expect(page.locator('.snooze-custom')).toBeHidden();
  await expect(customBtn(page)).toHaveCount(0);
});
