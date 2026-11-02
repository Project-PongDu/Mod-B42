require "HitmanCompatibility"
HitmanCustom = HitmanCustom or {}

HitmanCustom.hitmanData = {}
HitmanCustom.clanData = {}

-- HitmanCustom.filePath = getFileSeparator() .. "media" .. getFileSeparator() .. "hitmans" .. getFileSeparator()
HitmanCustom.filePath = HitmanCompatibility.GetConfigPath()
HitmanCustom.clanFile = "clans.txt"
HitmanCustom.hitmanFile = "hitmans.txt"

HitmanCustom.clanAdjectives =
{
    "Ruthless",
    "Savage",
    "Vicious",
    "Feral",
    "Brutal",
    "Merciless",
    "Bloodthirsty",
    "Relentless",
    "Fierce",
    "Deadly",
    "Broken",
    "Black",
    "Red",
    "Grey",
    "Dead",
    "Silent",
    "Wild",
    "Lost",
    "Burned",
    "Cold",
    "Dark",
    "Bleeding",
    "Hungry",
    "Fallen",
    "Forsaken",
    "Savage",
    "Brutal",
    "Ruthless",
    "Restless",
    "Desperate",
    "Vicious",
    "Feral",
    "Cruel",
    "Angry",
    "Mad",
    "Scarred",
    "Wounded",
    "Bitter",
    "Lonely",
    "Dying",
    "Rotten",
    "Ashen",
    "Dusty",
    "Iron",
    "Bloody",
    "Grim",
    "Hollow",
    "Shattered",
    "Forgotten",
    "Wandering",
}

HitmanCustom.clanNouns =
{
    "Hitmans",
    "Raiders",
    "Outlaws",
    "Marauders",
    "Scavengers",
    "Wanderers",
    "Vagabonds",
    "Nomads",
    "Rogues",
    "Thieves",
    "Brigands",
    "Reavers",
    "Prowlers",
    "Lurkers",
    "Predators",
    "Assassins",
    "Hunters",
    "Stalkers",
    "Vultures",
    "Wolves",
    "Hounds",
    "Crows",
    "Ravens",
    "Vultures",
    "Rats",
    "Snakes",
    "Jackals",
    "Dogs",
    "Bears",
    "Boars",
    "Hawks",
    "Rangers",
    "Raiders",
    "Hunters",
    "Killers",
    "Butchers",
    "Thieves",
    "Scavengers",
    "Marauders",
    "Outcasts",
    "Drifters",
    "Wanderers",
    "Strays",
    "Nomads",
    "Survivors",
    "Holdouts",
    "Runaways",
    "Exiles",
    "Rebels",
    "Deserters",
    "Renegades",
    "Vagabonds",
    "Highwaymen",
    "Outlaws",
    "Hitmans",
    "Robbers",
    "Looters",
    "Rogues",
    "Misfits",
    "Fugitives",
    "Strangers",
    "Ghosts",
    "Shadows",
    "Deadmen",
    "Ashwalkers",
    "Bloodhands",
    "Roadmen",
    "Wastrels",
}

