-- LFG Rivals: window. Two tabs: Players (solo + chat LFG) and Groups (listed
-- groups with their current makeup).

local ADDON, ns = ...
local UI = {}
ns.UI = UI

local ROW_H, GROUP_H, WIDTH, HEIGHT = 24, 42, 560, 520
local ROLE_LABEL = {
  HEALER  = "|cff40ff40Heal|r",
  TANK    = "|cff4da6ffTank|r",
  DAMAGER = "|cffff6060DPS|r",
}
local SECTION = {
  HEALER  = "Healers",
  TANK    = "Tanks",
  DAMAGER = "DPS - least gear competition first",
}
local ROLE_ORDER = { TANK = 1, HEALER = 2, DAMAGER = 3 }
local MAX_ICONS = 10

local frame, scroll, content, statusText, scanText, refreshBtn, pollBtn, classBtn, specBtn
local catPicker, actPicker, tankCB, playersTab, groupsTab, searchHint
local rows, gRows = {}, {}
local headers = { players = {}, groups = {} }
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

local function whisper(name)
  local cmd = "/w " .. name .. " "
  if ChatFrame_OpenChat then ChatFrame_OpenChat(cmd)
  elseif ChatFrameUtil and ChatFrameUtil.OpenChat then ChatFrameUtil.OpenChat(cmd) end
end

local function invite(name)
  if C_PartyInfo and C_PartyInfo.InviteUnit then C_PartyInfo.InviteUnit(name)
  elseif InviteUnit then InviteUnit(name) end
end

local function smallButton(parent, text, w, h)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w or 24, h or 18)
  b:SetText(text)
  return b
