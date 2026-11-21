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
  alerts = true,        -- chat line + sound + minimap flash on new matches
  alertSound = true,
  alertScore = 30,      -- DPS alert only at or below this Rival score
  levelRange = 0,       -- show only players within +/- this of my level; 0 = off
  whisperMsg = "Hi {name}! Want to run {dungeon}? I'm a {me}.",
  groupWhisperMsg = "Hi! Room for a {me} in your {dungeon} group?",
  contacted = {},       -- [name] = { t = time(), how = "whisper"|"invite" }
  lootSeen = {},        -- [dungeon] = { [itemID] = true }, see Loot.lua
  buildMode = false,
  size = nil,           -- { w, h } of the window
}
Core.CONTACT_TTL = 2 * 60 * 60   -- forget who you contacted after 2 hours

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

---------------------------------------------------------------------------
-- People you've whispered / invited (dimmed in the list for 2 hours)
---------------------------------------------------------------------------

function Core.MarkContacted(name, how)
  if not name then return end
  local prev = LFGRivalsDB.contacted[name]
  if prev and prev.how == "invite" then how = "invite" end   -- an invite outranks a later whisper
  LFGRivalsDB.contacted[name] = { t = time(), how = how }
  markDirty()
end

function Core.Contacted(name)
  local c = name and LFGRivalsDB.contacted[name]
  if c and time() - c.t > Core.CONTACT_TTL then
    LFGRivalsDB.contacted[name] = nil
    return nil
  end
  return c
end

function Core.PruneContacted()
  for name in pairs(LFGRivalsDB.contacted) do Core.Contacted(name) end
end

---------------------------------------------------------------------------
-- Loot profile for what you're searching
---------------------------------------------------------------------------

-- profile (or nil), dungeon name (or nil when searching a whole category).
function Core.CurrentProfile()
  local name = Sources.ActivityName(LFGRivalsDB.activityID)
  return ns.Loot.ProfileFor(name), name
end

local function inMyGroup(name)
  if not (UnitName and GetNumGroupMembers) or GetNumGroupMembers() == 0 then return false end
  local unit = IsInRaid and IsInRaid() and "raid" or "party"
  for i = 1, GetNumGroupMembers() do
    if UnitName(unit .. i) == name then return true end
  end
  return false
end

local function specsFor(e)
  local exact = e.class and Data.SpecFromName(e.class, e.specName)
  if exact then return { exact } end
  if e.class then return Data.GuessSpecs(e.class, e.role, e.comment) end
  return {}
end

