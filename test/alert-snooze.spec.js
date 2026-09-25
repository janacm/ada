// Behavioural tests for the snooze UI in alert.html: the collapsed "Snooze"
// toggle, the pin that keeps it open on every alert, and the custom duration
// field. All of it is in-page JS (the daemon and launcher contracts it relies
// on are tested in the .bats suite + Swift).
//
// The page talks to the snooze daemon through the native WebKit bridge
// (window.webkit.messageHandlers.adaSignal). There's no WKWebView here, so we
// inject a stub for that bridge before the page loads and capture what it would
// have sent. We also neutralise window.close so the helper "close" can't kill
// the test page out from under us.
const { test, expect } = require('@playwright/test');
const path = require('path');
const { pathToFileURL } = require('url');
const { recordCoverage } = require('./alert-coverage');

const ALERT_FILE = pathToFileURL(path.join(__dirname, '..', 'alert.html')).href;
recordCoverage(test, ALERT_FILE);

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

// `prefs` stands in for the window.adaPrefs script the native helper injects
// from user defaults; __pins records what the page posts to adaSnoozePin.
async function open(page, overrides = {}, prefs = null) {
  await page.addInitScript((prefs) => {
    window.__sig = [];
    window.__pins = [];
    window.webkit = {
      messageHandlers: {
        adaSignal: { postMessage: (p) => window.__sig.push(p) },
        adaSnoozePin: { postMessage: (v) => window.__pins.push(v) },
      },
    };
    window.close = () => { window.__closed = true; };
    if (prefs) window.adaPrefs = prefs;
  }, prefs);
  await page.goto(alertURL(overrides));
}

// Most tests are about the options, so they open the collapsed bar first.
async function openExpanded(page, overrides = {}) {
  await open(page, overrides);
  await toggle(page).click();
}

const customBtn = (page) => page.locator('button.snooze-btn').filter({ hasText: /^Custom$/ });
const setBtn = (page) => page.locator('button.snooze-btn').filter({ hasText: /^Set$/ });
const input = (page) => page.locator('.snooze-custom-input');
const signals = (page) => page.evaluate(() => window.__sig);
const pins = (page) => page.evaluate(() => window.__pins);
const toggle = (page) => page.locator('#snoozeToggle');
const pinBtn = (page) => page.locator('#snoozePin');
const preset = (page, label) => page.locator('button.snooze-btn').filter({ hasText: new RegExp(`^${label}$`) });

// --- collapsed by default, and the pin ---------------------------------------

test('the options start collapsed behind the Snooze toggle', async ({ page }) => {
  await open(page);
  await expect(toggle(page)).toBeVisible();
  await expect(toggle(page)).toHaveAttribute('aria-expanded', 'false');
  await expect(preset(page, '5m')).toBeHidden();
  await expect(customBtn(page)).toBeHidden();
  await expect(pinBtn(page)).toBeHidden();
});

test('clicking Snooze reveals the durations and the pin, and again hides them', async ({ page }) => {
  await open(page);
  await toggle(page).click();
  await expect(toggle(page)).toHaveAttribute('aria-expanded', 'true');
  for (const label of ['5m', '10m', '30m', 'Custom']) await expect(preset(page, label)).toBeVisible();
  await expect(pinBtn(page)).toBeVisible();
  await expect(pinBtn(page)).toHaveAttribute('aria-pressed', 'false');

  await toggle(page).click();
  await expect(toggle(page)).toHaveAttribute('aria-expanded', 'false');
  await expect(preset(page, '5m')).toBeHidden();
  // Toggling is not a click on the alert: nothing dismissed, nothing signalled.
  expect(await signals(page)).toEqual([]);
  expect(await page.evaluate(() => window.__closed || false)).toBe(false);
});

test('the pin sits after the durations', async ({ page }) => {
  await openExpanded(page);
  const order = await page.locator('#snoozeOptions > *').evaluateAll(
    (els) => els.map((el) => el.id || el.className));
  expect(order).toEqual(['snooze-btn', 'snooze-btn', 'snooze-btn', 'snooze-btn', 'snooze-custom', 'snoozePin']);
});

test('pinning posts true to the native bridge without dismissing', async ({ page }) => {
  await openExpanded(page);
  await pinBtn(page).click();
  await expect(pinBtn(page)).toHaveAttribute('aria-pressed', 'true');
  await expect(pinBtn(page)).toHaveText('Pinned open');
  expect(await pins(page)).toEqual([true]);
  expect(await signals(page)).toEqual([]);
  await expect(preset(page, '5m')).toBeVisible();
});

