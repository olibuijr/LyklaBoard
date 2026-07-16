/**
 * Headless visual check: serves ./dist, screenshots the hero in several states.
 * Usage: node scripts/screenshot.mjs [outdir]
 */
import http from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join } from "node:path";
import puppeteer from "puppeteer-core";

const DIST = new URL("../dist/", import.meta.url).pathname;
const OUT = process.argv[2] || new URL("./shots/", import.meta.url).pathname;
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

const MIME = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".css": "text/css",
  ".png": "image/png",
  ".glb": "model/gltf-binary",
  ".webp": "image/webp",
  ".svg": "image/svg+xml",
};

const server = http.createServer(async (req, res) => {
  let path = req.url.split("?")[0];
  if (path.endsWith("/")) path += "index.html";
  try {
    const data = await readFile(join(DIST, path));
    res.writeHead(200, { "content-type": MIME[extname(path)] || "application/octet-stream" });
    res.end(data);
  } catch {
    res.writeHead(404);
    res.end("not found");
  }
});
await new Promise((resolve) => server.listen(4177, resolve));

const browser = await puppeteer.launch({
  executablePath: CHROME,
  headless: true,
  args: ["--hide-scrollbars", "--force-device-scale-factor=2"],
});

async function shot(name, { dark = false, press = false, fullPage = false, width = 1280, height = 900 } = {}) {
  const page = await browser.newPage();
  await page.setViewport({ width, height, deviceScaleFactor: 2 });
  await page.emulateMediaFeatures([
    { name: "prefers-color-scheme", value: dark ? "dark" : "light" },
  ]);
  await page.goto("http://localhost:4177/", { waitUntil: "networkidle0" });
  // wait for the GLB to be loaded + a few frames rendered
  await page.waitForFunction(() => !document.getElementById("hero-hint").hidden, { timeout: 15000 })
    .catch(() => console.warn(`${name}: hero never became ready (fallback shown?)`));
  await new Promise((r) => setTimeout(r, 600));
  if (press) {
    await page.evaluate(() => {
      const canvas = document.querySelector(".hero-canvas");
      const rect = canvas.getBoundingClientRect();
      canvas.dispatchEvent(
        new PointerEvent("pointerdown", {
          clientX: rect.left + rect.width * 0.55,
          clientY: rect.top + rect.height * 0.5,
          bubbles: true,
          pointerId: 1,
        })
      );
    });
    await new Promise((r) => setTimeout(r, 350)); // settle at bottom
  }
  if (fullPage) {
    await page.screenshot({ path: join(OUT, `${name}.png`), fullPage: true });
  } else {
    const stage = await page.$("#hero-stage");
    const box = await stage.boundingBox();
    await page.screenshot({
      path: join(OUT, `${name}.png`),
      clip: { x: 0, y: 0, width, height: Math.min(height, box.y + box.height + 60) },
    });
  }
  const errors = await page.evaluate(() => window.__errors || []);
  if (errors.length) console.log(`${name} console errors:`, errors);
  await page.close();
  console.log(`shot: ${name}`);
}

import { mkdir } from "node:fs/promises";
await mkdir(OUT, { recursive: true });

await shot("hero-light");
await shot("hero-light-pressed", { press: true });
await shot("hero-dark", { dark: true });
await shot("hero-dark-pressed", { dark: true, press: true });
await shot("page-light-full", { fullPage: true });
await shot("page-dark-full", { dark: true, fullPage: true });
await shot("hero-mobile", { width: 390, height: 844 });

await browser.close();
server.close();
