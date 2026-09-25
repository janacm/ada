// Behavioural tests for "Pause all alerts" in alert.html: the toggle beside the
// mute pill, its row of delays, how it folds with the snooze row, the pause
// confirmation, and the note a test alert shows while a pause is on. The pause
// itself (ada-pause.sh, the held alerts, the timer) is tested in the .bats
// suite and test/snooze_daemon_check.py; the summary window is
// alert-summary.spec.js.
//
// Same stubs as alert-snooze.spec.js: adaSignal records what the page would
// send the daemon, adaSnoozePin records pin changes, and window.close only
// sets a flag.
const { test, expect } = require('@playwright/test');
const path = require('path');
const { pathToFileURL } = require('url');
const { recordCoverage } = require('./alert-coverage');

const ALERT_FILE = pathToFileURL(path.join(__dirname, '..', 'alert.html')).href;
recordCoverage(test, ALERT_FILE);

const b64url = (s) => Buffer.from(s, 'utf8').toString('base64url');
const RESUME = '~/Documents/GitHub/ada/lib/ada-pause.sh resume';
const epoch = (iso) => String(Math.floor(Date.parse(iso) / 1000));

// What the launcher sends an alert that has a daemon and ada-pause.sh beside
// it. An override of null leaves that param out.
function alertURL(overrides = {}) {
  const query = {
    cmd: 'npm run build',
    duration: '2m 14s',
    code: '0',
    autoclose: '300', // long, so the countdown never auto-dismisses mid-test
    sport: '1',
    stoken: 'tok',
    snooze: '1',
    snoozemins: '5,10,30',
    focus: '0',
    pause: '1',
    pausemins: '5,10,30,60',
    pauseresumeb64: b64url(RESUME),
    ...overrides,
  };
  for (const key of Object.keys(query)) if (query[key] === null) delete query[key];
  return `${ALERT_FILE}?${new URLSearchParams(query)}`;
}

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

const signals = (page) => page.evaluate(() => window.__sig);
const pins = (page) => page.evaluate(() => window.__pins);
const closed = (page) => page.evaluate(() => window.__closed || false);
const exact = (label) => new RegExp(`^${label}$`);
const pauseToggle = (page) => page.locator('#pauseToggle');
const pausePill = (page, label) => page.locator('button.pause-btn').filter({ hasText: exact(label) });
const pauseInput = (page) => page.locator('.pause-custom-input');
const snoozeToggle = (page) => page.locator('#snoozeToggle');
const snoozePill = (page, label) => page.locator('button.snooze-btn').filter({ hasText: exact(label) });
const muteBtn = (page) => page.locator('#muteBtn');
const note = (page) => page.locator('#pausedNote');

// --- when the toggle shows ---------------------------------------------------

test('no pause toggle unless the launcher offers one', async ({ page }) => {
  await open(page, { pause: null });
  await expect(pauseToggle(page)).toHaveCount(0);
  await expect(page.locator('#muteBar')).toBeHidden();
});

test('no pause toggle without a daemon to run ada-pause.sh', async ({ page }) => {
  await open(page, { sport: '', stoken: '' });
  await expect(pauseToggle(page)).toHaveCount(0);
  await expect(page.locator('#muteBar')).toBeHidden();
});

test('a test alert shown during a pause offers no second pause', async ({ page }) => {
  await open(page, { pauseduntil: '0', pauseheld: '1' });
  await expect(pauseToggle(page)).toHaveCount(0);
  await expect(note(page)).toBeVisible();
});

test('the toggle sits in the grey row after the mute pill, folded', async ({ page }) => {
  await open(page, { mute: '1', mutekindb64: b64url('conversation') });
  const order = await page.locator('#muteBar > *').evaluateAll((els) => els.map((el) => el.id));
  expect(order).toEqual(['muteBtn', 'pauseToggle']);
  await expect(pauseToggle(page)).toHaveText('Pause all alerts');
  await expect(pauseToggle(page)).toHaveAttribute('aria-expanded', 'false');
  await expect(pauseToggle(page)).toHaveAttribute('aria-controls', 'pauseOptions');
  await expect(pauseToggle(page)).toHaveAttribute('title', /^Silence every alert from every session until the time you pick\. /);
  await expect(pausePill(page, '5m')).toBeHidden();
  await expect(pausePill(page, 'Custom')).toBeHidden();
});

