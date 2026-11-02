HitmanGlobalData = {}
HitmanGlobalDataPlayers = {}
HitmanClusters = {}
HitmanClusterCount = 32

local function getClusterName(c)
    return "HitmanC"  .. tostring(c)
end

local function getClusterId(id)
    return math.floor(math.abs(id) % HitmanClusterCount)
end

local function initHitmanModData(isNewGame)

    -- HITMAN GLOBAL MODDATA
    local globalData = ModData.getOrCreate("Hitman")
    if isClient() then
        ModData.request("Hitman")
    end
    
    if not globalData.Scenes then globalData.Scenes = {} end
    if not globalData.Hitmans then globalData.Hitmans = {} end
    if not globalData.Posts then globalData.Posts = {} end
    if not globalData.Bases then globalData.Bases = {} end
    if not globalData.Kills then globalData.Kills = {} end
    if not globalData.VisitedBuildings then globalData.VisitedBuildings = {} end
    if not globalData.Wanderers then globalData.Wanderers = {} end
    HitmanGlobalData = globalData

    -- HITMAN PLAYERS GLOBAL MODDATA
    local globalDataPlayers = ModData.getOrCreate("HitmanPlayers")
    if isClient() then
        ModData.request("HitmanPlayers")
    end
   
    globalDataPlayers.OnlinePlayers = {}
    HitmanGlobalDataPlayers = globalDataPlayers

    -- HITMAN CLUSTERS GLOBAL MODDATA
    for i = 0, HitmanClusterCount - 1 do
        local clusterName = getClusterName(i)
        HitmanClusters[i] = ModData.getOrCreate(clusterName)
        print ("[HITMANS] GMD Cluster " .. clusterName .. " created.")
        if isClient() then
            ModData.request(clusterName)
        end
    end

end

local function loadHitmanModData(key, globalData)
    if isClient() then
        if key and globalData then
            if key == "Hitman" then
                HitmanGlobalData = globalData
            elseif key == "HitmanPlayers" then
                HitmanGlobalDataPlayers = globalData
            end
            for i = 0, HitmanClusterCount - 1 do
                if key == getClusterName(i) then
                    HitmanClusters[i] = globalData
                end
            end
        end
    end
end

function GetHitmanModData()
    return HitmanGlobalData
end

function GetHitmanModDataPlayers()
    return HitmanGlobalDataPlayers
end

function GetHitmanCluster(id)
    return getClusterId(id)
end

function GetHitmanClusterData(id)
    local c = getClusterId(id)
    return HitmanClusters[c]
end

function TransmitHitmanModData()
    ModData.transmit("Hitman")
end

function TransmitHitmanModDataPlayers()
    ModData.transmit("HitmanPlayers")
end

function TransmitHitmanCluster(id)
    local c = getClusterId(id)
    ModData.transmit(getClusterName(c))
end

function TransmitHitmanClusterExpicit(c)
    ModData.transmit(getClusterName(c))
end

local function everyTenMinutes()
    for i = 0, HitmanClusterCount - 1 do
        local globalData = HitmanClusters[i]
        local cnt = 0
        for _, _ in pairs(globalData) do
            cnt = cnt + 1
        end
        -- print ("[HITMANS] GMD Cluster " .. i .. " is " .. cnt .. " long.")
    end
end


Events.OnInitGlobalModData.Add(initHitmanModData)
Events.OnReceiveGlobalModData.Add(loadHitmanModData)

Events.EveryTenMinutes.Remove(everyTenMinutes)
Events.EveryTenMinutes.Add(everyTenMinutes)