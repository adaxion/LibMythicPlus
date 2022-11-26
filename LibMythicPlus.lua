--- A developer library to facilitate writing addons for M+
-- This library provides a normalized, consistent API for retrieving information about keystones, M+ season data, 
-- and access to rich-data events that happen within a M+ challenge. If you've never worked with Blizzard's M+ 
-- API before there are several nuances and challenges to working with it. In addition, most of the functionality
-- you'd want when writing a M+ addon requires working with multiple APIs; and that's just to get the data about 
-- the M+ and keystone, let alone unit data. This library aims to solve all those problems with 1 API that easily 
-- provides M+ data without having to worry about the nuances of Blizzard's Addon API.
--
-- Author: Adaxion
-- Version: 0.1.0
--
-- Architecture
-- ===============================================================================================================
-- 
-- Retrieving seasonal M+ data from Blizzard's API can be fairly esoteric and difficult to work with. Calls like 
-- C_MythicPlus.GetCurrentAffixes(), and others, require calling other methods to request that data, and in some 
-- cases, responding to events invoked later by Blizzard. All of this means that seasonal M+ data is not available
-- _immediately_ upon your addon, or LibMythicPlus, being initialized. Generally, in testing this data is ready 
-- within a couple seconds of LibMythicPlus initializing but the gap is there. IT can be significant enough to 
-- cause errors if you attempt to use LibMythicPlus in your addon's initialization code before that seasonal 
-- data is ready. Since that seasonal data is used to provide rich, complete information about keystones and active
-- M+ challenges there is a small window where addon's are initialized but LibMythicPlus is not yet ready to be 
-- used.
--
-- To handle this gap between addon initialization and you being able to use LibMythicPlus the addon is split into 
-- two distinct parts. The first is LibMythicPlus itself which provides a limited set of properties and functions 
-- that you can call. It primarily provides an entrypoint called LibMythicPlus:OnApiReady. You can provide that 
-- function a callback that will be passed a single argument. The second part of the architecture is the argument 
-- passsed to that OnApiReady callback; we call it `Api`. the Api is what provides the vast majority of actual 
-- functionality including retrieving keystones, registering for events, and normalized wrappers over Blizzard's
-- C_MythicPlus and C_ChallengeMode APIs. For more information about this aspect of the lib please checkout the 
-- documentation for LibMythicPlus:OnApiReady function below.
-- 
-- A quick tl;dr example in case you can't be bothered to read documentation
--
-- LibMythicPlus:OnApiReady(function(api)
--     if api == nil then
--         -- there is no m+ season active
--     else
--         -- call methods, access properties, listen to events
--     end
-- end)
--
-- Properties
-- ===============================================================================================================
-- 
-- Properties on LibMythicPlus
-- * Version (string) - The installed version of LibMythicPlus
-- * CommPrefix (string) - The prefix used by LibMythicPlus for inter-addon communication
-- * DebugMode (bool) - Defaults to false. Mark true to cause LibMythicPlus to output details on what it is doing
-- * DebugHandler (function(string)) - Do something what debug messages when DebugMode has been set to true. If not
--                                     set explicitly this will default to using LibMythicPlus:Print
--
-- Properties on LibMythicPlusAPI
-- * currentSeason = {
--
--   }
--
-- Methods
-- ===============================================================================================================
--
-- Methods on LibMythicPlus
--
-- Methods on LibMythicPlusAPI
-- 
-- Events
-- ===============================================================================================================
--
-- Types
-- ===============================================================================================================
--
-- Keystone
-- {
--     level = int,
--     mapId = challengeMapID,
--     mapName = string,
--     affixes = list<Affix>,
--     seasonId = int,
--     timeLimit = int
-- }
--
-- Affix
-- {
--     id = int,
--     name = string,
--     description = string,
--     fileDataId = number
-- }
-- 
-- PartyMember
-- {
--     id = unitGUID,
--     name = string,
--     realm = string,
--     class = string,
--     role = string,
--     guild = string
-- }
-- 
-- MythicPlusChallenge
-- 
-- 
--

-- Addon Declaration
-- ===============================================================================================================
local AceComm = LibStub("AceComm-3.0")
local AceEvent = LibStub("AceEvent-3.0")
local AceSerializer = LibStub("AceSerializer-3.0")
LibMythicPlus = LibStub("AceAddon-3.0"):NewAddon(
    "LibMythicPlus",
    "AceConsole-3.0"
)

