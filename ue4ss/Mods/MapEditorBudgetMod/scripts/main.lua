local MOD_PREFIX = "[MapEditorBudgetMod] "

local function Log(msg)
    print(MOD_PREFIX .. tostring(msg) .. "\n")
end

local function LoadConfig()
    package.loaded["config"] = nil
    local ok, cfg = pcall(require, "config")
    if ok and type(cfg) == "table" and type(cfg.BudgetLimit) == "number" then
        return cfg
    end
    Log("WARNING: Could not load config.lua, falling back to BudgetLimit = 10000")
    return { BudgetLimit = 10000 }
end

local function FindCC1047Config()
    local obj = StaticFindObject("/Script/CreativeCore1047.Default__CC1047Config")
    if obj and obj:IsValid() then
        return obj
    end
    obj = FindFirstOf("CC1047Config")
    if obj and obj:IsValid() then
        return obj
    end
    return nil
end

local function ApplyBudget(reason)
    local ok, err = pcall(function()
        local userCfg = LoadConfig()
        local targetLimit = math.floor(userCfg.BudgetLimit)

        local ccCfg = FindCC1047Config()
        if not ccCfg then
            Log("(" .. reason .. ") CC1047Config not found yet.")
            return
        end

        local before = ccCfg.BudgetLimit
        if before == targetLimit then
            Log("(" .. reason .. ") BudgetLimit is already " .. tostring(before) .. ".")
            return
        end

        ccCfg.BudgetLimit = targetLimit
        local after = ccCfg.BudgetLimit
        Log("(" .. reason .. ") BudgetLimit changed: " .. tostring(before) .. " -> " .. tostring(after))
    end)

    if not ok then
        Log("ERROR (" .. reason .. "): " .. tostring(err))
    end
end

Log("Loaded! Applying custom Map Editor budget limit...")
ApplyBudget("startup")

-- Re-check once after engine/config initialization finishes
ExecuteWithDelay(5000, function()
    ApplyBudget("delayed-5s")
end)

-- Allow live reload from config.lua via F7
pcall(function()
    RegisterKeyBind(Key.F7, function()
        ExecuteInGameThread(function()
            ApplyBudget("hotkey-F7")
        end)
    end)
    Log("Press F7 in-game to reload config.lua and re-apply BudgetLimit.")
end)