test('with the mute button off, the grey row holds the toggle alone', async ({ page }) => {
  await open(page);
  await expect(page.locator('#muteBar')).toBeVisible();
  await expect(muteBtn(page)).toHaveCount(0);
  await expect(pauseToggle(page)).toBeVisible();
});

test('with snooze off the pause still shows', async ({ page }) => {
  await open(page, { snooze: '0', snoozemins: null });
  await expect(page.locator('#snoozeBar')).toBeHidden();
  await expect(pauseToggle(page)).toBeVisible();
});

// --- the row -------------------------------------------------------------------

test('the toggle reveals the delays and Custom without dismissing, and folds them again', async ({ page }) => {
  await open(page);
  await pauseToggle(page).click();
  await expect(pauseToggle(page)).toHaveAttribute('aria-expanded', 'true');
  for (const label of ['5m', '10m', '30m', '60m', 'Custom']) await expect(pausePill(page, label)).toBeVisible();
  await expect(pauseInput(page)).toBeHidden();

  await pauseToggle(page).click();
  await expect(pauseToggle(page)).toHaveAttribute('aria-expanded', 'false');
  await expect(pausePill(page, '5m')).toBeHidden();
  expect(await signals(page)).toEqual([]);
  expect(await closed(page)).toBe(false);
});

test('a click on the row around the pills is not a dismiss', async ({ page }) => {
  await open(page);
  await pauseToggle(page).click();
  await page.locator('#pauseOptions').click({ position: { x: 2, y: 2 } });
  await page.locator('#muteBar').click({ position: { x: 2, y: 2 } });
  expect(await signals(page)).toEqual([]);
  expect(await closed(page)).toBe(false);
});

test('each delay says what it does', async ({ page }) => {
  await open(page, { pausemins: '1,30' });
  await expect(pausePill(page, '30m')).toHaveAttribute('aria-label', 'Pause all alerts for 30 minutes');
  await expect(pausePill(page, '1m')).toHaveAttribute('aria-label', 'Pause all alerts for 1 minute');
  await expect(pauseInput(page)).toHaveAttribute('aria-label', 'Custom pause minutes');
});

test('the delays default to 5 10 30 60, and one the daemon would reject is not offered', async ({ page }) => {
  await open(page, { pausemins: null });
  expect(await page.locator('#pauseOptions > .pause-btn').allTextContents())
    .toEqual(['5m', '10m', '30m', '60m', 'Custom']);

  await open(page, { pausemins: '5,2000,0,x' });
  expect(await page.locator('#pauseOptions > .pause-btn').allTextContents()).toEqual(['5m', 'Custom']);
});

test('the pause row has no pin', async ({ page }) => {
  await open(page);
  await expect(page.locator('#pauseOptions .snooze-pin')).toHaveCount(0);
});

test('opening the pause row folds a pinned snooze row for this alert only', async ({ page }) => {
  await open(page, {}, { snoozePinned: true });
  await expect(snoozeToggle(page)).toHaveAttribute('aria-expanded', 'true');
  await expect(pauseToggle(page)).toHaveAttribute('aria-expanded', 'false');

  await pauseToggle(page).click();
  await expect(snoozeToggle(page)).toHaveAttribute('aria-expanded', 'false');
  await expect(snoozePill(page, '5m')).toBeHidden();
  await expect(pausePill(page, '5m')).toBeVisible();
  // Folding for this alert must not unpin: nothing posted, still pressed.
  expect(await pins(page)).toEqual([]);
  await expect(page.locator('#snoozePin')).toHaveAttribute('aria-pressed', 'true');
});

test('opening the snooze row folds the pause row', async ({ page }) => {
  await open(page);
  await pauseToggle(page).click();
  await snoozeToggle(page).click();
  await expect(snoozeToggle(page)).toHaveAttribute('aria-expanded', 'true');
  await expect(pauseToggle(page)).toHaveAttribute('aria-expanded', 'false');
  await expect(pausePill(page, '5m')).toBeHidden();
  expect(await signals(page)).toEqual([]);
});