-- ReadOnly Properties
-- ===============================================================================================================

LibMythicPlus.Version = "0.1.0"
LibMythicPlus.CommPrefix = "LibMythicPlus"

-- Mutable Properties
-- ===============================================================================================================

-- Flip this to true to cause LibMythicPlus to output detailed information about what it is doing.
LibMythicPlus.DebugMode = false
-- Set this to a function that accepts a single, string parameter that holds debug output messages
LibMythicPlus.DebugHandler = function(msg) LibMythicPlus:Print(msg) end

--- LibMythicPlusAPI
local Api = {
    -- Information about the currently active season
    currentSeason = {
        id = nil,
        description = nil,
        affixes = nil,
        maps = nil
    }
}

-- Event listeners for LibMythicPlus internal events; each key in the table corresponds to a method on the Api
local EventListeners = {
    OnApiReady = {},
    OnKeystoneSlotted = {},
    OnMythicPlusChallengeStarted = {},
    OnMythicPlusChallengeCompleted = {},
    OnMythicPlusChallengeAbandoned = {},
    OnInstanceLeftWhileMythicPlusChallengeStillActive = {},
    OnInstanceReenteredWhileMythicPlusChallengeStillActive = {},
    OnDeathDuringMythicPlusChallenge = {}
}

-- Blizzard invoked events that LibMythicPlus responds to
local BlizzardEvents = {
    KeystoneSlotted = "CHALLENGE_MODE_KEYSTONE_SLOTTED",
    ChallengeStarted = "CHALLENGE_MODE_START",
    ChallengeCompleted = "CHALLENGE_MODE_COMPLETED",
    CurrentAffixUpdated = "MYTHIC_PLUS_CURRENT_AFFIX_UPDATE",
    SystemChatMessage = "CHAT_MSG_SYSTEM",
    PlayerEnteringWorld = "PLAYER_ENTERING_WORLD",
    ChallengeDeath = "CHALLENGE_MODE_DEATH_COUNT_UPDATED"
}

--- Events that are triggered via inter-addon communication
local CommEvents = {
    InstanceReset = "LibMythicPlus.InstanceReset"
}

local CommDistribution = {
    Party = "PARTY"
}

local SeasonalLoadAttempts = {
    Id = 0,
    Affixes = 0,
    Maps = 0
}

-- The AceDB that manages our persistent storage. This is not attached to LibMythicPlus or Api proper because 
-- we want to restrict what other addons can do to this data. If you want to manipulate the store you should 
-- do so with the functions provided by the Api. If you need to manipulate the Store in some way that the 
-- Api does not provide, and you have a valid use case, please submit an issue to the addon's repo.
local Store = nil

-- Private functions
-- ===============================================================================================================

--- Will output the passed msg if LibMythicPlus is in debug mode
--
-- @param msg string
-- @return nil
local function DebugPrint(msg)
    if LibMythicPlus.DebugMode then
        LibMythicPlus.DebugHandler(msg)
    end
end

--- Invoke all of the listeners in store, passing in any ... arguments provided
--
-- @param store list<function>
-- @param ... mixed
-- @return nil
local function InvokeListeners(store, ...)
    for _, listener in ipairs(store) do
        listener(...)
    end
end

--- Removes the listener from the provided store
--
-- @param store list<function>
-- @param listener function
-- @return nil
local function RemoveListener(store, listener)
    for index, storedListener in pairs(store) do
        if listener == storedListener then
            tremove(store, index)
        end
    end
end

--- Invoke listeners in the given store and then immediately remove them
-- This function is useful for events that are intended to be one-time, such as OnApiReady, and we don't want to keep 
-- references to potentially many functions that will never get called again.
--
-- @param store list<function>
-- @param ... mixed
-- @return nil
local function InvokeAndRemoveListeners(store, ...)
    for _, listener in ipairs(store) do
        listener(...)
        RemoveListener(store, listener)
    end
end

