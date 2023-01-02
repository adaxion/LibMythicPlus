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
-- within a couple seconds of LibMythicPlus initializing but the gap is there. It can be significant enough to
-- cause errors if you attempt to use LibMythicPlus in your addon's initialization code before that seasonal
-- data is ready. Since that seasonal data is used to provide rich, complete information about keystones and active
-- M+ challenges there is a small window where addons are initialized but LibMythicPlus is not yet ready to be
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
--     guild = string,
--     isLeader = bool
-- }
--
-- MythicPlusChallenge
-- {
--     keystone = Keystone,
--     party = list<PartyMember>,
--     result = number,
--     reason = string,
--     isCompleted = bool,
--     startedAt = ServerTime,
--     finishedAt = ServerTime,
--     deaths = number,
--     timeLostToDeaths = number,
--     isGuildParty = bool,
--     timeTaken = number|nil
-- }

-- Addon Declaration
-- ===============================================================================================================
local AceBucket = LibStub("AceBucket-3.0")
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
-- These are properties that you can change to alter the way LibMythicPlus works, these are primarily useful for
-- addon developers wishing to debug LibMythicPlus.

-- Flip this to true to cause LibMythicPlus to output detailed information about what it is doing and implicitly add
-- dump functions, regardless of the EnableDumpFunctions setting.
-- WARNING! This causes LibMythicPlus to output a _lot_ of information using, by default, LibMythicPlus:Print, which sends
-- output to your chat frame. If you have chat addons or addons that interact with chat history you could lose some of the
-- information that is output as these addons will destroy what LibMythicPlus printed. In these scenarios it is recommended
-- that you implement a LibMythicPlus.DebugHandler and consume messages in a manner that fits your addon or dev environment.
LibMythicPlus.DebugMode = true
-- Set this to a function that accepts a single, string parameter that holds debug output messages
LibMythicPlus.DebugHandler = function(Msg) LibMythicPlus:Print(Msg) end
-- Allow LibMythicPlus to define functions for dumping, with DevTools_Dump, important private data such as the Store and Api.
-- This property allow for dump functions to be declared without the noise that comes from turning on DebugMode
LibMythicPlus.EnableDumpFunctions = true

-- LibMythicPlusAPI
-- ===============================================================================================================
local Api = {
    -- Information about the currently active season
    CurrentSeason = {
        Id = nil,
        Description = nil,
        Affixes = nil,
        Maps = nil
    }
}

-- Private Configuration
-- ===============================================================================================================
--

-- Event listeners for LibMythicPlus internal events; each key in the table corresponds to a method on the Api
local EventListeners = {
    OnApiReady = {},
    OnKeystoneSlotted = {},
    OnMythicPlusStarted = {},
    OnMythicPlusCompleted = {},
    OnMythicPlusAbandoned = {},
    OnMythicPlusReset = {},
    OnInstanceLeftDuringMythicPlus = {},
    OnInstanceEnteredDuringMythicPlus = {},
    OnDeathDuringMythicPlus = {}
}

-- Blizzard invoked events that LibMythicPlus responds to
local BlizzardEvents = {
    KeystoneSlotted = "CHALLENGE_MODE_KEYSTONE_SLOTTED",
    ChallengeStarted = "CHALLENGE_MODE_START",
    ChallengeCompleted = "CHALLENGE_MODE_COMPLETED",
    ChallengeReset = "CHALLENGE_MODE_RESET",
    CurrentAffixUpdated = "MYTHIC_PLUS_CURRENT_AFFIX_UPDATE",
    SystemChatMessage = "CHAT_MSG_SYSTEM",
    PlayerEnteringWorld = "PLAYER_ENTERING_WORLD",
    ChallengeDeath = "CHALLENGE_MODE_DEATH_COUNT_UPDATED",
    InspectReady = "INSPECT_READY"
}

-- Events that are triggered via inter-addon communication
local CommEvents = {
    InstanceReset = "LibMythicPlus.InstanceReset",
    KeystoneSlotted = "LibMythicPlus.KeystoneSlotted",
    MythicPlusStarted = "LibMythicPlus.MythicPlusStarted",
    MythicPlusAbandoned = "LibMythicPlus.MythicPlusAbandoned",
    MythicPlusCompleted = "LibMythicPlus.MythicPlusCompleted"
}

-- Channels that inter-addon communication could get sent on
local CommDistribution = {
    Party = "PARTY",
    Friends = "FRIEND",
    Guild = "GUILD"
}

-- Controls the retry attempts for fetching seasonal M+ data
local MaxLoadChecksBeforeRefetch = 5
local SeasonalLoadChecks = 0
local SeasonalLoadTimers = {}

-- A list of units that need to be inspected to gather their spec and ilvl
local InspectQueue = {}

-- The AceDB that manages our persistent storage. This is not attached to LibMythicPlus or Api proper because
-- we want to restrict what other addons can do to this data. If you want to manipulate the store you should
-- do so with the functions provided by the Api. If you need to manipulate the Store in some way that the
-- Api does not provide, and you have a valid use case, please submit an issue to the addon's repo.
local Store = nil

