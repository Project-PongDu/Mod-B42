require "HitmanCompatibility"
-- shared subprograms available as subs for other programs

local function predicateAll(item)
    -- item:getType()
	return true
end

local function predicateSpoilableFood(item)
    local category = item:getDisplayCategory()
    if category == "Food" then
        local canSpoil = item:getOffAgeMax() < 1000
        if canSpoil then
            return true
        end
    end
    return false
end

local function predicateMelee(item)
    if item:IsWeapon() then
        local weaponType = WeaponType.getWeaponType(item)
        if weaponType ~= WeaponType.FIREARM and weaponType ~= WeaponType.HANDGUN then
            return true
        end
    end
    return false
end

local function getItem(hitman, itemTypeTab, cnt)
    local task
    local obj
    local itemType
    for _, it in pairs(itemTypeTab) do
        local o = HitmanPlayerBase.GetContainerWithItem(hitman, it, cnt)
        if o then 
            obj = o
            itemType = it
            break
        end
    end

    if not obj then return end

    local square = obj
    if not instanceof(obj, "IsoGridSquare") then square = obj:getParent():getSquare() end

    local asquare = AdjacentFreeTileFinder.Find(square, hitman)
    if not asquare then return end

    local dist = HitmanUtils.DistTo(hitman:getX(), hitman:getY(), asquare:getX() + 0.5, asquare:getY() + 0.5)
    if dist > 0.90 then
        -- hitman:addLineChatElement(("go collect: " .. itemType), 1, 1, 1)
        task = HitmanUtils.GetMoveTask(0, asquare:getX(), asquare:getY(), asquare:getZ(), "Walk", dist, false)
    else
        if instanceof(obj, "IsoGridSquare") then
            -- hitman:addLineChatElement(("pickup " .. itemType), 1, 1, 1)
            task = {action="PickUp", anim="LootLow", itemType=itemType, x=square:getX(), y=square:getY(), z=square:getZ(), cnt=cnt}
        else
            -- hitman:addLineChatElement(("take from container: " .. itemType), 1, 1, 1)
            task = {action="TakeFromContainer", anim="Loot", itemType=itemType, x=square:getX(), y=square:getY(), z=square:getZ(), cnt=cnt}
        end
    end
    return task
end

HitmanPrograms = HitmanPrograms or {}

HitmanPrograms.Weapon = HitmanPrograms.Weapon or {}

HitmanPrograms.Weapon.Switch = function(hitman, itemName)

    local tasks = {}

    -- check what is equipped that needs to be deattached
    local old = hitman:getPrimaryHandItem()
    if old then
        local sound = old:getUnequipSound()
        local task = {action="Unequip", sound=sound, time=100, itemPrimary=old:getFullType()}
        table.insert(tasks, task)
    end

    -- grab new weapon
    local new = HitmanCompatibility.InstanceItem(itemName)
    if new then
        local sound = new:getEquipSound()
        local task = {action="Equip", sound=sound, itemPrimary=itemName}
        table.insert(tasks, task)
    end
    return tasks
end

HitmanPrograms.Weapon.Aim = function(hitman, enemyCharacter, slot)
    local tasks = {}

    local walkType = hitman:getVariableString("HitmanWalkType")
    local brain = HitmanBrain.Get(hitman)
    local weapon = brain.weapons[slot]
    local weaponItem = HitmanCompatibility.InstanceItem(weapon.name)
    local sound = weaponItem:getBringToBearSound()

    -- aim time calc
    local dist = HitmanUtils.DistTo(hitman:getX(), hitman:getY(), enemyCharacter:getX(), enemyCharacter:getY())
    local aimTimeMin = Hitman.Settings.GunReflexMin or 18
    local aimTimeSurp = math.floor(dist * 5)
    if walkType == "WalkAim" then
        aimTimeMin = 1
        -- aimTimeSurp = aimTimeSurp
    end

    if instanceof(enemyCharacter, "IsoZombie") then
        aimTimeSurp = math.floor(aimTimeSurp / 2)
    else
        -- player handicap
        aimTimeSurp = aimTimeSurp + 10

        if enemyCharacter:getVehicle() then
            aimTimeSurp = aimTimeSurp - 20
        end
    end

    -- choose anim
    if aimTimeMin + aimTimeSurp > 0 then
        local anim
        local asn = enemyCharacter:getActionStateName()
        local down = enemyCharacter:isProne() or enemyCharacter:isBumpFall() or asn == "onground" or asn == "getup"
        if slot == "primary" then
            if dist < 2.5 and down then
                anim = "AimRifleLow"
            else
                if walkType == "WalkAim" then
                    anim = "AimRifle"
                else
                    anim = "IdleToAimRifle"
                end
            end
        else
            if dist < 2.5 and down then
                anim = "AimPistolLow"
            else
                if walkType == "WalkAim" then
                    anim = "AimPistol"
                else
                    anim = "IdleToAimPistol"
                end
            end
        end

        local aimTimeIndividual = brain.rnd and brain.rnd[2] or 0
        local time = aimTimeMin + aimTimeSurp + aimTimeIndividual
        if time > 60 then time = 60 end

        local task = {action="Aim", anim=anim, sound=sound, x=enemyCharacter:getX(), y=enemyCharacter:getY(), time=time}
        table.insert(tasks, task)
    end
    return tasks
