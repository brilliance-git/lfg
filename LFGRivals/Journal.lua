-- LFG Rivals: data from the ForeverDungeonJournal addon, when it's installed.
-- It exposes its namespace as _G.ForeverDungeonJournal_NS, with:
--   DB[dungeon] = { level = "40-47", bosses = { { name, loot = { {itemID, name, "Slot, Type", quality}, ... } } } }
--   DUNGEON_SEARCH_ALIASES[dungeon] = { "rfk", "kraul", ... }
-- Read live (nothing copied), so it stays as current as that addon.
-- Without it, level ranges fall back to the client's LFG activity info.

local ADDON, ns = ...
local J = {}
ns.Journal = J

local function fdj()
  local f = _G.ForeverDungeonJournal_NS
  if type(f) == "table" and type(f.DB) == "table" then return f end
  return nil
end

function J.Available() return fdj() ~= nil end

-- Same normalising the journal uses for its own LFG button.
local function norm(s)
  if type(s) ~= "string" then return "" end
  return (s:lower():gsub("^the ", ""):gsub("[^%w]", ""))
end

-- LFG activity / any dungeon name -> the journal's dungeon name.
local byName = {}
function J.Find(name)
  local f = fdj()
  if not f or not name or name == "" then return nil end
  if byName[name] ~= nil then return byName[name] or nil end
  local wanted, found = norm(name), nil
  for n in pairs(f.DB) do
    if norm(n) == wanted then found = n; break end
  end
  if not found and f.DUNGEON_SEARCH_ALIASES then
    for n, aliases in pairs(f.DUNGEON_SEARCH_ALIASES) do
      for _, a in ipairs(aliases) do
        if norm(a) == wanted then found = n; break end
      end
      if found then break end
    end
  end
  -- Names that differ a little ("The Stockade" / "Stormwind Stockades").
  if not found then
    local stem = wanted:gsub("s$", "")
    if #stem >= 5 then
      for n in pairs(f.DB) do
        local s = norm(n):gsub("s$", "")
        if s ~= "" and (s:find(stem, 1, true) or stem:find(s, 1, true)) then found = n; break end
      end
    end
  end
  byName[name] = found or false
  return found
end

-- lo, hi, source ("journal" | "client") for an LFG activity.
local rangeCache = {}
function J.Range(activityID, name)
  local key = activityID or name
  if not key then return nil end
  local c = rangeCache[key]
  if c ~= nil then
    if c then return c[1], c[2], c[3] end
    return nil
  end
  local lo, hi, src
  local f = fdj()
  local jname = J.Find(name)
  if f and jname and f.DB[jname].level then
    local a, b = tostring(f.DB[jname].level):match("(%d+)%s*%-%s*(%d+)")
    if a then lo, hi, src = tonumber(a), tonumber(b), "journal" end
  end
  if not lo and activityID and C_LFGList and C_LFGList.GetActivityInfoTable then
    local ok, t = pcall(C_LFGList.GetActivityInfoTable, activityID)
    if ok and type(t) == "table" then
      local a = t.minLevelSuggestion or t.minLevel
      local b = t.maxLevelSuggestion or t.maxLevel
      if a and a > 0 and b and b > 0 then lo, hi, src = a, b, "client" end
    end
  end
  rangeCache[key] = lo and { lo, hi, src } or false
  return lo, hi, src
end

-- Every boss's loot for a dungeon: { {id, label}, ... }, plus whether the
-- journal marks the list as incomplete.
function J.Loot(name)
  local f = fdj()
  local jname = J.Find(name)
  if not (f and jname) then return nil end
  local d = f.DB[jname]
  local out = {}
  for _, boss in ipairs(d.bosses or {}) do
    for _, it in ipairs(boss.loot or {}) do
      if type(it) == "table" and tonumber(it[1]) then out[#out + 1] = { id = tonumber(it[1]), label = it[3] } end
    end
  end
  return out, d.fullItemsTBD and true or false, jname
end

local AMBIGUOUS = { st = true, ht = true, rl = true, gy = true, arm = true, lib = true, halls = true,
                    dal = true, zul = true, cath = true, downs = true, depths = true, sunken = true }

-- Which dungeon a chat message names, using the journal's nicknames
-- ("LFG rfk heal" -> Razorfen Kraul). Returns the journal name or nil.
function J.DungeonInText(lower)
  local f = fdj()
  if not (f and f.DUNGEON_SEARCH_ALIASES) then return nil end
  local padded = " " .. lower:gsub("[^%w' ]", " ") .. " "
  local best, bestLen
  for n, aliases in pairs(f.DUNGEON_SEARCH_ALIASES) do
    local all = { n:lower() }
    for _, a in ipairs(aliases) do all[#all + 1] = a end
    for _, a in ipairs(all) do
      a = a:lower()
      -- Whole words only, longest match wins. Nicknames that are everyday
      -- chat words ("st", "rl", "arm", "lib", "halls"...) are skipped.
      if not AMBIGUOUS[a] and padded:find(" " .. a .. " ", 1, true) and (not bestLen or #a > bestLen) then
        best, bestLen = n, #a
      end
    end
  end
  return best
end
