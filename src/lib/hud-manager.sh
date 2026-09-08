# shellcheck shell=bash
# JTs Hud Manager (CS2 spectator HUD; upstream JohnTimmermann/JTs-Hud-Manager).
# Electron app exposing HUD_PORT (admin + socket.io) and HUD_GSI_PORT (cs2
# gamestate POSTs). Our auto-overlay.patch adds POST /api/overlay/start and
# auto-opens a fullscreen transparent BrowserWindow on the same Xorg-dummy
# as cs2 so ximagesrc captures both composited.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

: "${HUD_BIN:=/opt/hud-manager/jts-hud-manager}"
: "${HUD_PORT:=1349}"
: "${HUD_GSI_PORT:=23415}"
: "${HUD_HOST:=127.0.0.1}"
: "${HUD_USERDATA:=$HOME/.config/JTs Hud Manager}"
: "${HUD_OVERLAY_W:=${CS2_WIDTH:-1920}}"
: "${HUD_OVERLAY_H:=${CS2_HEIGHT:-1080}}"
# Initial HUD variant for the boot auto-overlay. The api stamps this
# onto the pod as HUD_MODE (resolveHudMode → default_hud_mode setting
# → "horizontal" fallback). We forward it to hud-manager as
# HUD_VARIANT so its auto-overlay-patch appends `?variant=...` to the
# initial loadURL — no second window swap needed at boot. Operator
# can still hot-swap mid-stream via /spec/hud-mode. Fallback to
# "horizontal" because that's what the bundled default HUD's "default"
# variant renders as (they're identical layouts).
: "${HUD_MODE:=horizontal}"
# The layout actually used. HUD_VARIANT is authoritative when the api set it --
# INCLUDING when it set it to empty, which means "whatever layout this bundle
# opens with". An imported HUD declares its own layouts (or none), so handing it
# `?variant=horizontal` names one its hud.json very likely does not have.
#
# `${HUD_VARIANT+isset}` rather than `:=`, because the whole point is telling
# "set to empty" apart from "not set at all" -- the default form cannot.
if [ -z "${HUD_VARIANT+isset}" ]; then
  HUD_VARIANT="$HUD_MODE"
fi
# Which HUD *bundle* to load, as opposed to which layout within it. Until the
# panel grew a HUD library there was only ever one on disk, so this was
# hardcoded to "default" in three places; the api now resolves it from a
# broadcast_huds row and stamps it here. Still defaults to the bundled HUD, so
# an api that has never heard of HUD_ID changes nothing.
: "${HUD_ID:=default}"
# Set only for an imported HUD: where to fetch its archive so JTs Hud Manager
# can install it before the overlay opens. A builtin is already inside the
# image and has nothing to download.
: "${HUD_BUNDLE_URL:=}"
# Downloaded archives live on the node cache mount, so a second pod on the same
# node skips the fetch. Keyed by the api's slug, which never names two
# different archives -- a re-import mints a new slug.
: "${HUD_BUNDLE_CACHE:=${STEAM_LIBRARY:-/mnt/game-streamer}/huds}"
# Injected into the overlay window by auto-overlay.patch, which reads it from
# disk at did-finish-load. Unset it to run without the camera overlay.
: "${HUD_CAMERA_OVERLAY_JS:=/opt/hud-manager/camera-overlay.js}"
# Where that overlay reaches the spec-server for the spectated player and the
# WHEP proxy; it never holds the match credentials itself.
: "${SPEC_BASE:=http://127.0.0.1:${SPEC_PORT:-1350}}"
: "${API_BASE:=}"
: "${API_TOKEN:=}"

export HUD_BIN HUD_PORT HUD_GSI_PORT HUD_HOST HUD_USERDATA \
       HUD_OVERLAY_W HUD_OVERLAY_H HUD_MODE HUD_VARIANT HUD_ID HUD_BUNDLE_URL \
       HUD_CAMERA_OVERLAY_JS SPEC_BASE

picom_running() { pgrep -x picom >/dev/null 2>&1; }

start_picom() {
  if picom_running; then return 0; fi
  log "starting picom"
  # xrender backend avoids GLX on Xorg-dummy.
  spawn_logged picom picom --backend xrender --no-fading-openclose --daemon
  for _ in $(seq 1 20); do
    picom_running && return 0
    sleep 0.2
  done
  warn "picom didn't come up — HUD background won't be transparent"
  return 1
}

