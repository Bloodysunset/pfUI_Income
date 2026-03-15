-- pfUI_Income: session income by source (loot, auction/mail, vendor, quest, other)
-- Events: CHAT_MSG_MONEY, MAIL_INBOX_UPDATE + TakeInboxMoney, MERCHANT_UPDATE + sell,
--         QUEST_COMPLETE + PLAYER_MONEY
-- Compatible with mailbox addons (e.g. TurtleMail) that collect mail without
-- calling the global TakeInboxMoney: we use MAIL_INBOX_UPDATE + MailFrame visible
-- as a fallback to attribute gold to mail. No dependency on those addons.

local income = {
  total = 0,
  loot = 0,
  auction = 0, -- mail / AH cash (money taken from inbox)
  vendor = 0,
  quest = 0,
}

local lastMoney = GetMoney()

--- Pending attribution for PLAYER_MONEY (order matters: most specific first)
local pendingVendor = false   -- SellMerchantItem
local pendingMailCash = false -- TakeInboxMoney (fires before money in same call chain)
local pendingQuestUntil = 0  -- GetTime() until which next gain counts as quest
--- When mailbox addons collect without using global TakeInboxMoney, we use this:
local lastMailInboxUpdate = 0
local MAIL_ATTRIBUTION_WINDOW = 1.0 -- seconds

--- Debug state (set when hooks are applied); used by /pfincome
local debug = { pfUIOutputPanelHooked = false, gameTooltipOnShowHooked = true }

--- Send a line to chat (vanilla-safe; print() may not exist or work in some clients)
local function chat(msg)
  if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    DEFAULT_CHAT_FRAME:AddMessage(tostring(msg))
  elseif print then
    print(msg)
  end
end

-- Parse "X Gold Y Silver Z Copper" style chat → copper (use string.find with captures; no match/strmatch)
local function parseMoneyFromChat(msg)
  if not msg or type(msg) ~= "string" then return 0 end
  local find = string.find
  if not find then return 0 end
  local _, _, g = find(msg, "(%d+)%s*[Gg]old")
  local _, _, s = find(msg, "(%d+)%s*[Ss]ilver")
  local _, _, c = find(msg, "(%d+)%s*[Cc]opper")
  g = tonumber(g) or 0
  s = tonumber(s) or 0
  c = tonumber(c) or 0
  return g * 10000 + s * 100 + c
end

local function attributeMoneyGain(diff)
  if diff == 0 then return end
  income.total = income.total + diff

  -- Loss (e.g. buy-back at vendor): only total + vendor net
  if diff < 0 then
    if MerchantFrame and MerchantFrame:IsVisible() then
      income.vendor = income.vendor + diff  -- vendor is net (sales - buybacks)
      if income.vendor < 0 then income.vendor = 0 end
    end
    return
  end

  -- Gain attribution
  if pendingMailCash then
    income.auction = income.auction + diff
    pendingMailCash = false
    pendingVendor = false
    lastMailInboxUpdate = 0 -- fallback must not steal next gain after MAIL_INBOX_UPDATE
    return
  end
  if pendingVendor then
    income.vendor = income.vendor + diff
    pendingVendor = false
    return
  end
  if GetTime() <= pendingQuestUntil then
    income.quest = income.quest + diff
    pendingQuestUntil = 0
    return
  end
  -- Fallback for mailbox addons (e.g. TurtleMail "Collect All") that call the
  -- original TakeInboxMoney stored at their load time, so our hook never runs.
  if MailFrame and MailFrame:IsVisible()
      and (GetTime() - lastMailInboxUpdate) <= MAIL_ATTRIBUTION_WINDOW then
    income.auction = income.auction + diff
    return
  end
  -- Fallback: vendor sell when our SellMerchantItem hook isn't used (e.g. client uses different API)
  if MerchantFrame and MerchantFrame:IsVisible() then
    income.vendor = income.vendor + diff
    return
  end
  -- Unclassified stays as total only; loot comes from CHAT_MSG_MONEY (avoids double count when both fire)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_MONEY")
frame:RegisterEvent("CHAT_MSG_MONEY")
frame:RegisterEvent("MAIL_INBOX_UPDATE")
frame:RegisterEvent("MERCHANT_UPDATE")
frame:RegisterEvent("QUEST_COMPLETE")

