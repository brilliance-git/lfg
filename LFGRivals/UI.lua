-- LFG Rivals: window. Two tabs: Players (solo + chat LFG) and Groups (listed
-- groups with their current makeup). Resizable from the bottom-right corner.

local ADDON, ns = ...
local UI = {}
ns.UI = UI

local ROW_H, GROUP_H = 24, 42
local DEFAULT_W, DEFAULT_H = 600, 540
local MIN_W, MIN_H, MAX_W, MAX_H = 580, 380, 1200, 1000   -- narrower and row 2 overlaps
local ROLE_LABEL = {
  HEALER  = "|cff40ff40Heal|r",
  TANK    = "|cff4da6ffTank|r",
  DAMAGER = "|cffff6060DPS|r",
}
local ROLE_WORD = { HEALER = "healer", TANK = "tank", DAMAGER = "DPS" }
local SECTION = {
  HEALER  = "Healers",
  TANK    = "Tanks",
  DAMAGER = "DPS - least gear competition first",
}
local ROLE_ORDER = { TANK = 1, HEALER = 2, DAMAGER = 3 }
local MAX_ICONS = 10
local ICON_STEP = 20

local frame, scroll, content, statusText, scanText, lootText, refreshBtn, pollBtn, classBtn, specBtn
local catPicker, actPicker, tankCB, playersTab, groupsTab, searchHint, buildBtn
local rows, gRows = {}, {}
local headers = { players = {}, groups = {} }
local hMakeup, hRival
local ROW1, ROW2, ROW3 = -30, -60, -92   -- me/refresh, category/activity, tabs/toggles

local function classColor(class)
  local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
  if c then return string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255) end
  return "|cffcccccc"
end

local function scoreColor(s)
  if not s then return "|cff888888" end
  local t = math.min(math.max(s / 100, 0), 1)
  return string.format("|cff%02x%02x40", 64 + 191 * t, 255 - 191 * t)
end

local function className(class)
  if LOCALIZED_CLASS_NAMES_MALE and class and LOCALIZED_CLASS_NAMES_MALE[class] then
    return LOCALIZED_CLASS_NAMES_MALE[class]
  end
  return class and (class:sub(1, 1) .. class:sub(2):lower()) or "?"
end

local function ago(t)
  local m = math.floor((time() - t) / 60)
  if m < 1 then return "just now" end
  if m < 60 then return m .. "m ago" end
  return math.floor(m / 60) .. "h" .. (m % 60) .. "m ago"
end

---------------------------------------------------------------------------
-- Whisper / invite
---------------------------------------------------------------------------

-- {name} {dungeon} {role} {me} -> text. Unknown placeholders are left alone.
local function fillTemplate(template, ctx)
  if not template or template == "" then return nil end
  return (template:gsub("{(%a+)}", function(k) return ctx[k] end))
end

local function myLabel()
  local class, spec = ns.Core.Me()
  return ((spec and spec.name:gsub("^Feral %((%a+)%)$", "Feral") or "") .. " " .. className(class)):gsub("^ ", "")
end

-- WoW Forever names contain spaces ("Abaddon Revantusk"), so "/w <name>"
-- would whisper "Abaddon" with the message "Revantusk". SendTell sets the
-- whole name as the whisper target instead. The message is only typed in;
-- you press Enter to send it.
function UI.Whisper(name, text)
  ns.Log.Add("ui", "whisper", name)
  ns.Core.MarkContacted(name, "whisper")
  if ChatFrame_SendTell then
    ChatFrame_SendTell(name)
  elseif ChatFrameUtil and ChatFrameUtil.SendTell then
    ChatFrameUtil.SendTell(name)
  elseif ChatFrame_OpenChat then
    ChatFrame_OpenChat("/w " .. name .. " ")
  end
  if text and text ~= "" then
    local eb = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
    if eb then eb:Insert(text) end
  end
end

function UI.Invite(name)
  ns.Log.Add("ui", "invite", name)
  ns.Core.MarkContacted(name, "invite")
  if C_PartyInfo and C_PartyInfo.InviteUnit then C_PartyInfo.InviteUnit(name)
  elseif InviteUnit then InviteUnit(name) end
end

local function whisperPlayer(e)
  local dungeon = ns.Sources.ActivityName(LFGRivalsDB.activityID) or "a dungeon"
  UI.Whisper(e.name, fillTemplate(LFGRivalsDB.whisperMsg, {
    name = e.name:match("^(%S+)") or e.name, dungeon = dungeon,
    role = ROLE_WORD[e.role] or "player", me = myLabel(),
  }))
