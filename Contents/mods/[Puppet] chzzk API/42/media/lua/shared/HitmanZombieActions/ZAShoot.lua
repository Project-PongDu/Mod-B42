--[[
rework

 - firing animations
 - need to detect short and long burts based on weapon
 - shooting angle should be used for multifloor 
 - there are no long shoot animations for upper floor for handgun
 - rifle full auto animation need to be cut

 - logic needs to change:

onStart
 - first compute landing square based on char stats like accuracy, global sandbox settings and chance, chance should be deterministic based on rnd[3] and game minute, and bullets left
 - weapon reloads should sync weapons in brains for multiplayer sync
 - projectile starts 
 - animation start
 - based on distance a bullet landing realization is calculated
 - shoot sound

onWaiting
 - onWaiting realizes bullet reaching the target in the precalculated tick,
 - does not repeat animation

onCOmplete 
 - world sound atraction with cooldown
 - spent round sound
 
 ]]
HitmanZombieActions = HitmanZombieActions or {}

HitmanZombieActions.Shoot = {}
HitmanZombieActions.Shoot.onStart = function(hitman, task)

    local brain = HitmanBrain.Get(hitman)
    local bx, by, bz, bd = hitman:getX(), hitman:getY(), hitman:getZ(), hitman:getDirectionAngle()

    local weapon = brain.weapons[task.slot]
    local weaponItem = HitmanCompatibility.InstanceItem(weapon.name)
    weaponItem = HitmanUtils.ModifyWeapon(weaponItem, brain)

    -- establish animation time
    local recoilDelay = weaponItem:getRecoilDelay()
    task.recoilDelay = recoilDelay
    task.tick = recoilDelay

    -- fire tick
    local fireDelay = 1
    task.tickFire = task.recoilDelay - fireDelay

    -- shell ground tick
    if not weaponItem:isManuallyRemoveSpentRounds() then
        local shellDelay = 50
        task.tickShell = task.recoilDelay - fireDelay - shellDelay
    end

    -- remember enemy location
    local enemy = HitmanZombie.Cache[task.eid] or HitmanPlayer.GetPlayerById(task.eid)
    if not enemy then return true end
    local ex, ey, ez = enemy:getX(), enemy:getY(), enemy:getZ()
    hitman:faceLocationF(ex, ey)

    -- establish bullet landing tick
    -- local dist = HitmanUtils.DistTo(bx, by, task.ex, task.ey)
    local reachDelay = 2 -- math.floor(dist / 5)
    task.tickAtTarget = task.recoilDelay - fireDelay - reachDelay

    -- handle animation
    local weaponType = WeaponType.getWeaponType(weaponItem)
    if weaponType == WeaponType.FIREARM then
        task.anim2 = "AimRifle"
        if weaponItem:getFireMode() == "Auto" then
            task.anim = "AttackRifleSmallAuto"
            task.auto = true
        else
            if recoilDelay >= 28 then
                task.anim = "AttackRifle"
            else
                task.anim = "AttackRifleSmall"
            end
        end
    elseif weaponType == WeaponType.HANDGUN then
        task.anim2 = "AimPistol"
        if recoilDelay >= 15 then
            task.anim = "AttackHandgun"
        else
            task.anim = "AttackHandgunSmall"
        end
    end
    hitman:setBumpType(task.anim)

    -- apply a slight random offset to the firing direction (degrees)
    local maxAimOffset = 5
    if task.auto then
        maxAimOffset = maxAimOffset * 1.8
    end
    local aimOffset = ZombRandFloat(0, 2 * maxAimOffset) - maxAimOffset
    task.fireAngle = hitman:getDirectionAngle() + aimOffset

    -- calculate target point
    local offsetRad = math.rad(aimOffset)
    task.cosO, task.sinO = math.cos(offsetRad), math.sin(offsetRad)

    -- weapon:getStopPower() [float]

    return true
end

