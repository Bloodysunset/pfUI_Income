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

-- Parse "X Gold Y Silver Z Copper" style chat → copper
local function parseMoneyFromChat(msg)
  if not msg or type(msg) ~= "string" then return 0 end
  local g = tonumber(string.match(msg, "(%d+)%s*[Gg]old")) or 0
  local s = tonumber(string.match(msg, "(%d+)%s*[Ss]ilver")) or 0
  local c = tonumber(string.match(msg, "(%d+)%s*[Cc]opper")) or 0
  return g * 10000 + s * 100 + c
end

local function attributeMoneyGain(diff)
  if diff <= 0 then return end
  income.total = income.total + diff

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
  -- Unclassified gold (trade, AH deposit refund, etc.) stays in Other via tooltip math
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

local function appendIncomeTooltip()
  if not GameTooltip:IsShown() then return end

  local accounted = income.loot + income.auction + income.vendor + income.quest
  local other = math.max(0, income.total - accounted)

  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("|cff33ffccSession income|r")
  GameTooltip:AddDoubleLine("Loot", GetCoinTextureString(income.loot))
  GameTooltip:AddDoubleLine("Auction", GetCoinTextureString(income.auction))
  GameTooltip:AddDoubleLine("Vendor", GetCoinTextureString(income.vendor))
  GameTooltip:AddDoubleLine("Quest", GetCoinTextureString(income.quest))
  GameTooltip:AddDoubleLine("Other", GetCoinTextureString(other))
  GameTooltip:Show()
end

local function hookMoneyFrame()
  if not MoneyFrame or not MoneyFrame.HookScript then return end
  MoneyFrame:HookScript("OnEnter", appendIncomeTooltip)
end

local initAttempts = 0
local MAX_INIT_ATTEMPTS = 120

local function tryHookMoneyFrame()
  if MoneyFrame and MoneyFrame.HookScript then
    hookMoneyFrame()
    return true
  end
  return false
end

local init = CreateFrame("Frame")
init:RegisterEvent("PLAYER_LOGIN")
init:SetScript("OnEvent", function()
  if event ~= "PLAYER_LOGIN" then return end
  this:SetScript("OnEvent", nil)
  if tryHookMoneyFrame() then return end
  init:SetScript("OnUpdate", function()
    initAttempts = initAttempts + 1
    if tryHookMoneyFrame() or initAttempts >= MAX_INIT_ATTEMPTS then
      this:SetScript("OnUpdate", nil)
    end
  end)
end)