end

local function whisperLeader(g)
  UI.Whisper(g.leader, fillTemplate(LFGRivalsDB.groupWhisperMsg, {
    name = g.leader:match("^(%S+)") or g.leader, dungeon = g.activity ~= "" and g.activity or "dungeon",
    role = "leader", me = myLabel(),
  }))
end

---------------------------------------------------------------------------
-- Small widgets
---------------------------------------------------------------------------

local function smallButton(parent, text, w, h)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w or 24, h or 18)
  b:SetText(text)
  return b
end
UI.SmallButton = smallButton

-- Round role icon (tank shield / healer cross / dps swords).
local ROLE_TEX = "Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES"
local ROLE_COORDS = {
  TANK    = { 0, 19 / 64, 22 / 64, 41 / 64 },
  HEALER  = { 20 / 64, 39 / 64, 1 / 64, 20 / 64 },
  DAMAGER = { 20 / 64, 39 / 64, 22 / 64, 41 / 64 },
}
local function setRoleIcon(tex, role)
  tex:SetTexture(ROLE_TEX)
  local c
  if GetTexCoordsForRoleSmallCircle then
    local ok, a, b, cc, d = pcall(GetTexCoordsForRoleSmallCircle, role)
    if ok and a then c = { a, b, cc, d } end
  end
  c = c or ROLE_COORDS[role] or ROLE_COORDS.DAMAGER
  tex:SetTexCoord(c[1], c[2], c[3], c[4])
end

local function checkbox(parent, label, key, x)
  local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  cb:SetSize(22, 22)
  cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, ROW3)
  local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
  fs:SetText(label)
  cb:SetScript("OnShow", function(self) self:SetChecked(LFGRivalsDB[key]) end)
  cb:SetScript("OnClick", function(self)
    LFGRivalsDB[key] = self:GetChecked() and true or false
    UI.Refresh()
  end)
  return cb
end

---------------------------------------------------------------------------
-- Pickers: a Blizzard-style dropdown when UIDropDownMenu exists, otherwise a
-- button that cycles (left-click forward, right-click back).
---------------------------------------------------------------------------

local function makePicker(name, parent, width, getItems, getSelected, onPick)
  local p = {}
  local function labelFor(id)
    for _, it in ipairs(getItems()) do if it.id == id then return it.name end end
    return "|cff888888Pick...|r"
  end

  if UIDropDownMenu_Initialize and UIDropDownMenu_CreateInfo then
    local dd = CreateFrame("Frame", name, parent, "UIDropDownMenuTemplate")
    UIDropDownMenu_SetWidth(dd, width)
    UIDropDownMenu_Initialize(dd, function(_, level)
      for _, it in ipairs(getItems()) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = it.name
        info.checked = (it.id == getSelected())
        info.func = function() onPick(it.id) end
        UIDropDownMenu_AddButton(info, level)
      end
    end)
    p.frame = dd
    p.Update = function() UIDropDownMenu_SetText(dd, labelFor(getSelected())) end
  else
    local b = smallButton(parent, "", width + 20)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", function(_, btn)
      local items, cur = getItems(), 0
      if #items == 0 then return end
      for i, it in ipairs(items) do if it.id == getSelected() then cur = i end end
      cur = (cur - 1 + (btn == "RightButton" and -1 or 1)) % #items + 1
      onPick(items[cur].id)
    end)
    p.frame = b
    p.Update = function() b:SetText(labelFor(getSelected())) end
  end
  return p
end

