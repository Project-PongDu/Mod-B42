require "HitmanZombie"

local sum1 = 0
local sum2 = 0
local sum3 = 0
local iter1 = 0
local iter2 = 0
local iter3 = 0

local function predicateRemovable(item)
    if not item:getModData().hitmanPreserve and not instanceof(item, "Clothing") then
        return true
    end
end

local function predicateAll(item)
	return true
end

-- Cache weapon ranges across ticks to avoid repeated item instantiation and range recomputation.
local WeaponRangeCache = {
    melee = {},
    ranged = {}
}

local function GetAccuracyScopeTier(brain)
    local sight = brain and brain.accuracyBoost or 0
    if sight >= 1 and sight <= 2 then return "x2" end
    if sight > 2 and sight <= 3 then return "x4" end
    if sight > 3 then return "x8" end
    return "none"
end

local function GetMeleeRangeCached(weaponType)
    if not weaponType or weaponType == "" then return nil end

    local cached = WeaponRangeCache.melee[weaponType]
    if cached then return cached end

    local item = HitmanCompatibility.InstanceItem(weaponType)
    if not item then return nil end

    local range = item:getMaxRange()
    WeaponRangeCache.melee[weaponType] = range
    return range
end

local function GetRangedRangeCached(weaponType, brain)
    if not weaponType or weaponType == "" then return nil end

    local key = weaponType .. "|" .. GetAccuracyScopeTier(brain)
    local cached = WeaponRangeCache.ranged[key]
    if cached then return cached end

    local item = HitmanCompatibility.InstanceItem(weaponType)
    if not item then return nil end

    item = HitmanUtils.ModifyWeapon(item, brain)
    local range = HitmanCompatibility.GetMaxRange(item)
    WeaponRangeCache.ranged[key] = range
    return range
end

local function CalcSpottedScore(player, distSq)
    

    local square = player:getSquare()
    if not square then return 0 end

    local spottedScore = square:getLightLevel(0)

    if instanceof(player, "IsoPlayer") then
        if player:isRunning() then spottedScore = spottedScore + 0.05 end
        if player:isSprinting() then spottedScore = spottedScore + 0.08 end
        if player:isSneaking() then spottedScore = spottedScore - 0.1 end
    end

    -- distance-based adjustment using squared distance
    -- Keeps the same endpoints as before: +0.65 at distance 0, +0.05 at distance 8.
    if distSq <= 64 then
        spottedScore = spottedScore + (0.65 - (distSq * 0.009375))
    end

    return spottedScore
end

local function IsWindowClose(hitman)
    local bx = math.floor(hitman:getX())
    local by = math.floor(hitman:getY())
    local bz = hitman:getZ()
    local cell = getCell()

    for x=-1, 1 do
        for y=-1, 1 do
            local square = cell:getGridSquare(bx + x, by + y, bz)
            if square then
                local objects = square:getObjects()
                for i = 0, objects:size() - 1 do
                    local object = objects:get(i)
                    if object then
                        if instanceof(object, "IsoWindow") or instanceof(object, "IsoWindowFrame") or instanceof(object, "IsoThumpable") then
                            if object:canClimbThrough(hitman) then
                                return true
                            end
                        end
                    end
                end
            end
        end
    end
end

-- checks if the line of fire is clear from friendlies
local function IsShotClear (shooter, enemy)

    if true then return true end

    local cell = getCell()

    local x0 = math.floor(shooter:getX())
    local y0 = math.floor(shooter:getY())
    local x1 = math.floor(enemy:getX())
    local y1 = math.floor(enemy:getY())
    local z = enemy:getZ()

    local dx = math.abs(x1 - x0)
    local dy = math.abs(y1 - y0)
    local sx = (x0 < x1) and 1 or -1
    local sy = (y0 < y1) and 1 or -1
    local err = dx - dy

    local cx, cy, cz = x0, y0, z

    local brainShooter = HitmanBrain.Get(shooter)

    local i = 0
    while true do

        -- last iteration
        local list = {}
        if cx == x1 and cy == y1 then
            for x = -2, 2 do
                for y = -2, 2 do
                    table.insert(list, {x = cx + x, y = cy + y, z=cz})
                end
            end
        else
            table.insert(list, {x=cx, y=cy, z=cz})
        end

        for _, c in pairs(list) do
            local square = cell:getGridSquare(c.x, c.y, c.z)
            if i > 1 and square then

                local chrs = square:getMovingObjects()
                for i=0, chrs:size()-1 do
                    local chr = chrs:get(i)
                    if instanceof(chr, "IsoPlayer") and not (brainShooter.hostile or brainShooter.hostileP) then
                        -- shooter:addLineChatElement("PLAYER IN LINE", 0.8, 0.8, 0.1)
                        return false
                    elseif instanceof(chr, "IsoZombie") then
                        local brainEnemy = HitmanBrain.Get(chr)
                        if not HitmanUtils.AreEnemies(brainEnemy, brainShooter) then
                        -- if brainEnemy and brainEnemy.clan and brainShooter.clan == brainEnemy.clan and (not brainShooter.hostile or brainEnemy.hostile) then
                            -- shooter:addLineChatElement("FRIENDLY IN LINE", 0.8, 0.8, 0.1)
                            return false
                        end
                    end
                end
            end
        end

        if cx == x1 and cy == y1 then break end
        local e2 = 2 * err
        if e2 > -dy then
            err = err - dy
            cx = cx + sx
        end
        if e2 < dx then
            err = err + dx
            cy = cy + sy
        end
        i = i + 1
    end

    return true
end

-- turns a zombie into a hitman
local function Hitmanize(zombie, brain)

    -- load brain
    HitmanBrain.Update(zombie, brain)

    -- just in case
    zombie:setNoTeeth(true)

    -- used to determine if zombie is a hitman, can be used by other mods
    zombie:setVariable("Hitman", true)
    zombie:getModData().isDeadHitman = false
    zombie:setVariable("LimpSpeed", 0.80)
    zombie:setVariable("RunSpeed", 0.65 + ZombRandFloat(0, 0.05))
    zombie:setVariable("WalkSpeed", 0.98 + ZombRandFloat(0, 0.05))

    -- hitman primary and secondary hand items
    zombie:setVariable("HitmanPrimary", "")
    zombie:setVariable("HitmanSecondary", "")

    -- hitman walking type defined in animations
    zombie:setWalkType("Walk")
    zombie:setVariable("HitmanWalkType", "Walk")

    -- this shit here is important, removes black screen crashes
    -- with this var set, game engine skips testDefense function that
    -- wrongly refers to moodles, which zombie object does not have
    zombie:setVariable("ZombieHitReaction", "Chainsaw")

    -- prevents the hitman from being the target of a lunge attack
    zombie:setVariable("NoLungeTarget", true)

    -- stfu
    zombie:getEmitter():stopAll()

    zombie:setPrimaryHandItem(nil)
    zombie:setSecondaryHandItem(nil)
    zombie:resetEquippedHandsModels()
    zombie:clearAttachedItems()

    -- makes hitman unstuck after spawns
    zombie:setTurnAlertedValues(-5, 5)

    zombie:getModData().hitmanBrainId = brain.id

    local desc = zombie:getDescriptor()
    -- local test = desc:getVoicePrefix()
    desc:setVoicePrefix("Hitman")

end

-- turns hitman into a zombie
local function Zombify(hitman)
    hitman:setNoTeeth(false)
    hitman:setUseless(false)
    hitman:setVariable("Hitman", false)
    hitman:setVariable("HitmanPrimary", "")
    hitman:setVariable("HitmanSecondary", "")
    hitman:setWalkType("2")
    hitman:setVariable("HitmanWalkType", "")
    hitman:setPrimaryHandItem(nil)
    hitman:setSecondaryHandItem(nil)
    hitman:resetEquippedHandsModels()
    hitman:clearAttachedItems()
    hitman:getModData().hitmanBrainId = nil
    HitmanBrain.Remove(hitman)
end

-- updates hitman torches light
local TorchLightDefs = {
    {d=0, r=2, c={r = 1, g = 0.9, b = 0.8}},
    {d=2, r=4, c={r = 1, g = 0.9, b = 0.8}},
    {d=7, r=8, c={r = 1, g = 0.9, b = 0.8}},
    {d=11, r=12, c={r = 0.8, g = 0.8, b = 0.7}}
}

local function ManageTorch(hitman, brain)
    if not Hitman.Settings.CarryTorches then return end
    if not brain.torch then return end

    local zx, zy, zz = math.floor(hitman:getX()), math.floor(hitman:getY()), math.floor(hitman:getZ())
    local vehicle = hitman:getVehicle()
    local cell = getCell()

    if vehicle then return end
    
    if hitman:isProne() then

        --[[local lightSource = IsoLightSource.new(zx, zy, zz, colors.r, colors.g, colors.b, 2, 20)
        if lightSource then
            getCell():addLamppost(lightSource)
        end]]
    else
        local theta = hitman:getDirectionAngle() * 0.0174533

        for _, ld in ipairs(TorchLightDefs) do
            local lx = math.floor(zx + (ld.d * math.cos(theta)) + 0.5)
            local ly = math.floor(zy + (ld.d * math.sin(theta)) + 0.5)
            local lz = zz

            local ls = cell:getLightSourceAt(lx, ly, lz)
            if not ls then
                local ls = IsoLightSource.new(lx, ly, lz, ld.c.r, ld.c.g, ld.c.b, ld.r, 1)
                if ls then
                    cell:addLamppost(ls)
                    --print("Added light source at: " .. lx .. ", " .. ly .. ", " .. lz)
                end
            else
                --print ("Light source already exists at: " .. lx .. ", " .. ly .. ", " .. lz)
                cell:removeLamppost(ls)
            end
        end
    end
end

-- update hitman chainsaw sound
local function ManageChainsaw(hitman)
    if hitman:isPrimaryEquipped("AuthenticZClothing.Chainsaw") then
        local emitter = hitman:getEmitter()
        if not emitter:isPlaying("ChainsawIdle") then
            hitman:playSound("ChainsawIdle")
        end
    end
end

-- updates hitman being on fire
local function ManageOnFire(hitman)
    if hitman:isOnFire() then
        if not Hitman.HasTaskType(hitman, "Die") then
            Hitman.ClearTasks(hitman)
            Hitman.AddTask(hitman, {action="Die", lock=true, anim="Die", fire=true, time=250})
        end
        return
    end

    local cell = hitman:getCell()
    local bx, by, bz = hitman:getX(), hitman:getY(), hitman:getZ()

    if Hitman.HasActionTask(hitman) then return end

    for x = -2, 2 do
        for y = -2, 2 do
            local testSquare = cell:getGridSquare(bx + x, by + y, bz)
            if testSquare and testSquare:haveFire() then
                Hitman.ClearTasks(hitman)
                Hitman.AddTask(hitman, {action="Time", anim="Cough", time=200})
                return
            end
        end
    end
end

-- reduces cooldown for hitman speech
local function ManageSpeechCooldown(brain)
    if brain.speech and brain.speech > 0 then
        brain.speech = brain.speech - 0.01
        if brain.speech < 0 then brain.speech = 0 end
        -- HitmanBrain.Update(hitman, brain)
    end
end

