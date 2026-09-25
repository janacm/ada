// Behavioural tests for the summary of a pause in alert.html (mode=summary):
// the title and subtitle, the rows in the order the launcher sent them, rows
// that open their alert's target through the daemon's open/<i>, the overflow
// row, and the fallback for a payload the page cannot trust. How the launcher
// builds the payload is tested in the .bats suite (test/ada-show-alert.bats,
// test/ada-pause.bats); its format is in the header of lib/ada-show-alert.sh.
//
// Same stubs as the other page specs: adaSignal records what the page would
// send the daemon, and window.close only sets a flag.
const { test, expect } = require('@playwright/test');
const path = require('path');
const { pathToFileURL } = require('url');
const { recordCoverage } = require('./alert-coverage');

const ALERT_FILE = pathToFileURL(path.join(__dirname, '..', 'alert.html')).href;
recordCoverage(test, ALERT_FILE);

// All times are pinned to New York, on 2026-09-24 unless a test says otherwise.
test.use({ locale: 'en-US', timezoneId: 'America/New_York' });
const NOW = '2026-09-24T16:00:00-04:00';
const epoch = (iso) => Math.floor(Date.parse(iso) / 1000);
const at = (hhmm, day = '2026-09-24') => epoch(`${day}T${hhmm}:00-04:00`);
const b64url = (s) => Buffer.from(s, 'utf8').toString('base64url');

function row(over = {}) {
  return { t: at('15:00'), l: 'npm test', d: '1m 2s', c: '0', r: 'ada', k: 'terminal',
           s: 'ok', z: 0, o: 0, a: '', ...over };
}

function payload(items, over = {}) {
  return { v: 1, n: items.length, why: 'ended', end: at('15:45'), items, ...over };
}

// What the launcher sends a summary: sport/stoken only when a row can open.
// An override of null leaves that param out.
function summaryURL(data, overrides = {}) {
  const query = {
    mode: 'summary',
    summaryb64: typeof data === 'string' ? data : b64url(JSON.stringify(data)),
    autoclose: '600',
    sport: '1',
    stoken: 'tok',
    snooze: '0',
    focus: '0',
    ...overrides,
  };
  for (const key of Object.keys(query)) if (query[key] === null) delete query[key];
  return `${ALERT_FILE}?${new URLSearchParams(query)}`;
}

async function open(page, data, overrides = {}) {
  await page.clock.setFixedTime(new Date(NOW));
  await page.addInitScript(() => {
    window.__sig = [];
    window.webkit = { messageHandlers: { adaSignal: { postMessage: (p) => window.__sig.push(p) } } };
    window.close = () => { window.__closed = true; };
  });
  await page.goto(summaryURL(data, overrides));
}

const signals = (page) => page.evaluate(() => window.__sig);
const closed = (page) => page.evaluate(() => window.__closed || false);
const rows = (page) => page.locator('#summaryList .summary-row');
const title = (page) => page.locator('.title');
const subtitle = (page) => page.locator('.subtitle');

// --- title and subtitle ---------------------------------------------------------

test('one alert: a bell, a singular title, and when the pause ended', async ({ page }) => {
  await open(page, payload([row()]));
  await expect(page.locator('#statusIcon')).toHaveText('🔔');
  await expect(title(page)).toHaveText('1 alert while you were paused');
  await expect(subtitle(page)).toHaveText(/^Pause ended at 3:45\sPM$/);
});

test('the count in the title is every held alert, not just the rows sent', async ({ page }) => {
  await open(page, payload([row(), row()], { n: 7 }));
  await expect(title(page)).toHaveText('7 alerts while you were paused');
});

test('the subtitle counts what failed and what needs you', async ({ page }) => {
  await open(page, payload([row({ s: 'ask' }), row({ s: 'fail' }), row()]));
  await expect(subtitle(page)).toHaveText(/^Pause ended at 3:45\sPM · 1 failed · 1 needs you$/);
});

test('the subtitle counts come from the totals, which can exceed the rows sent', async ({ page }) => {
  const items = [row({ s: 'ask' }), ...Array.from({ length: 29 }, () => row({ s: 'fail' }))];
  await open(page, payload(items, { n: 45, ask: 3, fail: 40 }));
  await expect(title(page)).toHaveText('45 alerts while you were paused');
  await expect(subtitle(page)).toHaveText(/^Pause ended at 3:45\sPM · 40 failed · 3 need you$/);
  await expect(page.locator('.summary-more')).toHaveText('and 15 more');
});

test('two asking read "need you"', async ({ page }) => {
  await open(page, payload([row({ s: 'ask' }), row({ s: 'ask' })]));
  await expect(subtitle(page)).toHaveText(/ · 2 need you$/);
});