local function categoryItems() return ns.Sources.GetCategories() end
local function activityItems()
  local items = { { id = 0, name = "All" } }
  for _, a in ipairs(ns.Sources.GetActivities(LFGRivalsDB.categoryID)) do items[#items + 1] = a end
  return items
end

local function updatePickers()
  local db = LFGRivalsDB
  if not db.categoryID then
    local cats = categoryItems()
    if cats[1] then db.categoryID = cats[1].id end
  end
  catPicker.Update()
  actPicker.Update()
end

---------------------------------------------------------------------------
-- Player rows (also used for section headers, optionally with a button)
---------------------------------------------------------------------------

local function showPlayerTooltip(row)
  local d = row.data
  if not d or d.section then return end
  local e = d.entry
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:AddLine(classColor(e.class) .. e.name .. "|r" .. (e.level and ("  level " .. e.level) or ""))
  GameTooltip:AddLine(className(e.class) .. " - " .. (#d.specs == 1 and d.specs[1].name or "spec unknown"), 1, 1, 1)
  if #d.specs > 1 then
    local names = {}
    for _, s in ipairs(d.specs) do names[#names + 1] = s.name end
    GameTooltip:AddLine("Could be: " .. table.concat(names, ", ") .. " (score is the average)", 0.7, 0.7, 0.7, true)
  end
  if d.score then
    GameTooltip:AddLine("Gear competition: " .. scoreColor(d.score) .. d.score .. "/100|r", 1, 1, 1)
  end
  GameTooltip:AddLine("Source: " .. (e.source == "chat" and "Chat" or "Group Finder"), 0.7, 0.7, 0.7)
  if d.contacted then
    GameTooltip:AddLine("You " .. (d.contacted.how == "invite" and "invited" or "whispered") .. " them "
      .. ago(d.contacted.t), 1, 0.6, 0.2)
  end
  if e.comment and e.comment ~= "" then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(e.comment, 1, 0.82, 0, true)
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Click: whisper   Shift-click: invite", 0.5, 0.8, 1)
  GameTooltip:Show()
end

local function rowText(r, x, w, justify, font)
  local s = r:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
  s:SetPoint("LEFT", r, "LEFT", x, 0)
  if w then s:SetWidth(w) end
  s:SetJustifyH(justify or "LEFT")
  s:SetWordWrap(false)
  return s
end

local function makeRow(i)
  local r = CreateFrame("Button", nil, content)
  r:SetHeight(ROW_H)
  r:RegisterForClicks("LeftButtonUp")

  local hl = r:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.08)

  r.bg = r:CreateTexture(nil, "BACKGROUND")
  r.bg:SetAllPoints()
  r.bg:SetColorTexture(1, 0.82, 0, 0.07)

  r.role    = rowText(r, 4, 36)
  r.name    = rowText(r, 42, 122)
  r.level   = rowText(r, 166, 30, "CENTER")
  r.score   = rowText(r, 198, 36, "RIGHT")
  r.wBtn = smallButton(r, "W", 32, 22)
  r.wBtn:SetPoint("RIGHT", r, "RIGHT", -40, 0)
  r.wBtn:SetScript("OnClick", function() whisperPlayer(r.data.entry) end)
  r.iBtn = smallButton(r, "+", 32, 22)
  r.iBtn:SetPoint("RIGHT", r, "RIGHT", -4, 0)
  r.iBtn:SetScript("OnClick", function() UI.Invite(r.data.entry.name) end)
  r.comment = rowText(r, 244, nil)
  r.comment:SetPoint("RIGHT", r.wBtn, "LEFT", -6, 0)

  r.header  = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  r.header:SetPoint("LEFT", r, "LEFT", 4, 0)
  r.action = smallButton(r, "", 110, 20)
  r.action:SetPoint("RIGHT", r, "RIGHT", -4, 0)
  r.action:SetScript("OnClick", function() if r.data and r.data.action then r.data.action.fn() end end)

  r:SetScript("OnEnter", showPlayerTooltip)
  r:SetScript("OnLeave", function() GameTooltip:Hide() end)
  r:SetScript("OnClick", function(self)
    if not self.data or self.data.section then return end
    if IsShiftKeyDown() then UI.Invite(self.data.entry.name) else whisperPlayer(self.data.entry) end
  end)
  rows[i] = r
  return r
end

local function setRow(r, d)
  r.data = d
  local isHeader = d.section ~= nil
  for _, k in ipairs({ "role", "name", "level", "score", "comment" }) do r[k]:SetShown(not isHeader) end
  r.wBtn:SetShown(not isHeader)
  r.iBtn:SetShown(not isHeader)
  r.header:SetShown(isHeader)
  r.action:SetShown(isHeader and d.action ~= nil)
  r.bg:SetShown(d.plan == true)
  r:SetAlpha(1)
  if isHeader then
    r.header:SetText(d.section)
    if d.action then r.action:SetText(d.action.text) end
    return
  end
  local e = d.entry
  local tag = ""
  if d.contacted then
    tag = d.contacted.how == "invite" and " |cffff9933inv|r" or " |cffff9933w|r"
    r:SetAlpha(0.55)
  end
  r.role:SetText(ROLE_LABEL[e.role] or "?")
  r.name:SetText(classColor(e.class) .. e.name .. "|r" .. (e.source == "chat" and " |cff888888(chat)|r" or "") .. tag)
  r.level:SetText(e.level and tostring(e.level) or "|cff888888?|r")
  r.score:SetText(d.score and (scoreColor(d.score) .. d.score .. "|r") or "|cff888888-|r")
  r.comment:SetText(e.comment or "")
end

---------------------------------------------------------------------------
-- Group rows: crown + leader, activity, note | role icons + empty slots | rival
---------------------------------------------------------------------------

local function sortedMembers(g)
  local list = {}
  for _, m in ipairs(g.members) do list[#list + 1] = m end
  table.sort(list, function(a, b) return (ROLE_ORDER[a.role] or 4) < (ROLE_ORDER[b.role] or 4) end)
  return list
end

-- Roles still wanted, one per empty slot, in tank/healer/dps order.
local function openSlots(g, filled)
  local out = {}
  local rem = g.remaining
  if rem then
    for _, role in ipairs({ "TANK", "HEALER", "DAMAGER" }) do
      for _ = 1, rem[role] or 0 do out[#out + 1] = role end
    end
  end
  while filled + #out < g.max do out[#out + 1] = false end   -- open, role unknown
  return out
end

local function showGroupTooltip(row)
  local d = row.data
  if not d or not d.group then return end
  local g = d.group
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:AddLine(classColor(g.leaderClass) .. g.leader .. "|r")
  GameTooltip:AddLine(g.activity .. "  (" .. g.size .. "/" .. g.max .. ")", 1, 1, 1)
  if d.score then
    GameTooltip:AddLine("Worst gear rival in group: " .. scoreColor(d.score) .. d.score .. "/100|r", 1, 1, 1)
  end
  if d.contacted then
    GameTooltip:AddLine("You whispered the leader " .. ago(d.contacted.t), 1, 0.6, 0.2)
  end
  GameTooltip:AddLine(" ")
  for _, m in ipairs(sortedMembers(g)) do
    GameTooltip:AddLine((ROLE_LABEL[m.role] or "?") .. "  " .. classColor(m.class)
      .. (m.name or (m.class and className(m.class)) or "Unknown") .. "|r"
      .. (m.level and ("  " .. m.level) or ""))
  end
  if g.comment ~= "" then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(g.comment, 1, 0.82, 0, true)
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Click: whisper leader   Hover an icon: that member", 0.5, 0.8, 1)
  GameTooltip:Show()
end

-- One member (or open slot) under the mouse.
local function showIconTooltip(icon)
  local m, row = icon.member, icon.row
  if not row.data then return end
  GameTooltip:SetOwner(icon, "ANCHOR_TOP")
  if m then
    GameTooltip:AddLine(classColor(m.class) .. (m.name or (m.class and className(m.class)) or "Unknown") .. "|r")
    GameTooltip:AddLine((m.class and className(m.class) or "Class unknown")
      .. (m.level and ("  level " .. m.level) or "") .. "  " .. (ROLE_LABEL[m.role] or ""), 1, 1, 1)
    local s = ns.Core.MemberScore(m, row.data.profile)
    if s then GameTooltip:AddLine("Gear competition: " .. scoreColor(s) .. s .. "/100|r", 1, 1, 1) end
  else
    GameTooltip:AddLine("Open slot")
    GameTooltip:AddLine(icon.wants and ("Looking for: " .. ROLE_WORD[icon.wants]) or "Any role", 1, 1, 1)
  end
  GameTooltip:Show()
end

local function makeGroupRow(i)
  local r = CreateFrame("Button", nil, content)
  r:SetHeight(GROUP_H)
  r:RegisterForClicks("LeftButtonUp")

  local hl = r:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.08)

  r.crown = r:CreateTexture(nil, "ARTWORK")
  r.crown:SetTexture("Interface\\GroupFrame\\UI-Group-LeaderIcon")
  r.crown:SetSize(14, 14)
  r.crown:SetPoint("TOPLEFT", r, "TOPLEFT", 4, -4)

  r.leader = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  r.leader:SetPoint("TOPLEFT", r, "TOPLEFT", 22, -4)
  r.leader:SetJustifyH("LEFT")
  r.leader:SetWordWrap(false)

  r.sub = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.sub:SetPoint("TOPLEFT", r, "TOPLEFT", 22, -22)
  r.sub:SetJustifyH("LEFT")
  r.sub:SetWordWrap(false)

  r.wBtn = smallButton(r, "W", 32, 22)
  r.wBtn:SetPoint("RIGHT", r, "RIGHT", -4, 0)
  r.wBtn:SetScript("OnClick", function() whisperLeader(r.data.group) end)
  r.score = rowText(r, 0, 30, "RIGHT")
  r.score:ClearAllPoints()
  r.score:SetPoint("RIGHT", r.wBtn, "LEFT", -8, 0)

  -- Icons are buttons so each one can show its own member on hover.
  r.icons = {}
  for k = 1, MAX_ICONS do
    local b = CreateFrame("Button", nil, r)
    b:SetSize(20, 20)
    b.tex = b:CreateTexture(nil, "ARTWORK")
    b.tex:SetAllPoints()
    b.bar = b:CreateTexture(nil, "OVERLAY")
    b.bar:SetSize(16, 3)
    b.bar:SetPoint("TOP", b, "BOTTOM", 0, -1)
    b.row = r
    b:SetScript("OnEnter", showIconTooltip)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnClick", function() if r.data then whisperLeader(r.data.group) end end)
    r.icons[k] = b
  end
  r.count = rowText(r, 0, 180, "LEFT")

  r:SetScript("OnEnter", showGroupTooltip)
  r:SetScript("OnLeave", function() GameTooltip:Hide() end)
  r:SetScript("OnClick", function(self) if self.data then whisperLeader(self.data.group) end end)
  gRows[i] = r
  return r
end

-- Column positions for the current width (window is resizable).
local function groupColumns()
  local w = content:GetWidth()
  local right = 4 + 32 + 8 + 30 + 12            -- W button, score, gap
  local iconsX = w - right - MAX_ICONS * ICON_STEP
  return iconsX, iconsX - 22 - 8                 -- icons start, leader/sub width
end

local function setGroupRow(r, d)
  r.data = d
  local g = d.group
  local iconsX, textW = groupColumns()
  r.leader:SetWidth(textW)
  r.sub:SetWidth(textW)
  r.leader:SetText(classColor(g.leaderClass) .. g.leader .. "|r"
    .. (d.contacted and " |cffff9933w|r" or ""))
  local sub = "|cffaaaaaa" .. g.activity .. "|r"
  if g.comment ~= "" then sub = sub .. "  |cff40ff40" .. g.comment .. "|r" end
  r.sub:SetText(sub)
  r:SetAlpha(d.contacted and 0.55 or 1)

  local members = sortedMembers(g)
  if g.max <= MAX_ICONS then
    r.count:Hide()
    local open = openSlots(g, #members)
    for k = 1, MAX_ICONS do
      local b = r.icons[k]
      b:ClearAllPoints()
      b:SetPoint("LEFT", r, "LEFT", iconsX + (k - 1) * ICON_STEP, 2)
      local m = members[k]
      if m and (m.role or m.class) then
        setRoleIcon(b.tex, m.role or "DAMAGER")
        b.tex:SetDesaturated(false)
        b.tex:SetAlpha(1)
        local c = m.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[m.class]
        if c then b.bar:SetColorTexture(c.r, c.g, c.b, 1); b.bar:Show() else b.bar:Hide() end
        b.member, b.wants = m, nil
        b:Show()
      elseif k <= g.max then
        local wants = open[k - #members]
        setRoleIcon(b.tex, wants or "DAMAGER")   -- empty slot: faded, shows the role wanted
        b.tex:SetDesaturated(true)
        b.tex:SetAlpha(wants and 0.35 or 0.15)
        b.bar:Hide()
        b.member, b.wants = nil, wants or nil
        b:Show()
      else
        b:Hide()
      end
    end
  else
    -- Raids: icons would overflow, show counts instead.
    for k = 1, MAX_ICONS do r.icons[k]:Hide() end
    local c = { TANK = 0, HEALER = 0, DAMAGER = 0 }
    for _, m in ipairs(members) do if m.role then c[m.role] = c[m.role] + 1 end end
    r.count:ClearAllPoints()
    r.count:SetPoint("LEFT", r, "LEFT", iconsX, 0)
    r.count:SetText(string.format("%d/%d   |cff4da6ff%dT|r |cff40ff40%dH|r |cffff6060%dD|r",
      g.size, g.max, c.TANK, c.HEALER, c.DAMAGER))
    r.count:Show()
  end
  r.score:SetText(d.score and (scoreColor(d.score) .. d.score .. "|r") or "|cff888888-|r")
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------

local function updateMe()
  local db = LFGRivalsDB
  local spec = ns.Data.GetSpec(db.class, db.spec)
  classBtn:SetText(classColor(db.class) .. className(db.class) .. "|r")
  specBtn:SetText((spec and spec.name or "?") .. (db.specLocked and "" or " (auto)"))
end

local function updatePoll()
  local secs = LFGRivalsDB.pollInterval
  pollBtn:SetText(secs > 0 and ("Auto: " .. secs .. "s") or "Auto: off")
  local left, due = ns.Core.PollStatus()
  if ns.Sources.searchBlocked then
    statusText:SetText("|cffff6060Addon searches blocked - see /rivals log.|r")
  elseif not left then
    statusText:SetText("|cff888888Auto-refresh off.|r")
  elseif due then
    if InCombatLockdown and InCombatLockdown() then
      statusText:SetText("|cffffd100Refresh due - waits for end of combat.|r")
    else
      statusText:SetText("|cffffd100Refresh due - next key press.|r")
    end
  else
    statusText:SetText("|cff888888Next refresh in " .. left .. "s (on key press).|r")
  end
  if due then refreshBtn:LockHighlight() else refreshBtn:UnlockHighlight() end

  local sc, s = ns.Sources.lastScan, ns.Sources.lastSearch
  if s and not s.ok then
    scanText:SetText("|cffff6060Search failed - type /rivals log|r")
  elseif sc then
    scanText:SetText(string.format("|cff888888Last results: %d listings, %.0fs ago|r", sc.total, GetTime() - sc.at))
  else
    scanText:SetText("|cff888888No results yet|r")
  end
end

local function setTab(tab)
  LFGRivalsDB.tab = tab
  UI.Refresh()
end

local function header(set, x, text)
  local h = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  h:SetPoint("TOPLEFT", frame, "TOPLEFT", 12 + x, ROW3 - 30)
  h:SetText(text)
  headers[set][#headers[set] + 1] = h
  return h
end

local function setBounds(f)
  if f.SetResizeBounds then
    f:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
  else
    if f.SetMinResize then f:SetMinResize(MIN_W, MIN_H) end
    if f.SetMaxResize then f:SetMaxResize(MAX_W, MAX_H) end
  end
end

local function build()
  local db = LFGRivalsDB
  frame = CreateFrame("Frame", "LFGRivalsFrame", UIParent, "BasicFrameTemplateWithInset")
  local w = db.size and db.size[1] or DEFAULT_W
  local h = db.size and db.size[2] or DEFAULT_H
  frame:SetSize(math.max(MIN_W, math.min(MAX_W, w)), math.max(MIN_H, math.min(MAX_H, h)))
  frame:SetPoint("CENTER")
  frame:SetMovable(true)
  frame:SetResizable(true)
  setBounds(frame)
  frame:SetClampedToScreen(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetFrameStrata("MEDIUM")
  tinsert(UISpecialFrames, "LFGRivalsFrame")

  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  title:SetPoint("TOP", frame, "TOP", 0, -5)
  title:SetText("LFG Rivals")

  -- Row 1: me + refresh
  local me = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  me:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, ROW1 - 4)
  me:SetText("Me:")

  classBtn = smallButton(frame, "", 100)
  classBtn:SetPoint("LEFT", me, "RIGHT", 6, 0)
  classBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  classBtn:SetScript("OnClick", function(_, btn) ns.Core.CycleClass(btn == "RightButton" and -1 or 1); UI.Refresh() end)

  specBtn = smallButton(frame, "", 130)
  specBtn:SetPoint("LEFT", classBtn, "RIGHT", 4, 0)
  specBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  specBtn:SetScript("OnClick", function(_, btn) ns.Core.CycleSpec(btn == "RightButton" and -1 or 1); UI.Refresh() end)

  -- One search per click/keypress is allowed (a second call in the same
  -- keypress is what got blocked in v0.2).
  refreshBtn = smallButton(frame, "Refresh", 80)
  refreshBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, ROW1)
  refreshBtn:SetScript("OnClick", function() ns.Core.ManualRefresh("refresh button") end)

  pollBtn = smallButton(frame, "", 84)
  pollBtn:SetPoint("RIGHT", refreshBtn, "LEFT", -4, 0)
  pollBtn:SetScript("OnClick", function() ns.Core.CyclePoll(); updatePoll() end)

  -- Row 2: category -> activity. Searching from a dropdown pick is blocked by
  -- the client (not a hardware event by the time it reaches us), so a pick only
  -- makes a refresh due: it fires on your next key press or Refresh click.
  local searchLbl = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  searchLbl:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, ROW2 - 8)
  searchLbl:SetText("Search:")

  catPicker = makePicker("LFGRivalsCategoryDropDown", frame, 130, categoryItems,
    function() return LFGRivalsDB.categoryID end,
    function(id)
      LFGRivalsDB.categoryID, LFGRivalsDB.activityID = id, 0
      updatePickers()
      ns.Core.MarkDue("category picked")
    end)
  catPicker.frame:SetPoint("TOPLEFT", frame, "TOPLEFT", 50, ROW2)

  actPicker = makePicker("LFGRivalsActivityDropDown", frame, 190, activityItems,
    function() return LFGRivalsDB.activityID end,
    function(id)
      LFGRivalsDB.activityID = id
      updatePickers()
      ns.Core.MarkDue("activity picked")
    end)
  actPicker.frame:SetPoint("LEFT", catPicker.frame, "RIGHT", 0, 0)

  searchHint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  searchHint:SetPoint("TOPLEFT", frame, "TOPLEFT", 66, ROW2 - 9)
  searchHint:SetText("Addon searches were blocked - search in Blizzard's LFG window. (/rivals unblock to retry)")

  buildBtn = smallButton(frame, "Build group", 100, 22)
  buildBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, ROW2 - 2)
  buildBtn:SetScript("OnClick", function()
    LFGRivalsDB.buildMode = not LFGRivalsDB.buildMode
    if LFGRivalsDB.buildMode then LFGRivalsDB.tab = "players" end
    UI.Refresh()
  end)
  buildBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Build my group")
    GameTooltip:AddLine("Suggests the best tank, healer and DPS for your open slots"
      .. " (lowest gear rivals first), then invite them one click at a time.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  buildBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- Row 3: tabs + toggles + options
  playersTab = smallButton(frame, "Players", 80, 22)
  playersTab:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, ROW3)
  playersTab:SetScript("OnClick", function() setTab("players") end)
  groupsTab = smallButton(frame, "Groups", 80, 22)
  groupsTab:SetPoint("LEFT", playersTab, "RIGHT", 4, 0)
  groupsTab:SetScript("OnClick", function() setTab("groups") end)

  tankCB = checkbox(frame, "Show tanks", "showTanks", 196)
  checkbox(frame, "Include chat LFG", "useChat", 300)

  local optBtn = smallButton(frame, "Options", 80, 22)
  optBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, ROW3)
  optBtn:SetScript("OnClick", function() ns.Options.Toggle() end)

  header("players", 4, "Role")
  header("players", 42, "Name")
  header("players", 166, "Level")
  header("players", 200, "Rival")
  header("players", 244, "Note")
  header("groups", 22, "Leader / activity")
  hMakeup = header("groups", 0, "Makeup")
  hRival = header("groups", 0, "Rival")

  scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, ROW3 - 44)
  scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -32, 46)
  content = CreateFrame("Frame", nil, scroll)
  content:SetSize(frame:GetWidth() - 44, 1)
  scroll:SetScrollChild(content)

  lootText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  lootText:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 28)
  lootText:SetPoint("RIGHT", frame, "RIGHT", -30, 0)
  lootText:SetJustifyH("LEFT")
  lootText:SetWordWrap(false)
  statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  statusText:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 10)
  scanText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  scanText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -26, 10)

  -- Resize grip (bottom-right corner).
  local grip = CreateFrame("Button", nil, frame)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 4)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
  grip:SetScript("OnMouseUp", function()
    frame:StopMovingOrSizing()
    LFGRivalsDB.size = { math.floor(frame:GetWidth() + 0.5), math.floor(frame:GetHeight() + 0.5) }
    UI.Refresh()
  end)
  frame:SetScript("OnSizeChanged", function()
    if content then content:SetWidth(frame:GetWidth() - 44) end
    ns.Core.MarkDirty()
  end)

  local acc = 0
  frame:SetScript("OnUpdate", function(_, elapsed)
    acc = acc + elapsed
    if acc >= 1 then acc = 0; updatePoll() end
  end)
  frame:SetScript("OnShow", function()
    ns.Minimap.SetFlash(false)
    UI.Refresh()
  end)
  frame:Hide()
