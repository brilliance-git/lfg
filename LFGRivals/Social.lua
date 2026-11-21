-- LFG Rivals: who you know.
--   friends / guild : read from the game (refreshed on FRIENDLIST_UPDATE / GUILD_ROSTER_UPDATE)
--   favorite / avoid / note : yours, saved in LFGRivalsDB.people[name]
--   met : people you've been in a group with (LFGRivalsDB.met[name] = time), kept 60 days

local ADDON, ns = ...
local S = {}
ns.Social = S

local MET_TTL = 60 * 24 * 60 * 60
local friends, guild = {}, {}

local function short(name)
  if not name then return nil end
  if Ambiguate then return Ambiguate(name, "short") end
  return (name:gsub("%-.*$", ""))
end

function S.RefreshFriends()
  wipe(friends)
  if C_FriendList and C_FriendList.GetNumFriends then
    local ok, n = pcall(C_FriendList.GetNumFriends)
    for i = 1, (ok and n or 0) do
      local okI, info = pcall(C_FriendList.GetFriendInfoByIndex, i)
      if okI and type(info) == "table" and info.name then friends[short(info.name)] = true end
    end
  elseif GetNumFriends and GetFriendInfo then
    for i = 1, GetNumFriends() do
      local name = GetFriendInfo(i)
      if name then friends[short(name)] = true end
    end
  end
end

function S.RefreshGuild()
  wipe(guild)
  if not (IsInGuild and IsInGuild() and GetNumGuildMembers and GetGuildRosterInfo) then return end
  for i = 1, GetNumGuildMembers() do
    local name = GetGuildRosterInfo(i)
    if name then guild[short(name)] = true end
  end
end

-- Ask the server for the guild roster (answer arrives as GUILD_ROSTER_UPDATE).
function S.RequestGuild()
  if C_GuildInfo and C_GuildInfo.GuildRoster then pcall(C_GuildInfo.GuildRoster)
  elseif GuildRoster then pcall(GuildRoster) end
end

-- Remember everyone in your current group.
function S.RecordGroup()
  if not (GetNumGroupMembers and UnitName) then return end
  local n = GetNumGroupMembers()
  if n == 0 then return end
  local unit = IsInRaid and IsInRaid() and "raid" or "party"
  local now = time()
  local me = UnitName("player")
  for i = 1, n do
    local name = UnitName(unit .. i)
    if name and name ~= me and name ~= UNKNOWNOBJECT then LFGRivalsDB.met[short(name)] = now end
  end
end

function S.Prune()
  local now = time()
  for name, t in pairs(LFGRivalsDB.met) do
    if now - t > MET_TTL then LFGRivalsDB.met[name] = nil end
  end
  for name, p in pairs(LFGRivalsDB.people) do
    if not p.fav and not p.avoid and (not p.note or p.note == "") then LFGRivalsDB.people[name] = nil end
  end
end

-- Everything known about one name, or nil if nothing.
function S.Info(name)
  if not name then return nil end
  local p = LFGRivalsDB.people[name]
  local info = {
    friend = friends[name] or nil,
    guild = guild[name] or nil,
    fav = p and p.fav or nil,
    avoid = p and p.avoid or nil,
    note = p and p.note ~= "" and p.note or nil,
    met = LFGRivalsDB.met[name],
  }
  if not (info.friend or info.guild or info.fav or info.avoid or info.note or info.met) then return nil end
  info.trusted = info.fav or info.friend or info.guild
  return info
end

local function person(name)
  local p = LFGRivalsDB.people[name]
  if not p then p = {}; LFGRivalsDB.people[name] = p end
  return p
end

function S.ToggleFav(name)
  local p = person(name)
  p.fav = not p.fav or nil
  if p.fav then p.avoid = nil end
  ns.Core.MarkDirty()
end

function S.ToggleAvoid(name)
  local p = person(name)
  p.avoid = not p.avoid or nil
  if p.avoid then p.fav = nil end
  ns.Core.MarkDirty()
end

function S.SetNote(name, note)
  person(name).note = note and note:gsub("^%s+", ""):gsub("%s+$", "") or nil
  ns.Core.MarkDirty()
end

