--[[
  MassDisenchant 1.1  -  WoW 1.12 (Lua 5.0)

  Click the minimap button (or type /md) to open the window.
  /md [show|hide] | start | stop | list | quality <green|blue|epic>
      | ignore <[item]> | unignore <[item]> | minimap
]]

local SPELL            = "Disenchant"   -- English client spell name
local DELAY_AFTER_CAST = 1.2            -- seconds to wait after a cast so loot can be taken
local START_TIMEOUT    = 2.5            -- seconds to wait for a cast to begin
local CAST_TIMEOUT     = 10             -- hard cap for a single cast

local ROWS  = 10   -- visible rows in the list
local ROW_H = 28   -- row height

local QUALITY = { green = 2, blue = 3, epic = 4 }
local QNAME   = { [2] = "green", [3] = "blue", [4] = "epic" }
local QTEXT   = { [2] = "|cff1eff00Green|r", [3] = "|cff4da6ffBlue|r", [4] = "|cffc060ffEpic|r" }
local QCOLOR  = { [2] = { 0.12, 1, 0 }, [3] = { 0, 0.44, 0.87 }, [4] = { 0.64, 0.21, 0.93 } }

-- Equip slots that can never be disenchanted
local BAD_LOC = {
  INVTYPE_BODY = true,    -- shirts
  INVTYPE_TABARD = true,
  INVTYPE_TRINKET = true,
  INVTYPE_BAG = true,
  INVTYPE_QUIVER = true,
  INVTYPE_AMMO = true,
  INVTYPE_RELIC = true,
}

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local queue   = {}       -- entries still to process
local runList = {}       -- snapshot of the current run (for the UI)
local skipped = {}       -- items that failed this session
local state   = "idle"   -- idle | casting | delay
local current, started
local timer, delayTime = 0, 0
local retries = 0
local total, done, failed = 0, 0, 0
local statusMsg          -- message shown in the window after a run
local uiDirty, uiTimer = false, 0
local offset = 0         -- scroll offset
local curList = {}       -- list currently shown in the window
local ui = {}            -- widget references

local events = CreateFrame("Frame", "MassDisenchantEvents")