--- Retrieves the current season ID and persists it in Store.
-- Sometimes C_MythicPlus.GetCurrentSeason() will return a -1 value as it waits for data to become available from Blizzard.
-- In those instances, this method will recursively attempt to load the data again in 1 second.
-- 
-- NOTE! C_MythicPlus.RequestMapInfo() MUST have been called before calling this method. If you call this method and have 
-- not requested map info nor will you request map info you could find this method recursing forever and, potentially more 
-- importantly, the lib's OnApiReady method will never be called.
--
-- @return nil
local function LoadSeasonId()
    if Api.currentSeason.id ~= nil then
        return
    end

    local currentSeasonId = C_MythicPlus.GetCurrentSeason()
    SeasonalLoadAttempts.Id = SeasonalLoadAttempts.Id + 1
    DebugPrint("Attempting to load the current season. Received " .. currentSeasonId)
    if currentSeasonId < 0 then
        if SeasonalLoadAttempts.Id > 10 then
            DebugPrint("We encountered what appears to be an infinite loop trying to retrieve season ID. Going to request data from Blizzard again.")
            LoadSeasonData()
        else
            DebugPrint("Received an invalid season value, will try again in 1 second.")
            C_Timer.After(1, LoadSeasonId)
        end
        
    else
        Api.currentSeason.id = currentSeasonId
        DebugPrint("Successfully loaded the current season into Api.currentSeason.id!")
    end
end

--- Retrieves the current season affixes, along with their details, and persists it in Store.
-- Sometimes C_MythicPlus.GetCurrentAffixes() will return nil as it waits for data to become available from Blizzard.
-- In those instances, this method will recursively attempt to load the data again in 1 second.
-- 
-- NOTE! C_MythicPlus.RequestMapInfo() AND C_MythicPlus.RequestCurrentAffixes() MUST have been called before calling 
-- this method. While you may think because of the name that just RequestCurrentAffixes() would be enough but you'd be 
-- wrong. If you call this method and have not requested info nor will you request info you could find this method
-- recursing forever and, potentially more importantly, the lib's OnApiReady method will never be called.
--
-- @return nil
local function LoadSeasonAffixes()
    -- The event that triggers this could get invoked many times, including by calls from other addons
    -- If we've already stored affix information for the current season then we don't really need to do 
    -- anything else and we can effectively skip over any processing of affixes.
    if Api.currentSeason.affixes ~= nil then
        return
    end

    local affixIds = C_MythicPlus.GetCurrentAffixes()
    SeasonalLoadAttempts.Affixes = SeasonalLoadAttempts.Affixes + 1
    DebugPrint("Attempting to load affixes for the current season.")
    if affixIds then
        local affixes = {}
        for _, affixInfo in ipairs(affixIds) do
            local name, description, fileId = C_ChallengeMode.GetAffixInfo(affixInfo.id)
            tinsert(affixes, {
                id = affixInfo.id,
                seasonId = affixInfo.seasonID,
                name = name,
                description = description,
                fileDataId = fileId
            })
        end
        Api.currentSeason.affixes = affixes
        DebugPrint("Successfully loaded the current season's affixes into Api.currentSeason.affixes!")
    else
        if SeasonalLoadAttempts.Affixes > 10 then
            DebugPrint("We encountered what appears to be an infinite loop trying to retrieve season affixes. Going to request data from Blizzard again.")
            LoadSeasonData()
        else
            DebugPrint("Received an invalid affix value, will try again in 1 second.")
            C_Timer.After(1, LoadSeasonAffixes)
        end
        
        
    end
end

--- Retrieves all of the map details for what's available in the current season.
-- Sometimes C_MythicPlus.GetMapUIInfo() will return a nil value as it waits for data to become available from Blizzard.
-- In those instances, this method will recursively attempt to load the data again in 1 second.
-- 
-- NOTE! C_MythicPlus.RequestMapInfo() MUST have been called before calling this method. If you call this method and have 
-- not requested map info nor will you request map info you could find this method recursing forever and, potentially more 
-- importantly, the lib's OnApiReady method will never be called.
--
-- @return nil
local function LoadSeasonMaps()
    if Api.currentSeason.maps ~= nil then
        return
    end

    local mapIds = C_ChallengeMode.GetMapTable()
    SeasonalLoadAttempts.Maps = SeasonalLoadAttempts.Maps + 1
    DebugPrint("Attempting to load the available maps for the current season.")
    if mapIds then
        local maps = {}
        for _, mapId in ipairs(mapIds) do
            DebugPrint("Loading detailed information for challengeMapID " .. mapId)
            local name, _, timeLimit, texture, backgroundTexture = C_ChallengeMode.GetMapUIInfo(mapId)
            maps[mapId] = {
                id = mapId,
                name = name,
                timeLimit = timeLimit,
                texture = texture,
                backgroundTexture = backgroundTexture
            }
        end
        Api.currentSeason.maps = maps
        DebugPrint("Successfully loaded the current season's maps into Api.currentSeason.maps")
    else
        if SeasonalLoadAttempts.Maps > 10 then
            DebugPrint("We encountered what appears to be an infinite loop trying to retrieve season map info. Going to request data from Blizzard again.")
            LoadSeasonData()
        else 
            DebugPrint("Received an invalid maps value, will try again in 1 second.")
            C_Timer.After(1, LoadSeasonMaps)
        end
        
    end