test('a resumed pause says when you resumed', async ({ page }) => {
  await open(page, payload([row()], { why: 'resumed', end: at('15:12') }));
  await expect(subtitle(page)).toHaveText(/^Resumed at 3:12\sPM$/);
});

test('a pause that ended the day before says yesterday', async ({ page }) => {
  await open(page, payload([row()], { end: at('23:50', '2026-09-23') }));
  await expect(subtitle(page)).toHaveText(/^Pause ended at 11:50\sPM yesterday$/);
});

test('the title never turns red, whatever the URL says', async ({ page }) => {
  await open(page, payload([row({ s: 'fail', c: '2' })]), { code: '2' });
  expect(await title(page).evaluate((el) => el.style.background)).toBe('');
  await expect(page.locator('#statusIcon')).toHaveText('🔔');
});

test('no command box, badges, snooze, mute or pause, whatever the URL says', async ({ page }) => {
  await open(page, payload([row()]), {
    cmd: 'npm run build', snooze: '1', snoozemins: '5,10', mute: '1', pause: '1', pausemins: '5',
    focus: '1', pauseduntil: '0',
  });
  await expect(page.locator('.cmd-box')).toBeHidden();
  await expect(page.locator('.meta')).toBeHidden();
  await expect(page.locator('#snoozeBar')).toBeHidden();
  await expect(page.locator('#muteBar')).toBeHidden();
  await expect(page.locator('#pauseToggle')).toHaveCount(0);
  await expect(page.locator('#pauseOptions')).toBeHidden();
  await expect(page.locator('#pausedNote')).toHaveCount(0);
  // focus=1 would make a click outside the list a focus request.
  await page.mouse.click(10, 10);
  expect(await signals(page)).toEqual(['dismiss']);
});

// --- rows ----------------------------------------------------------------------------

test('rows keep the payload order, each with its status mark', async ({ page }) => {
  await open(page, payload([
    row({ l: 'finished first', s: 'ok' }),
    row({ l: 'asked', s: 'ask' }),
    row({ l: 'failed', s: 'fail' }),
  ]));
  expect(await rows(page).locator('.summary-label').allTextContents()).toEqual(['finished first', 'asked', 'failed']);
  expect(await rows(page).evaluateAll((els) => els.map((el) => el.className)))
    .toEqual(['summary-row status-ok', 'summary-row status-ask', 'summary-row status-fail']);
  expect(await rows(page).locator('.summary-mark').allTextContents()).toEqual(['✓', '!', '✕']);
  expect(await rows(page).locator('.summary-mark').evaluateAll((els) => els.map((el) => el.getAttribute('aria-label'))))
    .toEqual(['Finished', 'Needs you', 'Failed']);
});

test('a row shows its time, with the date when it was not today', async ({ page }) => {
  await open(page, payload([row({ t: at('14:04') }), row({ t: at('09:30', '2026-09-22') })]));
  const times = await rows(page).locator('.summary-time').allTextContents();
  expect(times[0]).toMatch(/^2:04\sPM$/);
  expect(times[1]).toMatch(/^Sep 22 9:30\sAM$/);
});

test('the meta line is the repo and duration, with no duration for a permission prompt', async ({ page }) => {
  await open(page, payload([
    row({ r: 'ada', d: '2m 14s' }),
    row({ r: 'ada', d: 'permission', s: 'ask' }),
    row({ r: '', d: '41s' }),
    row({ r: '', d: '' }),
  ]));
  const metas = await rows(page).evaluateAll((els) => els.map((el) => el.querySelector('.summary-meta')?.textContent ?? null));
  expect(metas).toEqual(['ada · 2m 14s', 'ada', '41s', null]);
});

test('a snooze reminder is tagged', async ({ page }) => {
  await open(page, payload([row({ z: 1 }), row()]));
  await expect(rows(page).nth(0).locator('.summary-tag')).toHaveText('reminder');
  await expect(rows(page).nth(1).locator('.summary-tag')).toHaveCount(0);
});

test('a long label stays on one line, with the full text in its title', async ({ page }) => {
  const long = 'x'.repeat(40) + ' ' + 'y'.repeat(79);
  await open(page, payload([row({ l: long })]));
  const label = rows(page).locator('.summary-label');
  await expect(label).toHaveAttribute('title', long);
  expect(await label.evaluate((el) => getComputedStyle(el).whiteSpace)).toBe('nowrap');
  expect(await label.evaluate((el) => el.scrollWidth > el.clientWidth)).toBe(true);
});