-- Short colored tags for a row: "fav friend guild met avoid note".
function S.Tags(info)
  if not info then return "" end
  local t = {}
  if info.fav then t[#t + 1] = "|cffffd100fav|r" end
  if info.friend then t[#t + 1] = "|cff40c0fffriend|r" end
  if info.guild then t[#t + 1] = "|cff40ff40guild|r" end
  if info.met then t[#t + 1] = "|cffaaaaaamet|r" end
  if info.avoid then t[#t + 1] = "|cffff4040avoid|r" end
  if info.note then t[#t + 1] = "|cffffffffnote|r" end
  return table.concat(t, " ")
end

-- Tooltip lines.
function S.AddTooltip(info)
  if not info then return end
  if info.fav then GameTooltip:AddLine("Favorite", 1, 0.82, 0) end
  if info.friend then GameTooltip:AddLine("On your friends list", 0.25, 0.75, 1) end
  if info.guild then GameTooltip:AddLine("In your guild", 0.25, 1, 0.25) end
  if info.met then
    local days = math.floor((time() - info.met) / 86400)
    GameTooltip:AddLine("You grouped with them " .. (days < 1 and "today" or (days .. " days ago")), 0.7, 0.7, 0.7)
  end
  if info.avoid then GameTooltip:AddLine("Marked avoid", 1, 0.25, 0.25) end
  if info.note then GameTooltip:AddLine("Note: " .. info.note, 1, 1, 1, true) end
end

---------------------------------------------------------------------------
-- Right-click menu (own small frame: dropdown APIs differ between clients)
---------------------------------------------------------------------------

-- Note editor: a small frame of our own. Never touch StaticPopupDialogs:
-- writing to that global taints Blizzard's popups, and the game then blames
-- LFG Rivals when one of them does a protected action.
local noteFrame
local function noteEditor()
  if noteFrame then return noteFrame end
  local f = CreateFrame("Frame", "LFGRivalsNote", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  f:SetSize(300, 96)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
  f:SetFrameStrata("DIALOG")
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  if f.SetBackdrop then
    f:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 24,
      insets = { left = 6, right = 6, top = 6, bottom = 6 } })
  end
  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.title:SetPoint("TOP", f, "TOP", 0, -14)
  local eb = CreateFrame("EditBox", "LFGRivalsNoteEdit", f, "InputBoxTemplate")
  eb:SetSize(250, 20)
  eb:SetPoint("TOP", f.title, "BOTTOM", 0, -8)
  eb:SetAutoFocus(false)
  eb:SetMaxLetters(120)
  f.edit = eb
  local function save() S.SetNote(f.name, eb:GetText()); f:Hide() end
  eb:SetScript("OnEnterPressed", save)
  eb:SetScript("OnEscapePressed", function() f:Hide() end)
  local ok = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  ok:SetSize(90, 22)
  ok:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -4, 12)
  ok:SetText(SAVE or "Save")
  ok:SetScript("OnClick", save)
  local cancel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  cancel:SetSize(90, 22)
  cancel:SetPoint("BOTTOMLEFT", f, "BOTTOM", 4, 12)
  cancel:SetText(CANCEL or "Cancel")
  cancel:SetScript("OnClick", function() f:Hide() end)
  f:SetScript("OnHide", function() eb:ClearFocus() end)
  tinsert(UISpecialFrames, "LFGRivalsNote")
  noteFrame = f
  return f
end

function S.EditNote(name)
  local f = noteEditor()
  f.name = name
  f.title:SetText("Note for " .. name .. ":")
  local p = LFGRivalsDB.people[name]
  f.edit:SetText(p and p.note or "")
  f:Show()
  f.edit:SetFocus()
  f.edit:HighlightText()
end

local menu
local function menuButton(i)
  local b = CreateFrame("Button", nil, menu)
  b:SetSize(150, 18)
  b:SetPoint("TOPLEFT", menu, "TOPLEFT", 8, -8 - (i - 1) * 18)
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.12)
  b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.text:SetPoint("LEFT", 4, 0)
  b:SetScript("OnClick", function(self) menu:Hide(); if self.fn then self.fn() end end)
  return b
end

-- items = { { text, fn }, ... }; shown at the cursor.
function S.ShowMenu(title, items)
  if not menu then
    menu = CreateFrame("Frame", "LFGRivalsMenu", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    menu:SetFrameStrata("DIALOG")
    menu:SetClampedToScreen(true)
    if menu.SetBackdrop then
      menu:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 } })
      menu:SetBackdropColor(0, 0, 0, 0.92)
    end
    menu.buttons = {}
    menu:EnableMouse(true)
    tinsert(UISpecialFrames, "LFGRivalsMenu")
    -- Close when the mouse has been away for a moment.
    local away = 0
    menu:SetScript("OnUpdate", function(self, el)
      if self:IsMouseOver(8, -8, -8, 8) then away = 0 else away = away + el end
      if away > 1.5 then self:Hide() end
    end)
  end
  local all = { { title = true, text = title } }
  for _, it in ipairs(items) do all[#all + 1] = it end
  for i, it in ipairs(all) do
    local b = menu.buttons[i] or menuButton(i)
    menu.buttons[i] = b
    b.text:SetText(it.title and ("|cffffd100" .. it.text .. "|r") or it.text)
    b.fn = it.fn
    b:EnableMouse(not it.title)
    b:Show()
  end
  for i = #all + 1, #menu.buttons do menu.buttons[i]:Hide() end
  menu:SetSize(166, 16 + #all * 18)
  local x, y = GetCursorPosition()
  local s = UIParent:GetEffectiveScale()
  menu:ClearAllPoints()
  menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / s - 10, y / s + 10)
  menu:Show()
end

-- The standard menu for a player name (row right-click).
function S.PlayerMenu(name, whisperFn)
  local p = LFGRivalsDB.people[name] or {}
  S.ShowMenu(name, {
    { text = "Whisper", fn = whisperFn },
    { text = "Invite", fn = function() ns.UI.Invite(name) end },
    { text = p.fav and "Remove favorite" or "Favorite", fn = function() S.ToggleFav(name) end },
    { text = p.avoid and "Stop avoiding" or "Avoid", fn = function() S.ToggleAvoid(name) end },
    { text = (p.note and p.note ~= "") and "Edit note..." or "Add note...",
      fn = function() S.EditNote(name) end },
    { text = "|cff888888Cancel|r" },
  })
end
