-- LFG Rivals: options panel, docked to the right of the main window.
--   Alerts, level filter, score cut-offs, whisper messages, contacted list, loot data.

local ADDON, ns = ...
local Options = {}
ns.Options = Options

local panel
local controls = {}
local W = 300

local function label(parent, text, y, font)
  local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
  fs:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, y)
  fs:SetWidth(W - 28)
  fs:SetJustifyH("LEFT")
  fs:SetText(text)
  return fs
end

local function check(parent, text, key, y)
  local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  cb:SetSize(22, 22)
  cb:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, y)
  local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
  fs:SetText(text)
  cb:SetScript("OnClick", function(self)
    LFGRivalsDB[key] = self:GetChecked() and true or false
    ns.Core.MarkDirty()
  end)
  controls[#controls + 1] = function() cb:SetChecked(LFGRivalsDB[key]) end
  return cb
end

local function editBox(parent, x, y, w, key, numeric, lo, hi)
  local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  eb:SetSize(w, 20)
  eb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  eb:SetAutoFocus(false)
  if numeric then eb:SetNumeric(true); eb:SetMaxLetters(3) else eb:SetMaxLetters(240) end
  local function commit(self)
    local v = self:GetText()
    if numeric then
      v = tonumber(v) or LFGRivalsDB[key]
      v = math.max(lo, math.min(hi, v))
    end
    LFGRivalsDB[key] = v
    self:SetText(tostring(v))
    self:ClearFocus()
    ns.Core.MarkDirty()
  end
  eb:SetScript("OnEnterPressed", commit)
  eb:SetScript("OnEditFocusLost", commit)
  eb:SetScript("OnEscapePressed", function(self)
    self:SetText(tostring(LFGRivalsDB[key]))
    self:ClearFocus()
  end)
  controls[#controls + 1] = function()
    if not eb:HasFocus() then eb:SetText(tostring(LFGRivalsDB[key] or "")) end
  end
  return eb
end

local function numberRow(parent, text, key, y, lo, hi)
  local fs = label(parent, text, y - 2)
  fs:SetWidth(W - 90)
  editBox(parent, W - 60, y, 40, key, true, lo, hi)
end

local function build()
  local main = ns.UI.Frame()
  panel = CreateFrame("Frame", "LFGRivalsOptionsFrame", main, "BasicFrameTemplateWithInset")
  panel:SetSize(W, 440)
  panel:SetPoint("TOPLEFT", main, "TOPRIGHT", 2, 0)
  panel:EnableMouse(true)

  local title = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  title:SetPoint("TOP", panel, "TOP", 0, -5)
  title:SetText("LFG Rivals options")

  local y = -30
  label(panel, "Alerts", y, "GameFontNormal"); y = y - 18
  check(panel, "Alert me about new matches (chat + minimap)", "alerts", y); y = y - 24
  check(panel, "Play a sound", "alertSound", y); y = y - 28
  numberRow(panel, "Alert on DPS with a rival score up to", "alertScore", y, 0, 100); y = y - 28
  label(panel, "|cff888888Healers always alert; tanks only with Show tanks on. No alerts while"
    .. " this window is open.|r", y); y = y - 34

  label(panel, "Filters", y, "GameFontNormal"); y = y - 18
  check(panel, "Only players in the picked dungeon's level range", "levelFromDungeon", y); y = y - 26
  numberRow(panel, "Otherwise, only players within this many levels of me (0 = off)", "levelRange", y, 0, 60); y = y - 32
  numberRow(panel, "Hide DPS with a rival score above", "maxScore", y, 0, 100); y = y - 30
  check(panel, "Grey out filtered players instead of hiding them", "greyFiltered", y); y = y - 22
  check(panel, "Hide players and groups I marked Avoid", "hideAvoided", y); y = y - 30

  label(panel, "Whisper messages", y, "GameFontNormal"); y = y - 18
  label(panel, "To players:", y); y = y - 14
  editBox(panel, 18, y, W - 36, "whisperMsg"); y = y - 24
  label(panel, "To group leaders (W types it, Join sends it):", y); y = y - 14
  editBox(panel, 18, y, W - 36, "groupWhisperMsg"); y = y - 24
  label(panel, "|cff888888{name} {dungeon} {role} {me} {level} get filled in. W types the text into chat"
    .. " and you press Enter; Join sends it right away.|r", y); y = y - 40
  check(panel, "Join: accept that leader's invite automatically", "autoAccept", y); y = y - 30

  local forget = ns.UI.SmallButton(panel, "Forget who I contacted", 170, 22)
  forget:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, y)
  forget:SetScript("OnClick", function()
    wipe(LFGRivalsDB.contacted)
    ns.Core.MarkDirty()
  end)
  y = y - 32

  label(panel, "Loot data and level ranges", y, "GameFontNormal"); y = y - 18
  controls.journal = label(panel, "", y); y = y - 28
  controls.loot = label(panel, "", y); y = y - 30
  local reread = ns.UI.SmallButton(panel, "Re-read loot", 110, 22)
  reread:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, y)
  reread:SetScript("OnClick", function()
    ns.Loot.Invalidate()
    ns.Core.MarkDirty()
  end)

  panel:SetHeight(-y + 40)
  panel:SetScript("OnShow", Options.Refresh)
  panel:Hide()
end

function Options.Refresh()
  if not (panel and panel:IsShown()) then return end
  for _, f in ipairs(controls) do f() end
  local p, name = ns.Core.CurrentProfile()
  controls.loot:SetText(ns.Loot.Describe(p, name))
  controls.journal:SetText(ns.Journal.Available()
    and "|cff40ff40ForeverDungeonJournal found|r |cff888888- its level ranges and boss loot are used.|r"
    or "|cffff8040ForeverDungeonJournal not loaded|r |cff888888- using the game's own ranges and drops you've seen.|r")
end

function Options.Toggle()
  local main = ns.UI.Frame()
  if not main then return end
  if not main:IsShown() then main:Show() end
  if not panel then build() end
  panel:SetShown(not panel:IsShown())
end