local function Say(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99MassDE:|r " .. msg)
end

local function Touch()
  uiDirty = true
end

local function GetItemId(link)
  if not link then return nil end
  local _, _, id = strfind(link, "item:(%d+):")
  return tonumber(id)
end

local function KnowsDisenchant()
  for i = 1, 300 do
    local name = GetSpellName(i, BOOKTYPE_SPELL)
    if not name then break end
    if name == SPELL then return true end
  end
  return false
end

----------------------------------------------------------------------
-- Bag scanning
----------------------------------------------------------------------
-- Returns every bag item that matches the quality filter (including
-- protected / skipped ones, which are flagged).
local function Scan()
  local list = {}
  local maxQ = MassDisenchantDB.maxQuality
  for bag = 0, 4 do
    for slot = 1, GetContainerNumSlots(bag) do
      local link = GetContainerItemLink(bag, slot)
      if link then
        local id = GetItemId(link)
        if id then
          local name, _, quality, _, itype, subtype, _, equipLoc = GetItemInfo("item:" .. id .. ":0:0:0")
          if name and quality and quality >= 2 and quality <= maxQ
             and (itype == "Armor" or itype == "Weapon")
             and not (equipLoc and BAD_LOC[equipLoc])
             and subtype ~= "Fishing Pole" then
            local texture = GetContainerItemInfo(bag, slot)
            table.insert(list, {
              bag = bag, slot = slot, link = link, id = id,
              name = name, quality = quality, texture = texture,
              ignored = MassDisenchantDB.ignore[id] and true or false,
              skipped = skipped[bag .. ":" .. slot .. link] and true or false,
            })
          end
        end
      end
    end
  end
  return list
end

local function BuildQueue()
  queue = {}
  local list = Scan()
  for i = 1, getn(list) do
    local e = list[i]
    if not e.ignored and not e.skipped then
      e.status = "pending"
      table.insert(queue, e)
    end
  end
  return getn(queue)
end

----------------------------------------------------------------------
-- Disenchant engine
----------------------------------------------------------------------
local function Finish()
  state = "idle"
  current = nil
  if SpellIsTargeting() then SpellStopTargeting() end
  statusMsg = "Finished: " .. done .. " disenchanted" ..
              (failed > 0 and (", " .. failed .. " skipped") or "")
  Say(statusMsg)
  Touch()
end

local function Stop(reason)
  state = "idle"
  current = nil
  queue = {}
  if SpellIsTargeting() then SpellStopTargeting() end
  statusMsg = "Stopped" .. (reason and (" (" .. reason .. ")") or "") ..
              ": " .. done .. " of " .. total .. " done"
  Say(statusMsg)
  Touch()
end

local attempts = {}   -- failed attempts per item this run
local runSingle = false  -- true: stop after one item instead of emptying the list

-- Called when a cast never started. Retries once (could be a global
-- cooldown hiccup), then gives up on the item for this session.
local function SkipCurrent()
  if not current then return end
  local key = current.bag .. ":" .. current.slot .. current.link
  attempts[key] = (attempts[key] or 0) + 1
  if attempts[key] < 2 then
    current.status = "pending"
    table.insert(queue, current)
  else
    current.status = "failed"
    skipped[key] = true
    failed = failed + 1
  end
end

local function Next()
  Touch()
  if getn(queue) == 0 then
    if runSingle and (done + failed) > 0 then
      Finish()
      return
    end
    -- Queue is empty: rescan the bags. Picks up items that moved, were
    -- retried, or newly dropped, and only finishes when nothing is left.
    local list = Scan()
    local added = 0
    for i = 1, getn(list) do
      local e = list[i]
      if not e.ignored and not e.skipped and not (runSingle and added > 0) then
        e.status = "pending"
        table.insert(queue, e)
        table.insert(runList, e)
        added = added + 1
      end
    end
    if added == 0 then
      Finish()
      return
    end
    total = total + added
  end
  if UnitAffectingCombat("player") then
    Stop("you entered combat")
    return
  end
  if CursorHasItem() then
    Stop("item on cursor")
    return
  end
  if SpellIsTargeting() then SpellStopTargeting() end

  current = table.remove(queue, 1)

  -- Make sure the item is still where we expect it
  if GetContainerItemLink(current.bag, current.slot) ~= current.link then
    current.status = "gone"
    total = total - 1
    current = nil
    return Next()
  end

  current.status = "active"
  started = false
  CastSpellByName(SPELL)
  if SpellIsTargeting() then
    PickupContainerItem(current.bag, current.slot)
    state = "casting"
    timer = 0
    retries = 0
  else
    -- Cast did not go to targeting (global cooldown / busy). Retry shortly.
    retries = retries + 1
    if retries > 4 then
      Stop("could not start " .. SPELL)
      return
    end
    current.status = "pending"
    table.insert(queue, 1, current)
    current = nil
    state = "delay"
    delayTime = 0.5
    timer = 0
  end
end

local function Fail(msg)
  Say(msg)
  statusMsg = msg
  Touch()
end

local function Start(single)
  if state ~= "idle" then
    Say("Already running. Use /md stop to cancel.")
    return
  end
  if not KnowsDisenchant() then
    Fail("You don't know " .. SPELL .. ".")
    return
  end
  if UnitAffectingCombat("player") then
    Fail("You can't do that in combat.")
    return
  end
  statusMsg = nil
  total = BuildQueue()
  done, failed, retries = 0, 0, 0
  attempts = {}
  if total == 0 then
    Fail("Nothing to disenchant (limit: " .. QNAME[MassDisenchantDB.maxQuality] .. ").")
    return
  end
  runSingle = single and true or false
  if runSingle and total > 1 then
    local first = queue[1]
    queue = { first }
    total = 1
  end
  runList = {}
  for i = 1, total do runList[i] = queue[i] end
  offset = 0
  if runSingle then
    Say("Disenchanting 1 item (hold CTRL when clicking to disenchant everything).")
  else
    Say("Disenchanting " .. total .. " item(s). Move or jump to cancel.")
  end
  Next()
end

local function List()
  local list = Scan()
  local n = 0
  for i = 1, getn(list) do
    if not list[i].ignored then n = n + 1 end
  end
  if n == 0 then
    Say("Nothing to disenchant (limit: " .. QNAME[MassDisenchantDB.maxQuality] .. ").")
    return
  end
  Say(n .. " item(s) would be disenchanted (limit: " .. QNAME[MassDisenchantDB.maxQuality] .. "):")
  for i = 1, getn(list) do
    if not list[i].ignored then
      DEFAULT_CHAT_FRAME:AddMessage("  " .. list[i].link)
    end
  end
end

----------------------------------------------------------------------
-- UI: rendering
----------------------------------------------------------------------
local Rebuild, Render

-- Label of the main button when idle
local function StartLabel()
  if MassDisenchantDB.ctrlForAll and not IsControlKeyDown() then
    return "Disenchant Next"
  end
  return "Disenchant All"
end

Render = function()
  local f = ui.frame
  if not f or not f:IsVisible() then return end

  local running = (state ~= "idle")
  local list = curList
  local n = getn(list)

  -- scrollbar range
  local maxOffset = n - ROWS
  if maxOffset < 0 then maxOffset = 0 end
  if offset > maxOffset then offset = maxOffset end
  if offset < 0 then offset = 0 end
  ui.updating = true
  ui.slider:SetMinMaxValues(0, maxOffset)
  ui.slider:SetValue(offset)
  ui.updating = false
  if maxOffset > 0 then ui.slider:Show() else ui.slider:Hide() end

  -- counts
  local ready, prot, skip = 0, 0, 0
  for i = 1, n do
    local e = list[i]
    if e.ignored then prot = prot + 1
    elseif e.skipped then skip = skip + 1
    else ready = ready + 1 end
  end

  -- rows
  for i = 1, ROWS do
    local row = ui.rows[i]
    local e = list[offset + i]
    if e then
      row.entry = e
      local c = QCOLOR[e.quality]
      local st, dim = "", false
      if running then
        if e.status == "active" then st = "|cffffd100Working...|r"
        elseif e.status == "done" then st = "|cff40ff40Done|r"
        elseif e.status == "failed" then st = "|cffff5555Skipped|r"; dim = true
        elseif e.status == "gone" then st = "|cff999999Moved|r"; dim = true
        else st = "|cff999999Queued|r" end
      else
        if e.ignored then st = "|cff66aaffProtected|r"; dim = true
        elseif e.skipped then st = "|cffff5555Can't DE|r"; dim = true
        else st = "|cff40ff40Ready|r" end
      end

      row.icon:SetTexture(e.texture)
      if dim then
        row.icon:SetVertexColor(0.45, 0.45, 0.45)
        row.name:SetTextColor(c[1] * 0.5, c[2] * 0.5, c[3] * 0.5)
        row.border:SetTexture(c[1] * 0.4, c[2] * 0.4, c[3] * 0.4, 1)
      else
        row.icon:SetVertexColor(1, 1, 1)
        row.name:SetTextColor(c[1], c[2], c[3])
        row.border:SetTexture(c[1], c[2], c[3], 1)
      end
      row.name:SetText(e.name)
      row.status:SetText(st)
      if e.status == "active" and running then row.active:Show() else row.active:Hide() end
      row:Show()
    else
      row.entry = nil
      row:Hide()
    end
  end

  if n == 0 then ui.empty:Show() else ui.empty:Hide() end

  -- summary line
  local text
  if statusMsg then
    text = statusMsg
  elseif running then
    text = current and ("Disenchanting " .. current.name .. "...") or "Working..."
  else
    text = "|cff40ff40" .. ready .. " ready|r"
    if prot > 0 then text = text .. "   |cff66aaff" .. prot .. " protected|r" end
    if skip > 0 then text = text .. "   |cffff5555" .. skip .. " can't be disenchanted|r" end
  end
  ui.summary:SetText(text)

  -- progress bar
  if running or statusMsg then
    local mx = total
    if mx < 1 then mx = 1 end
    ui.bar:SetMinMaxValues(0, mx)
    ui.bar:SetValue(done + failed)
    ui.bar.text:SetText((done + failed) .. " / " .. total)
  else
    ui.bar:SetMinMaxValues(0, 1)
    ui.bar:SetValue(0)
    ui.bar.text:SetText("Idle")
  end

  -- buttons
  if running then
    ui.start:SetText("Stop")
    ui.start:Enable()
    ui.refresh:Disable()
  else
    ui.start:SetText(StartLabel())
    if ready > 0 then ui.start:Enable() else ui.start:Disable() end
    ui.refresh:Enable()
  end
  for q = 2, 4 do
    if MassDisenchantDB.maxQuality == q then ui.q[q]:LockHighlight() else ui.q[q]:UnlockHighlight() end
    if running then ui.q[q]:Disable() else ui.q[q]:Enable() end
  end
end

Rebuild = function()
  if not ui.frame or not ui.frame:IsVisible() then return end
  if state ~= "idle" then
    curList = runList
  else
    curList = Scan()
  end
  Render()
end

----------------------------------------------------------------------
-- UI: construction
----------------------------------------------------------------------
local btnCount = 0
local function MakeButton(parent, text, w, h)
  btnCount = btnCount + 1
  local b = CreateFrame("Button", "MassDisenchantButton" .. btnCount, parent, "UIPanelButtonTemplate")
  b:SetWidth(w)
  b:SetHeight(h)
  b:SetText(text)
  return b
end

local function BuildMinimapButton()
  local mm = CreateFrame("Button", "MassDisenchantMinimapButton", Minimap)
  mm:SetWidth(31)
  mm:SetHeight(31)
  mm:SetFrameStrata("MEDIUM")
  mm:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local icon = mm:CreateTexture(nil, "BACKGROUND")
  icon:SetTexture("Interface\\Icons\\INV_Enchant_ShardBrilliantLarge")
  icon:SetWidth(20)
  icon:SetHeight(20)
  icon:SetPoint("CENTER", mm, "CENTER", 0, 1)
  icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

  local border = mm:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetWidth(53)
  border:SetHeight(53)
  border:SetPoint("TOPLEFT", mm, "TOPLEFT", 0, 0)

  local function Place()
    local a = math.rad(MassDisenchantDB.minimapAngle or 200)
    mm:ClearAllPoints()
    mm:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * 80, math.sin(a) * 80)
  end
  Place()

  mm:RegisterForClicks("LeftButtonUp")
  mm:RegisterForDrag("LeftButton")
  mm:SetScript("OnDragStart", function() this.dragging = true end)
  mm:SetScript("OnDragStop", function() this.dragging = false end)
  mm:SetScript("OnUpdate", function()
    if this.dragging then
      local mx, my = Minimap:GetCenter()
      local cx, cy = GetCursorPosition()
      local s = Minimap:GetEffectiveScale()
      cx, cy = cx / s, cy / s
      MassDisenchantDB.minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
      Place()
    end
  end)
  mm:SetScript("OnClick", function()
    if ui.frame:IsVisible() then ui.frame:Hide() else ui.frame:Show() end
  end)
  mm:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this, "ANCHOR_LEFT")
    GameTooltip:AddLine("Mass Disenchant", 1, 1, 1)
    GameTooltip:AddLine("Click: open window", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Drag: move button", 0.8, 0.8, 0.8)
    GameTooltip:Show()
  end)
  mm:SetScript("OnLeave", function() GameTooltip:Hide() end)

  if MassDisenchantDB.hideMinimap then mm:Hide() end
  ui.minimap = mm
