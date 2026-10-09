--[[
  Claude Ping — a big, hard-to-miss reminder when a Claude session is done or needs you.

  Where the signals come from:
    • Claude Code (VS Code, terminal, background `claude` sessions) → hook → POST /code
    • Safari / Chrome (claude.ai)                                   → userscript → POST /browser
    • Claude Desktop, Chat and Code tabs → watched through macOS Accessibility, ONLY after you
      leave the Claude window (Desktop Code sessions run in a VM, so hooks never reach the Mac)

  What shows up:
    • A thick colored border around every screen (click-through, never blocks your work)
    • A big card at the top listing the sessions waiting for you → click a row to jump there
    • A count in the menu bar, plus a re-reminder every few minutes until you respond
    • A usage meter "36% · 2h 10m" in the menu bar (5-hour limit + time until it resets;
      refreshed once each time Claude finishes)
    • Green = done · Orange = Claude asks / needs permission · Red = stopped with an error

  Shortcuts:  ⌃⌥⌘C jump to the newest   ·   ⌃⌥⌘X dismiss all
]]

local M = {}

-- ───────────────────────────── Settings ─────────────────────────────
M.config = {
  port           = 47823,
  borderWidth    = 14,       -- border thickness at the screen edges
  cardWidth      = 660,      -- width of the card at the top
  maxRows        = 5,        -- max rows on the card (the rest are in the menu bar)
  sound          = "Glass",  -- macOS system sound (Glass, Ping, Hero, Submarine...)
  remindMinutes  = 5,        -- blink + sound again if you haven't responded; 0 = off
  quietIfLooking = true,     -- if you are already looking at that window, just a small toast
  hotkeyMods     = { "ctrl", "alt", "cmd" },
  jumpKey        = "C",
  dismissKey     = "X",
  -- Usage meter in the menu bar: "% of the 5-hour limit · time until reset"
  usage = {
    warnAt   = 75,           -- text turns orange from this percent
    dangerAt = 90,           -- text turns red + one alert from this percent
  },
  desktopChat = {
    pollSeconds = 2.5,       -- check interval, ONLY while Claude Desktop is still answering
    nodeBudget  = 4000,      -- max UI elements inspected per check
    maxMinutes  = 45,        -- stop watching after this, no matter what
    -- button labels in the Claude Desktop chat box (lowercase; adjust if your UI language differs)
    stopLabels  = { "stop response", "stop generating", "hentikan respons" },
    sendLabels  = { "send message", "kirim pesan" },
  },
}

-- ───────────────────────────── Constants ─────────────────────────────
local CLAUDE_DESKTOP = "com.anthropic.claudefordesktop"
local HAMMERSPOON    = hs.processInfo.bundleID

local APP_NAMES = {
  ["com.microsoft.VSCode"]     = "VS Code",
  [CLAUDE_DESKTOP]             = "Claude Desktop",
  ["com.apple.Terminal"]       = "Terminal",
  ["com.googlecode.iterm2"]    = "iTerm",
  ["com.mitchellh.ghostty"]    = "Ghostty",
  ["dev.warp.Warp-Stable"]     = "Warp",
  ["com.apple.Safari"]         = "Safari",
  ["com.google.Chrome"]        = "Chrome",
}

local TERMINALS = {
  ["com.apple.Terminal"]    = true,
  ["com.googlecode.iterm2"] = true,
  ["com.mitchellh.ghostty"] = true,
  ["dev.warp.Warp-Stable"]  = true,
  ["net.kovidgoyal.kitty"]  = true,
  ["com.github.wez.wezterm"] = true,
}

-- Editors where Claude Code usually runs (integrated terminal / extension).
local EDITORS = {
  "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", -- Cursor
  "com.exafunction.windsurf", "dev.zed.Zed",
}

local TERM_PROGRAM_TO_BUNDLE = {
  Apple_Terminal  = "com.apple.Terminal",
  ["iTerm.app"]   = "com.googlecode.iterm2",
  vscode          = "com.microsoft.VSCode",
  ghostty         = "com.mitchellh.ghostty",
  WarpTerminal    = "dev.warp.Warp-Stable",
  WezTerm         = "com.github.wez.wezterm",
}

local COLORS = {
  done  = { red = 0.13, green = 0.77, blue = 0.37, alpha = 1 },
  ask   = { red = 0.96, green = 0.62, blue = 0.04, alpha = 1 },
  error = { red = 0.94, green = 0.27, blue = 0.27, alpha = 1 },
}
local ICONS   = { done = "✅", ask = "🟠", error = "🔴" }
local RANK    = { done = 1, error = 2, ask = 3 }
local WHITE   = { white = 1, alpha = 1 }
local GREY    = { white = 1, alpha = 0.62 }
local CARD_BG = { red = 0.08, green = 0.08, blue = 0.10, alpha = 0.97 }
local ROW_BG  = { white = 1, alpha = 0.07 }

-- ───────────────────────────── State ─────────────────────────────
M.markers = {}   -- newest first
M.prompts = {}   -- session_id → snippet of your last prompt
M.borders = {}
M.card    = nil
M.lastFront = nil   -- the last app you used (other than Hammerspoon)
M.desk    = { timer = nil, sawBusy = false, idle = 0, blind = 0, axApp = nil }
M.state   = {
  dnd         = hs.settings.get("claudePing.dnd") == true,
  sound       = hs.settings.get("claudePing.sound") ~= false,
  desktopChat = hs.settings.get("claudePing.desktopChat") ~= false,
  usageMeter  = hs.settings.get("claudePing.usageMeter") ~= false,
}
-- { five_hour = { pct, resets }, seven_day = { pct, resets }, updated }  (kept across reloads)
M.usage   = hs.settings.get("claudePing.usage") or {}

-- ───────────────────────────── Helper ─────────────────────────────
local function log(...) print("[claude-ping]", ...) end