end

HitmanPrograms.Weapon.Shoot = function(hitman, enemyCharacter, slot)
    local tasks = {}

    --[[
    local brain = HitmanBrain.Get(hitman)
    local weapon = brain.weapons[slot]
    local weaponItem = HitmanCompatibility.InstanceItem(weapon.name)
    local fireTimeIndividual = brain.rnd and brain.rnd[2] or 0

    local dist = HitmanUtils.DistTo(hitman:getX(), hitman:getY(), enemyCharacter:getX(), enemyCharacter:getY())
    local firingtime = weaponItem:getRecoilDelay() + math.floor(dist ^ 1.1) + fireTimeIndividual

    local bullets = 1
    local modes = weaponItem:getFireModePossibilities()
    if modes then
        for i=0, modes:size()-1 do
            local mode = modes:get(i)
            if (dist < 12 or enemyCharacter:getVehicle()) and mode == "Auto" then
                bullets = 2 + ZombRand(6)
                break
            end
        end
    end

    local anim
    local asn = enemyCharacter:getActionStateName()
    local down = enemyCharacter:isProne() or enemyCharacter:isBumpFall() or asn == "onground" or asn == "getup"

    if slot == "primary" then
        if dist < 2.5 and down then
            anim = "AimRifleLow"
        else
            anim = "AimRifle"
        end
    else
        if dist < 2.5 and down then
            anim = "AimPistolLow"
        else
            anim = "AimPistol"
        end
    end

    local fd = enemyCharacter:getForwardDirection()
    fd:setLength(2)

    local x, y, z = enemyCharacter:getX() + fd:getX(), enemyCharacter:getY() + fd:getY(), enemyCharacter:getZ()
    local eid = HitmanUtils.GetCharacterID(enemyCharacter)
    local task = {action="Shoot", anim=anim, time=firingtime, slot=slot, x=x, y=y, z=z, eid=eid}
    table.insert(tasks, task)
    for i=2, bullets do
        local task = {action="Shoot", anim=anim, time=6, slot=slot, x=x, y=y, z=z, eid=eid}
        table.insert(tasks, task)
    end

    return tasks
    --]]
    local eid = HitmanUtils.GetCharacterID(enemyCharacter)
    local task = {action="Shoot", slot=slot, eid=eid}
    table.insert(tasks, task)
    return tasks
end

HitmanPrograms.Weapon.Rack = function(hitman, slot)
    local tasks = {}

    local brain = HitmanBrain.Get(hitman)
    local weapon = brain.weapons[slot]

    local primaryItem = HitmanCompatibility.InstanceItem(weapon.name)
    local reloadType = primaryItem:getWeaponReloadType()
    local magazineType = primaryItem:getMagazineType()

    local rackSound = primaryItem:getRackSound()
    local rackAnim
    if reloadType ==  WeaponReloadType.BOLT_ACTION then
        rackAnim = "RackRifle"
    elseif reloadType == WeaponReloadType.BOLT_ACTION_NO_MAG then
        rackAnim = "RackRifleAim" -- this is different than in Reload
    elseif reloadType == WeaponReloadType.SHOTGUN then
        rackAnim = "RackShotgunAim" -- this is different than in Reload
    elseif reloadType == WeaponReloadType.DOUBLE_BARREL_SHOTGUN then
        rackAnim = "RackDBShotgun"
    elseif reloadType == WeaponReloadType.DOUBLE_BARREL_SHOTGUN_SAWN then
        rackAnim = "RackDBShotgun"
    elseif reloadType == WeaponReloadType.HANDGUN then
        rackAnim = "RackPistol"
    elseif reloadType == WeaponReloadType.REVOLVER then
        rackAnim = "RackRevolver"
    end

    if not weapon.racked then
        local task = {action="Rack", slot=slot, anim=rackAnim, sound=rackSound, time=90}
        table.insert(tasks, task)
        return tasks
    end
end

