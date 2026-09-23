// Opt-in V8 coverage for alert.html's inline script, shared by the page specs.
//
// `./run-tests.sh --coverage` sets ADA_COV_JS_DIR; each test then writes the
// coverage entries for the page's own script (not Playwright's, not the bridge
// stub) to one JSON file, and test/coverage/report.py maps them back onto
// alert.html's line numbers. Chromium-only, which is the one project in
// playwright.config.js. Without the variable this registers nothing.
const fs = require('fs');
const path = require('path');

function recordCoverage(test, alertFileURL) {
  const dir = process.env.ADA_COV_JS_DIR;
  if (!dir) return;
  test.beforeEach(async ({ page }) => {
    await page.coverage.startJSCoverage({ resetOnNavigation: false });
  });
  test.afterEach(async ({ page }, info) => {
    const entries = await page.coverage.stopJSCoverage();
    const pageScripts = entries.filter((e) => e.url.startsWith(alertFileURL));
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, `${info.testId}.json`), JSON.stringify(pageScripts));
  });
}

module.exports = { recordCoverage };
