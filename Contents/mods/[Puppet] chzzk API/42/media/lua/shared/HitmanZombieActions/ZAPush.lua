HitmanZombieActions = HitmanZombieActions or {}

local function ShovePlayer (attacker, player)

    local hitFromBehind = false
    local hdx = player:getX() - attacker:getX()
    local hdy = player:getY() - attacker:getY()
    local hlen = math.sqrt(hdx * hdx + hdy * hdy)
    if hlen > 0 then
        local fwd = player:getForwardDirection()
        hitFromBehind = (hdx * fwd:getX() + hdy * fwd:getY()) / hlen > 0.5
    end

    player:clearVariable("BumpFallType")
    player:setBumpType("stagger")

    if HitmanUtils.HitmanRand(3) == 1 then
        player:setBumpFall(true)
    else
        player:setBumpFall(false)
    end

    if not hitFromBehind then
        player:setBumpFallType("pushedFront")
    else
        player:setBumpFallType("pushedBehind")
    end
end

local function ShoveZombie (attacker, zombie)
    
    local hitFromBehind = false
    local hdx = zombie:getX() - attacker:getX()
    local hdy = zombie:getY() - attacker:getY()
    local hlen = math.sqrt(hdx * hdx + hdy * hdy)
    if hlen > 0 then
        local fwd = zombie:getForwardDirection()
        hitFromBehind = (hdx * fwd:getX() + hdy * fwd:getY()) / hlen > 0.5
    end

    zombie:setHitFromBehind(hitFromBehind)
    zombie:setPlayerAttackPosition(zombie:testDotSide(attacker))
    zombie:setHitForce(1)
    --zombie:setStaggerBack(true)
    zombie:setKnockedDown(true)
    --zombie:setOnFloor(true)
    
end

HitmanZombieActions.Push = {}
HitmanZombieActions.Push.onStart = function(hitman, task)

    local anim = HitmanUtils.Choice({"Shove", "HighKick", "FrontKick"})

    local primaryItem = hitman:getPrimaryHandItem()
    if primaryItem and primaryItem:IsWeapon() then
        local primaryItemType = WeaponType.getWeaponType(primaryItem)

        if primaryItemType == WeaponType.FIREARM then
            anim = HitmanUtils.Choice({"WhipRifle1", "WhipRifle2", "HighKick", "FrontKick"})
        elseif primaryItemType == WeaponType.HANDGUN then
            anim = HitmanUtils.Choice({"WhipPistol1", "WhipPistol2", "HighKick", "FrontKick"})
        end
    end

    if anim then
        task.anim = anim
        hitman:setBumpType(anim)
    else
        return false
    end

    return true
end

HitmanZombieActions.Push.onWorking = function(hitman, task)
    hitman:faceLocationF(task.x, task.y)

    local bumpType = hitman:getBumpType()
    if bumpType ~= task.anim then return task.hit == true end

    if not task.hit and task.time <= 54 then

        task.hit = true

        local enemy = HitmanZombie.Cache[task.eid]
        if enemy then 
            local brainHitman = HitmanBrain.Get(hitman)
            local brainEnemy = HitmanBrain.Get(enemy)
            if HitmanUtils.AreEnemies(brainEnemy, brainHitman) then
            -- if not brainEnemy or not brainEnemy.clan or brainHitman.clan ~= brainEnemy.clan or (brainHitman.hostile and not brainEnemy.hostile) then 
                ShoveZombie (hitman, enemy)
            end
        end

        if Hitman.IsHostile(hitman) then
            local playerList = HitmanPlayer.GetPlayers()
            for i=0, playerList:size()-1 do
                local player = playerList:get(i)
                if player then
                    local eid = HitmanUtils.GetCharacterID(player)
                    if player:isAlive() and eid == task.eid then
                        ShovePlayer (hitman, player)
                    end
                end
            end
        end
    end
    return false
end

HitmanZombieActions.Push.onComplete = function(hitman, task)
    return true
end