stop_picom() { pkill -x picom 2>/dev/null || true; }

hud_running() { pgrep -f "$HUD_BIN" >/dev/null 2>&1; }

# Any HTTP response (incl. 404) means express bound the socket.
hud_server_up() {
  local code
  code=$(curl -sS -o /dev/null --max-time 2 -w '%{http_code}' \
    "http://${HUD_HOST}:${HUD_PORT}/" 2>/dev/null)
  [ -n "$code" ] && [ "$code" != "000" ]
}

start_hud() {
  if [ ! -x "$HUD_BIN" ]; then
    warn "HUD binary not found at $HUD_BIN"
    return 1
  fi
  # A hud-manager from a prior run (dev re-run in the same pod) may still be
  # alive but with its :$HUD_PORT server wedged — that holds the port so a
  # fresh instance can't bind, and the old one never serves. Reuse it only if
  # it's actually serving; otherwise kill the stale one and start clean.
  if hud_running; then
    if hud_server_up; then
      log "hud-manager already running"
      return 0
    fi
    local i=0
    while [ "$i" -lt 5 ]; do
      hud_server_up && { log "hud-manager already running"; return 0; }
      sleep 1; i=$(( i + 1 ))
    done
    warn "existing hud-manager not serving on :$HUD_PORT — restarting it"
    stop_hud; sleep 1
  fi
  mkdir -p "$HUD_USERDATA"
  log "starting hud-manager"
  # HUD_AUTO_OVERLAY=1 → auto-overlay.patch opens the bundled `default`
  # HUD on app-ready. HUD_VARIANT → the same patch appends
  # `?variant=<v>` so the initial layout matches the api-resolved
  # default. --mute-audio so HUD SFX don't leak into the captured
  # stream via the cs2 null sink.
  #
  # Deliberately NOT given HUD_ID: an imported HUD is installed by
  # install_custom_hud, which cannot run until this server is up, so at
  # app-ready the builtin is the only hud id that exists. Booting the overlay
  # on an id with nothing behind it renders a blank window and logs nothing.
  # install_custom_hud re-opens the overlay itself once the bundle is in.
  HUD_PORT="$HUD_PORT" \
  GSI_PORT="$HUD_GSI_PORT" \
  HUD_AUTO_OVERLAY=1 \
  HUD_VARIANT="$HUD_VARIANT" \
    spawn_logged hud-manager "$HUD_BIN" --no-sandbox --disable-gpu-sandbox --mute-audio
}

# Wait up to <timeout>s (default 60) for the server to bind. Returns 1 on
# timeout or if the process exits — callers recover (restart) rather than
# hang forever waiting on a wedged instance.
wait_for_hud_server() {
  local timeout="${1:-60}"
  log "waiting for HUD server on :${HUD_PORT} (timeout ${timeout}s)"
  local i=0
  while [ "$i" -lt "$timeout" ]; do
    if hud_server_up; then
      log "  hud server up after ${i}s"
      return 0
    fi
    if ! hud_running; then
      warn "hud-manager process exited early"
      return 1
    fi
    i=$(( i + 1 ))
    [ $(( i % 30 )) -eq 0 ] && log "  still waiting (${i}s)"
    sleep 1
  done
  warn "hud server didn't come up within ${timeout}s"
  return 1
}

stop_hud() { pkill -f "$HUD_BIN" 2>/dev/null || true; }

