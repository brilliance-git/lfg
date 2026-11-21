-- LFG Rivals: what drops in a dungeon, so the Rival score can use real loot.
-- Two sources, merged:
--   1. The Dungeon Journal (EJ_* API), if this client has one.
--   2. Drops you've seen yourself in that dungeon (loot window + loot chat),
--      saved in LFGRivalsDB.lootSeen, so custom dungeons fill in over time.
-- Items are classified with GetItemInfoInstant (armor type / weapon type /
-- accessory) and GetItemStats (which stat family wants them).

local ADDON, ns = ...
local Loot = {}
ns.Loot = Loot

local MIN_ITEMS = 4   -- fewer than this and the general model is more useful

local ARMOR  = { [1] = "cloth", [2] = "leather", [3] = "mail", [4] = "plate" }
local RELIC  = { [7] = "libram", [8] = "idol", [9] = "totem" }
local WEAPON = {
  [0] = "1h_axe", [1] = "2h_axe", [2] = "bow", [3] = "gun", [4] = "1h_mace", [5] = "2h_mace",
  [6] = "polearm", [7] = "1h_sword", [8] = "2h_sword", [10] = "staff", [13] = "fist",
  [15] = "dagger", [16] = "thrown", [18] = "xbow", [19] = "wand",
}
local ACC_SLOTS = { INVTYPE_NECK = true, INVTYPE_FINGER = true, INVTYPE_TRINKET = true, INVTYPE_CLOAK = true }
local GOOD_QUALITY = { "|cff1eff00", "|cff0070dd", "|cffa335ee", "|cffff8000" }  -- green and up

local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local getInfo    = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local getStats   = (C_Item and C_Item.GetItemStats) or GetItemStats

