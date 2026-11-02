HitmanZombiePrograms = HitmanZombiePrograms or {}

local function predicateAll(item)
    return true
end

HitmanZombiePrograms.Hitman = {}
HitmanZombiePrograms.Hitman.Stages = {}

HitmanZombiePrograms.Hitman.Init = function(hitman)
end

HitmanZombiePrograms.Hitman.Prepare = function(hitman)
    local tasks = {}

    Hitman.ForceStationary(hitman, false)
  
    return {status=true, next="Main", tasks=tasks}
end

HitmanZombiePrograms.Hitman.Main = function(hitman)
    local tasks = {}
    local cell = getCell()
    local bx, by, bz = hitman:getX(), hitman:getY(), hitman:getZ()
    local baseId, base = HitmanPlayerBase.GetBaseClosest(hitman)
    local endurance = 0.00
    local health = hitman:getHealth()
    local healthMin = 0.7
    local walkType = "Run"

    if Hitman.Settings.RunAway and health < healthMin then
        return {status=true, next="Escape", tasks=tasks}
    end

    local square = hitman:getSquare()
    local room = square and square:getRoom()
    if room then
        local lsList = room:getLightSwitches()
        local distBest = math.huge
        local lsBest
        for i=0, lsList:size()-1 do
            local ls = lsList:get(i)
            local square = ls:getSquare()
            if not ls:isActivated() and square:isFree(false) and (square:haveElectricity() or getWorld():isHydroPowerOn()) then
                local tx, ty, tz = square:getX() + 0.5, square:getY() + 0.5, square:getZ()
                local dist = HitmanUtils.DistTo(bx, by, tx, ty)
                if dist < distBest then
                    distBest = dist
                    lsBest = ls
                end
            end
        end

        if lsBest then
            local square = lsBest:getSquare()
            local tx, ty, tz = square:getX() + 0.5, square:getY() + 0.5, square:getZ()
            local dist = HitmanUtils.DistTo(bx, by, tx, ty)
            if distBest < 1.2 and bz == tz then
                local task = {action="LightToggle", time=20, active=true, x=tx, y=ty, z=tz}
                table.insert(tasks, task)
                return {status=true, next="Main", tasks=tasks}
            else
                table.insert(tasks, HitmanUtils.GetMoveTask(endurance, tx, ty, tz, walkType, dist, false))
                return {status=true, next="Main", tasks=tasks}
            end
        end
    end

    local isElectrician = Hitman.HasExpertise(hitman, Hitman.Expertise.Electrician)
    local isMechanic = Hitman.HasExpertise(hitman, Hitman.Expertise.Mechanic)
    if (isElectrician and Hitman.Settings.GeneratorCutoff) or (isMechanic and Hitman.Settings.SabotageVehicles) then 
        for z=0, 1 do
            for y=-10, 10 do
                for x=-10, 10 do
                    local tx, ty, tz = bx + x, by + y, z
                    local square = cell:getGridSquare(tx, ty, tz)
                    if square then

                        -- only if outside to prevent defenders shuting down their own genny
                        if isElectrician and hitman:isOutside() then
                            local gen = square:getGenerator()
                            if gen and gen:isActivated() then
                                local dist = HitmanUtils.DistTo(bx, by, tx, ty)
                                if dist < 1 then
                                    local task = {action="GeneratorToggle", anim="LootLow", x=tx, y=ty, z=tz, status=false}
                                    table.insert(tasks, task)
                                    return {status=true, next="Main", tasks=tasks}
                                else
                                    table.insert(tasks, HitmanUtils.GetMoveTask(endurance, tx, ty, tz, walkType, dist, false))
                                    return {status=true, next="Main", tasks=tasks}
                                end
                            end
                        end

                        -- Hitman.Settings.SabotageVehicles and
                        if isMechanic then
                            local vehicle = square:getVehicleContainer()
                            if vehicle and vehicle:isHotwired() then
                                local vx, vy, vz = vehicle:getX(), vehicle:getY(), vehicle:getZ()
                                local partIds = {"TireFrontRight", "TireFrontLeft", "TireRearLeft", "TireRearRight"}
                                for i=1, #partIds do
                                    local partId = partIds[i]
                                    local vehiclePart = vehicle:getPartById(partId)
                                    if vehiclePart then
                                        local item = vehiclePart:getInventoryItem()
                                        if item then
                                            local vector = vehicle:getAreaCenter(partId)
                                            local tx, ty, tz = vector:getX(), vector:getY(), vehicle:getZ()
                                            -- print ("PARTV: " .. partId .. " X:" .. tx .. " Y:" .. ty)

                                            local dist = HitmanUtils.DistTo(bx, by, tx, ty)
                                            if dist < 0.8 then
                                                local task = {action="VehicleAction", subaction="Uninstall", sound="RepairWithWrench", partId=partId, vx=vx, vy=vy, vz=vz, fx=vx, fy=vy, time=650}
                                                table.insert(tasks, task)
                                                return {status=true, next="Main", tasks=tasks}
                                            else
                                                table.insert(tasks, HitmanUtils.GetMoveTask(endurance, tx, ty, tz, walkType, dist, false))
                                                return {status=true, next="Main", tasks=tasks}
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if Hitman.Settings.Theft then
        local inventory = hitman:getInventory()
        local items = ArrayList.new()
        inventory:getAllEvalRecurse(predicateAll, items)
        if items:size() < 10 then
            if base and Hitman.HasExpertise(hitman, Hitman.Expertise.Thief) then
                local contId, cont = HitmanPlayerBase.GetContainerClosest(hitman, baseId)
                if contId then
                    -- select first item
                    local itemType
                    local cnt
                    for k, v in pairs(cont.items) do
                        itemType = k
                        cnt = v
                        break
                    end
                    if itemType then
                        local square = cell:getGridSquare(cont.x, cont.y, cont.z)
                        if square then
                            local asquare = AdjacentFreeTileFinder.Find(square, hitman)
                        
                            if asquare then
                                local dist = HitmanUtils.DistTo(hitman:getX(), hitman:getY(), asquare:getX() + 0.5, asquare:getY() + 0.5)
                                if dist > 0.90 or hitman:getZ() ~= asquare:getZ() then
                                    local task = HitmanUtils.GetMoveTask(0, asquare:getX(), asquare:getY(), asquare:getZ(), "Run", dist, false)
                                    table.insert(tasks, task)
                                    return {status=true, next="Main", tasks=tasks}
                                elseif hitman:getZ() == asquare:getZ() then
                                    Hitman.Say(hitman, "THIEF_SPOTTED")
                                    if cont.type == "floor" then
                                        -- hitman:addLineChatElement(("pickup " .. itemType), 1, 1, 1)
                                        local task = {action="PickUp", anim="LootLow", itemType=itemType, x=square:getX(), y=square:getY(), z=square:getZ(), cnt=cnt}
                                        table.insert(tasks, task)
                                        return {status=true, next="Main", tasks=tasks}
                                    else
                                        -- hitman:addLineChatElement(("take from container: " .. itemType), 1, 1, 1)
                                        local task = {action="TakeFromContainer", anim="Loot", itemType=itemType, x=square:getX(), y=square:getY(), z=square:getZ(), cnt=cnt}
                                        table.insert(tasks, task)
                                        return {status=true, next="Main", tasks=tasks}
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if Hitman.Settings.SabotageCrops then
        local plant = HitmanPlayerBase.GetFarm(hitman)
        if plant then
            local dist = HitmanUtils.DistTo(hitman:getX(), hitman:getY(), plant.x + 0.5, plant.y + 0.5)
            if dist > 0.80 then
                table.insert(tasks, HitmanUtils.GetMoveTask(0, plant.x, plant.y, plant.z, walkType, dist, false))
                return {status=true, next="Main", tasks=tasks}
            else
                local task = {action="StompPlant", x=plant.x, y=plant.y, z=plant.z, anim="Attack2HStamp", sound="AttackStomp"}
                table.insert(tasks, task)
                return {status=true, next="Main", tasks=tasks}
            end
        end
    end

    local config = {}
    config.mustSee = true
    config.hearDist = 5

    if Hitman.HasExpertise(hitman, Hitman.Expertise.Recon) then
        config.hearDist = 13
    elseif Hitman.HasExpertise(hitman, Hitman.Expertise.Tracker) then
        config.hearDist = 55
    end

    local target, enemy = HitmanUtils.GetTarget(hitman, config)
    
    -- engage with target
    if target.x and target.y and target.z then
        local targetSquare = cell:getGridSquare(target.x, target.y, target.z)
        if targetSquare then
            Hitman.SayLocation(hitman, targetSquare)
        end

        local tx, ty, tz = target.x, target.y, target.z
    
        if enemy then
            if target.fx and target.fy and (enemy:isRunning()  or enemy:isSprinting()) then
                tx, ty = target.fx, target.fy
            end
        end

        local walkType = Hitman.GetCombatWalktype(hitman, enemy, target.dist)

        table.insert(tasks, HitmanUtils.GetMoveTaskTarget(endurance, tx, ty, tz, target.id, target.player, walkType, target.dist))
        return {status=true, next="Main", tasks=tasks}
    end

    local task = {action="Time", anim="Shrug", time=200}
    table.insert(tasks, task)

    return {status=true, next="Main", tasks=tasks}
