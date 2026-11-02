-- PONGDU: hitman death on the MP server.
-- 1) builds the corpse loot (see shared/HitmanDeathLoot.lua)
-- 2) removes the brain from the global ModData cluster and transmits it
-- The server does not run the hitman AI, so the brain comes from the clusters (HitmanC0..31)
-- by the zombie id, the same id the clients use (HitmanUtils.GetCharacterID).
-- The brain used to be removed by the client (HitmanRemove from client OnZombieDead). That raced
-- with this handler (loot missing when the client won) and a client-only death removed the brain
-- of a hitman that was still alive on the server (it became a plain zombie).
-- SP keeps the original flow in client/HitmanUpdate.lua, so this file only runs on a MP server.

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

    gmd[id] = nil
    TransmitHitmanCluster(id)
    print("[HITMANS] brain removed (server death) id=" .. tostring(id))
end

Events.OnZombieDead.Add(onZombieDead)

-- brains that survive a restart (a hitman alive at shutdown), to trace hitmen lost after restart
local function onServerStarted()
    local total = 0
    for c = 0, HitmanClusterCount - 1 do
        local gmd = HitmanClusters[c]
        if gmd then
            for bid, brain in pairs(gmd) do
                total = total + 1
                local bc = brain.bornCoords
                print("[HITMANS] brain kept id=" .. tostring(bid) .. " cid=" .. tostring(brain.cid)
                    .. " born=" .. tostring(bc and bc.x) .. "," .. tostring(bc and bc.y) .. "," .. tostring(bc and bc.z)
                    .. " needRestore=" .. tostring(brain.needRestore))
            end
        end
    end
    print("[HITMANS] server started, brains in clusters=" .. tostring(total))
end

Events.OnServerStarted.Add(onServerStarted)