-- Controls information about the current season, used to handle xpac changes and the time in-between xpac's final
-- season ending and the new xpac's first season beginning
local PreviousExpansionName = "Shadowlands"
local CurrentExpansionName = "Dragonflight"
local PreviousExpansionLastSeason = "4"
local PreviousExpansionLastSeasonId = 8

-- This value is available to the whole module because the value is available only from an async Blizzard call
-- but several parts of the module need access to this data.
local IsMythicPlusSeasonActive = nil

-- Private functions
-- ===============================================================================================================

--- Will pass the provided Msg to the DebugHandler currently attached to LibMythicPlus.
--
-- By default, the DebugHandler will print out any output received.
--
-- @param Msg string
-- @return nil
local function DebugPrint(Msg)
    if LibMythicPlus.DebugMode then
        LibMythicPlus.DebugHandler(Msg)
    end
end

--- Removes the listener from the provided store
--
-- @param ListenerCollection list<function>
-- @param listener function
-- @return nil
local function RemoveListener(ListenerCollection, Listener)
    for Index, StoredListener in pairs(ListenerCollection) do
        if Listener == StoredListener then
            tremove(ListenerCollection, Index)
        end
    end
end

--- Triggers each event that is listed in the EventListeners where eventName represents the key in the listeners table.
-- Any additional arguments passed beyond the event to trigger will be passed to listeners as event arguments.
--
-- @param EventName string
-- @param ... mixed
-- @return nil
local function TriggerEvent(EventName, ...)
    DebugPrint("Triggering event " .. EventName)
    for _, Listener in ipairs(EventListeners[EventName]) do
        pcall(Listener, ...)
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
    if Api.CurrentSeason.Id ~= nil then
        return
    end

    local CurrentSeasonId = C_MythicPlus.GetCurrentSeason()
    DebugPrint("Attempting to load the current season. Received " .. CurrentSeasonId)
    if CurrentSeasonId < 0 then
        DebugPrint("Received an invalid season value, will try again in 1 second.")
        tinsert(SeasonalLoadTimers, C_Timer.NewTimer(1, LoadSeasonId))
    else
        -- Ok, so M+ season IDs are just arbitrary numbers that map to the expansion and season they are for
        -- 8 is the last season in shadowlands and 9 is the first season in dragonflight
        -- If this numbering scheme holds true than the (current season id) - (last shadowlands season id) will
        -- be the _human readable_ season for dragonflight. This algorithm, while admittedly a bit hacky, should
        -- hold up for the entirety of the dragonflight expansion, regardless of how many seasons there might be...
        -- unless Blizzard decides to arbitrarily change the way season ids work
        -- NEW_VERSION_UPDATE_TODO Make sure that if a new expansion has come out this value (and corresponding text) get updated
        local CurrentSeasonDescription = nil
        if PreviousExpansionLastSeasonId == CurrentSeasonId then
            CurrentSeasonDescription = PreviousExpansionName .. " Season " .. PreviousExpansionLastSeason
        else
            CurrentSeasonDescription = CurrentExpansionName .. " Season " .. (CurrentSeasonId - PreviousExpansionLastSeasonId)
        end

        Api.CurrentSeason.Id = CurrentSeasonId
        Api.CurrentSeason.Description = CurrentSeasonDescription
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
    if Api.CurrentSeason.Affixes ~= nil then
        return
    end

    local AffixIds = C_MythicPlus.GetCurrentAffixes()
    DebugPrint("Attempting to load affixes for the current season.")
    if AffixIds then
        local Affixes = {}
        for _, AffixInfo in ipairs(AffixIds) do
            local Name, Description, FileId = C_ChallengeMode.GetAffixInfo(AffixInfo.id)
            tinsert(Affixes, {
                Id = AffixInfo.id,
                SeasonId = AffixInfo.seasonID,
                Name = Name,
                Description = Description,
                FileDataId = FileId
            })
        end
        Api.CurrentSeason.Affixes = Affixes
        DebugPrint("Successfully loaded the current season's affixes into Api.currentSeason.affixes!")
    else
        DebugPrint("Received an invalid affix value, will try again in 1 second.")
        tinsert(SeasonalLoadTimers, C_Timer.NewTimer(1, LoadSeasonAffixes))
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
    if Api.CurrentSeason.Maps ~= nil then
        return
    end

    local MapIds = C_ChallengeMode.GetMapTable()
    DebugPrint("Attempting to load the available maps for the current season.")
    if MapIds then
        local Maps = {}
        for _, MapId in ipairs(MapIds) do
            DebugPrint("Loading detailed information for challengeMapID " .. MapId)
            local Name, _, TimeLimit, Texture, BackgroundTexture = C_ChallengeMode.GetMapUIInfo(MapId)
            Maps[MapId] = {
                Id = MapId,
                Name = Name,
                TimeLimit = TimeLimit,
                Texture = Texture,
                BackgroundTexture = BackgroundTexture
            }
        end
        Api.CurrentSeason.Maps = Maps
        DebugPrint("Successfully loaded the current season's maps into Api.currentSeason.maps")
    else
        DebugPrint("Received an invalid maps value, will try again in 1 second.")
        tinsert(SeasonalLoadTimers, C_Timer.NewTimer(1, LoadSeasonMaps))
    end
