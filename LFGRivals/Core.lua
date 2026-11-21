-- LFG Rivals: settings, ranking, events, slash commands.

local ADDON, ns = ...
local Data, Sources = ns.Data, ns.Sources
local Core = {}
ns.Core = Core

local DEFAULTS = {
  class = nil,          -- my class (auto-detected)
  spec = nil,           -- my spec key
  specLocked = false,   -- true once I pick a spec by hand
  showTanks = false,
  useChat = true,
  tab = "players",      -- "players" or "groups"
  maxScore = 100,       -- hide DPS that compete more than this
  pollInterval = 30,    -- seconds between auto-refreshes; 0 = off
  categoryID = nil,     -- Group Finder category to search (e.g. Dungeons)
  activityID = 0,       -- specific dungeon/raid; 0 = whole category
  minimap = { angle = 200, hide = false },
}

Core.POLL_STEPS = { 0, 5, 10, 15, 30 }
Core.MIN_POLL = 5       -- faster than this just gets throttled by the server

local function print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffLFG Rivals|r: " .. msg)
end
Core.print = print

local dirty = false
local function markDirty()
  if dirty then return end
  dirty = true
  C_Timer.After(0.3, function()
    dirty = false
    if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
  end)
end
Core.MarkDirty = markDirty

---------------------------------------------------------------------------
-- My class/spec
---------------------------------------------------------------------------

-- Talent tab order -> our spec list index (Druid has 4 specs for 3 tabs).
local TAB_TO_SPEC = { DRUID = { 1, 2, 4 } }

local function detectSpecFromTalents(class)
  if not GetTalentTabInfo then return nil end
  local best, bestPoints = nil, -1
  for tab = 1, 3 do
    local ok, a, b, c, d, e = pcall(GetTalentTabInfo, tab)
    if ok then
      -- Classic: name, icon, pointsSpent, ... | Retail-ish: id, name, desc, icon, pointsSpent
      local points = (type(c) == "number" and c) or (type(e) == "number" and e) or 0
      if points > bestPoints then best, bestPoints = tab, points end
    end
  end
  if not best or bestPoints <= 0 then return nil end
  local idx = (TAB_TO_SPEC[class] and TAB_TO_SPEC[class][best]) or best
  local spec = Data.SPECS[class] and Data.SPECS[class][idx]
  return spec and spec.key or nil
end

function Core.DetectMe()
  local db = LFGRivalsDB
  local _, class = UnitClass("player")
  if not Data.SPECS[class] then return end
  if db.class ~= class then
    db.class, db.spec, db.specLocked = class, nil, false
  end
  if not db.specLocked then
    db.spec = detectSpecFromTalents(class) or db.spec or Data.SPECS[class][1].key
  end
end

function Core.Me()
  local db = LFGRivalsDB
  return db.class, Data.GetSpec(db.class, db.spec)
end

function Core.CycleClass(dir)
  local db = LFGRivalsDB
  local order, cur = Data.CLASS_ORDER, 1
  for i, c in ipairs(order) do if c == db.class then cur = i end end
  cur = (cur - 1 + dir) % #order + 1
  db.class = order[cur]
  db.spec = Data.SPECS[db.class][1].key
  db.specLocked = true
end

function Core.CycleSpec(dir)
  local db = LFGRivalsDB
  local specs = Data.SPECS[db.class]
  if not specs then return end
  local cur = 1
  for i, s in ipairs(specs) do if s.key == db.spec then cur = i end end
  cur = (cur - 1 + dir) % #specs + 1
  db.spec = specs[cur].key
  db.specLocked = true
end

---------------------------------------------------------------------------
-- Ranking
---------------------------------------------------------------------------

local ROLE_ORDER = { HEALER = 1, TANK = 2, DAMAGER = 3 }

