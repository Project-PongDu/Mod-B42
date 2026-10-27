-- VehicleDropKeyGrant: 차량 보급 열쇠 지급 결과 로그 (MP 클라).
--
-- 열쇠는 서버(server/t3VehicleDropSpawner.lua)가 createVehicleKey 로 만들어 요청자 인벤에 넣고
-- sendAddItemToContainer 로 내려보낸다. B42 MP 는 아이템이 서버 권위라, 예전처럼 이 파일이
-- 클라 인벤에 키를 직접 만들면 키가 보이기만 하고 차 문·시동에 쓰이지 않았다.
-- 여기서는 서버가 보낸 "KeyGranted" 를 받아 키가 실제로 인벤에 들어왔는지만 로그로 남긴다.

local function findKey(player, keyId)
    local items = player:getInventory():getItems()
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if it and it:getType() == "CarKey" and it:getKeyId() == keyId then return it end
    end
    return nil
end

local function onServerCommand(module, command, args)
    if module ~= "PongDuVehicleDrop" then return end
    if command ~= "KeyGranted" then return end

    local keyId = args and args.keyId
    local player = getPlayer()
    if not player or not keyId then
        print("[VehicleDropKeyGrant] KeyGranted ignored (player=" .. tostring(player ~= nil)
            .. ", keyId=" .. tostring(keyId) .. ")")
        return
    end

    -- 인벤 추가 패킷과 이 명령의 도착 순서가 보장되지 않으므로 1초 뒤에 확인한다.
    local elapsed = 0
    local function check()
        elapsed = elapsed + getGameTime():getTimeDelta() * 1000
        if elapsed < 1000 then return end
        Events.OnTick.Remove(check)
        local p = getPlayer()
        local key = p and findKey(p, keyId)
        print("[VehicleDropKeyGrant] key check keyId=" .. tostring(keyId)
            .. " vehicleId=" .. tostring(args.vehicleId)
            .. " inInventory=" .. tostring(key ~= nil)
            .. " name=" .. tostring(key and key:getDisplayName()))
    end
    Events.OnTick.Add(check)
end

Events.OnServerCommand.Add(onServerCommand)
