local addonName, ns = ...

local ADDON_PATH = "Interface\\AddOns\\AssistedCombatAudio\\sounds\\"
local PREFIX = "|cff00ccff[ACA]|r "

local CHANNELS = { "Master", "SFX", "Dialog" }
local DISPLAY_MODES = { "Toujours", "En combat uniquement", "Avec cible hostile", "Combat OU cible hostile" }

local GetTime           = GetTime
local GetActionInfo     = GetActionInfo
local GetBindingKey     = GetBindingKey
local InCombatLockdown  = InCombatLockdown
local UnitCanAttack     = UnitCanAttack
local UnitInVehicle     = UnitInVehicle
local UnitGroupRolesAssigned = UnitGroupRolesAssigned
local C_Spell           = C_Spell
local C_SpellBook       = C_SpellBook
local C_AssistedCombat  = C_AssistedCombat
local C_Timer           = C_Timer

local rotationalSpells = {}
local BindingByButton = {}
local SpellIDByButton = {}
local ButtonsBySlot = {}
local SlotByButton = {}
local OverrideBindingByButton = nil

local playerClass = select(2, UnitClass("player"))

local KEY_TO_FILE = {}
local SUPPORTED_KEYS = {
    "A","Z","E","R","T","Q","S","D","F","G","W","X","C","V","B",
    "1","2","3","4","5",
}
for _, k in ipairs(SUPPORTED_KEYS) do
    KEY_TO_FILE[k] = "key_" .. k:lower() .. ".ogg"
end

---------------------------------------------------------------------------
-- Defaults (flat structure for Settings API)
---------------------------------------------------------------------------

local defaults = {
    enabled = true,
    soundChannelIndex = 3,  -- 1=Master, 2=SFX, 3=Dialog
    duckPercent = 30,       -- reduce other sounds by this % during cue
    displayMode = 1,        -- 1=Always, 2=Combat, 3=Target, 4=Either
    hideOnMount = false,
    hideInVehicle = false,
    hideAsHealer = false,
}

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local db
local ticker
local currentSpellID
local lastAnnouncedSpellID
local lastAnnouncedTime = 0
local isDefaultUI = true
local updateInterval = 0.25
local duckRestoreTimer
local originalVolumes

local castGraceUntil = 0
local debugMode = false

---------------------------------------------------------------------------
-- Utility
---------------------------------------------------------------------------

local function ApplyDefaults(saved, defs)
    for k, v in pairs(defs) do
        if saved[k] == nil then saved[k] = v end
    end
end

local function IsValidSpellID(spellID)
    return type(spellID) == "number" and spellID > 0 and C_Spell.DoesSpellExist(spellID)
end

local function IsMountedLocal()
    if playerClass == "DRUID" then
        return GetShapeshiftForm() == 3 or IsMounted()
    end
    return IsMounted()
end

---------------------------------------------------------------------------
-- Spell & button helpers (from original addon)
---------------------------------------------------------------------------

local function GetSpellIDFromActionID(action)
    if not action then return end
    local actionType, id, subType = GetActionInfo(action)
    if (actionType == "macro" and subType == "spell")
    or (actionType == "spell" and subType ~= "assistedcombat") then
        return id
    end
end

local function IsRotationalSpell(spellID)
    return rotationalSpells[spellID] or false
end

local function GetSpellIDFromButton(buttonName)
    local actionButton = _G[buttonName]
    if not actionButton then return end
    if actionButton.spellID then
        return actionButton.spellID
    elseif actionButton.action then
        return GetSpellIDFromActionID(actionButton.action)
    end
end

local function UpdateButtonSpellID(buttonName)
    if not buttonName then return end
    local spellID = GetSpellIDFromButton(buttonName)
    local baseSpellID = spellID and C_SpellBook.FindBaseSpellByID(spellID)
    local isRotation = IsRotationalSpell(spellID) or IsRotationalSpell(baseSpellID)
    SpellIDByButton[buttonName] = isRotation and baseSpellID or nil
end

local function UpdateAllButtonsSpellID()
    for buttonName in pairs(SpellIDByButton) do
        UpdateButtonSpellID(buttonName)
    end
end

local function AddButtonToSlot(buttonName, slot)
    local oldSlot = SlotByButton[buttonName]
    if not slot or oldSlot == slot then return end
    if oldSlot then
        local oldButtons = ButtonsBySlot[oldSlot]
        if oldButtons then
            oldButtons[buttonName] = nil
            if not next(oldButtons) then ButtonsBySlot[oldSlot] = nil end
        end
    end
    SlotByButton[buttonName] = slot
    ButtonsBySlot[slot] = ButtonsBySlot[slot] or {}
    ButtonsBySlot[slot][buttonName] = true