end

local function BuildUI()
  local f = CreateFrame("Frame", "MassDisenchantFrame", UIParent)
  ui.frame = f
  f:SetWidth(380)
  f:SetHeight(504)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
  f:SetFrameStrata("DIALOG")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function() this:StartMoving() end)
  f:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
  f:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
  })
  f:SetScript("OnShow", function() Rebuild() end)
  f:Hide()
  if UISpecialFrames then tinsert(UISpecialFrames, "MassDisenchantFrame") end

  -- Header
  local header = f:CreateTexture(nil, "ARTWORK")
  header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
  header:SetWidth(300)
  header:SetHeight(64)
  header:SetPoint("TOP", f, "TOP", 0, 12)
  local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  title:SetPoint("TOP", header, "TOP", 0, -14)
  title:SetText("Mass Disenchant")

  local close = CreateFrame("Button", "MassDisenchantClose", f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

  -- Quality selector
  local qlabel = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  qlabel:SetPoint("TOPLEFT", f, "TOPLEFT", 24, -57)
  qlabel:SetText("Disenchant up to:")

  ui.q = {}
  for q = 2, 4 do
    local b = MakeButton(f, QTEXT[q], 64, 22)
    b.quality = q
    b:SetPoint("TOPLEFT", f, "TOPLEFT", 150 + (q - 2) * 66, -52)
    b:SetScript("OnClick", function()
      if state ~= "idle" then return end
      MassDisenchantDB.maxQuality = this.quality
      statusMsg = nil
      if this.quality == 4 then
        statusMsg = "|cffff5555Warning: epic items will be disenchanted!|r"
      end
      offset = 0
      Rebuild()
    end)
    ui.q[q] = b
  end

  -- List background
  local listBg = CreateFrame("Frame", nil, f)
  listBg:SetWidth(340)
  listBg:SetHeight(290)
  listBg:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -82)
  listBg:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  listBg:SetBackdropColor(0, 0, 0, 0.65)
  listBg:SetBackdropBorderColor(0.7, 0.7, 0.7, 1)
  listBg:EnableMouseWheel(true)

  ui.empty = listBg:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  ui.empty:SetPoint("CENTER", listBg, "CENTER", 0, 0)
  ui.empty:SetText("No eligible items in your bags.")

  -- Scrollbar
  local slider = CreateFrame("Slider", "MassDisenchantSlider", listBg)
  slider:SetOrientation("VERTICAL")
  slider:SetWidth(16)
  slider:SetPoint("TOPRIGHT", listBg, "TOPRIGHT", -6, -8)
  slider:SetPoint("BOTTOMRIGHT", listBg, "BOTTOMRIGHT", -6, 8)
  slider:SetBackdrop({
    bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
    edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
    tile = true, tileSize = 8, edgeSize = 8,
    insets = { left = 3, right = 3, top = 6, bottom = 6 },
  })
  slider:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
  local thumb = slider:GetThumbTexture()
  thumb:SetWidth(18)
  thumb:SetHeight(24)
  thumb:SetTexCoord(0.20, 0.80, 0.125, 0.875)
  slider:SetMinMaxValues(0, 0)
  slider:SetValueStep(1)
  slider:SetValue(0)
  slider:SetScript("OnValueChanged", function()
    if ui.updating then return end
    offset = math.floor(this:GetValue() + 0.5)
    Render()
  end)
  ui.slider = slider

  listBg:SetScript("OnMouseWheel", function()
    if not ui.slider:IsVisible() then return end
    ui.slider:SetValue(ui.slider:GetValue() - arg1)
  end)

  -- Rows
  ui.rows = {}
  for i = 1, ROWS do
    local row = CreateFrame("Button", "MassDisenchantRow" .. i, listBg)
    row:SetWidth(304)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", listBg, "TOPLEFT", 8, -5 - (i - 1) * ROW_H)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    row:EnableMouseWheel(true)
    row:SetScript("OnMouseWheel", function()
      if not ui.slider:IsVisible() then return end
      ui.slider:SetValue(ui.slider:GetValue() - arg1)
    end)

    local stripe = row:CreateTexture(nil, "BACKGROUND")
    stripe:SetAllPoints(row)
    if math.mod(i, 2) == 0 then stripe:SetTexture(1, 1, 1, 0.05) else stripe:SetTexture(1, 1, 1, 0) end

    row.active = row:CreateTexture(nil, "BACKGROUND")
    row.active:SetAllPoints(row)
    row.active:SetTexture(1, 0.82, 0, 0.18)
    row.active:Hide()

    row.border = row:CreateTexture(nil, "BORDER")
    row.border:SetWidth(26)
    row.border:SetHeight(26)
    row.border:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.border:SetTexture(1, 1, 1, 1)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetWidth(22)
    row.icon:SetHeight(22)
    row.icon:SetPoint("CENTER", row.border, "CENTER", 0, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", row.border, "RIGHT", 8, 0)
    row.name:SetWidth(180)
    row.name:SetHeight(14)
    row.name:SetJustifyH("LEFT")

    row.status = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.status:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.status:SetWidth(70)
    row.status:SetJustifyH("RIGHT")

    row:SetScript("OnClick", function()
      if state ~= "idle" then return end
      local e = this.entry
      if not e then return end
      if e.ignored then
        MassDisenchantDB.ignore[e.id] = nil
      else
        MassDisenchantDB.ignore[e.id] = true
      end
      statusMsg = nil
      Rebuild()
    end)
    row:SetScript("OnEnter", function()
      local e = this.entry
      if not e then return end
      GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
      if GetContainerItemLink(e.bag, e.slot) == e.link then
        GameTooltip:SetBagItem(e.bag, e.slot)
      else
        GameTooltip:SetHyperlink("item:" .. e.id .. ":0:0:0")
      end
      if state == "idle" then
        GameTooltip:AddLine(" ")
        if e.ignored then
          GameTooltip:AddLine("Click to unprotect", 0.4, 0.67, 1)
        else
          GameTooltip:AddLine("Click to protect from disenchanting", 0.4, 0.67, 1)
        end
      end
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:Hide()
    ui.rows[i] = row
  end

  -- Summary line
  ui.summary = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  ui.summary:SetPoint("TOPLEFT", f, "TOPLEFT", 24, -380)
  ui.summary:SetWidth(332)
  ui.summary:SetHeight(12)
  ui.summary:SetJustifyH("LEFT")

  -- Progress bar
  local barBg = CreateFrame("Frame", nil, f)
  barBg:SetWidth(348)
  barBg:SetHeight(24)
  barBg:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -396)
  barBg:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  barBg:SetBackdropColor(0, 0, 0, 0.8)
  barBg:SetBackdropBorderColor(0.7, 0.7, 0.7, 1)

  local bar = CreateFrame("StatusBar", nil, f)
  bar:SetWidth(338)
  bar:SetHeight(14)
  bar:SetPoint("TOPLEFT", f, "TOPLEFT", 21, -401)
  bar:SetFrameLevel(barBg:GetFrameLevel() + 1)
  bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  bar:SetStatusBarColor(0.58, 0.35, 0.95)
  bar:SetMinMaxValues(0, 1)
  bar:SetValue(0)
  bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  bar.text:SetPoint("CENTER", bar, "CENTER", 0, 0)
  ui.bar = bar

  -- Buttons
  ui.start = MakeButton(f, "Disenchant All", 200, 26)
  ui.start:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -428)
  ui.start:SetScript("OnClick", function()
    if state ~= "idle" then
      Stop("cancelled")
    elseif MassDisenchantDB.ctrlForAll and not IsControlKeyDown() then
      Start(true)    -- option on, CTRL not held: just one item
    else
      Start()        -- everything until the list is empty
    end
  end)
  -- keep the label in sync with the CTRL key while the window is open
  ui.start:SetScript("OnUpdate", function()
    if state ~= "idle" then return end
    local want = StartLabel()
    if this:GetText() ~= want then this:SetText(want) end
  end)
  ui.start:SetScript("OnEnter", function()
    if not MassDisenchantDB.ctrlForAll then return end
    GameTooltip:SetOwner(this, "ANCHOR_TOP")
    GameTooltip:AddLine("Click: disenchant the next item", 1, 1, 1)
    GameTooltip:AddLine("CTRL + click: disenchant everything", 0.4, 0.67, 1)
    GameTooltip:Show()
  end)
  ui.start:SetScript("OnLeave", function() GameTooltip:Hide() end)

  ui.refresh = MakeButton(f, "Refresh", 130, 26)
  ui.refresh:SetPoint("TOPLEFT", f, "TOPLEFT", 230, -428)
  ui.refresh:SetScript("OnClick", function()
    skipped = {}          -- forget previous failures (e.g. after leveling Enchanting)
    statusMsg = nil
    Rebuild()
  end)

  -- Option: CTRL + click = everything, plain click = one item
  local cb = CreateFrame("CheckButton", "MassDisenchantCtrlCheck", f, "UICheckButtonTemplate")
  cb:SetWidth(24)
  cb:SetHeight(24)
  cb:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -458)
  local cbText = getglobal("MassDisenchantCtrlCheckText")
  if cbText then
    cbText:SetText("Hold CTRL to disenchant all (click = one item)")
    if GameFontHighlightSmall then cbText:SetFontObject(GameFontHighlightSmall) end
  end
  cb:SetChecked(MassDisenchantDB.ctrlForAll and 1 or nil)
  cb:SetScript("OnClick", function()
    if this:GetChecked() then
      MassDisenchantDB.ctrlForAll = true
    else
      MassDisenchantDB.ctrlForAll = nil
    end
    Touch()
  end)

  local hint = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  hint:SetPoint("TOP", f, "TOPLEFT", 190, -486)
  hint:SetText("Click an item in the list to protect it")

  BuildMinimapButton()
