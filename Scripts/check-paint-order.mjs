#!/usr/bin/env node
// Checks that rendered StaticHTMLBackend markup paints text above the
// backdrops behind it, by hit-testing the real browser's paint order rather
// than inspecting geometry.
//
// Geometry checks can't see this class of bug: a .background() backdrop that
// covers its foreground has exactly the box it is supposed to have, and every
// computed style is correct — only elementFromPoint reveals that the backdrop
// is the element a reader (and a screenshot) actually finds at that point.
//
// Usage: node Scripts/check-paint-order.mjs <file.html|url> [more...]
//
// Exits 1 if any text element is covered, 2 on usage error, and 0 (with a
// SKIP notice) when the driver isn't installed, so CI without a browser
// doesn't fail closed.
//
// Driver: the `agent-browser` CLI, which ships its own headless Chromium.
// Install with `npm i -g agent-browser`.

import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { promisify } from "node:util";

const run = promisify(execFile);

// Returns one record per text element: what sits at its center point, and
// whether that is the element itself (or a descendant of it).
// elementFromPoint is viewport-relative and returns null for coordinates
// outside it, so each element is scrolled into view before being hit-tested —
// otherwise every element below the fold reads as a failure. A null hit that
// survives scrolling is reported as unresolved rather than covered: the two
// mean different things, and only a hit on a *different* element is the
// paint-order bug this checks for.
const PROBE = `(() => {
    const results = [];
    for (const el of document.querySelectorAll('[data-scui="Text"]')) {
        if (el.getBoundingClientRect().height === 0) continue;
        el.scrollIntoView({ block: "center", inline: "center" });
        const r = el.getBoundingClientRect();
        if (r.width === 0 || r.height === 0) continue;
        const x = r.left + r.width / 2;
        const y = r.top + r.height / 2;
        const onscreen =
            x >= 0 && y >= 0 && x < window.innerWidth && y < window.innerHeight;
        const hit = onscreen ? document.elementFromPoint(x, y) : null;
        results.push({
            text: (el.textContent || "").trim().slice(0, 40),
            point: [Math.round(x), Math.round(y)],
            hit: hit ? hit.tagName + (hit.dataset.scui ? "[" + hit.dataset.scui + "]" : "") : null,
            covered: hit !== null && !(hit === el || el.contains(hit)),
            unresolved: hit === null,
        });
    }
    return JSON.stringify(results);
})()`;

async function browser(...args) {
    const { stdout } = await run("agent-browser", args, { maxBuffer: 32 * 1024 * 1024 });
    return stdout;
}

const targets = process.argv.slice(2);
if (targets.length === 0) {
    console.error("usage: check-paint-order.mjs <file.html|url> [more...]");
    process.exit(2);
}

try {
    await run("agent-browser", ["--version"]);
} catch {
    console.error("agent-browser is not installed; skipping paint-order check.");
    process.exit(0);
}

let failures = 0;
for (const target of targets) {
    const isRemote = /^https?:/.test(target);
    if (!isRemote && !existsSync(target)) {
        console.error(`MISSING ${target}`);
        failures += 1;
        continue;
    }

    const url = isRemote ? target : pathToFileURL(target).href;
    await browser("open", url);

    // An empty result is ambiguous: the page may genuinely have no text, or
    // `eval` may have reached the previous document because navigation hadn't
    // settled — which silently reports a covering regression as a pass. Only
    // an empty result observed on the page whose URL is the requested one,
    // and still empty on a retry, counts as genuinely text-free.
    let results = [];
    for (let attempt = 0; attempt < 5; attempt += 1) {
        const landed = (await browser("get", "url")).trim().replace(/^"|"$/g, "");
        if (landed === url || decodeURI(landed) === decodeURI(url)) {
            // `eval` prints the returned value as a JSON string literal, so
            // the payload needs unwrapping before it parses as the array.
            const trimmed = (await browser("eval", PROBE)).trim();
            results = JSON.parse(trimmed.startsWith('"') ? JSON.parse(trimmed) : trimmed);
            if (results.length > 0) break;
        }
        await new Promise((resolve) => setTimeout(resolve, 200));
    }

    const covered = results.filter((r) => r.covered);
    const unresolved = results.filter((r) => r.unresolved);
    if (results.length === 0) {
        console.log(`SKIP  ${target} (no [data-scui="Text"] elements)`);
    } else if (covered.length === 0) {
        const note = unresolved.length > 0 ? `, ${unresolved.length} unresolved` : "";
        console.log(`OK    ${target} (${results.length} text elements on top${note})`);
        for (const u of unresolved) {
            console.log(`        note: "${u.text}" at ${u.point.join(",")} hit nothing`);
        }
    } else {
        failures += covered.length;
        console.error(`FAIL  ${target}`);
        for (const c of covered) {
            console.error(`        "${c.text}" at ${c.point.join(",")} is covered by ${c.hit}`);
        }
    }
}

await browser("close").catch(() => {});
process.exit(failures > 0 ? 1 : 0);