end

UI.Frame = function() return frame end

local function layout(list, pool, make, set, height)
  local y = 0
  for i, d in ipairs(list) do
    local r = pool[i] or make(i)
    local h = (d.section and ROW_H) or height
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
    r:SetPoint("RIGHT", content, "RIGHT", 0, 0)
    r:SetHeight(h)
    set(r, d)
    r:Show()
    y = y + h
  end
  for i = #list + 1, #pool do pool[i]:Hide() end
  return y
end

-- Players tab rows, with the "Build group" suggestions on top when it's on.
local function playerDisplay()
  local db = LFGRivalsDB
  local display = {}
  if db.buildMode then
    local picks, missing = ns.Core.BuildPlan()
    display[#display + 1] = {
      section = "|cffffd100Suggested group|r |cff888888- lowest rivals for your open slots|r",
      action = { text = "Invite next", fn = function() ns.Core.InviteNext() end },
    }
    for _, d in ipairs(picks) do
      local copy = {}
      for k, v in pairs(d) do copy[k] = v end
      copy.plan = true
      display[#display + 1] = copy
    end
    if #picks == 0 then
      display[#display + 1] = { section = "|cff888888Nobody to suggest yet - press Refresh.|r" }
    end
    if #missing > 0 then
      display[#display + 1] = { section = "|cff888888Still missing: " .. table.concat(missing, ", ") .. "|r" }
    end
  end

  local list, hidden = ns.Core.BuildList()
  local lastRole
  for _, d in ipairs(list) do
    if d.entry.role ~= lastRole then
      lastRole = d.entry.role
      display[#display + 1] = { section = SECTION[lastRole] or lastRole }
    end
    display[#display + 1] = d
  end
  if #list == 0 then
    display[#display + 1] = { section = "|cff888888No solo players yet - press Refresh or wait for chat LFG.|r" }
  end
  if hidden > 0 then
    display[#display + 1] = { section = "|cff888888" .. hidden .. " more hidden by the level filter (Options).|r" }
  end
  return display
end

function UI.Refresh()
  if not frame or not frame:IsShown() then return end
  content:SetWidth(frame:GetWidth() - 44)
  updateMe()
  updatePoll()
  updatePickers()
  local blocked = ns.Sources.searchBlocked and true or false
  catPicker.frame:SetShown(not blocked)
  actPicker.frame:SetShown(not blocked)
  searchHint:SetShown(blocked)
  pollBtn:SetShown(not blocked)

  local profile, dungeon = ns.Core.CurrentProfile()
  lootText:SetText(ns.Loot.Describe(profile, dungeon))
  if LFGRivalsDB.buildMode then buildBtn:LockHighlight() else buildBtn:UnlockHighlight() end

  local tab = LFGRivalsDB.tab == "groups" and "groups" or "players"
  if tab == "players" then playersTab:LockHighlight(); groupsTab:UnlockHighlight()
  else groupsTab:LockHighlight(); playersTab:UnlockHighlight() end
  tankCB:SetShown(tab == "players")
  for set, list in pairs(headers) do
    for _, h in ipairs(list) do h:SetShown(set == tab) end
  end
  local iconsX = groupColumns()
  hMakeup:SetPoint("TOPLEFT", frame, "TOPLEFT", 12 + iconsX, ROW3 - 30)
  hRival:SetPoint("TOPLEFT", frame, "TOPLEFT", 12 + content:GetWidth() - 4 - 32 - 8 - 34, ROW3 - 30)

  local height
  if tab == "players" then
    for _, r in ipairs(gRows) do r:Hide() end
    height = layout(playerDisplay(), rows, makeRow, setRow, ROW_H)
  else
    for _, r in ipairs(rows) do r:Hide() end
    local groups = ns.Core.BuildGroups()
    if #groups == 0 then
      for _, r in ipairs(gRows) do r:Hide() end
      local d = { section = "|cff888888No groups listed for this search - press Refresh.|r" }
      height = layout({ d }, rows, makeRow, setRow, ROW_H)
    else
      height = layout(groups, gRows, makeGroupRow, setGroupRow, GROUP_H)
    end
  end
  content:SetHeight(math.max(height, 1))
  if ns.Options and ns.Options.Refresh then ns.Options.Refresh() end
end

function UI.Build()
  if not frame then build() end
end

function UI.Toggle()
  UI.Build()
  frame:SetShown(not frame:IsShown())
end

function UI.IsShown()
  return frame and frame:IsShown()
end

-- Keybindings (Bindings.xml)
BINDING_HEADER_LFGRIVALS = "LFG Rivals"
BINDING_NAME_LFGRIVALS_TOGGLE = "Toggle window"
BINDING_NAME_LFGRIVALS_REFRESH = "Refresh (search)"
function LFGRivals_Toggle() UI.Toggle() end
function LFGRivals_Refresh() ns.Core.ManualRefresh("keybind") end
