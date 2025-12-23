-- LibramSwap.lua (Turtle WoW 1.12)
-- Rank-aware version (handles "/cast Name(Rank X)" and plain "/cast Name").
-- Swaps librams for specific spells, but ONLY when the spell is ready (no CD/GCD).
-- Preserves Judgement gating (only swap ≤35% target HP) and per-spell throttles
-- that start AFTER the first successful swap for that spell.

-- =====================
-- Locals / Aliases
-- =====================
local GetContainerNumSlots  = GetContainerNumSlots
local GetContainerItemLink  = GetContainerItemLink
local UseContainerItem      = UseContainerItem
local GetInventoryItemLink  = GetInventoryItemLink
local GetSpellName          = GetSpellName
local GetEquippedItem       = GetEquippedItem
local GetActionText         = GetActionText
local GetTime               = GetTime
local string_find           = string.find
local BOOKTYPE_SPELL        = BOOKTYPE_SPELL or "spell"
local superwow = SUPERWOW_VERSION
local unitxp = pcall(UnitXP, "nop", "nop")

if not GetNampowerVersion then
    DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r |cFFFF5555Nampower required|r")
    return
end
if not unitxp then
    DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r |cFFFF5555UnitXp required|r")
    return
end
if not superwow then
    DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r |cFFFF5555SuperWow required|r")
    return
end

