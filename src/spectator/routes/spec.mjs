import {
  KEY_AUTODIRECTOR_OFF,
  KEY_SPEC_JUMP,
  KEY_SPEC_NEXT,
  KEY_SPEC_PREV,
  KEY_XRAY_TOGGLE,
  SLOT_KEYS,
} from "../constants.mjs";
import { existsSync, writeFileSync } from "node:fs";
import path from "node:path";
import { DISPLAY, HUD_HOST, HUD_PORT, LOG_DIR } from "../env.mjs";
import { execCfgCommand } from "../cs2/exec-cfg.mjs";
import { findCs2Window } from "../cs2/window.mjs";
import { sendKey, focusState } from "../cs2/input.mjs";
import { loadPlayerBindings } from "../state/bindings.mjs";
import { run } from "../util/run.mjs";
import { sendJson } from "../util/http.mjs";
import { directorState, startDirector, stopDirector } from "../director/index.mjs";
import { gsiState } from "../state/gsi.mjs";

function takeManualControl() {
  directorState.bootstrapped = true;
  if (directorState.enabled) stopDirector();
}

export async function clickHandler(_req, res, body) {
  takeManualControl();
  const key = body.button === "right" ? KEY_SPEC_PREV : KEY_SPEC_NEXT;
  const ok = await sendKey(key);
  sendJson(res, ok ? 200 : 503, ok ? { ok, key } : { error: "cs2 not running" });
}

export async function jumpHandler(_req, res) {
  takeManualControl();
  const ok = await sendKey(KEY_SPEC_JUMP);
  sendJson(res, ok ? 200 : 503, ok ? { ok, key: KEY_SPEC_JUMP } : { error: "cs2 not running" });
}

export async function playerHandler(_req, res, body) {
  const aidInt = Number.parseInt(body.accountid, 10);
  if (!Number.isFinite(aidInt)) {
    sendJson(res, 400, { error: "accountid (int) required" });
    return;
  }
  const key = loadPlayerBindings()[String(aidInt)];
  if (!key) {
    sendJson(res, 404, { error: `no key bound for accountid ${aidInt}` });
    return;
  }
  takeManualControl();
  const ok = await sendKey(key);
  sendJson(res, ok ? 200 : 503, { ok, accountid: aidInt, key });
}

export async function slotHandler(_req, res, body) {
  const slotInt = Number.parseInt(body.slot, 10);
  if (!Number.isFinite(slotInt) || slotInt < 1 || slotInt > 12) {
    sendJson(res, 400, { error: "slot (int 1..12) required" });
    return;
  }
  takeManualControl();
  const key = SLOT_KEYS[slotInt - 1];
  const ok = await sendKey(key);
  sendJson(res, ok ? 200 : 503, ok ? { ok, slot: slotInt, key } : { error: "cs2 not running" });
}

export async function autodirectorHandler(_req, res, body) {
  const enabled = Boolean(body.enabled);
  directorState.bootstrapped = true;
  if (!enabled) {
    stopDirector();
    const ok = await sendKey(KEY_AUTODIRECTOR_OFF);
    sendJson(res, ok ? 200 : 503, ok ? { ok, enabled: false } : { error: "cs2 not running" });
    return;
  }
  if ((await findCs2Window()) === null) {
    sendJson(res, 503, { error: "cs2 not running" });
    return;
  }
  await startDirector();
  sendJson(res, 200, { ok: true, enabled: true });
}

// Path the compositor consumer polls for HUD show/hide (stream.sh seeds it in
// composite mode). Mirror of VKCAP_HUD_CTL / $LOG_DIR/hud-visible.
const HUD_CTL_PATH = path.join(LOG_DIR, "hud-visible");