test('folding the pause row closes its custom field', async ({ page }) => {
  await open(page);
  await pauseToggle(page).click();
  await pausePill(page, 'Custom').click();
  await pauseInput(page).fill('42');
  await snoozeToggle(page).click();
  await pauseToggle(page).click();
  await expect(pauseInput(page)).toBeHidden();
  await expect(pausePill(page, 'Custom')).toBeVisible();
  expect(await signals(page)).toEqual([]);
});

// --- pausing -----------------------------------------------------------------------
// The clock is pinned so the confirmation's time is exact. Chromium puts
// U+202F before AM/PM in en-US, hence \s.

test.describe('pausing', () => {
  test.use({ locale: 'en-US', timezoneId: 'America/New_York' });
  const at = (page, iso) => page.clock.setFixedTime(new Date(iso));
  const notes = (page) => page.locator('.confirm-note');

  test('a delay pauses: one signal, and the confirmation says until when and how to resume', async ({ page }) => {
    await at(page, '2026-09-24T14:00:00-04:00');
    await open(page);
    await pauseToggle(page).click();
    await pausePill(page, '30m').click();
    expect(await signals(page)).toEqual(['pause/30']);
    await expect(page.locator('.icon')).toHaveText('⏸️');
    await expect(page.locator('.title')).toHaveText('Paused');
    await expect(page.locator('.subtitle')).toHaveText(/^All alerts are paused until 2:30\sPM$/);
    await expect(notes(page)).toHaveText([
      'What arrives meanwhile is shown in one summary when the pause ends',
      'Resume early: ' + RESUME,
    ]);
    await expect(notes(page).locator('code')).toHaveText(RESUME);
  });

  test('without a resume command the confirmation leaves that line out', async ({ page }) => {
    await open(page, { pauseresumeb64: null });
    await pauseToggle(page).click();
    await pausePill(page, '5m').click();
    await expect(notes(page)).toHaveText(['What arrives meanwhile is shown in one summary when the pause ends']);
  });

  test('the resume command is text, not markup', async ({ page }) => {
    await open(page, { pauseresumeb64: b64url('<b>x</b> resume') });
    await pauseToggle(page).click();
    await pausePill(page, '5m').click();
    await expect(notes(page).locator('code')).toHaveText('<b>x</b> resume');
    await expect(page.locator('#app b')).toHaveCount(0);
  });

  test('Custom takes 1 minute, from Enter', async ({ page }) => {
    await at(page, '2026-09-24T14:00:00-04:00');
    await open(page);
    await pauseToggle(page).click();
    await pausePill(page, 'Custom').click();
    await expect(pauseInput(page)).toBeFocused();
    await pauseInput(page).fill('1');
    await page.keyboard.press('Enter');
    expect(await signals(page)).toEqual(['pause/1']);
    await expect(page.locator('.subtitle')).toHaveText(/^All alerts are paused until 2:01\sPM$/);
  });

  test('Custom takes a whole day, from Set, and says tomorrow', async ({ page }) => {
    await at(page, '2026-09-24T14:00:00-04:00');
    await open(page);
    await pauseToggle(page).click();
    await pausePill(page, 'Custom').click();
    await pauseInput(page).fill('1440');
    await pausePill(page, 'Set').click();
    expect(await signals(page)).toEqual(['pause/1440']);
    await expect(page.locator('.subtitle')).toHaveText(/^All alerts are paused until 2:00\sPM tomorrow$/);
  });

  for (const value of ['0', '9999', '']) {
    test(`Custom rejects "${value}": no signal, the field stays open`, async ({ page }) => {
      await open(page);
      await pauseToggle(page).click();
      await pausePill(page, 'Custom').click();
      await pauseInput(page).fill(value);
      await page.keyboard.press('Enter');
      await expect(pauseInput(page)).toHaveClass(/invalid/);
      await expect(pauseInput(page)).toBeVisible();
      await expect(page.locator('.title')).toHaveText('Command Finished');
      expect(await signals(page)).toEqual([]);
    });
  }

  test('Esc in the custom field cancels only the field', async ({ page }) => {
    await open(page);
    await pauseToggle(page).click();
    await pausePill(page, 'Custom').click();
    await pauseInput(page).fill('42');
    await page.keyboard.press('Escape');
    await expect(pauseInput(page)).toBeHidden();
    await expect(pausePill(page, 'Custom')).toBeVisible();
    await expect(pauseToggle(page)).toHaveAttribute('aria-expanded', 'true');
    expect(await signals(page)).toEqual([]);
    expect(await closed(page)).toBe(false);
  });

  test('the pause confirmation stays up 2s before closing itself', async ({ page }) => {
    await page.clock.install();
    await open(page);
    await pauseToggle(page).click();
    await pausePill(page, '5m').click();
    await page.clock.runFor(1900);
    expect(await closed(page)).toBe(false);
    await page.clock.runFor(200);
    expect(await closed(page)).toBe(true);
  });

  test('a click on the pause confirmation closes it at once, with no second signal', async ({ page }) => {
    await open(page);
    await pauseToggle(page).click();
    await pausePill(page, '5m').click();
    await expect(page.locator('.title')).toHaveText('Paused');
    await page.mouse.click(10, 10);
    await expect.poll(() => closed(page), { timeout: 500 }).toBe(true);
    expect(await signals(page)).toEqual(['pause/5']);
  });

  test('after a pause, snooze and mute do nothing', async ({ page }) => {
    await open(page, { mute: '1' });
    await snoozeToggle(page).click();
    const snoozeBtn = await snoozePill(page, '5m').elementHandle();
    const mute = await muteBtn(page).elementHandle();
    await pauseToggle(page).click();
    await pausePill(page, '10m').click();
    await snoozeBtn.evaluate((b) => b.click());
    await mute.evaluate((b) => b.click());
    expect(await signals(page)).toEqual(['pause/10']);
  });

  test('after a snooze the pause does nothing', async ({ page }) => {
    await open(page);
    await pauseToggle(page).click();
    const pauseBtn = await pausePill(page, '30m').elementHandle();
    await snoozeToggle(page).click();
    await snoozePill(page, '5m').click();
    await pauseBtn.evaluate((b) => b.click());
    expect(await signals(page)).toEqual(['snooze/5']);
  });
});