test('a stored pin opens the options on load', async ({ page }) => {
  await open(page, {}, { snoozePinned: true });
  await expect(toggle(page)).toHaveAttribute('aria-expanded', 'true');
  await expect(preset(page, '5m')).toBeVisible();
  await expect(pinBtn(page)).toHaveAttribute('aria-pressed', 'true');
  expect(await pins(page)).toEqual([]); // reading the pin must not re-save it
});

test('unpinning posts false, and the row stays open for this alert', async ({ page }) => {
  await open(page, {}, { snoozePinned: true });
  await pinBtn(page).click();
  await expect(pinBtn(page)).toHaveAttribute('aria-pressed', 'false');
  await expect(pinBtn(page)).toHaveText('Pin open');
  expect(await pins(page)).toEqual([false]);
  await expect(preset(page, '5m')).toBeVisible();
});

test('a pinned row can still be collapsed without unpinning', async ({ page }) => {
  await open(page, {}, { snoozePinned: true });
  await toggle(page).click();
  await expect(preset(page, '5m')).toBeHidden();
  expect(await pins(page)).toEqual([]);
});

test('only a literal true counts as pinned', async ({ page }) => {
  await open(page, {}, { snoozePinned: 'true' });
  await expect(toggle(page)).toHaveAttribute('aria-expanded', 'false');
});

test('without the pin bridge the pin still toggles for this alert', async ({ page }) => {
  await page.addInitScript(() => {
    window.__sig = [];
    window.webkit = { messageHandlers: { adaSignal: { postMessage: (p) => window.__sig.push(p) } } };
    window.close = () => { window.__closed = true; };
  });
  await page.goto(alertURL());
  await toggle(page).click();
  await pinBtn(page).click();
  await expect(pinBtn(page)).toHaveAttribute('aria-pressed', 'true');
  expect(await signals(page)).toEqual([]);
});

test('collapsing closes an open custom field', async ({ page }) => {
  await openExpanded(page);
  await customBtn(page).click();
  await input(page).fill('42');
  await toggle(page).click();
  await toggle(page).click();
  await expect(input(page)).toBeHidden();
  await expect(customBtn(page)).toBeVisible();
  expect(await signals(page)).toEqual([]);
});

// --- durations and the custom field ------------------------------------------

test('custom field is hidden until the Custom pill is clicked', async ({ page }) => {
  await openExpanded(page);
  await expect(page.locator('.snooze-custom')).toBeHidden();
  await expect(input(page)).toBeHidden();
  await expect(customBtn(page)).toBeVisible();
});

test('clicking Custom reveals + focuses the input and hides the Custom pill', async ({ page }) => {
  await openExpanded(page);
  await customBtn(page).click();
  await expect(input(page)).toBeVisible();
  await expect(input(page)).toBeFocused();
  await expect(customBtn(page)).toBeHidden();
  expect(await signals(page)).toEqual([]); // opening must not dismiss/focus
});

test('Enter submits a valid custom duration as snooze/<n>', async ({ page }) => {
  await openExpanded(page);
  await customBtn(page).click();
  await input(page).fill('7');
  await page.keyboard.press('Enter');
  await expect(page.locator('.title')).toHaveText('Snoozed');
  expect(await signals(page)).toEqual(['snooze/7']);
});

test('the Set button submits the custom duration', async ({ page }) => {
  await openExpanded(page);
  await customBtn(page).click();
  await input(page).fill('15');
  await setBtn(page).click();
  await expect(page.locator('.title')).toHaveText('Snoozed');
  expect(await signals(page)).toEqual(['snooze/15']);
});

test('the daemon upper bound (1440) is accepted', async ({ page }) => {
  await openExpanded(page);
  await customBtn(page).click();
  await input(page).fill('1440');
  await page.keyboard.press('Enter');
  expect(await signals(page)).toEqual(['snooze/1440']);
});

test('an out-of-range value is rejected: no signal, field stays open', async ({ page }) => {
  await openExpanded(page);
  await customBtn(page).click();
  await input(page).fill('9999');
  await page.keyboard.press('Enter');
  await expect(input(page)).toHaveClass(/invalid/);
  await expect(input(page)).toBeVisible();
  await expect(page.locator('.title')).toHaveText('Command Finished');
  expect(await signals(page)).toEqual([]);
});

