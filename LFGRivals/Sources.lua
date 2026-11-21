-- LFG Rivals: where players come from.
--   1. Blizzard's Group Finder (C_LFGList) - listings with role/class/spec.
--   2. "LFG" messages in chat channels - class from GUID, role/spec from keywords.
-- Every Blizzard call is guarded: the Group Finder API differs between clients.

local ADDON, ns = ...
local Sources = {}
ns.Sources = Sources

-- entries[key] = { name, class, role, specName, comment, level, source, groupSize, seen }
Sources.entries = {}

local CHAT_TTL = 15 * 60

local function shortName(name)
  if not name then return nil end
  if Ambiguate then return Ambiguate(name, "short") end
  return (name:gsub("%-.*$", ""))
end

local function normRole(r)
  if r == "HEALER" or r == "TANK" or r == "DAMAGER" then return r end
  if r == "DPS" then return "DAMAGER" end
  return nil
end

-- {tank=, healer=, dps=} style tables (bools or counts, any key casing).
-- Healer wins, since that's who we're hunting for; tank only if nothing else.
local function rolesFromTable(t)
  if type(t) ~= "table" then return nil end
  local function on(...)
    for i = 1, select("#", ...) do
      local v = select(i, ...)
      if v == true or (type(v) == "number" and v > 0) then return true end
    end
    return false
  end
  if on(t.healer, t.HEALER, t.Healer, t.heal) then return "HEALER" end
  if on(t.dps, t.DPS, t.damager, t.DAMAGER, t.Damager) then return "DAMAGER" end
  if on(t.tank, t.TANK, t.Tank) then return "TANK" end
  return nil
end

local function roleFromText(lower)
  local padded = " " .. lower .. " "
  if padded:find("heal") or padded:find("%f[%a]resto%f[%A]") or padded:find("%f[%a]disc%f[%A]")
     or padded:find("%f[%a]holy%f[%A]") then
    return "HEALER"
  end
  if padded:find("%f[%a]tank%f[%A]") or padded:find("%f[%a]prot%f[%A]") or padded:find("%f[%a]bear%f[%A]") then
    return "TANK"
  end
  return "DAMAGER"
end

---------------------------------------------------------------------------
-- Group Finder
---------------------------------------------------------------------------

local function memberInfo(resultID, idx)
  -- Newer clients: table-returning GetSearchResultPlayerInfo.
  if C_LFGList.GetSearchResultPlayerInfo then
    local ok, info = pcall(C_LFGList.GetSearchResultPlayerInfo, resultID, idx)
    if ok and type(info) == "table" then
      return {
        role = info.assignedRole or info.role,
        class = info.classFilename or info.class,
        specName = info.specName or info.specLocalized,
        level = info.level,
        isLeader = info.isLeader,
        name = info.name,
      }
    end
  end
  if C_LFGList.GetSearchResultMemberInfo then
    local ok, a, b, c, d, e = pcall(C_LFGList.GetSearchResultMemberInfo, resultID, idx)
    if ok then
      if type(a) == "table" then
        return { role = a.assignedRole or a.role, class = a.classFilename or a.class,
                 specName = a.specName or a.specLocalized, level = a.level, isLeader = a.isLeader, name = a.name }
      end
      return { role = a, class = b, specName = d, isLeader = e }
    end
  end
  return nil
end

local function leaderExtra(resultID)
  if not C_LFGList.GetSearchResultLeaderInfo then return nil end
  local ok, info = pcall(C_LFGList.GetSearchResultLeaderInfo, resultID)
  if ok and type(info) == "table" then return info end
  return nil
end

-- name, maxPlayers for an activity ID.
local function activityInfo(id)
  if not id then return nil, nil end
  if C_LFGList.GetActivityInfoTable then
    local ok, t = pcall(C_LFGList.GetActivityInfoTable, id)
    if ok and type(t) == "table" then return t.fullName or t.shortName, t.maxNumPlayers end
  end
  if C_LFGList.GetActivityInfo then
    local ok, name, _, _, _, _, _, _, maxPlayers = pcall(C_LFGList.GetActivityInfo, id)
    if ok then
      if type(name) == "table" then return name.fullName, name.maxNumPlayers end
      return name, maxPlayers
    end
  end
  return nil, nil
end

