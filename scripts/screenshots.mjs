// Takes the README screenshots (light + dark) of a running `mix butler.demo`.
// Run through scripts/screenshots.sh, which installs playwright-core in
// PLAYWRIGHT_DIR and starts the demo server (BASE_URL). Needs a Chromium.
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const { chromium } = createRequire(`${process.env.PLAYWRIGHT_DIR}/`)("playwright-core");

const base = process.env.BASE_URL;
const chrome = process.env.CHROMIUM_PATH ?? "/usr/bin/chromium";
const outDir = fileURLToPath(new URL("../docs/screenshots/", import.meta.url));

// [file name, path, viewport height]. The job detail is resolved from the list.
const pages = [
  ["daemon", "/daemon", 900],
  ["jobs", "/jobs", 1100],
  ["job-detail", null, 1100],
  ["launch", "/launch", 1500],
  ["maintenance", "/maintenance", 800],
];

const browser = await chromium.launch({ executablePath: chrome, args: ["--no-sandbox"] });

async function jobDetailPath() {
  const page = await browser.newPage();
  await page.goto(`${base}/jobs`);
  await page.waitForSelector(".phx-connected");
  // A succeeded `mine` job of the demo queue ("atlas" has a mine report).
  const href = await page
    .locator("tr", { hasText: "/demo/projects/atlas" })
    .locator("a[href^='/jobs/']")
    .first()
    .getAttribute("href");
  await page.close();
  return href;
}

const detailPath = await jobDetailPath();

for (const theme of ["light", "dark"]) {
  for (const [name, path, height] of pages) {
    const context = await browser.newContext({ viewport: { width: 1400, height } });
    await context.addInitScript((t) => localStorage.setItem("phx:theme", t), theme);
    const page = await context.newPage();
    await page.goto(base + (path ?? detailPath));
    await page.waitForSelector(".phx-connected");
    await page.waitForTimeout(800); // let transitions settle
    await page.screenshot({ path: `${outDir}${name}-${theme}.png` });
    await context.close();
    console.log(`${name}-${theme}.png`);
  }
}

await browser.close();