end

----------------------------------------------------------------------
-- Events
----------------------------------------------------------------------
events:RegisterEvent("VARIABLES_LOADED")
events:RegisterEvent("BAG_UPDATE")
events:RegisterEvent("SPELLCAST_START")
events:RegisterEvent("SPELLCAST_STOP")
events:RegisterEvent("SPELLCAST_FAILED")
events:RegisterEvent("SPELLCAST_INTERRUPTED")
events:RegisterEvent("LOOT_OPENED")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("UI_ERROR_MESSAGE")

events:SetScript("OnEvent", function()
  if event == "VARIABLES_LOADED" then
    if not MassDisenchantDB then MassDisenchantDB = {} end
    if not MassDisenchantDB.maxQuality then MassDisenchantDB.maxQuality = 2 end
    if not MassDisenchantDB.ignore then MassDisenchantDB.ignore = {} end
    BuildUI()
    return
  end

  if event == "BAG_UPDATE" then
    if state == "idle" then Touch() end
    return
  end

  if state == "idle" then return end

  if event == "SPELLCAST_START" then
    if arg1 == SPELL and state == "casting" then started = true end

  elseif event == "SPELLCAST_STOP" then
    if state == "casting" and started then
      done = done + 1
      if current then current.status = "done" end
      current = nil
      state = "delay"
      delayTime = DELAY_AFTER_CAST
      timer = 0
      Touch()
    end

  elseif event == "SPELLCAST_FAILED" or event == "SPELLCAST_INTERRUPTED" then
    if state == "casting" then
      if started then
        Stop("cast interrupted")
      else
        if SpellIsTargeting() then SpellStopTargeting() end
        SkipCurrent()
        current = nil
        state = "delay"
        delayTime = 0.4
        timer = 0
        Touch()
      end
    end

  elseif event == "LOOT_OPENED" then
    for i = GetNumLootItems(), 1, -1 do
      LootSlot(i)
    end

  elseif event == "PLAYER_REGEN_DISABLED" then
    Stop("you entered combat")

  elseif event == "UI_ERROR_MESSAGE" then
    if arg1 == (ERR_INV_FULL or "Inventory is full.") then
      Stop("bags are full")
    end
  end
end)