end

--- Recursively checks if LibMythicPlus is ready and, when it is, will invoke and remove OnApiReady listeners.
--
-- @return nil
local function TriggerIsReadyEvent()
    if LibMythicPlus:IsReady() then
        DebugPrint("All information is available! Invoking the OnApiReady event and immediately removing lsiteners.")
        InvokeAndRemoveListeners(EventListeners.OnApiReady, Api)
    else
        DebugPrint("Information is not available. Will check again in 1 second.")
        C_Timer.After(1, TriggerIsReadyEvent)
    end
end

--- Requests seasonal M+ information from Blizzard and starts processes designed to capture that data
--
-- @return nil
local function LoadSeasonData()
    C_MythicPlus.RequestMapInfo()
    C_MythicPlus.RequestCurrentAffixes()
    DebugPrint("Requested seasonal M+ data from Blizzard.")

    -- You might expect to see LoadSeasonAffixes here but that should be triggered after receipt of a Blizzard-invoked event and is called 
    -- in the corresponding event handler. Do NOT attempt to LoadSeasonAffixes here!
    LoadSeasonId()
    LoadSeasonMaps()
end

--- Return a table of normalized information about a given unit
-- This function is designed to work with player and party units. Hostile units or NPC units may not be handled by this function correctly.
--
-- @return PartyMember
local function GetUnitInfo(unit)
    DebugPrint("Retrieving information for unit " .. unit)
    local name, realm = UnitName(unit)
    if name == nil then
        DebugPrint("No information was found for the given unit.")
        return nil 
    end
    if realm == nil then
        realm = GetRealmName()
    end
    DebugPrint("Successfully retrieved information for unit " .. unit)
    
    return {
        id = UnitGUID(unit),
        name = name,
        realm = realm,
        class = UnitClass(unit),
        role = UnitGroupRolesAssigned(unit),
        guild = GetGuildInfo(unit)
    }
end

--- Marks the currently active challenge as abandoned for the specified reason.
-- Calling this method will cause OnMythicPlusChallengeAbandoned event listeners to be invoked.
-- 
-- @param reason string
-- @return nil
local function AbandonMythicPlusChallenge(reason)
    assert(Store.char.activeChallenge ~= nil, "Attempted to abandon a MythicPlusChallenge while there is no Store.char.activeChallenge present.")
    DebugPrint("Abandoned current M+ Challenge because " .. reason)
    Store.char.activeChallenge.result = -1
    Store.char.activeChallenge.reason = reason
    Store.char.activeChallenge.isCompleted = false
    Store.char.activeChallenge.finishedAt = GetServerTime()
    local challenge = Store.char.activeChallenge
    Store.char.activeChallenge = nil
    InvokeListeners(EventListeners.OnMythicPlusChallengeAbandoned, challenge)
end

--- An event handler that checks if the player has reset all instances
-- If this method finds that the party leader has reset instances an inter-addon event, CommEvents.InstanceReset, will be triggered.
--
-- @param msg string
-- @return nil
local function CheckForInstanceReset(_, msg)
    local instanceResetSuccessRegex = string.gsub(INSTANCE_RESET_SUCCESS, "%%s", ".+")
    if string.match(msg, instanceResetSuccessRegex) then
        -- It is a completely valid use case to reset instances and there be no active challenge, if so return early and don't try to abandon 
        -- a M+ Challenge that doesn't exist.
        if Store.char.activeChallenge == nil then
            return
        end

        -- We need to let other members in the party that might be using this addon know that the leader reset the instance
        -- This chat message only shows up for the party leader, if we don't let other addon members know that the instance was reset (effectively ending the run)
        -- they'll still keep a value present in `activeChallenge` and the addon will believe that a M+ is in progress when really it failed.
        AbandonMythicPlusChallenge("InstanceReset")
        local payload = {event = CommEvents.InstanceReset}
        AceComm:SendCommMessage(LibMythicPlus.CommPrefix, AceSerializer:Serialize(payload), CommDistribution.Party)
    end