test('zero is rejected the same way', async ({ page }) => {
  await openExpanded(page);
  await customBtn(page).click();
  await input(page).fill('0');
  await setBtn(page).click();
  await expect(input(page)).toHaveClass(/invalid/);
  expect(await signals(page)).toEqual([]);
});

test('Escape cancels the field without dismissing the alert', async ({ page }) => {
  await openExpanded(page);
  await customBtn(page).click();
  await input(page).fill('42');
  await page.keyboard.press('Escape');
  await expect(page.locator('.snooze-custom')).toBeHidden();
  await expect(customBtn(page)).toBeVisible();
  expect(await signals(page)).toEqual([]);
  expect(await page.evaluate(() => window.__closed || false)).toBe(false);
});

test('preset buttons still emit snooze/<n>', async ({ page }) => {
  await openExpanded(page);
  await preset(page, '5m').click();
  await expect(page.locator('.title')).toHaveText('Snoozed');
  expect(await signals(page)).toEqual(['snooze/5']);
});

test('snooze controls stay hidden when the daemon is disabled', async ({ page }) => {
  // No sport/stoken => daemonEnabled is false => the whole bar must not render.
  await open(page, { snooze: '0', sport: '', stoken: '' });
  await expect(page.locator('#snoozeBar')).toBeHidden();
  await expect(toggle(page)).toBeHidden();
  await expect(page.locator('.snooze-custom')).toBeHidden();
  await expect(customBtn(page)).toHaveCount(0);
});

// --- "Mute this …" -----------------------------------------------------------
const muteBtn = (page) => page.locator('#muteBtn');
const b64url = (s) => Buffer.from(s).toString('base64url');

test('no mute button unless the launcher asked for one', async ({ page }) => {
  await open(page);
  await expect(muteBtn(page)).toHaveCount(0);
  await expect(page.locator('#muteBar')).toBeHidden();
});

test('no mute button without a daemon to write the marker', async ({ page }) => {
  await open(page, { mute: '1', sport: '', stoken: '' });
  await expect(muteBtn(page)).toHaveCount(0);
});

test('the mute button names the session kind', async ({ page }) => {
  await open(page, { mute: '1', mutekindb64: b64url('conversation') });
  await expect(muteBtn(page)).toBeVisible();
  await expect(muteBtn(page)).toHaveText('🔕 Mute this conversation');
});

test('with no kind the button says session', async ({ page }) => {
  await open(page, { mute: '1' });
  await expect(muteBtn(page)).toHaveText('🔕 Mute this session');
});

test('muting signals mute once, shows the muted screen, and closes', async ({ page }) => {
  await open(page, { mute: '1', mutekindb64: b64url('terminal') });
  await muteBtn(page).click();
  await expect(page.locator('.title')).toHaveText('Muted');
  await expect(page.locator('.subtitle')).toHaveText('No more alerts from this terminal');
  await expect.poll(() => page.evaluate(() => window.__closed === true)).toBe(true);
  // The click must not bubble into a dismiss/focus, and no second decision fires.
  await page.mouse.click(10, 10);
  expect(await signals(page)).toEqual(['mute']);
});

test('a kind with markup is shown as text, not parsed', async ({ page }) => {
  await open(page, { mute: '1', mutekindb64: b64url('<b>x</b>') });
  await muteBtn(page).click();
  await expect(page.locator('.subtitle')).toHaveText('No more alerts from this <b>x</b>');
  await expect(page.locator('#app b')).toHaveCount(0);
});

test('after a snooze the mute button does nothing', async ({ page }) => {
  await openExpanded(page, { mute: '1' });
  const btn = await muteBtn(page).elementHandle();
  await page.locator('button.snooze-btn').filter({ hasText: /^5m$/ }).click();
  await btn.evaluate((b) => b.click());
  expect(await signals(page)).toEqual(['snooze/5']);
});

// --- what a snooze covers ------------------------------------------------------
// The launcher sends snoozescope=session only when it named a hold for the
// session (lib/ada-show-alert.sh), and the noun in mutekindb64. The clock is
// pinned so the confirmation's time is exact.