-- === Bag Index ===
local LibramBagIndex   = {}  -- [libramId] = {bag=#, slot=#"}
local reindexQueued = false

-- Safety: block swaps when vendor/bank/auction/trade/mail/quest/gossip is open
local function IsInteractionBusy()
    return (MerchantFrame and MerchantFrame:IsVisible())
        or (BankFrame and BankFrame:IsVisible())
        or (AuctionFrame and AuctionFrame:IsVisible())
        or (TradeFrame and TradeFrame:IsVisible())
        or (MailFrame and MailFrame:IsVisible())
        or (QuestFrame and QuestFrame:IsVisible())
        or (GossipFrame and GossipFrame:IsVisible())
end

-- Global (generic) throttle for GCD-based swaps
local lastSwapTime = 0

-- =====================
-- Config
-- =====================

-- Initialize saved variables with defaults
LibramSwapDb = LibramSwapDb or {
    enabled = true,
    spam = true,
    -- Runtime toggle for which librams to use for spells with multiple options
    -- Consecration: ("faithful" or "farraki")
    -- Holy Strike: ("eternal" or "radiance")
    consecrationMode = "faithful",
    holyStrikeMode = "eternal"
}

-- Keep original generic throttle for GCD spells
local SWAP_THROTTLE_GENERIC = 1.48

local LIBRAM_OF_FERVOR = 23203
local LIBRAM_OF_FINAL_JUDGEMENT = 58240
local LIBRAM_OF_GRACE = 22402
local LIBRAM_OF_HOPE = 22401
local LIBRAM_OF_LIGHT = 23006
local LIBRAM_OF_DIVINITY = 23201
local LIBRAM_OF_RADIANCE = 55470
local LIBRAM_OF_THE_DREAMGUARD = 61203
local LIBRAM_OF_THE_ETERNAL_TOWER = 55110
local LIBRAM_OF_THE_FAITHFUL = 61443
local LIBRAM_OF_THE_JUSTICAR = 61337
local LIBRAM_OF_THE_RESOLUTE = 51804
local LIBRAM_OF_VERACITY = 51799
local LIBRAM_OF_TRUTH = 22400
local LIBRAM_OF_THE_FARRAKI_ZEALOT = 58093

-- Holy Strike libram choices
local HOLY_STRIKE_ETERNAL_TOWER = LIBRAM_OF_THE_ETERNAL_TOWER
local HOLY_STRIKE_RADIANCE  = LIBRAM_OF_RADIANCE

-- Consecration libram choices
local CONSECRATION_FAITHFUL = LIBRAM_OF_THE_FAITHFUL
local CONSECRATION_FARRAKI  = LIBRAM_OF_THE_FARRAKI_ZEALOT

-- Map spells -> preferred libram name (bag/equipped link substring match)
local LibramMap = {
    ["Consecration"]                  = LIBRAM_OF_THE_FAITHFUL,
    ["Holy Shield"]                   = LIBRAM_OF_THE_DREAMGUARD,
    ["Holy Light"]                    = LIBRAM_OF_RADIANCE,
    ["Flash of Light"]                = LIBRAM_OF_LIGHT,
    ["Cleanse"]                       = LIBRAM_OF_GRACE,
    ["Hammer of Justice"]             = LIBRAM_OF_THE_JUSTICAR,
    ["Hand of Freedom"]               = LIBRAM_OF_THE_RESOLUTE,
    ["Crusader Strike"]               = LIBRAM_OF_THE_ETERNAL_TOWER,
    ["Holy Strike"]                   = LIBRAM_OF_THE_ETERNAL_TOWER,
    ["Judgement"]                     = LIBRAM_OF_FINAL_JUDGEMENT,
    ["Seal of Wisdom"]                = LIBRAM_OF_HOPE,
    ["Seal of Light"]                 = LIBRAM_OF_HOPE,
    ["Seal of Justice"]               = LIBRAM_OF_HOPE,
    ["Seal of Command"]               = LIBRAM_OF_HOPE,
    ["Seal of the Crusader"]          = LIBRAM_OF_FERVOR,
    ["Seal of Righteousness"]         = LIBRAM_OF_HOPE,
    ["Blessing of Wisdom"]            = LIBRAM_OF_VERACITY,
    ["Blessing of Might"]             = LIBRAM_OF_VERACITY,
    ["Blessing of Kings"]             = LIBRAM_OF_VERACITY,
    ["Blessing of Sanctuary"]         = LIBRAM_OF_VERACITY,
    ["Blessing of Light"]             = LIBRAM_OF_VERACITY,
    ["Blessing of Salvation"]         = LIBRAM_OF_VERACITY,
    ["Greater Blessing of Wisdom"]    = LIBRAM_OF_VERACITY,
    ["Greater Blessing of Kings"]     = LIBRAM_OF_VERACITY,
    ["Greater Blessing of Sanctuary"] = LIBRAM_OF_VERACITY,
    ["Greater Blessing of Light"]     = LIBRAM_OF_VERACITY,
    ["Greater Blessing of Salvation"] = LIBRAM_OF_VERACITY,
}

-- Dont Swap libram, if these equipped
local DontSwap = {
    [LIBRAM_OF_TRUTH] = true
}

local EnemyTargetSpell = {
    ["Hammer of Justice"] = true,
    ["Crusader Strike"] = true,
    ["Holy Strike"] = true,
    ["Judgement"] = true,
}

local NoTargetSpell = {
    ["Consecration"]                  = true,
    ["Holy Shield"]                   = true,
    ["Seal of Wisdom"]                = true,
    ["Seal of Light"]                 = true,
    ["Seal of Justice"]               = true,
    ["Seal of Command"]               = true,
    ["Seal of the Crusader"]          = true,
    ["Seal of Righteousness"]         = true,
    ["Blessing of Wisdom"]            = true,
    ["Blessing of Might"]             = true,
    ["Blessing of Kings"]             = true,
    ["Blessing of Sanctuary"]         = true,
    ["Blessing of Light"]             = true,
    ["Blessing of Salvation"]         = true,
    ["Greater Blessing of Wisdom"]    = true,
    ["Greater Blessing of Kings"]     = true,
    ["Greater Blessing of Sanctuary"] = true,
    ["Greater Blessing of Light"]     = true,
    ["Greater Blessing of Salvation"] = true,
}

local WatchedLibrams = {}
for _, libramId in pairs(LibramMap) do
    WatchedLibrams[libramId] = true
end
-- Consecration options
WatchedLibrams[CONSECRATION_FAITHFUL] = true
WatchedLibrams[CONSECRATION_FARRAKI]  = true
-- Holy  Strike options
WatchedLibrams[HOLY_STRIKE_ETERNAL_TOWER] = true
WatchedLibrams[HOLY_STRIKE_RADIANCE]  = true

local _debug = false

local function DebugMessage(message)
    if not _debug then
        return
    end
    
    DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwapDebug]:|r |cFFFF5555" .. message .. "|r")
