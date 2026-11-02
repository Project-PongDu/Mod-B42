--
-- ********************************
-- *** Zombie Hitmans           ***
-- ********************************
-- *** Coded by: Slayer         ***
-- ********************************
--

HitmanMenu = HitmanMenu or {}

function HitmanMenu.AddWandererGroup(player, square)

    local cids = {
        "2681ecf5-d0d9-481d-b769-7c4fb626eb81",
        "a2dec2f0-c76d-4640-8a71-733a547a1ebc",
        "bf5985eb-7cb0-44ba-8392-f656ffe421f4",
    }
    local group = {}
    group.x = square:getX()
    group.y = square:getY()
    group.z = square:getZ()
    group.cid = HitmanUtils.Choice(cids)
    group.size = 1 + ZombRand(5)
    HitmanServer.Wanderers.AddGroup(group)
end

function HitmanMenu.Tent(player, square)
    local sx = square:getX()
    local sy = square:getY()
    local sz = square:getZ()

    HitmanBasePlacements.Tent(sx, sy, sz)
end


function HitmanMenu.Map(player)
    if HitmanMenu.mapInstance then
        HitmanMenu.mapInstance:removeFromUIManager()
        HitmanMenu.mapInstance = nil
    else
        local map = HitmanMap:new(200, 200, 800, 800, nil, "Hitman Map")
        map:initialise()
        map:addToUIManager()
        HitmanMenu.mapInstance = map
    end
end

function HitmanMenu.HitmanTest (player)
    HitmanTest.Check()
end

function HitmanMenu.TestAction (player, square, zombie)

    local task = {action="Time", anim="TEST", time=400}
    Hitman.AddTask(zombie, task)
end

function HitmanMenu.MakeProcedure (player, square)
    local cell = getCell()

    local sx = square:getX() - 10
    local sy = square:getY() - 10
    local sz = square:getZ()

    local w = 60
    local h = 60

    local lines = {}

    table.insert(lines, "require \"MysteryPlacements\"\n")
    table.insert(lines, "\n")
    table.insert(lines, "function ProcMedicalTent (sx, sy, sz)\n")
    
    for x = 0, w do
        for y = 0, h do
            for z = 0, 0 do
                local square = cell:getGridSquare(sx + x, sy + y, sz + z)
                if square then
                    local objects = square:getObjects()

                    for i=0, objects:size()-1 do
                        local object = objects:get(i)
                        if object then

                            local objectType = object:getType()
                            local spriteName = object:getSprite():getName()
                            local spriteProps = object:getSprite():getProperties()

                            local isSolidFloor = spriteProps:has(IsoFlagType.solidfloor)
                            local isAttachedFloor = spriteProps:has(IsoFlagType.attachedFloor)
                            local isExterior = spriteProps:has(IsoFlagType.exterior)
                            local isCanBeRemoved = spriteProps:has(IsoFlagType.canBeRemoved)
                            
                            if spriteName then
                                --[[if isSolidFloor and isExterior and not isAttachedFloor then
                                    --nature floor - skip it
                                    print ("nature floor")
                                elseif objectType == IsoObjectType.tree then
                                    print ("tree")

                                elseif isCanBeRemoved == true then
                                    print ("grass")

                                elseif isSolidFloor or isAttachedFloor then
                                    --floors
                                    table.insert(lines, "\tHitmanBasePlacements.IsoObject (\"" .. spriteName .. "\", sx + " .. tostring(x) .. ", sy + " .. tostring(y) .. ", sz + " .. tostring(z) .. ")\n")
                                
                                elseif false and objectType == IsoObjectType.wall then
                                    -- walls 
                                    table.insert(lines, "\tHitmanBasePlacements.IsoThumpable (\"" .. spriteName .. "\", sx + " .. tostring(x) .. ", sy + " .. tostring(y) .. ", sz + " .. tostring(z) .. ")\n")
                                ]]
                                if instanceof(object, 'IsoDoor') then
                                    -- door
                                    table.insert(lines, "\tHitmanBasePlacements.IsoDoor (\"" .. spriteName .. "\", sx + " .. tostring(x) .. ", sy + " .. tostring(y) .. ", sz + " .. tostring(z) .. ")\n")

                                elseif instanceof(object, 'IsoWindow') then
                                    -- window
                                    table.insert(lines, "\tHitmanBasePlacements.IsoWindow (\"" .. spriteName .. "\", sx + " .. tostring(x) .. ", sy + " .. tostring(y) .. ", sz + " .. tostring(z) .. ")\n")

                                else
                                    -- special objects?
                                    table.insert(lines, "\tHitmanBasePlacements.IsoObject (\"" .. spriteName .. "\", sx + " .. tostring(x) .. ", sy + " .. tostring(y) .. ", sz + " .. tostring(z) .. ")\n")
                                    
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    local fileWriter = getFileWriter("waitingroom2.txt", true, true)
    table.insert(lines, "end\n\n")

    local output = ""
    for k, v in pairs(lines) do
        output = output .. v
    end
    -- print (output)
    fileWriter:write(output)
    fileWriter:close()
                            
end

