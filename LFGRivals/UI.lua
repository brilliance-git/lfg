-- LFG Rivals: window.

local ADDON, ns = ...
local UI = {}
ns.UI = UI

local ROW_H, WIDTH, HEIGHT = 20, 560, 460
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

local frame, scroll, content, statusText, refreshBtn, pollBtn, classBtn, specBtn
local rows = {}

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

local function smallButton(parent, text, w)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w or 24, 18)
  b:SetText(text)
  return b
end

local function checkbox(parent, label, key, x)
  local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  cb:SetSize(22, 22)
  cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -56)
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
-- Rows
---------------------------------------------------------------------------

local function showTooltip(row)
  local d = row.data
  if not d or d.section then return end
  local e = d.entry
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:AddLine(classColor(e.class) .. e.name .. "|r " .. (e.level and ("(" .. e.level .. ")") or ""))
  GameTooltip:AddLine(className(e.class) .. " - " .. (#d.specs == 1 and d.specs[1].name or "spec unknown"), 1, 1, 1)
  if #d.specs > 1 then
    local names = {}
    for _, s in ipairs(d.specs) do names[#names + 1] = s.name end
    GameTooltip:AddLine("Could be: " .. table.concat(names, ", ") .. " (score is the average)", 0.7, 0.7, 0.7, true)
  end
  if d.score then
    GameTooltip:AddLine("Gear competition: " .. scoreColor(d.score) .. d.score .. "/100|r", 1, 1, 1)
  end
  local src = e.source == "chat" and "Chat" or ("Group Finder" .. ((e.groupSize or 1) > 1 and (" - group of " .. e.groupSize) or ""))
  GameTooltip:AddLine("Source: " .. src, 0.7, 0.7, 0.7)
  if e.comment and e.comment ~= "" then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(e.comment, 1, 0.82, 0, true)
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Click: whisper   Shift-click: invite", 0.5, 0.8, 1)
  GameTooltip:Show()
end

local function makeRow(i)
  local r = CreateFrame("Button", nil, content)
  r:SetHeight(ROW_H)
  r:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(i - 1) * ROW_H)
  r:SetPoint("RIGHT", content, "RIGHT", 0, 0)
  r:RegisterForClicks("LeftButtonUp")

  local hl = r:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.08)

  local function fs(x, w, justify)
    local s = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    s:SetPoint("LEFT", r, "LEFT", x, 0)
    s:SetWidth(w)
    s:SetJustifyH(justify or "LEFT")
    s:SetWordWrap(false)
    return s
  end
  r.role    = fs(4, 36)
  r.name    = fs(42, 110)
  r.spec    = fs(154, 90)
  r.score   = fs(246, 40, "RIGHT")
  r.comment = fs(296, 150)
  r.header  = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  r.header:SetPoint("LEFT", r, "LEFT", 4, 0)

  r.wBtn = smallButton(r, "W", 24)
  r.wBtn:SetPoint("RIGHT", r, "RIGHT", -30, 0)
  r.wBtn:SetScript("OnClick", function() whisper(r.data.entry.name) end)
  r.iBtn = smallButton(r, "+", 24)
  r.iBtn:SetPoint("RIGHT", r, "RIGHT", -4, 0)
  r.iBtn:SetScript("OnClick", function() invite(r.data.entry.name) end)

  r:SetScript("OnEnter", showTooltip)
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
  for _, k in ipairs({ "role", "name", "spec", "score", "comment" }) do r[k]:SetShown(not isHeader) end
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
  r.spec:SetText(d.specLabel ~= "" and d.specLabel or className(e.class))
  r.score:SetText(d.score and (scoreColor(d.score) .. d.score .. "|r") or "|cff888888-|r")
  r.comment:SetText(e.comment or "")
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
  if not left then
    statusText:SetText("|cff888888Auto-refresh off. Use Refresh or your keybind.|r")
  elseif due then
    if InCombatLockdown and InCombatLockdown() then
      statusText:SetText("|cffffd100Refresh due - waits until you leave combat.|r")
    else
      statusText:SetText("|cffffd100Refresh due - your next key press triggers it.|r")
    end
  else
    statusText:SetText("|cff888888Next refresh in " .. left .. "s (on your next key press).|r")
  end
  if due then refreshBtn:LockHighlight() else refreshBtn:UnlockHighlight() end
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

  local me = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  me:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -34)
  me:SetText("Me:")

  classBtn = smallButton(frame, "", 100)
  classBtn:SetPoint("LEFT", me, "RIGHT", 6, 0)
  classBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  classBtn:SetScript("OnClick", function(_, btn) ns.Core.CycleClass(btn == "RightButton" and -1 or 1); UI.Refresh() end)

  specBtn = smallButton(frame, "", 130)
  specBtn:SetPoint("LEFT", classBtn, "RIGHT", 4, 0)
  specBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  specBtn:SetScript("OnClick", function(_, btn) ns.Core.CycleSpec(btn == "RightButton" and -1 or 1); UI.Refresh() end)

  refreshBtn = smallButton(frame, "Refresh", 80)
  refreshBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -30)
  refreshBtn:SetScript("OnClick", function() ns.Core.ManualRefresh() end)

  pollBtn = smallButton(frame, "", 84)
  pollBtn:SetPoint("RIGHT", refreshBtn, "LEFT", -4, 0)
  pollBtn:SetScript("OnClick", function() ns.Core.CyclePoll(); updatePoll() end)

  checkbox(frame, "Show tanks", "showTanks", 12)
  checkbox(frame, "Solo players only", "soloOnly", 120)
  checkbox(frame, "Include chat LFG", "useChat", 260)

  for _, col in ipairs({ { 4, "Role" }, { 42, "Name" }, { 154, "Spec" }, { 250, "Rival" }, { 296, "Note" } }) do
    local h = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h:SetPoint("TOPLEFT", frame, "TOPLEFT", 12 + col[1], -86)
    h:SetText(col[2])
  end

  scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -100)
  scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -32, 30)
  content = CreateFrame("Frame", nil, scroll)
  content:SetSize(WIDTH - 44, 1)
  scroll:SetScrollChild(content)

  statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  statusText:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 10)

  local acc = 0
  frame:SetScript("OnUpdate", function(_, elapsed)
    acc = acc + elapsed
    if acc >= 1 then acc = 0; updatePoll() end
  end)
  frame:SetScript("OnShow", function() UI.Refresh() end)
  frame:Hide()