HitmanZombieActions.Shoot.onWorking = function(hitman, task)
    if hitman:getBumpType() ~= task.anim then 
        local elapsed = 1000 - task.time
        local reqTime = task.recoilDelay
        if task.auto then
            reqTime = reqTime * 0.25
        end
        if elapsed > reqTime then
            return true 
        else
            hitman:setBumpType(task.anim2)
        end
    end

    local enemy = HitmanZombie.Cache[task.eid] or HitmanPlayer.GetPlayerById(task.eid)
    if not enemy then return true end

    local ex, ey, ez = enemy:getX(), enemy:getY(), enemy:getZ()
    local bx, by, bz = hitman:getX(), hitman:getY(), hitman:getZ()

    local dx, dy = ex - bx, ey - by
    local tx = bx + dx * task.cosO - dy * task.sinO
    local ty = by + dx * task.sinO + dy * task.cosO
    local tz = ez

    -- hitman:faceLocationF(tx, ty)
    
    if task.tick == task.tickFire then
        local brain = HitmanBrain.Get(hitman)

        -- handle sound
        local bx, by, bz = hitman:getX(), hitman:getY(), hitman:getZ()
        local weapon = brain.weapons[task.slot]
        local weaponItem = HitmanCompatibility.InstanceItem(weapon.name)
        weaponItem = HitmanUtils.ModifyWeapon(weaponItem, brain)

        local emitter = getWorld():getFreeEmitter(bx, by, bz)
        -- local emitter = hitman:getEmitter()
        local swingSound = weaponItem:getSwingSound()
        -- emitter:stopAll()
        emitter:playSound(swingSound)
        -- emitter:setParameterValueByName(long, "CameraZoom", 1.0)

        -- update weapon stats here
        weapon.bulletsLeft = weapon.bulletsLeft - 1
        if weaponItem:isRackAfterShoot() then
            weapon.racked = false
        end
        if weapon.bulletsLeft <= 0 then
            --weapon.racked = false
        end

        -- handle flash and projectile
        HitmanCompatibility.StartMuzzleFlash(hitman)
        local reloadType = weaponItem:getWeaponReloadType()
        local projectiles = HitmanUtils.GetProjectileCount(reloadType)
        HitmanProjectile.Add(brain.id, bx, by, bz, task.fireAngle, projectiles)

        if not brain.shotCooldown or brain.shotCooldown + 5000 < getTimestampMs() then
            local radius = weaponItem:getSoundRadius()
            local volume = weaponItem:getSoundVolume()
            local zombieList = HitmanZombie.CacheLightZ
            for id, zombie in pairs(zombieList) do
                local dist = math.abs(bx - zombie.x) + math.abs(by - zombie.y)
                if dist < radius then
                    local zombie = HitmanZombie.Cache[id]
                    if zombie and not zombie:isMoving() then
                        local asn = zombie:getActionStateName()
                        if asn == "idle" then
                            zombie:spottedNew(hitman, true)
                            zombie:addAggro(hitman, 1)
                            zombie:setTarget(hitman)
                        end
                    end
                end
            end
            brain.shotCooldown = getTimestampMs()
        end

        -- print (task.tick .. " FIRE "  .. task.anim)
    elseif task.tick == task.tickAtTarget then
        local brain = HitmanBrain.Get(hitman)
        local weapon = brain.weapons[task.slot]
        local weaponItem = HitmanCompatibility.InstanceItem(weapon.name)
        weaponItem = HitmanUtils.ModifyWeapon(weaponItem, brain)

        if HitmanUtils.LineClear(hitman, enemy) then
            HitmanUtils.ManageLineOfFire(hitman, math.floor(tx), math.floor(ty), math.floor(tz), weaponItem)
        end
    elseif task.tick == task.tickShell then
        local bx, by, bz = hitman:getX(), hitman:getY(), hitman:getZ()
        local brain = HitmanBrain.Get(hitman)
        local weapon = brain.weapons[task.slot]
        local weaponItem = HitmanCompatibility.InstanceItem(weapon.name)
        weaponItem = HitmanUtils.ModifyWeapon(weaponItem, brain)
        local emitter = getWorld():getFreeEmitter(bx, by, bz)
        local shellFallSound = weaponItem:getShellFallSound()
        emitter:playSound(shellFallSound)
    else
        -- print (task.tick .. " VOID " .. task.anim)
    end
    
    task.tick = task.tick - 1

    return false
end

HitmanZombieActions.Shoot.onCompleteOld = function(hitman, task)

    --[[
    local bumpType = hitman:getBumpType()
    if bumpType ~= task.anim then return true end

    local shooter = hitman
    local sx, sy, sz, sd = shooter:getX(), shooter:getY(), shooter:getZ(), shooter:getDirectionAngle()
    local brainShooter = HitmanBrain.Get(shooter)
    local weapon = brainShooter.weapons[task.slot]
    local weaponItem = HitmanCompatibility.InstanceItem(weapon.name)
    if not weaponItem then return true end

    weaponItem = HitmanUtils.ModifyWeapon(weaponItem, brainShooter)

    local enemy = HitmanZombie.Cache[task.eid] or HitmanPlayer.GetPlayerById(task.eid)
    if not enemy then return true end

    if not HitmanUtils.IsFacing(sx, sy, sd, enemy:getX(), enemy:getY(), 5) then 
        return true
    end

    -- deplete round
    weapon.bulletsLeft = weapon.bulletsLeft - 1
    -- Hitman.UpdateItemsToSpawnAtDeath(shooter, brainShooter)

    -- apply a slight random offset to the firing direction (degrees)
    local maxAimOffset = 5
    local aimOffset = ZombRandFloat(0, 2 * maxAimOffset) - maxAimOffset
    local fireAngle = sd + aimOffset

    -- rotate the shooter->enemy vector by the aim offset to get the actual impact point
    local ex, ey, ez = enemy:getX(), enemy:getY(), enemy:getZ()
    local offsetRad = math.rad(aimOffset)
    local cosO, sinO = math.cos(offsetRad), math.sin(offsetRad)
    local dx, dy = ex - sx, ey - sy
    local tx = sx + dx * cosO - dy * sinO
    local ty = sy + dx * sinO + dy * cosO
    local tz = ez

    -- handle flash and projectile
    HitmanCompatibility.StartMuzzleFlash(shooter)
    local reloadType = weaponItem:getWeaponReloadType()
    local projectiles = HitmanUtils.GetProjectileCount(reloadType)
    HitmanProjectile.Add(brainShooter.id, sx, sy, sz, fireAngle, projectiles)

    -- handle real and "world" sound 
    -- local emitter = getWorld():getFreeEmitter(sx, sy, sz)
    local emitter = shooter:getEmitter()
    local swingSound = weaponItem:getSwingSound()
    -- emitter:stopAll()
    local long = emitter:playSound(swingSound)
    -- emitter:setParameterValueByName(long, "CameraZoom", 1.0)

    -- alert nearby zombies
    

    -- manage line of fire damage to characters and objects
    if HitmanUtils.LineClear(shooter, enemy) then
        HitmanUtils.ManageLineOfFire(shooter, math.floor(tx), math.floor(ty), math.floor(tz), weaponItem)
    end

    -- handle post-shot things
    if not weaponItem:isManuallyRemoveSpentRounds() then
        shooter:playSound(weaponItem:getShellFallSound())
    end

    if weaponItem:isRackAfterShoot() then
        weapon.racked = false
    end

    ]]

    return true
end