-- Everyone in a listing: { {role, class, name}, ... }. Falls back to role
-- counts (no classes) when per-member info isn't available.
local function groupMembers(resultID, size)
  local members = {}
  for i = 1, size do
    local m = memberInfo(resultID, i)
    if m and (m.role or m.class) then
      members[#members + 1] = { role = normRole(m.role), class = m.class, name = m.name, level = m.level }
    end
  end
  if #members == 0 and C_LFGList.GetSearchResultMemberCounts then
    local ok, c = pcall(C_LFGList.GetSearchResultMemberCounts, resultID)
    if ok and type(c) == "table" then
      for role, key in pairs({ TANK = "TANK", HEALER = "HEALER", DAMAGER = "DAMAGER" }) do
        for _ = 1, (tonumber(c[key]) or 0) do members[#members + 1] = { role = role } end
      end
    end
  end
  return members
end

-- groups[resultID] = { leader, leaderClass, activity, comment, size, max, members }
Sources.groups = {}

function Sources.ScanGroupFinder()
  if not (C_LFGList and C_LFGList.GetSearchResults and C_LFGList.GetSearchResultInfo) then return 0 end

  -- Drop old Group Finder entries; the result set is the source of truth.
  for k, e in pairs(Sources.entries) do
    if e.source == "finder" then Sources.entries[k] = nil end
  end
  wipe(Sources.groups)

  local ok, _, results = pcall(C_LFGList.GetSearchResults)
  if not ok or type(results) ~= "table" then return 0 end

  local added = 0
  local drop = { noInfo = 0, delisted = 0, noName = 0 }
  local firstDrop
  for _, resultID in ipairs(results) do
    local okInfo, info = pcall(C_LFGList.GetSearchResultInfo, resultID)
    if not okInfo or type(info) ~= "table" then
      drop.noInfo = drop.noInfo + 1
      firstDrop = firstDrop or ("noInfo id=" .. tostring(resultID) .. " " .. tostring(info))
    elseif info.isDelisted then
      drop.delisted = drop.delisted + 1
    end
    if okInfo and type(info) == "table" and not info.isDelisted then
      local size = info.numMembers or 1
      local m = memberInfo(resultID, 1) or {}
      local extra = leaderExtra(resultID) or {}
      local name = info.leaderName or m.name or extra.name
      local class = m.class or extra.classFilename or extra.class
      local comment = info.comment or info.name or ""
      -- Solo listers pick the roles they *want* rather than having an assigned one,
      -- so check wanted roles first, then assigned role, then the note text.
      local role = rolesFromTable(extra.lfgRoles) or rolesFromTable(info.lfgRoles)
        or rolesFromTable(m.lfgRoles) or normRole(m.role or extra.assignedRole or extra.role)
      if not role and size <= 1 and C_LFGList.GetSearchResultMemberCounts then
        local okC, counts = pcall(C_LFGList.GetSearchResultMemberCounts, resultID)
        if okC then role = rolesFromTable(counts) end
      end
      role = role or roleFromText(comment:lower())
      if class and #ns.Data.SpecsForRole(class, role) == 0 then role = "DAMAGER" end

      local entry = name and {
        name = shortName(name),
        class = class,
        role = role,
        specName = m.specName or extra.specName,
        level = m.level or extra.level or info.leaderLevel or info.level,
        comment = comment,
        source = "finder",
        groupSize = size,
        seen = GetTime and GetTime() or 0,
      }
      if not entry and size <= 1 then
        drop.noName = drop.noName + 1
        if not firstDrop then
          firstDrop = "noName id=" .. tostring(resultID) .. " info=" .. ns.Log.Fmt(info)
            .. " member1=" .. ns.Log.Fmt(m) .. " leader=" .. ns.Log.Fmt(extra)
        end
      elseif entry and size <= 1 then
        Sources.entries["finder:" .. entry.name] = entry
        added = added + 1
      elseif size > 1 then
        local actID = info.activityID or (type(info.activityIDs) == "table" and info.activityIDs[1])
        local actName, maxPlayers = activityInfo(actID)
        Sources.groups[resultID] = {
          id = resultID,
          leader = name and shortName(name) or "?",
          leaderClass = class,
          activity = actName or info.name or "",
          comment = info.comment or "",
          size = size,
          max = maxPlayers or 5,
          members = groupMembers(resultID, size),
        }
        added = added + 1
      end
    end
  end
  Sources.lastScan = { at = GetTime(), total = #results, parsed = added }
  local nGroups = 0
  for _ in pairs(Sources.groups) do nGroups = nGroups + 1 end
  ns.Log.Add("scan", #results, "results from client,", added - nGroups, "solo players,", nGroups, "groups;",
    "dropped: noInfo", drop.noInfo, "delisted", drop.delisted, "noName", drop.noName)
  -- Raw dump of the first dropped listing, once per distinct reason, to see why.
  if firstDrop and firstDrop:sub(1, 6) ~= (Sources.lastDropKind or "") then
    Sources.lastDropKind = firstDrop:sub(1, 6)
    ns.Log.Add("scan", "first dropped:", firstDrop)
  end
  return added
end

---------------------------------------------------------------------------
-- Category / activity pickers (Dungeons -> Krol'dok Stronghold, etc.)
---------------------------------------------------------------------------

function Sources.GetCategories()
  local out = {}
  if not (C_LFGList and C_LFGList.GetAvailableCategories) then return out end
  local ok, ids = pcall(C_LFGList.GetAvailableCategories)
  if not ok or type(ids) ~= "table" then return out end
  for _, id in ipairs(ids) do
    local name
    if C_LFGList.GetLfgCategoryInfo then
      local okI, info = pcall(C_LFGList.GetLfgCategoryInfo, id)
      if okI and type(info) == "table" then name = info.name end
    end
    if not name and C_LFGList.GetCategoryInfo then
      local okI, n = pcall(C_LFGList.GetCategoryInfo, id)
      if okI then name = type(n) == "table" and n.name or n end
    end
    out[#out + 1] = { id = id, name = name or ("Category " .. id) }
  end
  return out
end

function Sources.GetActivities(categoryID)
  local out = {}
  if not (categoryID and C_LFGList and C_LFGList.GetAvailableActivities) then return out end
  local ok, ids = pcall(C_LFGList.GetAvailableActivities, categoryID)
  if not ok or type(ids) ~= "table" then return out end
  for _, id in ipairs(ids) do
    local name
    if C_LFGList.GetActivityInfoTable then
      local okI, info = pcall(C_LFGList.GetActivityInfoTable, id)
      if okI and type(info) == "table" then name = info.fullName or info.shortName end
    end
    if not name and C_LFGList.GetActivityInfo then
      local okI, n = pcall(C_LFGList.GetActivityInfo, id)
      if okI then name = type(n) == "table" and n.fullName or n end
    end
    out[#out + 1] = { id = id, name = name or ("Activity " .. id) }
  end
  return out
end

-- Run a search for the picked category/activity. Must be called from a click
-- or key press. activityID 0 = everything in the category.
local function searchPicked()
  local db = LFGRivalsDB
  if not (db and db.categoryID and C_LFGList and C_LFGList.Search) then return false end
  local activityIDs = {}
  if db.activityID and db.activityID ~= 0 then
    activityIDs[1] = db.activityID
  else
    for _, a in ipairs(Sources.GetActivities(db.categoryID)) do activityIDs[#activityIDs + 1] = a.id end
  end
  local s = { at = GetTime(), category = db.categoryID, activities = #activityIDs }
  Sources.lastSearch = s
  -- A blocked protected call does NOT raise a Lua error, so pcall "succeeds";
  -- Core watches ADDON_ACTION_BLOCKED and flips Sources.searchBlocked.
  -- Signature confirmed on WoW Forever 1.60.1:
  -- Search(categoryID, filter, preferredFilters, languageFilter, crossFaction, advanced, activityIDs)
  Sources.inOurSearch = true
  ns.Log.Add("search", "C_LFGList.Search category=", db.categoryID, "activityIDs=", activityIDs)
  local ok, err = pcall(C_LFGList.Search, db.categoryID, 0, 0, nil, nil, nil, activityIDs)
  Sources.inOurSearch = false
  if ok then
    s.ok, s.how = true, "direct"
    ns.Log.Add("search", "call returned without error (may still be blocked)")
    return true
  end
  s.err1 = tostring(err)
  ns.Log.Add("search", "call error:", s.err1)
  return false
end

-- Blizzard's own LFG refresh button, if this client has one loaded. A secure
-- button that "clicks" it runs Blizzard's search untainted, which works even
-- when addons are blocked from calling C_LFGList.Search themselves.
function Sources.FindBlizzardRefresh()
  local function usable(b) return type(b) == "table" and type(b.Click) == "function" end
  local known = {
    { "LFGBrowseFrame.RefreshButton", LFGBrowseFrame and LFGBrowseFrame.RefreshButton },
    { "LFGBrowseFrameRefreshButton", _G.LFGBrowseFrameRefreshButton },
    { "LFGListFrame.SearchPanel.RefreshButton",
      LFGListFrame and LFGListFrame.SearchPanel and LFGListFrame.SearchPanel.RefreshButton },
    { "LFGListFrameSearchPanelRefreshButton", _G.LFGListFrameSearchPanelRefreshButton },
  }
  for _, c in ipairs(known) do
    if usable(c[2]) then return c[2], c[1] end
  end
  -- Unknown layout: look for a RefreshButton on any Blizzard LFG frame.
  for name, v in pairs(_G) do
    if type(name) == "string" and name:find("LFG") and not name:find("^LFGRivals")
       and type(v) == "table" and type(v.GetObjectType) == "function" then
      if usable(v.RefreshButton) then return v.RefreshButton, name .. ".RefreshButton" end
      if type(v.SearchPanel) == "table" and usable(v.SearchPanel.RefreshButton) then
        return v.SearchPanel.RefreshButton, name .. ".SearchPanel.RefreshButton"
      end
    end
  end
  return nil, nil
end

-- Log every call to C_LFGList.Search, including Blizzard's own (and other
-- addons'), so we can see which arguments this client's UI actually uses.
function Sources.InstallSpies()
  if not (C_LFGList and C_LFGList.Search and hooksecurefunc) then
    ns.Log.Add("spy", "C_LFGList.Search not hookable")
    return
  end
  hooksecurefunc(C_LFGList, "Search", function(...)
    local who = Sources.inOurSearch and "LFG Rivals" or "Blizzard/other addon"
    local args = {}
    for i = 1, select("#", ...) do args[#args + 1] = ns.Log.Fmt((select(i, ...))) end
    ns.Log.Add("spy", "Search called by " .. who .. " args: (" .. table.concat(args, ", ") .. ")")
  end)
  ns.Log.Add("spy", "hooked C_LFGList.Search")
end

-- LFG-related frames this client has (to find Blizzard's search/refresh buttons).
function Sources.FindLFGFrames()
  local found = {}
  for name, v in pairs(_G) do
    if type(name) == "string" and (name:find("LFG") or name:find("GroupFinder"))
       and type(v) == "table" and type(v.GetObjectType) == "function" then
      local ok, kind = pcall(v.GetObjectType, v)
      if ok and (kind == "Frame" or kind == "Button") and not name:find("^LFGRivals") then
        local shown = v.IsShown and v:IsShown() and "shown" or "hidden"
        found[#found + 1] = name .. "(" .. kind .. "," .. shown .. ")"
      end
    end
  end
  table.sort(found)
  return found
end

---------------------------------------------------------------------------
-- /rivals debug: dump what the client actually gives us.
---------------------------------------------------------------------------

local function flat(v, depth)
  depth = depth or 0
  if type(v) ~= "table" then return tostring(v) end
  if depth > 1 then return "{...}" end
  local parts = {}
  for k, x in pairs(v) do
    parts[#parts + 1] = tostring(k) .. "=" .. flat(x, depth + 1)
    if #parts >= 14 then parts[#parts + 1] = "..."; break end
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

function Sources.Debug(out)
  local L = C_LFGList
  out("API: Search=" .. tostring(L and L.Search ~= nil)
    .. " GetSearchResults=" .. tostring(L and L.GetSearchResults ~= nil)
    .. " MemberInfo=" .. tostring(L and L.GetSearchResultMemberInfo ~= nil)
    .. " PlayerInfo=" .. tostring(L and L.GetSearchResultPlayerInfo ~= nil)
    .. " LeaderInfo=" .. tostring(L and L.GetSearchResultLeaderInfo ~= nil)
    .. " MemberCounts=" .. tostring(L and L.GetSearchResultMemberCounts ~= nil))
  out("Picked: category=" .. tostring(LFGRivalsDB.categoryID) .. " activity=" .. tostring(LFGRivalsDB.activityID)
    .. " searchBlocked=" .. tostring(Sources.searchBlocked))
  local frames = Sources.FindLFGFrames()
  for i = 1, #frames, 6 do
    out("Frames: " .. table.concat(frames, " ", i, math.min(i + 5, #frames)))
  end
  if #frames == 0 then out("Frames: no LFG frames found") end
  local s = Sources.lastSearch
  if s then
    out(string.format("Last search %.0fs ago: ok=%s via=%s activities=%d err1=%s err2=%s",
      GetTime() - s.at, tostring(s.ok), tostring(s.how), s.activities, tostring(s.err1), tostring(s.err2)))
  else
    out("No search attempted by LFG Rivals yet.")
  end
  local sc = Sources.lastScan
  if sc then
    out(string.format("Last scan %.0fs ago: %d results from client, %d parsed",
      GetTime() - sc.at, sc.total, sc.parsed))
  end
  if not (L and L.GetSearchResults) then return end
  local ok, total, results = pcall(L.GetSearchResults)
  out("GetSearchResults: ok=" .. tostring(ok) .. " total=" .. tostring(total)
    .. " n=" .. tostring(type(results) == "table" and #results or results))
  if not ok or type(results) ~= "table" then return end
  for i = 1, math.min(2, #results) do
    local id = results[i]
    local _, info = pcall(L.GetSearchResultInfo, id)
    out("#" .. i .. " info: " .. flat(info))
    if L.GetSearchResultMemberInfo then
      out("#" .. i .. " member1: " .. flat({ pcall(L.GetSearchResultMemberInfo, id, 1) }))
    end
    if L.GetSearchResultPlayerInfo then
      out("#" .. i .. " player1: " .. flat({ pcall(L.GetSearchResultPlayerInfo, id, 1) }))
    end
    if L.GetSearchResultLeaderInfo then
      out("#" .. i .. " leader: " .. flat({ pcall(L.GetSearchResultLeaderInfo, id) }))
    end
    if L.GetSearchResultMemberCounts then
      out("#" .. i .. " counts: " .. flat({ pcall(L.GetSearchResultMemberCounts, id) }))
    end
  end
end

-- Start a search (needs a hardware click/keypress, which our Refresh button,
-- keybind, minimap button and keystroke hook all provide). Uses the picked
-- category/activity; falls back to re-running Blizzard's own last search.
function Sources.RequestRefresh(why)
  ns.Log.Add("refresh", "requested by", why or "?")
  if Sources.searchBlocked then
    -- Every further try would just pop "Interface action failed" again.
    -- (Clicking Blizzard's button from addon code is just as blocked; only the
    -- secure Refresh button / keybind can do that.)
    ns.Log.Add("refresh", "skipped: client blocks addon searches")
    return false
  end
  return searchPicked()
end

---------------------------------------------------------------------------
-- Chat
---------------------------------------------------------------------------

local function isLFGMessage(lower)
  local padded = " " .. lower .. " "
  if not (padded:find("%f[%a]lfg%f[%A]") or padded:find("looking for group", 1, true)) then
    return false
  end
  -- "LFM", "need X", "LF1M" are groups recruiting, not players looking.
  if padded:find("%f[%a]lfm%f[%A]") or padded:find("%f[%a]lf%dm%f[%A]") or padded:find("%f[%a]need%f[%A]") then
    return false
  end
  return true
end

function Sources.OnChat(text, sender, guid)
  if not (text and sender) then return false end
  local lower = text:lower()
  if not isLFGMessage(lower) then return false end

  local class
  if guid and GetPlayerInfoByGUID then
    local ok, _, englishClass = pcall(GetPlayerInfoByGUID, guid)
    if ok then class = englishClass end
  end

  local role = roleFromText(lower)
  -- A class that can't fill the role it typed (e.g. "mage lfg heal") -> trust class.
  if class and #ns.Data.SpecsForRole(class, role) == 0 then role = "DAMAGER" end

  local name = shortName(sender)
  ns.Log.Add("chat", name, class or "?class", role)
  Sources.entries["chat:" .. name] = {
    name = name, class = class, role = role, comment = text,
    source = "chat", groupSize = 1, seen = GetTime and GetTime() or 0,
  }
  return true
end

function Sources.Prune()
  local now = GetTime and GetTime() or 0
  for k, e in pairs(Sources.entries) do
    if e.source == "chat" and now - e.seen > CHAT_TTL then Sources.entries[k] = nil end
  end
end