end

--- Requests seasonal M+ information from Blizzard and starts processes designed to capture that data
--
-- @return nil
local function LoadSeasonData()
    IsMythicPlusSeasonActive = C_MythicPlus.IsMythicPlusActive()
    if not IsMythicPlusSeasonActive then
        DebugPrint("M+ is not active at this time.")
    else
        DebugPrint("Requested seasonal M+ data from Blizzard.")
        SeasonalLoadChecks = 0

        C_MythicPlus.RequestMapInfo()
        C_MythicPlus.RequestCurrentAffixes()
        C_MythicPlus.RequestRewards()

        -- You might expect to see LoadSeasonAffixes here but that should be triggered after receipt of a Blizzard-invoked event and is called
        -- in the corresponding event handler. Do NOT attempt to LoadSeasonAffixes here!
        LoadSeasonId()
        LoadSeasonMaps()
    end
end

--- Checks if ready to invoke OnApiReady event or restarts the seasonal data loading process if too many checks have been attempted.
--
-- @return nil
local function TriggerIsReadyEvent()
    -- Why is all this crap here? I'm glad you asked! I'm not glad I know the answer. Let's dive in...

    -- Loading seasonal data can fail for a variety of reasons, many of them legitimate, and we need a way to retry fetching seasonal data
    -- this check accomplishes that. By making sure we haven't exceeded the maximum amount of checks before we should refetch data from
    -- Blizzard we can prevent being in an infinite loop situation where the library never recognizes that it is ready to start processing.
    SeasonalLoadChecks = SeasonalLoadChecks + 1
    if SeasonalLoadChecks > MaxLoadChecksBeforeRefetch then
        DebugPrint("Too many attempts were made to fetch seasonal data with no response. Attempting to refetch from Blizzard.")
        -- Make sure we cancel all the existing timers for loading season data so we don't continue adding more and more timers, potentially
        -- resulting in a memory leak.
        for _, Timer in pairs(SeasonalLoadTimers) do
            Timer:Cancel()
        end
        LoadSeasonData()
        C_Timer.After(1.5, TriggerIsReadyEvent)
    elseif LibMythicPlus:IsReady() then
        DebugPrint("All information is available! Invoking the OnApiReady event and immediately removing lsiteners.")
        TriggerEvent("OnApiReady", Api)
        EventListeners.OnApiReady = {}
    elseif IsMythicPlusSeasonActive == false then
        -- This accounts for a gap between seasons, or expansions, where a couple weeks a season is not active.
        DebugPrint("M+ is not currently active, triggering OnApiReady event with no Api and immediately removing listeners.")
        TriggerEvent("OnApiReady", nil)
        EventListeners.OnApiReady = {}
    else
        -- We could be getting here because the data Blizzard provides async is not yet available and we should just check again soon
        DebugPrint("Information is not available. Will check again in 1.5 seconds.")
        C_Timer.After(1.5, TriggerIsReadyEvent)
    end
end

--- Retrieve the keystone that's currently slotted in the challenge model pedestal or nil if there is none.
-- This function running will invoke the OnKeystoneSlotted event and the LibMythicPlus.KeystoneSlotted inter-addon communication.
-- Blizzard Event Handler: CHALLENGE_MODE_KEYSTONE_SLOTTED
--
-- @return nil
local function KeystoneSlotted()
    local Keystone = Api:GetSlottedKeystone()
    assert(Keystone ~= nil, "There MUST be a keystone slotted before calling KeystoneSlotted but none was found.")
    TriggerEvent("OnKeystoneSlotted", Keystone)
    local Payload = {Event = CommEvents.KeystoneSlotted, Keystone = keystone, SenderGuid = UnitGUID("player")}
    AceComm:SendCommMessage(LibMythicPlus.CommPrefix, AceSerializer:Serialize(Payload), CommDistribution.Party)
end

--- Marks the currently active challenge as abandoned for the specified reason.
-- Calling this method will cause OnMythicPlusChallengeAbandoned event listeners to be invoked.
--
-- @param reason string
-- @return nil
local function AbandonMythicPlusChallenge(Reason)
    assert(Store.char.ActiveChallenge ~= nil, "Attempted to abandon a MythicPlusChallenge while there is no Store.char.activeChallenge present.")
    DebugPrint("Abandoned current M+ Challenge because " .. Reason)
    Store.char.ActiveChallenge.Result = -1
    Store.char.ActiveChallenge.Reason = Reason
    Store.char.ActiveChallenge.IsCompleted = false
    Store.char.ActiveChallenge.FinishedAt = GetServerTime()

    -- We want to make sure that Store.char.activeChallenge is set to nil BEFORE the OnMythicPlusAbandoned event is triggered
    -- There are several Api calls that are dependent on this value being present to indicate a run is active. If we trigger
    -- the event and keep the activeChallenge present in the store certain Api calls will believe that there is an active run
    -- when there really isn't.
    local Challenge = Store.char.ActiveChallenge
    Store.char.ActiveChallenge = nil
    TriggerEvent("OnMythicPlusAbandoned", challenge)
    if IsInGuild() then
        local Payload = {Event = CommEvents.MythicPlusAbandoned, SenderGuid = UnitGUID("player"), Challenge = Challenge}
        AceComm:SendCommMessage(LibMythicPlus.CommPrefix, AceSerializer:Serialize(Payload), CommDistribution.Guild)
    end