HitmanPrograms.Weapon.Reload = function(hitman, slot)
    local tasks = {}

    local brain = HitmanBrain.Get(hitman)
    local weapon = brain.weapons[slot]

    local primaryItem = HitmanCompatibility.InstanceItem(weapon.name)
    local reloadType = primaryItem:getWeaponReloadType()
    local magazineType = primaryItem:getMagazineType()
    local unloadSound = primaryItem:getEjectAmmoSound()
    local loadSound = primaryItem:getInsertAmmoSound()
    local rackSound = primaryItem:getRackSound()

    local clipMode
    local unloadAnim
    local loadAnim
    local rackAnim

    if reloadType == WeaponReloadType.BOLT_ACTION or (reloadType == WeaponReloadType.BOLT_ACTION_NO_MAG and magazineType) then -- b41 wrongly indicates hunting rifle as nomag weapon
        clipMode = true
        unloadAnim = "UnloadRifle"
        loadAnim = "LoadRifle"
        rackAnim = "RackRifle"
    elseif reloadType == WeaponReloadType.BOLT_ACTION_NO_MAG then
        clipMode = false
        unloadAnim = "UnloadShotgun"
        loadAnim = "LoadShotgun"
        rackAnim = "RackRifle"
    elseif reloadType == WeaponReloadType.SHOTGUN then
        clipMode = false
        unloadAnim = "UnloadShotgun"
        loadAnim = "LoadShotgun"
        rackAnim = "RackShotgun"
    elseif reloadType == WeaponReloadType.DOUBLE_BARREL_SHOTGUN then
        clipMode = false
        unloadAnim = "UnloadDBShotgun"
        loadAnim = "LoadDBShotgun"
        rackAnim = "RackDBShotgun"
    elseif reloadType == WeaponReloadType.DOUBLE_BARREL_SHOTGUN_SAWN then
        clipMode = false
        unloadAnim = "UnloadDBShotgun"
        loadAnim = "LoadDBShotgun"
        rackAnim = "RackDBShotgun"
    elseif reloadType == WeaponReloadType.HANDGUN then
        clipMode = true
        unloadAnim = "UnLoadPistol"
        loadAnim = "LoadPistol"
        rackAnim = "RackPistol"
    elseif reloadType == WeaponReloadType.REVOLVER then
        clipMode = false
        unloadAnim = "UnloadRevolver"
        loadAnim = "LoadRevolver"
        rackAnim = "RackRevolver"
    end

    if (weapon.type == "mag" and weapon.bulletsLeft <= 0 and weapon.magCount > 0) or
       (weapon.type == "nomag" and weapon.bulletsLeft < weapon.ammoSize and weapon.ammoCount > 0) then
        
        if clipMode then 
            if weapon.clipIn then
                local task = {action="Unload", slot=slot, drop=magazineType, anim=unloadAnim, sound=unloadSound, time=90}
                table.insert(tasks, task)
                return tasks
            else
                local task = {action="Load", slot=slot, anim=loadAnim, sound=loadSound, time=90}
                table.insert(tasks, task)
                return tasks
            end
        else
            local task = {action="Load", slot=slot, anim=loadAnim, sound=loadSound, time=90}
            table.insert(tasks, task)
            return tasks
        end
    elseif not weapon.racked then
        local task = {action="Rack", slot=slot, anim=rackAnim, sound=rackSound, time=90}
        table.insert(tasks, task)
        return tasks
    end

    return tasks
end