end

--- An event handler that checks if the player has left the current group, effectively abandoning the M+ Challenge
-- 
-- @return nil
local function CheckForPlayerLeftGroup()
    if Api:IsChallengeModeActive() and not IsInGroup() then
        AbandonMythicPlusChallenge("LeftGroup")
    end
end

local function CheckForPlayerZonedOutOfActiveMythicPlusChallenge(_, isLogin, isReload)
    -- We don't care about initial loading or reloading, we want to know when you zone between different maps
    if isLogin or isReload then
        -- We SHOULD care about these states. If a user logs out of an active m+ challenge and logs back in the library would not update appropriate event listeners that a challenge is active
        -- The same problem exists for when a user reloads their UI
        return
    end
    if Api:IsMythicPlusChallengeActive() and not C_ChallengeMode.IsChallengeModeActive() then
        InvokeListeners(EventListeners.OnInstanceLeftWhileMythicPlusChallengeStillActive, Store.char.activeChallenge)
    end
end

--- An event handler that will start a M+ Challenge and invoke listeners that want to know when a M+ Challenge started.
-- Calling this function will invoke the OnMythicPlusChallengeStarted listeners.
--
-- @return nil
local function StartMythicPlusChallenge()
    local GetActiveKeystone = function()
        DebugPrint("Retrieving keystone information for the active M+ Challenge.")
        local keystoneLevel = C_ChallengeMode.GetActiveKeystoneInfo()
        local keystoneMapId = C_ChallengeMode.GetActiveChallengeMapID()
        
        assert(keystoneLevel ~= nil, "Expected there to be an active keystone level but there is not one.")
        assert(keystoneMapId ~= nil, "Expected there to be an active keystone map ID but there is not one.")

        local mapInfo = Api.currentSeason.maps[keystoneMapId]

        assert(mapInfo ~= nil, "Expected to have retrieved information for the active keystone's challenge map but nothing was found for the ID " .. keystoneMapId)

        DebugPrint("Found map details for the active M+ Challenge.")
        return {
            level = keystoneLevel,
            mapId = keystoneMapId,
            mapName = mapInfo.name,
            affixes = Api:GetSeasonAffixesForKeystoneLevel(keystoneLevel),
            seasonId = Api.currentSeason.id,
            timeLimit = mapInfo.timeLimit
        }
    end

    local GetPartyMembers = function()
        DebugPrint("Retrieving party information for the active M+ Challenge.")
        local partyMembers = {}
        -- The partyN units exclude the player so make sure they get included in the party
        tinsert(partyMembers, GetUnitInfo("player"))
        for i = 1, 4, 1 do
            local unit = "party" .. i
            local unitInfo = GetUnitInfo(unit)

            if unitInfo then
                tinsert(partyMembers, unitInfo)
            end
        end

        return partyMembers
    end

    -- Did you know that if you zone out of an already started M+ and then back in the CHALLENGE_MODE_START event triggers again? Go figure!
    -- This ensures that if there's an active challenge already present we can trigger the correct event.
    -- TODO this could be made more future proof by doing a check against the active keystone and the activeChallenge. If the level, dungeon, or group members differ then we had an activeChallenge stored that never got cleared (this might be possible in a disconnect scenario)
    -- TODO when we improve the above check make sure we account for the fact that a group could decrease in size and still be active
    if Store.char.activeChallenge ~= nil then
        DebugPrint("Instance was re-entered while M+ Challenge was still active. Player likely zoned out and back in of dungeon instance.")
        InvokeListeners(EventListeners.OnInstanceReenteredWhileMythicPlusChallengeStillActive, Store.char.activeChallenge)
    else
        DebugPrint("M+ Challenge was started. Retrieving challenge information.")
        local activeChallenge = {
            startedAt = GetServerTime(),
            finishedAt = nil,
            party = GetPartyMembers(),
            keystone = GetActiveKeystone(),
            deaths = 0,
            timeLostToDeaths = 0
        }
        DebugPrint("Stored the active M+ Challenge details in Store.char.activeChallenge!")
        Store.char.activeChallenge = activeChallenge
        DebugPrint("Invoking OnMythicPlusChallengeStarted listeners.")
        InvokeListeners(EventListeners.OnMythicPlusChallengeStarted, Store.char.activeChallenge)
    end
