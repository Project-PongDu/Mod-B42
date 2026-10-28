-- [테스트] 숄더차지 어깨빵 애니메이션 파이프라인 검증 - 서버 중계.
-- 클라(client/PongDuBashTest.lua)가 고른 좀비 onlineID 를 받아 전체 클라에 방송한다.
-- 좀비 패킷(ZombiePacket)은 상태·walkType·위치·체력만 보내고 커스텀 애니 변수는 안 보내므로,
-- 각 클라가 자기 쪽 좀비 객체에 변수를 직접 세워야 소유·비소유 클라 모두에서 재생된다.
-- 테스트 끝나면 client/PongDuBashTest.lua, AnimSets/zombie/*/PongDuBashTest.xml 과 같이 지운다.
if isClient() then return end

local MOD = "PongDuBashTest"

local function canUse(player)
    if isDebugEnabled() then return true end
    if player:isAccessLevel("admin") then return true end
    local role = player:getRole()
    return role ~= nil and Capability ~= nil and Capability.UseDebugContextMenu ~= nil
        and role:hasCapability(Capability.UseDebugContextMenu)
end

local function onClientCommand(module, command, player, args)
    if module ~= MOD or command ~= "Request" then return end
    local zid = args and tonumber(args.zid)
    local who = player and player:getUsername() or "nil"
    if not player or not canUse(player) then
        print("[PongDu][BashTest] server denied request from=" .. tostring(who))
        return
    end
    if not zid then
        print("[PongDu][BashTest] server bad request (no zid) from=" .. tostring(who))
        return
    end
    print("[PongDu][BashTest] server relay zid=" .. tostring(zid) .. " from=" .. tostring(who))
    sendServerCommand(MOD, "Apply", { zid = zid })
end

Events.OnClientCommand.Add(onClientCommand)