-- "Shadow", or "Balance/Cat" when we can't tell which.
function Core.SpecLabel(specs)
  local names = {}
  for _, s in ipairs(specs) do names[#names + 1] = s.name:gsub("^Feral %((%a+)%)$", "%1") end
  return table.concat(names, "/")
end

-- Returns a flat, display-ready list: healers first, then (tanks), then DPS.
-- Within each role, lowest gear competition first; unknowns go last.
function Core.BuildList()
  local db = LFGRivalsDB
  local meClass, meSpec = Core.Me()
  local myName = UnitName and UnitName("player")
  local out = {}

  Sources.Prune()
  for _, e in pairs(Sources.entries) do
    local keep = e.name ~= myName
      and (e.source ~= "chat" or db.useChat)
      and (e.role ~= "TANK" or db.showTanks)
      and e.role ~= nil
    if keep then
      local specs
      local exact = e.class and Data.SpecFromName(e.class, e.specName)
      if exact then
        specs = { exact }
      elseif e.class then
        specs = Data.GuessSpecs(e.class, e.role, e.comment)
      else
        specs = {}
      end
      local score = Data.CompetitionAny(meClass, meSpec, e.class, specs)
      local row = {
        entry = e,
        specs = specs,
        specLabel = Core.SpecLabel(specs),
        score = score,
        certain = #specs == 1,
      }
      if e.role ~= "DAMAGER" or score == nil or score <= db.maxScore then
        out[#out + 1] = row
      end
    end
  end

  table.sort(out, function(a, b)
    local ra, rb = ROLE_ORDER[a.entry.role] or 9, ROLE_ORDER[b.entry.role] or 9
    if ra ~= rb then return ra < rb end
    local sa, sb = a.score or 999, b.score or 999
    if sa ~= sb then return sa < sb end
    if a.certain ~= b.certain then return a.certain end
    return (a.entry.name or "") < (b.entry.name or "")
  end)
  return out
end

-- Groups tab: each listed group with its makeup. Rival = the most any current
-- member competes with you for gear (unknown classes ignored). Lowest first.
function Core.BuildGroups()
  local meClass, meSpec = Core.Me()
  local out = {}
  for _, g in pairs(Sources.groups) do
    local worst
    for _, m in ipairs(g.members) do
      if m.class then
        local s = Data.CompetitionAny(meClass, meSpec, m.class, Data.GuessSpecs(m.class, m.role, nil))
        if s and (not worst or s > worst) then worst = s end
      end
    end
    out[#out + 1] = { group = g, score = worst }
  end
  table.sort(out, function(a, b)
    local sa, sb = a.score or 999, b.score or 999
    if sa ~= sb then return sa < sb end
    return a.group.size < b.group.size
  end)
  return out
end

---------------------------------------------------------------------------
-- Auto-refresh: timer + your keystrokes
--   Blizzard only lets a Group Finder search start from a real click/keypress.
--   So the timer just marks a refresh as "due"; the next key you press (out of
--   combat) fires it. Keys still reach the game normally.
---------------------------------------------------------------------------

Core.poll = { nextAt = 0, due = false }
local poll = Core.poll

local function scheduleNext()
  poll.due = false
  poll.nextAt = GetTime() + math.max(LFGRivalsDB.pollInterval, Core.MIN_POLL)
end

-- Refresh button / keybind (always a hardware event).
function Core.ManualRefresh(why)
  scheduleNext()
  if not Sources.RequestRefresh(why or "click") then
    if Sources.searchBlocked then
      print("addon searches were blocked by the client - search in Blizzard's LFG window"
        .. " (results still show here), or /rivals unblock to retry.")
    else
      print("couldn't start a search - pick a category at the top of the window. (/rivals log for details)")
    end
  end
  -- No scan here: results arrive with LFG_LIST_SEARCH_RESULTS_RECEIVED, and
  -- scanning now would briefly show an empty list.
  markDirty()
end

-- The client fires LFG_LIST_SEARCH_RESULT_UPDATED once per listing; collapse a
-- burst into one scan.
local scanPending = false
local function scheduleScan()
  if scanPending then return end
  scanPending = true
  C_Timer.After(0.2, function()
    scanPending = false
    Sources.ScanGroupFinder()
    markDirty()
  end)
end

function Core.SetPollInterval(secs)
  secs = tonumber(secs) or 0
  if secs > 0 then secs = math.max(secs, Core.MIN_POLL) end
  LFGRivalsDB.pollInterval = secs
  poll.due = false
  poll.nextAt = GetTime() + secs
  markDirty()
end

function Core.CyclePoll()
  local steps, cur = Core.POLL_STEPS, 1
  for i, s in ipairs(steps) do if s == LFGRivalsDB.pollInterval then cur = i end end
  Core.SetPollInterval(steps[cur % #steps + 1])
end

-- For the UI: nil if off, else seconds left and whether it's waiting on a key.
function Core.PollStatus()
  if LFGRivalsDB.pollInterval <= 0 then return nil end
  return math.max(0, math.ceil(poll.nextAt - GetTime())), poll.due
end

local keyCatcher = CreateFrame("Frame", nil, UIParent)
if keyCatcher.SetPropagateKeyboardInput and keyCatcher.EnableKeyboard then
  keyCatcher:EnableKeyboard(true)
  keyCatcher:SetPropagateKeyboardInput(true)  -- never swallow the key
  keyCatcher:SetScript("OnKeyDown", function()
    if not poll.due then return end
    if InCombatLockdown and InCombatLockdown() then return end
    scheduleNext()
    Sources.RequestRefresh("keystroke")
  end)
  Core.keystrokeSupported = true
end

local function tick()
  if not LFGRivalsDB or LFGRivalsDB.pollInterval <= 0 or poll.due or Sources.searchBlocked then return end
  if GetTime() >= poll.nextAt then
    poll.due = true
    markDirty()
  end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")

f:SetScript("OnEvent", function(_, event, ...)
  if event == "ADDON_LOADED" then
    if ... ~= ADDON then return end
    LFGRivalsDB = LFGRivalsDB or {}
    for k, v in pairs(DEFAULTS) do
      if LFGRivalsDB[k] == nil then LFGRivalsDB[k] = v end
    end
    ns.Log.Attach(LFGRivalsDB)
    local version, build, _, iface = GetBuildInfo()
    ns.Log.Add("init", "client", version, "build", build, "interface", iface,
      "addon", C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version")
        or (GetAddOnMetadata and GetAddOnMetadata(ADDON, "Version")))
  elseif event == "PLAYER_LOGIN" then
    Core.DetectMe()
    ns.Log.Add("init", "me:", LFGRivalsDB.class, LFGRivalsDB.spec, "poll:", LFGRivalsDB.pollInterval,
      "category:", LFGRivalsDB.categoryID, "activity:", LFGRivalsDB.activityID)
    for _, ev in ipairs({ "LFG_LIST_SEARCH_RESULTS_RECEIVED", "LFG_LIST_SEARCH_RESULT_UPDATED",
                          "LFG_LIST_SEARCH_FAILED", "LFG_LIST_AVAILABILITY_UPDATE",
                          "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN",
                          "CHARACTER_POINTS_CHANGED", "PLAYER_TALENT_UPDATE", "CHAT_MSG_CHANNEL" }) do
      local ok = pcall(f.RegisterEvent, f, ev)
      if not ok then ns.Log.Add("init", "event not available:", ev) end
    end
    Sources.InstallSpies()
    -- If this client build already blocked our direct search, don't trigger
    -- the "Interface action failed" popup again; use the secure Refresh.
    local _, build = GetBuildInfo()
    if LFGRivalsDB.blockedBuild == build then
      Sources.searchBlocked = true
      ns.Log.Add("init", "direct search known blocked on build", build, "- using secure Refresh only")
    end
    ns.UI.Build()   -- create the window (hidden) so the Refresh keybind works right away
    if type(LFGRivalsDB.minimap) ~= "table" then LFGRivalsDB.minimap = { angle = 200, hide = false } end
    ns.Minimap.Create()
    Sources.ScanGroupFinder()
    poll.nextAt = GetTime() + 5   -- first refresh on your first key press after login
    C_Timer.NewTicker(1, tick)
  elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
    local addon, func = ...
    ns.Log.Add("blocked", event, "addon=", addon, "function=", func)
    if addon == ADDON and not Sources.searchBlocked then
      Sources.searchBlocked = true
      LFGRivalsDB.blockedBuild = select(2, GetBuildInfo())
      poll.due = false
      print("the client blocked an LFG search from LFG Rivals. Addon searches are paused for this"
        .. " client build - search in Blizzard's LFG window, or /rivals unblock to retry. (/rivals log)")
      markDirty()
    end
  elseif event == "LFG_LIST_SEARCH_FAILED" then
    ns.Log.Add("event", event, ...)
  elseif event == "LFG_LIST_AVAILABILITY_UPDATE" then
    ns.Log.Add("event", event)
  elseif event == "LFG_LIST_SEARCH_RESULTS_RECEIVED" or event == "LFG_LIST_SEARCH_RESULT_UPDATED" then
    if event == "LFG_LIST_SEARCH_RESULTS_RECEIVED" then
      ns.Log.Add("event", event)
      -- Any fresh search (ours, the keybind, or Blizzard's own UI) resets the timer.
      scheduleNext()
    end
    scheduleScan()
  elseif event == "CHARACTER_POINTS_CHANGED" or event == "PLAYER_TALENT_UPDATE" then
    Core.DetectMe()
    markDirty()
  elseif event == "CHAT_MSG_CHANNEL" then
    if not LFGRivalsDB.useChat then return end
    local text, sender = ...
    local guid = select(12, ...)
    if Sources.OnChat(text, sender, guid) then markDirty() end
  end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

SLASH_LFGRIVALS1 = "/rivals"
SLASH_LFGRIVALS2 = "/lfgr"
SlashCmdList.LFGRIVALS = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  local db = LFGRivalsDB
  if msg == "reset" then
    db.specLocked = false
    Core.DetectMe()
    print("spec re-detected from talents.")
    markDirty()
  elseif msg:match("^max%s+%d+$") then
    db.maxScore = tonumber(msg:match("%d+"))
    print("hiding DPS with competition above " .. db.maxScore .. ".")
    markDirty()
  elseif msg:match("^poll%s+") then
    local arg = msg:match("^poll%s+(%S+)")
    Core.SetPollInterval(arg == "off" and 0 or tonumber(arg) or 0)
    if db.pollInterval > 0 then
      print("refresh due every " .. db.pollInterval .. "s; fires on your next key press.")
    else
      print("auto-refresh off.")
    end
  elseif msg == "debug" then
    Sources.Debug(function(s) print(s); ns.Log.Add("debug", s) end)
  elseif msg == "unblock" then
    db.blockedBuild, Sources.searchBlocked = nil, false
    print("will try direct searches again (expect the 'Interface action failed' popup if still blocked).")
    markDirty()
  elseif msg == "log" then
    ns.Log.Show()
  elseif msg == "verbose" then
    db.verbose = not db.verbose
    print("verbose logging to chat " .. (db.verbose and "on." or "off."))
  elseif msg == "minimap" then
    print(ns.Minimap.Toggle() and "minimap button shown." or "minimap button hidden (/rivals minimap to bring it back).")
  elseif msg == "help" then
    print("/rivals - toggle window | /rivals reset - re-detect spec | /rivals max <0-100> - hide DPS above that score"
      .. " | /rivals poll <seconds|off> - auto-refresh cadence (min " .. Core.MIN_POLL .. "s)"
      .. " | /rivals minimap - show/hide minimap button | /rivals debug - dump Group Finder data"
      .. " | /rivals log - copyable log | /rivals verbose - echo log to chat")
  else
    ns.UI.Toggle()
  end
end
