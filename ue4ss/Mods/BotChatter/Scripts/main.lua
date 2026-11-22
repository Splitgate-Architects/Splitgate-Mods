--[[
    BotChatter — UE4SS Lua Mod for Splitgate: Arena Reloaded (PortalWars2 / UE 5.5)
    ------------------------------------------------------------------------------
    Makes AI bots send realistic, randomized, replication-safe chat messages during
    host-run P2P / listen-server lobbies — visible to all unmodded clients.

    Verified Splitgate 2 Engine Hooks / Paths:
      - Chat broadcast (NetMulticast):
          /Script/PortalWarsCore.PortalWarsGameStateBaseV2:MulticastChatMessage
          Signature: (FGameplayTag Channel, APlayerState* FromPlayer, const FText& Message)
      - Per-controller fallback RPC:
          /Script/PortalWarsCore.PortalWarsPlayerController:ClientSendChatMessage
      - Default Lobby Chat Channel Tag:
          UI.Chat.Text.Channel.Lobby  (EOF1047ChatType::Lobby = 2)
      - Bot identification:
          APlayerState.bIsABot (offset 0x02E6) + APlayerState.PlayerNamePrivate (0x0380)
      - Death / Kill detection:
          AGF1047Character.HealthComponent (UGF1047HealthComponent)
          -> DeathInfo.DeathState (0=NotDead, 1=DeathStarted, 2=DeathFinished)
          -> IsAlive() / GetLastDamagedBy()
      - Host chat commands (!botchat on / !botchat off / !botreload / !bottest):
          Monitored safely via UPortalWarsUITextChatViewModel.ChatEntries
          (works even when HookUObjectProcessEvent = 0!) + optional ProcessEvent hook.
      - Console commands: bc_reload, bc_test, bc_inspect
      - Hotkeys (when enable_hotkeys = true):
          F6  = Run diagnostic inspector (bc_inspect)
          F8  = Force random bot test message (bc_test)
          F9  = Toggle BotChatter on/off
          F10 = Reload config.json & phrases.json (bc_reload)
]]

local MOD_NAME = "BotChatter"
local PREFIX   = "[" .. MOD_NAME .. "] "
local unpack   = table.unpack or unpack

--------------------------------------------------------------------------------
-- Path Resolution & Pure-Lua JSON Loader
--------------------------------------------------------------------------------
local function GetScriptsDir()
    local src = debug.getinfo(1, "S").source or ""
    if src:sub(1, 1) == "@" then
        src = src:sub(2)
    end
    src = src:gsub("/", "\\")
    return src:match("^(.*\\)[^\\]+$") or ""
end

local SCRIPTS_DIR    = GetScriptsDir()
local MOD_DIR        = SCRIPTS_DIR:gsub("[Ss]cripts\\?$", "")
local CONFIG_PATH    = MOD_DIR .. "config.json"
local PHRASES_PATH   = MOD_DIR .. "phrases.json"
local BOT_NAMES_PATH = MOD_DIR .. "bot_names.json"

-- Ensure Scripts/ is in package.path so require("json") always resolves cleanly
if SCRIPTS_DIR ~= "" and not package.path:find(SCRIPTS_DIR, 1, true) then
    package.path = SCRIPTS_DIR .. "?.lua;" .. package.path
end

local json = require("json")

math.randomseed(os.time() + math.floor((os.clock() or 0) * 1000))
-- Warm up PRNG
for _ = 1, 5 do math.random() end

--------------------------------------------------------------------------------
-- Default Config & Phrase Fallbacks
--------------------------------------------------------------------------------
local DEFAULT_CONFIG = {
    enabled = true,
    host_only = true,
    debug_logging = false,

    custom_bot_names_enabled = true,
    rename_bots_random = true,
    bot_name_prefix = "",
    bot_name_suffix = "",

    chat_broadcast_function = "/Script/PortalWarsCore.PortalWarsGameStateBaseV2:MulticastChatMessage",
    chat_channel_tag = "UI.Chat.Text.Channel.Lobby",
    chat_channel_type_enum = 2, -- EOF1047ChatType::Lobby

    global_cooldown_seconds = 8,
    recent_phrase_history_size = 5,
    poll_interval_ms = 250,

    pre_match_enabled = true,
    pre_match_min_bots = 1,
    pre_match_max_bots = 3,
    pre_match_delay_min_ms = 1500,
    pre_match_delay_max_ms = 5500,

    death_chat_enabled = true,
    death_chat_chance = 0.30,
    death_delay_min_ms = 1200,
    death_delay_max_ms = 3000,

    kill_chat_enabled = true,
    kill_chat_chance = 0.12,
    kill_delay_min_ms = 1400,
    kill_delay_max_ms = 3200,

    match_end_enabled = true,
    match_end_min_bots = 1,
    match_end_max_bots = 3,
    match_end_delay_min_ms = 1200,
    match_end_delay_max_ms = 4500,

    enable_event_hooks = false, -- Keep false on Splitgate 2 unless HookUObjectProcessEvent = 1
    enable_hotkeys = false,
}

local DEFAULT_PHRASES = {
    pre_match = { "glhf!", "Ready to portal", "Let's go!", "Warmup time" },
    on_death  = { "Nice shot", "Didn't see that portal", "Lag!", "wp", "Close one" },
    on_kill   = { "Gotcha", "Clean angle" },
    match_end = { "gg", "gg wp", "Rematch?" },
}

local DEFAULT_BOT_NAMES = {
    fixed_names  = {},
    random_names = {
        "Vortex99", "Kestrel", "NovaPulse", "ZeroG_Max", "EchoDrift",
        "RiftWalker", "ShadowHop", "PixelKnight", "FrostByte", "TurboSloth",
        "Hyperion", "NeonViper", "GlitchKing", "Cinder", "StrafeGod", "Lumen",
    },
}

--------------------------------------------------------------------------------
-- Runtime State
--------------------------------------------------------------------------------
local Config   = {}
local Phrases  = {}
local BotNames = { fixed_names = {}, random_names = {} }

local State = {
    last_chat_time       = 0,
    recent_phrases       = {},      -- FIFO list of last N used raw phrases
    last_game_state_addr = 0,
    cached_game_state    = nil,     -- cached active APortalWarsGameStateBaseV2 / AGameStateBase
    gs_found_via         = "",
    cached_text_chat_vm  = nil,     -- cached active UPortalWarsUITextChatViewModel
    last_gs_scan_time    = -10,
    last_vm_scan_time    = -10,
    last_phase_key       = "",
    pre_match_fired      = false,
    match_end_fired      = false,
    was_in_progress      = false,
    player_alive_cache   = {},      -- [ps_addr] = bool (true=alive, false=dead)
    player_hc_cache      = {},      -- [ps_addr] = last seen UGF1047HealthComponent
    renamed_bots         = {},      -- [ps_addr] = { orig = "...", custom = "..." }
    used_bot_names       = {},      -- [lower_name] = true
    name_queue           = {},      -- shuffled/ordered pool for the current match
    last_chat_entry_cnt  = 0,       -- tracks UPortalWarsUITextChatViewModel.ChatEntries
    processed_chat_cmds  = {},      -- dedupe processed chat command entries
    hooks_registered     = false,
    poll_started         = false,
}

--------------------------------------------------------------------------------
-- Logging & File Utilities
--------------------------------------------------------------------------------
local function Log(msg)
    print(PREFIX .. tostring(msg) .. "\n")
end

local function DebugLog(msg)
    if Config.debug_logging then
        print(PREFIX .. "[DEBUG] " .. tostring(msg) .. "\n")
    end
end

local function ReadFileText(path)
    local f, err = io.open(path, "rb")
    if not f then
        return nil, err
    end
    local content = f:read("*a")
    f:close()
    return content, nil
end

local function ShallowCopy(tbl)
    local out = {}
    for k, v in pairs(tbl) do out[k] = v end
    return out
end