end

function UI.Refresh()
  if not frame or not frame:IsShown() then return end
  updateMe()
  updatePoll()

  local list = ns.Core.BuildList()
  local display, lastRole = {}, nil
  for _, d in ipairs(list) do
    if d.entry.role ~= lastRole then
      lastRole = d.entry.role
      display[#display + 1] = { section = SECTION[lastRole] or lastRole }
    end
    display[#display + 1] = d
  end
  if #display == 0 then
    display[1] = { section = "|cff888888No players yet - press Refresh or wait for chat LFG.|r" }
  end

  for i, d in ipairs(display) do
    local r = rows[i] or makeRow(i)
    setRow(r, d)
    r:Show()
  end
  for i = #display + 1, #rows do rows[i]:Hide() end
  content:SetHeight(math.max(#display * ROW_H, 1))
end

function UI.Toggle()
  if not frame then build() end
  frame:SetShown(not frame:IsShown())
end

function UI.IsShown()
  return frame and frame:IsShown()
end

-- Keybinding (Bindings.xml)
BINDING_HEADER_LFGRIVALS = "LFG Rivals"
BINDING_NAME_LFGRIVALS_TOGGLE = "Toggle window"
BINDING_NAME_LFGRIVALS_REFRESH = "Refresh Group Finder search"
function LFGRivals_Toggle() UI.Toggle() end
function LFGRivals_Refresh() ns.Core.ManualRefresh() end