HitmanPrograms.Weapon.Resupply = function(hitman)
    local tasks = {}

    local cell = getCell()
    local zx, zy, zz = hitman:getX(), hitman:getY(), hitman:getZ()
    local isBareHands = Hitman.IsBareHands(hitman)
    local needPrimary = Hitman.NeedResupplySlot(hitman, "primary")
    local needSecondary = Hitman.NeedResupplySlot(hitman, "secondary")
    local bestDist = 100
    local destObject
    for y=-3, 3 do
        for x=-3, 3 do
            local square = cell:getGridSquare(zx + x, zy + y, zz)
            if square then
                local objectList = {}

                -- loot bodies
                if square:getDeadBody() then
                    local objects = square:getStaticMovingObjects()
                    for i=0, objects:size()-1 do
                        local object = objects:get(i)
                        if instanceof (object, "IsoDeadBody") then
                            local container = object:getContainer()
                            if container and not container:isEmpty() then
                                table.insert(objectList, object)
                            end
                        end
                    end
                end
                
                -- loot shelfs
                local objects = square:getObjects()
                for i=0, objects:size()-1 do
                    local object = objects:get(i)
                    local container = object:getContainer()
                    if container and not container:isEmpty() then
                        table.insert(objectList, object)
                    end
                end

                for i=1, #objectList do
                    local object = objectList[i]
                    local container = object:getContainer()
                    local dist = math.abs(x) + math.abs(y)

                    -- find melee
                    if isBareHands then
                        local items = ArrayList.new()
                        container:getAllEvalRecurse(predicateMelee, items)
                        if items:size() > 0 and dist < bestDist then
                            bestDist = dist
                            destObject = object
                        end
                    end

                    -- find primary or secondary
                    if needPrimary or needSecondary then
                        local items = ArrayList.new()
                        container:getAllEvalRecurse(predicateAll, items)
                        for i=0, items:size()-1 do
                            local item = items:get(i)
                            if item:IsWeapon() then
                                local weaponItem = item
                                local weaponType = WeaponType.getWeaponType(weaponItem)

                                if (needPrimary and weaponType == WeaponType.FIREARM) or
                                    (needSecondary and weaponType == WeaponType.HANDGUN) then
                                    
                                    if HitmanCompatibility.UsesExternalMagazine(weaponItem) then
                                        local magazineType = weaponItem:getMagazineType()
                                        for j=0, items:size()-1 do
                                            local item = items:get(j)
                                            if dist < bestDist and item:getFullType() == magazineType and item:getCurrentAmmoCount() > 0 then
                                                bestDist = dist
                                                destObject = object
                                            end
                                        end
                                    else
                                        local ammoType = weaponItem:getAmmoType():getItemKey()
                                        for j=0, items:size()-1 do
                                            local item = items:get(j)
                                            if dist < bestDist and item:getFullType() == ammoType then
                                                bestDist = dist
                                                destObject = object
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

    if destObject then
        local square = destObject:getSquare()
        local lx, ly, lz = square:getX(), square:getY(), square:getZ() 
        local ax, ay, az = lx, ly, lz
        
        if not square:isFree(false) then
            local asquare = AdjacentFreeTileFinder.Find(square, hitman)
            if asquare then
                ax, ay, az = asquare:getX(), asquare:getY(), asquare:getZ()
            end
        end
        local dist = HitmanUtils.DistTo(zx, zy, ax, ay)

        if dist > 0.9 then
            local task = HitmanUtils.GetMoveTask(0.01, ax + 0.5, ay + 0.5, az, "Run", dist, false)
            table.insert(tasks, task)
            return tasks
        else
            local task = {action="LootWeapons", anim="LootLow", time=100, x=lx, y=ly, z=lz}
            table.insert(tasks, task)
            return tasks
        end
    end
    return tasks
end

HitmanPrograms.Idle = function(hitman)
    local tasks = {}
    local action = ZombRand(10)

    local outOfAmmo = Hitman.IsOutOfAmmo(hitman)
    local gameTime = getGameTime()
    local alfa = gameTime:getMinutes() * 4
    local theta = alfa * math.pi / 180
    local x1 = hitman:getX() + 3 * math.cos(theta)
    local y1 = hitman:getY() + 3 * math.sin(theta)

    if action == 0 then
        local task = {action="Time", anim="ShiftWeight", time=200}
        table.insert(tasks, task)
    elseif action == 1 then
        local task = {action="Time", anim="Cough", time=200}
        table.insert(tasks, task)
    elseif action == 2 then
        local task = {action="Time", anim="ChewNails", time=200}
        table.insert(tasks, task)
    elseif action == 3 then
        local task = {action="Time", anim="Smoke", time=200}
        table.insert(tasks, task)
        table.insert(tasks, task)
        table.insert(tasks, task)
    elseif action == 4 then
        local task = {action="Time", anim="PullAtCollar", time=200}
        table.insert(tasks, task)
    elseif action == 5 then
        local task = {action="Time", anim="Sneeze", time=200}
        table.insert(tasks, task)
    elseif action == 6 then
        local task = {action="Time", anim="WipeBrow", time=200}
        table.insert(tasks, task)
    elseif action == 7 then
        local task = {action="Time", anim="WipeHead", time=200}
        table.insert(tasks, task)
    else
        local task = {action="Time", anim="ChewNails", time=200}
        table.insert(tasks, task)
    end
    return tasks
end 

HitmanPrograms.Container = HitmanPrograms.Container or {}


HitmanPrograms.Container.Loot = function(hitman, object, container)
    local tasks = {}

    local bx, by, bz
    local lootDist
    local lootAnim
    local square = object:getSquare()
    if square:isFree(false) then
        bx = object:getX()
        by = object:getY()
        bz = object:getZ()
        lootDist = 1.1
        lootAnim = "LootLow"
    else
        local asquare = AdjacentFreeTileFinder.Find(square, hitman)
        if asquare then
            bx = asquare:getX()
            by = asquare:getY()
            bz = asquare:getZ()
            lootDist = 2.1
            lootAnim = "Loot"
        end
    end

    local dist = HitmanUtils.DistTo(hitman:getX(), hitman:getY(), enemyCharacter:getX(), enemyCharacter:getY())

    -- we are here, take it
    if dist < lootDist then

        local items = ArrayList.new()
        container:getAllEvalRecurse(predicateAll, items)
    
        -- analyze container contents
        for i=0, items:size()-1 do
            local item = items:get(i)
        end

        local task = {action="LootItems", anim=lootAnim, time=items:size() * 50, x=object:getX(), y=object:getY(), z=object:getZ()}
        table.insert(tasks, task)
    -- go to location
    else
        table.insert(tasks, HitmanUtils.GetMoveTask(endurance, bx, by, bz, "Run", dist, false))
    end
                 
    return tasks