frame:SetScript("OnEvent", function()
  if event == "PLAYER_LOGIN" then
    lastMoney = GetMoney()
    pendingVendor = false
    pendingMailCash = false
    pendingQuestUntil = 0
    return
  end

  if event == "PLAYER_MONEY" then
    local current = GetMoney()
    local diff = current - lastMoney
    lastMoney = current
    attributeMoneyGain(diff)
    return
  end

  if event == "CHAT_MSG_MONEY" then
    local copper = parseMoneyFromChat(arg1)
    if copper > 0 then
      income.loot = income.loot + copper
    end
    return
  end

  if event == "MAIL_INBOX_UPDATE" then
    -- Fires when inbox changes (open, take mail, new mail). When mailbox is open,
    -- next PLAYER_MONEY is likely from taking cash; used as fallback when our
    -- TakeInboxMoney hook isn't used (e.g. TurtleMail bulk collect).
    if MailFrame and MailFrame:IsVisible() then
      lastMailInboxUpdate = GetTime()
    end
    return
  end

  if event == "MERCHANT_UPDATE" then
    -- Listed for parity with your source table; vendor $ is tied to SellMerchantItem → PLAYER_MONEY.
    return
  end

  if event == "QUEST_COMPLETE" then
    -- Quest money usually applies immediately after; narrow window avoids stealing next loot
    pendingQuestUntil = GetTime() + 0.35
    return
  end
end)

-- Mail cash: PLAYER_MONEY runs during TakeInboxMoney; flag before Blizzard adds money.
-- MAIL_INBOX_UPDATE runs after inbox changes; cash is applied inside TakeInboxMoney → PLAYER_MONEY.
local _TakeInboxMoney = TakeInboxMoney
if _TakeInboxMoney then
  TakeInboxMoney = function(index)
    pendingMailCash = true
    _TakeInboxMoney(index)
    if pendingMailCash then
      pendingMailCash = false
    end
  end
end

local _SellMerchantItem = SellMerchantItem
if _SellMerchantItem then
  SellMerchantItem = function(index)
    pendingVendor = true
    return _SellMerchantItem(index)
  end
end

local SESSION_INCOME_HEADER = "Session income"

-- Format copper as "Xg Ys Zc"; client may lack GetCoinTextureString (post-vanilla) or have CreateGoldString (pfUI)
local function formatMoney(copper)
  copper = tonumber(copper) or 0
  if GetCoinTextureString then
    return GetCoinTextureString(copper)
  end
  if CreateGoldString then
    return CreateGoldString(copper)
  end
  local g = math.floor(copper / 10000)
  local s = math.floor(math.mod(copper, 10000) / 100)
  local c = math.mod(copper, 100)
  if g > 0 then
    return string.format("%dg %ds %dc", g, s, c)
  elseif s > 0 then
    return string.format("%ds %dc", s, c)
  else
    return string.format("%dc", c)
  end
end

-- Colors: white numbers, gold/silver/copper for g/s/c (tooltip only)
local C_WHITE   = "|cffffffff"
local C_GOLD   = "|cffffcc00"
local C_SILVER = "|cffc0c0c0"
local C_COPPER = "|cffcd7f32"
local C_END    = "|r"

local function formatMoneyColored(copper)
  copper = tonumber(copper) or 0
  local g = math.floor(copper / 10000)
  local s = math.floor(math.mod(copper, 10000) / 100)
  local c = math.mod(copper, 100)
  return C_WHITE .. g .. C_END .. C_GOLD .. "g" .. C_END .. " " ..
         C_WHITE .. s .. C_END .. C_SILVER .. "s" .. C_END .. " " ..
         C_WHITE .. c .. C_END .. C_COPPER .. "c" .. C_END
end

local C_HEADER = "|cffffcc00"  -- yellow for Loot/Auction/etc

