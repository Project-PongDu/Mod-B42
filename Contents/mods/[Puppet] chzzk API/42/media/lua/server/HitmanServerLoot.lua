-- PONGDU: builds the hitman corpse loot on the MP server (see shared/HitmanDeathLoot.lua).
-- The server does not run the hitman AI, so the brain comes from the global ModData clusters
-- (HitmanC0..31) by the zombie id, the same id the clients use (HitmanUtils.GetCharacterID).
-- SP builds the loot in client/HitmanUpdate.lua, so this file only runs on a MP server.

if not isServer() then return end

local function onZombieDead(zombie)
    if not zombie then return end
    local id = HitmanUtils.GetCharacterID(zombie)
    local gmd = GetHitmanClusterData(id)
    local brain = gmd and gmd[id]
    if not brain then return end

    local ok, res = pcall(Hitman.BuildDeathLoot, zombie, brain)
    print("[HITMANS] death loot id=" .. tostring(id) .. " ok=" .. tostring(ok) .. " items=" .. tostring(res)
        .. " melee=" .. tostring(brain.weapons and brain.weapons.melee)
        .. " primary=" .. tostring(brain.weapons and brain.weapons.primary and brain.weapons.primary.name)
        .. " zid=" .. tostring(zombie:getOnlineID()))
end

Events.OnZombieDead.Add(onZombieDead)