local saveFile = function()
    local mods = HitmanCustom.GetMods()
    table.insert(mods, "LOCAL")

    local globalClanFileName = HitmanCustom.filePath .. HitmanCustom.clanFile
    local globalClanFile = getFileWriter(globalClanFileName, true, false)
    local globalClanOutput = ""

    for i=1, #mods do
        local modid = mods[i]
        local hitmanFileName
        local hitmanFile
        local clanFileName
        local clanFile
        if modid == "LOCAL" then
            hitmanFileName = HitmanCustom.filePath .. HitmanCustom.hitmanFile
            hitmanFile = getFileWriter(hitmanFileName, true, false)
        else
            hitmanFileName = HitmanCustom.filePath .. HitmanCustom.hitmanFile
            hitmanFile = getModFileWriter(modid, hitmanFileName, true, false)
            clanFileName = HitmanCustom.filePath .. HitmanCustom.clanFile
            clanFile = getModFileWriter(modid, clanFileName, true, false)
        end

        if hitmanFile then
            local data = HitmanCustom.hitmanData
            local hitmanOutput = ""
            local clanOutput = ""
            local cids = {}
            for id, sections in pairs(data) do
                if sections.general.modid == modid then

                    hitmanOutput = hitmanOutput .. "[" .. id .. "]\n"
                    for sname, tab in pairs(sections) do
                        for k, v in pairs(tab) do
                            hitmanOutput = hitmanOutput .. "\t" .. sname .. ": " .. k .. " = " .. tostring(v) .. "\n"
                        end
                    end
                    hitmanOutput = hitmanOutput .. "\n"

                    local cid = sections.general.cid
                    if not cids[cid] then
                        local clanData = HitmanCustom.clanData[cid]
                        if not clanData then
                            clanData = HitmanCustom.ClanCreate(cid)
                        end
                        local o = ""
                        o = o .. "[" .. cid .. "]\n"
                        for sname, tab in pairs(clanData) do
                            for k, v in pairs(tab) do
                                o = o .. "\t" .. sname .. ": " .. k .. " = " .. tostring(v) .. "\n"
                            end
                        end
                        o = o .. "\n"

                        clanOutput = clanOutput .. o
                        globalClanOutput = globalClanOutput .. o
                        cids[cid] = true
                    end
                end
            end
            hitmanFile:write(hitmanOutput)
            hitmanFile:close()

            if clanFile then
                clanFile:write(clanOutput)
                clanFile:close()
            end
        end
    end

    if globalClanFile then
        globalClanFile:write(globalClanOutput)
        globalClanFile:close()
    end
end

local loadFile = function(dataKey, fileName)

    local function splitString(input, separator)
        local result = {}
        for match in (input .. separator):gmatch("(.-)" .. separator) do
            table.insert(result, match:match("^%s*(.-)%s*$")) -- Trim spaces
        end
        return result
    end

    local types = {}

    local modList = {}
    local mods = getActivatedMods()
    for i=0, mods:size()-1 do
        local modid = mods:get(i):gsub("^\\", "")

        if modid == "Hitmans2" and isIngameState() then
            if Hitman.Settings.OriginalHitmans then
                table.insert(modList, modid)
            end
        else
            table.insert(modList, modid)
        end

    end

    -- LOCAL needs to load last so it remains untouched by other mods!
    table.insert(modList, "LOCAL")

    for i=1, #modList do
        local modid = modList[i]

        local file
        if modid == "LOCAL" then
            file  = getFileReader(fileName, false)
        else
            file  = getModFileReader(modid, fileName, false)
        end

        if file then 
            local line
            local id
            while true do
                line = file:readLine()
                if line == nil then
                    file:close()
                    break
                end

                -- guid match
                if line:match("%[(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)%]") then
                    id = line:match("%[(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)%]")
                end

                -- format:
                -- section: key=value
                local s, k, v = line:match("([%w_]+)%s*:%s*([%w_]+)%s*=%s*([^ \n]*)")
                if id and k and v then
                    if v == "true" then 
                        v = true 
                    elseif v == "false" then
                        v = false 
                    elseif v:match("^%-?%d+%.?%d*$") then 
                        v = tonumber(v) 
                    end

                    if not HitmanCustom[dataKey][id] then
                        HitmanCustom[dataKey][id] = {}
                    end

                    if not HitmanCustom[dataKey][id][s] then
                        HitmanCustom[dataKey][id][s] = {}
                    end

                    if types[k] == "array" then
                        HitmanCustom[dataKey][id][s][k] = splitString(v, ",")
                    else
                        HitmanCustom[dataKey][id][s][k] = v
                    end
                    --print ("HitmanCustom.hitmanData[" .. id .. "][" .. k .. "] = " .. v)
                end
            end
        end
    end
end

HitmanCustom.GetMods = function()
    local ret = {}
    local mods = getActivatedMods()
    local fileName = HitmanCustom.filePath .. HitmanCustom.hitmanFile
    for i=0, mods:size()-1 do
        local modid = mods:get(i):gsub("^\\", "")
        local file = getModFileReader(modid, fileName, false)
        if file then
            table.insert(ret, modid)
            file:close()
        end
    end
    return ret
end

HitmanCustom.Load = function()
    HitmanCustom.hitmanData = {}
    HitmanCustom.clanData = {}
    loadFile("hitmanData", HitmanCustom.filePath .. HitmanCustom.hitmanFile)
    loadFile("clanData", HitmanCustom.filePath .. HitmanCustom.clanFile)
