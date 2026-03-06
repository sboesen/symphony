import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";

import { chromium } from "playwright";

function parseArgs(argv) {
  const args = {};

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (!token.startsWith("--")) {
      continue;
    }

    const key = token.slice(2);
    const value = argv[index + 1];

    if (value === undefined || value.startsWith("--")) {
      args[key] = "true";
    } else {
      args[key] = value;
      index += 1;
    }
  }

  return args;
}

function requireArg(args, key) {
  const value = args[key];

  if (!value || `${value}`.trim() === "") {
    throw new Error(`missing required --${key}`);
  }

  return `${value}`.trim();
}

function parseBoolean(value, fallback) {
  if (value === undefined) {
    return fallback;
  }

  const normalized = `${value}`.trim().toLowerCase();

  if (["1", "true", "yes"].includes(normalized)) {
    return true;
  }

  if (["0", "false", "no"].includes(normalized)) {
    return false;
  }

  return fallback;
}

function parseInteger(value, fallback) {
  if (value === undefined) {
    return fallback;
  }

  const parsed = Number.parseInt(`${value}`, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

async function ensureDir(dirPath) {
  await fs.mkdir(dirPath, { recursive: true });
}

async function waitForPageState(page, args) {
  const waitForSelector = args["wait-for-selector"];
  const waitForText = args["wait-for-text"];

  if (waitForSelector) {
    await page.locator(waitForSelector).waitFor({ state: "visible", timeout: 15_000 });
  }

  if (waitForText) {
    await page.waitForFunction(
      (needle) => document.body && document.body.innerText.includes(needle),
      waitForText,
      { timeout: 15_000 }
    );
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const sourceUrl = requireArg(args, "url");
  const outputDir = path.resolve(requireArg(args, "output-dir"));
  const settleMs = parseInteger(args["settle-ms"], 2_000);
  const width = parseInteger(args.width, 1440);
  const height = parseInteger(args.height, 900);
  const traceEnabled = parseBoolean(args.trace, true);
  const manifestPath = path.join(outputDir, "manifest.json");
  const screenshotPath = path.join(outputDir, "poster.png");
  const finalVideoPath = path.join(outputDir, "recording.webm");
  const finalTracePath = path.join(outputDir, "trace.zip");

  await ensureDir(outputDir);

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: { width, height },
    recordVideo: {
      dir: outputDir,
      size: { width, height }
    }
  });

  const page = await context.newPage();
  const video = page.video();

  try {
    if (traceEnabled) {
      await context.tracing.start({ screenshots: true, snapshots: true });
    }

    await page.goto(sourceUrl, { waitUntil: "load", timeout: 30_000 });
    await waitForPageState(page, args);
    await page.waitForTimeout(settleMs);
    await page.screenshot({ path: screenshotPath });

    if (traceEnabled) {
      await context.tracing.stop({ path: finalTracePath });
    }
  } finally {
    await context.close();
    await browser.close();
  }

  const rawVideoPath = await video.path();
  await fs.rename(rawVideoPath, finalVideoPath);

  const manifest = {
    source_url: sourceUrl,
    output_dir: outputDir,
    video_path: finalVideoPath,
    trace_path: traceEnabled ? finalTracePath : null,
    screenshot_path: screenshotPath,
    captured_at: new Date().toISOString()
  };

  await fs.writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  process.stdout.write(`${JSON.stringify(manifest)}\n`);
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exit(1);
});
