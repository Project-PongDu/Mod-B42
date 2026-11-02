-- PONGDU: vanilla Fishing.Handler.onEquipPrimary (client/Fishing/FishingHandler.lua) runs on every
-- OnEquipPrimary and calls player:getUsername() in MP. Hitmen are IsoZombie (no getUsername) and equip
-- weapons with setPrimaryHandItem, which threw "Object tried to call nil in handleFishing" on every equip.
-- The original Bandits mod has the same problem. Re-register the vanilla handler for IsoPlayer only.

local function patchFishingHandler()
    if not (Fishing and Fishing.Handler and Fishing.Handler.onEquipPrimary) then
        print("[HITMANS] fishing handler patch skipped (vanilla handler not found)")
        return
    end
    if Fishing.Handler.hitmanPlayerOnly then return end

    local original = Fishing.Handler.onEquipPrimary
    Events.OnEquipPrimary.Remove(original)
    Fishing.Handler.onEquipPrimary = function(character, inventoryItem)
        if instanceof(character, "IsoPlayer") then
            original(character, inventoryItem)
        end
    end
    Events.OnEquipPrimary.Add(Fishing.Handler.onEquipPrimary)
    Fishing.Handler.hitmanPlayerOnly = true
    print("[HITMANS] fishing handler patched (IsoPlayer only)")
end

Events.OnGameBoot.Add(patchFishingHandler)
Events.OnGameStart.Add(patchFishingHandler)