local ClearTaskActionStates = {
    ["getup"] = true,
    ["getup-fromonback"] = true,
    ["getup-fromonfront"] = true,
    ["getup-fromsitting"] = true,
    ["staggerback"] = true,
    ["staggerback-knockeddown"] = true,
    ["onground"] = true,
    ["onground-ragdoll"] = true,
    ["onground-breathing"] = true,
    ["falldown"] = true,
    ["falldown-headleft"] = true,
    ["falldown-headleft-ragdoll"] = true,
    ["falldown-headright"] = true,
    ["falldown-headright-ragdoll"] = true,
    ["falldown-tophead"] = true,
    ["falldown-tophead-ragdoll"] = true,
    ["falldown-knifedead"] = true,
    ["falldown-knifedead-ragdoll"] = true,
    ["falldown-onknees"] = true,
    ["falldown-onknees-ragdoll"] = true,
    ["falldown-ragdoll"] = true,
    ["falldown-speardeath1"] = true,
    ["falldown-speardeath1-ragdoll"] = true,
    ["falldown-speardeath2"] = true,
    ["falldown-speardeath2-ragdoll"] = true,
    ["falldown-uppercut"] = true,
    ["falldown-uppercut-ragdoll"] = true,
    ["hitreaction"] = true,
    ["hitreaction-fencewindow"] = true,
    ["hitreaction-fencewindow-ragdoll"] = true,
    ["hitreaction-gettingup"] = true,
    ["hitreaction-hit"] = true,
    ["hitreaction-onfloor"] = true,
    ["hitreaction-ragdoll"] = true,
    ["hitreaction-shothead-bwd"] = true,
    ["hitreaction-shothead-bwd-ragdoll"] = true,
    ["hitreaction-shothead-fwd"] = true,
    ["hitreaction-shothead-fwd-ragdoll"] = true,
    ["hitreaction-shothead-fwd02"] = true,
    ["hitreaction-shothead-fwd02-ragdoll"] = true,
    ["knockeddown-headleft"] = true,
    ["knockeddown-headright"] = true,
    ["knockeddown-headtop"] = true,
    ["knockeddown-shotchestl"] = true,
    ["knockeddown-shotchestr"] = true,
    ["knockeddown-shotlegl"] = true,
    ["knockeddown-shotlegr"] = true,
    ["knockeddown-shotshoulderl"] = true,
    ["knockeddown-shotshoulderr"] = true,
    ["knockeddown-uppercut"] = true,
    ["staggerback-knockeddown-frombehind"] = true,
    ["staggerback-knockeddown-ragdoll"] = true,
    ["staggerback-ragdoll"] = true,
    ["vehiclecollision-bumped"] = true,
    ["vehiclecollision-falldown"] = true,
    ["vehiclecollision-onground"] = true,
    ["vehiclecollision-onground-dead"] = true,
    ["vehiclecollision-ragdoll"] = true,
    ["vehiclecollision-staggerback"] = true,
}

-- applies tweaks based on hitman action state
local function ManageActionState(hitman)
    local asn = hitman:getActionStateName()
    

    -- Keep this branch allocation-free; it's called from OnZombieUpdate.
    if asn == "turnalerted" then
        hitman:changeState(ZombieIdleState.instance())
        hitman:clearAggroList()
        hitman:setTarget(nil)
        return true
    elseif asn == "pathfind" then
        return true
    elseif asn =="thump" then
        hitman:addLineChatElement(asn, 0.2, 0.8, 0.1)
        hitman:changeState(ZombieIdleState.instance())
    elseif asn == "lunge" then
        hitman:setUseless(true)
        hitman:clearAggroList()
        hitman:setTarget(nil)
        return true
    elseif ClearTaskActionStates[asn] then
        Hitman.ClearTasks(hitman)
        return false
    end

    -- Default behavior (for undefined states)
    hitman:setTarget(nil)

    hitman:setUseless(HitmanUtils.GetGameMode() ~= "Multiplayer" or Hitman.IsForceStationary(hitman))

    return true
end

-- manages endurance regain tasks 
local function ManageEndurance(hitman)

    local player = getSpecificPlayer(0)
    if player then
        if hitman:isMoving() then
            if hitman:getVariableString("HitmanWalkType") == "Run" then
                
                local px, py, pz = player:getX(), player:getY(), player:getZ()
                local zx, zy, zz = hitman:getX(), hitman:getY(), hitman:getZ()
                local dist = ((zx - px) * (zx - px)) + ((zy - py) * (zy - py))
                if pz == zz and dist < 9 then
                    local volume = getSoundManager():getSoundVolume()
                    local emitter = hitman:getEmitter()
                    local sound = "ZSBreath_Male"
                    if hitman:isFemale() then sound = "ZSBreath_Female" end
                    if not emitter:isPlaying(sound) then
                        local id = emitter:playSound(sound)
                        emitter:setVolume(id, volume * 0.6)
                    end
                end
            end
        end
    end

    if not Hitman.Settings.LimitedEndurance then
        return {}
    end

    local brain = HitmanBrain.Get(hitman)
    if brain.endurance > 0 or Hitman.HasActionTask(hitman) then
        return {}
    end

    brain.endurance = 1

    local exhaustionTasks = {}
    local exhaustionTask = { action = "Time", anim = "Exhausted", time = 200, lock = true }

    for i = 1, 5 do
        exhaustionTasks[i] = exhaustionTask
    end

    return exhaustionTasks
end

-- manages tasks related to hitman health
local function ManageHealth(hitman)
    local tasks = {}

    -- temporarily removed until bleeding bug in week one investigation is complete
    if Hitman.Settings.BleedOut then
        local healing = false
        local health = hitman:getHealth()
        if health < 0.7 then
            local zx, zy = hitman:getX(), hitman:getY()

            -- purely visual so random allowed
            if ZombRand(16) == 0 then
                local bx = zx - 0.5 + ZombRandFloat(0.1, 0.9)
                local by = zy - 0.5 + ZombRandFloat(0.1, 0.9)
                
                local chunk = hitman:getChunk()
                if chunk then 
                    chunk:addBloodSplat(bx, by, 0, ZombRand(20))
                end

            end
            hitman:setHealth(health - 0.00005)
        end
    end

    if Hitman.Settings.Infection then
        local brain = HitmanBrain.Get(hitman)
        if brain.infection and brain.infection > 0 then
            -- print ("INFECTION: " .. brain.infection)
            Hitman.UpdateInfection(hitman, 0.001)
            if brain.infection >= 100 then
                Hitman.ClearTasks(hitman)
                local task = {action="Zombify", anim="Faint", lock=true, time=200}
                table.insert(tasks, task)
            end
        end
    end
    return tasks
end

local function RemoveWindowFromPathing (hitman, square)
    if true then return end
    -- will need to unset for windows and windowframes too
    local recalc = false
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        local properties = object:getProperties()

        if properties then
            if properties:has(IsoFlagType.canPathN) then
                properties:unset(IsoFlagType.canPathN)
                recalc = true
            end
            if properties:has(IsoFlagType.canPathW) then
                properties:unset(IsoFlagType.canPathW)
                recalc = true
            end

            -- properties:unset(IsoFlagType.WindowN)
            -- properties:unset(IsoFlagType.WindowW)
        end
    end

    if recalc then
        square:RecalcProperties()
        square:RecalcAllWithNeighbours(true)
        if HitmanCompatibility.GetGameVersion() >= 42 then
            square:setSquareChanged()
        end
    end
end