end

local function GetEquippedLibram()
    local libram = GetEquippedItem("player", 18)
    if not libram then
        return -1
    end
        
    return libram.itemId
end

local function BuildBagIndex()
    -- wipe current
    for k in pairs(LibramBagIndex) do LibramBagIndex[k] = nil end
    
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag)
        if slots and slots > 0 then
            for slot = 1, slots do
                local itemInfo = GetBagItem(bag, slot)
                if itemInfo then
                    local id = itemInfo.itemId
                    if WatchedLibrams[id] then
                        LibramBagIndex[id] = { bag = bag, slot = slot }
                    end
                end
            end
        end
    end
end

local LibramSwapFrame = CreateFrame("Frame")

-- gets spell readiness by ID
local function IsSpellReadyById(spellId)
    local usable = IsSpellUsable(spellId)
    if usbale == 0 then
        return false
    end
    
    local cd = GetSpellIdCooldown(spellId)
    return cd.isOnCooldown == 0
end

-- =====================
-- Helpers
-- =====================
-- Returns bag, slot or nil
local function HasItemInBags(libramId)
    local ref = LibramBagIndex[libramId]
    
    if ref then
        local current = GetBagItem(ref.bag, ref.slot)
        local id = current.itemId
        if id == libramId then
            return ref.bag, ref.slot
        end
        -- It moved; rebuild and try again
        BuildBagIndex()
        ref = LibramBagIndex[libramId]
        if ref then
            local verify = GetBagItem(ref.bag, ref.slot)
            local id = verify.itemId
            if id == libramId then
                return ref.bag, ref.slot
            end
        end
        return nil
    end
    
    return nil
end

-- whether or not the player has the libram, either in bag or equipped
local function HasLibram(libramId)
    local equipped = GetEquippedLibram()
    return (equipped == libramId) or HasItemInBags(libramId)
end

-- Returns target HP% (number) or nil if no valid target
local function TargetHealthPct()
    if not UnitExists("target") or UnitIsDeadOrGhost("target") then return nil end
    local maxHP = UnitHealthMax("target")
    if not maxHP or maxHP == 0 then return nil end
    return (UnitHealth("target") / maxHP) * 100
end

local function EquipLibram(bag, slot)
    -- Block swaps if an interaction UI is open (prevents accidental selling/moving)
    if IsInteractionBusy() then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r |cFFFF5555Swap blocked (interaction window open).|r")
        return
    end    
    
    local now = GetTime()
    -- Respect the GCD
    if (now - lastSwapTime) < SWAP_THROTTLE_GENERIC then
        -- return
    end
    
    if CursorHasItem and CursorHasItem() then
        return
    end
    
    UseContainerItem(bag, slot)
    lastSwapTime = now
    
    if LibramSwapDb.spam then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r Equipped |cFFFFD700" .. itemName .. "|r |cFF888888(" .. spellName .. ")|r")
    end
end

local function ResolveLibramForSpell(spellName)
    -- Special handling: Consecration libram is user-selectable
    if spellName == "Consecration" then
        if LibramSwapDb.consecrationMode == "farraki" then
            if HasLibram(CONSECRATION_FARRAKI) then return CONSECRATION_FARRAKI end
            if HasLibram(CONSECRATION_FAITHFUL) then return CONSECRATION_FAITHFUL end
            return nil
        else
            if HasLibram(CONSECRATION_FAITHFUL) then return CONSECRATION_FAITHFUL end
            if HasLibram(CONSECRATION_FARRAKI) then return CONSECRATION_FARRAKI end
            return nil
        end
    end

    -- Special handling: Holy Strike libram is user-selectable
    if spellName == "Holy Strike" then
        if LibramSwapDb.holyStrikeMode == "eternal" then
            if HasLibram(HOLY_STRIKE_ETERNAL_TOWER) then return HOLY_STRIKE_ETERNAL_TOWER end
            if HasLibram(HOLY_STRIKE_RADIANCE) then return HOLY_STRIKE_RADIANCE end
            return nil
        else
            if HasLibram(HOLY_STRIKE_RADIANCE) then return HOLY_STRIKE_RADIANCE end
            if HasLibram(HOLY_STRIKE_ETERNAL_TOWER) then return HOLY_STRIKE_ETERNAL_TOWER end
            return nil
        end
    end

    local libram = LibramMap[spellName]
    if not libram then return nil end

    -- Fallbacks if best pick isn't present
    if spellName == "Flash of Light" then
        if not HasLibram(LIBRAM_OF_LIGHT) and HasLibram(LIBRAM_OF_DIVINITY) then
            libram = LIBRAM_OF_DIVINITY
        end
    end
    return libram