test('an empty label shows a dash', async ({ page }) => {
  await open(page, payload([row({ l: '' })]));
  await expect(rows(page).locator('.summary-label')).toHaveText('—');
});

test('markup in a label, repo or app name stays text', async ({ page }) => {
  await open(page, payload([row({ l: '<img src=x onerror="window.__xss=1"><b>hi</b>', r: '<i>r</i>', o: 1, a: '<u>A</u>' })]));
  await expect(rows(page).locator('.summary-label')).toHaveText('<img src=x onerror="window.__xss=1"><b>hi</b>');
  await expect(rows(page).locator('.summary-meta')).toHaveText('<i>r</i> · 1m 2s');
  await expect(rows(page)).toHaveAttribute('title', 'Open in <u>A</u>');
  await expect(page.locator('#summaryList img, #summaryList b, #summaryList i, #summaryList u')).toHaveCount(0);
  expect(await page.evaluate(() => window.__xss)).toBeUndefined();
});

// --- opening a row ------------------------------------------------------------------

test('a row that can open is a button named for its app; a click opens it and closes the summary', async ({ page }) => {
  await open(page, payload([row({ l: 'static' }), row({ l: 'claude turn', o: 1, a: 'Claude' })]));
  const target = rows(page).nth(1);
  expect(await target.evaluate((el) => el.tagName)).toBe('BUTTON');
  await expect(target).toHaveAttribute('title', 'Open in Claude');
  await expect(target.locator('.summary-open')).toHaveCount(1);
  await target.click();
  expect(await signals(page)).toEqual(['open/1']);
  expect(await closed(page)).toBe(true);
  // Already decided: nothing more goes to the daemon.
  await page.mouse.click(10, 10);
  await page.keyboard.press('Escape');
  expect(await signals(page)).toEqual(['open/1']);
});

test('with no app name the row says it opens where the alert came from', async ({ page }) => {
  await open(page, payload([row({ o: 1, a: '' })]));
  await expect(rows(page)).toHaveAttribute('title', 'Open where it came from');
});

test('Enter on a focused row opens it', async ({ page }) => {
  await open(page, payload([row({ o: 1, a: 'Ghostty' })]));
  await rows(page).focus();
  await page.keyboard.press('Enter');
  expect(await signals(page)).toEqual(['open/0']);
});

test('a row that opens nothing is not a button, and a click on it does nothing', async ({ page }) => {
  await open(page, payload([row({ l: 'static' })]), { sport: null, stoken: null });
  expect(await rows(page).evaluate((el) => el.tagName)).toBe('DIV');
  await expect(rows(page).locator('.summary-open')).toHaveCount(0);
  await rows(page).click();
  expect(await closed(page)).toBe(false);
});

test('without a daemon no row opens, even one the payload marks', async ({ page }) => {
  await open(page, payload([row({ o: 1, a: 'Claude' })]), { sport: null, stoken: null });
  expect(await rows(page).evaluate((el) => el.tagName)).toBe('DIV');
  await expect(page.locator('#dismissHint')).toHaveText('Click anywhere or press Esc to dismiss');
});

test('the hint says a row opens only when one can', async ({ page }) => {
  await open(page, payload([row({ o: 1 })]));
  await expect(page.locator('#dismissHint'))
    .toHaveText('Click an alert to open it, click anywhere else or press Esc to dismiss');
  await expect(page.locator('#dismissHint kbd')).toHaveText('Esc');

  await open(page, payload([row()]), { sport: null, stoken: null });
  await expect(page.locator('#dismissHint')).toHaveText('Click anywhere or press Esc to dismiss');
});

// --- the list, the overflow, dismissing ---------------------------------------------

test('more alerts than rows end with "and N more"', async ({ page }) => {
  await open(page, payload([row(), row(), row()], { n: 15 }));
  await expect(page.locator('#summaryList .summary-more')).toHaveText('and 12 more');
  expect(await page.locator('#summaryList > *').last().evaluate((el) => el.className)).toBe('summary-more');
});

test('no overflow row when every alert has one', async ({ page }) => {
  await open(page, payload([row(), row()]));
  await expect(page.locator('.summary-more')).toHaveCount(0);
});

test('a click outside the list dismisses, one signal', async ({ page }) => {
  await open(page, payload([row({ o: 1 })]));
  await page.mouse.click(10, 10);
  await page.mouse.click(20, 20);
  expect(await signals(page)).toEqual(['dismiss']);
  expect(await closed(page)).toBe(true);
});