-- manages collisions with doors, windows, fences and other objects
local function ManageCollisions(hitman)
    local tasks = {}

    local task = Hitman.GetTask(hitman)
    if not task then return {} end
    if not (task.action == "Move" or task.action == "GoTo") then return {} end

    local square = hitman:getCurrentSquare()
    if not square then return {} end

    local dir = hitman:getDirectionAngle()
    local dirrad = hitman:getDirectionAngleRadians()
    local isodir = IsoDirections.cardinalFromAngle(dirrad)

    local fenceSquare = square
    local fenceFlag = IsoFlagType.HoppableW
    if isodir == IsoDirections.N or isodir == IsoDirections.S then
        fenceFlag = IsoFlagType.HoppableN
    end
    if isodir == IsoDirections.E or isodir == IsoDirections.S then
        fenceSquare = square:getAdjacentSquare(isodir)
    end
    if fenceSquare and fenceSquare:has(fenceFlag) then
        local x = hitman:getX() + math.cos(dirrad) * 0.1
        local y = hitman:getY() + math.sin(dirrad) * 0.1
        hitman:setX(x)
        hitman:setY(y)
        hitman:setNextX(x)
        hitman:setNextY(y)
        hitman:changeState(ClimbOverFenceState.instance())
        hitman:setBumpType("ClimbFenceEnd")
        return tasks
    end

    --hitman:addLineChatElement("X: " .. hitman:getX() .. ", Y: " .. hitman:getY() .. ", Z: " .. hitman:getZ(), 0.8, 0.8, 0.1)
    -- hitman:addLineChatElement("Facing direction: " .. hitman:getDirectionAngle(), 0.8, 0.8, 0.1)

    local collided = hitman:isCollidedWithDoor() or hitman:isCollidedThisFrame() or hitman:isCollided()
    if not collided then
        local edgeDistance
        if isodir == IsoDirections.W then
            edgeDistance = hitman:getX() - square:getX()
        elseif isodir == IsoDirections.E then
            edgeDistance = square:getX() + 1 - hitman:getX()
        elseif isodir == IsoDirections.N then
            edgeDistance = hitman:getY() - square:getY()
        else
            edgeDistance = square:getY() + 1 - hitman:getY()
        end

        if edgeDistance <= hitman:getFeelersize() then
            local adjacent = square:getAdjacentSquare(isodir)
            local door = adjacent and square:getDoorTo(adjacent)
            collided = door and not door:IsOpen()
        end
    end
    if not collided then return {} end
    
    --hitman:addLineChatElement("collided ", 0.8, 0.8, 0.1)

    -- west and north objects are ont the same square, east is x+1, south is y+1

    local bx = math.floor(hitman:getX())
    local by = math.floor(hitman:getY())
    local bz = hitman:getZ()
    local cell = getCell()

    local sqs = {
        {x = 0, y = 0},
        {x = -1, y = 0},
        {x = 0, y = -1},
        {x = 1, y = 0},
        {x = 0, y = 1}
    }
   
    -- print ("Checking collision at: " .. sx .. ", " .. sy .. ", " .. bz)
    
    for _, offset in pairs(sqs) do
        local sx = bx + offset.x
        local sy = by + offset.y
        local square = cell:getGridSquare(sx, sy, bz)
        if square then

            local brain = HitmanBrain.Get(hitman)
            local weapons = brain.weapons

            local objects = square:getObjects()
            for i = 0, objects:size() - 1 do
                local object = objects:get(i)
                if object then
                    local properties = object:getProperties()

                    if properties then

                        local lowFence = properties:get("FenceTypeLow")
                        local hoppable = object:isHoppable()

                        -- WINDOW COLLISIONS
                        if instanceof(object, "IsoWindow") then
                                
                            if hitman:isFacingObject(object, 0.5) then
                                
                                if object:isBarricaded() then
                                    if brain.hostile then
                                        local barricade = object:getBarricadeOnSameSquare()
                                        if not barricade then barricade = object:getBarricadeOnOppositeSquare() end
                                        local fx, fy
                                        if barricade then
                                            if properties:has(IsoFlagType.WindowN) then
                                                fx = barricade:getX()
                                                fy = barricade:getY() - 0.5
                                            else
                                                fx = barricade:getX() - 0.5
                                                fy = barricade:getY()
                                            end

                                        else
                                            barricade = object:getBarricadeOnOppositeSquare()
                                            if properties:has(IsoFlagType.WindowN) then
                                                fx = barricade:getX()
                                                fy = barricade:getY() + 0.5
                                            else
                                                fx = barricade:getX() + 0.5
                                                fy = barricade:getY()
                                            end
                                        end

                                        if Hitman.Settings.RemoveBarricade and Hitman.HasExpertise(hitman, Hitman.Expertise.Breaker) then
                                            if barricade:isMetal() or barricade:isMetalBar() then
                                                if not hitman:isPrimaryEquipped("Hitmans.PropaneTorch") then
                                                    if not HitmanBrain.HasActionTask(brain) then
                                                        local stasks = HitmanPrograms.Weapon.Switch(hitman, "Hitmans.PropaneTorch")
                                                        for _, t in pairs(stasks) do table.insert(tasks, t) end
                                                    end
                                                end
                                                if not HitmanBrain.HasTaskType(brain, "UnbarricadeMetal") then
                                                    local task = {action="UnbarricadeMetal", anim="BlowtorchHigh", time=500, fx=fx, fy=fy, x=object:getSquare():getX(), y=object:getSquare():getY(), z=object:getSquare():getZ(), idx=object:getObjectIndex()}
                                                    table.insert(tasks, task)
                                                end
                                                return tasks
                                            else
                                                anim = "RemoveBarricadeCrowbarMid"
                                                local planks = barricade:getNumPlanks()
                                                if planks == 2 or planks == 4 then
                                                    anim = "RemoveBarricadeCrowbarHigh"
                                                end
                                                if not hitman:isPrimaryEquipped("Base.Crowbar") then
                                                    if not HitmanBrain.HasActionTask(brain) then
                                                        if not HitmanBrain.HasActionTask(brain) then
                                                            local stasks = HitmanPrograms.Weapon.Switch(hitman, "Base.Crowbar")
                                                            for _, t in pairs(stasks) do table.insert(tasks, t) end
                                                        end
                                                    end
                                                end
                                                if not HitmanBrain.HasTaskType(brain, "Unbarricade") then
                                                    local task = {action="Unbarricade", anim=anim, time=300, fx=fx, fy=fy, x=object:getSquare():getX(), y=object:getSquare():getY(), z=object:getSquare():getZ(), idx=object:getObjectIndex()}
                                                    table.insert(tasks, task)
                                                end
                                                return tasks
                                            end
                                        else
                                            if not hitman:isPrimaryEquipped(weapons.melee) then
                                                if not HitmanBrain.HasActionTask(brain) then
                                                    if not HitmanBrain.HasActionTask(brain) then
                                                        local stasks = HitmanPrograms.Weapon.Switch(hitman, weapons.melee)
                                                        for _, t in pairs(stasks) do table.insert(tasks, t) end
                                                    end
                                                end
                                            end
                                            if not HitmanBrain.HasTaskType(brain, "Destroy") then
                                                Hitman.ClearTasks(hitman)
                                                local task = {action="Destroy", anim="FrontKick", x=object:getSquare():getX(), y=object:getSquare():getY(), z=object:getSquare():getZ(), idx=object:getObjectIndex()}
                                                table.insert(tasks, task)
                                            end
                                            return tasks
                                        end
                                    else
                                        RemoveWindowFromPathing(hitman, square)
                                    end

                                elseif not object:IsOpen() and not object:isSmashed() and not HitmanBrain.HasTaskType(brain, "SmashWindow") then
                                    if Hitman.Settings.SmashWindow and (brain.hostile or brain.demolish) then
                                        local task = {action="SmashWindow", anim="WindowSmash", time=25, x=object:getSquare():getX(), y=object:getSquare():getY(), z=object:getSquare():getZ()}
                                        table.insert(tasks, task)
                                        return tasks
                                    elseif not object:isPermaLocked() and not HitmanBrain.HasTaskType(brain, "OpenWindow") then
                                        local task = {action="OpenWindow", anim="WindowOpen", time=25, x=object:getSquare():getX(), y=object:getSquare():getY(), z=object:getSquare():getZ()}
                                        table.insert(tasks, task)
                                        return tasks
                                    end

                                elseif object:canClimbThrough(hitman) then
                                    ClimbThroughWindowState.instance():setParams(hitman, object)
                                    hitman:changeState(ClimbThroughWindowState.instance())
                                    hitman:setBumpType("ClimbWindow")
                                    --[[local task = {action="ClimbFence", anim="ClimbWindow", lock=true}
                                    table.insert(tasks, task)]]
                                    return tasks      
                                end
                            end
                        end

                        -- DOOR COLLISIONS
                        if instanceof(object, "IsoDoor") or (instanceof(object, 'IsoThumpable') and object:isDoor() == true) then
                            if hitman:isFacingObject(object, 0.5) then

                                if object:isBarricaded() then
                                    local barricade = object:getBarricadeOnSameSquare()
                                    local fx, fy
                                    if barricade then
                                        if properties:has(IsoFlagType.doorN) then
                                            fx = barricade:getX()
                                            fy = barricade:getY() - 1
                                        else
                                            fx = barricade:getX() - 1
                                            fy = barricade:getY()
                                        end

                                    else
                                        barricade = object:getBarricadeOnOppositeSquare()
                                        if properties:has(IsoFlagType.doorN) then
                                            fx = barricade:getX()
                                            fy = barricade:getY() + 1
                                        else
                                            fx = barricade:getX() + 1
                                            fy = barricade:getY()
                                        end
                                    end
                                    local sameSide = barricade:getSquare():getX() == hitman:getSquare():getX() and barricade:getSquare():getY() == hitman:getSquare():getY()

                                    if Hitman.Settings.RemoveBarricade and Hitman.HasExpertise(hitman, Hitman.Expertise.Breaker) and sameSide then
                                        anim = "RemoveBarricadeCrowbarMid"
                                        local planks = barricade:getNumPlanks()
                                        if planks == 2 or planks == 4 then
                                            anim = "RemoveBarricadeCrowbarHigh"
                                        end
                                        if not hitman:isPrimaryEquipped("Base.Crowbar") then
                                            if not HitmanBrain.HasActionTask(brain) then
                                                local stasks = HitmanPrograms.Weapon.Switch(hitman, "Base.Crowbar")
                                                for _, t in pairs(stasks) do table.insert(tasks, t) end
                                            end
                                        end
                                        Hitman.Say(hitman, "BREACH")
                                        if not HitmanBrain.HasTaskType(brain, "Unbarricade") then
                                            local task = {action="Unbarricade", anim=anim, time=300, fx=fx, fy=fy, x=object:getSquare():getX(), y=object:getSquare():getY(), z=object:getSquare():getZ(), idx=object:getObjectIndex()}
                                            table.insert(tasks, task)
                                        end
                                        return tasks
                                    else
                                        if not hitman:isPrimaryEquipped(weapons.melee) then
                                            if not HitmanBrain.HasActionTask(brain) then
                                                local stasks = HitmanPrograms.Weapon.Switch(hitman, weapons.melee)
                                                for _, t in pairs(stasks) do table.insert(tasks, t) end
                                            end
                                        end
                                        Hitman.Say(hitman, "BREACH")
                                        if not HitmanBrain.HasTaskType(brain, "Destroy") then
                                            Hitman.ClearTasks(hitman)
                                            local task = {action="Destroy", anim="FrontKick", x=object:getSquare():getX(), y=object:getSquare():getY(), z=object:getSquare():getZ(), idx=object:getObjectIndex()}
                                            table.insert(tasks, task)
                                        end
                                        return tasks
                                    end

                                elseif not object:IsOpen() then
                                    local hasKey = Hitman.HasKey(hitman, object)
                                    if IsoDoor.getDoubleDoorIndex(object) > -1 then

                                        if not hasKey and (object:isLocked() or object:isLockedByKey() or object:isObstructed()) then
                                            if hitman:isPrimaryEquipped(weapons.melee) then
                                                if not HitmanBrain.HasTaskType(brain, "Destroy") then
                                                    Hitman.ClearTasks(hitman)
                                                    local task = {action="Destroy", anim="FrontKick", x=object:getSquare():getX(), y=object:getSquare():getY(), z=object:getSquare():getZ(), idx=object:getObjectIndex()}
                                                    table.insert(tasks, task)
                                                end
                                                return tasks
                                            else
                                                if not HitmanBrain.HasActionTask(brain) then
                                                    local stasks = HitmanPrograms.Weapon.Switch(hitman, weapons.melee)
                                                    for _, t in pairs(stasks) do table.insert(tasks, t) end
                                                    return tasks
                                                end
                                            end
                                        else
                                            IsoDoor.toggleDoubleDoor(object, true)
                                            HitmanNotifications.DoorToggled(hitman, object, true)
                                            local doorSound = properties:has("DoorSound") and properties:get("DoorSound") or "WoodDoor"
                                            doorSound = doorSound .. "Open"
                                            hitman:playSound(doorSound)
                                        end

                                    elseif not hasKey and IsoDoor.getGarageDoorIndex(object) > -1 then
                                    
                                        local exterior = hitman:getCurrentSquare():has(IsoFlagType.exterior)
                                        if brain.hostile and (object:isLocked() or object:isLockedByKey() or object:getModData().CustomLock or object:isObstructed()) then
                                            if hitman:isPrimaryEquipped(weapons.melee) then
                                                Hitman.Say(hitman, "BREACH")
                                                if not HitmanBrain.HasTaskType(brain, "Destroy") then
                                                    Hitman.ClearTasks(hitman)
                                                    local task = {action="Destroy", anim="FrontKick", x=object:getSquare():getX(), y=object:getSquare():getY(), z=object:getSquare():getZ(), idx=object:getObjectIndex()}
                                                    table.insert(tasks, task)
                                                end
                                                return tasks
                                            else
                                                if not HitmanBrain.HasActionTask(brain) then
                                                    local stasks = HitmanPrograms.Weapon.Switch(hitman, weapons.melee)
                                                    for _, t in pairs(stasks) do table.insert(tasks, t) end
                                                    return tasks
                                                end
                                            end
                                        else
                                            IsoDoor.toggleGarageDoor(object, true)
                                            HitmanNotifications.DoorToggled(hitman, object, true)
                                            local doorSound = properties:has("DoorSound") and properties:get("DoorSound") or "WoodDoor"
                                            doorSound = doorSound .. "Open"
                                            hitman:playSound(doorSound)
                                        end
                                    else

                                        -- door locks are complicated... 
                                        if not hasKey and ((not hoppable and (object:isLocked() or object:isLockedByKey()) and (not hitman:getCurrentSquare():getRoom() or object:getProperties():has("forceLocked"))) or object:isObstructed()) then
                                            if hitman:isPrimaryEquipped(weapons.melee) then
                                                Hitman.Say(hitman, "BREACH")
                                                if not HitmanBrain.HasTaskType(brain, "Unbarricade") and not HitmanBrain.HasTaskType(brain, "Destroy") then
                                                    Hitman.ClearTasks(hitman)
                                                    local task = {action="Destroy", anim="FrontKick", x=object:getSquare():getX(), y=object:getSquare():getY(), z=object:getSquare():getZ(), idx=object:getObjectIndex()}
                                                    table.insert(tasks, task)
                                                end
                                                return tasks
                                            else
                                                if not HitmanBrain.HasActionTask(brain) then
                                                    local stasks = HitmanPrograms.Weapon.Switch(hitman, weapons.melee)
                                                    for _, t in pairs(stasks) do table.insert(tasks, t) end
                                                    return tasks
                                                end
                                            end
                                        else
                                            if hasKey and object:isLockedByKey() then
                                                object:setLockedByKey(false)
                                                local unlockSound = properties:has("DoorSound") and properties:get("DoorSound") .. "Unlock" or "UnlockDoor"
                                                hitman:playSound(unlockSound)
                                            end

                                            object:DirtySlice()
                                            IsoGridSquare.RecalcLightTime = -1.0
                                            square:InvalidateSpecialObjectPaths()
                                            object:ToggleDoorSilent()
                                            square:RecalcProperties()
                                            square:RecalcAllWithNeighbours(true)
                                            square:setSquareChanged()
                                            object:syncIsoObject(false, 1, nil, nil)
                                            lowFence = false
                                            hoppable = false
                                            LuaEventManager.triggerEvent("OnContainerUpdate")
                                            if HitmanCompatibility.GetGameVersion() >= 42 then
                                                object:invalidateRenderChunkLevel(FBORenderChunk.DIRTY_OBJECT_MODIFY)
                                            end
                                            HitmanNotifications.DoorToggled(hitman, object, true)

                                            local doorSound = properties:has("DoorSound") and properties:get("DoorSound") or "WoodDoor"
                                            doorSound = doorSound .. "Open"
                                            hitman:playSound(doorSound)
                                            return tasks
                                        end
                                    end
                                end
                            else
                                hitman:faceThisObject(object)
                            end
                        end

                        -- LOW FENCE COLLISION
                        --[[
                        if lowFence or hoppable then
                            if hitman:isFacingObject(object, 0.5) then
                                hitman:changeState(ClimbOverFenceState.instance())
                                hitman:setBumpType("ClimbFenceEnd")
                                

                            
                            else
                                hitman:faceThisObject(object)
                            end
                            return tasks
                        end
                        ]]

                        -- TALL FENCE COLLISION
                        local tallFence = properties:get("FenceTypeHigh")
                        local tallHoppable = object:isTallHoppable()
                        if tallFence or tallHoppable then
                            hitman:setCollidable(false)
                            if hitman:isFacingObject(object, 0.5) then
                                hitman:setBumpType("ClimbFenceTall")
                            else
                                hitman:faceThisObject(object)
                            end
                            return tasks
                        end

                        -- THUMPABLE COLLISIONS
                        if Hitman.Settings.DestroyThumpable and instanceof(object, "IsoThumpable") and not properties:get("FenceTypeLow") and brain.hostile then
                            local isWallTo = hitman:getSquare():isSomethingTo(object:getSquare())
                            if not isWallTo then
                                if hitman:isPrimaryEquipped(weapons.melee) then
                                    Hitman.ClearTasks(hitman)
                                    local task = {action="Destroy", anim="FrontKick", x=object:getSquare():getX(), y=object:getSquare():getY(), z=object:getSquare():getZ(), soundEnd=object:getThumpSound(), time=80}
                                    table.insert(tasks, task)
                                else
                                    if not HitmanBrain.HasActionTask(brain) then
                                        local stasks = HitmanPrograms.Weapon.Switch(hitman, weapons.melee)
                                        for _, t in pairs(stasks) do table.insert(tasks, t) end
                                        return tasks
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- hitman:addLineChatElement("FALL THRU GAP! " .. #tasks, 0.8, 0.8, 0.1)
    return tasks
end

-- manages melee and weapon combat
local function ManageCombat(hitman)

    if hitman:isCrawling() then return {} end 
    if Hitman.IsSleeping(hitman) then return {} end
    -- if hitman:getActionStateName() == "bumped" then return {} end

    local tasks = {}
    local zx, zy, zz = hitman:getX(), hitman:getY(), hitman:getZ()
    local hitmanSquare = hitman:getSquare()
    if not hitmanSquare then return {} end

    local brain = HitmanBrain.Get(hitman)
    local weapons = brain.weapons
    local isOutOfAmmo = HitmanBrain.IsOutOfAmmo(brain)
    local isNeedPrimary = HitmanBrain.NeedResupplySlot(brain, "primary")
    local isNeedSecondary = HitmanBrain.NeedResupplySlot(brain, "secondary")
    local isBareHands = HitmanBrain.IsBareHands(brain)
    local isOutside = hitmanSquare:isOutside()

    local bestDistSq = 1600
    local enemyCharacter, switchTo
    local healing, reload, resupply = false, false, false
    local combat, switch, firing, stomp, shove, escape = false, false, false, false, false, false
    local maxRangeMelee, maxRangePistol, maxRangeRifle
    local maxRangeMeleeSq, maxRangeMeleeWithFixSq
    local maxRangePistolSq, maxRangePistolFireSq
    local maxRangeRifleSq, maxRangeRifleFireSq
    local friendlies, friendliesBwd, enemies, enemiesBwd = 0, 0, 0, 0
    local sx, sy = 0, 0

    -- THIS GOVERNS LOW-PRIORITY TASKS
    if not HitmanBrain.HasActionTask(brain) then
        
        -- HEALING FLAG
        local health = hitman:getHealth()    
        if health < 0.4 then
            healing = true
        end

        -- PEACFUL RELOAD FLAG
        local wp = weapons.primary
        if wp and wp.name then
            if (wp.type == "mag" and wp.bulletsLeft <= 0 and wp.magCount > 0) or
               (wp.type == "nomag" and wp.bulletsLeft < wp.ammoSize and wp.ammoCount > 0) or
               wp.racked == false then
                if hitman:isPrimaryEquipped(wp.name) then
                    reload = true
                end
            end
        end

        local ws = weapons.secondary
        if not reload and ws and ws.name then
            if (ws.type == "mag" and ws.bulletsLeft <= 0 and ws.magCount > 0) or
               (ws.type == "nomag" and ws.bulletsLeft < ws.ammoSize and ws.ammoCount > 0) or
               ws.racked == false then
                if hitman:isPrimaryEquipped(ws.name) then
                    reload = true
                end
            end
        end

        -- RESUPPLY FLAG
        if (brain.hostile or brain.hostileP) and (isBareHands or isNeedPrimary or isNeedSecondary) then
            resupply = true
        end
    end

    -- SWITCH WEAPON DISTANCES
    local meleeDist = isOutside and 2.6 or 1.2
    local meleeDistPlayer = isOutside and 3.5 or 1.2
    local rifleDist = 5.5
    local escapeDist = 10 -- 5.2
    local bwdDist = 2.8
    local meleeDistSq = meleeDist * meleeDist
    local meleeDistPlayerSq = meleeDistPlayer * meleeDistPlayer
    local meleeDistPlayerShootSq = (meleeDistPlayer + 1) * (meleeDistPlayer + 1)
    local escapeDistSq = escapeDist * escapeDist
    local bwdDistSq = bwdDist * bwdDist

    -- COMBAT AGAIST PLAYERS 
    if brain.hostile or brain.hostileP then
        local playerList = HitmanPlayer.GetPlayers()

        for i=0, playerList:size()-1 do
            local potentialEnemy = playerList:get(i)
            if potentialEnemy and potentialEnemy:isAlive() and hitman:CanSee(potentialEnemy) and not potentialEnemy:isBehind(hitman) and (instanceof(potentialEnemy, "IsoPlayer") and not HitmanPlayer.IsGhost(potentialEnemy)) then
                local px, py, pz = potentialEnemy:getX(), potentialEnemy:getY(), potentialEnemy:getZ()
                local potentialEnemySquare = potentialEnemy:getSquare()
                if potentialEnemySquare then
                    local dx = zx - px
                    local dy = zy - py
                    local distSq = (dx * dx) + (dy * dy)
                    if distSq < bestDistSq and math.abs(zz - pz) < 0.5 then
                        local spottedScore = CalcSpottedScore(potentialEnemy, distSq)
                        if not hitmanSquare:isSomethingTo(potentialEnemySquare) and spottedScore > 0.49 then
                            bestDistSq, enemyCharacter = distSq, potentialEnemy

                            -- record last known position 
                            brain.lastPost = {x=px, y=py, z=pz, id=HitmanUtils.GetCharacterID(enemyCharacter), d=enemyCharacter:getDirectionAngle()}

                            --reset action flags, only one can be true
                            combat, switch, firing, shove, escape = false, false, false, false, false

                            --determine if hitman will be in combat mode
                            if weapons.melee then
                                if not maxRangeMelee then
                                    maxRangeMelee = GetMeleeRangeCached(weapons.melee)
                                    if not maxRangeMelee then return tasks end
                                    maxRangeMeleeSq = maxRangeMelee * maxRangeMelee
                                    local meleeFixRange = maxRangeMelee + 0.1
                                    maxRangeMeleeWithFixSq = meleeFixRange * meleeFixRange
                                end
                                local prone = potentialEnemy:isProne()
                                
                                if distSq <= meleeDistPlayerSq then 
                                    if hitman:isPrimaryEquipped(weapons.melee) then
                                        if distSq <= maxRangeMeleeSq then
                                            local asn = enemyCharacter:getActionStateName()
                                            shove = distSq < 0.25 and not prone and asn ~= "onground" and asn ~= "sitonground" and asn ~= "climbfence" and asn ~= "bumped"
                                            combat = not shove
                                        end
                                    else
                                        local asn = enemyCharacter:getActionStateName()
                                        if distSq < 0.30 then
                                            shove = true
                                            combat = false
                                        elseif asn == "bumped" then
                                            switch = true
                                            switchTo = weapons.melee
                                        end
                                    end
                                end
                            end

                            --determine if hitman will be in shooting mode
                            if not isOutOfAmmo and distSq > meleeDistPlayerShootSq and not combat and not shove then
                                if weapons.primary.name and weapons.primary.bulletsLeft > 0 then
                                    if not maxRangeRifle then
                                        maxRangeRifle = GetRangedRangeCached(weapons.primary.name, brain)
                                        if not maxRangeRifle then return tasks end
                                        maxRangeRifleSq = maxRangeRifle * maxRangeRifle
                                        local maxRangeRifleFire = maxRangeRifle + rifleDist
                                        maxRangeRifleFireSq = maxRangeRifleFire * maxRangeRifleFire
                                    end
                                    if distSq < maxRangeRifleSq then
                                        if hitman:isPrimaryEquipped(weapons.primary.name) then
                                            if distSq < maxRangeRifleFireSq and IsShotClear(hitman, potentialEnemy) then
                                                firing = true
                                            end
                                        elseif not reload then
                                            Hitman.Say(hitman, "SPOTTED")
                                            switch = true
                                            switchTo = weapons.primary.name
                                        end
                                    end
                                elseif weapons.secondary.name and weapons.secondary.bulletsLeft > 0 then
                                    if not maxRangePistol then
                                        maxRangePistol = GetRangedRangeCached(weapons.secondary.name, brain)
                                        if not maxRangePistol then return tasks end
                                        maxRangePistolSq = maxRangePistol * maxRangePistol
                                        local maxRangePistolFire = maxRangePistol + rifleDist
                                        maxRangePistolFireSq = maxRangePistolFire * maxRangePistolFire
                                    end
                                    if distSq < maxRangePistolSq then
                                        if hitman:isPrimaryEquipped(weapons.secondary.name) then
                                            if distSq < maxRangePistolFireSq and IsShotClear(hitman, potentialEnemy) then
                                                firing = true
                                            end
                                        elseif not reload then
                                            Hitman.Say(hitman, "SPOTTED")
                                            switch = true
                                            switchTo = weapons.secondary.name
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
    
    -- COMBAT AGAINST ZOMBIES AND HITMANS FROM OTHER CLAN
    local cache, potentialEnemyList = HitmanZombie.Cache, HitmanZombie.CacheLight
    for id, potentialEnemy in pairs(potentialEnemyList) do

        -- quick manhattan check for performance boost
        -- if HitmanUtils.DistToManhattan(potentialEnemy.x, potentialEnemy.y, zx, zy) < 36 then
        local maxDistAllowed = 57
        if brain.weaponsHold then
            maxDistAllowed = 2
        end
        local distManhattan = math.abs(potentialEnemy.x - zx) + math.abs(potentialEnemy.y - zy)
        if distManhattan < maxDistAllowed then

            if HitmanUtils.AreEnemies(potentialEnemy.brain, brain) then
            -- if not potentialEnemy.brain or (brain.clan ~= potentialEnemy.brain.clan and (brain.hostile or potentialEnemy.brain.hostile)) then
     
                -- load real instance here
                local potentialEnemy = cache[id]
                if potentialEnemy:isAlive() and potentialEnemy:getHealth() > 0 and hitman:CanSee(potentialEnemy) then
                --- if true then
                    local pesq = potentialEnemy:getSquare()
                    if pesq and not hitmanSquare:isSomethingTo(pesq) then
                        local px, py, pz = potentialEnemy:getX(), potentialEnemy:getY(), potentialEnemy:getZ()
                        local dx = zx - px
                        local dy = zy - py
                        local distSq = (dx * dx) + (dy * dy)
                        local spottedScore = CalcSpottedScore(potentialEnemy, distSq)
                        if spottedScore > 0.49 then
                            if distSq < escapeDistSq and not potentialEnemy:isProne() then
                                enemies = enemies + 1
                                if distSq < bwdDistSq  then
                                    enemiesBwd = enemiesBwd + 1
                                end
                            end
                            if distSq < bestDistSq then
                                bestDistSq, enemyCharacter = distSq, potentialEnemy

                                --reset action flags, only one can be true
                                combat, switch, firing, shove, stomp, escape = false, false, false, false, false, false
                                
                                if distSq <= 1 and math.abs(zz - pz) < 0.8 then
                                    if enemyCharacter:isProne() then
                                        stomp = true
                                    else
                                        shove = true
                                    end
                                elseif not isOutOfAmmo then
                                    if weapons.primary.name and weapons.primary.bulletsLeft > 0 then
                                        if not maxRangeRifle then
                                            maxRangeRifle = GetRangedRangeCached(weapons.primary.name, brain)
                                            if not maxRangeRifle then return tasks end
                                            maxRangeRifleSq = maxRangeRifle * maxRangeRifle
                                            local maxRangeRifleFire = maxRangeRifle + rifleDist
                                            maxRangeRifleFireSq = maxRangeRifleFire * maxRangeRifleFire
                                        end
                                        if distSq < maxRangeRifleSq then
                                            if hitman:isPrimaryEquipped(weapons.primary.name) then
                                                if distSq < maxRangeRifleFireSq and IsShotClear(hitman, potentialEnemy) then
                                                    firing = true
                                                end
                                            elseif not reload then
                                                Hitman.Say(hitman, "SPOTTED")
                                                switch = true
                                                switchTo = weapons.primary.name
                                                -- hitman:addLineChatElement("Primary" .. dist, 0.8, 0.8, 0.1)
                                            end
                                        end
                                    elseif weapons.secondary.name and weapons.secondary.bulletsLeft > 0 then
                                        if not maxRangePistol then
                                            maxRangePistol = GetRangedRangeCached(weapons.secondary.name, brain)
                                            if not maxRangePistol then return tasks end
                                            maxRangePistolSq = maxRangePistol * maxRangePistol
                                            local maxRangePistolFire = maxRangePistol + rifleDist
                                            maxRangePistolFireSq = maxRangePistolFire * maxRangePistolFire
                                        end
                                        if distSq < maxRangePistolSq then
                                            if hitman:isPrimaryEquipped(weapons.secondary.name) then
                                                if distSq < maxRangePistolFireSq and IsShotClear(hitman, potentialEnemy) then
                                                    firing = true
                                                end
                                            elseif not reload then
                                                Hitman.Say(hitman, "SPOTTED")
                                                switch = true
                                                switchTo = weapons.secondary.name
                                                -- hitman:addLineChatElement("Secondary" .. dist, 0.8, 0.8, 0.1)
                                            end
                                        end
                                    end
                                elseif distSq <= meleeDistSq then
                                    if hitman:isPrimaryEquipped(weapons.melee) then
                                        if not maxRangeMelee then
                                            maxRangeMelee = GetMeleeRangeCached(weapons.melee)
                                            if not maxRangeMelee then return tasks end
                                            maxRangeMeleeSq = maxRangeMelee * maxRangeMelee
                                            local meleeFixRange = maxRangeMelee + 0.1
                                            maxRangeMeleeWithFixSq = meleeFixRange * meleeFixRange
                                        end
                                        if distSq <= maxRangeMeleeWithFixSq then
                                            combat = true
                                        end
                                    else
                                        switch = true
                                        switchTo = weapons.melee
                                        -- hitman:addLineChatElement("Melee" .. dist, 0.8, 0.8, 0.1)
                                    end
                                end
                            end
                        end
                    end
                end
            else
                local distSq = ((zx - potentialEnemy.x) * (zx - potentialEnemy.x)) + ((zy - potentialEnemy.y) * (zy - potentialEnemy.y))
                if distSq < 27.04 then
                    friendlies = friendlies + 1
                    if distSq < 5.76 then
                        friendliesBwd = friendliesBwd + 1
                    end
                end
            end
        end
    end

    if HitmanUtils.GetGameMode() == "Multiplayer" and IsWindowClose(hitman) then
        if hitman:getPrimaryHandItem() then
            hitman:setPrimaryHandItem(nil)
        end
        if hitman:getSecondaryHandItem() then
            hitman:setSecondaryHandItem(nil)
        end
        switch = false
    end
    
    if shove then
        if not HitmanBrain.HasTaskType(brain, "Push") then
            Hitman.ClearTasks(hitman)
            local veh = enemyCharacter:getVehicle()
            if veh then Hitman.Say(hitman, "CAR") end

            if hitman:isFacingObject(enemyCharacter, 0.1) then
                local eid = HitmanUtils.GetCharacterID(enemyCharacter)
                local task = {action="Push", anim="Shove", sound="AttackShove", time=60, endurance=-0.05, eid=eid, x=enemyCharacter:getX(), y=enemyCharacter:getY(), z=enemyCharacter:getZ()}
                table.insert(tasks, task)
            else
                hitman:faceThisObject(enemyCharacter)
            end
        end

    elseif stomp then
        if not HitmanBrain.HasTaskTypes(brain, {"Smack"}) then 
            Hitman.ClearTasks(hitman)

            local eid = HitmanUtils.GetCharacterID(enemyCharacter)
            local task = {action="Smack", time=65, endurance=-0.03, shm=false, weapon=weapons.melee, eid=eid, x=enemyCharacter:getX(), y=enemyCharacter:getY(), z=enemyCharacter:getZ()}
            table.insert(tasks, task)
        end

    elseif switch then
        if not HitmanBrain.HasActionTask(brain) then
            Hitman.ClearTasks(hitman)
            local stasks = HitmanPrograms.Weapon.Switch(hitman, switchTo)
            for _, t in pairs(stasks) do table.insert(tasks, t) end
        end

    elseif combat then
        if not HitmanBrain.HasTaskTypes(brain, {"Smack", "Push", "Equip", "Unequip"}) then 
            Hitman.ClearTasks(hitman)
            local veh = enemyCharacter:getVehicle()
            if veh then Hitman.Say(hitman, "CAR") end

            if hitman:isFacingObject(enemyCharacter, 0.5) then
                local shouldHitMoving = false
                if enemiesBwd >= friendliesBwd + 1 then
                    shouldHitMoving = true
                end
                local eid = HitmanUtils.GetCharacterID(enemyCharacter)
                local task = {action="Smack", time=65, endurance=-0.03, shm=shouldHitMoving, weapon=weapons.melee, eid=eid, x=enemyCharacter:getX(), y=enemyCharacter:getY(), z=enemyCharacter:getZ()}
                table.insert(tasks, task)
            else
                hitman:faceThisObject(enemyCharacter)
            end

        
        elseif instanceof(enemyCharacter, "IsoPlayer") and not Hitman.HasActionTask(hitman) then
            local task = {action="Time", anim="Smoke", time=250}
            table.insert(tasks, task)
            Hitman.Say(hitman, "DEATH")
        end

    elseif enemies >= friendlies + 2 then
        -- fixme: i need to refactror this
        if not HitmanBrain.HasMoveTask(brain) then

            local sx, sy = 0, 0
            local closestDistSq = math.huge
            local closestDX, closestDY = 0, 0
            local threatCount = 0
            local escapeDistSq = escapeDist * escapeDist

            -- =====================================
            -- 1. BUILD DISTANCE-WEIGHTED REPULSION
            -- =====================================

            for id, enemyLight in pairs(potentialEnemyList) do

                if HitmanUtils.AreEnemies(enemyLight.brain, brain) then

                    local dx = zx - enemyLight.x
                    local dy = zy - enemyLight.y
                    local distSq = dx*dx + dy*dy

                    if distSq > 0.01 and distSq < escapeDistSq then

                        threatCount = threatCount + 1

                        -- track closest enemy (for fallback)
                        if distSq < closestDistSq then
                            closestDistSq = distSq
                            closestDX = dx
                            closestDY = dy
                        end

                        local dist = math.sqrt(distSq)

                        -- normalize
                        dx = dx / dist
                        dy = dy / dist

                        -- weight: closer enemies dominate strongly
                        local weight = 1 / distSq

                        sx = sx + dx * weight
                        sy = sy + dy * weight
                    end
                end
            end

            -- =====================================
            -- 2. BREAK PERFECT SYMMETRY
            -- =====================================

            if threatCount > 0 then
                -- perpendicular bias to prevent cancellation
                local perpX = -sy
                local perpY = sx

                sx = sx + perpX * 0.25
                sy = sy + perpY * 0.25
            end

            -- =====================================
            -- 3. NORMALIZE SAFELY
            -- =====================================

            local mag = math.sqrt(sx*sx + sy*sy)

            if mag < 0.001 then
                -- fallback: run opposite closest enemy
                if closestDistSq < math.huge then
                    local dist = math.sqrt(closestDistSq)
                    sx = closestDX / dist
                    sy = closestDY / dist
                else
                    -- absolute fallback (should never happen)
                    local angle = ZombRandFloat(0, math.pi * 2)
                    sx = math.cos(angle)
                    sy = math.sin(angle)
                end
            else
                sx = sx / mag
                sy = sy / mag
            end

            -- =====================================
            -- 4. SMOOTH DIRECTION (ANTI-JITTER)
            -- =====================================

            if brain.escapeX and brain.escapeY then
                sx = sx * 0.7 + brain.escapeX * 0.3
                sy = sy * 0.7 + brain.escapeY * 0.3

                local smag = math.sqrt(sx*sx + sy*sy)
                if smag > 0 then
                    sx = sx / smag
                    sy = sy / smag
                end
            end

            brain.escapeX = sx
            brain.escapeY = sy

            -- =====================================
            -- 5. COMPUTE TARGET (NO SQUARE SCAN)
            -- =====================================

            local baseDist = 6
            local scale = math.min(threatCount, 5) * 1.5
            local runDist = baseDist + scale

            local nbx = zx + sx * runDist
            local nby = zy + sy * runDist
            local nbz = zz

            -- =====================================
            -- 6. ISSUE MOVE TASK
            -- =====================================

            Hitman.ClearTasks(hitman)

            local task = HitmanUtils.GetMoveTask(
                0.01,
                nbx,
                nby,
                nbz,
                "Run",
                12,
                false
            )

            task.time = 140 + threatCount * 30
            task.backwards = false

            table.insert(tasks, task)
        end

    elseif HitmanCompatibility.GetGameVersion() >= 42 and enemiesBwd >= 2 then
        if not Hitman.HasMoveTask(hitman) and not Hitman.HasTaskType(hitman, "Shove") and not Hitman.HasTaskType(hitman, "Hit") then
            Hitman.ClearTasks(hitman)
            -- hitman:addLineChatElement("Slow", 0.8, 0.8, 0.1)
            local mrad = math.atan2(sy, sx)
            local mdeg = math.deg(mrad)
            local l = 1
            local nbx = zx + (l * math.cos(mrad))
            local nby = zy + (l * math.sin(mrad))
            local nbz = zz
            local task = HitmanUtils.GetMoveTask(0.01, nbx, nby, nbz, "WalkBwdAim", l, false)
            task.backwards = true
            task.lock = false
            table.insert(tasks, task)

        end

    elseif healing then
        if not HitmanBrain.HasTaskType(brain, "Bandage") then
            local task = {action="Bandage"}
            table.insert(tasks, task)
        end

    elseif firing then
        if not HitmanBrain.HasTaskTypes(brain, {"Shoot", "Turn", "Aim", "Rack", "Equip", "Unequip", "Load", "Unload"}) then 
            Hitman.ClearTasks(hitman)
            if enemyCharacter:isAlive() then
                
                local veh = enemyCharacter:getVehicle()
                if veh then Hitman.Say(hitman, "CAR") end

                if hitman:isFacingObject(enemyCharacter, 0.1) then
                    for _, slot in pairs({"primary", "secondary"}) do
                        
                        if weapons[slot].name then

                            if weapons[slot].bulletsLeft > 0 then
                                if not weapons[slot].racked then
                                        local stasks = HitmanPrograms.Weapon.Rack(hitman, slot)
                                        for _, t in pairs(stasks) do table.insert(tasks, t) end

                                elseif not Hitman.IsAim(hitman) then
                                    local stasks = HitmanPrograms.Weapon.Aim(hitman, enemyCharacter, slot)
                                    for _, t in pairs(stasks) do table.insert(tasks, t) end

                                elseif weapons[slot].bulletsLeft > 0 then
                                    local stasks = HitmanPrograms.Weapon.Shoot(hitman, enemyCharacter, slot)
                                    for _, t in pairs(stasks) do table.insert(tasks, t) end

                                end

                                break

                            elseif (weapons[slot].type == "mag"  and weapons[slot].magCount > 0) or
                                (weapons[slot].type == "nomag" and weapons[slot].ammoCount > 0) then

                                Hitman.Say(hitman, "RELOADING")

                                local stasks = HitmanPrograms.Weapon.Reload(hitman, slot)
                                for _, t in pairs(stasks) do table.insert(tasks, t) end

                                break
                            end
                            
                        end
                    end
                else
                    hitman:faceThisObject(enemyCharacter)
                end

            elseif instanceof(enemyCharacter, "IsoPlayer") then
                local task = {action="Time", anim="Smoke", time=250}
                table.insert(tasks, task)
                Hitman.Say(hitman, "DEATH")
            end

        end
    elseif reload then
        if not HitmanBrain.HasActionTask(brain) then
            for _, slot in pairs({"primary", "secondary"}) do
                if weapons[slot].name and hitman:isPrimaryEquipped(weapons[slot].name) then
                    Hitman.ClearTasks(hitman)
                    Hitman.Say(hitman, "RELOADING")
                    local stasks = HitmanPrograms.Weapon.Reload(hitman, slot)
                    for _, t in pairs(stasks) do table.insert(tasks, t) end
                end
            end
        end
    elseif false and resupply then
        if not HitmanBrain.HasTask(brain) then
            local stasks = HitmanPrograms.Weapon.Resupply(hitman)
            for _, t in pairs(stasks) do table.insert(tasks, t) end
        end
    end

    return tasks
end

-- manages multiplayer social distance hack
local function ManageSocialDistance(hitman)
    local bx, by, bz = hitman:getX(), hitman:getY(), hitman:getZ()
    local brain = HitmanBrain.Get(hitman)
    
    if brain.hostile or brain.hostileP then return end

    local playerList = HitmanPlayer.GetPlayers()

    -- Iterate through players
    for i = 0, playerList:size() - 1 do
        local player = playerList:get(i)
        if player then
            -- Cache player's position and vehicle status
            local px, py, pz = player:getX(), player:getY(), player:getZ()
            local veh = player:getVehicle()
            local asn = hitman:getActionStateName()
            
            -- Calculate distance only once and check if conditions are met
            -- local dist = HitmanUtils.DistToManhattan(bx, by, px, py)
            local distSq = ((bx - px) * (bx - px)) + ((by - py) * (by - py))
            if bz == pz and distSq < 9 and not veh and asn ~= "onground" then
                hitman:setUseless(true)
                break
            else
                hitman:setUseless(false)
            end
        end
    end
end

-- table of hitmans being attacked by zombies
local biteTab = {}

-- manages zombie behavior towards hitmans
local function UpdateZombies(zombie)

    local player = getSpecificPlayer(0)
    if not player then return end

    local target = zombie:getTarget()
    if target and target:getVariableBoolean("Hitman") then
        zombie:setVariable("NoLungeAttack", true)
    else
        zombie:setVariable("NoLungeAttack", false) -- Re-enable lunge for zombies targeting players
    end

    if zombie:getVariableBoolean("Hitman") then return end

    local asn = zombie:getActionStateName()
    local zid = zombie:getModData().hitmanZid
    if zid and biteTab[zid] and (zombie:getBumpType() == "Bite" or zombie:getBumpType() == "BiteLow") and asn == "bumped" then
        local tick = biteTab[zid].tick
        if tick == 14 then
            local hitman = biteTab[zid].hitman
            local dist = HitmanUtils.DistTo(zombie:getX(), zombie:getY(), hitman:getX(), hitman:getY())
            if dist < 0.8 then 
                if ZombRand(4) == 1 then
                    zombie:playSound("ZombieBite")
                else
                    zombie:playSound("ZombieScratch")
                end

                local teeth = HitmanCompatibility.InstanceItem("Base.RollingPin")
                HitmanCompatibility.Splash(hitman, teeth, zombie)
                hitman:setHitFromBehind(zombie:isBehind(hitman))
        
                if instanceof(hitman, "IsoZombie") then
                    -- hitman:setHitAngle(zombie:getForwardDirection())
                    hitman:setPlayerAttackPosition(hitman:testDotSide(zombie))
                end
        
                if not hitman:isOnKillDone() and not Hitman.HasTaskType(hitman, "Die") then
                    Hitman.ClearTasks(hitman)
                    -- hitman:setBumpDone(true)
                    hitman:Hit(teeth, zombie, 1.01, false, 1, false)
                    Hitman.Say(hitman, "DRAGDOWN", true)
                    Hitman.UpdateInfection(hitman, 0.001)

                    local h = hitman:getHealth()
                    local id = HitmanUtils.GetCharacterID(hitman)
                    local args = {id=id, h=h}
                    sendClientCommand(getSpecificPlayer(0), 'Hitman_Sync', 'Health', args)
                end
            end
        elseif tick >= 16 then
            biteTab[zid] = nil
            zombie:getModData().hitmanZid = nil
            return
        end
        biteTab[zid].tick = tick + 1
        return
    end


    local stuckTime = zombie:getModData().stuckTime or 0

    --[[
    if ans == "turnalerted" then
        stuckTime = stuckTime + 1
        zombie:getModData().stuckTime = stuckTime

        -- If the zombie stays in turnalerted for too long (≈5 seconds)
        if stuckTime > 300 then
            zombie:getModData().stuckTime = 0
            zombie:setActionStateName("idle")
            zombie:setTurnDelta(0)
            zombie:setTurnAlertedValues(0, 0)
            zombie:resetModelNextFrame()
        end
    end]]

    if asn == "bumped" or asn == "onground" or asn == "climbfence" or asn == "getup" or asn == "turnalerted" then
        return
    end
    if zombie:isProne() then return end

    -- Recycle brain and handle useless state
    HitmanBrain.Remove(zombie)
    if zombie:isUseless() then
        zombie:setUseless(false)
    end

    -- Handle primary and secondary hand items
    local phi = zombie:getPrimaryHandItem()
    if phi then zombie:setPrimaryHandItem(nil) end
    local shi = zombie:getSecondaryHandItem()
    if shi then 
        zombie:setSecondaryHandItem(nil) 
    end

    -- Handle zombie target and teeth state
    local target = zombie:getTarget()
    if target and instanceof(target, "IsoZombie") then
        zombie:setVariable("ZombieBiteDone", true)
        zombie:setNoTeeth(true)
    else
        zombie:setNoTeeth(false)
    end

    -- Clear invalid target
    --[[
    if target and (not target:isAlive() or not zombie:CanSee(target)) then
        zombie:setTarget(nil)
    end]]

    -- Stop sound if playing
    --[[
    local emitter = zombie:getEmitter()
    if emitter:isPlaying("ChainsawIdle") then
        emitter:stopSoundByName("ChainsawIdle")
    end]]

    -- Fetch zombie coordinates and closest hitman location
    local zx, zy, zz = zombie:getX(), zombie:getY(), zombie:getZ()

    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local distPlayer2 = ((px - zx) * (px - zx)) + ((py - zy) * (py - zy))
    if distPlayer2 < 4 and math.abs(pz - zz) < 0.3 then
        return
    end

    local hitmanList = HitmanZombie.CacheLightB
    local dist2max = math.huge
    local hitmanCached = nil
    for _, hitman in pairs(hitmanList) do
        local dz = math.abs(hitman.z - zz)
        if dz < 0.31 then
            local dx = hitman.x - zx
            local dy = hitman.y - zy
            local distManhattan = math.abs(dx) + math.abs(dy)

            -- broad-phase gate for the later Euclidean radius check (dist2max < 400)
            if distManhattan <= 28 then
                -- dynamic prune: if L1^2 >= 2 * bestDistSq, candidate cannot beat current best
                local manhattanSq = distManhattan * distManhattan
                if manhattanSq < (2 * dist2max) then
                    local dist2 = (dx * dx) + (dy * dy)
                    if dist2 < dist2max then
                        dist2max = dist2
                        hitmanCached = hitman
                    end
                end
            end
        end
    end

    -- local enemy = HitmanUtils.GetClosestHitmanLocation(zombie)

    -- If hitman is in range, proceed
    if hitmanCached and dist2max < 400 then
        --local player = HitmanUtils.GetClosestPlayerLocation(zombie, true)
        
        -- Skip if player is closer than the hitman
        --if player.dist < enemy.dist then return end

        local hitman = HitmanZombie.Cache[hitmanCached.id]
        -- local bx, by, bz = hitman:getX(), hitman:getY(), hitman:getZ()
        -- local dist = math.sqrt(((hitmanCached.x - zx) * (hitmanCached.x - zx)) + ((hitmanCached.y - zy) * (hitmanCached.y - zy)))

        -- Standard movement if hitman is far

        if dist2max > 9 then
            -- zombie:addLineChatElement(tostring(ZombRand(100)) .. " far", 0.6, 0.6, 1)
            --
            if zombie:CanSee(hitman) then
                zombie:pathToCharacter(hitman)
            end

        -- Approach hitman if in range
        else
            -- zombie:addLineChatElement(string.format("mid %.2f", dist2max), 0.6, 0.6, 1)
            
            -- local tempTarget = HitmanUtils.CloneIsoPlayer(hitman)
            -- if zombie:CanSee(hitman) and zombie:CanSee(player) then
                -- if HitmanCompatibility.GetGameVersion() >= 42 then
                    -- zombie:pathToCharacter(hitman)
                -- end
                -- if not zombie:getTarget() then
                    -- zombie:addLineChatElement(string.format("SPOTTED %.2f", enemy.dist), 0.6, 0.6, 1)
                    -- zombie:changeState(LungeState.instance())
                    -- zombie:getPathFindBehavior2():cancel()
                    -- zombie:setPath2(nil)

                    if zombie and hitman  then
                        zombie:spotted(hitman, true)
                        zombie:addAggro(hitman, 1)
                        zombie:setTarget(hitman)
                        zombie:setAttackedBy(hitman)
                   
                        --[[
                        zombie:spotted(hitman, true)
                        zombie:setTarget(hitman)
                        zombie:setAttackedBy(hitman)
                        ]]
                    end
                    
                    
                    --tempTarget:removeFromWorld()
                    -- tempTarget = nil

                -- end
            -- end
            if dist2max < 0.64 and math.abs(zz - hitmanCached.z) < 0.3 then
                
                local zombieSquare = zombie:getSquare()
                local hitmanSquare = hitman:getSquare()
                if zombieSquare then
                    local isWallTo = zombieSquare:isSomethingTo(hitmanSquare)
                    if not isWallTo then


                        if zombie:isFacingObject(hitman, 0.3) then
                            -- Optimized close-range attack logic
                            local attackingZombiesNumber = 0
                            for id, attackingZombie in pairs(HitmanZombie.CacheLightZ) do
                                -- local distManhattan = HitmanUtils.DistToManhattan(attackingZombie.x, attackingZombie.y, enemy.x, enemy.y)
                                if math.abs(attackingZombie.x - hitmanCached.x) + math.abs(attackingZombie.y - hitmanCached.y) < 1 then
                                    -- local dist = HitmanUtils.DistTo(attackingZombie.x, attackingZombie.y, enemy.x, enemy.y)
                                    local distSq = ((attackingZombie.x - hitmanCached.x) * (attackingZombie.x - hitmanCached.x)) + ((attackingZombie.y - hitmanCached.y) * (attackingZombie.y - hitmanCached.y))
                                    if distSq < 0.36 then
                                        attackingZombiesNumber = attackingZombiesNumber + 1
                                        if attackingZombiesNumber > 2 then break end
                                    end
                                end
                            end

                            -- If more than 2 zombies attacking, initiate death task
                            if attackingZombiesNumber > 2 then
                                if hitman:getActionStateName() == "onground" then
                                    Hitman.Say(hitman, "DRAGDOWN", true)
                                    zombie:die()
                                else
                                    if not Hitman.HasTaskType(hitman, "Die") then
                                        Hitman.ClearTasks(hitman)
                                        
                                        local task = {action="Die", lock=true, anim="Die", time=300}
                                        Hitman.AddTask(hitman, task)
                                    end
                                end
                                return
                            end

                            if zombie:getBumpType() ~= "Bite" and zombie:getBumpType() ~= "BiteLow" and asn ~= "staggerback" then
                                -- prevents zombie into entering real attack state (we want simulate our own attack)
                                -- zombie:setVariable("bAttack", false)
                                hitman:setZombiesDontAttack(true)
                                if hitman:isProne() or hitman:isCrawling() then
                                    zombie:setBumpType("BiteLow")
                                else
                                    zombie:setBumpType("Bite")
                                end
                                local zid = HitmanUtils.GetCharacterID(zombie)
                                zombie:getModData().hitmanZid = zid 
                                biteTab[zid] = {hitman=hitman, tick=0}
                                -- zombie:addLineChatElement("BITE", 0.8, 0.8, 0.1)
                            end
                        else
                            zombie:faceThisObject(hitman)
                        end
                    end
                end
            end
        end
    end
end


local function ProcessTask(hitman, task)

    if not task.action then return end
    if not task.state then task.state = "NEW" end

    
    -- hitman:addLineChatElement(task.action .. tostring(ZombRand(1000), 0.8, 0.8, 0.1))

    if task.state == "NEW" then
        -- print ("new: " .. hitman:getActionStateName() .. " " .. hitman:getBumpType() .. " " .. hitman:getVariableString("HitmanWalkType"))
        if not task.time then task.time = 1000 end
        
        if task.action ~= "Shoot" and task.action ~= "Aim" and task.action ~= "Rack"  and task.action ~= "Load" and task.action ~= "Bandage" then
            Hitman.SetAim(hitman, false)
        end

        if task.action ~= "Move" and task.action ~= "GoTo" then
            if Hitman.IsMoving(hitman) then
                Hitman.SetMoving(hitman, false)
            end
        end

        if task.sound then
            local player = getSpecificPlayer(0)
            if player then
                local play = true
                if task.soundDistMax then
                    local dist = HitmanUtils.DistTo(hitman:getX(), hitman:getY(), player:getX(), player:getY())
                    if dist > task.soundDistMax then
                        play = false
                    end
                end

                if play then
                    local emitter = hitman:getEmitter()
                    if not emitter:isPlaying(task.sound) then
                        emitter:playSound(task.sound)
                    end
                end
            end
        end

        if task.anim then
            hitman:setBumpType(task.anim)
        end

        local done = HitmanZombieActions[task.action].onStart(hitman, task)

        if done then 
            task.state = "WORKING"
            --Hitman.UpdateTask(hitman, task)
        end

    elseif task.state == "WORKING" then
        -- print ("working: " .. hitman:getActionStateName() .. " " .. hitman:getBumpType()  .. hitman:getVariableString("HitmanWalkType"))
        -- normalize time speed
        local decrement = 1 / ((getAverageFPS() + 0.5) * 0.01666667)
        --local decrement = 1 / ((60 + 0.5) * 0.01666667)
        task.time = task.time - decrement

        local done = HitmanZombieActions[task.action].onWorking(hitman, task)
        if done or task.time <= 0 then 

            if HitmanZombieActions[task.action].onComplete then
                task.state = "COMPLETED"
            else
                Hitman.RemoveTask(hitman)
            end
            
        end

    elseif task.state == "COMPLETED" then
        -- print ("working: " .. hitman:getActionStateName() .. " " .. hitman:getBumpType() .. " " .. hitman:getVariableString("HitmanWalkType"))
        if task.sound then
            local emitter = hitman:getEmitter()
            if not emitter:isPlaying(task.sound) then
                hitman:playSound(task.sound)
            end
        end
        
        if task.endurance then
            Hitman.UpdateEndurance(hitman, task.endurance)
        end

        local done = HitmanZombieActions[task.action].onComplete(hitman, task)

        if done then 
            Hitman.RemoveTask(hitman)
            -- hitman:setBumpDone(true)
            -- hitman:setBumpType("")
        end
    end
end

local function GenerateTask(hitman)
    local tasks = {}
    
    -- MANAGE HITMAN ENDURANCE LOSS
    -- local ts = getTimestampMs()
    local enduranceTasks = ManageEndurance(hitman)
    -- local elapsed = getTimestampMs() - ts
    -- if elapsed > 1 then
    --     print ("ManageEndurance: " .. elapsed)
    -- end
    if #enduranceTasks > 0 then
        for _, t in pairs(enduranceTasks) do table.insert(tasks, t) end
    end
    
    -- MANAGE BLEEDING AND HEALING
    if #tasks == 0 then
        -- local ts = getTimestampMs()
        local healingTasks = ManageHealth(hitman)
        -- local elapsed = getTimestampMs() - ts
        -- if elapsed > 1 then
        --    print ("ManageHealth: " .. elapsed)
        --end
        
        if #healingTasks > 0 then
            for _, t in pairs(healingTasks) do table.insert(tasks, t) end
        end
    end

    -- MANAGE MELEE / SHOOTING TASKS
    if #tasks == 0  then
        -- local ts = getTimestampMs()
        local combatTasks = ManageCombat(hitman)
        -- local elapsed = getTimestampMs() - ts
        -- if elapsed > 1 then
        --     print ("ManageCombat: " .. elapsed)
        -- end
        if #combatTasks > 0 then
            for _, t in pairs(combatTasks) do table.insert(tasks, t) end
        end
    end

    -- MANAGE COLLISION TASKS
    if #tasks == 0 then
        -- local ts = getTimestampMs()
        local colissionTasks = ManageCollisions(hitman)
        -- local elapsed = getTimestampMs() - ts
        -- if elapsed > 1 then
        --     print ("ManageCollisions: " .. elapsed)
        -- end
        if #colissionTasks > 0 then
            for _, t in pairs(colissionTasks) do table.insert(tasks, t) end
        end
    end
    
    -- CUSTOM PROGRAM 
    if #tasks == 0 and not Hitman.HasTask(hitman) then
        local program = Hitman.GetProgram(hitman)
        if program and program.name and program.stage  then
            -- local ts = getTimestampMs()
            local res = HitmanZombiePrograms[program.name][program.stage](hitman)
            -- local elapsed = getTimestampMs() - ts
            -- if elapsed > 1 then
            --     print ("CustomProgram: " .. program.name .. " " .. program.stage .. " ".. elapsed)
            -- end
            if res.status and res.next then
                Hitman.SetProgramStage(hitman, res.next)
                for _, task in pairs(res.tasks) do
                    table.insert(tasks, task)
                end
            else
                local task = {action="Time", anim="Shrug", time=200}
                table.insert(tasks, task)
            end
        end
    end
    

    if #tasks > 0 then
        local brain = HitmanBrain.Get(hitman)
        for _, task in pairs(tasks) do
            table.insert(brain.tasks, task)
        end
        -- HitmanBrain.Update(zombie, brain)
    end
end

-- main function to handle hitmans
local function OnHitmanUpdate(zombie)
    
    local ts = getTimestampMs()
    
    if isServer() then return end
    if not Hitman.Engine then return end
    if HitmanCompatibility.IsReanimatedForGrappleOnly(zombie) then return end
    if HitmanCompatibility.IsRagdoll(zombie) then return end

    local isMP = HitmanUtils.GetGameMode() == "Multiplayer"

    -- hack for multiplayer
    if isMP then
        local i1 = zombie:getPrimaryHandItem()
        local i2 = zombie:getSecondaryHandItem()
        if (i1 or i2) and IsWindowClose(zombie) then
            if i1 then
                zombie:setPrimaryHandItem(nil)
                zombie:setVariable("HitmanPrimary", "")
                zombie:setVariable("HitmanPrimaryType", "")
            end
            if i2 then
                zombie:setSecondaryHandItem(nil)
            end
        end
    end
    
    if zombie:isCrawling() then
        local target = zombie:getTarget()
        if target and instanceof(target, "IsoPlayer") and not target:getVariableBoolean("Hitman") then
            local targetSquare = target:getSquare()
            local zombieSquare = zombie:getSquare()
            if targetSquare and zombieSquare then
                local zx, zy, zz = zombie:getX(), zombie:getY(), zombie:getZ()
                local px, py, pz = target:getX(), target:getY(), target:getZ()
                local dist2 = ((zx - px) * (zx - px)) + ((zy - py) * (zy - py))

                if dist2 < 0.64 and math.abs(zz - pz) < 0.3 and zombie:CanSee(target) then
                    -- Check if there is no wall between zombie and player
                    
                    local isWallTo = zombieSquare:isSomethingTo(targetSquare)
                    if not isWallTo and zombie:isFacingObject(target, 0.3) then
                        -- Enable lunging for players
                        zombie:changeState(LungeState.instance())
                        zombie:getPathFindBehavior2():cancel()
                        zombie:setPath2(nil)
                        return -- Important: Exit the function to avoid further processing
                    end
                end
            end
        end
    end
    
    local id = HitmanUtils.GetZombieID(zombie)
    local zx = zombie:getX()
    local zy = zombie:getY()
    local zz = zombie:getZ()

    -- local cell = getCell()
    -- local world = getWorld()
    -- local gamemode = world:getGameMode()
    local brain = HitmanBrain.Get(zombie)
    
    -- HITMANIZE ZOMBIES SPAWNED AND ENQUEUED BY SERVER
    -- OR ZOMBIFY IF HAS BEEN REMOVED FROM CLUSTER
    local gmd = GetHitmanClusterData(id)
    if gmd and gmd[id] then
        if not zombie:getVariableBoolean("Hitman") then
            brain = gmd[id]
            Hitmanize(zombie, brain)
        end
    else
        if zombie:getVariableBoolean("Hitman") then
            Zombify(zombie)
        end
    end
    
    UpdateZombies(zombie)

    local asn = zombie:getActionStateName()
    if asn == "onground" then
        local h = zombie:getHealth()
        if h <= 0 then
            zombie:setAttackedBy(getCell():getFakeZombieForHit())
            zombie:die()
        end
    end

    ------------------------------------------------------------------------------------------------------------------------------------
    -- HITMAN UPDATE AFTER THIS LINE
    ------------------------------------------------------------------------------------------------------------------------------------
    if not zombie:getVariableBoolean("Hitman") then return end
    if not brain then return end

    -- distant hitmans are not updated by this mod so they need to be set useless
    -- to prevent game updating them as if they were zombies
    if HitmanZombie.CacheLightB[id] then 
        zombie:setUseless(false)
    else
        zombie:setUseless(true)
        return
    end
    
    local hitman = zombie

    if HitmanCompatibility.GetGameVersion() >= 42 then
        hitman:setAnimatingBackwards(false)
    end

    -- WALKTYPE
    -- we do it this way, if walktype get overwritten by game engine we force our animations
    hitman:setWalkType(hitman:getVariableString("HitmanWalkType"))
    -- hitman:addLineChatElement(hitman:getVariableString("HitmanWalkType"))
    hitman:setSpeedMod(1)

    -- NO ZOMBIE SOUNDS
    Hitman.SurpressZombieSounds(hitman)

    -- CANNIBALS
    if not brain.eatBody then
        hitman:setEatBodyTarget(nil, false)
    end
    
    -- ADJUST HUMAN VISUALS
    Hitman.ApplyVisuals(hitman, brain)

    -- MANAGE HITMAN TORCH
    --
    ManageTorch(hitman, brain)

    -- MANAGE HITMAN CHAINSAW
    -- ManageChainsaw(hitman)

    -- MANAGE HITMAN BEING ON FIRE
    ManageOnFire(hitman)

    -- MANAGE HITMAN SPEECH COOLDOWN
    ManageSpeechCooldown(brain)

    -- ACTION STATE TWEAKS
    -- local ts = getTimestampMs()
    local continue = ManageActionState(hitman)
    -- local elapsed = getTimestampMs() - ts
    -- if elapsed > 1 then
    --    print ("ManageActionState: " .. elapsed)
    -- end

    if not continue then return end
    
    -- COMPANION SOCIAL DISTANCE HACK
    -- local ts = getTimestampMs()
    if isMP then
        ManageSocialDistance(hitman)
    end
    -- local elapsed = getTimestampMs() - ts
    -- if elapsed > 1 then
    --     print ("ManageSocialDistance: " .. elapsed)
    -- end

    -- CRAWLERS SCREAM OCASSINALLY
    if hitman:isCrawling() then
        Hitman.Say(hitman, "DEAD")
    end
    
    GenerateTask(hitman)

    local task = Hitman.GetTask(hitman)
    if task then
    
        -- local ts = getTimestampMs()
        ProcessTask(hitman, task)
        -- local elapsed = getTimestampMs() - ts
        -- if elapsed > 1 then
        --     print ("ProcessTask " .. task.action .. "(" .. task.state .. "): " .. elapsed)
        -- end
    else
        local task = {action = "Idle", time = 100}
        ProcessTask(hitman, task)
    end
end

local function OnHitZombie(zombie, attacker, bodyPartType, handWeapon)
    
    --[[
    local visuals = zombie:getHumanVisual()
    local femaleChance = zombie:isFemale() and 100 or 0
    local hairModel = visuals:getHairModel()
    local hairColor = visuals:getHairColor()
    local beardModel
    local beardColor
    if femaleChance == 0 then
        beardModel = visuals:getBeardModel()
        beardColor = visuals:getBeardColor()
    end
    
    visuals:setSkinTextureName("MaleBody01_Headless")
    visuals:setHairModel("Bald")
    zombie:resetModel()

    -- PONGDU: Naked1..Naked100 only. "Naked101" does not exist and the engine would fall back
    -- to a random outfit, which can be a PongDuMutant_* outfit (mutant identity is the outfit name)
    local outfit = "Naked" .. (1 + ZombRand(100))
    local zombieList = HitmanCompatibility.AddZombiesInOutfit(zombie:getX(), zombie:getY(), zombie:getZ(), outfit, femaleChance, 
                                                              false, false, false, 
                                                              false, false, false,
                                                              1)

    if zombieList:size() > 0 then
        local head = zombieList:get(0)
        -- local head = createZombie(zombie:getX(), zombie:getY(), zombie:getZ(), nil, femaleChance, IsoDirections.fromAngle(zombie:getForwardDirection()))
        local headVisuals = head:getHumanVisual()
        local headItemVisuals = head:getItemVisuals()
        headItemVisuals:clear()
        head:dressInNamedOutfit("Naked1")
        headVisuals:setSkinTextureName("MaleBody01_Head")
        headVisuals:setHairModel(hairModel)
        headVisuals:setHairColor(hairColor)
        if femaleChance == 0 then
            headVisuals:setBeardModel(beardModel)
            headVisuals:setBeardColor(beardColor)
        end
        head:resetModel()
        head:resetModelNextFrame()
        head:setHealth(0)
    end
    ]]



    if not zombie:getVariableBoolean("Hitman") then return end

    local hitman = zombie

    Hitman.AddVisualDamage(hitman, handWeapon)
    Hitman.ClearTasks(hitman)
    Hitman.Say(hitman, "HIT", true)
    if Hitman.IsSleeping(hitman) then
        local task = {action="Time", lock=true, anim="GetUp", time=150}
        Hitman.ClearTasks(hitman)
        Hitman.AddTask(hitman, task)
        Hitman.SetSleeping(hitman, false)
        Hitman.SetProgramStage(hitman, "Prepare")
    end

    HitmanPlayer.CheckFriendlyFire(hitman, attacker)

    if handWeapon:isRanged() and instanceof(attacker, "IsoPlayer") then
        local bodyPartTypes = {
            Foot_R = {},
            Foot_L = {},
            LowerLeg_R = {},
            LowerLeg_L = {},
            UpperLeg_R = {},
            UpperLeg_L = {},
            Groin = {serious = true},
            Neck = {serious = true},
            Head = {insta = true},
            Torso_Lower = {serious = true},
            Torso_Upper = {serious = true},
            UpperArm_R = {},
            UpperArm_L = {},
            ForeArm_R = {},
            ForeArm_L = {},
            Hand_R = {},
            Hand_L = {}
        }

        for k, tab in pairs(bodyPartTypes) do
            if BodyPartType[k] == bodyPartType then
                local idx = BodyPartType.ToIndex(bodyPartType)
                local def = hitman:getBodyPartClothingDefense(idx, false, true)
                local rnd = ZombRand(100)
                if rnd > def then
                    if tab.insta then
                        hitman:Kill(nil)
                        return
                    end
                    if tab.serious then
                        local maxDmg = handWeapon:getMaxDamage() or 1
                        local extraDmg = 0.26 * maxDmg
                        local health = hitman:getHealth() - extraDmg
                        if health <=0 then
                            hitman:Kill(nil)
                            return
                        else
                            hitman:setHealth(health)
                        end
                    end
                end
            end
        end
    end
end

local function OnZombieDead(hitman)

    if hitman:getVariableBoolean("Hitman") then 

        local brain = HitmanBrain.Get(hitman)

        local veh = hitman:getVehicle()
        if veh then veh:exit(hitman) end

        -- PONGDU: corpse loot moved to shared/HitmanDeathLoot.lua (Hitman.BuildDeathLoot).
        -- SP builds it here like the original. In MP the server builds it (server/HitmanServerLoot.lua)
        -- and sends it with the corpse; the client must not touch the corpse inventory.
        if brain and not isClient() then
            Hitman.BuildDeathLoot(hitman, brain)
        end

        Hitman.Say(hitman, "DEAD", true)

        -- update player kills
        local player = getSpecificPlayer(0)
        local killer = hitman:getAttackedBy()
        if killer then
            if killer == player then
                player:setZombieKills(player:getZombieKills() - 1)
            end
        end

        -- warning: bwo overwrites CheckFriendlyFire
        local attacker = hitman:getAttackedBy()
        -- HitmanPlayer.CheckFriendlyFire(hitman, attacker)

        -- deprovision
        hitman:setUseless(false)
        hitman:setReanim(false)
        hitman:setVariable("Hitman", false)
        hitman:setVariable("LimpSpeed", 0.3)
        hitman:setVariable("RunSpeed", 0.3)
        hitman:setVariable("WalkSpeed", 0.3)
        hitman:setPrimaryHandItem(nil)
        hitman:clearAttachedItems()
        hitman:resetEquippedHandsModels()
        hitman:getModData().isDeadHitman = true

        if brain then
            local args = {}
            args.id = brain.id
            sendClientCommand(player, 'Hitman_Commands', 'HitmanRemove', args)
            HitmanBrain.Remove(hitman)
        end

        --[[
        local bx, by = hitman:getX(), hitman:getY()
        local zombieList = HitmanZombie.CacheLightZ
        for id, zombie in pairs(zombieList) do
            local dist = math.abs(bx - zombie.x) + math.abs(by - zombie.y)
            if dist < 10 then
                local zombie = HitmanZombie.Cache[id]
                if zombie then
                    zombie:setEatBodyTarget(hitman, true)
                end
            end
        end
        ]]
    end

    --[[
    -- stale corpse removal hack fro b42, it replaces the dying zombie with a deadbody
    -- and copies most of the properties to look as the original 
    if Hitman.Settings.CorpseSwapper and HitmanCompatibility.GetGameVersion() >= 42 then
        local isSeen = false
        local playerList = HitmanPlayer.GetPlayers()
        for i=0, playerList:size()-1 do
            local player = playerList:get(i)
            if player then
                if  player:CanSee(hitman) then
                    if hitman:getSquare():isCanSee(0) then
                        isSeen = true
                    end
                end
            end
        end

        --[[
        if not isSeen and not hitman:getVariableBoolean("HitmanBecomingCorpse") then
            hitman:setVariable("HitmanBecomingCorpse", true)
            hitman:getModData().isDeadHitman = false
            local wornItems = hitman:getWornItems()
            local inv = hitman:getInventory()
            local hv = hitman:getHumanVisual()
            local arrItems = ArrayList.new()
            inv:getAllEvalRecurse(predicateAll, arrItems)

            
            local hitman2 = createZombie(hitman:getX(), hitman:getY(), hitman:getZ(), nil, 0, IsoDirections.fromAngle(hitman:getForwardDirection()))
            local hv2 = hitman2:getHumanVisual()
            hitman2:setFemale(hitman:isFemale())
            hv2:setSkinTextureName(hv:getSkinTexture())
            hv2:setHairModel(hv:getHairModel())
            hv2:setBeardModel(hv:getHairModel())
            hv2:setHairColor(hv:getHairColor()) 
            hv2:setBeardColor(hv:getBeardColor())

            for it, _ in pairs(HitmanUtils.ItemVisuals) do
                if ZombRand(3) == 0 and it:embodies("ZedDmg") then
                    hv2:addBodyVisualFromItemType(it)
                end
            end
    
            local maxIndex = BloodBodyPartType.MAX:index()
            for i = 0, maxIndex - 1 do
                local part = BloodBodyPartType.FromIndex(i)
                hv2:setBlood(part, 1)
                hv2:setDirt(part, 1)
            end
            
            hitman2:setWornItems(wornItems)
            hitman2:setAttachedItems(hitman:getAttachedItems())
            hitman2:getModData().isDeadHitman = false

            local body = IsoDeadBody.new(hitman2, false);
            inv2 = body:getContainer()
            for i = 0, wornItems:size() - 1 do
                local wornItem = wornItems:get(i)
                local item = wornItem:getItem()
                inv2:AddItem(item)
            end

            for i = 0, arrItems:size()-1 do
                local item = arrItems:get(i)
                inv2:AddItem(item)
            end

            hitman:removeFromSquare()
            hitman:removeFromWorld()
            
            hitman2:removeFromWorld()
            hitman2:removeFromSquare()
            -- print ("----- CORPSE SWAPPED ------")
        end
    end
    ]]

end

local function OnDeadBodySpawn(body)
    --[[
    local hv = body:getHumanVisual()
    local skin = hv:getSkinTexture()
    if skin:find("^FemaleBody") or skin:find("^MaleBody") then
        local age = getGameTime():getWorldAgeHours()
        body:setReanimateTime(age + ZombRandFloat(0.1, 0.7))
    end
    ]]
    local md = body:getModData()
    if md.isDeadHitman then
        if md.isDeadHitman == true then
            local player = getSpecificPlayer(0)
            md.isDeadHitman = false
            local args = {
                x = body:getX(),
                y = body:getY(),
                z = body:getZ(),
                id = md.hitmanBrainId
            }
            sendClientCommand(player, 'Hitman_Commands', 'HitmanCorpse', args)
        end
    end
end

local function perf()
    print ("HITMAN UPDATE REPORT: invocations: " .. "short: " .. iter1 .. "( " .. sum1.. "), medium: " .. iter2 .. "(" .. sum2 .. "), long: " .. iter3 .. "(" .. sum3.. ")")
    iter1 = 0
    iter2 = 0
    iter3 = 0
    sum1 = 0
    sum2 = 0
    sum3 = 0
end

Events.OnZombieUpdate.Remove(OnHitmanUpdate)
Events.OnZombieUpdate.Add(OnHitmanUpdate)

Events.OnHitZombie.Remove(OnHitZombie)
Events.OnHitZombie.Add(OnHitZombie)

Events.OnZombieDead.Remove(OnZombieDead)
Events.OnZombieDead.Add(OnZombieDead)

Events.OnDeadBodySpawn.Remove(OnDeadBodySpawn)
Events.OnDeadBodySpawn.Add(OnDeadBodySpawn)

-- Events.EveryOneMinute.Remove(perf)
-- Events.EveryOneMinute.Add(perf)