export async function hudHandler(_req, res, body) {
  const visible = Boolean(body.visible);
  // Composite mode: the HUD is a separate gst compositor input, not part of
  // cs2's frame. Toggle it via the consumer's alpha control file — unmapping
  // the overlay window (the legacy path below) would break the ximagesrc xid
  // grab and freeze the whole composite.
  if (existsSync(HUD_CTL_PATH)) {
    writeFileSync(HUD_CTL_PATH, visible ? "1\n" : "0\n");
    sendJson(res, 200, { ok: true, visible, mode: "composite" });
    return;
  }
  const tree = await run(["xwininfo", "-display", DISPLAY, "-root", "-tree"]);
  let overlayId = null;
  let overlayArea = 0;
  if (tree.code === 0) {
    // Match by size: among jts-hud-manager-class windows the overlay
    // is the only fullscreen-sized one (admin is 1280x720).
    for (const line of tree.stdout.split("\n")) {
      const m = line.match(/^\s*(0x[0-9a-f]+)\s.*?(\d+)x(\d+)\+/);
      if (!m) continue;
      if (!/jts-hud-manager/i.test(line)) continue;
      const w = Number(m[2]), h = Number(m[3]);
      if (w < 1600 || h < 900) continue;
      const area = w * h;
      if (area > overlayArea) { overlayArea = area; overlayId = m[1]; }
    }
  }
  if (!overlayId) {
    sendJson(res, 404, { error: "no hud-manager overlay window" });
    return;
  }
  await run(["xdotool", visible ? "windowmap" : "windowunmap", overlayId]);
  sendJson(res, 200, { ok: true, visible, window: overlayId });
}

// What the overlay is currently showing, as the pair JTs Hud Manager needs: a
// hud id (which bundle) and a variant (which layout inside it). Seeded from the
// pod env and updated on every switch, so hudReloadHandler can rebuild exactly
// what is on screen.
//
// The two used to be one thing. HUD_MODE named a layout of the one bundle that
// existed (`default`), and the id was hardcoded. It is still honoured as the
// seed variant so an api that has never heard of HUD_ID behaves as before.
let activeHudId = process.env.HUD_ID || "default";
// ?? not ||: an empty HUD_VARIANT is a real answer ("the bundle's own
// layout"), and || would discard it for the legacy HUD_MODE fallback.
let activeHudVariant =
  process.env.HUD_VARIANT ?? process.env.HUD_MODE ?? "horizontal";

async function startOverlay(hudId, variant) {
  const r = await fetch(`http://${HUD_HOST}:${HUD_PORT}/api/overlay/start`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ hudId, variant }),
  });
  if (!r.ok) {
    const text = await r.text().catch(() => "");
    return { ok: false, status: r.status, body: text.slice(0, 200) };
  }
  return { ok: true };
}

// Fetch an imported bundle and hand it to JTs Hud Manager's own installer.
// Mirrors lib/hud-manager.sh:install_custom_hud, and exists here as well
// because a hot-swap can name a HUD this pod did not boot with. Returns the id
// JTHud actually created, which is not necessarily the one we asked for -- it
// derives the id from the archive when hud.json sits one level deep.
async function installBundle(bundleUrl) {
  const archive = await fetch(bundleUrl);
  if (!archive.ok) {
    throw new Error(`bundle fetch failed: ${archive.status}`);
  }

  const slug = /\/huds\/([^/]+)\/bundle\.zip/.exec(bundleUrl)?.[1] ?? "hud";
  const form = new FormData();
  form.append(
    "hud",
    new Blob([await archive.arrayBuffer()], { type: "application/zip" }),
    `${slug}.zip`,
  );

  const installed = await fetch(
    `http://${HUD_HOST}:${HUD_PORT}/api/huds/upload-zip`,
    { method: "POST", body: form },
  );
  if (!installed.ok) {
    const text = await installed.text().catch(() => "");
    throw new Error(`upload-zip -> ${installed.status}: ${text.slice(0, 200)}`);
  }

  const body = await installed.json().catch(() => ({}));
  if (typeof body?.id !== "string" || !body.id) {
    throw new Error("upload-zip returned no hud id");
  }
  return body.id;
}