end

HitmanPrograms.Generator = HitmanPrograms.Generator or {}

HitmanPrograms.Generator.Refuel = function(hitman, generator)
    local tasks = {}

    local itemType = "Base.PetrolCan"

    -- return with carnister
    local inventory = hitman:getInventory()
    if inventory:getItemCountFromTypeRecurse(itemType) > 0 then
        local dist = HitmanUtils.DistTo(hitman:getX(), hitman:getY(), generator:getX() + 0.5, generator:getY() + 0.5)
        if dist > 0.90 then
            table.insert(tasks, HitmanUtils.GetMoveTask(0, generator:getX(), generator:getY(), generator:getZ(), "Walk", dist, false))
            return tasks
        else
            if generator:isActivated() then
                local task = {action="GeneratorToggle", anim="LootLow", x=generator:getX(), y=generator:getY(), z=generator:getZ(), status=false}
                table.insert(tasks, task)
                return tasks
            else
                local task1 = {action="Equip", itemPrimary=itemType}
                table.insert(tasks, task1)

                local task2 = {action="GeneratorRefill", anim="Refuel", x=generator:getX(), y=generator:getY(), z=generator:getZ(), status=false}
                table.insert(tasks, task2)

                local task3 = {action="Equip", itemPrimary=Hitman.GetBestWeapon(hitman)}
                table.insert(tasks, task3)

                -- turn on the generator back, but not if the square is already powered
                -- this is likely to be a backup generator and we do not want redundancy
                if not generator:getSquare():haveElectricity() then
                    local task = {action="GeneratorToggle", anim="LootLow", x=generator:getX(), y=generator:getY(), z=generator:getZ(), status=true}
                    table.insert(tasks, task)
                end

                return tasks
            end
        end
    end
    
    -- go get carnister
    local task = getItem(hitman, {itemType}, 1)
    if task then
        table.insert(tasks, task)
    end
    return tasks
end

HitmanPrograms.Generator.Repair = function(hitman, generator)
    local tasks = {}

    local itemType = "Base.ElectronicsScrap"

    local condition = generator:getCondition()
    local cnt = math.ceil((100 - condition) / 5)

    -- return with electronics
    local inventory = hitman:getInventory()
    local has = inventory:getItemCountFromTypeRecurse(itemType)
    if inventory:getItemCountFromTypeRecurse(itemType) >= cnt then
        local dist = HitmanUtils.DistTo(hitman:getX(), hitman:getY(), generator:getX() + 0.5, generator:getY() + 0.5)
        if dist > 0.90 then
            table.insert(tasks, HitmanUtils.GetMoveTask(0, generator:getX(), generator:getY(), generator:getZ(), "Walk", dist, false))
            return tasks
        else
            if generator:isActivated() then
                local task = {action="GeneratorToggle", anim="LootLow", x=generator:getX(), y=generator:getY(), z=generator:getZ(), status=false}
                table.insert(tasks, task)
                return tasks
            else
                local task = {action="Equip", itemPrimary=itemType}
                table.insert(tasks, task)

                local task = {action="GeneratorFix", anim="LootLow", x=generator:getX(), y=generator:getY(), z=generator:getZ()}
                table.insert(tasks, task)

                local task = {action="Equip", itemPrimary=Hitman.GetBestWeapon(hitman)}
                table.insert(tasks, task)

                -- turn on the generator back, but not if the square is already powered
                -- this is likely to be a backup generator and we do not want redundancy
                if not generator:getSquare():haveElectricity() and condition > 99 then
                    local task = {action="GeneratorToggle", anim="LootLow", x=generator:getX(), y=generator:getY(), z=generator:getZ(), status=true}
                    table.insert(tasks, task)
                end

                return tasks
            end
        end
    end
    
    -- go get electronics
    local task = getItem(hitman, {itemType}, cnt)
    if task then
        table.insert(tasks, task)
    end

    return tasks
end

HitmanPrograms.Farm = HitmanPrograms.Farm or {}

-- allowed water containers for farming
HitmanPrograms.Farm.fillables = {}

if HitmanCompatibility.GetGameVersion() < 42 then
    table.insert(HitmanPrograms.Farm.fillables, "farming.WateredCanFull")
    table.insert(HitmanPrograms.Farm.fillables, "farming.WateredCan")
else
    table.insert(HitmanPrograms.Farm.fillables, "Base.WateredCan")
end

HitmanPrograms.Farm.PredicateFillable = function(item)
    for _, itemType in pairs(HitmanPrograms.Farm.fillables) do
        local d = item:getFullType()
        if item:getFullType() == itemType then
	        return true
        end
    end
    return false
end