end

--- An event handler that checks if the player has reset all instances
-- If this method finds that the party leader has reset instances an inter-addon event, CommEvents.InstanceReset, will be triggered.
-- Blizzard Event Handler: CHAT_MSG_SYSTEM
--
-- @param msg string
-- @return nil
local function CheckForInstanceReset(_, Msg)
    local InstanceResetSuccessRegex = string.gsub(INSTANCE_RESET_SUCCESS, "%%s", ".+")
    if string.match(Msg, InstanceResetSuccessRegex) then
        -- It is a completely valid use case to reset instances and there be no active challenge, if so return early and don't try to abandon
        -- a M+ Challenge that doesn't exist.
        if Store.char.ActiveChallenge == nil then
            return
        end

        -- We need to let other members in the party that might be using this addon know that the leader reset the instance
        -- This chat message only shows up for the party leader, if we don't let other addon members know that the instance was reset (effectively ending the run)
        -- they'll still keep a value present in `activeChallenge` and the addon will believe that a M+ is in progress when really it failed.
        AbandonMythicPlusChallenge("InstanceReset")
        local Payload = {Event = CommEvents.InstanceReset, SenderGuid = UnitGUID("player")}
        AceComm:SendCommMessage(LibMythicPlus.CommPrefix, AceSerializer:Serialize(Payload), CommDistribution.Party)
    end
end

local function CheckForPlayerZonedOutOfActiveMythicPlusChallenge(_, IsLogin, IsReload)
    -- We don't care about initial loading or reloading, we want to know when you zone between different maps
    if IsLogin or IsReload then
        -- @TODO Need to implement and validate all this logic
        -- If there IS NOT an active challenge
            -- Check to see if blizzard thinks m+ is active (could have happened if the player client reloaded while M+ was starting and missed challenge started event)
            -- If so, create the active challenge and, presumably, we _should_ fire the OnMythicPlusChallengeStarted event

        -- If there IS an active challenge

            -- Check to see if blizzard thinks m+ is inactive and we're still in the dungeon marked for the key (not sure how to do this).
            -- If so, mark active challenge as abandoned due to disconnect and fire OnMythicPlusChallengeAbandoned event

            -- Check to see if the active challenge has a group and the player is not grouped or the group members have changed
            -- If so, mark active challenge as abandoned due to disconnect and fire OnMythicPlusChallengeAbandoned event

            -- Check to see if a certain amount of time has elapsed since the active challenge started
            -- If so, mark active challenge as abandoned due to disconnect and fire OnMythicPlusChallengeAbandoned event

        -- After all the checks above finish, if there IS an active challenge trigger the OnMythicPlusStarted event
        return
    end

    if Api:IsMythicPlusActive() and not C_ChallengeMode.IsChallengeModeActive() then
        TriggerEvent("OnInstanceLeftDuringMythicPlus", Store.char.ActiveChallenge)
    end
end

local function PopInspectQueue()
    if next(InspectQueue) ~= nil then
        local Unit = tremove(InspectQueue)
        DebugPrint("Sending NotifyInspect request for " .. Unit)
        NotifyInspect(Unit)
    else
        DebugPrint("Skipped PopInspectQueue because we think it is empty.")
    end
end

local function InspectReadyHandler(_, Guid)
    if Store.char.ActiveChallenge == nil then
        DebugPrint("Ignore inspection request because active challenge is not present")
        ClearInspectPlayer()
        return
    end

    DebugPrint("Received an inspection request for " .. Guid)
    for _, PartyMember in ipairs(Store.char.ActiveChallenge.Party) do
        if PartyMember.Id == Guid and CanInspect(PartyMember.Unit) then
            DebugPrint("Found party member as unit " .. PartyMember.Unit)
            PartyMember.Spec = GetInspectSpecialization(PartyMember.Unit)
            PartyMember.Ilvl = C_PaperDollInfo.GetInspectItemLevel(PartyMember.Unit)
            ClearInspectPlayer()
            PopInspectQueue()
        end
    end
end

--- Return a table of normalized information about a given unit
-- This function is designed to work with player and party units. Hostile units or NPC units may not be handled by this function correctly.
--
-- @return PartyMember
local function GetPartyInfo(Unit)
    DebugPrint("Retrieving information for unit " .. Unit)
    local Name, Realm = UnitName(Unit)
    if Name == nil then
        DebugPrint("No information was found for the given unit.")
        return nil
    end
    if Realm == nil then
        Realm = GetRealmName()
    end
    DebugPrint("Successfully retrieved information for unit " .. Unit)
    local UnitId = UnitGUID(Unit)

    local Spec = nil
    local Ilvl = nil
    if Unit ~= "player" then
        DebugPrint("Added " .. Unit .. " to inspect queue")
        tinsert(InspectQueue, Unit)
    else
        local CurrentSpecIndex = GetSpecialization()
        Spec = GetSpecializationInfo(CurrentSpecIndex)
        _, Ilvl = GetAverageItemLevel()
    end

    return {
        Id = UnitId,
        Unit = Unit,
        Name = Name,
        Realm = Realm,
        Faction = UnitFactionGroup(Unit),
        Race = UnitRace(Unit),
        Class = UnitClass(Unit),
        Role = UnitGroupRolesAssigned(Unit),
        Guild = GetGuildInfo(Unit),
        IsLeader = UnitIsGroupLeader(Unit),
        Spec = Spec,
        Ilvl = Ilvl
    }
