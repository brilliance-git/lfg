-- LFG Rivals: minimap button. Left-click: toggle window. Right-click: search now.
-- Drag to move it around the minimap edge. /rivals minimap hides/shows it.

local ADDON, ns = ...
local MM = {}
ns.Minimap = MM

local btn
local RADIUS = 80

local function place()
  local a = math.rad(LFGRivalsDB.minimap.angle or 200)
  btn:ClearAllPoints()
  btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * RADIUS, math.sin(a) * RADIUS)
end

local function onDragUpdate()
  local mx, my = Minimap:GetCenter()
  local cx, cy = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  cx, cy = cx / scale, cy / scale
  LFGRivalsDB.minimap.angle = math.deg(math.atan2(cy - my, cx - mx))
  place()
end

function MM.Create()
  if btn or not Minimap then return end
  btn = CreateFrame("Button", "LFGRivalsMinimapButton", Minimap)
  btn:SetSize(31, 31)
  btn:SetFrameStrata("MEDIUM")
  btn:SetFrameLevel(8)
  btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  btn:RegisterForDrag("LeftButton")
  btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local bg = btn:CreateTexture(nil, "BACKGROUND")
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  bg:SetSize(20, 20)
  bg:SetPoint("TOPLEFT", 7, -5)

  local icon = btn:CreateTexture(nil, "ARTWORK")
  icon:SetTexture("Interface\\Icons\\INV_Misc_Spyglass_03")
  icon:SetSize(20, 20)
  icon:SetPoint("TOPLEFT", 7, -5)
  icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

  local border = btn:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT")

  btn:SetScript("OnClick", function(_, mouse)
    if mouse == "RightButton" then
      ns.Core.ManualRefresh("minimap right-click")
    else
      ns.UI.Toggle()
    end
  end)
  btn:SetScript("OnDragStart", function(self) MM.SetFlash(false); self:SetScript("OnUpdate", onDragUpdate) end)
  btn:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  btn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("LFG Rivals")
    GameTooltip:AddLine("Left-click: open / close", 1, 1, 1)
    GameTooltip:AddLine("Right-click: search now", 1, 1, 1)
    GameTooltip:AddLine("Drag: move", 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  place()
  btn:SetShown(not LFGRivalsDB.minimap.hide)
end

-- Pulse the button after an alert, until you open the window.
local glow, flashing = nil, false
function MM.SetFlash(on)
  if not btn then return end
  if not glow then
    glow = btn:CreateTexture(nil, "OVERLAY")
    glow:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    glow:SetBlendMode("ADD")
    glow:SetAllPoints(btn)
    glow:Hide()
  end
  if on == flashing then return end
  flashing = on
  if on then
    local t = 0
    glow:Show()
    btn:SetScript("OnUpdate", function(_, elapsed)
      t = t + elapsed
      glow:SetAlpha(0.35 + 0.65 * math.abs(math.sin(t * 3)))
    end)
  else
    glow:Hide()
    btn:SetScript("OnUpdate", nil)
  end
end

function MM.Toggle()
  LFGRivalsDB.minimap.hide = not LFGRivalsDB.minimap.hide
  if btn then btn:SetShown(not LFGRivalsDB.minimap.hide) end
  return not LFGRivalsDB.minimap.hide
end