end

local function CompleteMythicPlusChallenge()
    assert(Store.char.activeChallenge ~= nil, "An active challenge MUST be present to call CompleteMythicPlusChallenge but found nothing.")
    local _, _, completionTime, _, upgradeLevels = C_ChallengeMode.GetCompletionInfo()
    Store.char.activeChallenge.result = upgradeLevels
    Store.char.activeChallenge.isCompleted = true
    Store.char.activeChallenge.finishedAt = GetServerTime()
    Store.char.activeChallenge.timeTaken = completionTime
    local challenge = Store.char.activeChallenge
    Store.char.activeChallenge = nil
    InvokeListeners(EventListeners.OnMythicPlusChallengeCompleted, challenge)
end

local function HandleChallengeDeath()
    local numDeaths, timeLost = C_ChallengeMode.GetDeathCount()
    Store.char.activeChallenge.deaths = numDeaths
    Store.char.activeChallenge.timeLostToDeaths = timeLost
    InvokeListeners(EventListeners.OnDeathDuringMythicPlusChallenge, Store.char.activeChallenge)
end

--- LibMythicPlus handler for inter-addon communication events
--
-- @param payload serializedString
-- @param distribution string
-- @param sender string
local function CommHandler(_, payload, distribution, sender)
    payload = AceSerializer:Deserialize(payload)
    LibMythicPlus:Print(distribution)
    LibMythicPlus:Print(sender)
    DevTools_Dump(payload)
end

-- LibMythicPlus functions
-- ===============================================================================================================

--- 
function LibMythicPlus:OnInitialize()
    Store = LibStub("AceDB-3.0"):New("LibMythicPlusDB")

    -- TODO need to check if there's a season active, if not invoke the OnApiReady with nil
    DebugPrint("LibMythicPlus is intializing.")

    AceEvent:RegisterEvent(BlizzardEvents.KeystoneSlotted, function() InvokeListeners(EventListeners.OnKeystoneSlotted, Api:GetSlottedKeystone()) end)
    AceEvent:RegisterEvent(BlizzardEvents.CurrentAffixUpdated, LoadSeasonAffixes)
    AceEvent:RegisterEvent(BlizzardEvents.ChallengeStarted, StartMythicPlusChallenge)
    AceEvent:RegisterEvent(BlizzardEvents.ChallengeCompleted, CompleteMythicPlusChallenge)
    AceEvent:RegisterEvent(BlizzardEvents.SystemChatMessage, CheckForInstanceReset)
    AceEvent:RegisterEvent(BlizzardEvents.PlayerEnteringWorld, CheckForPlayerZonedOutOfActiveMythicPlusChallenge)
    AceEvent:RegisterEvent(BlizzardEvents.ChallengeDeath, HandleChallengeDeath)

    AceComm:RegisterComm(LibMythicPlus.CommPrefix, CommHandler)

    DebugPrint("All Blizzard events have had their listeners registered.")

    -- Why in the world would you be setting these to happen some arbitrary time in the future, Adaxion? Have you gone mad or are you a shit programmer?
    -- Well, my friend, once you have dived into the depths of Blizzard's API and been infested by the Old Gods that live in their code you too will 
    -- resort to drastic measures to vanquish your foes. You see, when a character first loads into the game there's a chance, even though we have 
    -- absolutely called the correct methods in LoadSeasonData that the seasonal M+ data we want still returns an invalid value and the addon 
    -- gets caught in an infinite loop waiting for data that never becomes available. Waiting a couple seconds after the addon initializes seems to 
    -- help ensure that the data becomes available. More complete testing may see this value needing to increase.
    C_Timer.After(2, LoadSeasonData)
    C_Timer.After(3, TriggerIsReadyEvent)
end