end

local function ResetMythicPlusChallenge()
    if Store.char.ActiveChallenge ~= nil then
        AbandonMythicPlusChallenge("ChallengeActiveDuringReset")
    end
    TriggerEvent("OnMythicPlusReset", nil)
end

--- Will start a M+ Challenge and invoke listeners that want to know when a M+ Challenge started.
-- Calling this function will invoke the OnMythicPlusChallengeStarted listeners.
-- Blizzard Event Handler: CHALLENGE_MODE_START
--
-- @return nil
local function StartMythicPlusChallenge()
    local GetActiveKeystone = function()
        DebugPrint("Retrieving keystone information for the active M+ Challenge.")
        local KeystoneLevel = C_ChallengeMode.GetActiveKeystoneInfo()
        local KeystoneMapId = C_ChallengeMode.GetActiveChallengeMapID()

        assert(KeystoneLevel ~= nil, "Expected there to be an active keystone level but there is not one.")
        assert(KeystoneMapId ~= nil, "Expected there to be an active keystone map ID but there is not one.")

        local MapInfo = Api.CurrentSeason.Maps[KeystoneMapId]

        assert(MapInfo ~= nil, "Expected to have retrieved information for the active keystone's challenge map but nothing was found for the ID " .. KeystoneMapId)

        DebugPrint("Found map details for the active M+ Challenge.")
        return {
            Level = KeystoneLevel,
            MapId = KeystoneMapId,
            MapName = MapInfo.Name,
            Affixes = Api:GetSeasonAffixesForKeystoneLevel(KeystoneLevel),
            SeasonId = Api.CurrentSeason.Id,
            TimeLimit = MapInfo.TimeLimit
        }
    end

    local GetPartyMembers = function()
        DebugPrint("Retrieving party information for the active M+ Challenge.")
        local PartyMembers = {}
        -- The partyN units exclude the player so make sure they get included in the party
        tinsert(PartyMembers, GetPartyInfo("player"))
        for i = 1, 4, 1 do
            local Unit = "party" .. i
            local UnitInfo = GetPartyInfo(Unit)

            if UnitInfo then
                tinsert(PartyMembers, UnitInfo)
            end
        end

        PopInspectQueue()
        return PartyMembers
    end

    -- Did you know that if you zone out of an already started M+ and then back in the CHALLENGE_MODE_START event triggers again? Go figure!
    -- This ensures that if there's an active challenge already present we can trigger the correct event.
    -- TODO this could be made more future proof by doing a check against the active keystone and the activeChallenge. If the level, dungeon, or group members differ then we had an activeChallenge stored that never got cleared (this might be possible in a disconnect scenario)
    -- TODO when we improve the above check make sure we account for the fact that a group could decrease in size and still be active
    if Store.char.ActiveChallenge ~= nil then
        DebugPrint("Instance was re-entered while M+ Challenge was still active. Player likely zoned out and back in of dungeon instance.")
        TriggerEvent("OnInstanceEnteredDuringMythicPlus", Store.char.ActiveChallenge)
    else
        DebugPrint("M+ Challenge was started. Retrieving challenge information.")
        local IsGuildParty = InGuildParty()
        local Guild = nil
        if IsGuildParty then
            Guild = GetGuildInfo("player")
        end
        local ActiveChallenge = {
            StartedAt = GetServerTime(),
            FinishedAt = nil,
            Party = GetPartyMembers(),
            Keystone = GetActiveKeystone(),
            Deaths = 0,
            TimeLostToDeaths = 0,
            IsGuildParty = InGuildParty(),
            Guild = guild
        }
        DebugPrint("Stored the active M+ Challenge details in Store.char.activeChallenge!")
        Store.char.ActiveChallenge = ActiveChallenge
        TriggerEvent("OnMythicPlusStarted", Store.char.ActiveChallenge)
        if IsInGuild() then
            local Payload = {Event = CommEvents.MythicPlusStarted, SenderGuid = UnitGUID("player"), Challenge = Store.char.ActiveChallenge}
            AceComm:SendCommMessage(LibMythicPlus.CommPrefix, AceSerializer:Serialize(Payload), CommDistribution.Guild)
        end
    end
end