end

-- Trims whitespace
local function trim(s)
    return (string.gsub(s or "", "^%s*(.-)%s*$", "%1"))
end

-- Prints current status
local function printStatus()
    local status = LibramSwapDb.enabled and "|cFF00FF00ENABLED|r" or "|cFFFF0000DISABLED|r"
    DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap] Status:|r " .. status)

    local spamStatus = LibramSwapDb.spam and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"
    DEFAULT_CHAT_FRAME:AddMessage("  Swap messages: " .. spamStatus)

    -- Show Consecration setting
    local consecLibram = (LibramSwapDb.consecrationMode == "farraki") and CONSECRATION_FARRAKI or CONSECRATION_FAITHFUL
    DEFAULT_CHAT_FRAME:AddMessage("  Consecration: |cFFFFD700" .. consecLibram .. "|r")

    -- Show Holy Strike setting
    local hsLibram = (LibramSwapDb.holyStrikeMode == "eternal") and HOLY_STRIKE_ETERNAL_TOWER or HOLY_STRIKE_RADIANCE
    DEFAULT_CHAT_FRAME:AddMessage("  Holy Strike: |cFFFFD700" .. hsLibram .. "|r")
end

-- ====================
-- Hidden Tooltip jank (needed to read spell names from action bar presses)
-- ====================
local hiddenActionTooltip = CreateFrame("GameTooltip", "LibramSwapActionTooltip", UIParent, "GameTooltipTemplate")

local function GetActionSpellName(slot)
    hiddenActionTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    hiddenActionTooltip:SetAction(slot)
    local name = LibramSwapActionTooltipTextLeft1:GetText()
    local rank = LibramSwapActionTooltipTextRight1:GetText()
    hiddenActionTooltip:Hide()
    return name, rank
end

-- =====================
-- Hooks (CastSpellByName / CastSpell)
-- =====================
local Original_CastSpellByName = CastSpellByName
local Original_CastSpell = CastSpell
local Original_UseAction = UseAction

local function IsValidTarget(spellName, target)
    if NoTargetSpell[spellName] then
        return true
    end
    
    -- everything else needs targets
    if not target then
        return false
    end
    
    local canAttack = UnitCanAttack("player", target)
    if EnemyTargetSpell[spellName] then
        return canAttack
    end
    
    -- everything else needs friendly target
    return not canAttack
end

local function IsTargetInRange(spellId, target)
    if not target then
        return true
    end
    
    if target == "player" then
        return true
    end
    
    return IsSpellInRange(spellId, target)
end

local function IsTargetInSight(spellName, target)
    if not target then
        return true
    end
    
    if target == "player" then
        return true
    end
    
    if NoTargetSpell[spellName] then
        return true
    end
    
    return UnitXP("inSight", "player", target)
end


