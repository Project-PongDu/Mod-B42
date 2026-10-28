-- 레커(돌진 특수좀비) 클라 처리. 설계는 shared/PongDuWrecker.lua 머리 주석 참고.
--
-- 서버가 방송한 단계를 받아 모든 클라가 자기 쪽 좀비에 애니메이션 단계 변수를 세운다.
-- 그 위에 클라 역할에 따라:
--   * 소유 클라(MP 에서 isRemoteZombie()=false, SP 는 항상):
--       warn/sprint/bash/recovery 동안 AI 이동을 멈추고(바닐라 no-op 상태 W.HOLD_STATE 로 전환),
--       warn/sprint 동안 서버가 준 방향으로 몸을 고정한다. 돌진 이동은 sprint 노드 클립의 루트모션.
--       sprint 중 벽·문·차량에 막히면(isCollidedThisFrame: 칸 경계 충돌만 서고 캐릭터 충돌은 안 섬,
--       IsoMovingObject.java:1158) 서버에 Crash 를 보고한다. crash 단계를 받으면 넘어진다.
--   * 모든 클라: sprint 중 자기 로컬 플레이어가 레커와 HIT_RADIUS 안이면 그 플레이어를 넘어뜨리고
--     (바닐라 스프린터 충돌과 같은 호출 순서, IsoGameCharacter.java:14828~14842) 서버에 Hit 를 보고한다.

require "PongDuWrecker"

local W  = PongDuWrecker
local PH = W.PH
local LOG = "[PongDu][Wrecker] "

local CRASH_GRACE_MS   = 150    -- sprint 시작 직후 이 시간 동안은 충돌을 보지 않는다
local SAFETY_MS        = 8000   -- 단계 통지가 끊겼을 때 스스로 풀리는 시간
local SPRINT_LOG_MS    = 500

local _act = {}   -- [키] = { z, zid, ph, seq, dx, dy, t0, held, hitLocal, crashSent, lastLog, lx, ly }

local function keyOf(zid, z)
    if isClient() then return zid end
    return z
end

local function isOwner(z)
    if isClient() then return not z:isRemoteZombie() end
    return true
end

local function findZombie(zid)
    local cell = getCell()
    if not cell then return nil end
    local list = cell:getZombieList()
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        if z and z:getOnlineID() == zid then return z end
    end
    return nil
end

-- ── 이동 고정 (소유 클라) ─────────────────────────────────────────────────────
local function hold(e)
    local z = e.z
    local hs = z:tryGetAIState(W.HOLD_STATE)
    if not hs then
        if not e.holdFailLogged then
            e.holdFailLogged = true
            print(LOG .. "hold state unavailable zid=" .. tostring(e.zid))
        end
        return
    end
    if not e.held then
        local pfb = z:getPathFindBehavior2()
        if pfb then pfb:cancel() end
        z:setPath2(nil)
        e.held = true
    end
    if z:getCurrentState() ~= hs then
        z:changeState(hs)
    end
end

local function release(e)
    if not e.held then return end
    e.held = false
    local z = e.z
    if not z or z:isDead() or z:isOnFloor() or z:isKnockedDown() then return end
    local t = z:getTarget()
    if t and instanceof(t, "IsoPlayer") and not t:isDead() and t:getCurrentSquare() then
        z:pathToCharacter(t)
        z:changeState(WalkTowardState.instance())
    else
        z:changeState(ZombieIdleState.instance())
    end
end

local function clearAnim(z)
    if z then z:setVariable(W.VAR_PHASE, "") end
end

local function finish(k, e, reason)
    release(e)
    clearAnim(e.z)
    _act[k] = nil
    print(LOG .. "end zid=" .. tostring(e.zid) .. " seq=" .. tostring(e.seq) .. " reason=" .. tostring(reason))
end

-- ── 피격 (모든 클라, 자기 로컬 플레이어) ──────────────────────────────────────
local function bumpFall(player, z)
    if player:isBumped() or player:isOnFloor() then return end
    player:clearVariable("BumpFallType")
    player:setBumpType("stagger")
    player:setBumpDone(false)
    player:setBumpFall(true)
    player:setBumpedChr(z)
    if z:isBehind(player) then
        player:setBumpFallType("pushedBehind")
    else
        player:setBumpFallType("pushedFront")
    end
    player:reportEvent("wasBumped")
end

local function checkVictims(e)
    local z = e.z
    local zz = math.floor(z:getZ())
    for i = 0, getNumActivePlayers() - 1 do
        local p = getSpecificPlayer(i)
        if p and not p:isDead() and not e.hitLocal[i] and math.floor(p:getZ()) == zz then
            local dx, dy = p:getX() - z:getX(), p:getY() - z:getY()
            if dx * dx + dy * dy <= W.HIT_RADIUS * W.HIT_RADIUS then
                e.hitLocal[i] = true
                bumpFall(p, z)
                print(LOG .. "hit local player=" .. tostring(p:getUsername()) .. " zid=" .. tostring(e.zid)
                    .. " seq=" .. tostring(e.seq))
                W.sendClaim(p, "Hit", { ["zid"] = e.zid, ["seq"] = e.seq }, z)
            end
        end
    end
