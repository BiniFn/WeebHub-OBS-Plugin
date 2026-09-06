<p align="center">
  <a href="https://weebhub-pearl.vercel.app">
    <img src="assets/weebhub-logo-v2.png" alt="WeebHub logo" width="112" />
  </a>
</p>

<h1 align="center">WeebHub OBS Integration</h1>

<p align="center">
  Local OBS Studio integration bridge for WeebHub playback and streamer metadata.
</p>

<p align="center">
  <a href="https://github.com/BiniFn/WeebHub">WeebHub Server</a> ·
  <a href="https://github.com/BiniFn/WeebHub-OBS-Plugin/releases">Releases</a> ·
  <a href="https://github.com/BiniFn/WeebHub-OBS-Plugin">Source</a>
</p>

## What it does

The bridge exposes a localhost HTTP, Server-Sent Events, and WebSocket interface for current WeebHub media state. It is intended for the WeebHub OBS source/plugin layer and allows an OBS integration to receive live, automatically updated metadata without relying on a manually refreshed browser source.

The bridge is deliberately local-only. It is designed to expose presentation-safe playback metadata such as title, episode, chapter/page, playback state, progress, and artwork—not unrestricted WeebHub server access or account credentials.

## Development

```bash
git clone https://github.com/BiniFn/WeebHub-OBS-Plugin.git
cd WeebHub-OBS-Plugin
python3 bridge/weebhub_bridge.py --help
```

See the source comments in `bridge/weebhub_bridge.py` for its available configuration and local API behavior.

## Credits and Fork Attribution

**Maintained by BiniFn for WeebHub.**

WeebHub is a modified fork of [Seanime](https://github.com/5rahim/seanime) by 5rahim and contributors. This OBS integration is a WeebHub-specific component; it preserves attribution to the Seanime project for the upstream media-server foundation on which WeebHub is based.

## License

The WeebHub OBS integration follows the WeebHub ecosystem's [GNU General Public License v3.0](https://www.gnu.org/licenses/gpl-3.0.html) licensing and attribution requirements.