--- Determines whether the necessary seasonal data has been loaded and the Api is ready to be provided to consumers.
--
-- @return bool
function LibMythicPlus:IsReady()
    local hasCurrentSeason = Api.currentSeason.id ~= nil
    local hasCurrentAffixes = Api.currentSeason.affixes ~= nil
    local hasSeasonMaps = Api.currentSeason.maps ~= nil
    return hasCurrentSeason and hasCurrentAffixes and hasSeasonMaps
end

--- Register an event listener to be invoked when the LibMythicPlusAPI is ready for use.
--
-- @param listener function(LibMythicPlusAPI)
-- @return nil
function LibMythicPlus:OnApiReady(listener)
    if LibMythicPlus:IsReady() then
        DebugPrint("LibMythicPlus is already ready, invoking OnApiReady listener immediately.")
        listener(Api)
        return function() end
    else
        tinsert(EventListeners.OnApiReady, listener)
        DebugPrint("Registered OnApiReady listener.")
        return function()
            DebugPrint("Removed OnApiReady listener.")
            RemoveListener(EventListeners.OnApiReady, listener) 
        end
    end
end

if LibMythicPlus.DebugMode then
    function LibMythicPlus:DumpStore()
        DevTools_Dump(Store)
    end

    function LibMythicPlus:DumpApi()
        DevTools_Dump(Api)
    end
end

-- LibMythicPlusAPI functions
-- ===============================================================================================================

--- Determine the affixes that would be assigned to a keystone for a given keystoneLevel
-- There is no Blizzard API for retrieving the affixes that are actually on a keystone. In theory we could parse the keystone's
-- tooltip but that seems haphazard and error prone. Instead we do the math necessary to determine how many affixes get assigned 
-- based on the keystone level. This should be, in theory, future proof... even to potential changes to the user's tooltip 
-- (which may ultimately be altered by other addons) 
--
-- @param keystoneLevel int
-- @return list<Affix>
function Api:GetSeasonAffixesForKeystoneLevel(keystoneLevel)
    local affixes = self.currentSeason.affixes
    if keystoneLevel <= 3 then
        return {affixes[1]}
    elseif keystoneLevel <= 6 then
        return {affixes[1], affixes[2]}
    elseif keystoneLevel <= 9 then
        return {affixes[1], affixes[2], affixes[3]}
    else
        return affixes 
    end
end

--- Get the player's currently owned keystone or nil if they do not have one
--
-- @weturn Keystone|nil
function Api:GetOwnedKeystone()
    local mapId = C_MythicPlus.GetOwnedKeystoneChallengeMapID()
    if not mapId then
        return nil
    end

    local level = C_MythicPlus.GetOwnedKeystoneLevel()
    local mapInfo = self.currentSeason.maps[mapId]
    return {
        level = level,
        mapId = mapId,
        mapName = mapInfo.name,
        affixes = self:GetSeasonAffixesForKeystoneLevel(level),
        seasonId = self.currentSeason.id,
        timeLimit = mapInfo.timeLimit
    }
end

--- Returns the keystone that has been slotted into a challenge mode pedestal or nil if there is no slotted keystone
--
-- @return Keystone|nil
function Api:GetSlottedKeystone()
    if not C_ChallengeMode.HasSlottedKeystone() then
        return nil
    end

    local mapId, _, level = C_ChallengeMode.GetSlottedKeystoneInfo()
    local mapInfo = self.currentSeason.maps[mapId]

    return {
        level = level,
        mapId = mapId,
        mapName = mapInfo.name,
        affixes = self:GetSeasonAffixesForKeystoneLevel(level),
        seasonId = self.currentSeason.id,
        timieLimit = mapInfo.timeLimit
    }
end

--- Returns whether or not the addon believes a M+ Challenge is active.
-- Please note that this does NOT check for Blizzard's C_ChallengeMode.IsChallengeModeActive. This method returns false if 
-- the player has zoned out of the dungeon, even if a challenge is actually underway.
--
-- @return bool
function Api:IsMythicPlusChallengeActive()
    return Store.char.activeChallenge ~= nil
end

--- Returns whether or not the addon believe a M+ Challange is active AND the player is zoned into the dungeon
--
-- @return bool
function Api:IsMythicPlusChallengeActiveAndPlayerInDungeon()
    return Api:IsMythicPlusChallengeActive() and C_ChallengeMode.IsChallengeModeActive()
end

