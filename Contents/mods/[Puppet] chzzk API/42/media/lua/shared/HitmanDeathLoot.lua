-- PONGDU: hitman corpse loot, moved out of client/HitmanUpdate.lua OnZombieDead.
--
-- B42 MP builds the corpse inventory on the server:
--   IsoZombie.onKilled (server/SP) -> DoZombieInventory -> OnZombieDead -> DoDeath
--   and the server inventory goes to the clients with DeadZombiePacket.
-- The original mod built the loot in the client OnZombieDead, so in MP the client corpse held items
-- the server never had: worn clothes listed twice, weapon/ID only on some corpses, items that
-- cannot be taken. Now the loot is built only where onKilled builds the inventory:
--   SP        : client/HitmanUpdate.lua OnZombieDead (same timing as the original)
--   MP server : server/HitmanServerLoot.lua OnZombieDead (brain from the global ModData clusters)
--   MP client : does not touch the corpse inventory

Hitman = Hitman or {}

local function predicateRemovable(item)
    if not item:getModData().hitmanPreserve and not instanceof(item, "Clothing") then
        return true
    end
end

-- returns the number of items in the corpse inventory (for logs)
function Hitman.BuildDeathLoot(hitman, brain)
    local inventory = hitman:getInventory()
    local items = ArrayList.new()

    inventory:getAllEvalRecurse(predicateRemovable, items)
    for i=0, items:size()-1 do
        local item = items:get(i)
        inventory:Remove(item)
        inventory:setDrawDirty(true)
    end

    -- update stuck weapons
    local stuckLocationList = {"MeatCleaver in Back", "Axe Back", "Knife in Back", "Knife Left Leg", "Knife Right Leg", "Knife Shoulder", "Knife Stomach"}
    for _, stuckLocation in pairs(stuckLocationList) do
        local attachedItem = hitman:getAttachedItem(stuckLocation)
        if attachedItem then
            inventory:AddItem(attachedItem)
            inventory:setDrawDirty(true)
        end
    end

    Hitman.UpdateItemsToSpawnAtDeath(hitman, brain)

    hitman:DoZombieInventory()

    -- drop extra suitcase item 
    if brain and brain.bag then
        if brain.bag == "Briefcase" then
            local bag = HitmanCompatibility.InstanceItem("Base.Briefcase")
            local bagContainer = bag:getItemContainer()
            if bagContainer then
                local rn = ZombRand(3)
                if rn == 0 then
                    for i = 1, 1000 do
                        local money = HitmanCompatibility.InstanceItem("Base.Money")
                        bagContainer:AddItem(money)
                    end
                elseif rn == 1 then
                    local c1 = HitmanCompatibility.InstanceItem("Base.Corset_Black")
                    local c2 = HitmanCompatibility.InstanceItem("Base.StockingsBlack")
                    local c3 = HitmanCompatibility.InstanceItem("Base.Hat_PeakedCapArmy")
                    bagContainer:AddItem(c1)
                    bagContainer:AddItem(c2)
                    bagContainer:AddItem(c3)
                elseif rn == 2 then
                    local c1 = HitmanCompatibility.InstanceItem("Base.Machete")
                    bagContainer:AddItem(c1)
                    if HitmanCompatibility.GetGameVersion() >= 42 then
                        local c2 = HitmanCompatibility.InstanceItem("Base.Hat_HalloweenMaskVampire")
                        local c3 = HitmanCompatibility.InstanceItem("Base.BlackRobe")
                        bagContainer:AddItem(c2)
                        bagContainer:AddItem(c3)
                    end
                end
                hitman:getSquare():AddWorldInventoryItem(bag, ZombRandFloat(0.2, 0.8), ZombRandFloat(0.2, 0.8), 0)
            end
        end
    end

    return inventory:getItems():size()
end