-- Returns a flat, display-ready list: healers first, then (tanks), then DPS.
-- Within each role, lowest gear competition first; unknowns go last.
-- opts.allRoles: include tanks even when "Show tanks" is off (group builder).
-- Also returns how many players the level filter hid.
function Core.BuildList(opts)
  local db = LFGRivalsDB
  local meClass, meSpec = Core.Me()
  local myName = UnitName and UnitName("player")
  local myLevel = UnitLevel and UnitLevel("player") or 0
  local profile = Core.CurrentProfile()
  local out, hiddenByLevel = {}, 0

  Sources.Prune()
  for _, e in pairs(Sources.entries) do
    local keep = e.name ~= myName
      and (e.source ~= "chat" or db.useChat)
      and (e.role ~= "TANK" or db.showTanks or (opts and opts.allRoles))
      and e.role ~= nil
    if keep and db.levelRange > 0 and e.level and math.abs(e.level - myLevel) > db.levelRange then
      keep = false
      hiddenByLevel = hiddenByLevel + 1
    end
    if keep then
      local specs = specsFor(e)
      local score = Data.Score(meClass, meSpec, e.class, specs, profile)
      local row = {
        entry = e,
        specs = specs,
        specLabel = Core.SpecLabel(specs),
        score = score,
        certain = #specs == 1,
        contacted = Core.Contacted(e.name),
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
  return out, hiddenByLevel
end

-- Rival score of one group member (Groups tab, icon tooltips).
function Core.MemberScore(m, profile)
  if not m.class then return nil end
  local meClass, meSpec = Core.Me()
  return Data.Score(meClass, meSpec, m.class, Data.GuessSpecs(m.class, m.role, nil), profile)
end

-- Groups tab: each listed group with its makeup. Rival = the most any current
-- member competes with you for gear (unknown classes ignored). Lowest first.
function Core.BuildGroups()
  local out = {}
  for _, g in pairs(Sources.groups) do
    local profile = ns.Loot.ProfileFor(g.activity)
    local worst
    for _, m in ipairs(g.members) do
      local s = Core.MemberScore(m, profile)
      if s and (not worst or s > worst) then worst = s end
    end
    out[#out + 1] = { group = g, score = worst, profile = profile, contacted = Core.Contacted(g.leader) }
  end
  table.sort(out, function(a, b)
    local sa, sb = a.score or 999, b.score or 999
    if sa ~= sb then return sa < sb end
    return a.group.size < b.group.size
  end)
  return out
end

---------------------------------------------------------------------------
-- Build my group: best tank / healer / DPS from the list for the open slots
---------------------------------------------------------------------------

function Core.BuildPlan()
  local _, meSpec = Core.Me()
  local need = { TANK = 1, HEALER = 1, DAMAGER = 3 }
  local myRole = meSpec and meSpec.role or "DAMAGER"
  need[myRole] = need[myRole] - 1

  -- Party members already fill slots. Use their assigned role if the client
  -- has one, otherwise assume DPS (the role there's most of).
  local n = GetNumGroupMembers and GetNumGroupMembers() or 0
  if n > 0 and not (IsInRaid and IsInRaid()) then
    for i = 1, n - 1 do
      local role = UnitGroupRolesAssigned and UnitGroupRolesAssigned("party" .. i)
      if not need[role] or need[role] <= 0 then
        role = need.DAMAGER > 0 and "DAMAGER" or (need.HEALER > 0 and "HEALER" or "TANK")
      end
      need[role] = math.max(0, need[role] - 1)
    end
  end

  local picks, taken = {}, {}
  local list = Core.BuildList({ allRoles = true })
  for _, role in ipairs({ "HEALER", "TANK", "DAMAGER" }) do
    for _, d in ipairs(list) do
      if need[role] <= 0 then break end
      local e = d.entry
      if e.role == role and not taken[e.name] and not inMyGroup(e.name) then
        taken[e.name] = true
        need[role] = need[role] - 1
        picks[#picks + 1] = d
      end
    end
  end
  local missing = {}
  for _, role in ipairs({ "HEALER", "TANK", "DAMAGER" }) do
    if need[role] > 0 then missing[#missing + 1] = need[role] .. " " .. role:lower() end
  end
  return picks, missing
end

-- Invite the next suggested player you haven't invited yet. Returns the name.
function Core.InviteNext()
  local picks = Core.BuildPlan()
  for _, d in ipairs(picks) do
    local c = d.contacted
    if not (c and c.how == "invite") then
      ns.UI.Invite(d.entry.name)
      return d.entry.name
    end
  end
  print("everyone suggested has been invited - wait for replies or press Refresh for new people.")
  return nil
end

---------------------------------------------------------------------------
-- Alerts: a new healer, or a DPS under your alert score, shows up
---------------------------------------------------------------------------

local alerted, alertSeeded, lastSound = {}, false, 0

function Core.CheckAlerts()
  local db = LFGRivalsDB
  local fresh = {}
  local list = Core.BuildList()
  if #list == 0 then return end
  for _, d in ipairs(list) do
    local e = d.entry
    local key = e.source .. ":" .. e.name
    local match = not d.contacted and (e.role == "HEALER"
      or (e.role == "TANK" and db.showTanks)
      or (e.role == "DAMAGER" and d.score and d.score <= db.alertScore))
    if match and not alerted[key] then
      alerted[key] = true
      fresh[#fresh + 1] = d
    end
  end
  -- The first results after login are a baseline, not news. And while the
  -- window is open you're already looking, so no alert.
  if not alertSeeded then alertSeeded = true; return end
  if #fresh == 0 or not db.alerts or (ns.UI.IsShown and ns.UI.IsShown()) then return end

  for i = 1, math.min(#fresh, 3) do
    local d = fresh[i]
    local e = d.entry
    local what = e.role == "HEALER" and "healer" or (e.role == "TANK" and "tank" or ("DPS, rival " .. d.score))
    print("new " .. what .. ": " .. e.name .. (e.level and (" (" .. e.level .. ")") or "")
      .. " - /rivals to open")
  end
  if #fresh > 3 then print("...and " .. (#fresh - 3) .. " more.") end
  ns.Log.Add("alert", #fresh, "new matches")
  if db.alertSound and GetTime() - lastSound > 10 and PlaySound then
    lastSound = GetTime()
    pcall(PlaySound, (SOUNDKIT and SOUNDKIT.READY_CHECK) or 8960, "Master")
  end
  ns.Minimap.SetFlash(true)
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

-- From non-hardware contexts (dropdown picks): don't search, just make a
-- refresh due so the next key press or Refresh click runs it.
function Core.MarkDue(why)
  ns.Log.Add("refresh", "due now:", why)
  poll.due = true
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
    Core.CheckAlerts()
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
  if poll.due then return 0, true end
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
                          "CHARACTER_POINTS_CHANGED", "PLAYER_TALENT_UPDATE", "CHAT_MSG_CHANNEL",
                          "CHAT_MSG_LOOT", "LOOT_OPENED", "PLAYER_LEVEL_UP" }) do
      local ok = pcall(f.RegisterEvent, f, ev)
      if not ok then ns.Log.Add("init", "event not available:", ev) end
    end
    Sources.InstallSpies()
    -- Older versions remembered a single block forever; clicks and key
    -- presses do work, so forget it.
    LFGRivalsDB.blockedBuild = nil
    Core.PruneContacted()
    ns.Log.Add("init", "loot: journal API", ns.Loot.journal.available)
    ns.UI.Build()   -- create the window (hidden) so the Refresh keybind works right away
    if type(LFGRivalsDB.minimap) ~= "table" then LFGRivalsDB.minimap = { angle = 200, hide = false } end
    ns.Minimap.Create()
    Sources.ScanGroupFinder()
    poll.nextAt = GetTime() + 5   -- first refresh on your first key press after login
    C_Timer.NewTicker(1, tick)
  elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
    local addon, func = ...
    ns.Log.Add("blocked", event, "addon=", addon, "function=", func)
    -- One blocked call doesn't mean searching is broken (Refresh clicks and
    -- key presses work), so just log it; nothing gets switched off.
    if addon == ADDON then
      ns.Log.Add("blocked", "search from LFG Rivals was blocked; next key press or Refresh will retry")
      poll.due = true
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
    if Sources.OnChat(text, sender, guid) then
      Core.CheckAlerts()
      markDirty()
    end
  elseif event == "CHAT_MSG_LOOT" then
    -- "X receives loot: [item]" / "You receive loot: [item]" - one or more links.
    local text = ...
    if type(text) == "string" then
      for link in text:gmatch("|c%x+|Hitem:.-|h.-|h|r") do ns.Loot.Record(link) end
    end
  elseif event == "LOOT_OPENED" then
    if GetNumLootItems and GetLootSlotLink then
      for i = 1, GetNumLootItems() do
        local ok, link = pcall(GetLootSlotLink, i)
        if ok and link then ns.Loot.Record(link) end
      end
    end
  elseif event == "PLAYER_LEVEL_UP" then
    markDirty()
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
  elseif msg:match("^level%s+%d+$") then
    db.levelRange = tonumber(msg:match("%d+"))
    print(db.levelRange > 0 and ("showing players within " .. db.levelRange .. " levels of you.")
      or "level filter off.")
    markDirty()
  elseif msg == "alerts" then
    db.alerts = not db.alerts
    print("alerts " .. (db.alerts and "on." or "off."))
  elseif msg == "options" then
    ns.UI.Build()
    ns.Options.Toggle()
  elseif msg == "loot" then
    local p, name = Core.CurrentProfile()
    print(ns.Loot.Describe(p, name))
    print("Dungeon Journal API on this client: " .. tostring(ns.Loot.journal.available))
    local n = 0
    for inst, items in pairs(db.lootSeen) do
      local c = 0
      for _ in pairs(items) do c = c + 1 end
      print("  seen in " .. inst .. ": " .. c .. " items")
      n = n + 1
    end
    if n == 0 then print("  no drops recorded yet (they're learned as you loot in dungeons).") end
  elseif msg == "help" then
    print("/rivals - toggle window | /rivals options - settings | /rivals reset - re-detect spec"
      .. " | /rivals max <0-100> - hide DPS above that score | /rivals level <N|0> - only players within N levels"
      .. " | /rivals alerts - toggle alerts | /rivals loot - loot data for the picked dungeon"
      .. " | /rivals poll <seconds|off> - auto-refresh cadence (min " .. Core.MIN_POLL .. "s)"
      .. " | /rivals minimap - show/hide minimap button | /rivals debug - dump Group Finder data"
      .. " | /rivals log - copyable log | /rivals verbose - echo log to chat")
  else
    ns.UI.Toggle()
  end
end
