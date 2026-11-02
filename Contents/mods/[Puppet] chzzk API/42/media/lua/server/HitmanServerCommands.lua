local getBarricadeAble = function(x, y, z, index)
    local sq = getCell():getGridSquare(x, y, z)
    if sq and index >= 0 and index < sq:getObjects():size() then
        local o = sq:getObjects():get(index)
        if instanceof(o, 'BarricadeAble') then
            return o
        end
    end
    return nil
end

HitmanServer = HitmanServer or {}
HitmanServer.Hitman_Commands = {}

HitmanServer.Hitman_Commands.PostToggle = function(player, args)
    local gmd = GetHitmanModData()
    if not (args.x and args.y and args.z) then return end

    local id = args.x .. "-" .. args.y .. "-" .. args.z
    
    if gmd.Posts[id] then
        gmd.Posts[id] = nil
    else
        gmd.Posts[id] = args
    end
    TransmitHitmanModData()
end

HitmanServer.Hitman_Commands.PostUpdate = function(player, args)
    local gmd = GetHitmanModData()
    if not (args.x and args.y and args.z) then return end

    local id = args.x .. "-" .. args.y .. "-" .. args.z
    gmd.Posts[id] = args
    TransmitHitmanModData()
end

HitmanServer.Hitman_Commands.BaseUpdate = function(player, args)
    local gmd = GetHitmanModData()
    if not (args.x and args.y) then return end

    local id = args.x .. "-" .. args.y
    gmd.Bases[id] = args
    TransmitHitmanModData()
end

HitmanServer.Hitman_Commands.HitmanRemove  = function(player, args)
    local id = args.id
    if id then
        local gmd = GetHitmanClusterData(id)
        if gmd[id] then
            gmd[id] = nil
            -- print ("[INFO] Hitman removed: " .. id)
        end
        TransmitHitmanCluster(id)
    end
end

HitmanServer.Hitman_Commands.HitmanFlush  = function(player, args)
    local gmd = GetHitmanModData()
    gmd.VisitedBuildings = {}
    gmd.Posts = {}
    gmd.Bases = {}
    TransmitHitmanModData()
    print ("[INFO] All hitmans removed!!!")
end

HitmanServer.Hitman_Commands.HitmanUpdatePart = function(player, args)
    local id = args.id
    if id then
        local gmd = GetHitmanClusterData(id)
        if gmd[id] then
            local brain = gmd[id]
            for k, v in pairs(args) do
                brain[k] = v
                -- print ("[INFO] Hitman sync id: " .. id .. " key: " .. k)
            end

            gmd[id] = brain
            TransmitHitmanCluster(id)

            --[[
            local zombie = HitmanZombie.GetInstanceById(id)
            if zombie then
                Hitman.UpdateItemsToSpawnAtDeath(zombie, brain)
            end]]
            --sendServerCommand('Hitman_Commands', 'UpdateHitmanPart', args)
        end
    end
end

HitmanServer.Hitman_Commands.HitmanCorpse = function(player, args)

    local cell = getCell()
    local square = cell:getGridSquare(args.x, args.y, args.z)
    local body
    if square then
        local objects = square:getStaticMovingObjects()
        for i=0, objects:size()-1 do
            local object = objects:get(i)
            if instanceof (object, "IsoDeadBody") then
                local md = object:getModData()
                if md.hitmanBrainId == args.id then
                    body = object
                    break
                end
            end
        end
    end

    if body then
        -- print ("SERVER FOUND DEAD HITMAN BODY")
        body:sync()
        
    end
end

HitmanServer.Hitman_Commands.Unbarricade = function(player, args)
    local object = getBarricadeAble(args.x, args.y, args.z, args.index)
    if object then
        local barricade = object:getBarricadeOnSameSquare()
        if not barricade then barricade = object:getBarricadeOnOppositeSquare() end
        if barricade then
            if barricade:isMetal() then
                local metal = barricade:removeMetal(nil)
            elseif barricade:isMetalBar() then
                local bar = barricade:removeMetalBar(nil)
            else
                local plank = barricade:removePlank(nil)
                if barricade:getNumPlanks() > 0 then
                    barricade:sendObjectChange(IsoObjectChange.STATE)
                end
            end
        end
    end
end

HitmanServer.Hitman_Commands.Barricade = function(player, args)
    local object = getBarricadeAble(args.x, args.y, args.z, args.index)
    if object then
        local barricade = IsoBarricade.AddBarricadeToObject(object, player)
        if barricade then
            if not barricade:isMetal() and args.isMetal then
                local metal = HitmanCompatibility.InstanceItem("Base.SheetMetal")
                metal:setCondition(args.condition)
                barricade:addMetal(nil, metal)
                barricade:transmitCompleteItemToClients()
            elseif not barricade:isMetalBar() and args.isMetalBar then
                local metal = HitmanCompatibility.InstanceItem("Base.MetalBar")
                metal:setCondition(args.condition)
                barricade:addMetalBar(nil, metal)
                barricade:transmitCompleteItemToClients()
            elseif barricade:getNumPlanks() < 4 then
                local plank = HitmanCompatibility.InstanceItem("Base.Plank")
                plank:setCondition(args.condition)
                barricade:addPlank(nil, plank)
                if barricade:getNumPlanks() == 1 then
                    barricade:transmitCompleteItemToClients()
                else
                    barricade:sendObjectChange(IsoObjectChange.STATE)
                end
            end
        end
    else
        noise('expected BarricadeAble')
    end
end

HitmanServer.Hitman_Commands.OpenDoor = function(player, args)
    local sq = getCell():getGridSquare(args.x, args.y, args.z)
    if sq and args.index >= 0 and args.index < sq:getObjects():size() then
        local object = sq:getObjects():get(args.index)
        if instanceof(object, "IsoDoor") or (instanceof(object, 'IsoThumpable') and object:isDoor() == true) then
            if not object:IsOpen() then
                object:ToggleDoorSilent()
            end
        end
    end
