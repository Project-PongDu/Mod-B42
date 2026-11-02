HitmanServer = HitmanServer or {}
HitmanServer.Hitman_Custom = {}

HitmanServer.Hitman_Custom.SendStats = function()
    local stats = HitmanCustom.GetStats()
    sendServerCommand('Hitman_Custom', 'SendCustomStatsToClient', stats)
end

HitmanServer.Hitman_Custom.ReceiveFromClient  = function(player, args)
    print("[HITMANS] Received Custom Hitmans data from client.")
    HitmanCustom.hitmanData = args.hitmanData
    HitmanCustom.clanData = args.clanData
    HitmanCustom.Save()
    HitmanServer.Hitman_Custom.SendStats()
end

local function onClientCommand(module, command, player, args)
    if module == "Hitman_Custom" and HitmanServer[module] and HitmanServer[module][command] then
        local argStr = ""
        for k, v in pairs(args) do
            argStr = argStr .. " " .. k .. "=" .. tostring(v)
        end
        -- print ("received " .. module .. "." .. command .. " "  .. argStr)
        HitmanServer[module][command](player, args)
    end
end

local function onServerStarted()
    HitmanCustom.Load()
    print("[HITMANS] Custom Hitmans loaded successfully.")
end

Events.OnClientCommand.Add(onClientCommand)
Events.OnServerStarted.Add(onServerStarted)