local function LoadConfigAndPhrases(reason)
    -- 1. Load config.json
    local cfg = ShallowCopy(DEFAULT_CONFIG)
    local cfg_text, cfg_err = ReadFileText(CONFIG_PATH)
    if cfg_text then
        local ok, parsed = pcall(json.decode, cfg_text)
        if ok and type(parsed) == "table" then
            for k, v in pairs(parsed) do
                cfg[k] = v
            end
            Log("(" .. reason .. ") Loaded config.json")
        else
            Log("ERROR parsing config.json (" .. tostring(parsed) .. "); using defaults.")
        end
    else
        Log("WARNING: Could not read " .. CONFIG_PATH .. " (" .. tostring(cfg_err) .. "); using defaults.")
    end
    Config = cfg

    -- 2. Load phrases.json
    local phr = ShallowCopy(DEFAULT_PHRASES)
    local phr_text, phr_err = ReadFileText(PHRASES_PATH)
    if phr_text then
        local ok, parsed = pcall(json.decode, phr_text)
        if ok and type(parsed) == "table" then
            for category, list in pairs(parsed) do
                if type(list) == "table" then
                    phr[category] = list
                end
            end
            Log(string.format(
                "(%s) Loaded phrases.json (pre_match=%d, on_death=%d, on_kill=%d, match_end=%d)",
                reason,
                #(phr.pre_match or {}),
                #(phr.on_death or {}),
                #(phr.on_kill or {}),
                #(phr.match_end or {})
            ))
        else
            Log("ERROR parsing phrases.json (" .. tostring(parsed) .. "); using defaults.")
        end
    else
        Log("WARNING: Could not read " .. PHRASES_PATH .. " (" .. tostring(phr_err) .. "); using defaults.")
    end
    Phrases = phr

    -- 3. Load bot_names.json (supports either { fixed_names={}, random_names=[...] } or a plain JSON array [...])
    local bn = {
        fixed_names  = {},
        random_names = ShallowCopy(DEFAULT_BOT_NAMES.random_names),
    }
    local bn_text, bn_err = ReadFileText(BOT_NAMES_PATH)
    if bn_text then
        local ok, parsed = pcall(json.decode, bn_text)
        if ok and type(parsed) == "table" then
            if #parsed > 0 then
                -- Plain JSON array of names
                bn.random_names = {}
                for _, item in ipairs(parsed) do
                    if type(item) == "string" and item ~= "" then
                        bn.random_names[#bn.random_names + 1] = item
                    end
                end
            else
                if type(parsed.fixed_names) == "table" then
                    for orig_k, custom_v in pairs(parsed.fixed_names) do
                        if type(orig_k) == "string" and type(custom_v) == "string" and custom_v ~= "" then
                            bn.fixed_names[orig_k] = custom_v
                        end
                    end
                end
                if type(parsed.random_names) == "table" and #parsed.random_names > 0 then
                    bn.random_names = {}
                    for _, item in ipairs(parsed.random_names) do
                        if type(item) == "string" and item ~= "" then
                            bn.random_names[#bn.random_names + 1] = item
                        end
                    end
                end
            end
            local fixed_cnt = 0
            for _ in pairs(bn.fixed_names) do fixed_cnt = fixed_cnt + 1 end
            Log(string.format("(%s) Loaded bot_names.json (fixed=%d, random=%d)", reason, fixed_cnt, #bn.random_names))
        else
            Log("ERROR parsing bot_names.json (" .. tostring(parsed) .. "); using defaults.")
        end
    else
        DebugLog("bot_names.json not found (" .. tostring(bn_err) .. "); using built-in bot name list.")
    end
    BotNames = bn
    State.name_queue = {}
end

--------------------------------------------------------------------------------
-- Safe UObject / Property Helpers
--------------------------------------------------------------------------------
local function IsValidObj(obj)
    if obj == nil then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
end

local function SafeGetAddress(obj)
    if not IsValidObj(obj) then return 0 end
    local ok, addr = pcall(function() return obj:GetAddress() end)
    return (ok and addr) or 0
end

local function SafeToString(val)
    if val == nil then return "" end
    if type(val) == "string" then return val end
    local ok, str = pcall(function()
        if type(val) == "userdata" and val.ToString then
            return val:ToString()
        end
        return tostring(val)
    end)
    return (ok and type(str) == "string") and str or ""
end

local function SafeProp(obj, prop_name)
    if not IsValidObj(obj) then return nil end
    local ok, val = pcall(function() return obj[prop_name] end)
    if ok then return val end
    return nil
end

local function SafeCall(obj, fn_name, ...)
    if not IsValidObj(obj) then return false, nil end
    local args = { ... }
    local ok, res = pcall(function()
        local fn = obj[fn_name]
        if type(fn) == "function" then
            return fn(obj, unpack(args))
        end
        return nil
    end)
    return ok, res
end

local function GetBool(val)
    return val == true or val == 1
end

local function Trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function RandomInt(min_v, max_v)
    min_v = math.floor(tonumber(min_v) or 0)
    max_v = math.floor(tonumber(max_v) or min_v)
    if max_v <= min_v then return min_v end
    return math.random(min_v, max_v)
end

local function ShuffleCopy(list)
    local copy = {}
    for i = 1, #list do copy[i] = list[i] end
    for i = #copy, 2, -1 do
        local j = math.random(1, i)
        copy[i], copy[j] = copy[j], copy[i]
    end
    return copy
end

--------------------------------------------------------------------------------
-- GameState / Host Authority / Map / Bot Discovery (Fast, Non-Blocking)
--------------------------------------------------------------------------------
local function IsCDOOrArchetype(obj)
    if not IsValidObj(obj) then return true end
    local ok, name = pcall(function() return obj:GetFName():ToString() end)
    if ok and type(name) == "string" then
        if name:sub(1, 9) == "Default__" then
            return true
        end
        return false
    end
    return false
end

local function GetGameplayStatics()
    local cdo = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if IsValidObj(cdo) then return cdo end
    return nil
end

local function ScoreGameStateCandidate(cand)
    if not IsValidObj(cand) or IsCDOOrArchetype(cand) then return -1 end
    local score = 1
    local ok_isa, is_pw = pcall(function() return cand:IsA("/Script/PortalWarsCore.PortalWarsGameStateBaseV2") end)
    if ok_isa and is_pw then score = score + 100 end
    local ok_gf, is_gf = pcall(function() return cand:IsA("/Script/GameFramework1047.GF1047GameStateBase") end)
    if ok_gf and is_gf then score = score + 50 end
    local ok_cnt, cnt = pcall(function() return cand.PlayerArray:GetArrayNum() end)
    if ok_cnt and type(cnt) == "number" and cnt > 0 then score = score + 20 + math.min(cnt, 20) end
    return score
end

local function PickBestGameStateFromList(list)
    if type(list) ~= "table" then return nil end
    local best, best_score = nil, -1
    for _, cand in ipairs(list) do
        local sc = ScoreGameStateCandidate(cand)
        if sc > best_score then
            best = cand
            best_score = sc
        end
    end
    return best
end

local function GetGameState(force_scan)
    if not force_scan and IsValidObj(State.cached_game_state) and not IsCDOOrArchetype(State.cached_game_state) then
        -- Keep cached match GameState (GF1047GameStateBase+); allow upgrading away from MainMenuGameState
        if ScoreGameStateCandidate(State.cached_game_state) >= 50 then
            return State.cached_game_state
        end
    end

    local now = os.clock()
    if not force_scan and (now - State.last_gs_scan_time) < 2.0 then
        return State.cached_game_state
    end
    State.last_gs_scan_time = now

    local gs_lib = GetGameplayStatics()

    -- 1. Primary (100% native C++): UGameplayStatics::GetGameState(WorldContextObject)
    --    Feed live APlayerState instances (confirmed present in matches via FindAllOf("PlayerState")),
    --    PlayerControllers, and Worlds directly into UE5's UWorld::GetGameState().
    if IsValidObj(gs_lib) then
        local cands = {}
        local seen = {}
        local function TryContextObj(ctx, label)
            if not IsValidObj(ctx) or IsCDOOrArchetype(ctx) then return end
            local ok_gs, found_gs = pcall(function() return gs_lib:GetGameState(ctx) end)
            if ok_gs and IsValidObj(found_gs) and not IsCDOOrArchetype(found_gs) then
                local addr = SafeGetAddress(found_gs)
                if addr ~= 0 and not seen[addr] then
                    seen[addr] = label
                    cands[#cands + 1] = found_gs
                end
            end
        end

        for _, cls_name in ipairs({ "PlayerState", "PortalWarsPlayerController", "PlayerController", "World" }) do
            local ok_list, objs = pcall(FindAllOf, cls_name)
            if ok_list and type(objs) == "table" then
                for _, obj in ipairs(objs) do
                    TryContextObj(obj, "GameplayStatics:GetGameState(" .. cls_name .. ")")
                end
            end
        end

        local picked = PickBestGameStateFromList(cands)
        if IsValidObj(picked) then
            State.cached_game_state = picked
            State.gs_found_via = seen[SafeGetAddress(picked)] or "GameplayStatics:GetGameState"
            return picked
        end
    end

    -- 2. Secondary (100% native C++): UGameStateComponent::GetOwner()
    --    AGF1047GameStateBase always owns ExperienceManagerComponent & ScoreContainerComponent.
    for _, comp_cls in ipairs({ "GF1047ExperienceManagerComponent", "GF1047ScoreContainerComponent", "GameStateComponent" }) do
        local ok_c, comps = pcall(FindAllOf, comp_cls)
        if ok_c and type(comps) == "table" then
            local owners = {}
            for _, comp in ipairs(comps) do
                if IsValidObj(comp) and not IsCDOOrArchetype(comp) then
                    local ok_o, owner = SafeCall(comp, "GetOwner")
                    if ok_o and IsValidObj(owner) then
                        owners[#owners + 1] = owner
                    end
                end
            end
            local picked = PickBestGameStateFromList(owners)
            if IsValidObj(picked) then
                State.cached_game_state = picked
                State.gs_found_via = comp_cls .. ":GetOwner()"
                return picked
            end
        end
    end

    -- 3. Direct class search fallbacks
    for _, name in ipairs({ "PortalWarsGameStateV2", "PortalWarsGameStateBaseV2", "GF1047GameStateBase", "GameStateBase" }) do
        local ok_all, all_gs = pcall(FindAllOf, name)
        if ok_all then
            local picked = PickBestGameStateFromList(all_gs)
            if IsValidObj(picked) then
                State.cached_game_state = picked
                State.gs_found_via = "FindAllOf(" .. name .. ")"
                return picked
            end
        end
    end

    return nil
end

local function GetTextChatVM(force_scan)
    if IsValidObj(State.cached_text_chat_vm) and not IsCDOOrArchetype(State.cached_text_chat_vm) then
        return State.cached_text_chat_vm
    end

    local now = os.clock()
    if not force_scan and (now - State.last_vm_scan_time) < 3.0 then
        return nil
    end
    State.last_vm_scan_time = now

    local vm = FindFirstOf("PortalWarsUITextChatViewModel")
    if IsValidObj(vm) and not IsCDOOrArchetype(vm) then
        State.cached_text_chat_vm = vm
        return vm
    end

    local sub = FindFirstOf("PortalWarsUIPlayerDataSubsystem")
    if IsValidObj(sub) then
        local sub_vm = SafeProp(sub, "TextChatVM")
        if IsValidObj(sub_vm) then
            State.cached_text_chat_vm = sub_vm
            return sub_vm
        end
    end

    return nil
end

local function IsHostingMatch(gs)
    if not Config.host_only then
        return true
    end
    if IsValidObj(gs) then
        local ok, has_auth = SafeCall(gs, "HasAuthority")
        if ok and GetBool(has_auth) then return true end
        local role = SafeProp(gs, "Role")
        if role == 3 then return true end -- ROLE_Authority
        local auth_gm = SafeProp(gs, "AuthorityGameMode")
        if IsValidObj(auth_gm) then return true end
        local gs_lib = GetGameplayStatics()
        if IsValidObj(gs_lib) then
            local ok_gm, gm = pcall(function() return gs_lib:GetGameMode(gs) end)
            if ok_gm and IsValidObj(gm) then return true end
        end
    end

    for _, name in ipairs({ "PortalWarsGameModeV2_BP_C", "PortalWarsGameModeV2", "PortalWarsGameModeBaseV2", "GF1047GameModeBase", "GameModeBase" }) do
        local gm = FindFirstOf(name)
        if IsValidObj(gm) and not IsCDOOrArchetype(gm) then return true end
    end
    return false
end

local function GetCurrentMapName(gs)
    if IsValidObj(gs) then
        local map_data = SafeProp(gs, "MapData")
        if IsValidObj(map_data) then
            local name_txt = SafeToString(SafeProp(map_data, "MapName"))
            if name_txt ~= "" then
                return name_txt
            end
        end
        local ok, world_name = pcall(function()
            local outer = gs:GetOuter() -- ULevel
            if IsValidObj(outer) then
                local world = outer:GetOuter() -- UWorld
                if IsValidObj(world) then
                    return world:GetFName():ToString()
                end
            end
            return ""
        end)
        if ok and world_name and world_name ~= "" then
            return world_name
        end
    end
    return "this map"
end

local function GetPlayerName(ps)
    if not IsValidObj(ps) then return "Player" end
    local name = SafeToString(SafeProp(ps, "PlayerNamePrivate"))
    if name ~= "" then return name end
    local ok, res = SafeCall(ps, "GetPlayerName")
    if ok then
        local s = SafeToString(res)
        if s ~= "" then return s end
    end
    return "Bot"
end

local function IsPlayerStateBot(ps)
    if not IsValidObj(ps) then return false end

    -- Primary check: APlayerState::bIsABot (verified offset 0x02E6)
    if GetBool(SafeProp(ps, "bIsABot")) then
        return true
    end

    -- Secondary check: AIController ownership or pawn controller
    local ok_ai, is_ai = pcall(function()
        local owner = ps:GetOwner()
        if IsValidObj(owner) and owner:IsA("/Script/AIModule.AIController") then
            return true
        end
        local pawn = ps.PawnPrivate
        if IsValidObj(pawn) then
            local ctrl = pawn.Controller
            if IsValidObj(ctrl) and ctrl:IsA("/Script/AIModule.AIController") then
                return true
            end
        end
        return false
    end)
    return ok_ai and is_ai == true
end

local function GetAllPlayerStates(gs)
    local out = {}
    local seen = {}
    if IsValidObj(gs) then
        pcall(function()
            local arr = gs.PlayerArray
            if arr then
                arr:ForEach(function(_, elem)
                    local ps = elem:get()
                    if IsValidObj(ps) and not IsCDOOrArchetype(ps) then
                        local addr = SafeGetAddress(ps)
                        if addr ~= 0 and not seen[addr] then
                            seen[addr] = true
                            out[#out + 1] = ps
                        end
                    end
                end)
            end
        end)
    end

    -- Fallback: read live APlayerState instances directly if PlayerArray was empty
    if #out == 0 then
        pcall(function()
            local all_ps = FindAllOf("PlayerState")
            if type(all_ps) == "table" then
                for _, ps in ipairs(all_ps) do
                    if IsValidObj(ps) and not IsCDOOrArchetype(ps) then
                        local addr = SafeGetAddress(ps)
                        if addr ~= 0 and not seen[addr] then
                            seen[addr] = true
                            out[#out + 1] = ps
                        end
                    end
                end
            end
        end)
    end
    return out
end

local function GetLobbyBots(gs)
    local bots = {}
    for _, ps in ipairs(GetAllPlayerStates(gs)) do
        if IsPlayerStateBot(ps) then
            bots[#bots + 1] = ps
        end
    end
    return bots
end

--------------------------------------------------------------------------------
-- Custom Bot Renaming (Replication-Safe via AGameModeBase::ChangeName)
--------------------------------------------------------------------------------
local function GetAuthorityGameMode(gs)
    if IsValidObj(gs) then
        local auth_gm = SafeProp(gs, "AuthorityGameMode")
        if IsValidObj(auth_gm) then return auth_gm end
        local gs_lib = GetGameplayStatics()
        if IsValidObj(gs_lib) then
            local ok_gm, gm = pcall(function() return gs_lib:GetGameMode(gs) end)
            if ok_gm and IsValidObj(gm) then return gm end
        end
    end
    for _, name in ipairs({ "PortalWarsGameModeV2_BP_C", "PortalWarsGameModeV2", "PortalWarsGameModeBaseV2", "GF1047GameModeBase", "GameModeBase" }) do
        local gm = FindFirstOf(name)
        if IsValidObj(gm) and not IsCDOOrArchetype(gm) then return gm end
    end
    return nil
end

local function GetBotController(ps)
    if not IsValidObj(ps) then return nil end
    local ok_own, owner = SafeCall(ps, "GetOwner")
    if ok_own and IsValidObj(owner) then
        local ok_is, is_ctrl = pcall(function() return owner:IsA("/Script/Engine.Controller") end)
        if ok_is and is_ctrl then return owner end
    end
    local pawn = SafeProp(ps, "PawnPrivate")
    if IsValidObj(pawn) then
        local ctrl = SafeProp(pawn, "Controller")
        if IsValidObj(ctrl) then return ctrl end
    end
    return nil
end

local function RefillBotNameQueue()
    local pool = (BotNames and type(BotNames.random_names) == "table" and #BotNames.random_names > 0)
        and BotNames.random_names or DEFAULT_BOT_NAMES.random_names
    if Config.rename_bots_random ~= false then
        State.name_queue = ShuffleCopy(pool)
    else
        State.name_queue = {}
        for i = 1, #pool do State.name_queue[i] = pool[i] end
    end
end

local function PickNextUniqueBotName(orig_name)
    local prefix = tostring(Config.bot_name_prefix or "")
    local suffix = tostring(Config.bot_name_suffix or "")

    -- 1. Check explicit fixed_names mapping (by exact original name, e.g. "Ace 0")
    if BotNames and type(BotNames.fixed_names) == "table" and orig_name ~= "" then
        local mapped = BotNames.fixed_names[orig_name]
        if type(mapped) == "string" and mapped ~= "" then
            local candidate = prefix .. mapped .. suffix
            State.used_bot_names[candidate:lower()] = true
            return candidate
        end
    end

    -- 2. Draw next unused name from shuffled/ordered random_names pool
    if #State.name_queue == 0 then
        RefillBotNameQueue()
    end

    for _ = 1, #State.name_queue do
        local base = table.remove(State.name_queue, 1)
        if type(base) == "string" and base ~= "" then
            local candidate = prefix .. base .. suffix
            if not State.used_bot_names[candidate:lower()] then
                State.used_bot_names[candidate:lower()] = true
                return candidate
            end
        end
    end

    -- 3. Pool exhausted (more bots than names in bot_names.json): append a unique number
    local pool = (BotNames and type(BotNames.random_names) == "table" and #BotNames.random_names > 0)
        and BotNames.random_names or DEFAULT_BOT_NAMES.random_names
    local base = pool[math.random(1, #pool)] or "Bot"
    for n = 2, 99 do
        local candidate = prefix .. base .. " " .. tostring(n) .. suffix
        if not State.used_bot_names[candidate:lower()] then
            State.used_bot_names[candidate:lower()] = true
            return candidate
        end
    end
    return prefix .. base .. suffix
end

local function ApplyCustomBotNames(gs, force_reroll)
    if not Config.custom_bot_names_enabled and not force_reroll then return 0 end
    if not IsValidObj(gs) or not IsHostingMatch(gs) then return 0 end

    local gm = GetAuthorityGameMode(gs)
    if not IsValidObj(gm) then return 0 end

    if force_reroll then
        State.renamed_bots   = {}
        State.used_bot_names = {}
        State.name_queue     = {}
    end

    local bots = GetLobbyBots(gs)
    if #bots == 0 then return 0 end

    local renamed_count = 0
    for _, ps in ipairs(bots) do
        local addr = SafeGetAddress(ps)
        if addr ~= 0 then
            local rec = State.renamed_bots[addr]
            local cur_name = GetPlayerName(ps)

            -- Rename if not yet renamed (or if the engine reset it back to the original name)
            if not rec or (rec.custom and cur_name ~= rec.custom) then
                local ctrl = GetBotController(ps)
                if IsValidObj(ctrl) then
                    local orig_name = (rec and rec.orig) or cur_name
                    local new_name  = (rec and not force_reroll and rec.custom) or PickNextUniqueBotName(orig_name)

                    local ok_chg, err_chg = pcall(function()
                        gm:ChangeName(ctrl, new_name, true)
                    end)
                    if ok_chg then
                        State.renamed_bots[addr] = { orig = orig_name, custom = new_name }
                        renamed_count = renamed_count + 1
                        Log(string.format("[RENAME] '%s' -> '%s'", orig_name, new_name))
                    else
                        DebugLog("ChangeName failed for '" .. orig_name .. "': " .. tostring(err_chg))
                    end
                end
            end
        end
    end
    return renamed_count
end

--------------------------------------------------------------------------------
-- Phrase Selection, Placeholders & Anti-Spam Cooldown
--------------------------------------------------------------------------------
local function IsRecentlyUsed(raw_phrase)
    for i = 1, #State.recent_phrases do
        if State.recent_phrases[i] == raw_phrase then
            return true
        end
    end
    return false
end

local function RememberPhrase(raw_phrase)
    local limit = tonumber(Config.recent_phrase_history_size) or 5
    if limit <= 0 then return end
    State.recent_phrases[#State.recent_phrases + 1] = raw_phrase
    while #State.recent_phrases > limit do
        table.remove(State.recent_phrases, 1)
    end
end

local function PickPhrase(category, vars)
    local pool = Phrases[category]
    if type(pool) ~= "table" or #pool == 0 then
        return nil
    end

    local has_killer = vars and type(vars.killer) == "string" and vars.killer ~= ""
    local has_victim = vars and type(vars.victim) == "string" and vars.victim ~= ""

    -- Filter out phrases whose required dynamic placeholder is unavailable (never say "someone")
    local eligible = {}
    for i = 1, #pool do
        local p = pool[i]
        if type(p) == "string" and p ~= "" then
            local needs_killer = p:find("{killer}", 1, true) ~= nil
            local needs_victim = p:find("{victim}", 1, true) ~= nil
            if (not needs_killer or has_killer) and (not needs_victim or has_victim) then
                eligible[#eligible + 1] = p
            end
        end
    end
    if #eligible == 0 then
        eligible = pool
    end

    -- Prefer phrases not in the recent history window
    local fresh = {}
    for i = 1, #eligible do
        if type(eligible[i]) == "string" and eligible[i] ~= "" and not IsRecentlyUsed(eligible[i]) then
            fresh[#fresh + 1] = eligible[i]
        end
    end

    local source = (#fresh > 0) and fresh or eligible
    local picked = source[math.random(1, #source)]
    if type(picked) == "string" and picked ~= "" then
        RememberPhrase(picked)
        return picked
    end
    return nil
end

local function FormatPhrase(template, vars)
    local out = template
    local replacements = {
        ["{bot}"]    = (vars and vars.bot)    or "Bot",
        ["{killer}"] = (vars and vars.killer) or "someone",
        ["{victim}"] = (vars and vars.victim) or "someone",
        ["{map}"]    = (vars and vars.map)    or "this map",
    }
    for token, val in pairs(replacements) do
        local safe_val = tostring(val):gsub("%%", "%%%%")
        out = out:gsub(token, safe_val)
    end
    return out
end

local function CanPassGlobalCooldown(bypass_cooldown)
    if bypass_cooldown then return true end
    local cd = tonumber(Config.global_cooldown_seconds) or 8
    local now = os.clock()
    if (now - State.last_chat_time) < cd then
        return false
    end
    return true
end

--------------------------------------------------------------------------------
-- Replication-Safe Chat Dispatch (Visible to All Unmodded Clients)
--------------------------------------------------------------------------------
local function BuildChatChannelTag()
    -- 1. Try Splitgate 2's own UPortalWarsUIChatHelpers::GetTextChatChannelTagFromChatType
    local ok_helper, helper_tag = pcall(function()
        local cdo = StaticFindObject("/Script/PortalWarsUI.Default__PortalWarsUIChatHelpers")
        if IsValidObj(cdo) then
            return cdo:GetTextChatChannelTagFromChatType(tonumber(Config.chat_channel_type_enum) or 2)
        end
        return nil
    end)
    if ok_helper and helper_tag ~= nil then
        local ok_tn, raw_tn = pcall(function() return helper_tag.TagName end)
        local tag_name = ok_tn and SafeToString(raw_tn) or ""
        if tag_name ~= "" and tag_name ~= "None" then
            return helper_tag, tag_name, "UIChatHelpers"
        end
    end

    -- 2. Construct FGameplayTag table directly using verified tag name ("UI.Chat.Text.Channel.Lobby")
    local tag_str = tostring(Config.chat_channel_tag or "UI.Chat.Text.Channel.Lobby")
    return { TagName = FName(tag_str) }, tag_str, "ConfigFallback"
end

local function ExtractFuncName(full_path)
    if type(full_path) ~= "string" or full_path == "" then
        return "MulticastChatMessage"
    end
    local fn = full_path:match(":([^:]+)$")
    return fn or full_path
end

local function DispatchBotChat(bot_ps, message, bypass_cooldown)
    if not Config.enabled and not bypass_cooldown then
        return false
    end
    if not IsValidObj(bot_ps) then
        DebugLog("Skipped chat dispatch: bot PlayerState is no longer valid.")
        return false
    end

    local gs = GetGameState()
    if not IsValidObj(gs) then
        DebugLog("Skipped chat dispatch: GameState is not valid.")
        return false
    end
    if not IsHostingMatch(gs) then
        DebugLog("Skipped chat dispatch: not host/authority.")
        return false
    end
    if not CanPassGlobalCooldown(bypass_cooldown) then
        DebugLog("Skipped chat dispatch (global cooldown active): " .. message)
        return false
    end

    local bot_name = GetPlayerName(bot_ps)
    local channel_tag, channel_tag_name, channel_src = BuildChatChannelTag()
    local text_msg = FText(message)
    local fn_name = ExtractFuncName(Config.chat_broadcast_function)
    DebugLog(string.format("Dispatching chat as '%s' via %s (Channel='%s' [%s])", bot_name, fn_name, tostring(channel_tag_name), tostring(channel_src)))

    -- Primary path: NetMulticast RPC on APortalWarsGameStateBaseV2
    -- Signature: void MulticastChatMessage(FGameplayTag Channel, APlayerState* FromPlayer, const FText& Message)
    local ok_mc, err_mc = pcall(function()
        gs[fn_name](gs, channel_tag, bot_ps, text_msg)
    end)

    if ok_mc then
        State.last_chat_time = os.clock()
        Log(string.format("[CHAT] %s: %s", bot_name, message))
        return true
    end

    DebugLog("Primary broadcast '" .. fn_name .. "' failed (" .. tostring(err_mc) .. "); trying per-controller ClientSendChatMessage fallback...")

    -- Fallback path: iterate all APortalWarsPlayerController instances on server and call ClientSendChatMessage
    local sent_any = false
    pcall(function()
        local pcs = FindAllOf("PortalWarsPlayerController")
        if not pcs or #pcs == 0 then
            pcs = FindAllOf("BP_PlayerController_C")
        end
        if pcs then
            for _, pc in ipairs(pcs) do
                if IsValidObj(pc) and not IsCDOOrArchetype(pc) then
                    local ok_c = pcall(function()
                        pc:ClientSendChatMessage(channel_tag, bot_ps, text_msg)
                    end)
                    if ok_c then sent_any = true end
                end
            end
        end
    end)

    if sent_any then
        State.last_chat_time = os.clock()
        Log(string.format("[CHAT/Fallback] %s: %s", bot_name, message))
        return true
    end

    Log("ERROR: Failed to dispatch chat message for " .. bot_name .. " (primary error: " .. tostring(err_mc) .. ")")
    return false
end

local function ScheduleBotMessage(bot_ps, category, vars, delay_ms, bypass_cooldown)
    if not IsValidObj(bot_ps) then return end
    vars = vars or {}
    local raw = PickPhrase(category, vars)
    if not raw then return end

    local ps_addr = SafeGetAddress(bot_ps)
    local bot_name = GetPlayerName(bot_ps)
    vars.bot = bot_name
    if not vars.map then
        vars.map = GetCurrentMapName(GetGameState())
    end
    local final_msg = FormatPhrase(raw, vars)

    DebugLog(string.format("Scheduled [%s] for '%s' in %dms: %s", category, bot_name, delay_ms, final_msg))

    ExecuteWithDelay(delay_ms, function()
        ExecuteInGameThread(function()
            if not Config.enabled and not bypass_cooldown then return end
            -- Re-verify the exact PlayerState is still alive/valid in the current GameState
            if not IsValidObj(bot_ps) or SafeGetAddress(bot_ps) ~= ps_addr then
                DebugLog("Cancelled delayed message for '" .. bot_name .. "' (despawned/map changed).")
                return
            end
            DispatchBotChat(bot_ps, final_msg, bypass_cooldown)
        end)
    end)
end

--------------------------------------------------------------------------------
-- Event Triggers: Pre-Match, Match-End, On-Death, On-Kill
--------------------------------------------------------------------------------
local function TriggerLobbyBurst(gs, category, min_bots, max_bots, d_min, d_max)
    if not Config.enabled then return end
    if not IsValidObj(gs) or not IsHostingMatch(gs) then return end

    local bots = GetLobbyBots(gs)
    if #bots == 0 then
        DebugLog("TriggerLobbyBurst(" .. category .. "): no bots found in PlayerArray.")
        return
    end

    local shuffled = ShuffleCopy(bots)
    local count = math.min(#shuffled, RandomInt(min_bots, max_bots))
    local map_name = GetCurrentMapName(gs)
    local base_delay = 0

    for i = 1, count do
        -- Stagger each bot so messages feel natural and never collide on the same tick
        local step_delay = RandomInt(d_min, d_max)
        local delay = (i == 1) and step_delay or (base_delay + RandomInt(1200, 2800))
        base_delay = delay
        -- For multi-bot pre_match / match_end bursts, bypass global cooldown after the first
        -- message only if the user's global_cooldown_seconds is longer than the stagger window.
        ScheduleBotMessage(shuffled[i], category, { map = map_name }, delay, true)
    end
end

local function ExtractPlayerStateFromActor(actor, depth)
    if not IsValidObj(actor) then return nil end
    depth = depth or 0
    if depth > 4 then return nil end

    local ok_ps, ps = pcall(function()
        if actor:IsA("/Script/Engine.PlayerState") then
            return actor
        end
        local direct_ps = actor.PlayerState
        if IsValidObj(direct_ps) then
            return direct_ps
        end
        local ctrl = actor.Controller
        if IsValidObj(ctrl) and IsValidObj(ctrl.PlayerState) then
            return ctrl.PlayerState
        end
        return nil
    end)
    if ok_ps and IsValidObj(ps) then
        return ps
    end

    -- Walk Instigator (e.g. projectile/weapon -> APawn) and Owner chain
    local inst = SafeProp(actor, "Instigator")
    if IsValidObj(inst) and SafeGetAddress(inst) ~= SafeGetAddress(actor) then
        local found = ExtractPlayerStateFromActor(inst, depth + 1)
        if IsValidObj(found) then return found end
    end
    local ok_own, owner = SafeCall(actor, "GetOwner")
    if ok_own and IsValidObj(owner) and SafeGetAddress(owner) ~= SafeGetAddress(actor) then
        local found = ExtractPlayerStateFromActor(owner, depth + 1)
        if IsValidObj(found) then return found end
    end
    return nil
end

local function ResolveAttackerPlayerState(health_comp)
    if not IsValidObj(health_comp) then return nil end

    -- 1. Primary (Lyra / GAS): extract killer from DeathInfo.ContextHandle via UAbilitySystemBlueprintLibrary
    local ok_gas, gas_ps = pcall(function()
        local asc_lib = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
        if not IsValidObj(asc_lib) then return nil end

        local death_info = SafeProp(health_comp, "DeathInfo")
        if death_info == nil then
            local ok_di, di_res = SafeCall(health_comp, "GetDeathInfo")
            if ok_di then death_info = di_res end
        end
        if death_info == nil then return nil end

        local ctx = nil
        pcall(function() ctx = death_info.ContextHandle end)
        if ctx == nil then return nil end

        for _, fn_name in ipairs({
            "EffectContextGetOriginalInstigatorActor",
            "EffectContextGetInstigatorActor",
            "EffectContextGetEffectCauser",
        }) do
            local ok_c, actor = pcall(function() return asc_lib[fn_name](asc_lib, ctx) end)
            if ok_c and IsValidObj(actor) then
                local ps = ExtractPlayerStateFromActor(actor, 0)
                if IsValidObj(ps) then
                    DebugLog("Resolved killer via " .. fn_name .. " -> " .. GetPlayerName(ps))
                    return ps
                end
            end
        end
        return nil
    end)
    if ok_gas and IsValidObj(gas_ps) then
        return gas_ps
    end

    -- 2. Secondary: UGF1047HealthComponent::GetLastDamagedBy()
    local ok, dmg_by = SafeCall(health_comp, "GetLastDamagedBy")
    if ok and IsValidObj(dmg_by) then
        local ps = ExtractPlayerStateFromActor(dmg_by, 0)
        if IsValidObj(ps) then
            DebugLog("Resolved killer via GetLastDamagedBy -> " .. GetPlayerName(ps))
            return ps
        end
    end

    DebugLog("Could not resolve killer PlayerState (suicide/environment or empty context).")
    return nil
end

local function HandlePlayerDeath(gs, victim_ps, killer_ps)
    if not Config.enabled or not IsValidObj(victim_ps) then return end
    if not IsValidObj(gs) or not IsHostingMatch(gs) then return end

    local map_name     = GetCurrentMapName(gs)
    local victim_bot   = IsPlayerStateBot(victim_ps)
    local victim_name  = GetPlayerName(victim_ps)
    local killer_valid = IsValidObj(killer_ps) and (SafeGetAddress(killer_ps) ~= SafeGetAddress(victim_ps))
    local killer_name  = killer_valid and GetPlayerName(killer_ps) or nil
    local killer_bot   = killer_valid and IsPlayerStateBot(killer_ps) or false

    -- 1. Bot died -> roll death_chat_chance
    if victim_bot and Config.death_chat_enabled then
        local roll = math.random()
        local chance = tonumber(Config.death_chat_chance) or 0.30
        if roll <= chance then
            local delay = RandomInt(Config.death_delay_min_ms or 1200, Config.death_delay_max_ms or 3000)
            ScheduleBotMessage(victim_ps, "on_death", {
                killer = killer_name,
                map = map_name,
            }, delay, false)
        end
    end

    -- 2. Bot got a kill -> roll kill_chat_chance
    if killer_bot and Config.kill_chat_enabled then
        local roll = math.random()
        local chance = tonumber(Config.kill_chat_chance) or 0.12
        if roll <= chance then
            local delay = RandomInt(Config.kill_delay_min_ms or 1400, Config.kill_delay_max_ms or 3200)
            ScheduleBotMessage(killer_ps, "on_kill", {
                victim = victim_name,
                map = map_name,
            }, delay, false)
        end
    end
end

--------------------------------------------------------------------------------
-- Host Chat Commands (!botchat on / off, !botreload, !bottest)
--------------------------------------------------------------------------------
local function ForceTestBotMessage()
    local gs = GetGameState(true)
    if not IsValidObj(gs) then
        Log("bc_test: No active GameState found (load into a match/lobby first).")
        return
    end
    local bots = GetLobbyBots(gs)
    if #bots == 0 then
        local all_ps = GetAllPlayerStates(gs)
        Log(string.format("bc_test: No AI bots (bIsABot == true) found (total PlayerStates=%d, GameState=%s).", #all_ps, gs:GetFullName()))
        for idx, ps in ipairs(all_ps) do
            Log(string.format("  Player[%d]: '%s' | bIsABot=%s", idx, GetPlayerName(ps), tostring(IsPlayerStateBot(ps))))
        end
        return
    end
    local bot = bots[math.random(1, #bots)]
    local raw = PickPhrase("pre_match") or "Testing BotChatter!"
    local msg = FormatPhrase(raw, {
        bot = GetPlayerName(bot),
        killer = "Host",
        victim = "Target",
        map = GetCurrentMapName(gs),
    })
    DispatchBotChat(bot, msg, true)
end

local function ProcessHostCommandText(raw_text)
    if type(raw_text) ~= "string" or raw_text == "" then return false end
    local cmd = Trim(raw_text):lower()
    if cmd == "!botchat on" then
        Config.enabled = true
        Log("Host command: BotChatter ENABLED.")
        return true
    elseif cmd == "!botchat off" then
        Config.enabled = false
        Log("Host command: BotChatter DISABLED.")
        return true
    elseif cmd == "!botreload" then
        LoadConfigAndPhrases("chat-command")
        return true
    elseif cmd == "!bottest" then
        ForceTestBotMessage()
        return true
    elseif cmd == "!botnames" or cmd == "!botrename" then
        local gs = GetGameState(true)
        local n = ApplyCustomBotNames(gs, true)
        Log("Host command: Reroll custom bot names -> renamed " .. tostring(n) .. " bot(s).")
        return true
    end
    return false
end

local function PollHostChatCommands()
    pcall(function()
        local vm = GetTextChatVM(false)
        if not IsValidObj(vm) then return end
        local entries = vm.ChatEntries
        if not entries then return end

        local count = entries:GetArrayNum()
        if count < State.last_chat_entry_cnt then
            -- Chat list cleared (e.g. map transition)
            State.last_chat_entry_cnt = 0
            State.processed_chat_cmds = {}
        end
        if count <= State.last_chat_entry_cnt then return end

        entries:ForEach(function(index, elem)
            if index > State.last_chat_entry_cnt then
                local entry = elem:get()
                if IsValidObj(entry) then
                    local addr = SafeGetAddress(entry)
                    if addr ~= 0 and not State.processed_chat_cmds[addr] then
                        State.processed_chat_cmds[addr] = true
                        if GetBool(SafeProp(entry, "bSenderIsLocalPlayer")) then
                            local msg = SafeToString(SafeProp(entry, "Message"))
                            ProcessHostCommandText(msg)
                        end
                    end
                end
            end
        end)
        State.last_chat_entry_cnt = count
    end)
end

--------------------------------------------------------------------------------
-- Match Phase & Player Death Polling (100% Safe Without Native Function Hooks)
--------------------------------------------------------------------------------
local function ResetMatchTracking(new_gs_addr)
    State.last_game_state_addr = new_gs_addr
    if new_gs_addr == 0 then
        State.cached_game_state = nil
        State.cached_text_chat_vm = nil
    end
    State.last_phase_key       = ""
    State.pre_match_fired      = false
    State.match_end_fired      = false
    State.was_in_progress      = false
    State.player_alive_cache   = {}
    State.player_hc_cache      = {}
    State.renamed_bots         = {}
    State.used_bot_names       = {}
    State.name_queue           = {}
    DebugLog("Detected new GameState (0x" .. string.format("%X", new_gs_addr) .. "), reset match state tracking.")
end

local function GetCurrentPhaseInfo(gs)
    local block_tag = ""
    local ok_blk, blk = pcall(function() return gs.CurrentExperienceBlock end)
    if ok_blk and blk ~= nil then
        block_tag = SafeToString(SafeProp(blk, "TagName"))
    end

    local match_state = SafeToString(SafeProp(gs, "MatchState"))

    local in_progress = false
    local ok_ip, ip_res = SafeCall(gs, "IsMatchInProgress")
    if ok_ip then
        in_progress = GetBool(ip_res)
    elseif match_state == "InProgress" then
        in_progress = true
    end

    return block_tag, match_state, in_progress
end

local function PollMatchAndPlayers()
    local gs = GetGameState()
    if not IsValidObj(gs) then
        if State.last_game_state_addr ~= 0 then
            ResetMatchTracking(0)
        end
        return
    end

    local gs_addr = SafeGetAddress(gs)
    if gs_addr ~= State.last_game_state_addr then
        ResetMatchTracking(gs_addr)
    end

    -- Monitor host chat commands even if not currently in active combat
    PollHostChatCommands()

    if not IsHostingMatch(gs) then
        return
    end

    -- 0. Apply custom bot names from bot_names.json BEFORE any chat messages fire
    ApplyCustomBotNames(gs, false)

    -- 1. Match Phase / Warmup / End Detection
    local block_tag, match_state, in_progress = GetCurrentPhaseInfo(gs)
    local phase_key = block_tag .. "|" .. match_state .. "|" .. tostring(in_progress)
    local lower_tag = (block_tag .. " " .. match_state):lower()

    if phase_key ~= State.last_phase_key then
        DebugLog("Phase transition: '" .. State.last_phase_key .. "' -> '" .. phase_key .. "'")
        State.last_phase_key = phase_key
    end

    local is_pre_match = lower_tag:find("warmup", 1, true)
        or lower_tag:find("prematch", 1, true)
        or lower_tag:find("pregame", 1, true)
        or lower_tag:find("countdown", 1, true)
        or lower_tag:find("waiting", 1, true)
        or lower_tag:find("intro", 1, true)

    local is_post_match = lower_tag:find("postgame", 1, true)
        or lower_tag:find("postmatch", 1, true)
        or lower_tag:find("endofmatch", 1, true)
        or lower_tag:find("matchend", 1, true)
        or lower_tag:find("gameover", 1, true)

    -- Trigger pre_match burst once when entering warmup/countdown OR when match starts with bots present
    if Config.pre_match_enabled and not State.pre_match_fired then
        local bots = GetLobbyBots(gs)
        if #bots > 0 and (is_pre_match or in_progress) then
            State.pre_match_fired = true
            TriggerLobbyBurst(
                gs,
                "pre_match",
                Config.pre_match_min_bots or 1,
                Config.pre_match_max_bots or 3,
                Config.pre_match_delay_min_ms or 1500,
                Config.pre_match_delay_max_ms or 5500
            )
        end
    end

    if in_progress then
        State.was_in_progress = true
    end

    -- Trigger match_end burst once when transitioning from InProgress -> PostGame/MatchEnd
    if Config.match_end_enabled and not State.match_end_fired then
        if is_post_match or (State.was_in_progress and not in_progress and block_tag ~= "") then
            State.match_end_fired = true
            TriggerLobbyBurst(
                gs,
                "match_end",
                Config.match_end_min_bots or 1,
                Config.match_end_max_bots or 3,
                Config.match_end_delay_min_ms or 1200,
                Config.match_end_delay_max_ms or 4500
            )
        end
    end

    -- 2. Bot Death & Kill Polling
    if not Config.death_chat_enabled and not Config.kill_chat_enabled then
        return
    end

    local players = GetAllPlayerStates(gs)
    for _, ps in ipairs(players) do
        local addr = SafeGetAddress(ps)
        if addr ~= 0 then
            local pawn = SafeProp(ps, "PawnPrivate")
            local hc = IsValidObj(pawn) and SafeProp(pawn, "HealthComponent") or nil
            if IsValidObj(hc) then
                State.player_hc_cache[addr] = hc
            elseif IsValidObj(State.player_hc_cache[addr]) then
                hc = State.player_hc_cache[addr]
            end
            local is_alive = nil

            if IsValidObj(hc) then
                local death_info = SafeProp(hc, "DeathInfo")
                if death_info ~= nil then
                    local ds = SafeProp(death_info, "DeathState")
                    if type(ds) == "number" then
                        is_alive = (ds == 0) -- EGF1047DeathState::NotDead = 0
                    end
                end
                if is_alive == nil then
                    local ok_a, a_res = SafeCall(hc, "IsAlive")
                    if ok_a and a_res ~= nil then
                        is_alive = GetBool(a_res)
                    end
                end
            else
                local ok_psa, psa_res = SafeCall(ps, "IsAlive")
                if ok_psa and psa_res ~= nil then
                    is_alive = GetBool(psa_res)
                end
            end

            if is_alive ~= nil then
                local prev = State.player_alive_cache[addr]
                if prev == true and is_alive == false then
                    local killer_ps = ResolveAttackerPlayerState(hc)
                    HandlePlayerDeath(gs, ps, killer_ps)
                end
                State.player_alive_cache[addr] = is_alive
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Optional ProcessEvent Hooks (Disabled by Default on Splitgate 2)
--------------------------------------------------------------------------------
local function TryRegisterOptionalHooks()
    if State.hooks_registered or not Config.enable_event_hooks then
        return
    end
    State.hooks_registered = true

    -- Hook MulticastChatMessage to catch host chat commands immediately
    local chat_fn = Config.chat_broadcast_function or "/Script/PortalWarsCore.PortalWarsGameStateBaseV2:MulticastChatMessage"
    local ok_chat, err_chat = pcall(function()
        RegisterHook(chat_fn, function(_, _, FromPlayerParam, MessageParam)
            local ok_m, msg_txt = pcall(function() return MessageParam:get():ToString() end)
            if ok_m and msg_txt then
                ProcessHostCommandText(msg_txt)
            end
        end)
    end)
    DebugLog("Optional hook '" .. chat_fn .. "': " .. (ok_chat and "OK" or ("skipped: " .. tostring(err_chat))))

    -- Hook K2_OnSetMatchState if present
    local ok_ms, err_ms = pcall(function()
        RegisterHook("/Script/Engine.GameMode:K2_OnSetMatchState", function(_, NewStateParam)
            local new_state = SafeToString(NewStateParam:get())
            DebugLog("Hook K2_OnSetMatchState -> " .. new_state)
            local gs = GetGameState()
            if new_state == "WaitingToStart" and Config.pre_match_enabled and not State.pre_match_fired then
                State.pre_match_fired = true
                TriggerLobbyBurst(gs, "pre_match", Config.pre_match_min_bots, Config.pre_match_max_bots, Config.pre_match_delay_min_ms, Config.pre_match_delay_max_ms)
            elseif new_state == "WaitingPostMatch" and Config.match_end_enabled and not State.match_end_fired then
                State.match_end_fired = true
                TriggerLobbyBurst(gs, "match_end", Config.match_end_min_bots, Config.match_end_max_bots, Config.match_end_delay_min_ms, Config.match_end_delay_max_ms)
            end
        end)
    end)
    DebugLog("Optional hook 'K2_OnSetMatchState': " .. (ok_ms and "OK" or ("skipped: " .. tostring(err_ms))))
end

--------------------------------------------------------------------------------
-- Diagnostics (bc_inspect)
--------------------------------------------------------------------------------
local function RunInspect()
    Log("========== BotChatter Diagnostics (bc_inspect) ==========")
    Log("Mod Dir:     " .. MOD_DIR)
    Log("Enabled:     " .. tostring(Config.enabled) .. " | HostOnly: " .. tostring(Config.host_only))
    Log("Chat Func:   " .. tostring(Config.chat_broadcast_function))
    local _, resolved_tag, resolved_src = BuildChatChannelTag()
    Log("Channel Tag: " .. tostring(Config.chat_channel_tag) .. " (Enum=" .. tostring(Config.chat_channel_type_enum) .. ") -> Resolved: '" .. tostring(resolved_tag) .. "' [" .. tostring(resolved_src) .. "]")

    local gs = GetGameState(true)
    if IsValidObj(gs) then
        local blk, ms, ip = GetCurrentPhaseInfo(gs)
        local gm_str = "nil"
        pcall(function()
            local gs_lib = GetGameplayStatics()
            if IsValidObj(gs_lib) then
                local gm = gs_lib:GetGameMode(gs)
                if IsValidObj(gm) then gm_str = gm:GetFullName() end
            end
        end)
        Log("GameState:   " .. gs:GetFullName() .. " (via " .. tostring(State.gs_found_via) .. ")")
        Log("GameMode:    " .. gm_str)
        Log("HasAuthority:" .. tostring(IsHostingMatch(gs)) .. " | Map: " .. GetCurrentMapName(gs))
        Log(string.format("Phase Info:  ExperienceBlock='%s' | MatchState='%s' | IsMatchInProgress=%s", blk, ms, tostring(ip)))

        local players = GetAllPlayerStates(gs)
        local bot_count = 0
        Log("Players detected (" .. tostring(#players) .. "):")
        for idx, ps in ipairs(players) do
            local is_bot = IsPlayerStateBot(ps)
            if is_bot then bot_count = bot_count + 1 end
            local pawn = SafeProp(ps, "PawnPrivate")
            local hc = IsValidObj(pawn) and SafeProp(pawn, "HealthComponent") or nil
            local death_state = "n/a"
            if IsValidObj(hc) then
                local di = SafeProp(hc, "DeathInfo")
                if di ~= nil then death_state = tostring(SafeProp(di, "DeathState")) end
            end
            Log(string.format("  [%d] %s | bIsABot=%s | HealthComp=%s | DeathState=%s",
                idx, GetPlayerName(ps), tostring(is_bot), tostring(IsValidObj(hc)), death_state))
        end
        Log("Total AI Bots detected: " .. tostring(bot_count))
    else
        Log("GameState:   <none loaded — enter a match or lobby to inspect live players>")
    end

    -- Extra Finder Diagnostics
    pcall(function()
        local gs_lib = GetGameplayStatics()
        local all_w  = FindAllOf("World")
        local all_ps = FindAllOf("PlayerState")
        local all_gs = FindAllOf("GameStateBase")
        local all_em = FindAllOf("GF1047ExperienceManagerComponent")
        Log(string.format("FinderDiag:  GameplayStatics=%s | Worlds=%d | PlayerStates=%d | GameStateBase=%d | ExpMgrComps=%d",
            tostring(IsValidObj(gs_lib)),
            (type(all_w) == "table" and #all_w or -1),
            (type(all_ps) == "table" and #all_ps or -1),
            (type(all_gs) == "table" and #all_gs or -1),
            (type(all_em) == "table" and #all_em or -1)))
        if type(all_ps) == "table" then
            for i = 1, math.min(#all_ps, 6) do
                local ps = all_ps[i]
                if IsValidObj(ps) then
                    local ok_call, gs_res = pcall(function() return IsValidObj(gs_lib) and gs_lib:GetGameState(ps) or nil end)
                    Log(string.format("  PS[%d] %s | CDO=%s | GS=%s",
                        i, ps:GetFullName(), tostring(IsCDOOrArchetype(ps)),
                        ok_call and (IsValidObj(gs_res) and gs_res:GetFullName() or "nil") or ("ERR:" .. tostring(gs_res))))
                end
            end
        end
    end)

    local vm = GetTextChatVM(true)
    if IsValidObj(vm) then
        local cnt = 0
        pcall(function() cnt = vm.ChatEntries:GetArrayNum() end)
        local out_tag = ""
        pcall(function()
            if IsValidObj(vm.OutgoingChannelVM) then
                out_tag = SafeToString(SafeProp(vm.OutgoingChannelVM.ChannelTag, "TagName"))
            end
        end)
        Log(string.format("TextChatVM:  FOUND (Entries=%d, OutgoingChannelTag='%s')", cnt, out_tag))
    else
        Log("TextChatVM:  <not found>")
    end

    -- Verify key UFunction paths exist in memory
    local fn_paths = {
        "/Script/PortalWarsCore.PortalWarsGameStateBaseV2:MulticastChatMessage",
        "/Script/PortalWarsCore.PortalWarsPlayerController:ClientSendChatMessage",
        "/Script/PortalWarsUI.PortalWarsUIChatHelpers:GetTextChatChannelTagFromChatType",
        "/Script/GameFramework1047.GF1047PlayerState:OnStartDeath",
        "/Script/GameFramework1047.GF1047HealthComponent:GetLastDamagedBy",
        "/Script/GameFramework1047.GF1047GameStateBase:IsMatchInProgress",
        "/Script/Engine.GameMode:K2_OnSetMatchState",
    }
    Log("UFunction Signature Verification:")
    for _, path in ipairs(fn_paths) do
        local fn = StaticFindObject(path)
        Log("  " .. (IsValidObj(fn) and "[OK]   " or "[MISS] ") .. path)
    end
    Log("=========================================================")
end

--------------------------------------------------------------------------------
-- Console Commands & Hotkeys
--------------------------------------------------------------------------------
local function RegisterCommandsAndHotkeys()
    -- UE4SS console commands (active whenever console exec hooks are enabled)
    pcall(function()
        RegisterConsoleCommandHandler("bc_reload", function()
            ExecuteInGameThread(function() LoadConfigAndPhrases("console") end)
            return true
        end)
        RegisterConsoleCommandHandler("bc_test", function()
            ExecuteInGameThread(function() ForceTestBotMessage() end)
            return true
        end)
        RegisterConsoleCommandHandler("bc_inspect", function()
            ExecuteInGameThread(function() RunInspect() end)
            return true
        end)
        RegisterConsoleCommandHandler("bc_rename", function()
            ExecuteInGameThread(function()
                local gs = GetGameState(true)
                local n = ApplyCustomBotNames(gs, true)
                Log("bc_rename: Renamed " .. tostring(n) .. " bot(s).")
            end)
            return true
        end)
        Log("Registered console commands: bc_reload, bc_test, bc_inspect, bc_rename")
    end)

    -- Convenient hotkeys (always work in Splitgate 2 without needing console exec hooks)
    if Config.enable_hotkeys then
        pcall(function()
            RegisterKeyBind(Key.F8, function()
                Log("Hotkey F8 pressed -> running bc_test...")
                ExecuteInGameThread(function() ForceTestBotMessage() end)
            end)
            RegisterKeyBind(Key.F9, function()
                ExecuteInGameThread(function()
                    Config.enabled = not Config.enabled
                    Log("Hotkey F9: BotChatter is now " .. (Config.enabled and "ENABLED" or "DISABLED"))
                end)
            end)
            RegisterKeyBind(Key.F10, function()
                Log("Hotkey F10 pressed -> reloading config & phrases...")
                ExecuteInGameThread(function() LoadConfigAndPhrases("hotkey-F10") end)
            end)
            RegisterKeyBind(Key.F6, function()
                Log("Hotkey F6 pressed -> running bc_inspect...")
                ExecuteInGameThread(function() RunInspect() end)
            end)
            Log("Hotkeys active: F6=Inspect | F8=TestMsg | F9=Toggle | F10=Reload")
        end)
    end
end

--------------------------------------------------------------------------------
-- Startup & Main Polling Loop
--------------------------------------------------------------------------------
LoadConfigAndPhrases("startup")
RegisterCommandsAndHotkeys()
TryRegisterOptionalHooks()

if not State.poll_started then
    State.poll_started = true
    local interval = math.max(100, tonumber(Config.poll_interval_ms) or 250)
    LoopAsync(interval, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(PollMatchAndPlayers)
            if not ok then
                DebugLog("Poll error: " .. tostring(err))
            end
        end)
        return false -- keep looping
    end)
    Log("Started match & bot monitor loop (" .. tostring(interval) .. "ms interval).")
end