-- "Scarlet Monastery - Armory" / "Krol'dok Stronghold" -> "scarlet monastery armory"
local function norm(s)
  if not s then return "" end
  return (s:lower():gsub("[^%w ]", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end
Loot.Norm = norm

local function sameDungeon(a, b)
  a, b = norm(a), norm(b)
  if a == "" or b == "" then return false end
  return a == b or a:find(b, 1, true) ~= nil or b:find(a, 1, true) ~= nil
end

---------------------------------------------------------------------------
-- Item classification
---------------------------------------------------------------------------

local function itemIDFromLink(link)
  return type(link) == "string" and tonumber(link:match("|Hitem:(%d+)")) or nil
end

local function classify(itemID)
  if not getInstant then return nil end
  local ok, id, _, _, equipLoc, _, classID, subID = pcall(getInstant, itemID)
  if not ok or not id then return nil end
  if ACC_SLOTS[equipLoc] then return "acc", equipLoc:lower() end
  if equipLoc == "INVTYPE_HOLDABLE" then return "weapon", "offhand" end
  if equipLoc == "INVTYPE_SHIELD" or (classID == 4 and subID == 6) then return "weapon", "shield" end
  if classID == 4 and RELIC[subID] then return "weapon", RELIC[subID] end
  if classID == 4 and ARMOR[subID] then return "armor", ARMOR[subID] end
  if classID == 2 and WEAPON[subID] then return "weapon", WEAPON[subID] end
  return nil
end

-- Stat keys -> family shares. Returns fam (sums to 1), or nil if the item has
-- no useful stats / isn't cached yet (second value true = try again later).
local function family(itemID)
  if not (getInfo and getStats) then return nil end
  local link = select(2, getInfo(itemID))
  if not link then
    if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, itemID) end
    return nil, true
  end
  local ok, stats = pcall(getStats, link)
  if not ok or type(stats) ~= "table" then return nil end
  local f = { agi = 0, str = 0, tank = 0, spell = 0, heal = 0 }
  for key, v in pairs(stats) do
    v = tonumber(v) or 0
    if key:find("HEAL") or key:find("MANA_REGEN") or key:find("POWER_REGEN0") then f.heal = f.heal + v * 2
    elseif key:find("SPELL") then f.spell = f.spell + v * 2
    elseif key:find("AGILITY") then f.agi = f.agi + v
    elseif key:find("STRENGTH") then f.str = f.str + v
    elseif key:find("INTELLECT") then f.spell = f.spell + v * 0.5; f.heal = f.heal + v * 0.5
    elseif key:find("SPIRIT") then f.heal = f.heal + v * 0.7; f.spell = f.spell + v * 0.3
    elseif key:find("DEFENSE") or key:find("DODGE") or key:find("PARRY") or key:find("BLOCK") then f.tank = f.tank + v * 2
    elseif key:find("ATTACK_POWER") then f.agi = f.agi + v * 0.25; f.str = f.str + v * 0.25
    elseif key:find("CRIT") or key:find("HIT") then f.agi = f.agi + v * 5; f.str = f.str + v * 5
    elseif key:find("STAMINA") then f.tank = f.tank + v * 0.3
    end
  end
  local total = f.agi + f.str + f.tank + f.spell + f.heal
  if total <= 0 then return nil end
  for k, v in pairs(f) do f[k] = v / total end
  return f
end

---------------------------------------------------------------------------
-- Source 1: Dungeon Journal
---------------------------------------------------------------------------

Loot.journal = { available = (EJ_GetInstanceByIndex and EJ_SelectInstance and EJ_GetNumLoot) and true or false }

local function journalItems(name)
  if not Loot.journal.available then return nil end
  -- Selecting an instance would jump the journal around under you.
  if EncounterJournal and EncounterJournal.IsShown and EncounterJournal:IsShown() then return nil end
  local instanceID
  local tiers = (EJ_GetNumTiers and select(2, pcall(EJ_GetNumTiers))) or 1
  for t = 1, tonumber(tiers) or 1 do
    if EJ_SelectTier then pcall(EJ_SelectTier, t) end
    for _, raid in ipairs({ false, true }) do
      for i = 1, 200 do
        local ok, id, iname = pcall(EJ_GetInstanceByIndex, i, raid)
        if not ok or not id then break end
        if sameDungeon(iname, name) then instanceID = id; break end
      end
      if instanceID then break end
    end
    if instanceID then break end
  end
  if not instanceID then return nil end
  pcall(EJ_SelectInstance, instanceID)
  if EJ_ResetLootFilter then pcall(EJ_ResetLootFilter) end
  if EJ_SetLootFilter then pcall(EJ_SetLootFilter, 0, 0) end
  if C_EncounterJournal and C_EncounterJournal.ResetSlotFilter then pcall(C_EncounterJournal.ResetSlotFilter) end
  local ok, n = pcall(EJ_GetNumLoot)
  if not ok or not n then return nil end
  local ids = {}
  for i = 1, n do
    local itemID
    if C_EncounterJournal and C_EncounterJournal.GetLootInfoByIndex then
      local okI, info = pcall(C_EncounterJournal.GetLootInfoByIndex, i)
      if okI and type(info) == "table" then itemID = info.itemID or itemIDFromLink(info.link) end
    end
    if not itemID and EJ_GetLootInfoByIndex then
      local r = { pcall(EJ_GetLootInfoByIndex, i) }
      if r[1] then
        for k = 2, #r do itemID = itemID or itemIDFromLink(r[k]) end
      end
    end
    if itemID then ids[#ids + 1] = itemID end
  end
  return ids
end

---------------------------------------------------------------------------
-- Source 2: drops you've seen
---------------------------------------------------------------------------

local function currentInstance()
  if not (IsInInstance and GetInstanceInfo) then return nil end
  local inInst, kind = IsInInstance()
  if not inInst or (kind ~= "party" and kind ~= "raid") then return nil end
  return (GetInstanceInfo())
end

local function isGoodQuality(link)
  for _, c in ipairs(GOOD_QUALITY) do
    if link:find(c, 1, true) then return true end
  end
  return false
end

-- Record every green-or-better equippable item seen in a dungeon.
function Loot.Record(link)
  local inst = currentInstance()
  if not inst or type(link) ~= "string" or not isGoodQuality(link) then return end
  local itemID = itemIDFromLink(link)
  if not itemID or not classify(itemID) then return end
  local db = LFGRivalsDB
  db.lootSeen = db.lootSeen or {}
  local key = norm(inst)
  db.lootSeen[key] = db.lootSeen[key] or {}
  if not db.lootSeen[key][itemID] then
    db.lootSeen[key][itemID] = true
    ns.Log.Add("loot", "learned", link, "in", inst)
    Loot.Invalidate()
  end
end

local function seenItems(name)
  local seen = LFGRivalsDB and LFGRivalsDB.lootSeen
  if not seen then return nil end
  local ids
  for inst, items in pairs(seen) do
    if sameDungeon(inst, name) then
      ids = ids or {}
      for itemID in pairs(items) do ids[#ids + 1] = itemID end
    end
  end
  return ids
end

---------------------------------------------------------------------------
-- Profiles
---------------------------------------------------------------------------

local cache = {}

function Loot.Invalidate() wipe(cache) end

-- Returns a profile { name, items, journal = n, seen = n, pending = bool } or
-- nil when there's not enough loot data for this dungeon.
function Loot.ProfileFor(name)
  if not name or name == "" then return nil end
  local key = norm(name)
  local p = cache[key]
  if p ~= nil then return p or nil end

  local fromJournal = journalItems(name) or {}
  local fromSeen = seenItems(name) or {}
  local items, used, pending = {}, {}, false
  local function add(itemID)
    if used[itemID] then return end
    used[itemID] = true
    local kind, typ = classify(itemID)
    if not kind then return end
    local fam, later = family(itemID)
    if later then pending = true end
    items[#items + 1] = { id = itemID, kind = kind, type = typ, fam = fam }
  end
  for _, id in ipairs(fromJournal) do add(id) end
  for _, id in ipairs(fromSeen) do add(id) end

  if #items < MIN_ITEMS then
    cache[key] = false
    if not Loot.loggedMiss then Loot.loggedMiss = {} end
    if not Loot.loggedMiss[key] then
      Loot.loggedMiss[key] = true
      ns.Log.Add("loot", "no loot data for", name, "- journal items", #fromJournal, "seen", #fromSeen,
        "(journal API", Loot.journal.available, ")")
    end
    return nil
  end
  p = { name = name, items = items, journal = #fromJournal, seen = #fromSeen, pending = pending }
  cache[key] = p
  ns.Log.Add("loot", "profile", name, "items", #items, "journal", #fromJournal, "seen", #fromSeen,
    pending and "(some item stats still loading)" or "")
  -- Item stats arrive asynchronously; rebuild once they have (a few tries).
  Loot.retries = Loot.retries or {}
  if pending and (Loot.retries[key] or 0) < 5 then
    Loot.retries[key] = (Loot.retries[key] or 0) + 1
    C_Timer.After(3, function()
      if cache[key] == p then cache[key] = nil; if ns.Core then ns.Core.MarkDirty() end end
    end)
  end
  return p
end

-- One line for the window / options panel.
function Loot.Describe(p, name)
  if not name then return "|cff888888Rival score: general model (pick a dungeon for loot-based scores)|r" end
  if not p then
    return "|cff888888Rival score: general model - no loot data for " .. name
      .. " yet (learned as you see drops there)|r"
  end
  local src = {}
  if p.journal > 0 then src[#src + 1] = p.journal .. " from journal" end
  if p.seen > 0 then src[#src + 1] = p.seen .. " seen" end
  return "|cff40ff40Rival score uses " .. name .. " loot|r |cff888888(" .. #p.items .. " items: "
    .. table.concat(src, ", ") .. ")|r"
end
