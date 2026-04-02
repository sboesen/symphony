import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";

import { chromium } from "playwright";

const MANIFEST_VERSION = 2;

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

function normalizeOptionalValue(value) {
  if (value === undefined || value === null) {
    return null;
  }

  const normalized = `${value}`.trim();

  if (
    normalized === "" ||
    ["null", "undefined", "false"].includes(normalized.toLowerCase())
  ) {
    return null;
  }

  return normalized;
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

async function loadPlan(planFile) {
  if (!planFile) {
    return null;
  }

  const raw = await fs.readFile(path.resolve(planFile), "utf8");
  const parsed = JSON.parse(raw);

  if (!parsed || typeof parsed !== "object") {
    throw new Error("demo plan must be a JSON object");
  }

  return parsed;
}

function isLoopbackHost(hostname) {
  const value = `${hostname || ""}`.trim().toLowerCase();
  return value === "127.0.0.1" || value === "localhost" || value === "::1";
}

function resolveSourceUrl(planUrl, fallbackUrl) {
  const fallback = `${fallbackUrl || ""}`.trim();
  const candidate = `${planUrl || ""}`.trim();

  if (!candidate) {
    return fallback;
  }

  try {
    const resolved = new URL(candidate, fallback);

    if (fallback) {
      const fallbackUrlObject = new URL(fallback);
      if (isLoopbackHost(resolved.hostname) && isLoopbackHost(fallbackUrlObject.hostname)) {
        return new URL(
          `${resolved.pathname || "/"}${resolved.search || ""}${resolved.hash || ""}`,
          fallbackUrlObject
        ).toString();
      }
    }

    return resolved.toString();
  } catch {
    return candidate;
  }
}

function normalizeVerificationResult(type, details = {}) {
  return { type, passed: false, ...details };
}

async function writeManifest(manifestPath, manifest) {
  await fs.writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
}

async function safeScreenshot(page, outputPath) {
  try {
    await page.screenshot({ path: outputPath, fullPage: false });
    return outputPath;
  } catch {
    return null;
  }
}

async function waitForPageState(page, args) {
  const waitForSelector = normalizeOptionalValue(args["wait-for-selector"]);
  const waitForText = normalizeOptionalValue(args["wait-for-text"]);

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

async function runPlan(page, plan, baseUrl) {
  const steps = Array.isArray(plan?.steps) ? plan.steps : [];

  for (const step of steps) {
    if (!step || typeof step !== "object") {
      continue;
    }

    const action = `${step.action || ""}`.trim().toLowerCase();

    switch (action) {
      case "goto": {
        const target = resolveSourceUrl(step.url, baseUrl);
        if (!target) {
          throw new Error("demo plan goto step requires url");
        }
        await page.goto(target, { waitUntil: "load", timeout: 30_000 });
        break;
      }

      case "click": {
        const selector = `${step.selector || ""}`.trim();
        if (!selector) {
          throw new Error("demo plan click step requires selector");
        }
        await page.locator(selector).click({ timeout: 15_000 });
        break;
      }

      case "type": {
        const selector = `${step.selector || ""}`.trim();
        if (!selector) {
          throw new Error("demo plan type step requires selector");
        }
        await page.locator(selector).fill(`${step.text || ""}`, { timeout: 15_000 });
        if (step.submitKey) {
          await page.keyboard.press(`${step.submitKey}`);
        }
        break;
      }

      case "press": {
        const key = `${step.key || ""}`.trim();
        if (!key) {
          throw new Error("demo plan press step requires key");
        }
        await page.keyboard.press(key);
        break;
      }

      case "wait": {
        const ms = parseInteger(step.ms, 1000);
        await page.waitForTimeout(ms);
        break;
      }

      case "wait_for_text": {
        const text = `${step.text || ""}`.trim();
        if (!text) {
          throw new Error("demo plan wait_for_text step requires text");
        }
        await page.waitForFunction(
          (needle) => document.body && document.body.innerText.includes(needle),
          text,
          { timeout: parseInteger(step.timeoutMs, 15_000) }
        );
        break;
      }

      case "wait_for_selector": {
        const selector = `${step.selector || ""}`.trim();
        if (!selector) {
          throw new Error("demo plan wait_for_selector step requires selector");
        }
        await page.locator(selector).waitFor({
          state: "visible",
          timeout: parseInteger(step.timeoutMs, 15_000)
        });
        break;
      }

      case "scroll": {
        const x = Number.isFinite(Number(step.x)) ? Number(step.x) : 0;
        const y = Number.isFinite(Number(step.y)) ? Number(step.y) : 600;
        const behavior = `${step.behavior || "smooth"}`;
        await page.evaluate(
          ({ scrollX, scrollY, scrollBehavior }) => {
            window.scrollBy({ left: scrollX, top: scrollY, behavior: scrollBehavior });
          },
          { scrollX: x, scrollY: y, scrollBehavior: behavior }
        );
        break;
      }

      case "scroll_to_selector": {
        const selector = `${step.selector || ""}`.trim();
        if (!selector) {
          throw new Error("demo plan scroll_to_selector step requires selector");
        }
        await page.locator(selector).scrollIntoViewIfNeeded({ timeout: 15_000 });
        if (`${step.behavior || "smooth"}` === "smooth") {
          await page.waitForTimeout(750);
        }
        break;
      }

      default:
        throw new Error(`unsupported demo plan action: ${action || "<empty>"}`);
    }
  }
}

async function verifyAssertions(page, plan) {
  const assertions = Array.isArray(plan?.assertions) ? plan.assertions : [];
  const results = [];
  const consoleErrors = Array.isArray(plan?.console_errors) ? plan.console_errors : [];

  for (const assertion of assertions) {
    if (!assertion || typeof assertion !== "object") {
      continue;
    }

    const type = `${assertion.type || ""}`.trim().toLowerCase();

    switch (type) {
      case "text_present": {
        const value = `${assertion.value || assertion.text || ""}`.trim();
        if (!value) {
          throw new Error("demo plan text_present assertion requires value");
        }
        const passed = await page.evaluate(
          (needle) => Boolean(document.body && document.body.innerText.includes(needle)),
          value
        );
        results.push({ type, value, passed });
        break;
      }

      case "selector_visible": {
        const selector = `${assertion.selector || ""}`.trim();
        if (!selector) {
          throw new Error("demo plan selector_visible assertion requires selector");
        }
        const passed = await page.locator(selector).isVisible().catch(() => false);
        results.push({ type, selector, passed });
        break;
      }

      case "selector_hidden": {
        const selector = `${assertion.selector || ""}`.trim();
        if (!selector) {
          throw new Error("demo plan selector_hidden assertion requires selector");
        }
        const passed = !(await page.locator(selector).isVisible().catch(() => false));
        results.push({ type, selector, passed });
        break;
      }

      case "url_includes": {
        const value = `${assertion.value || ""}`.trim();
        if (!value) {
          throw new Error("demo plan url_includes assertion requires value");
        }
        const passed = page.url().includes(value);
        results.push({ type, value, passed, actual_url: page.url() });
        break;
      }

      case "title_includes": {
        const value = `${assertion.value || ""}`.trim();
        if (!value) {
          throw new Error("demo plan title_includes assertion requires value");
        }
        const actual = await page.title();
        const passed = actual.includes(value);
        results.push({ type, value, passed, actual });
        break;
      }

      case "selector_text_equals": {
        const selector = `${assertion.selector || ""}`.trim();
        const value = `${assertion.value || assertion.text || ""}`.trim();
        if (!selector || !value) {
          throw new Error("demo plan selector_text_equals assertion requires selector and value");
        }
        const actual = await page.locator(selector).textContent().catch(() => null);
        const normalizedActual = (actual || "").trim();
        const passed = normalizedActual === value;
        results.push({ type, selector, value, passed, actual: normalizedActual });
        break;
      }

      case "attribute_equals": {
        const selector = `${assertion.selector || ""}`.trim();
        const attribute = `${assertion.attribute || ""}`.trim();
        const value = `${assertion.value || ""}`.trim();
        if (!selector || !attribute || !value) {
          throw new Error("demo plan attribute_equals assertion requires selector, attribute, and value");
        }
        const actual = await page.locator(selector).getAttribute(attribute).catch(() => null);
        const passed = actual === value;
        results.push({ type, selector, attribute, value, passed, actual });
        break;
      }

      case "selector_count_at_least": {
        const selector = `${assertion.selector || ""}`.trim();
        const value = Number.parseInt(`${assertion.value ?? assertion.count ?? ""}`, 10);
        if (!selector || !Number.isFinite(value)) {
          throw new Error("demo plan selector_count_at_least assertion requires selector and count");
        }
        const actual = await page.locator(selector).count().catch(() => 0);
        const passed = actual >= value;
        results.push({ type, selector, value, passed, actual });
        break;
      }

      case "text_absent": {
        const value = `${assertion.value || assertion.text || ""}`.trim();
        if (!value) {
          throw new Error("demo plan text_absent assertion requires value");
        }
        const present = await page.evaluate(
          (needle) => Boolean(document.body && document.body.innerText.includes(needle)),
          value
        );
        results.push({ type, value, passed: !present, actual_present: present });
        break;
      }

      case "console_errors_absent": {
        results.push({
          type,
          passed: consoleErrors.length === 0,
          actual_count: consoleErrors.length,
          console_errors: consoleErrors
        });
        break;
      }

      default:
        throw new Error(`unsupported demo plan assertion: ${type || "<empty>"}`);
    }
  }

  const passed = results.every((result) => result.passed === true);
  return { passed, results };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const fallbackUrl = requireArg(args, "url");
  const planFile = args["plan-file"];
  const plan = await loadPlan(planFile);
  const captureType = `${plan?.capture || "video"}`.trim().toLowerCase() === "screenshot"
    ? "screenshot"
    : "video";
  const sourceUrl = resolveSourceUrl(plan?.url, fallbackUrl);
  const outputDir = path.resolve(requireArg(args, "output-dir"));
  const settleMs = parseInteger(plan?.settle_ms ?? args["settle-ms"], 2_000);
  const width = parseInteger(args.width, 1440);
  const height = parseInteger(args.height, 900);
  const traceEnabled = parseBoolean(args.trace, true);
  const manifestPath = path.join(outputDir, "manifest.json");
  const posterPath = path.join(outputDir, "poster.png");
  const finalVideoPath = path.join(outputDir, "recording.mp4");
  const finalTracePath = path.join(outputDir, "trace.zip");
  const verificationPath = path.join(outputDir, "verification.json");
  const failureScreenshotPath = path.join(outputDir, "failure.png");

  await ensureDir(outputDir);

  const browser = await chromium.launch({ headless: true });
  const contextOptions = {
    viewport: { width, height }
  };

  if (captureType === "video") {
    contextOptions.recordVideo = {
      dir: outputDir,
      size: { width, height }
    };
  }

  const context = await browser.newContext(contextOptions);

  const page = await context.newPage();
  const video = captureType === "video" ? page.video() : null;
  const consoleErrors = [];
  page.on("console", (message) => {
    if (message.type() === "error") {
      consoleErrors.push(message.text());
    }
  });
  page.on("pageerror", (error) => {
    consoleErrors.push(error.message);
  });

  let verification = { passed: true, results: [] };
  let status = "ready";
  let errorMessage = null;
  let finalPageUrl = null;
  let screenshotPath = posterPath;

  try {
    if (traceEnabled) {
      await context.tracing.start({ screenshots: true, snapshots: true });
    }

    if (plan?.non_demoable === true) {
      status = "skipped";
    } else {
      const preCaptureWaitArgs = captureType === "screenshot"
        ? {
            "wait-for-selector": plan?.wait_for_selector,
            "wait-for-text": plan?.wait_for_text
          }
        : {
            "wait-for-selector": plan?.wait_for_selector ?? args["wait-for-selector"],
            "wait-for-text": plan?.wait_for_text ?? args["wait-for-text"]
          };

      await page.goto(sourceUrl, { waitUntil: "load", timeout: 30_000 });
      await waitForPageState(page, preCaptureWaitArgs);
      await runPlan(page, plan, sourceUrl);
      finalPageUrl = page.url();
      if (captureType === "video") {
        verification = await verifyAssertions(page, {
          ...(plan || {}),
          console_errors: consoleErrors
        });
        await fs.writeFile(`${verificationPath}`, `${JSON.stringify(verification, null, 2)}\n`, "utf8");
        if (!verification.passed) {
          throw new Error(`demo plan assertions failed: ${JSON.stringify(verification.results)}`);
        }
      }
      await page.waitForTimeout(settleMs);
      await page.screenshot({ path: screenshotPath });
    }
  } catch (error) {
    status = "error";
    errorMessage = error.stack || error.message;
    finalPageUrl = page.url().trim() || finalPageUrl;
    screenshotPath = (await safeScreenshot(page, failureScreenshotPath)) || screenshotPath;
  } finally {
    if (traceEnabled) {
      await context.tracing.stop({ path: finalTracePath }).catch(() => {});
    }
    await context.close();
    await browser.close();
  }

  let rawVideoPath = null;
  let finalVideo = null;
  try {
    if (status !== "skipped" && captureType === "video" && video) {
      rawVideoPath = await video.path();
      await transcodeToMp4(rawVideoPath, finalVideoPath);
      finalVideo = finalVideoPath;
    }
  } catch (error) {
    status = "error";
    errorMessage = errorMessage || error.stack || error.message;
  }

  const manifest = {
    manifest_version: MANIFEST_VERSION,
    capture_type: captureType,
    status,
    source_url: sourceUrl,
    output_dir: outputDir,
    video_path: finalVideo,
    raw_video_path: rawVideoPath,
    trace_path: traceEnabled ? finalTracePath : null,
    screenshot_path: screenshotPath,
    verification_path: verification.results.length > 0 ? verificationPath : null,
    demo_plan_path: planFile ? path.resolve(planFile) : null,
    assertions: captureType === "video" && Array.isArray(plan?.assertions) ? plan.assertions : [],
    verification,
    current_url: status === "skipped" ? null : finalPageUrl || sourceUrl,
    console_errors: consoleErrors,
    non_demoable: plan?.non_demoable === true,
    non_demoable_reason: plan?.non_demoable === true ? `${plan?.reason || ""}`.trim() : null,
    error: errorMessage,
    captured_at: new Date().toISOString()
  };

  await writeManifest(manifestPath, manifest);
  process.stdout.write(`${JSON.stringify(manifest)}\n`);

  if (status === "error") {
    process.stderr.write(`${errorMessage || "demo recording failed"}\n`);
    process.exit(1);
  }
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exit(1);
});