end

local function OnActionSlotChanged(slot)
    if not slot then return end
    local buttons = ButtonsBySlot[slot]
    if not buttons then return end
    for buttonName in pairs(buttons) do
        UpdateButtonSpellID(buttonName)
    end
end

local function OnActionChanged(self, button, action)
    if not button then return end
    local buttonName = button:GetName()
    if not buttonName then return end
    C_Timer.After(0, function()
        AddButtonToSlot(buttonName, button.action)
        UpdateButtonSpellID(buttonName)
    end)
end

local function OnSpellsChanged()
    local spells = C_AssistedCombat.GetRotationSpells()
    for _, spellID in ipairs(spells) do
        if C_SpellBook.IsSpellInSpellBook(spellID) then
            rotationalSpells[spellID] = true
        end
    end
    UpdateAllButtonsSpellID()
end

local function LoadRotationalSpells()
    wipe(rotationalSpells)
    OnSpellsChanged()
end

---------------------------------------------------------------------------
-- Action bar mapping (Default, Bartender4, Dominos, ElvUI)
---------------------------------------------------------------------------

local function LoadActionSlotMap()
    local HasBartender = C_AddOns.IsAddOnLoaded("Bartender4")
    local HasDominos = C_AddOns.IsAddOnLoaded("Dominos")
    local HasElvUI = false
    if C_AddOns.IsAddOnLoaded("ElvUI") then
        local E = unpack(ElvUI)
        HasElvUI = E and E.private and E.private.actionbar and E.private.actionbar.enable or false
    end

    if HasDominos then
        local map = {
            { actionPrefix = "ACTIONBUTTON",          buttonPrefix = "DominosActionButton",       start = 1,   last = 12  },
            { actionPrefix = "ACTIONBUTTON",          buttonPrefix = "DominosActionButton",       start = 13,  last = 24  },
            { actionPrefix = "MULTIACTIONBAR3BUTTON", buttonPrefix = "MultiBarRightButton",       start = 25,  last = 36  },
            { actionPrefix = "MULTIACTIONBAR4BUTTON", buttonPrefix = "MultiBarLeftButton",        start = 37,  last = 48  },
            { actionPrefix = "MULTIACTIONBAR2BUTTON", buttonPrefix = "MultiBarBottomRightButton", start = 49,  last = 60  },
            { actionPrefix = "MULTIACTIONBAR1BUTTON", buttonPrefix = "MultiBarBottomLeftButton",  start = 61,  last = 72  },
            { actionPrefix = "ACTIONBUTTON",          buttonPrefix = "DominosActionButton",       start = 73,  last = 84  },
            { actionPrefix = "ACTIONBUTTON",          buttonPrefix = "DominosActionButton",       start = 85,  last = 96  },
            { actionPrefix = "ACTIONBUTTON",          buttonPrefix = "DominosActionButton",       start = 97,  last = 108 },
            { actionPrefix = "ACTIONBUTTON",          buttonPrefix = "DominosActionButton",       start = 109, last = 120 },
            { actionPrefix = "ACTIONBUTTON",          buttonPrefix = "DominosActionButton",       start = 121, last = 132 },
            { actionPrefix = "MULTIACTIONBAR5BUTTON", buttonPrefix = "MultiBar5Button",           start = 145, last = 156 },
            { actionPrefix = "MULTIACTIONBAR6BUTTON", buttonPrefix = "MultiBar6Button",           start = 157, last = 168 },
            { actionPrefix = "MULTIACTIONBAR7BUTTON", buttonPrefix = "MultiBar7Button",           start = 169, last = 180 },
        }
        for _, info in ipairs(map) do
            for slot = info.start, info.last do
                local index = slot - info.start + 1
                local buttonName = info.buttonPrefix .. index
                BindingByButton[buttonName] = info.actionPrefix .. index
                UpdateButtonSpellID(buttonName)
                local button = _G[buttonName]
                if button and button.action then AddButtonToSlot(buttonName, button.action) end
            end
        end
        OverrideBindingByButton = {}
        local overrideMap = {
            { start = 13, last = 24 }, { start = 73, last = 84 }, { start = 85, last = 96 },
            { start = 97, last = 108 }, { start = 109, last = 120 }, { start = 121, last = 132 },
        }
        for _, info in ipairs(overrideMap) do
            for slot = info.start, info.last do
                local buttonName = "DominosActionButton" .. slot
                OverrideBindingByButton[buttonName] = ("CLICK %s%s:HOTKEY"):format("DominosActionButton", slot)
            end
        end
        if Dominos and Dominos.ActionButtons then
            hooksecurefunc(Dominos.ActionButtons, "OnActionChanged", function(self, name, value)
                OnActionChanged(self, _G[name], value)
            end)
        end

    elseif HasBartender then
        local LAB = LibStub("LibActionButton-1.0", true)
        local map = {
            { actionPrefix = "ACTIONBUTTON",          id = true, buttonPrefix = "BT4Button", start = 1,   last = 12  },
            { actionPrefix = "ACTIONBUTTON",          id = true, buttonPrefix = "BT4Button", start = 13,  last = 24  },
            { actionPrefix = "MULTIACTIONBAR3BUTTON",            buttonPrefix = "BT4Button", start = 25,  last = 36  },
            { actionPrefix = "MULTIACTIONBAR4BUTTON",            buttonPrefix = "BT4Button", start = 37,  last = 48  },
            { actionPrefix = "MULTIACTIONBAR2BUTTON",            buttonPrefix = "BT4Button", start = 49,  last = 60  },
            { actionPrefix = "MULTIACTIONBAR1BUTTON",            buttonPrefix = "BT4Button", start = 61,  last = 72  },
            { actionPrefix = "ACTIONBUTTON",          id = true, buttonPrefix = "BT4Button", start = 73,  last = 84  },
            { actionPrefix = "ACTIONBUTTON",          id = true, buttonPrefix = "BT4Button", start = 85,  last = 96  },
            { actionPrefix = "ACTIONBUTTON",          id = true, buttonPrefix = "BT4Button", start = 97,  last = 108 },
            { actionPrefix = "ACTIONBUTTON",          id = true, buttonPrefix = "BT4Button", start = 109, last = 120 },
            { actionPrefix = "ACTIONBUTTON",          id = true, buttonPrefix = "BT4Button", start = 121, last = 132 },
            { actionPrefix = "MULTIACTIONBAR5BUTTON",            buttonPrefix = "BT4Button", start = 145, last = 156 },
            { actionPrefix = "MULTIACTIONBAR6BUTTON",            buttonPrefix = "BT4Button", start = 157, last = 168 },
            { actionPrefix = "MULTIACTIONBAR7BUTTON",            buttonPrefix = "BT4Button", start = 169, last = 180 },
        }
        for _, info in ipairs(map) do
            for slot = info.start, info.last do
                local id = slot - info.start + 1
                local index = info.id and id or slot
                local buttonName = info.buttonPrefix .. index
                BindingByButton[buttonName] = info.actionPrefix .. id
                UpdateButtonSpellID(buttonName)
                local button = _G[buttonName]
                if button and button.action then AddButtonToSlot(buttonName, button.action) end
            end
        end
        OverrideBindingByButton = {}
        for slot = 1, 180 do
            local buttonName = "BT4Button" .. slot
            OverrideBindingByButton[buttonName] = ("CLICK %s%s:Keybind"):format("BT4Button", slot)
        end
        if LAB then LAB.RegisterCallback(ns, "OnButtonUpdate", OnActionChanged) end

    elseif HasElvUI then
        local LAB = LibStub("LibActionButton-1.0-ElvUI", true)
        local map = {
            { actionPrefix = "ACTIONBUTTON",          buttonPrefix = "ElvUI_Bar1Button",  start = 1,   last = 12  },
            { actionPrefix = "ACTIONBUTTON",          buttonPrefix = "ElvUI_Bar1Button",  start = 13,  last = 24  },
            { actionPrefix = "MULTIACTIONBAR3BUTTON", buttonPrefix = "ElvUI_Bar3Button",  start = 25,  last = 36  },
            { actionPrefix = "MULTIACTIONBAR4BUTTON", buttonPrefix = "ElvUI_Bar4Button",  start = 37,  last = 48  },
            { actionPrefix = "MULTIACTIONBAR2BUTTON", buttonPrefix = "ElvUI_Bar5Button",  start = 49,  last = 60  },
            { actionPrefix = "MULTIACTIONBAR1BUTTON", buttonPrefix = "ElvUI_Bar6Button",  start = 61,  last = 72  },
            { actionPrefix = "MULTIACTIONBAR5BUTTON", buttonPrefix = "ElvUI_Bar13Button", start = 145, last = 156 },
            { actionPrefix = "MULTIACTIONBAR6BUTTON", buttonPrefix = "ElvUI_Bar14Button", start = 157, last = 168 },
            { actionPrefix = "MULTIACTIONBAR7BUTTON", buttonPrefix = "ElvUI_Bar15Button", start = 169, last = 180 },
        }
        for _, info in ipairs(map) do
            for slot = info.start, info.last do
                local id = slot - info.start + 1
                local buttonName = info.buttonPrefix .. id
                BindingByButton[buttonName] = info.actionPrefix .. id
                UpdateButtonSpellID(buttonName)
                local button = _G[buttonName]
                if button and button.action then AddButtonToSlot(buttonName, button.action) end
            end
        end
        OverrideBindingByButton = {}
        local elvOverride = {
            { actionPrefix = "ELVUIBAR2BUTTON",  buttonPrefix = "ElvUI_Bar2Button",  start = 13, last = 24  },
            { actionPrefix = "ELVUIBAR7BUTTON",  buttonPrefix = "ElvUI_Bar7Button",  start = 73, last = 84  },
            { actionPrefix = "ELVUIBAR8BUTTON",  buttonPrefix = "ElvUI_Bar8Button",  start = 85, last = 96  },
            { actionPrefix = "ELVUIBAR9BUTTON",  buttonPrefix = "ElvUI_Bar9Button",  start = 97, last = 108 },
            { actionPrefix = "ELVUIBAR10BUTTON", buttonPrefix = "ElvUI_Bar10Button", start = 109,last = 120 },
        }
        for _, info in ipairs(elvOverride) do
            for slot = info.start, info.last do
                local id = slot - info.start + 1
                local buttonName = info.buttonPrefix .. id
                OverrideBindingByButton[buttonName] = info.actionPrefix .. id
            end
        end
        if LAB then LAB.RegisterCallback(ns, "OnButtonUpdate", OnActionChanged) end

    else
        -- Default Blizzard UI
        local map = {
            { actionPrefix = "ACTIONBUTTON",          buttonPrefix = "ActionButton",              start = 1,   last = 12  },
            { actionPrefix = "ACTIONBUTTON",          buttonPrefix = "ActionButton",              start = 13,  last = 24  },
            { actionPrefix = "MULTIACTIONBAR3BUTTON", buttonPrefix = "MultiBarRightButton",       start = 25,  last = 36  },
            { actionPrefix = "MULTIACTIONBAR4BUTTON", buttonPrefix = "MultiBarLeftButton",        start = 37,  last = 48  },
            { actionPrefix = "MULTIACTIONBAR2BUTTON", buttonPrefix = "MultiBarBottomRightButton", start = 49,  last = 60  },
            { actionPrefix = "MULTIACTIONBAR1BUTTON", buttonPrefix = "MultiBarBottomLeftButton",  start = 61,  last = 72  },
            { actionPrefix = "ACTIONBUTTON",          buttonPrefix = "ActionButton",              start = 73,  last = 84  },
            { actionPrefix = "ACTIONBUTTON",          buttonPrefix = "ActionButton",              start = 85,  last = 96  },
            { actionPrefix = "ACTIONBUTTON",          buttonPrefix = "ActionButton",              start = 97,  last = 108 },
            { actionPrefix = "ACTIONBUTTON",          buttonPrefix = "ActionButton",              start = 109, last = 120 },
            { actionPrefix = "ACTIONBUTTON",          buttonPrefix = "ActionButton",              start = 121, last = 132 },
            { actionPrefix = "MULTIACTIONBAR5BUTTON", buttonPrefix = "MultiBar5Button",           start = 145, last = 156 },
            { actionPrefix = "MULTIACTIONBAR6BUTTON", buttonPrefix = "MultiBar6Button",           start = 157, last = 168 },
            { actionPrefix = "MULTIACTIONBAR7BUTTON", buttonPrefix = "MultiBar7Button",           start = 169, last = 180 },
        }
        for _, info in ipairs(map) do
            for slot = info.start, info.last do
                local index = slot - info.start + 1
                local buttonName = info.buttonPrefix .. index
                BindingByButton[buttonName] = info.actionPrefix .. index
                AddButtonToSlot(buttonName, slot)
                UpdateButtonSpellID(buttonName)
            end
        end
        EventRegistry:RegisterCallback("ActionButton.OnActionChanged", OnActionChanged)
    end

    return not HasBartender and not HasDominos and not HasElvUI