end

HitmanCustom.Save = function()
    saveFile()
end

-- clan methods
HitmanCustom.ClanCreate = function(cid)
    local data = {}
    data.general = {}
    data.general.name = HitmanUtils.Choice(HitmanCustom.clanAdjectives) .. "_" .. HitmanUtils.Choice(HitmanCustom.clanNouns)
	data.spawn = {}
	data.spawn.friendly = false
	data.spawn.companion = false
	data.spawn.defenders = false
	data.spawn.campers = false
	data.spawn.assault = true
	data.spawn.wanderer = false
	data.spawn.roadblock = false
	data.spawn.dayStart = 0
	data.spawn.dayEnd = 10000
	data.spawn.spawnChance = 1
	data.spawn.groupMin = 1
	data.spawn.groupMax = 10
	data.spawn.zone = 0
    HitmanCustom.clanData[cid] = data
    return HitmanCustom.clanData[cid]
end

HitmanCustom.Delete = function(cid)
    HitmanCustom.clanData[cid] = nil
end

HitmanCustom.ClanGetAll = function()
    return HitmanCustom.clanData
end

HitmanCustom.ClanGetAllSorted = function()
    local allData = HitmanCustom.clanData
    local keys = {}
    for key in pairs(allData) do
        table.insert(keys, key)
    end

    table.sort(keys, function(k1, k2)
        return allData[k1].general.name < allData[k2].general.name
    end)

    local allDataSorted = {}
    for _, key in ipairs(keys) do
        allDataSorted[key] = allData[key]
    end
    return allDataSorted
end

HitmanCustom.ClanGet = function(cid)
    return HitmanCustom.clanData[cid]
end

-- hitman methods
HitmanCustom.Create = function(bid)
    local data = {}
    data.general = {}
    data.general.name = "Hitman_" .. ZombRand(1000000)
    data.general.female = false
    data.general.skin = 1
    data.general.hairType = 1
    data.general.beardType = 1
    data.general.hairColor = 1
    data.clothing = {}
    data.tint = {}
    data.weapons = {}
    data.ammo = {}
    data.bag = {}

    HitmanCustom.hitmanData[bid] = data
    return HitmanCustom.hitmanData[bid]
end

HitmanCustom.Delete = function(bid)
    HitmanCustom.hitmanData[bid] = nil
end

HitmanCustom.GetNextId = function(bid)
    --[[
    local newid = 0
    for id, _ in pairs(HitmanCustom.hitmanData) do
        if id > newid then
            newid = id
        end
    end
    return newid + 1
    ]]
    return getRandomUUID()
end

HitmanCustom.GetAll = function()
    return HitmanCustom.hitmanData
end

HitmanCustom.GetFromClan = function(cid)
    local ret = {}
    for bid, data in pairs(HitmanCustom.hitmanData) do
        if data.general.cid == cid then
            ret[bid] = data
        end
    end
    return ret
end

HitmanCustom.GetById = function(bid)
    return HitmanCustom.hitmanData[bid]
end

HitmanCustom.GetFromClanSorted = function(cid)
    local allData = {}
    for bid, data in pairs(HitmanCustom.hitmanData) do
        if data.general.cid == cid then
            allData[bid] = data
        end
    end

    local keys = {}
    for key in pairs(allData) do
        table.insert(keys, key)
    end

    table.sort(keys, function(k1, k2)
        return allData[k1].general.name < allData[k2].general.name
    end)

    local allDataSorted = {}
    for _, key in ipairs(keys) do
        allDataSorted[key] = allData[key]
    end
    return allDataSorted
   
end

HitmanCustom.Get = function(bid)
    return HitmanCustom.hitmanData[bid]
end

HitmanCustom.GetStats = function()
    local clanData = HitmanCustom.clanData
    local clanCount = 0
    for cid, clan in pairs(clanData) do
        clanCount = clanCount + 1
    end

    local hitmanData = HitmanCustom.hitmanData
    local hitmanCount = 0
    for bid, hitman in pairs(hitmanData) do
        hitmanCount = hitmanCount + 1
    end

    local stats = {}
    stats.clanCount = clanCount
    stats.hitmanCount = hitmanCount
    return stats
end

local function onGameStart()
    HitmanCustom.Load()
end

Events.OnGameStart.Add(onGameStart)