local function CompleteMythicPlusChallenge()
    assert(Store.char.ActiveChallenge ~= nil, "An active challenge MUST be present to call CompleteMythicPlusChallenge but found nothing.")
    local _, _, CompletionTime, _, UpgradeLevels, _, OldScore, NewScore, _, _, _, IsEligibleForScore = C_ChallengeMode.GetCompletionInfo()
    Store.char.ActiveChallenge.Result = upgradeLevels
    Store.char.ActiveChallenge.Reason = "SuccessfulCompletion"
    Store.char.ActiveChallenge.IsCompleted = true
    Store.char.ActiveChallenge.FinishedAt = GetServerTime()
    Store.char.ActiveChallenge.TimeTaken = completionTime
    Store.char.ActiveChallenge.OldScore = oldScore
    Store.char.ActiveChallenge.NewScore = newScore
    Store.char.ActiveChallenge.IsEligibleForScore = isEligibleForScore

    local Challenge = Store.char.ActiveChallenge
    Store.char.ActiveChallenge = nil
    TriggerEvent("OnMythicPlusCompleted", Challenge)
    if IsInGuild() then
        local Payload = {Event = CommEvents.MythicPlusCompleted, SenderGuid = UnitGUID("player"), Challenge = challenge}
        AceComm:SendCommMessage(LibMythicPlus.CommPrefix, AceSerializer:Serialize(payload), CommDistribution.Guild)
    end
end

local function HandleChallengeDeath()
    assert(Store.char.ActiveChallenge ~= nil, "An active challenge MUST be present to call HandleChallengeDeath but found nothing.")
    local NumDeaths, TimeLost = C_ChallengeMode.GetDeathCount()
    Store.char.ActiveChallenge.Deaths = NumDeaths
    Store.char.ActiveChallenge.TimeLostToDeaths = TimeLost
    TriggerEvent("OnDeathDuringMythicPlus", Store.char.ActiveChallenge)
end

--- LibMythicPlus handler for inter-addon communication events
--
-- @param payload serializedString
-- @param distribution string
-- @param sender string
local function CommHandler(_, Payload, Distribution, Sender)
    local Successful, Payload = AceSerializer:Deserialize(Payload)

    if not Successful then
        DebugPrint("Received a payload message that could not be deserialized.")
        return
    end

    assert(Payload.SenderGuid ~= nil, "All LibMythicPlus addon communication MUST include the sender's unit GUID.")

    -- It is possible that the player could receive their own communication, our addon is designed so that the player has already done
    -- whatever it is they're trying to communicate to other users. Nothing good can happen from a user being allowed to respond to
    -- their own inter-addon communications, so don't do it!
    if Payload.SenderGuid == UnitGUID("player") then
        return
    end

    if Payload.Event == CommEvents.InstanceReset and Api:IsMythicPlusChallengeActive() then
        AbandonMythicPlusChallenge("InstanceReset")
    end
end

-- LibMythicPlus functions
-- ===============================================================================================================

function LibMythicPlus:OnInitialize()
    DebugPrint("LibMythicPlus is intializing.")
    Store = LibStub("AceDB-3.0"):New("LibMythicPlusDB")
end

---
function LibMythicPlus:OnEnable()
    -- TODO need to check if there's a season active, if not invoke the OnApiReady with nil
    DebugPrint("Running LibMythicPlus enabled hook.")

    AceEvent:RegisterEvent(BlizzardEvents.KeystoneSlotted, KeystoneSlotted)
    AceEvent:RegisterEvent(BlizzardEvents.CurrentAffixUpdated, LoadSeasonAffixes)
    AceEvent:RegisterEvent(BlizzardEvents.ChallengeStarted, StartMythicPlusChallenge)
    AceEvent:RegisterEvent(BlizzardEvents.ChallengeCompleted, CompleteMythicPlusChallenge)
    AceEvent:RegisterEvent(BlizzardEvents.SystemChatMessage, CheckForInstanceReset)
    -- This event could potentially fire multiple times in succession, e.g. when zoning into a dungeon.
    -- By bucketing these events and only responding to 1 we make sure we avoid an issue where zoning INTO an instance
    -- results in an OnInstanceLeftDuringMythicPlus before OnInstanceEnteredDuringMythicPlus.
    AceBucket:RegisterBucketEvent({BlizzardEvents.PlayerEnteringWorld}, 1, CheckForPlayerZonedOutOfActiveMythicPlusChallenge)
    AceEvent:RegisterEvent(BlizzardEvents.ChallengeDeath, HandleChallengeDeath)
    AceEvent:RegisterEvent(BlizzardEvents.ChallengeReset, ResetMythicPlusChallenge)
    AceEvent:RegisterEvent(BlizzardEvents.InspectReady, InspectReadyHandler)

    DebugPrint("All Blizzard events have had their listeners registered.")

    AceComm:RegisterComm(LibMythicPlus.CommPrefix, CommHandler)

    DebugPrint("LibMythicPlus is registered for inter-addon communications.")

    -- Why in the world would you be setting these to happen some arbitrary time in the future, Adaxion? Have you gone mad or are you a shit programmer?
    -- Well, my friend, once you have dived into the depths of Blizzard's API and been infested by the Old Gods that live in their code you too will
    -- resort to drastic measures to vanquish your foes. You see, when a character first loads into the game there's a chance, even though we have
    -- absolutely called the correct methods in LoadSeasonData that the seasonal M+ data we want still returns an invalid value and the addon
    -- gets caught in an infinite loop waiting for data that never becomes available. Waiting a couple seconds after the addon initializes seems to
    -- help ensure that the data becomes available. More complete testing may see this value needing to increase.
    C_Timer.After(1, LoadSeasonData)
    C_Timer.After(1.5, TriggerIsReadyEvent)
