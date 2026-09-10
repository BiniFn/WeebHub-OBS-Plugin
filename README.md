<p align="center">
  <a href="https://weebhub-pearl.vercel.app">
    <img src="assets/weebhub-logo-v2.png" alt="WeebHub logo" width="112" />
  </a>
</p>

<h1 align="center">WeebHub OBS Integration</h1>

<p align="center">
  Local OBS Studio metadata bridge + browser-source overlay for WeebHub playback.
</p>

<p align="center">
  <a href="https://github.com/BiniFn/WeebHub">WeebHub Server</a> ·
  <a href="https://github.com/BiniFn/WeebHub-OBS-Plugin/releases">Releases</a> ·
  <a href="https://github.com/BiniFn/WeebHub-OBS-Plugin">Source</a>
</p>

## What this is (and what it isn't)

This repository ships **two** things:

| Component | Path | What it is |
|---|---|---|
| **Bridge** | `bridge/weebhub_bridge.py` | A dependency-free local server that exposes current WeebHub playback state over HTTP, SSE and WebSocket. |
| **Overlay** | `overlay/weebhub-overlay.html` | A single-file overlay you add to OBS as a **Browser Source**. It connects to the bridge and renders the now-playing card. |
| **Text script** | `plugin/weebhub-nowplaying.lua` | An optional OBS Lua script that writes title and progress to any existing Text source. |

There is no compiled OBS plugin binary. Use the Browser Source for the styled card, or load
the included Lua script from **Tools → Scripts** for a native Text-source workflow.

The bridge is deliberately local-only and exposes presentation-safe metadata (title, episode,
playback state, progress, cover art) — not WeebHub account access or credentials.

## Setup

> **Step-by-step walkthrough with troubleshooting: [`TUTORIAL.md`](TUTORIAL.md).**
> The summary below is the short version.

### 1. Run the bridge

Python 3.8+ only; no packages to install.

```bash
git clone https://github.com/BiniFn/WeebHub-OBS-Plugin.git
cd WeebHub-OBS-Plugin
python3 bridge/weebhub_bridge.py --weebhub-url http://127.0.0.1:43211
```

The bridge now follows local WeebHub playback automatically. Add `--demo` to set up an
overlay without WeebHub running; it simulates playback instead.

If the WeebHub server has a password, pass its SHA-256 token (not the raw password):

```bash
python3 bridge/weebhub_bridge.py --weebhub-url http://127.0.0.1:43211 --weebhub-token YOUR_SHA256_TOKEN
```

Verify it's alive:

```bash
curl http://127.0.0.1:8710/api/health
```

### 2. Add the overlay to OBS

1. In OBS: **Sources → + → Browser**.
2. Tick **Local file** and point it at `overlay/weebhub-overlay.html`.
   *(Or serve the file and use the URL form — both work.)*
3. Set **Width** `1920`, **Height** `1080`.
4. Leave **Shutdown source when not visible** unchecked so it stays connected.

If you load it by URL instead of local file, append config:

```
overlay/weebhub-overlay.html?host=127.0.0.1&port=8710&position=bottom-left&theme=dark
```

### 3. Overlay options

Pass these as query-string parameters on the Browser Source URL:

| Param | Default | Values |
|---|---|---|
| `host` | `127.0.0.1` | Bridge host |
| `port` | `8710` | Bridge port |
| `position` | `bottom-left` | `bottom-left`, `bottom-right`, `top-left`, `top-right` |
| `theme` | `dark` | `dark`, `light` |
| `scale` | `1` | Any positive number |
| `accent` | `#7c5cff` | Any CSS color for the progress bar |
| `show` | `cover,title,episode,progress` | Comma-separated subset to display |

The overlay auto-hides when nothing is playing, shows a **Paused** badge when playback is
paused, and smoothly interpolates the progress bar between bridge updates.

## Bridge API

| Endpoint | Transport | Returns |
|---|---|---|
| `GET /api/health` | HTTP | Liveness + uptime + current state |
| `GET /api/state` | HTTP | Current media state as JSON |
| `GET /api/cover` | HTTP | Current cover art as PNG bytes |
| `GET /api/stream` | SSE | `event: state` push on every change, 15s heartbeat |
| `WS /ws` | WebSocket | Same JSON, pushed on connect and on every change |

Example state payload:

```json
{
  "anime_title": "Frieren: Beyond Journey's End",
  "episode": 12,
  "episode_title": "A Real Hero",
  "playback_state": "playing",
  "position_sec": 64.0,
  "duration_sec": 1440.0,
  "cover_art_url": "/api/cover",
  "connection": "connected",
  "revision": 26,
  "uptime_sec": 8.07
}
```

Clients get the latest state immediately on connect and then receive pushes. No session
token is required — the bridge is always the server.

## Development

```bash
python3 -m py_compile bridge/weebhub_bridge.py
python3 bridge/weebhub_bridge.py --help
python3 bridge/weebhub_bridge.py --demo   # simulated player source
python3 bridge/weebhub_bridge.py --weebhub-url http://127.0.0.1:43211
```

## Credits and Fork Attribution

**Maintained by BiniFn for WeebHub.**

WeebHub is a modified fork of [Seanime](https://github.com/5rahim/seanime) by 5rahim and
contributors. This OBS integration is a WeebHub-specific component; it preserves attribution
to the Seanime project for the upstream media-server foundation on which WeebHub is based.

## License

The WeebHub OBS integration follows the WeebHub ecosystem's
[GNU General Public License v3.0](https://www.gnu.org/licenses/gpl-3.0.html) licensing and
attribution requirements.