test('a press on a row let go outside the list is not a dismiss', async ({ page }) => {
  await open(page, payload([row({ o: 1 })]));
  const box = await rows(page).boundingBox();
  const list = await page.locator('#summaryList').boundingBox();
  await page.mouse.move(box.x + 20, box.y + box.height / 2);
  await page.mouse.down();
  await page.mouse.move(box.x + 20, list.y + list.height + 40, { steps: 5 });
  await page.mouse.up();
  expect(await signals(page)).toEqual([]);
  expect(await closed(page)).toBe(false);
  await page.mouse.click(10, 10);
  expect(await signals(page)).toEqual(['dismiss']);
});

test('Esc dismisses', async ({ page }) => {
  await open(page, payload([row()]));
  await page.keyboard.press('Escape');
  expect(await signals(page)).toEqual(['dismiss']);
  expect(await closed(page)).toBe(true);
});

test('thirty rows scroll inside the list, which does not dismiss, and the page still fits', async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 775 });
  const items = Array.from({ length: 30 }, (_, i) => row({ l: `turn ${i}`, t: at('15:00') + i * 60 }));
  await open(page, payload(items));
  const list = page.locator('#summaryList');
  expect(await list.evaluate((el) => el.scrollHeight > el.clientHeight)).toBe(true);
  await list.hover();
  await page.mouse.wheel(0, 400);
  await expect.poll(() => list.evaluate((el) => el.scrollTop)).toBeGreaterThan(0);
  await list.click({ position: { x: 3, y: 3 } });
  expect(await signals(page)).toEqual([]);
  expect(await closed(page)).toBe(false);
  const box = await page.locator('#app').boundingBox();
  expect(box.y).toBeGreaterThanOrEqual(0);
  expect(box.y + box.height).toBeLessThanOrEqual(775);
});

test('the summary stays up for its autoclose, not the alert default', async ({ page }) => {
  await page.clock.install({ time: new Date(NOW) });
  await page.addInitScript(() => {
    window.__sig = [];
    window.webkit = { messageHandlers: { adaSignal: { postMessage: (p) => window.__sig.push(p) } } };
    window.close = () => { window.__closed = true; };
  });
  await page.goto(summaryURL(payload([row()])));
  await page.clock.runFor(120 * 1000);
  expect(await closed(page)).toBe(false);
  await page.clock.runFor(480 * 1000);
  expect(await closed(page)).toBe(true);
});

// --- a payload the page cannot trust ------------------------------------------------

const unreadable = {
  'no payload at all': null,
  'not base64url': '!!!',
  'not JSON': b64url('{"v":1,'),
  'JSON but not an object': b64url('[1,2]'),
  'another version': payload([row()], { v: 2 }),
  'a count that is not a number': payload([row()], { n: '1' }),
  'fewer alerts than rows': payload([row(), row()], { n: 1 }),
  'an unknown reason': payload([row()], { why: 'later' }),
  'a negative end': payload([row()], { end: -1 }),
  'items that are not a list': payload([], { items: { 0: row() }, n: 1 }),
  'more than 50 rows': payload(Array.from({ length: 51 }, () => row())),
  'a row that is not an object': payload(['npm test']),
  'a time that is a string': payload([row({ t: '1790000000' })]),
  'a label that is not a string': payload([row({ l: 42 })]),
  'a missing app name': payload([row({ a: undefined })]),
  'an unknown status': payload([row({ s: 'maybe' })]),
  'a reminder flag of 2': payload([row({ z: 2 })]),
  'an open flag of true': payload([row({ o: true })]),
  'a failed total that is not a number': payload([row()], { fail: '1' }),
  'fewer needs-you than needs-you rows': payload([row({ s: 'ask' }), row({ s: 'ask' })], { ask: 1 }),
  'more failed and needs-you than alerts': payload([row()], { n: 3, ask: 2, fail: 2 }),
};

for (const [name, data] of Object.entries(unreadable)) {
  test(`${name}: the summary says it could not read the list`, async ({ page }) => {
    await open(page, data === null ? '' : data, data === null ? { summaryb64: null } : {});
    await expect(title(page)).toHaveText('Alerts while you were paused');
    await expect(subtitle(page)).toHaveText('The list could not be read');
    await expect(page.locator('#summaryList')).toHaveCount(0);
    await expect(page.locator('.cmd-box')).toBeHidden();
    await expect(page.locator('#dismissHint')).toHaveText('Click anywhere or press Esc to dismiss');
  });
}

test('only overflow and no rows still reads', async ({ page }) => {
  await open(page, payload([], { n: 5 }));
  await expect(title(page)).toHaveText('5 alerts while you were paused');
  await expect(rows(page)).toHaveCount(0);
  await expect(page.locator('.summary-more')).toHaveText('and 5 more');
});
