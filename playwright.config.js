const { defineConfig, devices } = require('@playwright/test');

// The alert is a static file:// page rendered by the native WebKit helper, so
// the tests load alert.html directly off disk — no dev server needed.
module.exports = defineConfig({
  testDir: './test',
  testMatch: '**/*.spec.js',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  reporter: process.env.CI ? 'github' : 'list',
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
  ],
});
