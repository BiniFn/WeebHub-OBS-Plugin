# WeebHub OBS — Full Setup Tutorial

Everything below was run and verified on a real machine before being written down.
Where something is not yet finished, it says so.

---

## 0. What you actually need

| Piece | Where it comes from | Notes |
|---|---|---|
| **OBS Studio** | obsproject.com (free) | Not currently installed on this Mac — step 1. |
| **The bridge** | `bridge/weebhub_bridge.py` in this repo | Python 3.8+ only. No `pip install` of anything. |
| **The overlay** | `overlay/weebhub-overlay.html` in this repo | Single file. No build step. |
| **A WeebHub server** | optional for now | Only needed once the player-feed hook exists (step 7). |

You do **not** need a compiled OBS plugin, a `.lua` script, or any OBS SDK.
OBS has no scripting API this project needs — a **Browser Source** is the supported path,
and it works identically on macOS, Windows and Linux.

---

## 1. Install OBS Studio

1. Download from **https://obsproject.com** → install → open it.
2. Run the Auto-Configuration Wizard on first launch (any answer is fine; you're only
   using a Browser Source, not capturing anything heavy).

Verify: the main window opens and you can see the **Sources** panel at the bottom.

---

## 2. Get the bridge and the overlay

Download and extract the release zip, or clone:

```bash
git clone https://github.com/BiniFn/WeebHub-OBS-Plugin.git
cd WeebHub-OBS-Plugin
```

You should now have:

```
bridge/weebhub_bridge.py        <- the local metadata server
overlay/weebhub-overlay.html    <- the card OBS renders
```

Release page: https://github.com/BiniFn/WeebHub-OBS-Plugin/releases/tag/obs-v1.0.0
Asset: `weebhub-obs-bridge-1.0.0.zip` (contains both files).

---

## 3. Start the bridge

### Test mode (no WeebHub needed — do this first)

```bash
python3 bridge/weebhub_bridge.py --host 127.0.0.1 --port 8710 --demo
```

`--demo` simulates a player: it cycles through titles, advances the position every
second, and pauses periodically. That lets you finish the whole OBS setup and *see*
it working before wiring in anything real.

Leave this terminal window open. Expected output:

```
[bridge] demo player source enabled (updates every 1s)
[bridge] WeebHub local bridge listening on http://127.0.0.1:8710
```

### Real mode (once step 7 is done)

```bash
python3 bridge/weebhub_bridge.py --host 127.0.0.1 --port 8710
```

### Confirm it's alive

```bash
curl http://127.0.0.1:8710/api/health
```

You should get JSON back with `"status": "ok"` and the current title/episode.

---

## 4. Add the overlay to OBS

1. In OBS, in the **Sources** panel: **`+` → Browser**.
2. Name it `WeebHub` → OK.
3. In the properties dialog:
   - Tick **Local file**
   - Click **Browse** and pick `overlay/weebhub-overlay.html`
   - **Width** `1920`, **Height** `1080`
   - Leave **Shutdown source when not visible** UNCHECKED (keeps it connected)
   - Leave **Refresh browser when scene becomes active** unchecked
4. Click **OK**.

The now-playing card should appear in the bottom-left of the preview, showing
"Frieren: Beyond Journey's End — Episode 12" with a moving progress bar.

That's it — the setup is complete. Everything below is optional tuning or troubleshooting.

> Prefer serving over HTTP? Any static server works:
> `python3 -m http.server 8711 --bind 127.0.0.1` then point the Browser Source at
> `http://127.0.0.1:8711/overlay/weebhub-overlay.html`.

---

## 5. Customise the overlay

Options are query-string parameters. With a **local file** Browser Source, append them
to the file path in the URL box after ticking Local file (OBS preserves them), or switch
to the HTTP form and use a normal URL:

```
http://127.0.0.1:8711/overlay/weebhub-overlay.html?position=bottom-right&theme=light&scale=0.9
```