# Install the imported HUD bundle into JTs Hud Manager, and leave HUD_ID naming
# whatever it ended up as on disk.
#
# We hand it the archive rather than unpacking anything ourselves: JTHud's own
# POST /api/huds/upload-zip is what creates ~/jthm-huds/<id>, and it is also
# what verifies a signed bundle against the `key` file beside its hud.json. A
# second unpacker here would be a second thing to keep in agreement with it.
#
# The id is read back out of the response instead of assumed, because JTHud
# derives it itself -- from the top-level folder when hud.json sits one level
# deep, otherwise from the filename we posted. Those disagree often enough that
# guessing would open the overlay on a hud id that does not exist, which renders
# a blank window and logs nothing.
#
# Every failure path leaves HUD_ID at the builtin. A stream with the stock HUD
# is a far better outcome than a stream with no HUD, and the operator can still
# switch at runtime once the cause is fixed.
install_custom_hud() {
  [ -z "$HUD_BUNDLE_URL" ] && return 0

  if ! hud_server_up; then
    warn "hud-manager not serving — cannot install the custom HUD, using the bundled one"
    HUD_ID=default
    return 1
  fi

  local slug archive response installed_id
  # .../huds/<slug>/bundle.zip
  slug=$(printf '%s\n' "$HUD_BUNDLE_URL" | sed -n 's#.*/huds/\([^/]*\)/bundle\.zip.*#\1#p')
  if [ -z "$slug" ]; then
    warn "could not read a HUD slug out of $HUD_BUNDLE_URL — using the bundled HUD"
    HUD_ID=default
    return 1
  fi

  mkdir -p "$HUD_BUNDLE_CACHE" 2>/dev/null || true
  archive="$HUD_BUNDLE_CACHE/$slug.zip"

  # A slug never names two different archives -- the panel mints a new one on
  # re-import -- so a cached file is always the right bytes.
  if [ -s "$archive" ]; then
    log "custom HUD $slug already cached"
  else
    log "downloading custom HUD $slug"
    # .part so an interrupted download is never mistaken for a cached archive
    # by the next pod on this node.
    if ! curl -fsS -m 120 -o "$archive.part" "$HUD_BUNDLE_URL"; then
      rm -f "$archive.part"
      warn "custom HUD download failed — using the bundled HUD"
      HUD_ID=default
      return 1
    fi
    mv -f "$archive.part" "$archive"
  fi

  log "installing custom HUD $slug into hud-manager"
  response=$(curl -fsS -m 60 -X POST \
    -F "hud=@${archive};type=application/zip;filename=${slug}.zip" \
    "http://${HUD_HOST}:${HUD_PORT}/api/huds/upload-zip" 2>/dev/null) || {
      warn "hud-manager rejected the custom HUD — using the bundled HUD"
      HUD_ID=default
      return 1
    }

  installed_id=$(printf '%s' "$response" | python3 -c '
import json, sys
try:
    body = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(body, dict) and isinstance(body.get("id"), str):
    print(body["id"])
' 2>/dev/null)

  if [ -z "$installed_id" ]; then
    warn "hud-manager returned no HUD id — using the bundled HUD"
    HUD_ID=default
    return 1
  fi

  HUD_ID="$installed_id"
  export HUD_ID
  log "custom HUD installed as \"$HUD_ID\""

  # Move the overlay onto it now. The boot auto-overlay opened the builtin
  # because that was the only thing installed at app-ready; this is the switch,
  # and doing it here rather than leaving it to a later caller means an imported
  # HUD works on a pod that never seeds match data (no MATCH_ID, no API_BASE).
  if ! curl -fsS -m 10 -X POST -o /dev/null \
       -H 'content-type: application/json' \
       --data "{\"hudId\":\"${HUD_ID}\",\"variant\":\"${HUD_VARIANT}\"}" \
       "http://${HUD_HOST}:${HUD_PORT}/api/overlay/start"; then
    warn "installed $HUD_ID but the overlay would not switch to it"
    return 1
  fi

  return 0
}

# windowunmap alone is sometimes ignored by Electron windows; offscreen
# move is the fallback.
hide_hud_admin_window() {
  local id name target=""
  for id in $(xdotool search --classname '^jts-hud-manager' 2>/dev/null); do
    name=$(xdotool getwindowname "$id" 2>/dev/null || true)
    if [ "$name" = "JTs Hud Manager" ]; then target="$id"; break; fi
  done
  [ -z "$target" ] && return 0
  xdotool windowminimize "$target"         2>/dev/null || true
  wmctrl -ir "$target" -b add,hidden       2>/dev/null || true
  xdotool windowunmap "$target"            2>/dev/null || true
  xdotool windowmove "$target" -3000 -3000 2>/dev/null || true
}

# Largest jts-hud-manager window above HUD_MIN_W x HUD_MIN_H. Title isn't
# reliable (loadURL replaces it from the HUD bundle's <title>), but the
# overlay is unique in being fullscreen-sized.
find_hud_overlay_window() {
  local min_w="${HUD_MIN_W:-1600}"
  local min_h="${HUD_MIN_H:-900}"
  local id w h area best=0 best_id=""
  for id in $(xdotool search --classname '^jts-hud-manager' 2>/dev/null); do
    unset WIDTH HEIGHT X Y SCREEN
    eval "$(xdotool getwindowgeometry --shell "$id" 2>/dev/null)"
    w="${WIDTH:-0}"; h="${HEIGHT:-0}"
    [ "$w" -ge "$min_w" ] && [ "$h" -ge "$min_h" ] || continue
    area=$((w * h))
    if [ "$area" -gt "$best" ]; then
      best="$area"; best_id="$id"
    fi
  done
  [ -n "$best_id" ] && echo "$best_id"
}

# Wait for the overlay window, respawn hud-manager if it died, then
# move/size/raise it. Upstream's enforceOverlayOnTop() handles
# alwaysOnTop in JS land; this nails stacking before the first capture
# frame.
position_hud_overlay() {
  local timeout="${HUD_OVERLAY_TIMEOUT:-30}"
  local id=""
  for _ in $(seq 1 "$timeout"); do
    id=$(find_hud_overlay_window)
    [ -n "$id" ] && break
    if ! hud_running; then
      warn "hud-manager process died — restarting"
      stop_hud; sleep 1
      start_hud
      wait_for_hud_server 30 || warn "respawned hud-manager not responding"
    fi
    sleep 1
  done
  if [ -z "$id" ]; then
    warn "no HUD overlay window after ${timeout}s"
    return 1
  fi
  log "positioning HUD overlay ${HUD_OVERLAY_W}x${HUD_OVERLAY_H} (window $id)"
  xdotool windowmove "$id" 0 0                                2>/dev/null || true
  xdotool windowsize "$id" "$HUD_OVERLAY_W" "$HUD_OVERLAY_H"  2>/dev/null || true
  wmctrl -ir "$id" -b add,above                               2>/dev/null || true
  xdotool windowraise "$id"                                   2>/dev/null || true
}

# Single GSI cfg. cs2 POSTs to spec-server; spec-server processes the
# body for the director and forwards it to hud-manager's /cs2/input.
# Data fields are the union of what both consumers need (the HUD's set
# from src/main/ipc.ts:GSI_CFG_CONTENT plus the director's position /
# weapons / match_stats).
write_gsi_cfg() {
  local cfg_dir="$CS2_DIR/game/csgo/cfg"
  mkdir -p "$cfg_dir"
  # Clean up the legacy two-cfg setup if a prior image left them.
  rm -f "$cfg_dir/gamestate_integration_jts_hud_manager.cfg"
  local dst="$cfg_dir/gamestate_integration_5stack.cfg"
  local port="${SPEC_SERVER_PORT:-1350}"
  cat >"$dst" <<EOF
"5Stack GSI"
{
  "uri" "http://127.0.0.1:${port}/gsi"
  "timeout" "5.0"
  "buffer" "0.0"
  "throttle" "0.1"
  "heartbeat" "10.0"
  "auth" { "token" "5stack-spec" }
  "data"
  {
    "provider"               "1"
    "map"                    "1"
    "round"                  "1"
    "player_id"              "1"
    "player_state"           "1"
    "player_position"        "1"
    "allplayers_id"          "1"
    "allplayers_state"       "1"
    "allplayers_position"    "1"
    "allplayers_weapons"     "1"
    "allplayers_match_stats" "1"
    "phase_countdowns"       "1"
    "allgrenades"            "1"
    "map_round_wins"         "1"
    "bomb"                   "1"
  }
}
EOF
}

# Mirror in src/spectator/constants.mjs. BACKSPACE → exec 5stack_exec
# is the exec-cfg flush path used by spec-server's execCfgCommand; both
# live and demo need it (e.g. /spec/scoreboard fires +/-showscores via
# exec-cfg).
spec_static_binds_block() {
  cat <<'EOF'
bind "F1" "spec_next"
bind "F2" "spec_prev"
bind "F3" "+jump"
bind "F4" "spec_autodirector 1; spec_mode 5"
bind "F5" "spec_autodirector 0"
bind "BACKSPACE" "exec 5stack_exec"
EOF
}

# Mirror in src/spectator/constants.mjs. Tick offsets assume 64-tick demos.
demo_static_binds_block() {
  cat <<'EOF'
bind "PAUSE" "demo_togglepause"
bind "HOME" "demo_gototick -960"
bind "END" "demo_gototick +960"
bind "INS" "host_timescale 1"
bind "SEMICOLON" "host_timescale 0.5"
bind "APOSTROPHE" "host_timescale 2"
bind "PGUP" "host_timescale 4"
bind "PGDN" "host_timescale 0.25"
bind "F11" "demoui"
EOF
}

# Append per-player `bind "F<n>" "spec_player_by_accountid <id>"` to the
# autoexec from the seeded match JSON, and emit the accountid→keysym map
# spec-server reads at request time.
write_spec_player_binds() {
  local match_json="$1" autoexec="$2" map_out="$3"
  if [ ! -s "$match_json" ]; then
    : > "$map_out" 2>/dev/null || true
    return 0
  fi

  python3 - "$match_json" "$autoexec" "$map_out" <<'PY' 2>&1 | sed 's/^/    /'
import json, sys

match_json_path, autoexec_path, map_path = sys.argv[1], sys.argv[2], sys.argv[3]

# F6..F11 — 5v5 plus one sub. F12 is Steam's screenshot hotkey; binding
# cs2 actions to it triggers a Steam screenshot.
KEYS = [f"F{n}" for n in range(6, 12)]

STEAMID64_BASE = 76561197960265728
def to_accountid(s):
    try:
        n = int(s)
    except (TypeError, ValueError):
        return None
    return n - STEAMID64_BASE if n > STEAMID64_BASE else n

with open(match_json_path) as f:
    raw = json.load(f)
match = raw.get('match', raw) if isinstance(raw, dict) else {}

binds = []
mapping = {}
seen = set()
slot = 0
for lu in (match.get('lineups') or []):
    if slot >= len(KEYS):
        break
    for p in (lu.get('players') or lu.get('lineup_players') or []):
        if slot >= len(KEYS):
            break
        steam = (p.get('steam_id') or p.get('steamId') or
                 p.get('steamid64') or p.get('steamid'))
        aid = to_accountid(steam)
        if aid is None or aid in seen:
            continue
        seen.add(aid)
        key = KEYS[slot]
        binds.append(f'bind "{key}" "spec_player_by_accountid {aid}"')
        mapping[str(aid)] = key
        slot += 1

with open(autoexec_path, 'a') as f:
    f.write('\n// per-player spec binds (auto-generated)\n')
    f.write('\n'.join(binds))
    f.write('\n')

with open(map_path, 'w') as f:
    json.dump({'accountid_to_key': mapping, 'keys': KEYS[:slot]}, f, indent=2)

print(f"wrote {slot} per-player binds")
PY
}

# Best-effort: GET match metadata from the 5stack api, then POST
# translated objects to JTs Hud Manager's REST. Non-fatal — HUD still
# runs with fallback GSI-provider names if this drifts.
seed_hud_db() {
  local match_id="${1:?match id required}"
  if [ -z "$API_BASE" ]; then return 0; fi
  log "seeding hud-manager DB for match $match_id"

  local hdr=()
  [ -n "$API_TOKEN" ] && hdr=(-H "Authorization: Bearer $API_TOKEN")

  # GET /hud-data/:id returns the curated shape we POST onward — pre-flattened
  # lineups with absolute avatar/logo URLs. See
  # api/src/matches/game-streamer/hud-data.controller.ts:getMatchHudData.
  # Path is intentionally outside /matches/* so it stays off the public api
  # ingress (only reachable from inside the cluster via $API_BASE).
  local match_json
  match_json=$(curl -fsS --max-time 10 "${hdr[@]}" \
        "${API_BASE%/}/hud-data/${match_id}") || {
    warn "match fetch failed"
    return 0
  }
  if [ -z "$match_json" ]; then
    warn "match fetch returned empty body"
    return 0
  fi

  printf '%s\n' "$match_json" >"$LOG_DIR/hud-seed-match.json"

  # Batch-highlights skips the HUD overlay entirely (no scoreboard on
  # recorded clips), so hud-manager isn't running. Downstream callers
  # (write_spec_player_binds) only need the JSON file we just wrote;
  # the HTTP POSTs below would otherwise spam "Connection refused" and
  # obscure real clip-render errors in the logs.
  if [ "${CLIP_BATCH_MODE:-0}" = "1" ]; then
    log "  CLIP_BATCH_MODE=1 — skipping hud-manager POSTs (json snapshot saved)"
    return 0
  fi

  python3 - <<'PY' "$match_json" "http://${HUD_HOST}:${HUD_PORT}/api"
import json, secrets, sys, urllib.request, urllib.error

raw, base = sys.argv[1], sys.argv[2]

def log(msg):
    sys.stderr.write(f"[hud-seed] {msg}\n"); sys.stderr.flush()

def post_json(path, body):
    req = urllib.request.Request(
        base + path,
        data=json.dumps(body).encode(),
        headers={'Content-Type': 'application/json'},
        method='POST',
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            log(f"POST {path} -> {r.status}")
            return json.loads(r.read() or b'{}')
    except urllib.error.HTTPError as e:
        log(f"POST {path} -> HTTP {e.code}: {e.read().decode(errors='replace')}")
    except Exception as e:
        log(f"POST {path} -> {type(e).__name__}: {e}")
    return None

def put_json(path, body):
    req = urllib.request.Request(
        base + path,
        data=json.dumps(body).encode(),
        headers={'Content-Type': 'application/json'},
        method='PUT',
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            log(f"PUT {path} -> {r.status}")
            return json.loads(r.read() or b'{}')
    except urllib.error.HTTPError as e:
        log(f"PUT {path} -> HTTP {e.code}: {e.read().decode(errors='replace')}")
    except Exception as e:
        log(f"PUT {path} -> {type(e).__name__}: {e}")
    return None

# JTs Hud Manager stores logos/avatars as multer-uploaded files and
# the HUD renders them via /api/teams/logo/:id (which sendFile's the
# uploaded file). JSON-stuffing a URL/data-URL into the `logo` field
# would pass the truthy check on the server but break sendFile, so we
# POST as multipart with the file field name multer expects
# (upload.single('logo') / upload.single('avatar')).
def _sniff_ext(data):
    if data.startswith(b'\xff\xd8\xff'): return 'jpg', 'image/jpeg'
    if data.startswith(b'\x89PNG\r\n\x1a\n'): return 'png', 'image/png'
    if data.startswith(b'GIF8'): return 'gif', 'image/gif'
    if data[:4] == b'RIFF' and data[8:12] == b'WEBP': return 'webp', 'image/webp'
    if data.startswith(b'<svg') or data[:5] == b'<?xml': return 'svg', 'image/svg+xml'
    return 'bin', 'application/octet-stream'

def fetch_image(url):
    if not url or not isinstance(url, str): return None
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'game-streamer/hud-seed'})
        with urllib.request.urlopen(req, timeout=8) as r:
            data = r.read()
            ext, ctype = _sniff_ext(data)
            log(f"fetched {len(data)}B from {url} -> {ctype}")
            return {'data': data, 'ext': ext, 'ctype': ctype}
    except Exception as e:
        log(f"image fetch failed {url}: {type(e).__name__}: {e}")
        return None

def post_multipart(path, fields, files):
    """fields: list[(name, value_str)]. files: list[(name, filename, ctype, bytes)]."""
    boundary = '----HudSeed' + secrets.token_hex(16)
    crlf = b'\r\n'
    body = bytearray()
    for name, value in fields:
        body += b'--' + boundary.encode() + crlf
        body += f'Content-Disposition: form-data; name="{name}"'.encode() + crlf + crlf
        body += str(value).encode() + crlf
    for name, filename, ctype, data in files:
        body += b'--' + boundary.encode() + crlf
        body += f'Content-Disposition: form-data; name="{name}"; filename="{filename}"'.encode() + crlf
        body += f'Content-Type: {ctype}'.encode() + crlf + crlf
        body += data + crlf
    body += b'--' + boundary.encode() + b'--' + crlf
    req = urllib.request.Request(
        base + path,
        data=bytes(body),
        headers={'Content-Type': f'multipart/form-data; boundary={boundary}'},
        method='POST',
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            log(f"POST {path} -> {r.status} (multipart, {len(body)}B)")
            return json.loads(r.read() or b'{}')
    except urllib.error.HTTPError as e:
        log(f"POST {path} -> HTTP {e.code}: {e.read().decode(errors='replace')}")
    except Exception as e:
        log(f"POST {path} -> {type(e).__name__}: {e}")
    return None

try:
    m = json.loads(raw)
except Exception as e:
    log(f"match json parse failed: {e}")
    sys.exit(0)

match = m.get('match', m) if isinstance(m, dict) else {}
lineups = match.get('lineups') or []

team_ids = []
for lu in lineups:
    name = lu.get('name') or 'Team'
    short = lu.get('short_name') or name[:3].upper()
    logo = fetch_image(lu.get('logo'))
    if logo:
        resp = post_multipart(
            '/teams',
            [('name', name), ('shortName', short), ('country', 'us'), ('extra', '{}')],
            [('logo', f'logo.{logo["ext"]}', logo['ctype'], logo['data'])],
        )
    else:
        resp = post_json('/teams', {
            'name': name, 'shortName': short, 'country': 'us',
            'logo': '', 'extra': {},
        })
    tid = (resp or {}).get('_id') or (resp or {}).get('id')
    team_ids.append(tid)
    for p in lu.get('players') or []:
        steam = p.get('steam_id') or ''
        first = p.get('name') or 'Player'
        p_fields = [
            ('firstName', first), ('lastName', ''),
            ('username', first),
            ('country', p.get('country') or 'us'),
            ('steamid', steam),
            ('team', tid or ''),
            ('isCoach', 'false'), ('extra', '{}'),
        ]
        avatar = fetch_image(p.get('avatar'))
        if avatar:
            post_multipart('/players', p_fields, [
                ('avatar', f'avatar.{avatar["ext"]}', avatar['ctype'], avatar['data']),
            ])
        else:
            post_json('/players', {
                'firstName': first, 'lastName': '', 'username': first,
                'avatar': '', 'country': p.get('country') or 'us',
                'steamid': steam, 'team': tid or '',
                'isCoach': False, 'extra': {},
            })

if len(team_ids) >= 2 and all(team_ids[:2]):
    # spec-server owns halftime/OT swaps via reporters/sides.mjs — the
    # HUD's built-in autoSwitchSides was unreliable, so we drive it.
    put_json('/settings', {'autoSwitchSides': False})

    best_of = int(match.get('best_of') or 1)
    if best_of <= 1:
        match_type = 'bo1'
    elif best_of == 2:
        match_type = 'bo2'
    elif best_of <= 4:
        match_type = 'bo3'
    else:
        match_type = 'bo5'

    lineup_1_id = match.get('lineup_1_id')
    lineup_2_id = match.get('lineup_2_id')
    lineup_to_team = {}
    if lineup_1_id:
        lineup_to_team[str(lineup_1_id)] = team_ids[0]
    if lineup_2_id:
        lineup_to_team[str(lineup_2_id)] = team_ids[1]

    left_wins = 0
    right_wins = 0
    vetos = []
    for mm in (match.get('match_maps') or []):
        map_name = (mm.get('map_name') or '').strip()
        if not map_name:
            continue
        status = mm.get('status') or 'pending'
        winning_lineup_id = mm.get('winning_lineup_id')
        winner_team = lineup_to_team.get(str(winning_lineup_id)) if winning_lineup_id else None
        if winner_team == team_ids[0]:
            left_wins += 1
        elif winner_team == team_ids[1]:
            right_wins += 1
        pick_type_raw = (mm.get('pick_type') or 'Decider')
        veto_type = 'decider' if pick_type_raw == 'Decider' else 'pick'
        picker_lineup_id = mm.get('picked_by_lineup_id')
        picker_team = lineup_to_team.get(str(picker_lineup_id)) if picker_lineup_id else ''
        veto = {
            'teamId': picker_team or '',
            'mapName': map_name,
            'side': 'NO',
            'type': veto_type,
            'reverseSide': False,
            'mapEnd': status == 'finished',
        }
        if status == 'finished':
            veto['score'] = {
                team_ids[0]: int(mm.get('lineup_1_score') or 0),
                team_ids[1]: int(mm.get('lineup_2_score') or 0),
            }
            if winner_team:
                veto['winner'] = winner_team
        vetos.append(veto)

    post_json('/match', {
        'current': True,
        'left':  {'id': team_ids[0], 'wins': left_wins},
        'right': {'id': team_ids[1], 'wins': right_wins},
        'matchType': match_type, 'vetos': vetos,
    })
PY
  return 0
}