function HitmanMenu.ShowBrain (player, square, zombie)
    local id = HitmanUtils.GetCharacterID(zombie)

    -- add breakpoint below to see data
    local brain = HitmanBrain.Get(zombie)
    local moddata = zombie:getModData()
    
    local isUseless = zombie:isUseless()
    local isHitman = zombie:getVariableBoolean("Hitman")
    local walktype = zombie:getVariableString("zombieWalkType")
    local walktype2 = zombie:getVariableString("HitmanWalkType")
    local isHitmanTarget = zombie:getVariableString("HitmanTarget")
    local primary = zombie:getVariableString("HitmanPrimary")
    local primaryType = zombie:getVariableString("HitmanPrimaryType")
    local secondary = zombie:getVariableString("HitmanSecondary")
    local outfit = zombie:getOutfitName()
    local ans = zombie:getActionStateName()
    local under = zombie:isUnderVehicle()
    local veh = zombie:getVehicle()
    local health = zombie:getHealth()
    local zx = zombie:getX()
    local zy = zombie:getY()
    local hv = zombie:getHumanVisual()
    local bv = hv:getBodyVisuals()
    local moddata = zombie:getModData()
    local target = zombie:getTarget()
    local animator = zombie:getAdvancedAnimator()
    local inventory = zombie:getInventory()
    local ragdoll = zombie:isRagdoll()
    -- local astate = zombie:getAnimationDebug()
    local baseData = HitmanPlayerBase.data

    zombie:resetModelNextFrame()
    zombie:resetModel()

end

function HitmanMenu.SwitchProgram(player, hitman, program)
    local brain = HitmanBrain.Get(hitman)
    if brain then
        local pid = HitmanUtils.GetCharacterID(player)

        brain.master = pid
        brain.program = {}
        brain.program.name = program
        brain.program.stage = "Prepare"
        HitmanBrain.Update(hitman, brain)

        local syncData = {}
        syncData.id = brain.id
        syncData.master = brain.master
        syncData.program = brain.program
        Hitman.ForceSyncPart(hitman, syncData)
    end
end

function HitmanMenu.HitmanFlush(player)
    local args = {a=1}
    sendClientCommand(player, 'Hitman_Commands', 'HitmanFlush', args)
end

function HitmanMenu.SpawnClan(player, square, cid)
    local player = getSpecificPlayer(0)
    local args = {}
    args.cid = cid
    args.x = square:getX()
    args.y = square:getY()
    args.z = square:getZ()
    args.program = "Hitman"
    args.size = 6
    -- args.voice = 101
    sendClientCommand(player, 'Hitman_Spawner', 'Clan', args)
end

function HitmanMenu.WorldContextMenuPre(playerID, context, worldobjects, test)
    local world = getWorld()
    local player = getSpecificPlayer(playerID)
    local square = HitmanCompatibility.GetClickedSquare()
    -- PONGDU: nil guard (clicking outside a loaded square)
    if not square then return end

    local zombie = square:getZombie()
    if not zombie then
        local squareS = square:getS()
        if squareS then
            zombie = squareS:getZombie()
            if not zombie then
                local squareW = square:getW()
                if squareW then
                    zombie = squareW:getZombie()
                end
            end
        end
    end

    -- Player options
    if zombie and zombie:getVariableBoolean("Hitman") then
        local brain = HitmanBrain.Get(zombie)
        if not (brain.hostile or brain.hostileP) then
            local hitmanOption = context:addOption(brain.fullname)
            local hitmanMenu = context:getNew(context)

            if brain.program.name == "Looter" then
                context:addSubMenu(hitmanOption, hitmanMenu)
                hitmanMenu:addOption("Join Me!", player, HitmanMenu.SwitchProgram, zombie, "Companion")
            elseif brain.program.name == "Companion" or brain.program.name == "CompanionGuard" then
                context:addSubMenu(hitmanOption, hitmanMenu)
                hitmanMenu:addOption("Leave Me!", player, HitmanMenu.SwitchProgram, zombie, "Looter")
            end
        end
    end

    -- Debug options
    if isDebugEnabled() then

        
        -- context:addOption("[DGB] Tent", player, HitmanMenu.Tent, square)
        -- PONGDU: map UI (BanditMap) is not part of the fork
        -- context:addOption("[DGB] Hitman Map", player, HitmanMenu.Map)
        -- context:addOption("[DGB] Add Wanderer Group", player, HitmanMenu.AddWandererGroup, square)
        -- context:addOption("[DGB] Tests", player, HitmanMenu.HitmanTest)
        -- context:addOption("[DGB] Make Procedure", player, HitmanMenu.MakeProcedure, square)
        context:addOption("[DGB] Remove All Hitmans", player, HitmanMenu.HitmanFlush, square)

        if zombie then
            context:addOption("[DGB] Show Brain", player, HitmanMenu.ShowBrain, square, zombie)
        end
    end

    -- PONGDU: "Spawn Hitman Clan" context menu removed (B41 fork); hitmen come from donations only
    if false then
        HitmanCustom.Load()
        local clanData  = HitmanCustom.ClanGetAllSorted()
        local clanSpawnOption = context:addOption("Spawn Hitman Clan")
        local clanSpawnMenu = context:getNew(context)
        context:addSubMenu(clanSpawnOption, clanSpawnMenu)
        for cid, clan in pairs(clanData) do
            clanSpawnMenu:addOption("Clan " .. clan.general.name, player, HitmanMenu.SpawnClan, square, cid)
        end
    end
end

Events.OnPreFillWorldObjectContextMenu.Add(HitmanMenu.WorldContextMenuPre)