--- Returns the active M+ Challenge if one is present, or nil.
function Api:GetActiveMythicPlusChallenge()
    return Store.char.activeChallenge
end

--- Register an event listener that will be invoked when a keystone has been slotted into a challenge mode pedestal.
--
-- @param listener function(Keystone)
-- @return nil
function Api:OnKeystoneSlotted(listener)
    tinsert(EventListeners.OnKeystoneSlotted, listener)
    DebugPrint("Registered OnKeystoneSlotted listener.")
    return function() 
        DebugPrint("Removed OnKeystoneSlotted listener.")
        RemoveListener(EventListeners.OnKeystoneSlotted, listener) 
    end
end

--- Register an event listener that will be invoked when a M+ Challenge has started
--
-- @param listener function(MythicPlusChallenge)
-- @return nil
function Api:OnMythicPlusChallengeStarted(listener)
    tinsert(EventListeners.OnMythicPlusChallengeStarted, listener)
    DebugPrint("Registered OnMythicPlusChallengeStarted listener.")
    return function()
        DebugPrint("Removed OnMythicPlusChallengeStarted listener.")
        RemoveListener(EventListeners.OnMythicPlusChallengeStarted, listener) 
    end
end

--- Register an event listener that will be invoked when a M+ Challenge has completed
--
-- @param listener function(MythicPlusChallenge)
-- @return nil
function Api:OnMythicPlusChallengeCompleted(listener)
    tinsert(EventListeners.OnMythicPlusChallengeCompleted, listener)
    DebugPrint("Registered OnMythicPlusChallengeCompleted listener.")
    return function()
        DebugPrint("Removed OnMythicPlusChallengeCompleted listener.")
        RemoveListener(EventListeners.OnMythicPlusChallengeCompleted, listener) 
    end
end

--- Register an event listener that will be invoked when a M+ Challenge has been abandoned.
--
-- @param listener function(MythicPlusChallenge)
-- @return nil
function Api:OnMythicPlusChallengeAbandoned(listener)
    tinsert(EventListeners.OnMythicPlusChallengeAbandoned, listener)
    DebugPrint("Registered OnMythicPlusChallengeAbandoned listener.")
    return function()
        DebugPrint("Removed OnMythicPlusChallengeAbandoned listener.")
        RemoveListener(EventListeners.OnMythicPlusChallengeAbandoned, listener)
    end
end

--- Register an event listener that will be invoked when a player has zoned out of an active M+ Challenge.
--
-- @param listener function(MythicPlusChallenge)
-- @return nil
function Api:OnInstanceLeftWhileMythicPlusChallengeStillActive(listener)
    tinsert(EventListeners.OnInstanceLeftWhileMythicPlusChallengeStillActive, listener)
    DebugPrint("Registered OnInstanceLeftWhileMythicPlusChallengeStillActive listener.")
    return function()
        DebugPrint("Removed OnInstanceLeftWhileMythicPlusChallengeStillActive listener.")
        RemoveListener(EventListeners.OnInstanceLeftWhileMythicPlusChallengeStillActive, listener)
    end
end

--- Register an event listener when a player has zoned into an already active M+ Challenge.
-- 
-- @param listener function(MythicPlusChallenge)
-- @return nil
function Api:OnInstanceReenteredWhileMythicPlusChallengeStillActive(listener)
    tinsert(EventListeners.OnInstanceReenteredWhileMythicPlusChallengeStillActive, listener)
    DebugPrint("Registered OnInstanceReenteredWhileMythicPlusChallengeStillActive listener.")
    return function()
        DebugPrint("Removed OnInstanceReenteredWhileMythicPlusChallengeStillActive listener.")
        RemoveListener(EventListeners.OnInstanceReenteredWhileMythicPlusChallengeStillActive, listener)
    end
end

--- Register an event listener when the player or party member has died.
--
-- @param listener function(MythicPlusChallenge)
-- @return nil
function Api:OnDeathDuringMythicPlusChallenge(listener)
    tinsert(EventListeners.OnDeathDuringMythicPlusChallenge, listener)
    DebugPrint("Registered OnDeathDuringMythicPlusChallenge listener.")
    return function()
        DebugPrint("Removed OnDeathDuringMythicPlusChallenge listener.")
        RemoveListener(EventListeners.OnDeathDuringMythicPlusChallenge, listener)
    end
end