end

---------------------------------------------------------------------------
-- Keybind lookup: spellID -> key
---------------------------------------------------------------------------

local function GetButtonsForSpellID(spellID)
    if not IsValidSpellID(spellID) then return end
    local baseSpellID = C_SpellBook.FindBaseSpellByID(spellID)
    local buttons = {}

    -- Fast path: cached SpellIDByButton
    for buttonName, buttonSpellID in pairs(SpellIDByButton) do
        if _G[buttonName] and buttonSpellID == baseSpellID then
            buttons[#buttons + 1] = buttonName
        end
    end

    -- Fallback: live check all known buttons (handles procs/overrides)
    if #buttons == 0 then
        for buttonName in pairs(BindingByButton) do
            local btn = _G[buttonName]
            if btn then
                local btnSpell = GetSpellIDFromButton(buttonName)
                if btnSpell and (btnSpell == spellID or C_SpellBook.FindBaseSpellByID(btnSpell) == baseSpellID) then
                    buttons[#buttons + 1] = buttonName
                    break
                end
            end
        end
    end

    return buttons
end

local function GetKeyBindForSpellID(spellID)
    if not IsValidSpellID(spellID) then return end
    local buttons = GetButtonsForSpellID(spellID)
    if not buttons then return end

    for _, buttonName in ipairs(buttons) do
        local buttonAction = BindingByButton[buttonName]
        local key = GetBindingKey(buttonAction)
        if not key and OverrideBindingByButton then
            buttonAction = OverrideBindingByButton[buttonName]
            if buttonAction then key = GetBindingKey(buttonAction) end
        end
        if key then
            local baseKey = key:match("%-(%w+)$") or key
            return baseKey:upper(), key
        end
    end
end

---------------------------------------------------------------------------
-- Audio ducking: temporarily reduce other sounds so the cue is heard
---------------------------------------------------------------------------

local lastSoundHandle = nil

local function PlayWithDuck(soundFile)
    -- Stop previous cue immediately so it doesn't block the new one
    if lastSoundHandle then
        StopSound(lastSoundHandle, 0)
        lastSoundHandle = nil
    end

    if duckRestoreTimer then
        duckRestoreTimer:Cancel()
        duckRestoreTimer = nil
    end

    local duckPct = db.duckPercent
    local channel = CHANNELS[db.soundChannelIndex] or "Dialog"

    if duckPct > 0 then
        if not originalVolumes then
            originalVolumes = {
                sfx      = tonumber(GetCVar("Sound_SFXVolume")) or 1,
                music    = tonumber(GetCVar("Sound_MusicVolume")) or 1,
                ambience = tonumber(GetCVar("Sound_AmbienceVolume")) or 1,
            }
        end
        local factor = 1 - (duckPct / 100)
        SetCVar("Sound_SFXVolume", originalVolumes.sfx * factor)
        SetCVar("Sound_MusicVolume", originalVolumes.music * factor)
        SetCVar("Sound_AmbienceVolume", originalVolumes.ambience * factor)
    end

    local willPlay, soundHandle = PlaySoundFile(soundFile, channel)
    if willPlay then
        lastSoundHandle = soundHandle
    end

    if duckPct > 0 then
        duckRestoreTimer = C_Timer.NewTimer(0.6, function()
            if originalVolumes then
                SetCVar("Sound_SFXVolume", originalVolumes.sfx)
                SetCVar("Sound_MusicVolume", originalVolumes.music)
                SetCVar("Sound_AmbienceVolume", originalVolumes.ambience)
                originalVolumes = nil
            end
            duckRestoreTimer = nil
        end)
    end
end

---------------------------------------------------------------------------
-- Visibility check
---------------------------------------------------------------------------

local function ShouldBeActive()
    if not db or not db.enabled then return false end

    if db.hideInVehicle and UnitInVehicle("player") then return false end
    if db.hideAsHealer and UnitGroupRolesAssigned("player") == "HEALER" then return false end
    if db.hideOnMount and IsMountedLocal() then return false end

    local mode = db.displayMode
    if mode == 1 then return true end
    if mode == 2 then return InCombatLockdown() end
    if mode == 3 then return UnitCanAttack("player", "target") end
    if mode == 4 then return InCombatLockdown() or UnitCanAttack("player", "target") end
    return true
end

---------------------------------------------------------------------------
-- Core: announce
---------------------------------------------------------------------------

local function GetSpellName(spellID)
    if not spellID then return "nil" end
    local info = C_Spell.GetSpellInfo(spellID)
    return info and info.name or tostring(spellID)
end

local function DebugLog(msg)
    if debugMode then print(PREFIX .. "|cff888888" .. msg .. "|r") end
end

local spellKeyCache = {}

local function AnnounceSpell(spellID, forceRepeat)
    if not spellID then return end

    local baseKey, fullKey = GetKeyBindForSpellID(spellID)
    if not baseKey then
        baseKey = spellKeyCache[spellID]
    end
    if not baseKey then
        DebugLog("NO_KEY: " .. GetSpellName(spellID) .. " (id:" .. spellID .. ") -> retry 0.15s")
        C_Timer.After(0.15, function()
            local key = GetKeyBindForSpellID(spellID)
            if key then
                spellKeyCache[spellID] = key
                DebugLog("|cff00ff00RETRY_OK|r: " .. GetSpellName(spellID) .. " -> " .. key .. " (cached)")
                if currentSpellID == spellID then
                    AnnounceSpell(spellID)
                end
            else
                DebugLog("RETRY_FAIL: " .. GetSpellName(spellID) .. " still not found")
            end
        end)
        return
    end

    spellKeyCache[spellID] = baseKey

    local soundFile = KEY_TO_FILE[baseKey]
    if not soundFile then
        DebugLog("NO_FILE: key " .. baseKey .. " has no sound file")
        return
    end

    local now = GetTime()
    if (now - lastAnnouncedTime) < 0.1 then
        DebugLog("DEBOUNCE: " .. baseKey .. " blocked (" .. format("%.2f", now - lastAnnouncedTime) .. "s since last)")
        return
    end

    DebugLog("|cff00ff00PLAY|r: " .. baseKey .. " (" .. GetSpellName(spellID) .. " id:" .. spellID .. ")")
    PlayWithDuck(ADDON_PATH .. soundFile)
    lastAnnouncedSpellID = spellID
    lastAnnouncedTime = now
end

---------------------------------------------------------------------------
-- Ticker
---------------------------------------------------------------------------

local function Tick()
    if not ShouldBeActive() then
        if debugMode and currentSpellID then DebugLog("INACTIVE: ShouldBeActive=false") end
        currentSpellID = nil

        return
    end

    local nextSpell = C_AssistedCombat.GetNextCastSpell(isDefaultUI)
    if not IsValidSpellID(nextSpell) then
        if debugMode and currentSpellID then DebugLog("NO_SPELL: API returned nothing valid") end
        currentSpellID = nil

        return
    end

    local now = GetTime()

    -- Grace period: block ALL announcements after cast/channel start
    if castGraceUntil > 0 then
        if now >= castGraceUntil then
            -- Grace expired: always announce (player just cast, needs next instruction)
            castGraceUntil = 0
            currentSpellID = nextSpell
            DebugLog("GRACE_END: announce " .. GetSpellName(nextSpell) .. " (id:" .. nextSpell .. ")")
            AnnounceSpell(nextSpell)
            return
        else
            DebugLog("GRACE: blocked " .. GetSpellName(nextSpell) .. " (" .. format("%.1f", castGraceUntil - now) .. "s left)")
            return
        end
    end

    -- Normal path: only announce if base spell changed (prevents re-announce from ID flickering)
    local nextBase = C_SpellBook.FindBaseSpellByID(nextSpell) or nextSpell
    local currentBase = currentSpellID and (C_SpellBook.FindBaseSpellByID(currentSpellID) or currentSpellID)
    if nextBase ~= currentBase then
        currentSpellID = nextSpell
        AnnounceSpell(nextSpell)
    end
end

local function StartTicker()
    if ticker then return end
    ticker = C_Timer.NewTicker(updateInterval, Tick)
end

local function StopTicker()
    if not ticker then return end
    ticker:Cancel()
    ticker = nil
    currentSpellID = nil
    lastAnnouncedSpellID = nil
    castGraceUntil = 0
end

---------------------------------------------------------------------------
-- Settings Panel (native WoW Settings API)
---------------------------------------------------------------------------

local function CreateSettingsPanel()
    local category, layout = Settings.RegisterVerticalLayoutCategory("Assisted Combat Audio")

    ---- Section: General ----
    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Général"))

    do
        local setting = Settings.RegisterAddOnSetting(category, addonName .. "Enabled", "enabled", AssistedCombatAudioDB, Settings.VarType.Boolean, defaults.enabled)
        setting:SetValueChangedCallback(function(_, val)
            if val then StartTicker() else StopTicker() end
        end)
        Settings.CreateCheckbox(category, setting, "Activer ou désactiver les annonces audio.")
    end

    ---- Section: Son ----
    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Son"))

    do
        local function GetChannelOptions()
            local container = Settings.CreateControlTextContainer()
            container:Add(1, "Master - Volume Principale")
            container:Add(2, "SFX - Effets Sonores")
            container:Add(3, "Dialog - Dialogue (recommandé)")
            return container:GetData()
        end
        local setting = Settings.RegisterAddOnSetting(category, addonName .. "Channel", "soundChannelIndex", AssistedCombatAudioDB, Settings.VarType.Number, defaults.soundChannelIndex)
        Settings.CreateDropdown(category, setting, GetChannelOptions, "Canal audio pour les annonces.\n|cffffd100Dialog|r est recommandé : tu peux monter le volume Dialogue indépendamment dans les options Son de WoW.")
    end

    do
        local setting = Settings.RegisterAddOnSetting(category, addonName .. "Duck", "duckPercent", AssistedCombatAudioDB, Settings.VarType.Number, defaults.duckPercent)
        local options = Settings.CreateSliderOptions(0, 100, 5)
        options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(val) return val .. "%" end)
        Settings.CreateSlider(category, setting, options, "Réduit temporairement le volume des SFX, musique et ambiance quand une annonce joue.\n0% = pas de réduction, 100% = silence total des autres sons.")
    end

    ---- Section: Quand jouer ----
    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Quand jouer"))

    do
        local function GetDisplayOptions()
            local container = Settings.CreateControlTextContainer()
            container:Add(1, "Toujours")
            container:Add(2, "En combat uniquement")
            container:Add(3, "Avec cible hostile uniquement")
            container:Add(4, "En combat OU cible hostile")
            return container:GetData()
        end
        local setting = Settings.RegisterAddOnSetting(category, addonName .. "DisplayMode", "displayMode", AssistedCombatAudioDB, Settings.VarType.Number, defaults.displayMode)
        setting:SetValueChangedCallback(function()
            currentSpellID = nil
            lastAnnouncedSpellID = nil
        end)
        Settings.CreateDropdown(category, setting, GetDisplayOptions, "Quand les annonces audio sont actives.")
    end

    ---- Section: Couper quand ----
    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Couper quand"))

    do
        local setting = Settings.RegisterAddOnSetting(category, addonName .. "Mount", "hideOnMount", AssistedCombatAudioDB, Settings.VarType.Boolean, defaults.hideOnMount)
        Settings.CreateCheckbox(category, setting, "Couper les annonces sur une monture.")
    end

    do
        local setting = Settings.RegisterAddOnSetting(category, addonName .. "Vehicle", "hideInVehicle", AssistedCombatAudioDB, Settings.VarType.Boolean, defaults.hideInVehicle)
        Settings.CreateCheckbox(category, setting, "Couper les annonces en véhicule ou en pet battle.")
    end

    do
        local setting = Settings.RegisterAddOnSetting(category, addonName .. "Healer", "hideAsHealer", AssistedCombatAudioDB, Settings.VarType.Boolean, defaults.hideAsHealer)
        Settings.CreateCheckbox(category, setting, "Couper les annonces quand tu es heal en groupe.")
    end

    Settings.RegisterAddOnCategory(category)
    ns.settingsCategory = category
end

---------------------------------------------------------------------------
-- DB migration (from v1 nested format to v2 flat format)
---------------------------------------------------------------------------

local function MigrateDB()
    -- Migrate from old nested display table
    if AssistedCombatAudioDB.display then
        local d = AssistedCombatAudioDB.display
        if d.ALWAYS then
            AssistedCombatAudioDB.displayMode = 1
        elseif d.IN_COMBAT and d.HOSTILE_TARGET then
            AssistedCombatAudioDB.displayMode = 4
        elseif d.IN_COMBAT then
            AssistedCombatAudioDB.displayMode = 2
        elseif d.HOSTILE_TARGET then
            AssistedCombatAudioDB.displayMode = 3
        end
        AssistedCombatAudioDB.hideOnMount = d.HideOnMount or false
        AssistedCombatAudioDB.hideInVehicle = d.HideInVehicle or false
        AssistedCombatAudioDB.hideAsHealer = d.HideAsHealer or false
        AssistedCombatAudioDB.display = nil
    end

    -- Migrate from string channel to index
    if type(AssistedCombatAudioDB.soundChannel) == "string" then
        local channelMap = { Master = 1, SFX = 2, Dialog = 3 }
        AssistedCombatAudioDB.soundChannelIndex = channelMap[AssistedCombatAudioDB.soundChannel] or 3
        AssistedCombatAudioDB.soundChannel = nil
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("SPELLS_CHANGED")
frame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
frame:RegisterEvent("ACTIONBAR_UPDATE_STATE")
frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
frame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
frame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= addonName then return end

        AssistedCombatAudioDB = AssistedCombatAudioDB or {}
        MigrateDB()
        ApplyDefaults(AssistedCombatAudioDB, defaults)
        db = AssistedCombatAudioDB

        local cvarRate = tonumber(C_CVar.GetCVar("assistedCombatIconUpdateRate"))
        if cvarRate then updateInterval = cvarRate end

        CreateSettingsPanel()
        self:UnregisterEvent("ADDON_LOADED")

    elseif event == "PLAYER_LOGIN" then
        LoadRotationalSpells()
        isDefaultUI = LoadActionSlotMap()
        if db.enabled then StartTicker() end
        print(PREFIX .. "Loaded. |cff00ff00/aca|r = options, ou Échap > Options > AddOns.")

    elseif event == "SPELLS_CHANGED" then
        OnSpellsChanged()

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        LoadRotationalSpells()

    elseif event == "ACTIONBAR_SLOT_CHANGED" then
        OnActionSlotChanged(...)

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, castGUID, spellID = ...
        if unit == "player" and currentSpellID then
            local castBase = spellID and C_SpellBook.FindBaseSpellByID(spellID)
            local currentBase = C_SpellBook.FindBaseSpellByID(currentSpellID)
            if spellID == currentSpellID or castBase == currentBase then
                castGraceUntil = GetTime() + 0.2
            end
        end

    elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
        local unit = ...
        if unit == "player" then
            local _, _, _, startTimeMS, endTimeMS = UnitChannelInfo("player")
            if startTimeMS and endTimeMS then
                local duration = (endTimeMS - startTimeMS) / 1000
                if duration > 2 then
                    castGraceUntil = GetTime() + duration * (1 / 3)
                end
            end
        end

    elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        local unit = ...
        if unit == "player" then
            castGraceUntil = GetTime() + 0.2
        end

    elseif event == "ACTIONBAR_UPDATE_STATE" then
        -- Catches proc changes on action buttons (e.g. E key changing spell)
        UpdateAllButtonsSpellID()

    end
end)

