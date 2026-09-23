// Behavioural tests for everything in alert.html except the snooze bar (that
// is alert-snooze.spec.js): how the page decodes the launcher's query string,
// the success/failure/snoozed states, click and Esc dismissal, the countdown,
// the feedback link, and the fetch fallback when there is no native bridge.
//
// The native helper injects window.webkit.messageHandlers.{adaSignal,adaOpen}
// and replaces window.close. Most tests stub those before the page loads and
// read back what the page sent; `bare: true` loads it with no bridge at all.
const { test, expect } = require('@playwright/test');
const path = require('path');
const { pathToFileURL } = require('url');
const { recordCoverage } = require('./alert-coverage');

const ALERT_FILE = pathToFileURL(path.join(__dirname, '..', 'alert.html')).href;
recordCoverage(test, ALERT_FILE);

// Base64url, as ada-show-alert.sh writes cmdb64 / repob64 / focusnameb64.
const b64url = (s) => Buffer.from(s, 'utf8').toString('base64url');

function alertURL(overrides = {}) {
  const params = new URLSearchParams({
    cmd: 'npm run build',
    duration: '2m 14s',
    code: '0',
    autoclose: '300',
    sport: '1',
    stoken: 'tok',
    snooze: '0',
    focus: '0',
    ...overrides,
  });
  for (const [k, v] of [...params]) if (v === null || v === undefined) params.delete(k);
  return `${ALERT_FILE}?${params.toString()}`;
}

async function open(page, overrides = {}, { bare = false, native = false } = {}) {
  await page.addInitScript(({ bare, native }) => {
    window.__sig = [];
    window.__opened = [];
    window.close = () => { window.__closed = true; };
    window.open = (url) => { window.__opened.push(url); };
    if (native) window.adaNative = true;
    if (!bare) {
      window.webkit = {
        messageHandlers: {
          adaSignal: { postMessage: (p) => window.__sig.push(p) },
          adaOpen: { postMessage: (u) => window.__opened.push('bridge:' + u) },
        },
      };
    }
  }, { bare, native });
  await page.goto(alertURL(overrides));
}

const signals = (page) => page.evaluate(() => window.__sig);
const closed = (page) => page.evaluate(() => window.__closed || false);

// --- decoding the launcher's query string ------------------------------------

test('base64url labels win over the legacy params and survive non-ASCII', async ({ page }) => {
  await open(page, { cmd: 'legacy', cmdb64: b64url('pytest -k "émoji ✓"'), repob64: b64url('agent-core') });
  await expect(page.locator('#cmdDisplay')).toHaveText('pytest -k "émoji ✓"');
  await expect(page.locator('#repoDisplay')).toHaveText('agent-core');
  await expect(page.locator('#repoBadge')).toHaveClass(/is-visible/);
});

test('an undecodable cmdb64 falls back to the plain cmd param', async ({ page }) => {
  await open(page, { cmd: 'make test', cmdb64: '!!!not-base64!!!' });
  await expect(page.locator('#cmdDisplay')).toHaveText('make test');
});

test('with no label at all the command shows a dash, and no repo badge', async ({ page }) => {
  await open(page, { cmd: '', duration: '' });
  await expect(page.locator('#cmdDisplay')).toHaveText('—');
  await expect(page.locator('#durationDisplay')).toHaveText('—');
  await expect(page.locator('#repoBadge')).not.toHaveClass(/is-visible/);
});

// WKWebView's loadFileURL can re-escape a percent-encoded query value, so under
// the native helper a label arriving as "a%20b" is decoded once more.
test('under the native helper a re-escaped legacy label is decoded once more', async ({ page }) => {
  await open(page, { cmd: 'git%20status' }, { native: true });
  await expect(page.locator('#cmdDisplay')).toHaveText('git status');
});

test('a malformed escape under the native helper is shown as-is', async ({ page }) => {
  await open(page, { cmd: '100%zz and %E0%A4%A' }, { native: true });
  await expect(page.locator('#cmdDisplay')).toHaveText('100%zz and %E0%A4%A');
});

test('outside the native helper a literal %20 is left alone', async ({ page }) => {
  await open(page, { cmd: 'git%20status' });
  await expect(page.locator('#cmdDisplay')).toHaveText('git%20status');
});

// --- states --------------------------------------------------------------------

