-- [테스트] 숄더차지 어깨빵 애니메이션 파이프라인 검증 - 클라.
--
-- 아무 곳이나 우클릭 -> "[PongDu] Bash anim test" -> 내 캐릭터에서 가장 가까운 좀비(10칸 이내)에
-- 어깨빵 노드(AnimSets/zombie/*/PongDuBashTest.xml)를 1.5초 건다.
--   * 멀티: 서버(server/PongDuBashTestServer.lua)를 거쳐 접속한 모든 클라가 같은 좀비에 변수를 건다.
--   * 싱글: 바로 건다(싱글은 좀비 onlineID 가 전부 -1 이라 객체를 직접 쓴다).
--
-- 클라별 로그(영어):
--   applied zid= remote= state= realState=   <- 변수를 건 순간. remote=true 면 이 클라는 비소유
--   check   zid= played= state=              <- 0.5초 뒤. played=true 면 노드가 실제로 재생됨
--   cleared zid= played= done=               <- 1.5초 뒤 변수 해제. done=true 면 클립 끝까지 재생됨
--   no zombie zid=                           <- 이 클라에 그 좀비가 없음(범위 밖)
-- 테스트 끝나면 이 파일, 서버 파일, AnimSets 노드 12개를 같이 지운다.

local MOD = "PongDuBashTest"
local VAR_BASH = "PongDuShoulderBash"
local VAR_PLAYED = "PongDuBashPlayed"
local VAR_DONE = "PongDuBashDone"
local DURATION_MS = 1500
local CHECK_MS = 500
local PICK_RANGE = 10

local active = {}

local function log(msg)
    print("[PongDu][BashTest] " .. msg)
end

local function stateText(zombie)
    local s = tostring(zombie:getCurrentActionContextStateName())
    local rs = "na"
    if isClient() then rs = tostring(zombie:getRealState()) end
    return s, rs
end

local function apply(zombie, zid)
    zombie:setVariable(VAR_PLAYED, false)
    zombie:setVariable(VAR_DONE, false)
    zombie:setVariable(VAR_BASH, true)
    local s, rs = stateText(zombie)
    local remote = isClient() and zombie:isRemoteZombie()
    log("applied zid=" .. tostring(zid) .. " remote=" .. tostring(remote)
        .. " state=" .. s .. " realState=" .. rs)
    table.insert(active, { zombie = zombie, zid = zid, t0 = getTimestampMs(), checked = false })
end

local function findZombieByOnlineId(zid)
    local cell = getCell()
    if not cell then return nil end
    local list = cell:getZombieList()
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        if z and z:getOnlineID() == zid then return z end
    end
    return nil
end

local function findNearestZombie(player)
    local cell = getCell()
    if not cell then return nil end
    local list = cell:getZombieList()
    local px, py = player:getX(), player:getY()
    local best, bestD = nil, PICK_RANGE * PICK_RANGE
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        if z and not z:isDead() then
            local dx, dy = z:getX() - px, z:getY() - py
            local d = dx * dx + dy * dy
            if d <= bestD then best, bestD = z, d end
        end
    end
    return best
end

local function onTick()
    if #active == 0 then return end
    local now = getTimestampMs()
    for i = #active, 1, -1 do
        local e = active[i]
        local z = e.zombie
        if not z or z:isDead() then
            log("lost zid=" .. tostring(e.zid) .. " (dead or gone)")
            table.remove(active, i)
        else
            local age = now - e.t0
            if not e.checked and age >= CHECK_MS then
                e.checked = true
                local s = stateText(z)
                log("check zid=" .. tostring(e.zid) .. " played=" .. tostring(z:getVariableBoolean(VAR_PLAYED))
                    .. " state=" .. s)
            end
            if age >= DURATION_MS then
                log("cleared zid=" .. tostring(e.zid) .. " played=" .. tostring(z:getVariableBoolean(VAR_PLAYED))
                    .. " done=" .. tostring(z:getVariableBoolean(VAR_DONE)))
                z:setVariable(VAR_BASH, false)
                table.remove(active, i)
            end
        end
    end
end

local function onServerCommand(module, command, args)
    if module ~= MOD or command ~= "Apply" then return end
    local zid = args and tonumber(args.zid)
    if not zid then return end
    local z = findZombieByOnlineId(zid)
    if not z then
        log("no zombie zid=" .. tostring(zid) .. " on this client")
        return
    end
    apply(z, zid)
end

local function canUse(player)
    if isDebugEnabled() then return true end
    if not isClient() then return true end
    if isAdmin() then return true end
    local role = player:getRole()
    return role ~= nil and Capability ~= nil and Capability.UseDebugContextMenu ~= nil
        and role:hasCapability(Capability.UseDebugContextMenu)
end

local function fire(player)
    local z = findNearestZombie(player)
    if not z then
        log("no zombie within " .. tostring(PICK_RANGE) .. " tiles")
        return
    end
    if isClient() then
        local zid = z:getOnlineID()
        log("request zid=" .. tostring(zid))
        sendClientCommand(player, MOD, "Request", { zid = zid })
    else
        apply(z, -1)
    end
end

local function onFillMenu(playerID, context, worldobjects, test)
    if test then return end
    local player = getSpecificPlayer(playerID)
    if not player or not canUse(player) then return end
    context:addOption("[PongDu] Bash anim test (nearest zombie)", player, fire)
end

Events.OnPreFillWorldObjectContextMenu.Add(onFillMenu)
Events.OnServerCommand.Add(onServerCommand)
Events.OnTick.Add(onTick)