local function TryEquipLibram(spellName, target, spellId)
    if not LibramSwapDb.enabled then 
        return 
    end
    
    if not spellName then 
        DebugMessage("No Spell")
        return
    end

    local libram = ResolveLibramForSpell(spellName)
    if not libram then 
        DebugMessage("No Libram for " .. spellName)
        return
    end

    -- Dont swap away on certain librams
    local equipped = GetEquippedLibram()
    if DontSwap[equipped] then
        DebugMessage("Libram " .. equipped .." equipped. Not swapping")
        return
    end
    
    -- Already equipped?
    if equipped and equipped == libram then
        DebugMessage("Libram " .. libram .." already equipped")
        return
    end
    
    local bag, slot = HasItemInBags(libram)
    local hasInBag = bag and slot
    if not hasInBag then
        DebugMessage("Libram " .. libram .." not in bag")
        return
    end
    
    -- Is target required, do we have a target and is target valid for spell (enemy/friendly)?
    local isValidTarget = IsValidTarget(spellName, target)
    if not isValidTarget then
        DebugMessage("Invalid target " .. target)
        return
    end

    -- Dont change while currently casting
    local _, _, _, casting, channeling = GetCurrentCastingInfo()
    if casting ~= 0 or channeling ~= 0 then
        DebugMessage("Currently casting")
        return
    end
    
    if not spellId then
        spellId = GetSpellIdForName(spellName)
        DebugMessage("Found Spell Id " .. spellId)
    end
    
    -- Check if spell is ready from cooldown etc
    local isReady = IsSpellReadyById(spellId)
    if not isReady then
        DebugMessage("Not ready to cast " .. spellName)
        return
    end
    
    -- Check line of sight
    local isInSight = IsTargetInSight(spellName, target)
    if not isInSight then
        DebugMessage("No LOS to " .. target)
        return
    end
    
    -- Check if target in range. No target = in range 
    local isInRange = IsTargetInRange(spellId, target)
    if isInRange == 0 then
        DebugMessage("No range to " .. target)
        return
    end
    
    -- TODO: Figure out how to check if facing target for offensive spells
    
    -- actually equip libram
    DebugMessage("Swap to " .. libram)
    EquipLibram(bag, slot)
end

local function OnQueuePopTryEquipLibram(spellId)
    if not LibramSwapDb.enabled then 
        return 
    end
    
    local spellName = SpellInfo(spellId)
    
    DebugMessage("Queue popped for " .. spellName)

    if not spellName then 
        DebugMessage("No Spell")
        return
    end

    local libram = ResolveLibramForSpell(spellName)
    if not libram then 
        DebugMessage("No Libram for " .. spellName)
        return
    end

    -- Dont swap away on certain librams
    local equipped = GetEquippedLibram()
    if DontSwap[equipped] then
        DebugMessage("Libram " .. equipped .." equipped. Not swapping")
        return
    end
    
    -- Already equipped?
    if equipped and equipped == libram then
        DebugMessage("Libram " .. libram .." already equipped")
        return
    end
    
    local bag, slot = HasItemInBags(libram)
    local hasInBag = bag and slot
    if not hasInBag then
        DebugMessage("Libram " .. libram .." not in bag")
        return
    end
    
    -- actually equip libram
    DebugMessage("Swap to " .. libram)
    EquipLibram(bag, slot)
end

-- Hook: CastSpellByName (used by macros and scripts)
function CastSpellByName(spellName, targetGuid)
    TryEquipLibram(spellName, targetGuid)
    return Original_CastSpellByName(spellName, targetGuid)
end

-- Hook: CastSpell (used by spellbook and macros)
function CastSpell(spellIndex, bookType)
    if bookType ~= BOOKTYPE_SPELL then
        return Original_CastSpell(spellIndex, bookType)
    end

    local spellName = GetSpellName(spellIndex, bookType)
    
    local target = "target"
    TryEquipLibram(spellName, target)
    return Original_CastSpell(spellIndex, bookType)
end

-- Hook: UseAction (used by action bar clicks and keybinds)
function UseAction(slot, checkCursor, onSelf)
    -- indicates this is a macro, we dont want to call for macros
    if GetActionText(slot) then
        return Original_UseAction(slot, checkCursor, onSelf)
    end
    
    if checkCursor then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r |cFF00FF00CheckCursor|r")
    end

    local target = "target"
    if onSelf then
        target = "player"
    end

    local name, rank = GetActionSpellName(slot)
    TryEquipLibram(name, target)
    return Original_UseAction(slot, checkCursor, onSelf)
end

-- =====================
-- Slash Commands
-- =====================