end

HitmanServer.Hitman_Commands.CloseDoor = function(player, args)
    local sq = getCell():getGridSquare(args.x, args.y, args.z)
    if sq and args.index >= 0 and args.index < sq:getObjects():size() then
        local object = sq:getObjects():get(args.index)
        if instanceof(object, "IsoDoor") or (instanceof(object, 'IsoThumpable') and object:isDoor() == true) then
            if object:IsOpen() then
                object:ToggleDoorSilent()
            end
        end
    end
end

HitmanServer.Hitman_Commands.LockDoor = function(player, args)
    local sq = getCell():getGridSquare(args.x, args.y, args.z)
    if sq and args.index >= 0 and args.index < sq:getObjects():size() then
        local object = sq:getObjects():get(args.index)
        if instanceof(object, "IsoDoor") or (instanceof(object, 'IsoThumpable') and object:isDoor() == true) then
            if not object:isLockedByKey() then
                object:setLockedByKey(true)
            end
        end
    end
end

HitmanServer.Hitman_Commands.UnlockDoor = function(player, args)
    local sq = getCell():getGridSquare(args.x, args.y, args.z)
    if sq and args.index >= 0 and args.index < sq:getObjects():size() then
        local object = sq:getObjects():get(args.index)
        if instanceof(object, "IsoDoor") or (instanceof(object, 'IsoThumpable') and object:isDoor() == true) then
            if object:isLockedByKey() then
                object:setLockedByKey(false)
            end
        end
    end
end

HitmanServer.Hitman_Commands.VehiclePartRemove = function(player, args)
    local sq = getCell():getGridSquare(args.x, args.y, 0)
    if sq then
        local vehicle = sq:getVehicleContainer()
        if vehicle then
            local vehiclePart = vehicle:getPartById(args.id)
            if vehiclePart then
                vehiclePart:setInventoryItem(nil)
                vehicle:transmitPartItem(vehiclePart)
                vehicle:updatePartStats()
            end
        end
    end
end

HitmanServer.Hitman_Commands.VehiclePartDamage = function(player, args)
    local sq = getCell():getGridSquare(args.x, args.y, 0)
    if sq then
        local vehicle = sq:getVehicleContainer()
        if vehicle then
            local vehiclePart = vehicle:getPartById(args.id)
            if vehiclePart then
                vehiclePart:damage(args.dmg)

                if vehiclePart:getCondition() <= 0 then
                    vehiclePart:setInventoryItem(nil)
                    vehicle:transmitPartItem(vehiclePart)
                else
                    vehicle:transmitPartCondition(vehiclePart)
                end
                vehicle:updatePartStats()
            end
        end
    end
end

HitmanServer.Hitman_Commands.IncrementHitmanKills = function(player, args)
    local gmd = GetHitmanModData()
    local id = HitmanUtils.GetCharacterID(player)
    if gmd.Kills[id] then
        gmd.Kills[id] = gmd.Kills[id] + 1
    else
        gmd.Kills[id] = 1
    end
    TransmitHitmanModData()
end

HitmanServer.Hitman_Commands.ResetHitmanKills = function(player, args)
    local gmd = GetHitmanModData()
    local id = HitmanUtils.GetCharacterID(player)
    if gmd.Kills[id] then
        gmd.Kills[id] = 0
    end
    TransmitHitmanModData()
end

HitmanServer.Hitman_Commands.UpdateVisitedBuilding = function(player, args)
    local gmd = GetHitmanModData()
    gmd.VisitedBuildings[args.bid] = args.wah
    TransmitHitmanModData()
end

HitmanServer.Hitman_Commands.WakeEveryone = function(player, args)
    local playerList = getOnlinePlayers()
    if not playerList then return end

    for i=0, playerList:size()-1 do
        local p = playerList:get(i)
        if p then
            p:forceAwake()
        end
    end
end

HitmanServer.Hitman_Commands.PlayerDamage = function(player, args)
    local bodyDamage = player:getBodyDamage()
    local stats = player:getStats()
    local health = bodyDamage:getOverallBodyHealth()

    if args.healthDrop then
        bodyDamage:ReduceGeneralHealth(args.healthDrop)
    end

    if args.intoxication then
        stats:set(CharacterStat.INTOXICATION, args.intoxication)
    end

    if args.sickness then
        stats:set(CharacterStat.FOOD_SICKNESS, args.sickness)
    end

    if args.bodyPartIndex then
        local bodyPart = bodyDamage:getBodyParts():get(args.bodyPartIndex)
        local bloodBodyPart = BloodBodyPartType.FromIndex(args.bodyPartIndex)
        
        if args.scratched then
            bodyPart:setScratched(true, true)
        end

        if args.cut then
            bodyPart:setCut(true)
        end

        if args.deepWound then
            bodyPart:generateDeepWound()
        end

        if args.bullet then
            bodyPart:setHaveBullet(true, 1)
        end

        if args.blood then
            player:addBlood(bloodBodyPart, false, true, false)
        end

        if args.hole and args.holeAllLayers then
            player:addHole(bloodBodyPart, args.holeAllLayers)
        end
    end
end

local onClientCommand = function(module, command, player, args)
    if module == "Hitman_Commands" and HitmanServer[module] and HitmanServer[module][command] then
        local argStr = ""
        for k, v in pairs(args) do
            argStr = argStr .. " " .. k .. "=" .. tostring(v)
        end
        -- print ("received " .. module .. "." .. command .. " "  .. argStr)
        HitmanServer[module][command](player, args)
    end
end

Events.OnClientCommand.Add(onClientCommand)
