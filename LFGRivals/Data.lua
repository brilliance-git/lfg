-- LFG Rivals: gear-competition model.
-- Pure Lua (no WoW API calls) so it can be tested outside the game.

local ADDON, ns = ...
ns = ns or {}
local Data = {}
ns.Data = Data

-- Stat "families". Two specs only fight over an item if their families overlap.
--   agi   = agility physical (rogue, hunter, cat)
--   str   = strength physical (warrior dps, ret, enhancement)
--   tank  = defense/stamina/armor
--   spell = spell damage casters
--   heal  = +healing / mp5 healers
local STAT_SIM = {
  agi   = { agi = 1.0, str = 0.6, tank = 0.3, spell = 0.0, heal = 0.0 },
  str   = { agi = 0.6, str = 1.0, tank = 0.5, spell = 0.0, heal = 0.0 },
  tank  = { agi = 0.3, str = 0.5, tank = 1.0, spell = 0.0, heal = 0.0 },
  spell = { agi = 0.0, str = 0.0, tank = 0.0, spell = 1.0, heal = 0.3 },
  heal  = { agi = 0.0, str = 0.0, tank = 0.0, spell = 0.3, heal = 1.0 },
}
Data.STAT_SIM = STAT_SIM

-- How much each gear bucket matters to the final score (sums to 100).
Data.WEIGHTS = { armor = 45, accessories = 25, weapons = 20, set = 10 }

local RANGED_PHYS = { "bow", "gun", "xbow", "thrown" }
local CASTER_WEP  = { "staff", "dagger", "1h_sword", "offhand", "wand" }