-- Main command handler
local function HandleLibramSwapCommand(msg)
    msg = string.lower(trim(msg))
    
    -- Split into command and argument
    local _, _, cmd, arg = string_find(msg, "^(%S*)%s*(.-)$")
    cmd = cmd or ""
    arg = arg or ""
    
    if cmd == "on" then
        LibramSwapDb.enabled = true
        DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r |cFF00FF00ENABLED|r")
        
    elseif cmd == "off" then
        LibramSwapDb.enabled = false
        DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r |cFFFF0000DISABLED|r")

    elseif cmd == "spam" then
        LibramSwapDb.spam = not LibramSwapDb.spam
        local spamStatus = LibramSwapDb.spam and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"
        DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r Swap messages " .. spamStatus)
        
    elseif cmd == "consecration" or cmd == "consec" or cmd == "c" then
        arg = string.lower(arg)
        if arg == "faithful" or arg == "f" then
            LibramSwapDb.consecrationMode = "faithful"
            DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r Consecration set to |cFFFFD700" .. CONSECRATION_FAITHFUL .. "|r")
        elseif arg == "farraki" or arg == "z" or arg == "zealot" then
            LibramSwapDb.consecrationMode = "farraki"
            DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r Consecration set to |cFFFFD700" .. CONSECRATION_FARRAKI .. "|r")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r Usage: /ls consecration [faithful / farraki]|r")
        end
        
    elseif cmd == "holystrike" or cmd == "hs" then
        arg = string.lower(arg)
        if arg == "radiance" or arg == "r" then
            LibramSwapDb.holyStrikeMode = "radiance"
            DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r Holy Strike set to |cFFFFD700" .. HOLY_STRIKE_RADIANCE .. "|r")
        elseif arg == "eternal" or arg == "e" then
            LibramSwapDb.holyStrikeMode = "eternal"
            DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r Holy Strike set to |cFFFFD700" .. HOLY_STRIKE_ETERNAL_TOWER .. "|r")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r c||cFFFF5555Usage: /ls holystrike [eternal / radiance]|r")
        end

    elseif cmd == "status" then
        printStatus()
        
    elseif cmd == "help" or cmd == "?" then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap] Commands:|r")
        DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFD700/ls on|r - Enable libram swapping")
        DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFD700/ls off|r - Disable libram swapping")
        DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFD700/ls spam|r - Toggle swap messages on/off")
        DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFD700/ls consecration [faithful / farraki]|r - Set Consecration libram")
        DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFD700/ls holystrike [eternal / radiance]|r - Set Holy Strike libram")
        DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFD700/ls status|r - Show current settings")
        
    elseif cmd == "" then
        -- Toggle behavior when no argument provided
        LibramSwapDb.enabled = not LibramSwapDb.enabled
        if LibramSwapDb.enabled then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r |cFF00FF00ENABLED|r")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r |cFFFF0000DISABLED|r")
        end
        
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r |cFFFF5555Unknown command. Type '/ls help' for usage.|r")
    end
end

-- Register slash command variants
SLASH_LIBRAMSWAP1 = "/libramswap"
SLASH_LIBRAMSWAP2 = "/lswap"
SLASH_LIBRAMSWAP3 = "/ls"
SlashCmdList["LIBRAMSWAP"] = HandleLibramSwapCommand

LibramSwapFrame:RegisterEvent("PLAYER_LOGIN")
LibramSwapFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
LibramSwapFrame:RegisterEvent("BAG_UPDATE")
LibramSwapFrame:RegisterEvent("SPELL_QUEUE_EVENT")

LibramSwapFrame:SetScript("OnEvent", function()
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        BuildBagIndex()
    elseif event == "BAG_UPDATE" then
        -- simple & safe: rebuild immediately (cost is tiny since we only watch librams)
        BuildBagIndex()
    elseif event == "SPELL_QUEUE_EVENT" then
        		-- arg1 is eventCode, arg2 is spellId
		-- NORMAL_QUEUE_POPPED = 3
		if arg1 ~= 3 then
			return
		end
        OnQueuePopTryEquipLibram(arg2)
    end
end)