-- One-shot timer whose reference is kept so the garbage collector does not drop it.
local pending = {}
local function later(delay, fn)
  local t
  t = hs.timer.doAfter(delay, function()
    pending[t] = nil
    local ok, err = pcall(fn)
    if not ok then log("error:", err) end
  end)
  pending[t] = true
  return t
end

local function basename(p)
  if type(p) ~= "string" or p == "" then return "" end
  p = p:gsub("/+$", "")
  return p:match("([^/]+)$") or p
end

local function snippet(s, n)
  if type(s) ~= "string" then return nil end
  s = s:gsub("%s+", " ")
  s = s:gsub("^ ", ""):gsub(" $", "")
  if s == "" then return nil end
  n = n or 70
  local len = utf8.len(s)
  if len and len > n then
    local cut = utf8.offset(s, n + 1)
    if cut then s = s:sub(1, cut - 1) .. "…" end
  end
  return s
end

-- Strip the most common markdown marks so the card reads cleanly.
local function plain(s)
  if type(s) ~= "string" then return s end
  return (s:gsub("%*%*", ""):gsub("__", ""):gsub("`", ""):gsub("^%s*#+%s*", ""))
end

local function ago(t)
  local d = os.time() - (t or os.time())
  if d < 60 then return "just now" end
  if d < 3600 then return math.floor(d / 60) .. " min ago" end
  return math.floor(d / 3600) .. " h ago"
end

local function header(headers, name)
  if type(headers) ~= "table" then return nil end
  local want = name:lower()
  for k, v in pairs(headers) do
    if type(k) == "string" and k:lower() == want then return v end
  end
  return nil
end