// Switch the overlay to another HUD.
//
// Two shapes arrive here. `{ hudId, variant, bundleUrl? }` is the current one:
// a row from the panel's HUD library, where bundleUrl is present only for an
// imported bundle and the pod installs it on first use. `{ mode }` is what
// older clients send -- it was only ever a layout of the bundled HUD, so it
// keeps meaning exactly that.
export async function hudModeHandler(_req, res, body) {
  const LAYOUTS = new Set(["default", "horizontal", "vertical"]);

  let hudId = typeof body.hudId === "string" && body.hudId ? body.hudId : null;
  let variant = typeof body.variant === "string" && body.variant ? body.variant : null;
  const bundleUrl =
    typeof body.bundleUrl === "string" && body.bundleUrl ? body.bundleUrl : null;

  if (!hudId) {
    const mode = typeof body.mode === "string" ? body.mode : null;
    if (!mode || !LAYOUTS.has(mode)) {
      sendJson(res, 400, {
        error: "send a hudId, or a mode of default|horizontal|vertical",
      });
      return;
    }
    hudId = "default";
    variant = mode;
  }

  try {
    if (bundleUrl) {
      // Re-installing an already-present HUD is a no-op overwrite in JTHud, so
      // this does not need to track what is installed -- and must not, since a
      // pod restart empties ~/jthm-huds.
      hudId = await installBundle(bundleUrl);
    }

    const r = await startOverlay(hudId, variant);
    if (!r.ok) {
      sendJson(res, 502, { error: "hud-manager rejected overlay/start", status: r.status, body: r.body });
      return;
    }

    activeHudId = hudId;
    activeHudVariant = variant;
    // `mode` echoed back for older callers that read it.
    sendJson(res, 200, { ok: true, hudId, variant, mode: variant });
  } catch (err) {
    sendJson(res, 502, { error: "hud switch failed", detail: String(err) });
  }
}

// Rebuild the overlay BrowserWindow against whatever is currently shown — a
// fresh page load that re-fetches player metadata and images. Lets
// operators push a mid-match image swap to the live HUD without
// flipping layouts (previously the only way to force a reload).
export async function hudReloadHandler(_req, res, _body) {
  try {
    const r = await startOverlay(activeHudId, activeHudVariant);
    if (!r.ok) {
      sendJson(res, 502, { error: "hud-manager rejected overlay/start", status: r.status, body: r.body });
      return;
    }
    sendJson(res, 200, { ok: true, hudId: activeHudId, variant: activeHudVariant });
  } catch (err) {
    sendJson(res, 502, { error: "hud-manager unreachable", detail: String(err) });
  }
}

export async function hudSidesHandler(_req, res, _body) {
  const raw = gsiState.mapName || "";
  const mapName = raw.includes("/") ? raw.substring(raw.lastIndexOf("/") + 1) : raw;
  if (!mapName) {
    sendJson(res, 409, { error: "no current map" });
    return;
  }
  try {
    const r = await fetch(
      `http://${HUD_HOST}:${HUD_PORT}/api/match/current/veto/${encodeURIComponent(mapName)}/reverse-side`,
      { method: "PATCH" },
    );
    if (!r.ok) {
      const text = await r.text().catch(() => "");
      sendJson(res, 502, {
        error: "hud-manager rejected reverse-side",
        status: r.status,
        body: text.slice(0, 200),
      });
      return;
    }
    sendJson(res, 200, { ok: true, mapName });
  } catch (err) {
    sendJson(res, 502, { error: "hud-manager unreachable", detail: String(err) });
  }
}

// X-ray toggle. cs2's built-in `x` keypress cycles spec_show_xray 0↔1
// — caller tracks the intended state locally and we just emit one
// keypress per intent change.
export async function specXrayHandler(_req, res, body) {
  const ok = await sendKey(KEY_XRAY_TOGGLE);
  sendJson(
    res,
    ok ? 200 : 503,
    ok ? { ok, enabled: Boolean(body.enabled) } : { error: "cs2 not running" },
  );
}

// Momentary scoreboard hold: caller fires {show:true} on Tab-down and
// {show:false} on Tab-up. +showscores / -showscores are valid cs2
// console commands; we send them via exec-cfg.
export async function specScoreboardHandler(_req, res, body) {
  const cmd = body.show ? "+showscores" : "-showscores";
  const ok = await execCfgCommand(cmd);
  sendJson(
    res,
    ok ? 200 : 503,
    ok ? { ok, show: Boolean(body.show) } : { error: "cs2 not running" },
  );
}

// Every spectator control that drives cs2 goes through XTest, which follows X
// input focus rather than a target window -- so "nothing responds" is almost
// always focus having moved. This says so directly.
export async function specFocusHandler(_req, res) {
  sendJson(res, 200, await focusState());
}