end

HitmanZombiePrograms.Hitman.Escape = function(hitman)
    local tasks = {}
    local weapons = Hitman.GetWeapons(hitman)

    local health = hitman:getHealth()

    local endurance = -0.06
    local walkType = "Run"
    if health < 0.8 then
        walkType = "Limp"
        endurance = 0
    end

    local config = {}
    config.mustSee = false
    config.hearDist = 40

    local closestPlayer = HitmanUtils.GetClosestPlayerLocation(hitman, config)

    if closestPlayer.x and closestPlayer.y and closestPlayer.z then

        -- calculate random escape direction
        local deltaX = 100 + ZombRand(100)
        local deltaY = 100 + ZombRand(100)

        local rx = ZombRand(2)
        local ry = ZombRand(2)
        if rx == 1 then deltaX = -deltaX end
        if ry == 1 then deltaY = -deltaY end

        table.insert(tasks, HitmanUtils.GetMoveTask(endurance, closestPlayer.x+deltaX, closestPlayer.y+deltaY, 0, walkType, 12, false))
    end
    return {status=true, next="Escape", tasks=tasks}
end

HitmanZombiePrograms.Hitman.Surrender = function(hitman)
    local tasks = {}

    if ZombRand(2) == 0 then
        local task = {action="Time", anim="Surrender", time=40}
        table.insert(tasks, task)
    else
        local task = {action="Time", anim="Scramble", time=40}
        table.insert(tasks, task)
    end

    return {status=true, next="Surrender", tasks=tasks}
end