end

--- Determines whether the necessary seasonal data has been loaded and the Api is ready to be provided to consumers.
--
-- @return bool
function LibMythicPlus:IsReady()
    local HasCurrentSeason = Api.CurrentSeason.Id ~= nil
    local HasCurrentAffixes = Api.CurrentSeason.Affixes ~= nil
    local HasSeasonMaps = Api.CurrentSeason.Maps ~= nil
    return HasCurrentSeason and HasCurrentAffixes and HasSeasonMaps
end

--- Register an event listener to be invoked when the LibMythicPlusAPI is ready for use.
--
-- Returns a function when invoked will remove the listener.
--
-- @param listener function(LibMythicPlusAPI)
-- @return function
function LibMythicPlus:OnApiReady(Listener)
    if LibMythicPlus:IsReady() then
        DebugPrint("LibMythicPlus is already ready, invoking OnApiReady listener immediately.")
        Listener(Api)
        -- Since this listener is never added we don't need to worry about doing anything to remove it
        return function() end
    else
        tinsert(EventListeners.OnApiReady, Listener)
        DebugPrint("Registered OnApiReady listener.")
        return function()
            DebugPrint("Removed OnApiReady listener.")
            RemoveListener(EventListeners.OnApiReady, Listener)
        end
    end
end

if LibMythicPlus.DebugMode or LibMythicPlus.EnableDumpFunctions then
    function LibMythicPlus:DumpStore()
        DevTools_Dump(Store)
    end

    function LibMythicPlus:DumpApi()
        DevTools_Dump(Api)
    end

    function LibMythicPlus:DumpActiveChallenge()
        DevTools_Dump(Store.char.ActiveChallenge)
    end
end

-- LibMythicPlusAPI functions
-- ===============================================================================================================

-- Utility functions
-- ***************************************************************************************************************
-- These are functions that could potentially be used by other other pieces of LibMythicPlusAPI.

--- Determine the affixes that would be assigned to a keystone for a given keystoneLevel
-- There is no Blizzard API for retrieving the affixes that are actually on a keystone. In theory we could parse the keystone's
-- tooltip but that seems haphazard and error prone. Instead we do the math necessary to determine how many affixes get assigned
-- based on the keystone level. This should be, in theory, future proof... even to potential changes to the user's tooltip
-- (which may ultimately be altered by other addons)
--
-- @param keystoneLevel int
-- @return list<Affix>
function Api:GetSeasonAffixesForKeystoneLevel(KeystoneLevel)
    local Affixes = self.CurrentSeason.Affixes
    assert(Affixes ~= nil)
    if KeystoneLevel <= 3 then
        return {Affixes[1]}
    elseif KeystoneLevel <= 6 then
        return {Affixes[1], Affixes[2]}
    elseif KeystoneLevel <= 9 then
        return {Affixes[1], Affixes[2], Affixes[3]}
    else
        return Affixes
    end
end

-- Player functions
-- ***************************************************************************************************************
-- These are functions that return information about the current player's Mythic+ status or keystone.

--- Return the player's current season M+ Rating
--
-- @return number
function Api:GetCurrentSeasonMythicPlusRating()
    return C_ChallengeMode.GetOverallDungeonScore()
end

--- Get the player's currently owned keystone or nil if they do not have one
--
-- @weturn Keystone|nil
function Api:GetOwnedKeystone()
    local MapId = C_MythicPlus.GetOwnedKeystoneChallengeMapID()
    if not MapId then
        return nil
    end

    local Level = C_MythicPlus.GetOwnedKeystoneLevel()
    local MapInfo = self.CurrentSeason.Maps[MapId]
    return {
        Level = Level,
        MapId = MapId,
        MapName = MapInfo.name,
        Affixes = self:GetSeasonAffixesForKeystoneLevel(Level),
        SeasonId = self.CurrentSeason.Id,
        TimeLimit = MapInfo.timeLimit
    }
end

-- Mythic+ functions
-- ***************************************************************************************************************
-- Functions that return information about the currently active, or potentially active, M+ challenge.

--- Returns the keystone that has been slotted into a challenge mode pedestal or nil if there is no slotted keystone
--
-- @return Keystone|nil
function Api:GetSlottedKeystone()
    if not C_ChallengeMode.HasSlottedKeystone() then
        return nil
    end

    local MapId, _, Level = C_ChallengeMode.GetSlottedKeystoneInfo()
    local MapInfo = self.CurrentSeason.Maps[MapId]

    return {
        Level = Level,
        MapId = MapId,
        MapName = MapInfo.name,
        Affixes = self:GetSeasonAffixesForKeystoneLevel(Level),
        SeasonId = self.CurrentSeason.Id,
        TimeLimit = MapInfo.TimeLimit
    }