// --- the note on a test alert during a pause ------------------------------------

test.describe('a test alert during a pause', () => {
  test.use({ locale: 'en-US', timezoneId: 'America/New_York' });
  const at = (page, iso) => page.clock.setFixedTime(new Date(iso));
  const during = (extra = {}) => ({ pause: null, pausemins: null, pauseheld: '3', ...extra });

  test('says until when, how many alerts wait, and how to resume', async ({ page }) => {
    await at(page, '2026-09-24T14:00:00-04:00');
    await open(page, during({ pauseduntil: epoch('2026-09-24T14:30:00-04:00') }));
    await expect(note(page)).toHaveText(new RegExp(
      `^All alerts are paused until 2:30\\sPM · 3 held\\. Resume: ${RESUME.replace(/[.]/g, '\\.')}$`));
    await expect(note(page).locator('code')).toHaveText(RESUME);
  });

  test('a pause until resumed says so', async ({ page }) => {
    await open(page, during({ pauseduntil: '0', pauseheld: '1' }));
    await expect(note(page)).toHaveText('All alerts are paused until you resume · 1 held. Resume: ' + RESUME);
  });

  test('with nothing held yet it says so', async ({ page }) => {
    await open(page, during({ pauseduntil: '0', pauseheld: '0' }));
    await expect(note(page)).toHaveText('All alerts are paused until you resume · none held yet. Resume: ' + RESUME);
  });

  test('a pause that ends tomorrow says tomorrow', async ({ page }) => {
    await at(page, '2026-09-24T23:00:00-04:00');
    await open(page, during({ pauseduntil: epoch('2026-09-25T08:00:00-04:00') }));
    await expect(note(page)).toHaveText(/^All alerts are paused until 8:00\sAM tomorrow · 3 held\./);
  });

  test('a pause a month out names the date', async ({ page }) => {
    await at(page, '2026-09-24T14:00:00-04:00');
    await open(page, during({ pauseduntil: epoch('2026-10-24T14:00:00-04:00') }));
    await expect(note(page)).toHaveText(/^All alerts are paused until 2:00\sPM on Oct 24 · 3 held\./);
  });

  test('without a resume command the note ends at the count', async ({ page }) => {
    await open(page, during({ pauseduntil: '0', pauseresumeb64: null }));
    await expect(note(page)).toHaveText('All alerts are paused until you resume · 3 held');
    await expect(note(page).locator('code')).toHaveCount(0);
  });

  test('an unreadable end or count still says a pause is on', async ({ page }) => {
    await open(page, during({ pauseduntil: 'soon', pauseheld: 'many', pauseresumeb64: null }));
    await expect(note(page)).toHaveText('All alerts are paused');
  });

  test('the command is text, not markup', async ({ page }) => {
    await open(page, during({ pauseduntil: '0', pauseresumeb64: b64url('<b>x</b>') }));
    await expect(note(page).locator('code')).toHaveText('<b>x</b>');
    await expect(page.locator('#app b')).toHaveCount(0);
  });

  test('the note sits above the hint, can be selected, and a click on it is not a dismiss', async ({ page }) => {
    await open(page, during({ pauseduntil: '0' }));
    expect(await note(page).evaluate((el) => el.nextElementSibling.id)).toBe('dismissHint');
    expect(await note(page).evaluate((el) => getComputedStyle(el).userSelect)).toBe('text');
    await note(page).click();
    expect(await signals(page)).toEqual([]);
    expect(await closed(page)).toBe(false);
  });

  // Selecting the command often runs past its last character, and the click
  // that ends the drag then lands on the common ancestor, not on the note.
  test('a drag that starts in the note and ends outside it selects, and is not a dismiss', async ({ page }) => {
    await open(page, during({ pauseduntil: '0' }));
    const box = await note(page).locator('code').boundingBox();
    const y = box.y + box.height / 2;
    await page.mouse.move(box.x + 1, y);
    await page.mouse.down();
    await page.mouse.move(box.x + box.width + 15, y, { steps: 5 });
    await page.mouse.up();
    expect(await page.evaluate(() => String(getSelection()))).toBe(RESUME);
    expect(await signals(page)).toEqual([]);
    expect(await closed(page)).toBe(false);
    // The next plain click still dismisses.
    await page.mouse.click(10, 10);
    expect(await signals(page)).toEqual(['dismiss']);
  });

  test('a normal alert has no note', async ({ page }) => {
    await open(page);
    await expect(note(page)).toHaveCount(0);
  });
});

// --- layout ------------------------------------------------------------------------
// The accordion keeps the page no taller than a pinned snooze row plus the grey
// row, so a full Claude alert still fits the window of a 13" laptop.

test.describe('layout at 1280x775', () => {
  test.use({ viewport: { width: 1280, height: 775 } });
  const full = {
    cmd: 'fix the flaky snooze test', repob64: b64url('ada'), snoozemins: '5,10,30,60',
    snoozescope: 'session', mute: '1', mutekindb64: b64url('conversation'),
    focus: '1', focusnameb64: b64url('Claude'),
  };
  const inside = async (page) => {
    const box = await page.locator('#app').boundingBox();
    expect(box.y).toBeGreaterThanOrEqual(0);
    expect(box.y + box.height).toBeLessThanOrEqual(775);
  };

  test('folded', async ({ page }) => {
    await open(page, full);
    await inside(page);
  });

  test('with the snooze row pinned open', async ({ page }) => {
    await open(page, full, { snoozePinned: true });
    await inside(page);
  });

  test('with the pause row open', async ({ page }) => {
    await open(page, full, { snoozePinned: true });
    await pauseToggle(page).click();
    await pausePill(page, 'Custom').click();
    await inside(page);
  });
});