end

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
        info.func = function() onPick(it.id) end   -- runs inside the click
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
-- Player rows
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
  s:SetWidth(w)
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

  r.role    = rowText(r, 4, 36)
  r.name    = rowText(r, 42, 110)
  r.level   = rowText(r, 154, 30, "CENTER")
  r.score   = rowText(r, 190, 36, "RIGHT")
  r.comment = rowText(r, 236, 200)
  r.header  = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  r.header:SetPoint("LEFT", r, "LEFT", 4, 0)

  r.wBtn = smallButton(r, "W", 32, 22)
  r.wBtn:SetPoint("RIGHT", r, "RIGHT", -40, 0)
  r.wBtn:SetScript("OnClick", function() whisper(r.data.entry.name) end)
  r.iBtn = smallButton(r, "+", 32, 22)
  r.iBtn:SetPoint("RIGHT", r, "RIGHT", -4, 0)
  r.iBtn:SetScript("OnClick", function() invite(r.data.entry.name) end)

  r:SetScript("OnEnter", showPlayerTooltip)
  r:SetScript("OnLeave", function() GameTooltip:Hide() end)
  r:SetScript("OnClick", function(self)
    if not self.data or self.data.section then return end
    if IsShiftKeyDown() then invite(self.data.entry.name) else whisper(self.data.entry.name) end
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
  if isHeader then
    r.header:SetText(d.section)
    return
  end
  local e = d.entry
  r.role:SetText(ROLE_LABEL[e.role] or "?")
  r.name:SetText(classColor(e.class) .. e.name .. "|r" .. (e.source == "chat" and " |cff888888(chat)|r" or ""))
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
  GameTooltip:AddLine("Click: whisper leader", 0.5, 0.8, 1)
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
  r.leader:SetWidth(240)
  r.leader:SetJustifyH("LEFT")
  r.leader:SetWordWrap(false)

  r.sub = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.sub:SetPoint("TOPLEFT", r, "TOPLEFT", 22, -22)
  r.sub:SetWidth(240)
  r.sub:SetJustifyH("LEFT")
  r.sub:SetWordWrap(false)

  r.icons = {}
  for k = 1, MAX_ICONS do
    local t = r:CreateTexture(nil, "ARTWORK")
    t:SetSize(20, 20)
    t:SetPoint("LEFT", r, "LEFT", 268 + (k - 1) * 18, 0)
    r.icons[k] = t
  end
  r.count = rowText(r, 268, 180, "LEFT")

  r.score = rowText(r, 448, 30, "RIGHT")

  r.wBtn = smallButton(r, "W", 32, 22)
  r.wBtn:SetPoint("RIGHT", r, "RIGHT", -4, 0)
  r.wBtn:SetScript("OnClick", function() whisper(r.data.group.leader) end)

  r:SetScript("OnEnter", showGroupTooltip)
  r:SetScript("OnLeave", function() GameTooltip:Hide() end)
  r:SetScript("OnClick", function(self) if self.data then whisper(self.data.group.leader) end end)
  gRows[i] = r
  return r
end

local function setGroupRow(r, d)
  r.data = d
  local g = d.group
  r.leader:SetText(classColor(g.leaderClass) .. g.leader .. "|r")
  local sub = "|cffaaaaaa" .. g.activity .. "|r"
  if g.comment ~= "" then sub = sub .. "  |cff40ff40" .. g.comment .. "|r" end
  r.sub:SetText(sub)

  local members = sortedMembers(g)
  if g.max <= MAX_ICONS then
    r.count:Hide()
    for k = 1, MAX_ICONS do
      local t = r.icons[k]
      if k <= #members and members[k].role then
        setRoleIcon(t, members[k].role)
        t:SetDesaturated(false)
        t:SetAlpha(1)
        t:Show()
      elseif k <= g.max then
        setRoleIcon(t, "DAMAGER")           -- empty slot: faded
        t:SetDesaturated(true)
        t:SetAlpha(0.2)
        t:Show()
      else
        t:Hide()
      end
    end
  else
    -- Raids: icons would overflow, show counts instead.
    for k = 1, MAX_ICONS do r.icons[k]:Hide() end
    local c = { TANK = 0, HEALER = 0, DAMAGER = 0 }
    for _, m in ipairs(members) do if m.role then c[m.role] = c[m.role] + 1 end end
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
end

local function build()
  frame = CreateFrame("Frame", "LFGRivalsFrame", UIParent, "BasicFrameTemplateWithInset")
  frame:SetSize(WIDTH, HEIGHT)
  frame:SetPoint("CENTER")
  frame:SetMovable(true)
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

  -- Row 2: category -> activity. Picking one searches right away (it's a click).
  local searchLbl = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  searchLbl:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, ROW2 - 8)
  searchLbl:SetText("Search:")

  catPicker = makePicker("LFGRivalsCategoryDropDown", frame, 130, categoryItems,
    function() return LFGRivalsDB.categoryID end,
    function(id)
      LFGRivalsDB.categoryID, LFGRivalsDB.activityID = id, 0
      updatePickers()
      ns.Core.ManualRefresh("category picked")
    end)
  catPicker.frame:SetPoint("TOPLEFT", frame, "TOPLEFT", 50, ROW2)

  actPicker = makePicker("LFGRivalsActivityDropDown", frame, 190, activityItems,
    function() return LFGRivalsDB.activityID end,
    function(id)
      LFGRivalsDB.activityID = id
      updatePickers()
      ns.Core.ManualRefresh("activity picked")
    end)
  actPicker.frame:SetPoint("LEFT", catPicker.frame, "RIGHT", 0, 0)

  -- Shown instead of the pickers when addon searches are blocked: Blizzard's
  -- refresh searches whatever is selected in Blizzard's LFG window.
  searchHint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  searchHint:SetPoint("TOPLEFT", frame, "TOPLEFT", 66, ROW2 - 9)
  searchHint:SetText("Addon searches were blocked - search in Blizzard's LFG window. (/rivals unblock to retry)")

  -- Row 3: tabs + toggles
  playersTab = smallButton(frame, "Players", 80, 22)
  playersTab:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, ROW3)
  playersTab:SetScript("OnClick", function() setTab("players") end)
  groupsTab = smallButton(frame, "Groups", 80, 22)
  groupsTab:SetPoint("LEFT", playersTab, "RIGHT", 4, 0)
  groupsTab:SetScript("OnClick", function() setTab("groups") end)

  tankCB = checkbox(frame, "Show tanks", "showTanks", 196)
  checkbox(frame, "Include chat LFG", "useChat", 300)

  header("players", 4, "Role")
  header("players", 42, "Name")
  header("players", 154, "Level")
  header("players", 192, "Rival")
  header("players", 236, "Note")
  header("groups", 22, "Leader / activity")
  header("groups", 268, "Makeup")
  header("groups", 444, "Rival")

  scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, ROW3 - 44)
  scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -32, 30)
  content = CreateFrame("Frame", nil, scroll)
  content:SetSize(WIDTH - 44, 1)
  scroll:SetScrollChild(content)

  statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  statusText:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 10)
  scanText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  scanText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 10)

  local acc = 0
  frame:SetScript("OnUpdate", function(_, elapsed)
    acc = acc + elapsed
    if acc >= 1 then acc = 0; updatePoll() end
  end)
  frame:SetScript("OnShow", function() UI.Refresh() end)
  frame:Hide()
end

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

function UI.Refresh()
  if not frame or not frame:IsShown() then return end
  updateMe()
  updatePoll()
  updatePickers()
  local blocked = ns.Sources.searchBlocked and true or false
  catPicker.frame:SetShown(not blocked)
  actPicker.frame:SetShown(not blocked)
  searchHint:SetShown(blocked)
  pollBtn:SetShown(not blocked)     -- a timer can't trigger a secure click

  local tab = LFGRivalsDB.tab == "groups" and "groups" or "players"
  if tab == "players" then playersTab:LockHighlight(); groupsTab:UnlockHighlight()
  else groupsTab:LockHighlight(); playersTab:UnlockHighlight() end
  tankCB:SetShown(tab == "players")
  for set, list in pairs(headers) do
    for _, h in ipairs(list) do h:SetShown(set == tab) end
  end

  local height
  if tab == "players" then
    for _, r in ipairs(gRows) do r:Hide() end
    local display, lastRole = {}, nil
    for _, d in ipairs(ns.Core.BuildList()) do
      if d.entry.role ~= lastRole then
        lastRole = d.entry.role
        display[#display + 1] = { section = SECTION[lastRole] or lastRole }
      end
      display[#display + 1] = d
    end
    if #display == 0 then
      display[1] = { section = "|cff888888No solo players yet - press Refresh or wait for chat LFG.|r" }
    end
    height = layout(display, rows, makeRow, setRow, ROW_H)
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
