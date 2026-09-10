--[[
  weebhub-nowplaying.lua — WeebHub now-playing plugin for OBS Studio

  Loaded by OBS's built-in Lua scripting engine: Tools -> Scripts -> +.
  No compilation, no OBS SDK, no installer. Works on Windows, macOS and Linux.

  WHAT IT DOES
  ------------
  Polls the WeebHub local bridge (bridge/weebhub_bridge.py) and writes the
  current title / episode / progress into a Text source you already have in
  your scene. Optionally hides that source while nothing is playing.

  WHAT IT DOES NOT DO
  -------------------
  OBS's Lua API cannot create or drive a Browser Source, so this plugin
  renders plain text, not the styled card with cover art. For the card, add
  overlay/weebhub-overlay.html as a Browser Source (see TUTORIAL.md). Both
  read the same bridge and can run at the same time.

  REQUIRES
  --------
  curl on PATH. It is preinstalled on macOS and most Linux distributions, and
  curl.exe ships with Windows 10 1803+.

  LICENCE
  -------
  GNU GPL-3.0 — see LICENSE. WeebHub is a modified fork of Seanime by 5rahim
  and contributors; see UPSTREAM.md.
]]

local obs = obslua

-- ===========================================================================
-- configuration
-- ===========================================================================

local DEFAULT_URL      = "http://127.0.0.1:8710/api/state"
local DEFAULT_SOURCE   = "WeebHub Now Playing"
local DEFAULT_TEMPLATE = "{title}\nEpisode {episode} — {episode_title}\n{position} / {duration}  ({percent}%)\n{progress}"
local DEFAULT_INTERVAL = 1000

-- Text source ids this plugin knows how to write to.
local TEXT_SOURCE_IDS = {
  text_gdiplus       = true,
  text_gdiplus_v2    = true,
  text_ft2_source    = true,
  text_ft2_source_v2 = true,
}

-- Only URLs matching this are handed to the shell. Rejecting everything else
-- (quotes, ;, $, backtick, |, &, whitespace) means the curl command below
-- cannot be broken out of, whatever the user types into the settings box.
local URL_SAFE = "^https?://[%w%.%-%_:/%?%%&=~#%+,]+$"

local cfg = {
  url            = DEFAULT_URL,
  source_name    = DEFAULT_SOURCE,
  template       = DEFAULT_TEMPLATE,
  idle_text      = "",
  hide_when_idle = true,
  interval_ms    = DEFAULT_INTERVAL,
}

local timer_fn  = nil
local last_text = nil
local warned    = {}

-- ===========================================================================
-- forward declarations
--
-- Several of these call each other, so they are declared before definition;
-- otherwise a body referencing a later `local function` would silently
-- capture a global (nil) instead.
-- ===========================================================================

local json_decode, format_time, make_bar, apply_template, build_vals
local is_idle, http_get, push_to_source, tick_once, restart_timer, apply_settings

-- ===========================================================================
-- logging (deduplicated so a 1 Hz poll cannot flood the OBS log)
-- ===========================================================================

local function log_once(key, level, msg)
  if warned[key] then return end
  warned[key] = true
  obs.obs_log(level, "[weebhub] " .. msg)
end

local function log_clear(key)
  warned[key] = nil
end

-- ===========================================================================
-- JSON
--
-- The bridge's payload is a flat object, but titles are arbitrary UTF-8, so a
-- real decoder is used instead of pattern matching: escaped quotes, \uXXXX,
-- surrogate pairs (emoji), nulls, booleans and floats all have to survive.
-- ===========================================================================

local ESCAPES = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }

json_decode = function(text)
  if type(text) ~= "string" then error("json_decode: expected string") end
  local pos, len = 1, #text

  local function skip_ws()
    while pos <= len do
      local c = text:sub(pos, pos)
      if c == " " or c == "\t" or c == "\n" or c == "\r" then pos = pos + 1 else break end
    end
  end

  local parse_value

  local function parse_string()
    pos = pos + 1 -- opening quote
    local buf = {}
    while true do
      if pos > len then error("json_decode: unterminated string") end
      local c = text:sub(pos, pos)
      if c == '"' then
        pos = pos + 1
        break
      elseif c == "\\" then
        local e = text:sub(pos + 1, pos + 1)
        if ESCAPES[e] then
          buf[#buf + 1] = ESCAPES[e]
          pos = pos + 2
        elseif e == "u" then
          local code = tonumber(text:sub(pos + 2, pos + 5), 16)
          if not code then error("json_decode: bad \\u escape") end
          pos = pos + 6
          -- surrogate pair -> single code point
          if code >= 0xD800 and code <= 0xDBFF and text:sub(pos, pos + 1) == "\\u" then
            local lo = tonumber(text:sub(pos + 2, pos + 5), 16)
            if lo and lo >= 0xDC00 and lo <= 0xDFFF then
              code = 0x10000 + (code - 0xD800) * 0x400 + (lo - 0xDC00)
              pos = pos + 6
            end
          end
          buf[#buf + 1] = utf8.char(code)
        else
          error("json_decode: bad escape \\" .. tostring(e))
        end
      else
        buf[#buf + 1] = c
        pos = pos + 1
      end
    end
    return table.concat(buf)
  end

  local function parse_number()
    local start = pos
    while pos <= len and text:sub(pos, pos):match("[%d%.eE%+%-]") do pos = pos + 1 end
    local n = tonumber(text:sub(start, pos - 1))
    if n == nil then error("json_decode: bad number") end
    return n
  end

  parse_value = function()
    skip_ws()
    local c = text:sub(pos, pos)
    if c == "{" then
      pos = pos + 1
      local obj = {}
      skip_ws()
      if text:sub(pos, pos) == "}" then pos = pos + 1 return obj end
      while true do
        skip_ws()
        if text:sub(pos, pos) ~= '"' then error("json_decode: expected object key") end
        local k = parse_string()
        skip_ws()
        if text:sub(pos, pos) ~= ":" then error("json_decode: expected ':'") end
        pos = pos + 1
        obj[k] = parse_value()
        skip_ws()
        local d = text:sub(pos, pos)
        if d == "," then pos = pos + 1
        elseif d == "}" then pos = pos + 1 break
        else error("json_decode: expected ',' or '}'") end
      end
      return obj
    elseif c == "[" then
      pos = pos + 1
      local arr = {}
      skip_ws()
      if text:sub(pos, pos) == "]" then pos = pos + 1 return arr end
      while true do
        arr[#arr + 1] = parse_value()
        skip_ws()
        local d = text:sub(pos, pos)
        if d == "," then pos = pos + 1
        elseif d == "]" then pos = pos + 1 break
        else error("json_decode: expected ',' or ']'") end
      end
      return arr
    elseif c == '"' then
      return parse_string()
    elseif text:sub(pos, pos + 3) == "true" then
      pos = pos + 4 return true
    elseif text:sub(pos, pos + 4) == "false" then
      pos = pos + 5 return false
    elseif text:sub(pos, pos + 3) == "null" then
      pos = pos + 4 return nil
    else
      return parse_number()
    end
  end

  local value = parse_value()
  skip_ws()
  if pos <= len then error("json_decode: trailing data at " .. pos) end
  return value
end

-- ===========================================================================
-- rendering
-- ===========================================================================

format_time = function(sec)
  sec = tonumber(sec) or 0
  if sec < 0 then sec = 0 end
  sec = math.floor(sec)
  local h = math.floor(sec / 3600)
  local m = math.floor((sec % 3600) / 60)
  local s = sec % 60
  if h > 0 then
    return string.format("%d:%02d:%02d", h, m, s)
  end
  return string.format("%d:%02d", m, s)
end

make_bar = function(pct, width)
  width = width or 24
  local filled = math.floor((pct / 100) * width + 0.5)
  if filled < 0 then filled = 0 end
  if filled > width then filled = width end
  return string.rep("#", filled) .. string.rep("-", width - filled)
end

apply_template = function(tpl, vals)
  -- gsub with a function replacement: the returned string is inserted
  -- literally, so values containing '%' are safe.
  return (tpl:gsub("{(%w+)}", function(key)
    local v = vals[key]
    if v == nil then return "" end
    return tostring(v)
  end))
end

build_vals = function(st)
  local pos = tonumber(st.position_sec) or 0
  local dur = tonumber(st.duration_sec) or 0
  local pct = 0
  if dur > 0 then pct = math.floor((pos / dur) * 100 + 0.5) end
  if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end
  local ep = st.episode
  if ep == nil or ep == "" then ep = "" end
  return {
    title         = st.anime_title or "",
    episode       = ep,
    episode_title = st.episode_title or "",
    position      = format_time(pos),
    duration      = format_time(dur),
    percent       = pct,
    progress      = make_bar(pct),
    state         = st.playback_state or "",
    connection    = st.connection or "",
  }
end

is_idle = function(st)
  if type(st) ~= "table" then return true end
  local conn = st.connection
  local play = st.playback_state
  if conn == "no-player" then return true end
  if play == nil or play == "" or play == "stopped" then return true end
  return false
end

-- ===========================================================================
-- transport
-- ===========================================================================

http_get = function(url)
  if type(url) ~= "string" or not url:match(URL_SAFE) then
    return nil, "refusing unsafe or malformed URL"
  end
  local ok_open, pipe = pcall(io.popen, string.format('curl -s --max-time 3 "%s"', url))
  if not ok_open or not pipe then
    return nil, "io.popen unavailable in this Lua build"
  end
  local body = pipe:read("*a") or ""
  local _, _, code = pipe:close()
  if body == "" then
    return nil, "empty response (curl exit " .. tostring(code or "?") .. ")"
  end
  return body
end

-- ===========================================================================
-- pushing state into the Text source
-- ===========================================================================

push_to_source = function(st)
  local name = cfg.source_name
  if name == nil or name == "" then
    log_once("nosource", obs.LOG_WARNING, "no text source name configured")
    return false
  end

  local src = obs.obs_get_source_by_name(name)
  if src == nil then
    log_once("missing:" .. name, obs.LOG_WARNING,
      "text source '" .. name .. "' not found — create a Text source with that exact name")
    return false
  end
  log_clear("missing:" .. name)

  if obs.obs_source_get_id then
    local id = obs.obs_source_get_id(src)
    if id and not TEXT_SOURCE_IDS[id] then
      log_once("badtype:" .. name, obs.LOG_WARNING,
        "'" .. name .. "' is a '" .. tostring(id) .. "' source, not a Text source — nothing will render")
    end
  end

  local idle = is_idle(st)
  local text = idle and cfg.idle_text or apply_template(cfg.template, build_vals(st))

  if text ~= last_text then
    local settings = obs.obs_source_get_settings(src)
    obs.obs_data_set_string(settings, "text", text)
    obs.obs_source_update(src, settings)
    obs.obs_data_release(settings)
    last_text = text
  end

  if cfg.hide_when_idle and obs.obs_source_set_enabled then
    obs.obs_source_set_enabled(src, not idle)
  end

  obs.obs_source_release(src)
  return true
end

-- ===========================================================================
-- poll loop
-- ===========================================================================

tick_once = function()
  local body, err = http_get(cfg.url)
  if not body then
    -- Deliberately leave the source untouched on a transient failure: a
    -- dropped poll should not blank the overlay mid-stream.
    log_once("fetch", obs.LOG_WARNING, "poll failed: " .. tostring(err))
    return false
  end
  log_clear("fetch")

  local ok, state = pcall(json_decode, body)
  if not ok or type(state) ~= "table" then
    log_once("json", obs.LOG_WARNING, "could not parse bridge response: " .. tostring(state))
    return false
  end
  log_clear("json")

  return push_to_source(state)
end

restart_timer = function()
  if timer_fn then
    obs.timer_remove(timer_fn)
    timer_fn = nil
  end
  timer_fn = function() tick_once() end
  obs.timer_add(timer_fn, cfg.interval_ms)
end

-- ===========================================================================
-- settings plumbing
-- ===========================================================================

apply_settings = function(settings)
  local function str(key, fallback)
    local v = obs.obs_data_get_string(settings, key)
    if v == nil or v == "" then return fallback end
    return v
  end

  cfg.url         = str("url", DEFAULT_URL)
  cfg.source_name = str("source_name", DEFAULT_SOURCE)
  cfg.template    = str("template", DEFAULT_TEMPLATE)

  local idle = obs.obs_data_get_string(settings, "idle_text")
  cfg.idle_text = idle or ""

  cfg.hide_when_idle = obs.obs_data_get_bool(settings, "hide_when_idle")

  local n = obs.obs_data_get_int(settings, "interval_ms")
  if n and n >= 250 then cfg.interval_ms = n else cfg.interval_ms = DEFAULT_INTERVAL end

  last_text = nil -- force a rewrite after any settings change
end

-- ===========================================================================
-- OBS script entry points
-- ===========================================================================

function script_description()
  return [[WeebHub Now Playing
Polls the WeebHub local bridge and writes the current title, episode and
progress into a Text source in your scene.

Needs the bridge running (python3 bridge/weebhub_bridge.py --demo to test).
Set "Text source name" to the exact name of a Text source in your scene.
For the styled card with cover art, use overlay/weebhub-overlay.html as a
Browser Source instead — see TUTORIAL.md.]]
end

local function on_test_connection(props, prop)
  local body, err = http_get(cfg.url)
  if not body then
    obs.obs_log(obs.LOG_WARNING, "[weebhub] test connection FAILED: " .. tostring(err))
    return false
  end
  local ok, st = pcall(json_decode, body)
  if not ok or type(st) ~= "table" then
    obs.obs_log(obs.LOG_WARNING, "[weebhub] reached the bridge but the response was not JSON")
    return false
  end
  obs.obs_log(obs.LOG_INFO, string.format(
    "[weebhub] connection OK — %s ep %s (%s)",
    tostring(st.anime_title or "?"), tostring(st.episode or "?"), tostring(st.playback_state or "?")))
  return false
end

function script_properties()
  local props = obs.obs_properties_create()
  local multiline = obs.OBS_TEXT_MULTILINE or obs.OBS_TEXT_DEFAULT

  obs.obs_properties_add_text(props, "url", "Bridge URL", obs.OBS_TEXT_DEFAULT)
  obs.obs_properties_add_text(props, "source_name", "Text source name (exact)", obs.OBS_TEXT_DEFAULT)
  obs.obs_properties_add_text(props, "template", "Template", multiline)
  obs.obs_properties_add_text(props, "idle_text", "Text when nothing is playing", multiline)
  obs.obs_properties_add_bool(props, "hide_when_idle", "Hide the source when nothing is playing")
  obs.obs_properties_add_int(props, "interval_ms", "Poll interval (ms)", 250, 10000, 250)
  obs.obs_properties_add_button(props, "test_connection", "Test connection", on_test_connection)
  return props
end

function script_defaults(settings)
  obs.obs_data_set_default_string(settings, "url", DEFAULT_URL)
  obs.obs_data_set_default_string(settings, "source_name", DEFAULT_SOURCE)
  obs.obs_data_set_default_string(settings, "template", DEFAULT_TEMPLATE)
  obs.obs_data_set_default_string(settings, "idle_text", "")
  obs.obs_data_set_default_bool(settings, "hide_when_idle", true)
  obs.obs_data_set_default_int(settings, "interval_ms", DEFAULT_INTERVAL)
end

function script_update(settings)
  apply_settings(settings)
  restart_timer()
end

function script_load(settings)
  apply_settings(settings)

  local ok, pipe = pcall(io.popen, "curl --version")
  if not ok or not pipe then
    obs.obs_log(obs.LOG_ERROR, "[weebhub] could not run curl — install curl or put it on PATH; the plugin cannot poll without it")
  else
    local out = pipe:read("*a") or ""
    pipe:close()
    if not out:find("curl") then
      obs.obs_log(obs.LOG_ERROR, "[weebhub] 'curl --version' produced no output �� curl may be missing from PATH")
    end
  end

  tick_once()      -- paint immediately instead of waiting one interval
  restart_timer()
end

function script_unload()
  if timer_fn then
    obs.timer_remove(timer_fn)
    timer_fn = nil
  end
end

-- ===========================================================================
-- offline test hooks (tests/plugin_harness.lua). Inert inside OBS.
-- ===========================================================================

if _G.__WEEBHUB_TEST then
  _G.__WEEBHUB_TEST.decode_json    = json_decode
  _G.__WEEBHUB_TEST.format_time    = format_time
  _G.__WEEBHUB_TEST.make_bar       = make_bar
  _G.__WEEBHUB_TEST.apply_template = apply_template
  _G.__WEEBHUB_TEST.build_vals     = build_vals
  _G.__WEEBHUB_TEST.is_idle        = is_idle
  _G.__WEEBHUB_TEST.push_state     = push_to_source
  _G.__WEEBHUB_TEST.tick           = tick_once
  _G.__WEEBHUB_TEST.cfg            = cfg
  _G.__WEEBHUB_TEST.reset          = function() last_text = nil; warned = {} end
end