HitmanPermanent = HitmanPermanent or {}

-- if player travels to different cell, hitmans get unloaded
-- this logic restores hitmans marked as permanent in their original location
-- should the player decide to come back to the cell where they were born.

HitmanPermanent.Check = function()
    if true then return end

    local gmd = GetHitmanModData()
    if not gmd.Queue then return end

    local cache = HitmanZombie.CacheLightB
    if not cache then return end

    local player = getSpecificPlayer(0)
    local cell = getCell()
    for id, gmdBrain in pairs(gmd.Queue) do
        if gmdBrain.permanent and not gmdBrain.inVehicle then
            if not cache[id] then
                local square = cell:getGridSquare(gmdBrain.bornCoords.x, gmdBrain.bornCoords.y, gmdBrain.bornCoords.z)
                if square then
                    sendClientCommand(player, 'Hitman_Spawner', 'Restore', gmdBrain)
                end
            end
        end
    end
end

