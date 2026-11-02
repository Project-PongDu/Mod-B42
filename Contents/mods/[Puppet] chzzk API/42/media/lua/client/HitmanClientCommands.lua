HitmanZSClient = {}
HitmanZSClient.Hitman_Commands = {}

HitmanZSClient.Hitman_Commands.UpdateVehicle = function(args)
    for i=0, 100 do
        local vehicleList = getCell():getVehicles():toArray()
        for _, vehicle in pairs(vehicleList) do
            if vehicle:getId() == args.id then
                if vehicle:hasLightbar() then 
                    if args.lightbar then
                        vehicle:setLightbarLightsMode(args.lightbar)
                    end
                    if args.siren then
                        vehicle:setLightbarSirenMode(args.siren)
                    end
                end 

                if args.alarm then
                    vehicle:setAlarmed(true)
                    vehicle:triggerAlarm()
                end
                return
            end
        end
    end
end

HitmanZSClient.Hitman_Commands.UpdateHealth  = function(args)
    local id = args.id
    if id then
        local zombie = HitmanZombie.Cache[id]
        if zombie then
            local health = zombie:getHealth()
            -- print ("CLIENT HEALTH CURRENT: " .. health .. " NEW:" .. args.h)
            if health > args.h then
                zombie:setHealth(args.h)
            end
        end
    end
end

HitmanZSClient.Hitman_Commands.SendCustomToClients = function(args)
    HitmanCustom.hitmanData = args.hitmanData
    HitmanCustom.clanData = args.clanData
    HitmanCustom.Save()
end

HitmanZSClient.Hitman_Commands.SetMarker  = function(args)
    HitmanEventMarkerHandler.set(getRandomUUID(), args.icon, args.time, args.x, args.y, args.color, args.desc)
end

local onServerCommand = function(module, command, args)
    if HitmanZSClient[module] and HitmanZSClient[module][command] then
        local argStr = ""
        for k, v in pairs(args) do
            argStr = argStr .. " " .. k .. "=" .. tostring(v)
        end
        -- print ("client received " .. module .. "." .. command .. " "  .. argStr)
        HitmanZSClient[module][command](args)
    end
end

Events.OnServerCommand.Add(onServerCommand)