HitmanPrograms.Farm.Water = function(hitman, plant)
    local tasks = {}

    local farm = HitmanPlayerBase.GetFarm(hitman)
    if not farm then return tasks end

    -- water plants
    local inventory = hitman:getInventory()
    local items = ArrayList.new()
    inventory:getAllEvalRecurse(HitmanPrograms.Farm.PredicateFillable, items)
    if items:size() > 0 then
        local item = items:get(0)

        local itemType = item:getFullType()
        local water = item:getUsedDelta()
        if water > 0 then
            local dist = HitmanUtils.DistTo(hitman:getX(), hitman:getY(), farm.x + 0.5, farm.y + 0.5)
            if dist > 0.80 then
                table.insert(tasks, HitmanUtils.GetMoveTask(0, farm.x, farm.y, farm.z, "Walk", dist, false))
                return tasks
            else
                local task1 = {action="Equip", itemPrimary=itemType}
                table.insert(tasks, task1)

                local task2 = {action="WaterFarm", anim="PourWateringCan", itemType=itemType, x=farm.x, y=farm.y, z=farm.z}
                table.insert(tasks, task2)

                local task3 = {action="Equip", itemPrimary=Hitman.GetBestWeapon(hitman)}
                table.insert(tasks, task3)

                return tasks
            end
        else
            local source = HitmanPlayerBase.GetWaterSource(hitman)
            if source then
                local square = source:getSquare()
                local asquare = AdjacentFreeTileFinder.Find(square, hitman)
                if asquare then
                    local dist = HitmanUtils.DistTo(hitman:getX(), hitman:getY(), asquare:getX() + 0.5, asquare:getY() + 0.5)
                    if dist > 0.90 then
                        table.insert(tasks, HitmanUtils.GetMoveTask(0, asquare:getX(), asquare:getY(), asquare:getZ(), "Walk", dist, false))
                        return tasks
                    else
                        local task1 = {action="Equip", itemPrimary=itemType}
                        table.insert(tasks, task1)
        
                        local task2 = {action="FillWater", anim="FillBucket", time=400, itemType=itemType, x=square:getX(), y=square:getY(), z=square:getZ()}
                        table.insert(tasks, task2)
        
                        local task3 = {action="Equip", itemPrimary=Hitman.GetBestWeapon(hitman)}
                        table.insert(tasks, task3)

                        return tasks
                    end
                end
            end
        end
    end

    -- go get watering can
    local task = getItem(hitman, HitmanPrograms.Farm.fillables, 1)
    if task then
        table.insert(tasks, task)
    end

    return tasks
end

HitmanPrograms.Farm.Heal = function(hitman)
    
end

HitmanPrograms.Housekeeping = HitmanPrograms.Housekeeping or {}

-- allowed water containers for farming
HitmanPrograms.Housekeeping.trash = {}
table.insert(HitmanPrograms.Housekeeping.trash, "Base.BeerCanEmpty")
table.insert(HitmanPrograms.Housekeeping.trash, "Base.PopEmpty")
table.insert(HitmanPrograms.Housekeeping.trash, "Base.Pop2Empty")
table.insert(HitmanPrograms.Housekeeping.trash, "Base.Pop3Empty")
table.insert(HitmanPrograms.Housekeeping.trash, "Base.WineEmpty")
table.insert(HitmanPrograms.Housekeeping.trash, "Base.WineEmpty2")
table.insert(HitmanPrograms.Housekeeping.trash, "Base.BeerEmpty")
table.insert(HitmanPrograms.Housekeeping.trash, "Base.WaterBottleEmpty")
table.insert(HitmanPrograms.Housekeeping.trash, "Base.BleechEmpty")
table.insert(HitmanPrograms.Housekeeping.trash, "Base.RemouladeEmpty")
table.insert(HitmanPrograms.Housekeeping.trash, "Base.WhiskeyEmpty")
table.insert(HitmanPrograms.Housekeeping.trash, "Base.PopBottleEmpty")
table.insert(HitmanPrograms.Housekeeping.trash, "Base.RippedSheetsDirty")
table.insert(HitmanPrograms.Housekeeping.trash, "Base.TinCanEmpty")
table.insert(HitmanPrograms.Housekeeping.trash, "Base.UnusableWood")
table.insert(HitmanPrograms.Housekeeping.trash, "Base.UnusableMetal")

HitmanPrograms.Housekeeping.PredicateTrash = function(item)
    for _, itemType in pairs(HitmanPrograms.Housekeeping.trash) do
        if item:getFullType() == itemType then
	        return true
        end
    end
    return false
end