test('exit 0 reads as success', async ({ page }) => {
  await open(page, { code: '0' });
  await expect(page.locator('#exitDisplay')).toHaveText('Exit 0');
  await expect(page.locator('#exitBadge')).toHaveClass('badge success');
  await expect(page.locator('.title')).toHaveText('Command Finished');
});

test('a non-zero exit reads as failure', async ({ page }) => {
  await open(page, { code: '2' });
  await expect(page.locator('#exitDisplay')).toHaveText('Exit 2');
  await expect(page.locator('#exitBadge')).toHaveClass('badge failure');
  await expect(page.locator('#statusIcon')).toHaveText('✕');
  await expect(page.locator('.title')).toHaveText('Command Failed');
});

test('a snoozed relaunch says so in the subtitle', async ({ page }) => {
  await open(page, { snoozed: '1' });
  await expect(page.locator('.subtitle')).toHaveText('Snoozed reminder · the terminal is ready for you');
});

// --- dismissal -------------------------------------------------------------------

test('a click dismisses: one signal to the daemon, then the window closes', async ({ page }) => {
  await open(page);
  await page.mouse.click(10, 10);
  await page.mouse.click(20, 20); // already dismissed: no second signal
  expect(await signals(page)).toEqual(['dismiss']);
  expect(await closed(page)).toBe(true);
});

test('Esc dismisses the same way', async ({ page }) => {
  await open(page);
  await page.keyboard.press('Escape');
  expect(await signals(page)).toEqual(['dismiss']);
  expect(await closed(page)).toBe(true);
});

test('with a click target, the hint names it and a click asks the daemon to focus', async ({ page }) => {
  await open(page, { focus: '1', focusnameb64: b64url('Ghostty') });
  await expect(page.locator('#dismissHint')).toHaveText('Click anywhere to return to Ghostty or press Esc to dismiss');
  await page.mouse.click(10, 10);
  expect(await signals(page)).toEqual(['focus']);
});

test('with no daemon, dismissing closes the window without signalling', async ({ page }) => {
  await open(page, { sport: '', stoken: '', focus: '1' });
  await page.keyboard.press('Escape');
  expect(await signals(page)).toEqual([]);
  expect(await closed(page)).toBe(true);
});

test('the countdown dismisses the alert when it runs out', async ({ page }) => {
  await open(page, { autoclose: '2' });
  await expect.poll(() => closed(page), { timeout: 4000 }).toBe(true);
  expect(await signals(page)).toEqual(['dismiss']);
});

test('a bogus autoclose falls back to the 90s default instead of closing at once', async ({ page }) => {
  await open(page, { autoclose: 'soon' });
  await page.waitForTimeout(1200);
  expect(await closed(page)).toBe(false);
});

// Without the WebKit bridge (a plain browser), signals go out as a no-cors
// fetch to the loopback daemon instead.
test('with no native bridge, a dismiss is sent as a fetch to the daemon', async ({ page }) => {
  const hits = [];
  await page.route('http://127.0.0.1:47125/**', (route) => {
    hits.push(new URL(route.request().url()).pathname);
    route.fulfill({ status: 200, body: 'ok' });
  });
  await open(page, { sport: '47125', stoken: 'tok' }, { bare: true });
  await page.keyboard.press('Escape');
  await expect.poll(() => hits).toEqual(['/tok/dismiss']);
});

// --- feedback link -----------------------------------------------------------------

test('the feedback link opens through the adaOpen bridge and does not dismiss', async ({ page }) => {
  await open(page);
  await page.locator('#feedbackLink').click();
  const opened = await page.evaluate(() => window.__opened);
  expect(opened).toEqual(['bridge:https://github.com/janacm/ada/issues/new']);
  expect(await signals(page)).toEqual([]);
  expect(await closed(page)).toBe(false);
});

test('without the bridge the feedback link falls back to window.open', async ({ page }) => {
  await open(page, {}, { bare: true });
  await page.locator('#feedbackLink').click();
  expect(await page.evaluate(() => window.__opened)).toEqual(['https://github.com/janacm/ada/issues/new']);
  expect(await closed(page)).toBe(false);
});

test('clicks inside the feedback box do not dismiss the alert', async ({ page }) => {
  await open(page);
  await page.locator('#feedbackBox .feedback-text').click({ position: { x: 5, y: 5 } });
  expect(await signals(page)).toEqual([]);
});