local function appendIncomeTooltip()
  if not GameTooltip or not GameTooltip:IsShown() then return end
  -- Avoid duplicate block when both OnShow and wrapped OnEnter call us
  local maxLines = (GameTooltip.NumLines and GameTooltip:NumLines()) or 20
  for i = 1, maxLines do
    local left = _G["GameTooltipTextLeft" .. i]
    if not left then break end
    local text = left:GetText()
    if text and string.find(text, SESSION_INCOME_HEADER) then return end
  end

  local accounted = income.loot + income.auction + income.vendor + income.quest
  local other = math.max(0, income.total - accounted)

  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("|cff33ffcc" .. SESSION_INCOME_HEADER .. "|r")
  GameTooltip:AddDoubleLine(C_HEADER .. "Loot" .. C_END, formatMoneyColored(income.loot))
  GameTooltip:AddDoubleLine(C_HEADER .. "Auction" .. C_END, formatMoneyColored(income.auction))
  GameTooltip:AddDoubleLine(C_HEADER .. "Vendor" .. C_END, formatMoneyColored(income.vendor))
  GameTooltip:AddDoubleLine(C_HEADER .. "Quest" .. C_END, formatMoneyColored(income.quest))
  GameTooltip:AddDoubleLine(C_HEADER .. "Other" .. C_END, formatMoneyColored(other))
  GameTooltip:Show()
end

-- Detect if current GameTooltip is the money tooltip (pfUI or similar: has "Money" and "Login"/"Now"/"Session")
local function isMoneyTooltip()
  if not GameTooltip or not GameTooltip:IsShown() then return false end
  local hasMoney, hasSession = false, false
  local maxLines = (GameTooltip.NumLines and GameTooltip:NumLines()) or 20
  for i = 1, maxLines do
    local left = _G["GameTooltipTextLeft" .. i]
    if not left then break end
    local text = left:GetText()
    if text then
      if string.find(text, "Money") or string.find(text, "Gold") then hasMoney = true end
      if string.find(text, "Login") or string.find(text, "Now") or string.find(text, "This Session") then hasSession = true end
      if string.find(text, SESSION_INCOME_HEADER) then return false end -- already added
    end
  end
  return hasMoney and hasSession
end

-- Universal fallback: when any tooltip is shown, if it's the money tooltip then append our block.
local function hookGameTooltipOnShow()
  if not GameTooltip or not GameTooltip.SetScript then return end
  local oldOnShow = GameTooltip:GetScript("OnShow")
  GameTooltip:SetScript("OnShow", function()
    if oldOnShow then oldOnShow() end
    -- Run after tooltip content is filled (pfUI fills then Show())
    if isMoneyTooltip() then
      appendIncomeTooltip()
    end
  end)
end

-- pfUI panel: gold is shown by OutputPanel("gold", value, widget.Tooltip, widget.Click).
-- The visible frame is whichever panel slot has "gold" in config. Hook OutputPanel so
-- the gold tooltip is wrapped to append our session income. If the gold slot was
-- already initialized before we hooked, wrap that frame's OnEnter directly.
local function wrapGoldTooltip(tooltip)
  if type(tooltip) ~= "function" then return tooltip end
  local orig = tooltip
  return function()
    orig()
    appendIncomeTooltip()
  end
end

local function hookPfUIPanelOutputPanel()
  if not pfUI or not pfUI.panel or not pfUI.panel.OutputPanel then return false end

  local orig = pfUI.panel.OutputPanel
  function pfUI.panel:OutputPanel(entry, value, tooltip, func)
    if entry == "gold" and type(tooltip) == "function" then
      tooltip = wrapGoldTooltip(tooltip)
    end
    return orig(self, entry, value, tooltip, func)
  end

  -- Gold slot may already be initialized; wrap that frame's OnEnter so we still show income.
  local panels = {
    pfUI.panel.left and pfUI.panel.left.left, pfUI.panel.left and pfUI.panel.left.center, pfUI.panel.left and pfUI.panel.left.right,
    pfUI.panel.right and pfUI.panel.right.left, pfUI.panel.right and pfUI.panel.right.center, pfUI.panel.right and pfUI.panel.right.right,
    pfUI.panel.minimap,
  }
  for _, fr in pairs(panels) do
    if fr and fr.initialized == "gold" then
      local oldOnEnter = fr:GetScript("OnEnter")
      if oldOnEnter then
        fr:SetScript("OnEnter", wrapGoldTooltip(oldOnEnter))
      end
      break
    end
  end
  debug.pfUIOutputPanelHooked = true
  return true