---------------------------------------------------------------------------
-- Slash commands: /aca
---------------------------------------------------------------------------

SLASH_ASSISTEDCOMBATAUDIO1 = "/aca"
SlashCmdList["ASSISTEDCOMBATAUDIO"] = function(msg)
    if not db then return end
    msg = msg:lower():trim()

    if msg == "" or msg == "options" or msg == "config" then
        Settings.OpenToCategory(ns.settingsCategory:GetID())

    elseif msg == "on" then
        db.enabled = true
        StartTicker()
        print(PREFIX .. "Enabled.")

    elseif msg == "off" then
        db.enabled = false
        StopTicker()
        print(PREFIX .. "Disabled.")

    elseif msg == "test" then
        print(PREFIX .. "Testing all sounds...")
        local delay = 0
        for _, k in ipairs(SUPPORTED_KEYS) do
            C_Timer.After(delay, function()
                PlayWithDuck(ADDON_PATH .. KEY_TO_FILE[k])
            end)
            delay = delay + 0.8
        end

    elseif msg == "status" then
        print(PREFIX .. "Status:")
        print("  Enabled: " .. (db.enabled and "|cff00ff00YES|r" or "|cffff0000NO|r"))
        print("  Channel: " .. (CHANNELS[db.soundChannelIndex] or "?"))
        print("  Duck: " .. db.duckPercent .. "%")
        print("  Mode: " .. (DISPLAY_MODES[db.displayMode] or "?"))
        print("  Hide mount/vehicle/healer: " ..
            (db.hideOnMount and "mount " or "") ..
            (db.hideInVehicle and "vehicle " or "") ..
            (db.hideAsHealer and "healer " or ""))
        if currentSpellID and IsValidSpellID(currentSpellID) then
            local info = C_Spell.GetSpellInfo(currentSpellID)
            local baseKey = GetKeyBindForSpellID(currentSpellID)
            print("  Spell: " .. (info and info.name or "?") .. " -> " .. (baseKey or "?"))
        end

    elseif msg == "debug" then
        debugMode = not debugMode
        print(PREFIX .. "Debug: " .. (debugMode and "|cff00ff00ON|r" or "|cffff0000OFF|r"))

    else
        print(PREFIX .. "Commands:")
        print("  /aca - Open settings panel")
        print("  /aca on|off - Enable/disable")
        print("  /aca test - Play all sounds")
        print("  /aca status - Show current state")
        print("  /aca debug - Toggle debug logging")
    end
end
