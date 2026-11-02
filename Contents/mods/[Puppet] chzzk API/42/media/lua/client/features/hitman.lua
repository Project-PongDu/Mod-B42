-- PongDu hitman donations (bandit_melee / bandit_ranged).
-- The hitman NPC itself is the Bandits B42 fork (Hitman*.lua). This file only queues
-- donation waves and asks the hitman spawner (server) for a clan near the local player.
-- Hitmen ignore safe zones (B41 91dd350): the wave spawns even inside one.
local hitman = {}

-- wave id (rewardManager) -> clan in common/hitmans/clans.txt
local WAVES = {
    [11] = { name = "melee",  cid = "1a9db80f-9f5e-4e9e-a842-a9ca9a6bc220", size = 4 },
    [15] = { name = "ranged", cid = "7b0273ef-54db-444f-97f9-bf2b22e7fe38", size = 2 },
}
local SPAWN_DIST = 15   -- tiles from the player, random direction

local queue = {}

local function spawnWave(entry, player)
    local wave = WAVES[entry.wave]
    if not wave then
        print("[PongDu][Hitman] unknown wave " .. tostring(entry.wave) .. " sender=" .. tostring(entry.sender))
        return
    end
    local angle = ZombRandFloat(0, 2 * math.pi)
    local args = {
        cid     = wave.cid,
        size    = wave.size,
        program = "Hitman",
        x       = math.floor(player:getX() + SPAWN_DIST * math.cos(angle)),
        y       = math.floor(player:getY() + SPAWN_DIST * math.sin(angle)),
        z       = math.floor(player:getZ()),
    }
    if entry.sender ~= "" then
        args.donorTag = entry.sender .. getText("IGUI_donation_Hitman_owner")
    end
    sendClientCommand(player, "Hitman_Spawner", "Clan", args)
    print("[PongDu][Hitman] wave=" .. wave.name .. " cid=" .. wave.cid .. " size=" .. tostring(wave.size)
        .. " at " .. tostring(args.x) .. "," .. tostring(args.y) .. "," .. tostring(args.z)
        .. " player=" .. tostring(player:getUsername()) .. " sender=" .. tostring(entry.sender))
end

-- queue a wave (called by rewardManager)
function hitman.a(wave, sender)
    table.insert(queue, { wave = wave, sender = sender or "" })
    hitman.b()
end

-- drain the queue (DonationReceiver OnTick)
function hitman.b()
    if #queue == 0 then return end
    local player = getPlayer()
    if not player then return end
    local entry = table.remove(queue, 1)
    spawnWave(entry, player)
end

return hitman