end

local function attachToMoneyLikeFrame(fr)
  if not fr then return false end

  if fr.HookScript then
    fr:HookScript("OnEnter", appendIncomeTooltip)
    return true
  end

  local oldOnEnter = fr:GetScript("OnEnter")
  fr:SetScript("OnEnter", function()
    if oldOnEnter then oldOnEnter() end
    appendIncomeTooltip()
  end)
  return true
end

local function hookMoneyFrame()
  if MoneyFrame and attachToMoneyLikeFrame(MoneyFrame) then return true end
  if pfUI and pfUI.money and pfUI.money.frame and attachToMoneyLikeFrame(pfUI.money.frame) then return true end
  if pfMoney and attachToMoneyLikeFrame(pfMoney) then return true end
  return false
end

local initAttempts = 0
local MAX_INIT_ATTEMPTS = 120

local init = CreateFrame("Frame")
init:RegisterEvent("PLAYER_LOGIN")
init:SetScript("OnEvent", function()
  if event ~= "PLAYER_LOGIN" then return end
  init:SetScript("OnEvent", nil)

  -- 1) Hook pfUI panel so gold tooltip appends our income (panel may exist at load or created later)
  if hookPfUIPanelOutputPanel() then return end

  -- 2) Fallback: hook Blizzard/pfUI money frames when pfUI panel isn't used
  if hookMoneyFrame() then return end

  init:SetScript("OnUpdate", function()
    initAttempts = initAttempts + 1
    if hookPfUIPanelOutputPanel() or hookMoneyFrame() or initAttempts >= MAX_INIT_ATTEMPTS then
      init:SetScript("OnUpdate", nil)
    end
  end)
end)

-- Hook pfUI as soon as it's available (we load after pfUI via OptionalDeps)
if hookPfUIPanelOutputPanel() then
  -- done
elseif pfUI and not pfUI.panel then
  -- panel module not loaded yet; init's OnUpdate will retry
end

-- Universal fallback: detect money tooltip by content and append. Works even if pfUI hook fails.
hookGameTooltipOnShow()

local function printDebug()
  local accounted = income.loot + income.auction + income.vendor + income.quest
  local other = math.max(0, income.total - accounted)
  chat("|cff33ffcc[pfUI Income]|r Session totals:")
  chat("  Total:  " .. formatMoney(income.total))
  chat("  Loot:   " .. formatMoney(income.loot))
  chat("  Auction:" .. formatMoney(income.auction))
  chat("  Vendor: " .. formatMoney(income.vendor))
  chat("  Quest:  " .. formatMoney(income.quest))
  chat("  Other:  " .. formatMoney(other))
  chat("  Current money: " .. formatMoney(GetMoney()) .. " (lastMoney: " .. formatMoney(lastMoney) .. ")")
  chat("Hooks: pfUI OutputPanel=" .. (debug.pfUIOutputPanelHooked and "|cff88ff88yes|r" or "|cffff8888no|r") .. ", GameTooltip OnShow=" .. (debug.gameTooltipOnShowHooked and "|cff88ff88yes|r" or "|cffff8888no|r"))
  if GameTooltip and GameTooltip:IsShown() then
    chat("Tooltip open; first 5 lines:")
    for i = 1, 5 do
      local left = _G["GameTooltipTextLeft" .. i]
      if left then
        local t = left:GetText()
        chat("  " .. i .. ": " .. (t and string.gsub(t, "|c%x%x%x%x%x%x%x%x", "") or "(nil)"))
      end
    end
  else
    chat("No tooltip open. Hover the gold display then run /pfincome again to see tooltip lines.")
  end
end

-- Register /pfincome at parse time, same way pfUI registers /rl, /pfui, /gm (no ADDON_LOADED)
SLASH_PFUIINCOME1 = "/pfincome"
function SlashCmdList.PFUIINCOME(msg, editbox)
  printDebug()
end
-- Confirm addon ran (pfUI loads first and sets print; we load after via OptionalDeps)
if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ffcc[pfUI Income]|r Loaded. Use /pfincome for session totals.")
end