HitmanPrograms.Housekeeping.CleanBlood = function(hitman)
    local tasks = {}

    local square = HitmanPlayerBase.GetBlood(hitman)
    if not square then return tasks end

    local inventory = hitman:getInventory()

    itemMopType = "Base.Broom"
    itemBleachType = "Base.Bleach"

    local itemMop = inventory:getItemFromType(itemMopType)
    local itemBleach = inventory:getItemFromType(itemBleachType)

    if itemMop and itemBleach then
        local dist = HitmanUtils.DistTo(hitman:getX(), hitman:getY(), square:getX() + 0.5, square:getY() + 0.5)
        if dist > 0.80 then
            -- hitman:addLineChatElement(("go clean blood"), 1, 1, 1)
            table.insert(tasks, HitmanUtils.GetMoveTask(0, square:getX(), square:getY(), square:getZ(), "Walk", dist, false))
            return tasks
        else
            -- hitman:addLineChatElement(("clean blood"), 1, 1, 1)
            local task1 = {action="Equip", itemPrimary=itemMopType}
            table.insert(tasks, task1)

            local task2 = {action="CleanBlood", anim="Rake", itemType=itemMopType, x=square:getX(), y=square:getY(), z=square:getZ(), time=300}
            table.insert(tasks, task2)

            local task3 = {action="Equip", itemPrimary=Hitman.GetBestWeapon(hitman)}
            table.insert(tasks, task3)

            return tasks
        end
    end

    -- get tools
    local itemType
    if not itemBleach then itemType = itemBleachType end
    if not itemMop then itemType = itemMopType end

    if itemType then
        local task = getItem(hitman, {itemType}, 1)
        if task then
            table.insert(tasks, task)
        end
    end

    return tasks
end

HitmanPrograms.Housekeeping.RemoveTrash = function(hitman)
    local tasks = {}

    local trashcan = HitmanPlayerBase.GetTrashcan(hitman)
    if not trashcan then return tasks end

    -- put trash in the trashcan
    local inventory = hitman:getInventory()
    local items = ArrayList.new()
    inventory:getAllEvalRecurse(HitmanPrograms.Housekeeping.PredicateTrash, items)
    if items:size() >= 7 then
        local item = items:get(0)
        local itemType = item:getFullType()
        local square = trashcan:getSquare()
        local asquare = AdjacentFreeTileFinder.Find(square, hitman)
        if asquare then
            local dist = HitmanUtils.DistTo(hitman:getX(), hitman:getY(), asquare:getX() + 0.5, asquare:getY() + 0.5)
            if dist > 0.90 then
                -- hitman:addLineChatElement(("go to throw away trash"), 1, 1, 1)
                table.insert(tasks, HitmanUtils.GetMoveTask(0, asquare:getX(), asquare:getY(), asquare:getZ(), "Walk", dist, false))
                return tasks
            else
                for i=0, items:size()-1 do
                    -- hitman:addLineChatElement(("throw away trash"), 1, 1, 1)
                    local item = items:get(i)
                    local itemType = item:getFullType()
                    local task = {action="PutInContainer", anim="Loot", itemType=itemType, x=square:getX(), y=square:getY(), z=square:getZ()}
                    table.insert(tasks, task)
                end
                return tasks
            end
        end
    end

    -- collect trash
    local task = getItem(hitman, HitmanPrograms.Housekeeping.trash, 1)
    if task then
        table.insert(tasks, task)
    end

    return tasks
end

HitmanPrograms.Housekeeping.FillGraves = function(hitman)
    local tasks = {}

    local grave = HitmanPlayerBase.GetGrave(hitman, true)
    if not grave then return tasks end

    -- fill grave
    local itemType = "Base.Shovel"
    local inventory = hitman:getInventory()
    if inventory:getItemCountFromTypeRecurse(itemType) > 0 then
        local dist = HitmanUtils.DistTo(hitman:getX(), hitman:getY(), grave:getX() + 0.5, grave:getY() + 0.5)
        if dist > 0.90 then
            table.insert(tasks, HitmanUtils.GetMoveTask(0, grave:getX(), grave:getY(), grave:getZ(), "Walk", dist, false))
            return tasks
        else
            local task1 = {action="Equip", itemPrimary=itemType}
            table.insert(tasks, task1)

            local task = {action="FillGrave", anim="DigShovel", sound="Shoveling", itemType=itemType, time=400, x=grave:getX(), y=grave:getY(), z=grave:getZ()}
            table.insert(tasks, task)

            local task3 = {action="Equip", itemPrimary=Hitman.GetBestWeapon(hitman)}
            table.insert(tasks, task3)

            return tasks
        end
    end

    -- go take shovel
    local itemType = "Base.Shovel"
    local task = getItem(hitman, {itemType}, 1)
    if task then
        table.insert(tasks, task)
    end

    return tasks
end

