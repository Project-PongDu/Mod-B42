-- t3VehicleDrop MP 릴레이: 클라가 보고하는 낙하산 회수/착지 이벤트를 서버에서 처리.
-- B41의 SpawnVehicleDrop(클라가 좌표/차종을 보내 소환)은 B42에서 제거했다.
-- craftRecipe OnCreate(t3VehicleDrop.OpenKit)가 서버에서 직접 소환하므로 필요 없고,
-- 남겨두면 아무 클라나 임의 차량을 소환할 수 있다.
if not isServer() then return end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= "PongDuVehicleDrop" then return end
    if command == "ClearParachutes" then
        t3VehicleDrop.clearParachutes(getVehicleById(args.vehicleId))
    elseif command == "ChuteLanded" then
        -- 낙하산 하강 연출 종료 보고 (client/VehicleDropChute.lua)
        t3VehicleDrop.chuteLanded(args.cargoVid, player)
    end
end)