end

-- ── 충돌 (소유 클라) ─────────────────────────────────────────────────────────
local function checkCrash(e, tnow)
    if e.crashSent or tnow - e.t0 < CRASH_GRACE_MS then return end
    local z = e.z
    if not (z:isCollidedThisFrame() or z:isCollidedWithVehicle()) then return end
    e.crashSent = true
    print(LOG .. "crash detected zid=" .. tostring(e.zid) .. " seq=" .. tostring(e.seq)
        .. " vehicle=" .. tostring(z:isCollidedWithVehicle())
        .. " at " .. string.format("%.2f,%.2f", z:getX(), z:getY()))
    local reporter = getSpecificPlayer(0) or getPlayer()
    W.sendClaim(reporter, "Crash", { ["zid"] = e.zid, ["seq"] = e.seq }, z)
end

local function crashFall(e)
    local z = e.z
    release(e)
    if not z:isOnFloor() and not z:isKnockedDown() then
        z:knockDown(false)
        print(LOG .. "crash knockdown zid=" .. tostring(e.zid))
    end
end

-- ── 단계 수신 ────────────────────────────────────────────────────────────────
W.clientHandler = function(args, zobj)
    args = args or {}
    local zid = tonumber(args["zid"])
    local ph = args["ph"]
    local z = zobj or (zid and findZombie(zid))
    if not z then
        print(LOG .. "phase " .. tostring(ph) .. " for zid=" .. tostring(zid) .. " but zombie not on this client")
        return
    end
    local k = keyOf(zid, z)
    local e = _act[k]

    if ph == PH.NONE then
        if e then
            e.z = z
            finish(k, e, "server none")
        else
            clearAnim(z)
        end
        return
    end

    if not e then
        e = { hitLocal = {} }
        _act[k] = e
    end
    e.z, e.zid, e.ph = z, zid, ph
    e.seq = tonumber(args["seq"])
    e.dx, e.dy = tonumber(args["dx"]), tonumber(args["dy"])
    e.t0 = getTimestampMs()

    print(LOG .. "phase zid=" .. tostring(zid) .. " seq=" .. tostring(e.seq) .. " ph=" .. tostring(ph)
        .. " owner=" .. tostring(isOwner(z))
        .. " state=" .. tostring(z:getCurrentActionContextStateName()))

    if ph == PH.CRASH then
        clearAnim(z)
        if isOwner(z) then crashFall(e) end
        return
    end

    z:setVariable(W.VAR_PHASE, ph)
    if ph == PH.SPRINT then
        e.hitLocal = {}
        e.crashSent = false
        e.lx, e.ly, e.lastLog = z:getX(), z:getY(), e.t0
    end
end

-- 서버 MP 수신
Events.OnServerCommand.Add(function(module, command, args)
    if module ~= W.NET or command ~= "Phase" then return end
    W.clientHandler(args, nil)
end)

-- ── 매 틱 ────────────────────────────────────────────────────────────────────
Events.OnTick.Add(function()
    local tnow = getTimestampMs()
    for k, e in pairs(_act) do
        local z = e.z
        if not z or z:isDead() then
            _act[k] = nil
        elseif tnow - e.t0 > SAFETY_MS then
            finish(k, e, "safety timeout ph=" .. tostring(e.ph))
        elseif e.ph ~= PH.CRASH then
            local owner = isOwner(z)
            if owner then
                hold(e)
                if (e.ph == PH.WARN or e.ph == PH.SPRINT) and e.dx and (e.dx ~= 0 or e.dy ~= 0) then
                    z:setTargetAndCurrentDirection(e.dx, e.dy)
                end
            elseif e.held then
                e.held = false   -- 소유권이 넘어가면 새 소유 클라가 고정한다
            end
            -- 단계 변수는 다른 코드나 좀비 재로드로 지워질 수 있어 계속 세운다
            if z:getVariableString(W.VAR_PHASE) ~= e.ph then
                z:setVariable(W.VAR_PHASE, e.ph)
            end
            if e.ph == PH.SPRINT then
                if owner then checkCrash(e, tnow) end
                checkVictims(e)
                if owner and tnow - e.lastLog >= SPRINT_LOG_MS then
                    local dx, dy = z:getX() - e.lx, z:getY() - e.ly
                    print(LOG .. "sprint progress zid=" .. tostring(e.zid)
                        .. " moved=" .. string.format("%.2f", math.sqrt(dx * dx + dy * dy))
                        .. " state=" .. tostring(z:getCurrentActionContextStateName()))
                    e.lx, e.ly, e.lastLog = z:getX(), z:getY(), tnow
                end
            end
        end
    end
end)

Events.OnZombieDead.Add(function(zombie)
    for k, e in pairs(_act) do
        if e.z == zombie then _act[k] = nil end
    end
end)