-- Project folder names from the deepest one up (stopping at $HOME), because a session can
-- start in a subfolder while the VS Code window has the parent folder open.
local function projectNames(project)
  local names, home = {}, os.getenv("HOME") or ""
  local p = (type(project) == "string" and project or ""):gsub("/+$", "")
  while p ~= "" and p ~= home and #names < 4 do
    names[#names + 1] = basename(p)
    p = p:match("^(.*)/[^/]*$") or ""
  end
  return names
end

-- VS Code titles look like "file — folder" or "folder (Workspace)". Match whole segments so
-- a project named "challenge" does not match a window named "challenge4".
local function titleHasName(title, name)
  for seg in (title .. " — "):gmatch("(.-) — ") do
    if seg == name or seg == name .. " (Workspace)" then return true end
  end
  return false
end

-- The window that best matches the project; otherwise a partial match on the deepest name.
local function matchWindow(wins, project)
  local names = projectNames(project)
  for _, name in ipairs(names) do
    for _, w in ipairs(wins) do
      if titleHasName(w:title() or "", name) then return w end
    end
  end
  if names[1] then
    for _, w in ipairs(wins) do
      if (w:title() or ""):find(names[1], 1, true) then return w end
    end
  end
  -- Session started in a parent folder (e.g. ~/project) while the window has a subfolder open.
  local root = type(project) == "string" and project:gsub("/+$", "") or ""
  if root ~= "" and root ~= os.getenv("HOME") then
    for _, w in ipairs(wins) do
      for seg in ((w:title() or "") .. " — "):gmatch("(.-) — ") do
        seg = seg:gsub(" %(Workspace%)$", "")
        if seg ~= "" and not seg:find("/", 1, true)
           and hs.fs.attributes(root .. "/" .. seg, "mode") == "directory" then
          return w
        end
      end
    end
  end
  return nil
end

-- Find the project window across all open editors & terminals (preferBid is checked first).
-- Used for background `claude` sessions, which don't know which app you view them in.
local function findProjectWindow(project, preferBid)
  if basename(project) == "" then return nil end
  local order, seen = {}, {}
  local function add(bid) if bid and not seen[bid] then seen[bid] = true; order[#order + 1] = bid end end
  add(preferBid)
  for _, bid in ipairs(EDITORS) do add(bid) end
  for bid in pairs(TERMINALS) do add(bid) end
  for _, bid in ipairs(order) do
    local app = hs.application.get(bid)
    if app then
      local w = matchWindow(app:allWindows(), project)
      if w then return w, bid end
    end
  end
  return nil
end

local function appName(bid)
  if not bid or bid == "" then return "Claude Code" end
  if APP_NAMES[bid] then return APP_NAMES[bid] end
  local ok, name = pcall(hs.application.nameForBundleID, bid)
  return (ok and name) or bid
end

local function playSound()
  if not M.state.sound or not M.config.sound then return end
  local s = hs.sound.getByName(M.config.sound)
  if s then s:play() end
end

local function mostUrgent()
  local best = "done"
  for _, m in ipairs(M.markers) do
    if (RANK[m.kind] or 0) > RANK[best] then best = m.kind end
  end
  return best
end

local function indexOfKey(key)
  for i, m in ipairs(M.markers) do
    if m.key == key then return i end
  end
  return nil
end

local function removeByKey(key)
  local i = indexOfKey(key)
  if i then
    table.remove(M.markers, i)
    M.render()
  end
end

-- ───────────────────────────── Drawing ─────────────────────────────
local function makeBorder(scr, color)
  local f = scr:fullFrame()
  local w = M.config.borderWidth
  local glow = {}
  for k, v in pairs(color) do glow[k] = v end
  glow.alpha = 0.28
  local c = hs.canvas.new({ x = f.x, y = f.y, w = f.w, h = f.h })
  if not c then return nil end
  -- The stroke is centered on the canvas edge, so half is clipped: visible width = w.
  c:appendElements({
    { type = "rectangle", action = "stroke", strokeColor = glow,  strokeWidth = w * 4,
      frame = { x = 0, y = 0, w = f.w, h = f.h } },
    { type = "rectangle", action = "stroke", strokeColor = color, strokeWidth = w * 2,
      frame = { x = 0, y = 0, w = f.w, h = f.h } },
  })
  -- Without a mouseCallback this canvas is click-through (hs.canvas default).
  c:behaviorAsLabels({ "canJoinAllSpaces", "stationary", "fullScreenAuxiliary" })
  c:level("overlay")
  c:show(0.15)
  return c
end

local function headerText()
  local n = #M.markers
  if n == 1 then
    local k = M.markers[1].kind
    if k == "ask" then return "🟠  Claude needs your input" end
    if k == "error" then return "🔴  Claude stopped with an error" end
    return "✅  Claude is done — your turn"
  end
  return string.format("%s  %d Claude sessions are waiting", ICONS[mostUrgent()], n)
end

-- On macOS 27 a click on a canvas still activates Hammerspoon even with clickActivating(false),
-- so after a click that doesn't jump (✕, empty area) focus is handed back to your app.
local function giveBackFocus()
  later(0.05, function()
    local front = hs.application.frontmostApplication()
    if front and front:bundleID() == HAMMERSPOON and M.lastFront and M.lastFront:isRunning() then
      M.lastFront:activate()
    end
  end)
end

local function makeCard(scr, accent)
  local cfg = M.config
  local sf = scr:frame()
  local W = math.min(cfg.cardWidth, sf.w - 40)
  local rows = math.min(#M.markers, cfg.maxRows)
  local more = #M.markers - rows
  local PAD, HEAD, ROW, FOOT = 18, 56, 58, 30
  local H = PAD + HEAD + rows * ROW + (more > 0 and 24 or 0) + FOOT

  local c = hs.canvas.new({ x = sf.x + (sf.w - W) / 2, y = sf.y + 10, w = W, h = H })
  if not c then return nil end

  local els = {
    { type = "rectangle", action = "fill", fillColor = CARD_BG,
      roundedRectRadii = { xRadius = 18, yRadius = 18 }, frame = { x = 0, y = 0, w = W, h = H } },
    { type = "rectangle", action = "stroke", strokeColor = accent, strokeWidth = 4,
      roundedRectRadii = { xRadius = 17, yRadius = 17 }, frame = { x = 2, y = 2, w = W - 4, h = H - 4 } },
    { type = "text", text = headerText(), textFont = "HelveticaNeue-Bold", textSize = 26,
      textColor = WHITE, textLineBreak = "truncateTail",
      frame = { x = PAD, y = PAD - 2, w = W - PAD * 2 - 52, h = HEAD } },
    -- ✕ is the one way to "skip": it closes all markers.
    { id = "close", type = "rectangle", action = "fill", fillColor = { white = 1, alpha = 0.16 },
      roundedRectRadii = { xRadius = 20, yRadius = 20 }, trackMouseUp = true,
      frame = { x = W - PAD - 40, y = PAD - 2, w = 40, h = 40 } },
    { type = "text", text = "✕", textSize = 22, textColor = WHITE,
      textAlignment = "center", frame = { x = W - PAD - 40, y = PAD + 4, w = 40, h = 30 } },
  }

  for i = 1, rows do
    local m = M.markers[i]
    local y = PAD + HEAD + (i - 1) * ROW
    local rowH = ROW - 8
    els[#els + 1] = { id = "row" .. i, type = "rectangle", action = "fill", fillColor = ROW_BG,
      roundedRectRadii = { xRadius = 12, yRadius = 12 }, trackMouseUp = true,
      frame = { x = PAD - 6, y = y, w = W - (PAD - 6) * 2, h = rowH } }
    els[#els + 1] = { type = "circle", action = "fill", fillColor = COLORS[m.kind] or COLORS.done,
      center = { x = PAD + 10, y = y + rowH / 2 }, radius = 7 }
    els[#els + 1] = { type = "text", text = m.title or "Claude", textFont = "HelveticaNeue-Medium",
      textSize = 17, textColor = WHITE, textLineBreak = "truncateTail",
      frame = { x = PAD + 28, y = y + 5, w = W - PAD * 2 - 28 - 110, h = 24 } }
    els[#els + 1] = { type = "text", text = ago(m.created), textSize = 13, textColor = GREY,
      textAlignment = "right", frame = { x = W - PAD - 112, y = y + 8, w = 104, h = 20 } }
    els[#els + 1] = { type = "text", text = m.detail or "", textSize = 14, textColor = GREY,
      textLineBreak = "truncateTail", frame = { x = PAD + 28, y = y + 27, w = W - PAD * 2 - 36, h = 20 } }
  end

  if more > 0 then
    els[#els + 1] = { type = "text", text = string.format("+%d more in the menu bar", more),
      textSize = 13, textColor = GREY, frame = { x = PAD + 28, y = PAD + HEAD + rows * ROW, w = W - PAD * 2, h = 20 } }
  end

  els[#els + 1] = { type = "text", textSize = 12, textColor = { white = 1, alpha = 0.45 },
    text = "Click a row to jump there  ·  Click ✕ to skip",
    textAlignment = "center", frame = { x = PAD, y = H - FOOT + 4, w = W - PAD * 2, h = 18 } }

  c:appendElements(els)
  c:behaviorAsLabels({ "canJoinAllSpaces", "stationary", "fullScreenAuxiliary" })
  c:level("overlay")
  c:clickActivating(false)
  c:canvasMouseEvents(false, true, false, false)   -- clicks on empty areas are reported too
  c:mouseCallback(function(_, msg, id)
    if msg ~= "mouseUp" then return end
    local idx = tonumber(tostring(id):match("^row(%d+)$"))
    local m = idx and M.markers[idx]
    if m and m.app then M.jump(m) return end   -- jump: focus is meant to move to that session
    if m then M.jump(m) elseif id == "close" then M.dismissAll() end
    giveBackFocus()
  end)
  c:show(0.15)
  return c
end

local function updateMenubar()
  if not M.menubar then return end
  local n = #M.markers
  if n == 0 then
    M.menubar:setTitle(M.state.dnd and "◌ zz" or "◌")
  else
    M.menubar:setTitle(ICONS[mostUrgent()] .. " " .. n)
  end
end

local function syncRemind()
  local need = #M.markers > 0 and not M.state.dnd and (M.config.remindMinutes or 0) > 0
  if need and not M.remindTimer then
    M.remindTimer = hs.timer.doEvery(M.config.remindMinutes * 60, function()
      if #M.markers > 0 and not M.state.dnd then
        M.render()
        M.pulse()
        playSound()
      end
    end)
  elseif not need and M.remindTimer then
    M.remindTimer:stop()
    M.remindTimer = nil
  end
end

function M.render()
  updateMenubar()
  for _, c in ipairs(M.borders) do c:delete() end
  M.borders = {}
  if M.card then M.card:delete() M.card = nil end
  syncRemind()
  if #M.markers == 0 or M.state.dnd then return end

  local color = COLORS[mostUrgent()]
  for _, scr in ipairs(hs.screen.allScreens()) do
    local b = makeBorder(scr, color)
    if b then M.borders[#M.borders + 1] = b end
  end
  M.card = makeCard(hs.mouse.getCurrentScreen() or hs.screen.mainScreen(), color)
end

-- A short blink (8 times, then still) — no animation keeps running.
function M.pulse()
  if M.pulseTimer then M.pulseTimer:stop() end
  local n = 0
  M.pulseTimer = hs.timer.doEvery(0.28, function()
    n = n + 1
    local a = (n % 2 == 1) and 0.2 or 1.0
    for _, b in ipairs(M.borders) do b:alpha(a) end
    if n >= 8 then
      M.pulseTimer:stop()
      M.pulseTimer = nil
      for _, b in ipairs(M.borders) do b:alpha(1) end
    end
  end)
end

-- ───────────────────────────── Markers ─────────────────────────────
function M.addMarker(m)
  m.created = m.created or os.time()
  -- Claude Desktop: avoid duplicates between the Chat watcher and hooks from the Code tab.
  if m.app == CLAUDE_DESKTOP then
    for i = #M.markers, 1, -1 do
      local o = M.markers[i]
      if o.app == CLAUDE_DESKTOP and o.key ~= m.key and math.abs(m.created - o.created) <= 20 then
        if m.source == "desktop" then return end
        if o.source == "desktop" then table.remove(M.markers, i) end
      end
    end
  end
  local i = indexOfKey(m.key)
  if i then table.remove(M.markers, i) end
  table.insert(M.markers, 1, m)
  playSound()
  M.render()
  M.pulse()
end

local function isLooking(m)
  if not M.config.quietIfLooking or not m.app then return false end
  local front = hs.application.frontmostApplication()
  if not front or front:bundleID() ~= m.app then return false end
  if m.app == CLAUDE_DESKTOP then return true end
  if basename(m.project) == "" then return true end
  local win = front:focusedWindow()
  return win ~= nil and matchWindow({ win }, m.project) ~= nil
end

local function notify(m)
  if isLooking(m) then
    removeByKey(m.key)
    hs.alert.show(ICONS[m.kind] .. "  " .. (m.title or "Claude"), { textSize = 18, radius = 10 },
      hs.screen.mainScreen(), 2.5)
    return
  end
  M.addMarker(m)
end

function M.dismissAll()
  M.markers = {}
  M.render()
end

function M.test()
  M.addMarker({
    key = "test:" .. tostring(hs.timer.secondsSinceEpoch()), kind = "done", source = "test",
    title = "Claude Ping test",
    detail = "If you can see this, it works 🎉  Click ✕ to skip.",
  })
end

-- ───────────────────────────── Jump to a session ─────────────────────────────
local function focusBrowserTab(m)
  local url = (m.url or ""):gsub("[?#].*$", "")
  local esc = (url:gsub("\\", "\\\\"):gsub('"', '\\"'))
  local script
  if m.browser == "chrome" then
    script = string.format([[
tell application "Google Chrome"
  repeat with w in windows
    set i to 0
    repeat with t in tabs of w
      set i to i + 1
      if (URL of t) contains "%s" then
        set active tab index of w to i
        set index of w to 1
        activate
        return true
      end if
    end repeat
  end repeat
  activate
end tell
return false]], esc)
  else
    script = string.format([[
tell application "Safari"
  repeat with w in windows
    repeat with t in tabs of w
      if (URL of t) contains "%s" then
        set current tab of w to t
        set index of w to 1
        activate
        return true
      end if
    end repeat
  end repeat
  activate
end tell
return false]], esc)
  end
  local ok, _, err = hs.osascript.applescript(script)
  if not ok then log("could not focus tab:", hs.inspect(err)) end
end

function M.jump(m)
  if not m then return end
  local i = indexOfKey(m.key)
  if i then table.remove(M.markers, i) end
  M.render()

  if m.source == "browser" then focusBrowserTab(m) return end

  local app = m.app and hs.application.get(m.app)
  local w = app and matchWindow(app:allWindows(), m.project)
  -- Search again on click: the window may have moved screens, closed, or just opened.
  if not w and m.source == "code" then w = findProjectWindow(m.project, m.app) end
  log("jump:", m.title or "?", "→", w and w:title() or (m.app or "not found"))
  if w then
    w:focus()
    -- macOS sometimes raises a different window of the same app (common when the window
    -- is on another screen). Check once and retry if it missed.
    later(0.3, function()
      local f = hs.window.focusedWindow()
      if not f or f:id() ~= w:id() then w:focus() end
    end)
    return
  end
  if app then app:activate() return end
  if m.app then hs.application.launchOrFocusByBundleID(m.app) return end
  hs.alert.show("Can’t find the window for " .. (basename(m.project) ~= "" and basename(m.project) or "this session"), 3)
end

-- If you switch to that window yourself, its marker disappears automatically.
local function clearForApp(app)
  local bid = app and app:bundleID()
  if not bid or #M.markers == 0 then return end
  later(0.4, function()
    local front = hs.application.frontmostApplication()
    if not front or front:bundleID() ~= bid then return end
    local win = front:focusedWindow()
    local changed = false
    for i = #M.markers, 1, -1 do
      local m = M.markers[i]
      if m.app == bid and m.source ~= "browser" then
        if bid == CLAUDE_DESKTOP or basename(m.project) == ""
           or (win and matchWindow({ win }, m.project)) then
          table.remove(M.markers, i)
          changed = true
        end
      end
    end
    if changed then M.render() end
  end)
end

-- ───────────────────────────── Claude Desktop watcher ─────────────────────────────
-- Electron only exposes its accessibility tree when asked through AXManualAccessibility.
-- While it is on, Claude keeps that tree updated as text streams in, so it is only turned
-- on while watching. The tree is ready about 2 s after turning it on.
local function setDesktopAX(app, on)
  if not app or not app:isRunning() then M.desk.axApp = nil return end
  pcall(function()
    hs.axuielement.applicationElement(app):setAttributeValue("AXManualAccessibility", on)
  end)
  M.desk.axApp = on and app or nil
end

local function claudeWindow(app)
  local ax = hs.axuielement.applicationElement(app)
  if not ax then return nil end
  local win = ax:attributeValue("AXMainWindow") or ax:attributeValue("AXFocusedWindow")
  if not win then
    local wins = ax:attributeValue("AXWindows")
    if type(wins) == "table" then win = wins[1] end
  end
  return win or ax   -- if the window can't be read, walk from the app element instead
end

local function axLabel(el)
  local d = el:attributeValue("AXDescription") or ""
  local t = el:attributeValue("AXTitle") or ""
  local h = el:attributeValue("AXHelp") or ""
  return (tostring(d) .. " | " .. tostring(t) .. " | " .. tostring(h)):lower()
end

local function matchesAny(s, list)
  for _, p in ipairs(list) do
    if s:find(p, 1, true) then return true end
  end
  return false
end

-- Walk buttons from the BOTTOM up (the chat box is at the bottom), with an element budget.
local function walkButtons(root, budget, visit)
  local stack, visited = { root }, 0
  while #stack > 0 and visited < budget do
    local el = table.remove(stack)
    visited = visited + 1
    if el:attributeValue("AXRole") == "AXButton" then
      local r = visit(el)
      if r ~= nil then return r end
    end
    local kids = el:attributeValue("AXChildren")
    if type(kids) == "table" then
      for i = 1, #kids do stack[#stack + 1] = kids[i] end
    end
  end
  return nil
end

local function desktopState(app)
  local win = claudeWindow(app)
  if not win then return nil end
  local cfg = M.config.desktopChat
  return walkButtons(win, cfg.nodeBudget, function(el)
    local label = axLabel(el)
    if matchesAny(label, cfg.stopLabels) then return "busy" end
    if matchesAny(label, cfg.sendLabels) then return "idle" end
    return nil
  end)
end

local function stopDesktopWatch()
  if M.desk.timer then M.desk.timer:stop() end
  M.desk.timer = nil
  M.desk.sawBusy = false
  M.desk.idle = 0
  M.desk.blind = 0
  if M.desk.axApp then setDesktopAX(M.desk.axApp, false) end
end

function M.onDesktopDone(app)
  M.fetchUsage()
  local front = hs.application.frontmostApplication()
  if front and front:bundleID() == CLAUDE_DESKTOP then return end -- you are already back
  local win = app:mainWindow()
  local t = win and win:title() or ""
  local detail = "Finished responding"
  if t ~= "" and t ~= "Claude" then detail = "“" .. (snippet(t, 80) or t) .. "”" end
  -- Generic title because the Code tab is detected this way too (its sessions run in a VM).
  M.addMarker({
    key = "desktop:chat", kind = "done", source = "desktop", app = CLAUDE_DESKTOP,
    project = "", title = "Claude Desktop", detail = detail,
  })
end

local function startDesktopWatch(app)
  stopDesktopWatch()
  if not M.state.desktopChat then return end
  setDesktopAX(app, true)
  local cfg = M.config.desktopChat
  local started, tries = os.time(), 0
  M.desk.timer = hs.timer.doEvery(cfg.pollSeconds, function()
    tries = tries + 1
    if not app:isRunning() or os.time() - started > cfg.maxMinutes * 60 then
      stopDesktopWatch()
      return
    end
    local ok, st = pcall(desktopState, app)
    if not ok then
      log("desktop watcher:", st)
      st = nil
    end
    -- nil = buttons unreadable (the tree is being rebuilt, which happens for ~20 s while
    -- answering). That is NOT "done"; only the send button counts as done.
    if st == "busy" then
      M.desk.sawBusy = true
      M.desk.idle = 0
      M.desk.blind = 0
    elseif st == "idle" then
      M.desk.blind = 0
      if M.desk.sawBusy then
        M.desk.idle = M.desk.idle + 1
        if M.desk.idle >= 2 then
          stopDesktopWatch()
          M.onDesktopDone(app)
        end
      elseif tries >= 2 then
        stopDesktopWatch()   -- Claude wasn't answering when you left
      end
    else
      -- Buttons unreadable: never seen any (~20 s), or 60 s in a row (e.g. the window
      -- was closed) → stop instead of watching for nothing.
      M.desk.blind = M.desk.blind + 1
      if (not M.desk.sawBusy and tries >= 8) or M.desk.blind >= 24 then stopDesktopWatch() end
    end
  end)
end

-- Lists button labels + the cost of one check. noConsole = don't open the Console window.
function M.debugDesktop(noConsole)
  local app = hs.application.get(CLAUDE_DESKTOP)
  if not app then hs.alert.show("Claude Desktop isn’t open") return end
  local watching = M.desk.timer ~= nil
  if not watching then setDesktopAX(app, true) end
  later(watching and 0 or 2.5, function()
    local win = claudeWindow(app)
    if not win then
      hs.alert.show("Can’t read the Claude window — check Accessibility access for Hammerspoon")
      return
    end
    local labels = {}
    walkButtons(win, 8000, function(el)
      labels[#labels + 1] = axLabel(el)
      if #labels >= 120 then return true end
      return nil
    end)
    local t0 = hs.timer.absoluteTime()
    local st = desktopState(app)
    local cost = (hs.timer.absoluteTime() - t0) / 1e6
    if not M.desk.timer then setDesktopAX(app, false) end
    print("[claude-ping] Buttons in the Claude Desktop window (bottom to top):")
    for i, l in ipairs(labels) do print(string.format("  %3d  %s", i, l)) end
    print(string.format("[claude-ping] Current state: %s (one check: %.0f ms)", tostring(st), cost))
    if not noConsole then hs.openConsole() end
  end)
end

-- ───────────────────────────── Incoming signals ─────────────────────────────
local function resolveHost(headers)
  local bid = header(headers, "X-Ping-App") or ""
  local hints = header(headers, "X-Ping-Hints") or ""
  local term = hints:match("term=([^;]*)") or ""
  local entry = (hints:match("entry=([^;]*)") or ""):lower()
  if (hints:find("vscode=1", 1, true) or entry:find("vscode", 1, true)) and (bid == "" or TERMINALS[bid]) then
    bid = "com.microsoft.VSCode"
  end
  if bid == "" and entry:find("desktop", 1, true) then bid = CLAUDE_DESKTOP end
  -- Sessions without __CFBundleIdentifier (e.g. background `claude` sessions): look for a
  -- GUI app in the parent process chain sent by the hook script.
  -- (applicationForPID is not used: it logs an ERROR to the Console for every non-app PID.)
  local pids = header(headers, "X-Ping-Pids") or ""
  if bid == "" and pids:find("%d") then
    local byPid = {}
    for _, a in ipairs(hs.application.runningApplications()) do byPid[a:pid()] = a end
    for pid in pids:gmatch("%d+") do
      local app = byPid[tonumber(pid)]
      if app and app:kind() == 1 and app:bundleID() then bid = app:bundleID() break end
    end
  end
  if bid == "" then bid = TERM_PROGRAM_TO_BUNDLE[term] or "" end
  local fromEnv = (header(headers, "X-Ping-App") or "") ~= "" or hints:find("vscode=1", 1, true) ~= nil
  if bid == "" then return nil, fromEnv end
  return bid, fromEnv
end

function M.handleCode(headers, data)
  local ev = header(headers, "X-Ping-Event") or "stop"
  if ev == "stop" or ev == "error" then M.fetchUsage() end
  local sid = tostring(data.session_id or "unknown")
  local key = "code:" .. sid

  if ev == "prompt" then
    -- Background task notifications also arrive via UserPromptSubmit; that is not your prompt.
    local p = type(data.prompt) == "string" and data.prompt or ""
    if not p:match("^%s*<task%-notification>") then M.prompts[sid] = snippet(p, 80) end
    removeByKey(key)        -- this session is running again → remove its marker
    return
  end
  -- Notification arrives ~6 s after AskUserQuestion for the same thing: don't play the sound
  -- twice, and don't replace the question text with a generic message.
  if ev == "notify" then
    local i = indexOfKey(key)
    if i and M.markers[i].kind == "ask" then return end
  end
  if ev == "end" then
    M.prompts[sid] = nil
    removeByKey(key)
    return
  end

  local app, fromEnv = resolveHost(headers)
  local project = header(headers, "X-Ping-Project")
  -- Header is not valid UTF-8 (accented folder name) → use cwd from the JSON body.
  if not project or project == "" or not utf8.len(project) then project = data.cwd or "" end
  -- A background `claude` session doesn't know which app you view it in (its process chain
  -- leads to the daemon, not your terminal). The window showing its project folder is more reliable.
  if not fromEnv then
    local _, wbid = findProjectWindow(project, app)
    if wbid then app = wbid end
  end
  local base = basename(project)
  local where = appName(app)
  local title = (base ~= "") and (where .. " · " .. base) or where
  local asked = M.prompts[sid] and ("“" .. M.prompts[sid] .. "”") or nil

  local kind, detail
  if ev == "stop" then
    kind = "done"
    detail = asked or snippet(plain(data.last_assistant_message), 90) or "Claude finished responding"
  elseif ev == "notify" then
    kind = "ask"
    detail = snippet(data.message, 90) or "Claude needs your permission or an answer"
  elseif ev == "ask" then
    kind = "ask"
    local qs = type(data.tool_input) == "table" and data.tool_input.questions or nil
    local q = (type(qs) == "table" and type(qs[1]) == "table") and qs[1].question or nil
    detail = snippet(q, 90) or "Claude asked you a question"
  elseif ev == "error" then
    kind = "error"
    local e = data.error_type or data.error or data.reason
    if type(e) ~= "string" then e = "unknown" end
    detail = "Stopped with an error: " .. e
  else
    return
  end

  notify({ key = key, kind = kind, source = "code", app = app, project = project,
           title = title, detail = detail })
end

function M.handleBrowser(data)
  local url = (type(data.url) == "string" and data.url or ""):gsub("[?#].*$", "")
  if url == "" then return end
  local key = "browser:" .. url
  if data.event == "seen" then removeByKey(key) return end
  M.fetchUsage()
  if data.event ~= "done" then return end

  local browser = data.browser == "chrome" and "chrome" or "safari"
  local bid = browser == "chrome" and "com.google.Chrome" or "com.apple.Safari"
  local title = type(data.title) == "string" and data.title:gsub("%s*[-–—]%s*Claude%s*$", "") or ""
  M.addMarker({
    key = key, kind = "done", source = "browser", browser = browser, url = url, app = bid,
    project = "", title = appName(bid) .. " · claude.ai",
    detail = (title ~= "" and title ~= "Claude") and ("“" .. (snippet(title, 80) or title) .. "”")
             or "Claude finished responding",
  })
end

local function onRequest(method, path, headers, body)
  if method == "GET" then return "claude-ping is running", 200, {} end
  if method ~= "POST" then return "", 405, {} end
  -- This custom header means ordinary web pages cannot trigger markers.
  if header(headers, "X-Claude-Ping") ~= "1" then return "forbidden", 403, {} end
  local ok, data = pcall(hs.json.decode, body or "")
  if not ok or type(data) ~= "table" then data = {} end
  local route = (path or ""):match("^/(%a+)") or ""
  later(0, function()
    if route == "code" then M.handleCode(headers, data)
    elseif route == "browser" then M.handleBrowser(data) end
  end)
  return "ok", 200, {}
end

local function onAppEvent(_, event, app)
  if not app then return end
  local ok, bid = pcall(function() return app:bundleID() end)
  if not ok or not bid then return end
  local W = hs.application.watcher
  if bid == CLAUDE_DESKTOP then
    if event == W.deactivated then
      startDesktopWatch(app)
    elseif event == W.activated then
      stopDesktopWatch()
    elseif event == W.terminated then
      stopDesktopWatch()
    end
  end
  if event == W.activated then
    if bid ~= HAMMERSPOON then M.lastFront = app end
    clearForApp(app)
  end
end

-- ───────────────────────────── Usage meter (menu bar) ─────────────────────────────
-- Numbers are fetched (claude-usage.sh --fetch) only right after Claude finishes anywhere,
-- when the menu opens, or at reset time; the server is never polled. Apart from that there is
-- only a once-a-minute timer that updates the time-left text in the menu bar.
local WINDOWS = { { key = "five_hour", long = "5-hour limit" },
                  { key = "seven_day", long = "Weekly limit" } }

local function pctColor(p)
  local u = M.config.usage
  if p >= u.dangerAt then return COLORS.error end
  if p >= u.warnAt then return COLORS.ask end
  return nil
end

local function untilText(t)
  local d = (t or 0) - os.time()
  if d <= 0 then return "now" end
  if d >= 86400 then return os.date("%a %H:%M", t) end
  local h, m = math.floor(d / 3600), math.floor(d % 3600 / 60)
  if h > 0 then return string.format("%d h %d min", h, m) end
  return m .. " min"
end

local function usageWindow(key)
  local w = M.usage[key]
  if type(w) ~= "table" or type(w.pct) ~= "number" then return nil end
  if w.resets and w.resets <= os.time() then return { pct = 0, resets = nil, wasReset = true } end
  return w
end

-- Compact time left for the menu bar: "2h 10m", "45m".
local function shortLeft(t)
  local d = (t or 0) - os.time()
  if d < 60 then return "<1m" end
  local h, m = math.floor(d / 3600), math.floor(d % 3600 / 60)
  if h > 0 then return string.format("%dh %02dm", h, m) end
  return m .. "m"
end

-- Menu bar: "36% · 2h 10m" (5-hour limit + time until reset). The text is refreshed once a
-- minute by a single timer that only swaps the text; it stops by itself when no limit
-- window is running or the meter is turned off.
local function updateUsageBar()
  if M.usageTick then pending[M.usageTick] = nil; M.usageTick:stop(); M.usageTick = nil end
  if not M.state.usageMeter then
    if M.usageBar then M.usageBar:delete(); M.usageBar = nil end
    return
  end
  if not M.usageBar then
    M.usageBar = hs.menubar.new()
    if not M.usageBar then return end
    M.usageBar:setTooltip("Claude usage (5-hour limit)")
    M.usageBar:setMenu(function() M.fetchUsage(); return M.usageMenu() end)
  end
  local w = usageWindow("five_hour")
  if not w then M.usageBar:setTitle("–%") return end
  local p = math.floor(w.pct + 0.5)
  local title = p .. "%"
  if w.resets then title = title .. " · " .. shortLeft(w.resets) end
  local c = pctColor(p)
  if c then
    title = hs.styledtext.new(title, { color = c, font = { name = ".AppleSystemUIFont", size = 14 } })
  end
  M.usageBar:setTitle(title)
  if w.resets then
    -- Wake exactly when the minute changes.
    local delay = ((w.resets - os.time()) % 60) + 0.5
    M.usageTick = later(delay, function() M.usageTick = nil; updateUsageBar() end)
  end
end

local function scheduleUsageReset()
  if M.usageResetTimer then
    pending[M.usageResetTimer] = nil; M.usageResetTimer:stop(); M.usageResetTimer = nil
  end
  local soonest
  for _, win in ipairs(WINDOWS) do
    local w = M.usage[win.key]
    if type(w) == "table" and w.resets and w.resets > os.time() then
      soonest = math.min(soonest or w.resets, w.resets)
    end
  end
  if soonest then
    M.usageResetTimer = later(soonest - os.time() + 1, function()
      M.usageResetTimer = nil
      updateUsageBar(); scheduleUsageReset(); M.fetchUsage(true)
    end)
  end
end

-- Fetch the latest numbers once, right after Claude finishes (anywhere: terminal, VS Code,
-- Desktop, browser). At most once a minute; nothing runs while Claude is idle.
local USAGE_SCRIPT = os.getenv("HOME") .. "/.claude/hooks/claude-usage.sh"
M.usageFetchedAt = 0

function M.fetchUsage(force)
  if not M.state.usageMeter then return end
  local wait = 60 - (os.time() - M.usageFetchedAt)
  if M.usageTask or (not force and wait > 0) then
    -- Too soon: don't drop it, fetch once more when the gap is over, so the last
    -- reply is still counted.
    if not M.usageTrail then
      M.usageTrail = later(math.max(wait, 5), function() M.usageTrail = nil; M.fetchUsage() end)
    end
    return
  end
  M.usageFetchedAt = os.time()
  later(force and 0 or 2, function()   -- give the server time to record the last reply
    M.usageTask = hs.task.new(USAGE_SCRIPT, function(code, out)
      M.usageTask = nil
      if code ~= 0 or not out or out == "" then return end
      local ok, data = pcall(hs.json.decode, out)
      if ok and type(data) == "table" then M.handleUsage(data) end
    end, { "--fetch" })
    if not M.usageTask:start() then M.usageTask = nil end
  end)
end

function M.handleUsage(data)
  local rl = type(data.rate_limits) == "table" and data.rate_limits or data
  local got = false
  for _, win in ipairs(WINDOWS) do
    local w = rl[win.key]
    local pct = type(w) == "table" and tonumber(w.used_percentage)
    local old = usageWindow(win.key)
    if pct then
      local oldPct = (type(old) == "table" and old.pct) or 0
      -- One alert when crossing the danger threshold (not on every update).
      if pct >= M.config.usage.dangerAt and oldPct < M.config.usage.dangerAt and M.state.usageMeter then
        hs.alert.show(string.format("⚠️  Claude %s at %d%% — resets %s",
          win.long:lower(), math.floor(pct + 0.5),
          (((tonumber(w.resets_at) or 0) - os.time() >= 86400) and "" or "in ") .. untilText(tonumber(w.resets_at))), 4)
      end
      M.usage[win.key] = { pct = pct, resets = tonumber(w.resets_at) }
      got = true
    end
  end
  if not got then return end
  if type(data.breakdown) == "table" then M.usage.breakdown = data.breakdown end
  M.usage.updated = os.time()
  hs.settings.set("claudePing.usage", M.usage)
  updateUsageBar()
  scheduleUsageReset()
end

function M.usageMenu()
  local items = {}
  for _, win in ipairs(WINDOWS) do
    local w = usageWindow(win.key)
    if w then
      local p = math.floor(w.pct + 0.5)
      local bar = string.rep("▰", math.floor(p / 10 + 0.5)) .. string.rep("▱", 10 - math.floor(p / 10 + 0.5))
      items[#items + 1] = { title = string.format("%s:  %s  %d%% used", win.long, bar, p), disabled = true }
      items[#items + 1] = { title = w.wasReset and "      Reset — new window starts with your next message"
                                    or ("      Resets " .. ((w.resets - os.time() >= 86400) and "" or "in ") .. untilText(w.resets)),
                            disabled = true }
    else
      items[#items + 1] = { title = win.long .. ":  no data yet", disabled = true }
    end
  end
  local split = {}
  for _, b in ipairs(type(M.usage.breakdown) == "table" and M.usage.breakdown or {}) do
    if type(b) == "table" and b.name and b.pct then split[#split + 1] = b.name .. " " .. b.pct .. "%" end
  end
  if #split > 0 then
    items[#items + 1] = { title = "Share of this week:  " .. table.concat(split, "  ·  "), disabled = true }
  end
  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = M.usage.updated and ("Updated " .. ago(M.usage.updated) .. "  ·  refreshes each time Claude replies")
                                or "Waiting for the next Claude reply…", disabled = true }
  items[#items + 1] = { title = "Refresh now", fn = function() M.fetchUsage(true) end }
  items[#items + 1] = { title = "Hide usage meter", fn = function() M.toggle("usageMeter") end }
  return items
end

-- ───────────────────────────── Menu bar & settings ─────────────────────────────
function M.toggle(name)
  M.state[name] = not M.state[name]
  hs.settings.set("claudePing." .. name, M.state[name])
  if name == "desktopChat" and not M.state.desktopChat then stopDesktopWatch() end
  if name == "usageMeter" then updateUsageBar(); M.fetchUsage() end
  M.render()
end

local function buildMenu()
  local items = {}
  for _, m in ipairs(M.markers) do
    items[#items + 1] = {
      title = ICONS[m.kind] .. "  " .. (m.title or "Claude") .. "  ·  " .. ago(m.created),
      fn = function() M.jump(m) end,
    }
  end
  if #items == 0 then items[1] = { title = "No Claude sessions waiting", disabled = true } end
  local add = function(t) items[#items + 1] = t end
  add({ title = "-" })
  add({ title = "Skip all", fn = M.dismissAll, disabled = #M.markers == 0 })
  add({ title = "Show a test reminder", fn = M.test })
  add({ title = "-" })
  add({ title = "Do not disturb (menu bar count only)", checked = M.state.dnd,
        fn = function() M.toggle("dnd") end })
  add({ title = "Sound", checked = M.state.sound, fn = function() M.toggle("sound") end })
  add({ title = "Watch Claude Desktop", checked = M.state.desktopChat,
        fn = function() M.toggle("desktopChat") end })
  add({ title = "Usage meter in menu bar", checked = M.state.usageMeter,
        fn = function() M.toggle("usageMeter") end })
  add({ title = "-" })
  add({ title = "Debug: check Claude Desktop buttons", fn = function() M.debugDesktop() end })
  return items
end

-- ───────────────────────────── Start ─────────────────────────────
function M.start()
  if M.started then return M end
  M.started = true

  M.server = hs.httpserver.new(false, false)   -- no HTTPS, no Bonjour
  M.server:setInterface("localhost")           -- reachable from this Mac only
  M.server:setPort(M.config.port)
  M.server:setCallback(onRequest)
  M.server:start()

  M.menubar = hs.menubar.new()
  if M.menubar then
    M.menubar:setTooltip("Claude Ping")
    M.menubar:setMenu(buildMenu)
  end

  M.appWatcher = hs.application.watcher.new(onAppEvent)
  M.appWatcher:start()
  local front = hs.application.frontmostApplication()
  if front and front:bundleID() ~= HAMMERSPOON then M.lastFront = front end
  M.screenWatcher = hs.screen.watcher.new(function() M.render() end)
  M.screenWatcher:start()

  M.hkJump = hs.hotkey.bind(M.config.hotkeyMods, M.config.jumpKey, function() M.jump(M.markers[1]) end)
  M.hkDismiss = hs.hotkey.bind(M.config.hotkeyMods, M.config.dismissKey, M.dismissAll)

  -- Older versions left AXManualAccessibility on permanently; turn that leftover off.
  local desk = hs.application.get(CLAUDE_DESKTOP)
  if desk then setDesktopAX(desk, false) end

  updateUsageBar()
  scheduleUsageReset()
  M.fetchUsage(true)
  M.render()
  log("running at http://127.0.0.1:" .. M.config.port)
  return M
end

return M
