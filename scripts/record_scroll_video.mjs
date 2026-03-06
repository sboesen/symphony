import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";

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

function runCommand(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      stdio: ["ignore", "pipe", "pipe"],
      ...options
    });

    let stdout = "";
    let stderr = "";

    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });

    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });

    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) {
        resolve({ stdout, stderr });
      } else {
        reject(new Error(`${command} exited with ${code}: ${stderr || stdout}`));
      }
    });
  });
}

async function transcodeToMp4(inputPath, outputPath) {
  await runCommand("ffmpeg", [
    "-y",
    "-i",
    inputPath,
    "-vf",
    "format=yuv420p",
    "-movflags",
    "+faststart",
    "-an",
    outputPath
  ]);
}

async function recordScrollVideo({
  url,
  outputPath,
  width,
  height,
  durationMs,
  fps,
  settleMs
}) {
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), "sbo-scroll-"));
  const rawVideoDir = path.join(tempRoot, "video");
  await ensureDir(rawVideoDir);

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: { width, height },
    recordVideo: {
      dir: rawVideoDir,
      size: { width, height }
    }
  });

  const page = await context.newPage();
  const video = page.video();

  try {
    await page.goto(url, { waitUntil: "networkidle", timeout: 45_000 });
    await page.waitForTimeout(settleMs);

    const maxScroll = await page.evaluate(() => {
      return Math.max(
        0,
        document.documentElement.scrollHeight - window.innerHeight,
        document.body ? document.body.scrollHeight - window.innerHeight : 0
      );
    });

    const stepMs = Math.max(40, Math.round(1000 / fps));
    const steps = Math.max(1, Math.floor(durationMs / stepMs));

    await page.evaluate(() => window.scrollTo({ top: 0, behavior: "instant" }));

    for (let step = 0; step <= steps; step += 1) {
      const progress = step / steps;
      const position = Math.round(maxScroll * progress);
      await page.evaluate((top) => {
        window.scrollTo({ top, behavior: "instant" });
      }, position);
      await page.waitForTimeout(stepMs);
    }

    await page.waitForTimeout(500);
  } finally {
    await context.close();
    await browser.close();
  }

  const rawVideoPath = await video.path();
  await ensureDir(path.dirname(outputPath));
  await transcodeToMp4(rawVideoPath, outputPath);
  await fs.rm(tempRoot, { recursive: true, force: true });
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const url = requireArg(args, "url");
  const outputPath = path.resolve(requireArg(args, "output"));
  const width = parseInteger(args.width, 1440);
  const height = parseInteger(args.height, 900);
  const durationMs = parseInteger(args.duration, 10_000);
  const fps = parseInteger(args.fps, 30);
  const settleMs = parseInteger(args["settle-ms"], 1500);

  await recordScrollVideo({
    url,
    outputPath,
    width,
    height,
    durationMs,
    fps,
    settleMs
  });

  process.stdout.write(`${outputPath}\n`);
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exit(1);
});