test.describe('scope labels and confirmations', () => {
  test.use({ locale: 'en-US', timezoneId: 'America/New_York' });
  const at = (page, iso) => page.clock.setFixedTime(new Date(iso));
  const label = (page) => page.locator('#snoozeLabel');
  const note = (page) => page.locator('.confirm-note');
  const session = { snoozescope: 'session', mutekindb64: b64url('conversation') };

  test('a plain snooze says it covers this alert', async ({ page }) => {
    await open(page);
    await expect(label(page)).toHaveText('Snooze this alert');
    await expect(toggle(page)).toHaveAttribute('title', 'Show this alert again later. Other alerts keep coming.');
  });

  test('a session-wide snooze names the conversation', async ({ page }) => {
    await open(page, session);
    await expect(label(page)).toHaveText('Snooze this conversation');
    await expect(toggle(page)).toHaveAttribute('title', /Sending it a message ends the snooze early/);
  });

  test('a session-wide snooze with no noun says session', async ({ page }) => {
    await open(page, { snoozescope: 'session' });
    await expect(label(page)).toHaveText('Snooze this session');
  });

  test('the noun is text, not markup', async ({ page }) => {
    await open(page, { snoozescope: 'session', mutekindb64: b64url('<b>x</b>') });
    await expect(label(page)).toHaveText('Snooze this <b>x</b>');
    await expect(page.locator('#snoozeToggle b')).toHaveCount(0);
  });

  test('the noun alone does not widen the scope', async ({ page }) => {
    await open(page, { mute: '1', mutekindb64: b64url('conversation') });
    await expect(label(page)).toHaveText('Snooze this alert');
  });

  test('a plain snooze confirms the time the alert comes back', async ({ page }) => {
    await at(page, '2026-09-24T14:30:00-04:00');
    await openExpanded(page);
    await preset(page, '5m').click();
    await expect(page.locator('.subtitle')).toHaveText(/^This alert comes back at 2:35\sPM$/);
    await expect(note(page)).toHaveText('Other alerts still come through');
  });

  test('a session-wide snooze confirms how long the conversation stays quiet', async ({ page }) => {
    await at(page, '2026-09-24T14:30:00-04:00');
    await openExpanded(page, session);
    await preset(page, '30m').click();
    await expect(page.locator('.subtitle')).toHaveText(/^This conversation is quiet until 3:00\sPM$/);
    await expect(note(page)).toHaveText('Send it a message to end the snooze early');
    expect(await signals(page)).toEqual(['snooze/30']);
  });

  test('only a conversation promises that a message ends the snooze', async ({ page }) => {
    await at(page, '2026-09-24T14:30:00-04:00');
    await openExpanded(page, { snoozescope: 'session', mutekindb64: b64url('agent') });
    await preset(page, '10m').click();
    await expect(page.locator('.subtitle')).toHaveText(/^This agent is quiet until 2:40\sPM$/);
    await expect(note(page)).toHaveCount(0);
  });

  test('a snooze into the next day says tomorrow', async ({ page }) => {
    await at(page, '2026-09-24T23:50:00-04:00');
    await openExpanded(page, session);
    await preset(page, '30m').click();
    await expect(page.locator('.subtitle')).toHaveText(/^This conversation is quiet until 12:20\sAM tomorrow$/);
  });

  test('a click on the confirmation closes it at once, with no second signal', async ({ page }) => {
    await openExpanded(page);
    await preset(page, '5m').click();
    await expect(page.locator('.title')).toHaveText('Snoozed');
    await page.mouse.click(10, 10);
    await expect.poll(() => page.evaluate(() => window.__closed === true), { timeout: 500 }).toBe(true);
    expect(await signals(page)).toEqual(['snooze/5']);
  });

  test('Esc on the confirmation closes it too', async ({ page }) => {
    await openExpanded(page);
    await preset(page, '5m').click();
    await expect(page.locator('.title')).toHaveText('Snoozed');
    await page.keyboard.press('Escape');
    await expect.poll(() => page.evaluate(() => window.__closed === true), { timeout: 500 }).toBe(true);
    expect(await signals(page)).toEqual(['snooze/5']);
  });

  test('left alone, the confirmation closes by itself', async ({ page }) => {
    await openExpanded(page);
    await preset(page, '5m').click();
    await expect.poll(() => page.evaluate(() => window.__closed === true)).toBe(true);
  });

  test('the reminder after a session-wide snooze says the conversation can alert again', async ({ page }) => {
    await open(page, { snoozed: '1', ...session });
    await expect(page.locator('.subtitle')).toHaveText('Snooze over · this conversation can alert again');
    await expect(label(page)).toHaveText('Snooze this conversation');
  });
});