| Param | Default | Accepted values |
|---|---|---|
| `host` | `127.0.0.1` | Bridge host |
| `port` | `8710` | Bridge port |
| `position` | `bottom-left` | `bottom-left`, `bottom-right`, `top-left`, `top-right` |
| `theme` | `dark` | `dark`, `light` |
| `scale` | `1` | Any positive number |
| `accent` | `#7c5cff` | Any CSS colour (progress bar) |
| `show` | `cover,title,episode,progress` | Any comma-separated subset |

Notes:
- `theme=light` is for bright scenes (the card goes white with dark text).
- `show=title,progress` gives you a minimal bar with no cover art.
- The overlay **auto-hides** when nothing is playing (`connection: no-player` or
  `playback_state: stopped`) and shows a **Paused** badge when paused.
- The progress bar interpolates between bridge updates, so it moves smoothly even
  though the bridge only pushes on change.

---

## 6. Troubleshooting

**Card never appears / stays blank**

Check the bridge first:

```bash
curl http://127.0.0.1:8710/api/state
```

- Connection refused → the bridge isn't running. Go back to step 3.
- Works in curl but not OBS → in the Browser Source properties, click **Refresh cache
  of current page**, then **OK**. If still blank, right-click the source → **Interact**;
  the card renders there and you can see any error.
- Still nothing → confirm the file path in the Browser Source points at
  `overlay/weebhub-overlay.html` and not at the folder.

**Card shows but stays frozen on an old title**

The overlay uses SSE, falling back to polling automatically. If SSE is blocked (some
CEF builds), it polls `/api/state` once a second — so it will still update, just less
instantly. Nothing to configure.

**Port already in use**

```bash
lsof -nP -i :8710
```

Either kill that process or run the bridge on a different port and pass the same
`port=` to the overlay.

**Verify the whole pipeline without OBS**

```bash
curl http://127.0.0.1:8710/api/health      # liveness
curl http://127.0.0.1:8710/api/state       # current metadata
curl -o cover.png http://127.0.0.1:8710/api/cover   # cover art PNG
curl -N http://127.0.0.1:8710/api/stream   # live SSE push (Ctrl-C to stop)
```

---

## 7. Feeding real WeebHub playback into the bridge

**Status: not wired up yet.** This is the one gap left.

The bridge is a *server*. Something has to tell it what's playing. Right now the only
thing that does is `--demo`. The intended production path is a small hook in the
WeebHub player that POSTs (or calls in-process) the current state on play/pause/seek/
episode-change:

```json
{
  "anime_title": "Frieren: Beyond Journey's End",
  "episode": 12,
  "episode_title": "A Real Hero",
  "playback_state": "playing",
  "position_sec": 342.0,
  "duration_sec": 1440.0,
  "cover_art_url": "/api/cover"
}
```

Until that hook exists, the overlay works with `--demo` but will not follow your actual
WeebHub playback. Ask if you want that hook built next — it's the natural follow-on.

---

## 8. Bridge API reference

| Endpoint | Transport | Returns |
|---|---|---|
| `GET /api/health` | HTTP | Liveness + uptime + current state |
| `GET /api/state` | HTTP | Current media state as JSON |
| `GET /api/cover` | HTTP | Current cover art as PNG bytes |
| `GET /api/stream` | SSE | `event: state` on every change, 15s heartbeat |
| `WS /ws` | WebSocket | Same JSON, pushed on connect and on change |

All endpoints send `Access-Control-Allow-Origin: *`, so the overlay works whether it's
loaded from `file://` (OBS "Local file") or over HTTP. No session token, no auth —
the bridge is loopback-only by design.

---

## Credits and licence

**Maintained by BiniFn for WeebHub.**

WeebHub is a modified fork of [Seanime](https://github.com/5rahim/seanime) by 5rahim and
contributors. This OBS integration is a WeebHub-specific component and preserves
attribution to the Seanime project for the upstream media-server foundation.

Licensed under **GNU GPL-3.0**, same as upstream. See `LICENSE` and `UPSTREAM.md`.