HitmanPrograms.Housekeeping.RemoveCorpses = function(hitman)
    local tasks = {}

    local grave = HitmanPlayerBase.GetGrave(hitman, false)
    if not grave then return tasks end

    -- return with deadbody
    local itemType = "Base.CorpseMale"
    local inventory = hitman:getInventory()
    if inventory:getItemCountFromTypeRecurse(itemType) > 0 then
        local dist = HitmanUtils.DistTo(hitman:getX(), hitman:getY(), grave:getX() + 0.5, grave:getY() + 0.5)
        if dist > 0.90 then
            table.insert(tasks, HitmanUtils.GetMoveTask(0, grave:getX(), grave:getY(), grave:getZ(), "Walk", dist, false))
            return tasks
        else
            local task = {action="BuryCorpse", anim="LootLow", sound="BodyHitGround", x=grave:getX(), y=grave:getY(), z=grave:getZ()}
            table.insert(tasks, task)
            return tasks
        end
    end
    
    -- go take deadbody
    local deadbody = HitmanPlayerBase.GetDeadbody(hitman)
    if not deadbody then return tasks end

    local square = obj
    local dist = HitmanUtils.DistTo(hitman:getX(), hitman:getY(), deadbody:getX() + 0.5, deadbody:getY() + 0.5)
    if dist > 0.90 then
        table.insert(tasks, HitmanUtils.GetMoveTask(0, deadbody:getX(), deadbody:getY(), deadbody:getZ(), "Walk", dist, false))
        return tasks
    else
        local task = {action="PickUpBody", anim="LootLow", itemType=itemType, x=deadbody:getX(), y=deadbody:getY(), z=deadbody:getZ()}
        table.insert(tasks, task)
        return tasks
    end

    return tasks
end

HitmanPrograms.Misc = HitmanPrograms.Misc or {}

HitmanPrograms.Misc.ReturnFood = function(hitman)
    local tasks = {}

    local container = HitmanPlayerBase.GetContainerOfType(hitman, "freezer")

    if not container then
        container = HitmanPlayerBase.GetContainerOfType(hitman, "fridge")
    end
    if not container then return tasks end
    local inventory = hitman:getInventory()

    local itemType
    local items = ArrayList.new()
    inventory:getAllEvalRecurse(predicateSpoilableFood, items)
    if items:size() == 0 then return tasks end

    local square = container:getParent():getSquare()
    local asquare = AdjacentFreeTileFinder.Find(square, hitman)
    if asquare then
        local dist = HitmanUtils.DistTo(hitman:getX(), hitman:getY(), asquare:getX() + 0.5, asquare:getY() + 0.5)
        if dist > 0.90 then
            -- hitman:addLineChatElement(("go put food to fridge"), 1, 1, 1)
            table.insert(tasks, HitmanUtils.GetMoveTask(0, asquare:getX(), asquare:getY(), asquare:getZ(), "Walk", dist, false))
            return tasks
        else
            for i=0, items:size()-1 do
                -- hitman:addLineChatElement(("put food to fridge"), 1, 1, 1)
                local item = items:get(i)
                local itemType = item:getFullType()
                local task = {action="PutInContainer", anim="Loot", itemType=itemType, x=square:getX(), y=square:getY(), z=square:getZ()}
                table.insert(tasks, task)
            end
            return tasks
        end
    end

    return tasks
end

HitmanPrograms.Self = HitmanPrograms.Self or {}

HitmanPrograms.Self.Wash = function(hitman)
    local tasks = {}

    local visual = hitman:getHumanVisual()
    local bodyBlood = 0
    local bodyDirt = 0
    for i=1, BloodBodyPartType.MAX:index() do
        local part = BloodBodyPartType.FromIndex(i-1)
        bodyBlood = bodyBlood + visual:getBlood(part)
        bodyDirt = bodyDirt + visual:getDirt(part)
    end
    --[[
    if bodyBlood > 0 then
        print ("blood: " .. bodyBlood)
    end
    if bodyDirt > 0 then
        print ("dirt: " .. bodyDirt)
    end]]

    if bodyBlood + bodyDirt < 10 then return tasks end

    local itemType = "Base.Soap2"
    local inventory = hitman:getInventory()
    if inventory:getItemCountFromTypeRecurse(itemType) > 0 then
        local source = HitmanPlayerBase.GetWaterSource(hitman)
        if source then
            local square = source:getSquare()
            local asquare = AdjacentFreeTileFinder.Find(square, hitman)
            if asquare then
                local dist = HitmanUtils.DistTo(hitman:getX(), hitman:getY(), asquare:getX() + 0.5, asquare:getY() + 0.5)
                if dist > 0.90 then
                    table.insert(tasks, HitmanUtils.GetMoveTask(0, asquare:getX(), asquare:getY(), asquare:getZ(), "Walk", dist, false))
                    return tasks
                else
                    local task = {action="Wash", anim="washFace", x=square:getX(), y=square:getY(), z=square:getZ(), time=400}
                    table.insert(tasks, task)

                    return tasks
                end
            end
        end
    else

        -- go get soap
        local task = getItem(hitman, {itemType}, 1)
        if task then
            table.insert(tasks, task)
        end
    end

    return tasks
end