events:SetScript("OnUpdate", function()
  local elapsed = arg1

  -- throttled UI refresh
  uiTimer = uiTimer + elapsed
  if uiDirty and uiTimer > 0.1 then
    uiDirty = false
    uiTimer = 0
    Rebuild()
  end

  if state == "idle" then return end
  timer = timer + elapsed

  if state == "casting" then
    if not started and timer > START_TIMEOUT then
      if SpellIsTargeting() then SpellStopTargeting() end
      SkipCurrent()
      current = nil
      state = "delay"
      delayTime = 0.4
      timer = 0
      Touch()
    elseif timer > CAST_TIMEOUT then
      Stop("cast timed out")
    end

  elseif state == "delay" then
    if timer >= delayTime then
      -- give an open loot window a moment longer to close
      if LootFrame and LootFrame:IsVisible() and timer < delayTime + 3 then return end
      Next()
    end
  end
end)

----------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------
SLASH_MASSDE1 = "/md"
SLASH_MASSDE2 = "/massde"
SlashCmdList["MASSDE"] = function(msg)
  msg = msg or ""
  local _, _, cmd, rest = strfind(msg, "^(%S*)%s*(.*)$")
  cmd = strlower(cmd or "")

  if cmd == "" or cmd == "show" or cmd == "toggle" then
    if ui.frame then
      if cmd == "show" or not ui.frame:IsVisible() then ui.frame:Show() else ui.frame:Hide() end
    end
  elseif cmd == "hide" then
    if ui.frame then ui.frame:Hide() end
  elseif cmd == "start" then
    Start()
  elseif cmd == "stop" then
    if state == "idle" then Say("Not running.") else Stop("cancelled") end
  elseif cmd == "list" then
    List()
  elseif cmd == "quality" then
    local q = QUALITY[strlower(rest or "")]
    if q then
      MassDisenchantDB.maxQuality = q
      Say("Max quality set to " .. QNAME[q] .. (q == 4 and "  |cffff0000(careful: epics will be disenchanted!)|r" or ""))
      Touch()
    else
      Say("Usage: /md quality green|blue|epic  (current: " .. QNAME[MassDisenchantDB.maxQuality] .. ")")
    end
  elseif cmd == "ignore" or cmd == "unignore" then
    local id = GetItemId(rest)
    if not id then
      Say("Usage: /md " .. cmd .. " [shift-click an item link]")
    elseif cmd == "ignore" then
      MassDisenchantDB.ignore[id] = true
      Say("Protecting " .. rest)
      Touch()
    else
      MassDisenchantDB.ignore[id] = nil
      Say("No longer protecting " .. rest)
      Touch()
    end
  elseif cmd == "minimap" then
    if ui.minimap then
      if ui.minimap:IsVisible() then
        ui.minimap:Hide()
        MassDisenchantDB.hideMinimap = true
      else
        ui.minimap:Show()
        MassDisenchantDB.hideMinimap = nil
      end
    end
  else
    Say("Commands:")
    DEFAULT_CHAT_FRAME:AddMessage("  /md               - open / close the window")
    DEFAULT_CHAT_FRAME:AddMessage("  /md start | stop  - run without the window")
    DEFAULT_CHAT_FRAME:AddMessage("  /md list          - print what would be disenchanted")
    DEFAULT_CHAT_FRAME:AddMessage("  /md quality X     - green (default), blue or epic")
    DEFAULT_CHAT_FRAME:AddMessage("  /md ignore [item] / unignore [item]")
    DEFAULT_CHAT_FRAME:AddMessage("  /md minimap       - show / hide the minimap button")
  end
end
