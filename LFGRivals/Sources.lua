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

function Sources.ScanGroupFinder()
  if not (C_LFGList and C_LFGList.GetSearchResults and C_LFGList.GetSearchResultInfo) then return 0 end

  -- Drop old Group Finder entries; the result set is the source of truth.
  for k, e in pairs(Sources.entries) do
    if e.source == "finder" then Sources.entries[k] = nil end
  end

  local ok, _, results = pcall(C_LFGList.GetSearchResults)
  if not ok or type(results) ~= "table" then return 0 end

  local added = 0
  for _, resultID in ipairs(results) do
    local okInfo, info = pcall(C_LFGList.GetSearchResultInfo, resultID)
    if okInfo and type(info) == "table" and not info.isDelisted and info.leaderName then
      local size = info.numMembers or 1
      local m = memberInfo(resultID, 1) or {}
      local extra = leaderExtra(resultID) or {}
      local role = normRole(m.role or extra.assignedRole or extra.role)
      local entry = {
        name = shortName(info.leaderName),
        class = m.class or extra.classFilename,
        role = role,
        specName = m.specName or extra.specName,
        level = m.level or extra.level,
        comment = info.comment or info.name or "",
        source = "finder",
        groupSize = size,
        seen = GetTime and GetTime() or 0,
      }
      Sources.entries["finder:" .. entry.name] = entry
      added = added + 1
    end
  end
  return added
end

-- Ask Blizzard's own UI to re-run its last search (needs a hardware click, which
-- our Refresh button provides). Returns true if a search was triggered.
function Sources.RequestRefresh()
  local candidates = {
    LFGBrowseFrame and LFGBrowseFrame.RefreshButton,                         -- Classic-style browser
    LFGListFrame and LFGListFrame.SearchPanel and LFGListFrame.SearchPanel.RefreshButton, -- Retail-style
  }
  for _, btn in ipairs(candidates) do
    if btn and btn.Click then
      local ok = pcall(btn.Click, btn)
      if ok then return true end
    end
  end
  return false
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