local function list(...)
  local t = {}
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if type(v) == "table" then
      for _, x in ipairs(v) do t[#t + 1] = x end
    else
      t[#t + 1] = v
    end
  end
  return t
end

-- armor: preference weight per armor type (1 = what they chase at max level).
-- role:  HEALER / DAMAGER / TANK
Data.SPECS = {
  WARRIOR = {
    { key = "ARMS",  name = "Arms",       role = "DAMAGER", stat = "str",  armor = { plate = 1, mail = 0.3 },
      weapons = list("2h_sword", "2h_axe", "2h_mace", "polearm", RANGED_PHYS) },
    { key = "FURY",  name = "Fury",       role = "DAMAGER", stat = "str",  armor = { plate = 1, mail = 0.3 },
      weapons = list("1h_sword", "1h_axe", "1h_mace", "fist", "dagger", "2h_sword", "2h_axe", "2h_mace", RANGED_PHYS) },
    { key = "PROT",  name = "Protection", role = "TANK",    stat = "tank", armor = { plate = 1 },
      weapons = list("1h_sword", "1h_axe", "1h_mace", "shield", RANGED_PHYS) },
  },
  PALADIN = {
    { key = "HOLY",  name = "Holy",        role = "HEALER",  stat = "heal", armor = { plate = 1, cloth = 0.6, leather = 0.4 },
      weapons = list("1h_mace", "1h_sword", "shield", "offhand", "libram") },
    { key = "PROT",  name = "Protection",  role = "TANK",    stat = "tank", armor = { plate = 1 },
      weapons = list("1h_sword", "1h_mace", "1h_axe", "shield", "libram") },
    { key = "RET",   name = "Retribution", role = "DAMAGER", stat = "str",  armor = { plate = 1, mail = 0.3 },
      weapons = list("2h_sword", "2h_mace", "2h_axe", "polearm", "libram") },
  },
  HUNTER = {
    { key = "BM",    name = "Beast Mastery", role = "DAMAGER", stat = "agi", armor = { mail = 1, leather = 0.6 },
      weapons = list("bow", "gun", "xbow", "polearm", "2h_axe", "2h_sword", "staff", "1h_sword", "1h_axe", "dagger", "fist") },
    { key = "MM",    name = "Marksmanship",  role = "DAMAGER", stat = "agi", armor = { mail = 1, leather = 0.6 },
      weapons = list("bow", "gun", "xbow", "polearm", "2h_axe", "2h_sword", "staff", "1h_sword", "1h_axe", "dagger", "fist") },
    { key = "SURV",  name = "Survival",      role = "DAMAGER", stat = "agi", armor = { mail = 1, leather = 0.6 },
      weapons = list("bow", "gun", "xbow", "polearm", "2h_axe", "2h_sword", "staff", "1h_sword", "1h_axe", "dagger", "fist") },
  },
  ROGUE = {
    { key = "ASSA",  name = "Assassination", role = "DAMAGER", stat = "agi", armor = { leather = 1 },
      weapons = list("dagger", "1h_sword", "1h_mace", "fist", RANGED_PHYS) },
    { key = "COMBAT",name = "Combat",        role = "DAMAGER", stat = "agi", armor = { leather = 1 },
      weapons = list("1h_sword", "1h_mace", "fist", "dagger", RANGED_PHYS) },
    { key = "SUB",   name = "Subtlety",      role = "DAMAGER", stat = "agi", armor = { leather = 1 },
      weapons = list("dagger", "1h_sword", "fist", RANGED_PHYS) },
  },
  PRIEST = {
    { key = "DISC",  name = "Discipline", role = "HEALER",  stat = "heal",  armor = { cloth = 1 },
      weapons = list("staff", "1h_mace", "dagger", "offhand", "wand") },
    { key = "HOLY",  name = "Holy",       role = "HEALER",  stat = "heal",  armor = { cloth = 1 },
      weapons = list("staff", "1h_mace", "dagger", "offhand", "wand") },
    { key = "SHADOW",name = "Shadow",     role = "DAMAGER", stat = "spell", armor = { cloth = 1 },
      weapons = list("staff", "1h_mace", "dagger", "offhand", "wand") },
  },
  SHAMAN = {
    { key = "ELE",   name = "Elemental",   role = "DAMAGER", stat = "spell", armor = { mail = 1, leather = 0.5, cloth = 0.4 },
      weapons = list("1h_mace", "1h_axe", "staff", "dagger", "fist", "shield", "offhand", "totem") },
    { key = "ENH",   name = "Enhancement", role = "DAMAGER", stat = "str",   armor = { mail = 1, leather = 0.6 },
      weapons = list("2h_mace", "2h_axe", "staff", "1h_mace", "1h_axe", "fist", "totem") },
    { key = "RESTO", name = "Restoration", role = "HEALER",  stat = "heal",  armor = { mail = 1, leather = 0.5, cloth = 0.4 },
      weapons = list("1h_mace", "staff", "shield", "offhand", "totem") },
  },
  MAGE = {
    { key = "ARCANE",name = "Arcane", role = "DAMAGER", stat = "spell", armor = { cloth = 1 }, weapons = list(CASTER_WEP) },
    { key = "FIRE",  name = "Fire",   role = "DAMAGER", stat = "spell", armor = { cloth = 1 }, weapons = list(CASTER_WEP) },
    { key = "FROST", name = "Frost",  role = "DAMAGER", stat = "spell", armor = { cloth = 1 }, weapons = list(CASTER_WEP) },
  },
  WARLOCK = {
    { key = "AFFLI", name = "Affliction",  role = "DAMAGER", stat = "spell", armor = { cloth = 1 }, weapons = list(CASTER_WEP) },
    { key = "DEMO",  name = "Demonology",  role = "DAMAGER", stat = "spell", armor = { cloth = 1 }, weapons = list(CASTER_WEP) },
    { key = "DESTRO",name = "Destruction", role = "DAMAGER", stat = "spell", armor = { cloth = 1 }, weapons = list(CASTER_WEP) },
  },
  DRUID = {
    { key = "BALANCE",name = "Balance",      role = "DAMAGER", stat = "spell", armor = { leather = 1, cloth = 0.6 },
      weapons = list("staff", "1h_mace", "dagger", "offhand", "idol") },
    { key = "CAT",    name = "Feral (Cat)",  role = "DAMAGER", stat = "agi",   armor = { leather = 1 },
      weapons = list("2h_mace", "staff", "1h_mace", "dagger", "fist", "idol") },
    { key = "BEAR",   name = "Feral (Bear)", role = "TANK",    stat = "tank",  armor = { leather = 1 },
      weapons = list("2h_mace", "staff", "1h_mace", "idol") },
    { key = "RESTO",  name = "Restoration",  role = "HEALER",  stat = "heal",  armor = { leather = 1, cloth = 0.6 },
      weapons = list("staff", "1h_mace", "dagger", "offhand", "idol") },
  },
}

Data.CLASS_ORDER = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

-- Words people type in LFG comments / chat that pin down a spec.
Data.SPEC_KEYWORDS = {
  WARRIOR = { ARMS = { "arms" }, FURY = { "fury", "dw" }, PROT = { "prot", "tank" } },
  PALADIN = { HOLY = { "holy", "heal" }, PROT = { "prot", "tank" }, RET = { "ret" } },
  HUNTER  = { BM = { "bm", "beast" }, MM = { "mm", "marks" }, SURV = { "surv" } },
  ROGUE   = { ASSA = { "assa", "mutilate" }, COMBAT = { "combat", "swords" }, SUB = { "sub" } },
  PRIEST  = { DISC = { "disc" }, HOLY = { "holy", "heal" }, SHADOW = { "shadow", "spriest", "sp " } },
  SHAMAN  = { ELE = { "ele", "elemental" }, ENH = { "enh", "enhance" }, RESTO = { "resto", "heal" } },
  MAGE    = { ARCANE = { "arcane" }, FIRE = { "fire" }, FROST = { "frost" } },
  WARLOCK = { AFFLI = { "affli", "aff " }, DEMO = { "demo" }, DESTRO = { "destro" } },
  DRUID   = { BALANCE = { "balance", "boomkin", "moonkin", "boomy" }, CAT = { "cat", "kitty" },
              BEAR = { "bear", "tank" }, RESTO = { "resto", "heal", "tree" } },
}

function Data.GetSpec(class, specKey)
  local specs = Data.SPECS[class]
  if not specs then return nil end
  for _, s in ipairs(specs) do
    if s.key == specKey then return s end
  end
  return nil
end

-- Match a localized spec name (e.g. from the Group Finder) to our spec table.
function Data.SpecFromName(class, name)
  if not (class and name) then return nil end
  local specs = Data.SPECS[class]
  if not specs then return nil end
  local lname = name:lower()
  for _, s in ipairs(specs) do
    if s.name:lower() == lname or lname:find(s.key:lower(), 1, true) then return s end
  end
  return nil
end

-- Specs of a class that can fill a role (HEALER/DAMAGER/TANK). nil role = all.
function Data.SpecsForRole(class, role)
  local out = {}
  for _, s in ipairs(Data.SPECS[class] or {}) do
    if not role or s.role == role then out[#out + 1] = s end
  end
  return out
end

-- Pick the most likely spec(s) from class, role and free text.
-- Returns a list of candidate specs (1 = confident, >1 = ambiguous).
function Data.GuessSpecs(class, role, text)
  local candidates = Data.SpecsForRole(class, role)
  if #candidates == 0 then candidates = Data.SpecsForRole(class, nil) end
  if #candidates <= 1 or not text or text == "" then return candidates end

  local lower = " " .. text:lower() .. " "
  local kw = Data.SPEC_KEYWORDS[class] or {}
  local hits = {}
  for _, s in ipairs(candidates) do
    for _, word in ipairs(kw[s.key] or {}) do
      if lower:find(word, 1, true) then hits[#hits + 1] = s; break end
    end
  end
  if #hits > 0 then return hits end
  return candidates
end

local function armorOverlap(a, b)
  local total = 0
  for kind, wa in pairs(a) do
    local wb = b[kind]
    if wb then total = total + math.min(wa, wb) end
  end
  return math.min(total, 1)
end

local function weaponOverlap(a, b)
  if #a == 0 then return 0 end
  local set = {}
  for _, w in ipairs(b) do set[w] = true end
  local shared = 0
  for _, w in ipairs(a) do if set[w] then shared = shared + 1 end end
  return shared / #a
end

-- 0..100: how much `other` competes with `me` for the gear `me` wants.
function Data.Competition(meClass, meSpec, otherClass, otherSpec)
  if not (meSpec and otherSpec) then return nil end
  local W = Data.WEIGHTS
  local sim = STAT_SIM[meSpec.stat][otherSpec.stat] or 0

  local armor = armorOverlap(meSpec.armor, otherSpec.armor) * sim
  local acc   = sim
  local weps  = weaponOverlap(meSpec.weapons, otherSpec.weapons) * sim
  -- Same class = same tier set/tokens. Same class + different stat (e.g. holy vs ret
  -- paladin) still rolls on tier, so it counts even when stats don't line up.
  local set   = (meClass == otherClass) and 1 or 0

  local score = W.armor * armor + W.accessories * acc + W.weapons * weps + W.set * set
  return math.floor(score + 0.5)
end

-- Competition for an uncertain spec = average over the candidate specs.
function Data.CompetitionAny(meClass, meSpec, otherClass, candidates)
  if not meSpec or not candidates or #candidates == 0 then return nil end
  local sum = 0
  for _, s in ipairs(candidates) do sum = sum + Data.Competition(meClass, meSpec, otherClass, s) end
  return math.floor(sum / #candidates + 0.5)
end

---------------------------------------------------------------------------
-- Dungeon-aware model: score against the actual loot of one dungeon.
-- profile.items = { { kind = "armor"|"acc"|"weapon", type = "plate"|"2h_sword"|...,
--                     fam = { agi=, str=, tank=, spell=, heal= } (sums to 1, or nil) }, ... }
---------------------------------------------------------------------------

local function hasWeapon(spec, w)
  spec._wset = spec._wset or {}
  if spec._wset[w] == nil then
    local found = false
    for _, x in ipairs(spec.weapons) do if x == w then found = true; break end end
    spec._wset[w] = found
  end
  return spec._wset[w]
end

-- 0..1: how much a spec wants one item.
function Data.Desire(spec, item)
  local typeFit
  if item.kind == "armor" then
    typeFit = spec.armor[item.type] or 0
  elseif item.kind == "weapon" then
    typeFit = hasWeapon(spec, item.type) and 1 or 0
  else
    typeFit = 1          -- rings, necks, trinkets, cloaks: anyone, if the stats fit
  end
  if typeFit == 0 then return 0 end
  local statFit
  if item.fam then
    statFit = 0
    local row = STAT_SIM[spec.stat]
    for fam, share in pairs(item.fam) do statFit = statFit + share * (row[fam] or 0) end
  else
    -- Stats unknown (item not cached yet): type alone decides, accessories half.
    statFit = item.kind == "acc" and 0.5 or 1
  end
  return typeFit * statFit
end

local function desires(profile, spec)
  profile._desire = profile._desire or {}
  local d = profile._desire[spec]
  if not d then
    d = { total = 0 }
    for i, item in ipairs(profile.items) do
      d[i] = Data.Desire(spec, item)
      d.total = d.total + d[i]
    end
    profile._desire[spec] = d
  end
  return d
end

-- How much of this dungeon's loot `me` wants at all (0 = nothing for you here).
function Data.WantedHere(profile, meSpec)
  if not (profile and meSpec) then return nil end
  return desires(profile, meSpec).total
end

-- 0..100: share of the loot I want that `other` also wants.
function Data.CompetitionLoot(meSpec, otherSpec, profile)
  local mine, theirs = desires(profile, meSpec), desires(profile, otherSpec)
  if mine.total <= 0 then return 0 end
  local shared = 0
  for i = 1, #profile.items do shared = shared + math.min(mine[i], theirs[i]) end
  return math.floor(100 * shared / mine.total + 0.5)
end

-- The one scoring entry point: dungeon loot when we have it, else the general model.
function Data.Score(meClass, meSpec, otherClass, candidates, profile)
  if not meSpec or not candidates or #candidates == 0 then return nil end
  if not (profile and profile.items and #profile.items > 0) then
    return Data.CompetitionAny(meClass, meSpec, otherClass, candidates)
  end
  local sum = 0
  for _, s in ipairs(candidates) do sum = sum + Data.CompetitionLoot(meSpec, s, profile) end
  return math.floor(sum / #candidates + 0.5)
end

return Data
