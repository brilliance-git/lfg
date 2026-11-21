-- LFG Rivals: troubleshooting log.
--   /rivals log      open a copyable log window (Ctrl+A, Ctrl+C)
--   /rivals verbose  also echo each log line to chat
-- The log is saved in SavedVariables (LFGRivalsDB.log; previous session in
-- LFGRivalsDB.logPrev), so it survives /reload and can be sent as a file.

local ADDON, ns = ...
local Log = {}
ns.Log = Log

local MAX = 400
Log.lines = {}

-- Wall clock plus the game's uptime clock (GetTime). The fraction used to come
-- from a different clock than the seconds, so lines looked out of order.
local function stamp()
  local t = (GetTime and GetTime()) or 0
  return (date and date("%H:%M:%S") or "") .. string.format(" t=%.3f", t)
end

-- Turn any values into one readable string (tables shallowly).
function Log.Fmt(...)
  local parts = {}
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if type(v) == "table" then
      local inner, n = {}, 0
      for k, x in pairs(v) do
        n = n + 1
        if n > 12 then inner[#inner + 1] = "..."; break end
        inner[#inner + 1] = tostring(k) .. "=" .. (type(x) == "table" and "{...}" or tostring(x))
      end
      parts[#parts + 1] = "{" .. table.concat(inner, ",") .. "}"
    else
      parts[#parts + 1] = tostring(v)
    end
  end
  return table.concat(parts, " ")
end

function Log.Add(tag, ...)
  local line = stamp() .. " [" .. tag .. "] " .. Log.Fmt(...)
  local lines = Log.lines
  lines[#lines + 1] = line
  while #lines > MAX do table.remove(lines, 1) end
  if LFGRivalsDB and LFGRivalsDB.verbose and DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cff888888LFGR " .. line .. "|r")
  end
  if Log.viewer and Log.viewer:IsShown() then Log.FillViewer() end
end

-- Called at ADDON_LOADED: keep last session's log, start a fresh one that
-- already contains anything logged before the DB existed.
function Log.Attach(db)
  if type(db.log) == "table" then db.logPrev = db.log end
  db.log = Log.lines
end

---------------------------------------------------------------------------
-- Viewer
---------------------------------------------------------------------------

function Log.FillViewer()
  local text = table.concat(Log.lines, "\n")
  Log.edit:SetText(text)
  Log.edit:SetCursorPosition(#text)
end

function Log.Show()
  if not Log.viewer then
    local f = CreateFrame("Frame", "LFGRivalsLogFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(640, 420)
    f:SetPoint("CENTER", 0, 40)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    tinsert(UISpecialFrames, "LFGRivalsLogFrame")

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -5)
    title:SetText("LFG Rivals log - Ctrl+A then Ctrl+C to copy")

    local sf = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 12, -30)
    sf:SetPoint("BOTTOMRIGHT", -32, 36)

    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)
    eb:SetFontObject(ChatFontNormal)
    eb:SetWidth(590)
    eb:SetScript("OnEscapePressed", function() f:Hide() end)
    sf:SetScrollChild(eb)
    Log.edit = eb

    local clear = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clear:SetSize(80, 22)
    clear:SetPoint("BOTTOMLEFT", 12, 8)
    clear:SetText("Clear")
    clear:SetScript("OnClick", function() wipe(Log.lines); Log.FillViewer() end)

    local snap = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    snap:SetSize(120, 22)
    snap:SetPoint("LEFT", clear, "RIGHT", 6, 0)
    snap:SetText("Add snapshot")
    snap:SetScript("OnClick", function() ns.Sources.Debug(function(s) Log.Add("debug", s) end) end)

    Log.viewer = f
  end
  Log.viewer:Show()
  Log.FillViewer()
end