end

--- Returns the active M+ Challenge if one is present, or nil.
function Api:GetActiveMythicPlus()
    return Store.char.ActiveChallenge
end

--- Returns whether or not the addon believes a M+ Challenge is active.
-- Please note that this does NOT check for Blizzard's C_ChallengeMode.IsChallengeModeActive. This method returns false if
-- the player has zoned out of the dungeon, even if a challenge is actually underway.
--
-- @return bool
function Api:IsMythicPlusActive()
    return Store.char.ActiveChallenge ~= nil
end

--- Returns whether or not the addon believe a M+ Challange is active AND the player is zoned into the dungeon
--
-- @return bool
function Api:IsMythicPlusActiveAndPlayerInDungeon()
    return Api:IsMythicPlusChallengeActive() and C_ChallengeMode.IsChallengeModeActive()
end

-- Events
-- ***************************************************************************************************************

--- Register an event listener that will be invoked when a keystone has been slotted into a challenge mode pedestal.
--
-- @param listener function(Keystone)
-- @return nil
function Api:OnKeystoneSlotted(Listener)
    tinsert(EventListeners.OnKeystoneSlotted, Listener)
    DebugPrint("Registered OnKeystoneSlotted listener.")
    return function()
        DebugPrint("Removed OnKeystoneSlotted listener.")
        RemoveListener(EventListeners.OnKeystoneSlotted, Listener)
    end
end

--- Register an event listener that will be invoked when a M+ Challenge has started
--
-- @param listener function(MythicPlusChallenge)
-- @return nil
function Api:OnMythicPlusStarted(Listener)
    tinsert(EventListeners.OnMythicPlusStarted, Listener)
    DebugPrint("Registered OnMythicPlusStarted listener.")
    return function()
        DebugPrint("Removed OnMythicPlusStarted listener.")
        RemoveListener(EventListeners.OnMythicPlusStarted, Listener)
    end
end

--- Register an event listener that will be invoked when a M+ Challenge has completed
--
-- @param listener function(MythicPlusChallenge)
-- @return nil
function Api:OnMythicPlusCompleted(Listener)
    tinsert(EventListeners.OnMythicPlusCompleted, Listener)
    DebugPrint("Registered OnMythicPlusCompleted listener.")
    return function()
        DebugPrint("Removed OnMythicPlusCompleted listener.")
        RemoveListener(EventListeners.OnMythicPlusCompleted, Listener)
    end
end

--- Register an event listern that will be invoked when a M+ Challenge has been reset
function Api:OnMyhicPlusReset(Listener)
    tinsert(EventListeners.OnMythicPlusReset, Listener)
    DebugPrint("Registered OnMythicPlusReset listener.")
    return function()
        DebugPrint("Removed OnMythicPlusReset listener.")
        RemoveListener(EventListeners.OnMyhicPlusReset, Listener)
    end
end

--- Register an event listener that will be invoked when a M+ Challenge has been abandoned.
--
-- @param listener function(MythicPlusChallenge)
-- @return nil
function Api:OnMythicPlusAbandoned(Listener)
    tinsert(EventListeners.OnMythicPlusAbandoned, Listener)
    DebugPrint("Registered OnMythicPlusAbandoned listener.")
    return function()
        DebugPrint("Removed OnMythicPlusAbandoned listener.")
        RemoveListener(EventListeners.OnMythicPlusAbandoned, Listener)
    end
end

--- Register an event listener that will be invoked when a player has zoned out of an active M+ Challenge.
--
-- @param listener function(MythicPlusChallenge)
-- @return nil
function Api:OnInstanceLeftDuringMythicPlus(Listener)
    tinsert(EventListeners.OnInstanceLeftDuringMythicPlus, Listener)
    DebugPrint("Registered OnInstanceLeftDuringMythicPlus listener.")
    return function()
        DebugPrint("Removed OnInstanceLeftDuringMythicPlus listener.")
        RemoveListener(EventListeners.OnInstanceLeftDuringMythicPlus, Listener)
    end
end

--- Register an event listener when a player has zoned into an already active M+ Challenge.
--
-- @param listener function(MythicPlusChallenge)
-- @return nil
function Api:OnInstanceEnteredDuringMythicPlus(Listener)
    tinsert(EventListeners.OnInstanceEnteredDuringMythicPlus, Listener)
    DebugPrint("Registered OnInstanceEnteredDuringMythicPlus listener.")
    return function()
        DebugPrint("Removed OnInstanceEnteredDuringMythicPlus listener.")
        RemoveListener(EventListeners.OnInstanceEnteredDuringMythicPlus, Listener)
    end
end

--- Register an event listener when the player or party member has died.
--
-- @param listener function(MythicPlusChallenge)
-- @return nil
function Api:OnDeathDuringMythicPlus(Listener)
    tinsert(EventListeners.OnDeathDuringMythicPlus, Listener)
    DebugPrint("Registered OnDeathDuringMythicPlus listener.")
    return function()
        DebugPrint("Removed OnDeathDuringMythicPlus listener.")
        RemoveListener(EventListeners.OnDeathDuringMythicPlus, Listener)
    end
end
