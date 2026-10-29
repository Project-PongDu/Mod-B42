-- 레커(돌진 특수좀비) 클라 처리. 설계는 shared/PongDuWrecker.lua 머리 주석 참고.
--
-- 서버가 방송한 단계를 받아 모든 클라가 자기 쪽 좀비에 애니메이션 단계 변수를 세운다.
-- 그 위에 클라 역할에 따라:
--   * 소유 클라(MP 에서 isRemoteZombie()=false, SP 는 항상):
--       warn/sprint/recovery 동안 AI 이동을 멈추고(바닐라 no-op 상태 W.HOLD_STATE 로 전환),
--       방향은 원본과 같이: warn 은 대상을 계속 바라보고(TRACK_TARGET), sprint 는 시작 순간 이 클라에서
--       본 대상 쪽으로 한 번 잡아 유지하고, recovery 는 들어올 때 방향을 유지한다(LOCK_ON_ENTER).
--       돌진 이동은 sprint 노드 클립(원본 Zombie_PZM_Wrecker_ChargeSprint)의 루트모션.
--       단, 고정은 애니메이션 상태가 W.HOLD_STATES 에 있을 때만 한다. 울타리 넘기 등 다른 상태면
--       손을 떼고(바닐라 AI 상태로 되돌림) 그 상태가 끝나기를 기다린다. 이걸 무시하고 고정하면
--       애니메이션은 climbfence 인데 AI 는 다른 상태가 되어 그 자세로 영영 굳는다.
--       sprint 중 벽·문·울타리·차량에 막히면(isCollidedThisFrame: 칸 경계 충돌만 서고 캐릭터 충돌은
--       안 섬, IsoMovingObject.java:1158) 부딪힌 칸과 방향을 서버에 Crash 로 보고한다.
--       crash 단계를 받으면 넘어진다.
--   * 모든 클라: sprint 중 자기 로컬 플레이어가 레커와 몸이 부딪히면(OnCharacterCollide, 원본과 같음)
--     그 플레이어를 넘어뜨리고(바닐라 스프린터 충돌과 같은 호출 순서, IsoGameCharacter.java:14828~14842)
--     서버에 Hit 를 보고한다. 돌진은 멈추지 않으므로 같은 돌진에 여러 명이 맞을 수 있다(플레이어마다 1번).
--   * 모든 클라: warn 을 받으면 예고음(원본 사운드)을 원본과 같이 좀비 목소리 채널(playVocals)로 내고
--     예고 동안 바닐라 좀비 울음(zombie.vocalEvent)을 끈다. 단계가 바뀌면 예고음을 멈춘다
--     (원본 PZM_ActionPresentation PZM_applyPhaseVocal/PZM_suppressVanillaVocal).
--     예고 클립 재생 위치는 W.VAR_PROGRESS 로 넘긴다(원본 ActionProgress).
--   * 소유 클라: sprint 중 자기 쪽 위치로 W.CHARGE_DISTANCE 칸을 가면 서버에 Arrive 를 보내고
--     바로 recovery 로 넘어간다(서버 위치는 늦게 따라와 서버만 재면 한참 더 간다).

require "PongDuWrecker"

local W  = PongDuWrecker
local PH = W.PH
local LOG = "[PongDu][Wrecker] "

local CRASH_GRACE_MS   = 50     -- sprint 시작 직후 이 시간 동안은 충돌을 보지 않는다 (원본 첫 검사 3틱)
local SAFETY_MS        = 8000   -- 단계 통지가 끊겼을 때 스스로 풀리는 시간
local SPRINT_LOG_MS    = 500
local WATCH_MS         = 6000   -- 돌진이 끝난 뒤 애니메이션·AI 상태 어긋남을 감시하는 시간
local WATCH_LOG_MS     = 1000

-- AI 상태와 짝이 맞아야 끝나는 애니메이션 상태. 돌진이 끝난 뒤 이 상태인데 AI 가
-- 다른 상태면 그 자세로 굳으므로 짝을 맞춰 준다.
local RESYNC_STATES = { climbfence = true, climbwindow = true }

local FALL_VAR_MIN_MS  = 500    -- 넘어짐 변수는 최소 이만큼 유지 (bumped 진입 전 지우지 않게)
local FALL_VAR_MAX_MS  = 6000   -- 넘어짐 변수 최대 유지 시간

local _fallVar = {}   -- [IsoPlayer] = 켠 시각 (넘어짐 변수 정리용)
local _pendingKnock = {}  -- [IsoZombie] = { zid, t } 넘기(climbfence)를 끝낸 뒤 넘어뜨릴 슬래머
local _pendingChase = {}  -- [IsoZombie] = t  공격 종료 처리 뒤 idle 로 떨어지면 다시 쫓게 할 슬래머
local KNOCK_WAIT_MS = 1000
local CHASE_WAIT_MS = 1500
local _act   = {}   -- [키] = { z, zid, ph, seq, dx, dy, t0, held, hitLocal, crashSent, lastLog, lx, ly, policy }
local _watch = {}   -- [키] = { z, zid, untilMs, lastLog }

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

local function validTarget(z)
    local t = z:getTarget()
    return t and instanceof(t, "IsoPlayer") and not t:isDead() and t:getCurrentSquare() and t or nil
end

-- 고정을 풀고 현재 애니메이션 상태에 맞는 바닐라 AI 상태로 되돌린다 (원본 PZM_ActionStateAdapter 방식).
--   walktoward : 대상이 있으면 그쪽 경로 + WalkToward, 없으면 Idle
--   idle       : 대상이 있으면 경로 + WalkToward (고정 중 애니메이션이 idle 로 떨어졌을 수 있다)
--   attack     : 대상이 공격 거리 밖이면(bAttack=false) 공격을 끝낸 것으로 하고(ZombieBiteDone,
--                actiongroups zombie/attack/to_idle.xml) 경로 + WalkToward. [원본과 다름]
--                돌진 중 플레이어 곁을 지나면 애니메이션이 lunge->attack 으로 넘어가고(bAttack,
--                lunge/to_attack.xml) 돌진 클립이 바닐라 공격 클립을 덮어 ZombieBiteDone 이 안 서서
--                attack 에 남는다. 원본처럼 AttackState 로 돌리면 멀리 있는 대상을 향해 헛공격 모션을 한다.
--                대상이 공격 거리 안이면 원본대로 AttackState (물기).
--   그 외      : 애니메이션 상태 이름으로 등록된 AI 상태 (attack, lunge, climbfence 등)
--   등록 없음  : 대상 있으면 WalkToward, 없으면 Idle
local function resumeVanilla(z)
    local raw = z:getCurrentActionContextStateName()
    local name = W.normState(raw)
    local resume = raw and z:tryGetAIState(raw) or nil
    local t = validTarget(z)
    local how
    if name == "walktoward" then
        if t and resume then
            z:pathToCharacter(t)
            z:changeState(resume)
            how = "walktoward"
        else
            z:changeState(ZombieIdleState.instance())
            how = "idle"
        end
    elseif name == "idle" and t then
        z:pathToCharacter(t)
        z:changeState(WalkTowardState.instance())
        how = "walktoward(from idle)"
    elseif name == "attack" and t and not z:getVariableBoolean("bAttack") then
        -- ZombieBiteDone 으로 애니가 attack->idle 로 넘어가면 AI 가 ZombieIdleState 로 강제 전환된다
        -- (StateMachineComponent.actionStateChanged). ZombieIdleState 는 대상을 쫓지 않아 수 초간 멀뚱히 선다.
        -- 그래서 idle 로 넘어간 뒤 OnTick 에서 한 번 더 경로 + WalkToward 를 건다(_pendingChase).
        z:setVariable("ZombieBiteDone", true)
        z:pathToCharacter(t)
        z:changeState(WalkTowardState.instance())
        _pendingChase[z] = getTimestampMs()
        how = "walktoward(attack out of reach)"
    elseif resume then
        z:changeState(resume)
        how = tostring(raw)
    elseif t then
        z:pathToCharacter(t)
        z:changeState(WalkTowardState.instance())
        how = "walktoward(fallback)"
    else
        z:changeState(ZombieIdleState.instance())
        how = "idle(fallback)"
    end
    return raw, how
end

local function release(e, why)
    if not e.held then return end
    e.held = false
    local z = e.z
    if not z or z:isDead() or z:isOnFloor() or z:isKnockedDown() then return end
    local raw, how = resumeVanilla(z)
    print(LOG .. "release zid=" .. tostring(e.zid) .. " why=" .. tostring(why)
        .. " anim=" .. tostring(raw) .. " resume=" .. tostring(how))
end

local function clearAnim(z)
    if z then
        z:setVariable(W.VAR_PHASE, "")
        z:clearVariable(W.VAR_PROGRESS)
    end
end

local function faceDir(z, dx, dy)
    if not dx or not dy then return end
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.001 then return end
    z:setTargetAndCurrentDirection(dx / len, dy / len)
end

-- 예고 중 바라볼 대상: 서버가 고른 대상(tid), 없으면 이 클라 좀비의 대상
local function warnTarget(e)
    local t = nil
    if e.tid and e.tid >= 0 and getPlayerByOnlineID then
        t = getPlayerByOnlineID(e.tid)
    end
    if not t then t = validTarget(e.z) end
    if t and not t:isDead() and t:getCurrentSquare() then return t end
    return nil
end

-- ── 예고음 (원본 PZM_applyPhaseVocal / PZM_suppressVanillaVocal / PZM_stopCustomVocal) ──
local function muteVanillaVocal(z)
    pcall(function()
        local h = z.vocalEvent
        if h ~= nil and h ~= 0 then
            z:getEmitter():stopSoundLocal(h)
            z.vocalEvent = 0
        end
    end)
end

local function stopVocal(e)
    local h = e.vocal
    e.vocal = nil
    e.muteVanilla = false
    if h ~= nil and h ~= 0 and e.z then
        local ok, err = pcall(function() e.z:getEmitter():stopSoundLocal(h) end)
        if not ok then print(LOG .. "warn vocal stop failed zid=" .. tostring(e.zid) .. " err=" .. tostring(err)) end
    end
end

local function startWarnVocal(e)
    stopVocal(e)
    local z = e.z
    e.muteVanilla = true
    muteVanillaVocal(z)
    local ok, h = pcall(function() return z:getEmitter():playVocals(W.WARN_SOUND) end)
    if ok and h ~= nil and h ~= 0 then
        e.vocal = h
    else
        e.muteVanilla = false
        print(LOG .. "warn vocal failed zid=" .. tostring(e.zid) .. " ok=" .. tostring(ok) .. " ret=" .. tostring(h))
    end
end

local function finish(k, e, reason)
    stopVocal(e)
    release(e, "end")
    clearAnim(e.z)
    _act[k] = nil
    if e.z and isOwner(e.z) then
        _watch[k] = { z = e.z, zid = e.zid, untilMs = getTimestampMs() + WATCH_MS, lastLog = 0 }
    end
    print(LOG .. "end zid=" .. tostring(e.zid) .. " seq=" .. tostring(e.seq) .. " reason=" .. tostring(reason))
end

-- ── 피격 (모든 클라, 자기 로컬 플레이어) ──────────────────────────────────────
-- 넘어짐 클립 선택 변수: 켜면 PongDuSlammerFall 노드가 바닐라 밀려 넘어짐을 덮는다.
-- bumped 상태를 벗어나면 OnTick 이 지운다.
local function markFall(player)
    player:setVariable(W.VAR_PLAYER_FALL, true)
    _fallVar[player] = getTimestampMs()
end

local function bumpFall(player, z)
    if player:isBumped() or player:isOnFloor() then return end
    -- 울타리 넘기 실패 클립은 앞으로 몸을 던지며 구른다. 돌진 방향(슬래머가 보는 쪽)으로
    -- 몸을 돌려 놓아야 밀린 방향으로 날아간다. BumpedState.enter 가 애니 각도를 방향으로 쓰므로
    -- 애니 각도까지 같이 돌린다(setTargetAndCurrentDirection).
    local f = z:getForwardDirection()
    if f and (f:getX() ~= 0 or f:getY() ~= 0) then
        player:setTargetAndCurrentDirection(f:getX(), f:getY())
    end
    markFall(player)
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

-- 레커 몸에 부딪힌 자기 로컬 플레이어 (원본 PZM_onCharacterCollide)
local function onCollide(first, second)
    local p, z
    if instanceof(first, "IsoPlayer") and instanceof(second, "IsoZombie") then
        p, z = first, second
    elseif instanceof(second, "IsoPlayer") and instanceof(first, "IsoZombie") then
        p, z = second, first
    else
        return
    end
    local e = _act[keyOf(z:getOnlineID(), z)]
    if not e or e.ph ~= PH.SPRINT or e.z ~= z then return end
    if not p:isLocalPlayer() or p:isDead() or p:getVehicle() then return end
    if e.hitLocal[p] then return end
    if not p:getCurrentSquare() then return end
    e.hitLocal[p] = true
    bumpFall(p, z)
    print(LOG .. "hit local player=" .. tostring(p:getUsername()) .. " zid=" .. tostring(e.zid)
        .. " seq=" .. tostring(e.seq))
    W.sendClaim(p, "Hit", { ["zid"] = e.zid, ["seq"] = e.seq }, z)
end

-- ── 충돌 (소유 클라) ─────────────────────────────────────────────────────────
-- 부딪힌 면: 충돌 플래그 중 돌진(앞) 방향과 가장 맞는 것 (원본 PZM_getImpactDirection)
local function impactDir(z, e)
    local fx, fy = e.dx or 0, e.dy or 0
    if fx == 0 and fy == 0 then
        local f = z:getForwardDirection()
        fx, fy = f:getX(), f:getY()
    end
    local best, bestScore = nil, -999
    local c = {
        { z:isCollidedN(), "N", -fy },
        { z:isCollidedS(), "S", fy },
        { z:isCollidedE(), "E", fx },
        { z:isCollidedW(), "W", -fx },
    }
    for _, v in ipairs(c) do
        if v[1] and v[3] > bestScore then best, bestScore = v[2], v[3] end
    end
    return best
end

local function checkCrash(e, tnow)
    if e.crashSent or tnow - e.t0 < CRASH_GRACE_MS then return end
    local z = e.z
    if not (z:isCollidedThisFrame() or z:isCollidedWithVehicle()) then return end
    e.crashSent = true
    local sq = z:getCurrentSquare()
    local dir = impactDir(z, e)
    print(LOG .. "crash detected zid=" .. tostring(e.zid) .. " seq=" .. tostring(e.seq)
        .. " vehicle=" .. tostring(z:isCollidedWithVehicle()) .. " dir=" .. tostring(dir)
        .. " state=" .. tostring(z:getCurrentActionContextStateName())
        .. " at " .. string.format("%.2f,%.2f", z:getX(), z:getY()))
    local reporter = getSpecificPlayer(0) or getPlayer()
    W.sendClaim(reporter, "Crash", {
        ["zid"] = e.zid, ["seq"] = e.seq,
        ["hx"] = sq and sq:getX() or math.floor(z:getX()),
        ["hy"] = sq and sq:getY() or math.floor(z:getY()),
        ["hz"] = sq and sq:getZ() or math.floor(z:getZ()),
        ["dir"] = dir or "",
    }, z)
end

-- 10칸 도달 (소유 클라): 서버에 알리고 바로 회복으로 넘어간다. 서버 recovery 통지가 오면 같은 단계라 그대로 잇는다.
local function checkArrive(e, tnow)
    if e.arriveSent or not e.sx then return end
    local z = e.z
    local dx, dy = z:getX() - e.sx, z:getY() - e.sy
    local d = math.sqrt(dx * dx + dy * dy)
    if d < W.CHARGE_DISTANCE then return end
    e.arriveSent = true
    print(LOG .. "arrive zid=" .. tostring(e.zid) .. " seq=" .. tostring(e.seq)
        .. " d=" .. string.format("%.2f", d) .. " ms=" .. tostring(tnow - e.t0))
    e.ph = PH.RECOVERY
    e.t0 = tnow
    local f = z:getForwardDirection()
    e.fx, e.fy = f:getX(), f:getY()
    z:setVariable(W.VAR_PHASE, PH.RECOVERY)
    local reporter = getSpecificPlayer(0) or getPlayer()
    W.sendClaim(reporter, "Arrive", { ["zid"] = e.zid, ["seq"] = e.seq, ["d"] = string.format("%.1f", d) }, z)
end

-- 돌진 중 바닐라가 넘기(climbfence)를 걸었다 (소유 클라): 넘으려는 울타리 면을 충돌로 보고한다.
-- 면 방향: 돌진 방향과 가까운 순서로 4방향을 보며 그 쪽에 넘을 수 있는 오브젝트(getHoppableTo)가 있는 것.
local function climbCrash(e)
    if e.crashSent then return end
    e.crashSent = true
    local z = e.z
    local sq = z:getCurrentSquare()
    local fx, fy = e.fx or e.dx or 0, e.fy or e.dy or 0
    local order = {
        { "N", -fy, IsoDirections.N }, { "S", fy, IsoDirections.S },
        { "E", fx, IsoDirections.E },  { "W", -fx, IsoDirections.W },
    }
    table.sort(order, function(a, b) return a[2] > b[2] end)
    local dir = nil
    if sq then
        for _, o in ipairs(order) do
            local adj = sq:getAdjacentSquare(o[3])
            if adj and sq:getHoppableTo(adj) then dir = o[1]; break end
        end
    end
    if not dir then dir = impactDir(z, e) or order[1][1] end
    print(LOG .. "climb crash zid=" .. tostring(e.zid) .. " seq=" .. tostring(e.seq) .. " dir=" .. tostring(dir)
        .. " at " .. string.format("%.2f,%.2f", z:getX(), z:getY()))
    local reporter = getSpecificPlayer(0) or getPlayer()
    W.sendClaim(reporter, "Crash", {
        ["zid"] = e.zid, ["seq"] = e.seq,
        ["hx"] = sq and sq:getX() or math.floor(z:getX()),
        ["hy"] = sq and sq:getY() or math.floor(z:getY()),
        ["hz"] = sq and sq:getZ() or math.floor(z:getZ()),
        ["dir"] = dir, ["climb"] = "1",
    }, z)
end

local function knockDownNow(z, zid)
    if not z:isOnFloor() and not z:isKnockedDown() then
        z:setIgnoreMovement(false)
        z:setFallOnFront(false)
        z:knockDown(false)
        print(LOG .. "crash knockdown zid=" .. tostring(zid))
    end
end

local function crashFall(e)
    local z = e.z
    release(e, "crash")
    -- 넘기(climbfence) 중이면 ClimbOverFenceState.execute 가 매 틱 setKnockedDown(false) 로 덮고,
    -- climbfence 애니에는 넘어짐 전이가 없다(staggerback 으로만 가서 일어남). 그래서 넘기를 끝내
    -- (ClimbFenceFinished -> climbfence/to_idle.xml) idle 로 돌린 뒤 다음 틱에 넘어뜨린다.
    -- idle 에서는 높은 담장 충돌과 같은 falldown(idle/to_falldown.xml)이 나온다.
    if W.normState(z:getCurrentActionContextStateName()) == "climbfence" then
        z:setVariable("ClimbFenceFinished", true)
        _pendingKnock[z] = { zid = e.zid, t = getTimestampMs() }
        print(LOG .. "crash knockdown deferred (climbfence) zid=" .. tostring(e.zid))
        return
    end
    -- 정면 충돌이므로 뒤로 넘어진다 (원본 PZM_onCrashRecoveryEnter)
    knockDownNow(z, e.zid)
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
    local newSeq = tonumber(args["seq"])
    local changed = e.ph ~= ph or e.seq ~= newSeq
    if changed then stopVocal(e) end
    e.z, e.zid, e.ph = z, zid, ph
    e.seq = newSeq
    e.dx, e.dy = tonumber(args["dx"]), tonumber(args["dy"])
    e.tid = tonumber(args["tid"])
    e.t0 = getTimestampMs()
    e.fx, e.fy = nil, nil

    _watch[k] = nil
    print(LOG .. "phase zid=" .. tostring(zid) .. " seq=" .. tostring(e.seq) .. " ph=" .. tostring(ph)
        .. " owner=" .. tostring(isOwner(z))
        .. " state=" .. tostring(z:getCurrentActionContextStateName())
        .. " ai=" .. tostring(z:getCurrentStateName()))

    if ph == PH.CRASH then
        clearAnim(z)
        if isOwner(z) then crashFall(e) end
        return
    end

    if ph == PH.WARN then
        if changed then startWarnVocal(e) end
        z:setVariable(W.VAR_PROGRESS, 0)
    end

    z:setVariable(W.VAR_PHASE, ph)
    if ph == PH.SPRINT then
        e.hitLocal = {}
        e.crashSent = false
        e.arriveSent = false
        e.sx, e.sy = z:getX(), z:getY()
        e.lx, e.ly, e.lastLog = z:getX(), z:getY(), e.t0
        -- 돌진 방향: 이 클라에서 본 대상 쪽으로 한 번 잡는다. 대상이 없으면 서버 방향 (원본 PZM_captureSprintFacing)
        if isOwner(z) then
            local t = validTarget(z)
            if t then
                e.fx, e.fy = t:getX() - z:getX(), t:getY() - z:getY()
            else
                e.fx, e.fy = e.dx, e.dy
            end
            faceDir(z, e.fx, e.fy)
        end
    elseif ph == PH.RECOVERY then
        local f = z:getForwardDirection()
        e.fx, e.fy = f:getX(), f:getY()   -- 들어올 때 방향 유지 (LOCK_ON_ENTER)
    end
end

-- 서버 MP 수신
Events.OnServerCommand.Add(function(module, command, args)
    if module ~= W.NET then return end
    if command == "Phase" then
        W.clientHandler(args, nil)
    elseif command == "Fall" then
        -- 다른 플레이어가 맞음: 이 클라에 보이는 그 플레이어도 같은 클립으로 넘어지게 변수를 켠다
        local pid = tonumber(args and args["pid"])
        local p = pid and getPlayerByOnlineID and getPlayerByOnlineID(pid)
        if p and not p:isLocalPlayer() then
            markFall(p)
            print(LOG .. "remote fall player=" .. tostring(p:getUsername()))
        end
    end
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
            if e.muteVanilla then muteVanillaVocal(z) end
            local owner = isOwner(z)
            local policy = nil
            if owner then
                local state = W.normState(z:getCurrentActionContextStateName())
                local table_ = W.HOLD_STATES[e.ph]
                policy = table_ and table_[state or ""] or nil
                if policy ~= e.policy then
                    print(LOG .. "policy zid=" .. tostring(e.zid) .. " ph=" .. tostring(e.ph)
                        .. " state=" .. tostring(state) .. " -> " .. tostring(policy or "yield"))
                    e.policy = policy
                end
                if policy == "hold" then
                    hold(e)
                    if e.ph == PH.WARN then
                        local t = warnTarget(e)
                        if t then faceDir(z, t:getX() - z:getX(), t:getY() - z:getY()) end
                    elseif e.ph == PH.RECOVERY then
                        faceDir(z, e.fx, e.fy)
                    end
                elseif policy == "crash" then
                    -- 넘기를 막지 않고(손을 떼고) 울타리 충돌로 보고한다. 서버가 crash 를 보내면 넘기를 끝내고
                    -- 넘어진다(crashFall).
                    if e.ph == PH.SPRINT then climbCrash(e) end
                    release(e, "climb crash")
                elseif policy == "suppress" then
                    -- 돌진 중 몸 충돌로 bumped 에 들어감: 바닐라 상태로 돌려 놓고 bumped 를 바로 끝낸다
                    release(e, "bumped")
                    z:setBumpDone(true)
                    z:reportEvent("ActiveAnimFinishing")
                else
                    release(e, "yield " .. tostring(state))
                end
            elseif e.held then
                e.held = false   -- 소유권이 넘어가면 새 소유 클라가 고정한다
            end
            -- 돌진 방향은 고정 여부와 상관없이 다시 건다 (원본도 sprint 방향은 항상 재적용)
            if owner and e.ph == PH.SPRINT then faceDir(z, e.fx, e.fy) end
            if e.ph == PH.WARN then
                local pr = (tnow - e.t0) / W.WARN_MS
                if pr > 1 then pr = 1 elseif pr < 0 then pr = 0 end
                z:setVariable(W.VAR_PROGRESS, pr * W.WARN_CLIP_END)   -- 퓨커 클립의 젖히기 구간만
            end
            -- 단계 변수는 다른 코드나 좀비 재로드로 지워질 수 있어 계속 세운다
            if z:getVariableString(W.VAR_PHASE) ~= e.ph then
                z:setVariable(W.VAR_PHASE, e.ph)
            end
            if e.ph == PH.SPRINT then
                if owner and policy == "hold" then checkCrash(e, tnow) end
                if owner and not e.crashSent then checkArrive(e, tnow) end
                if owner and tnow - e.lastLog >= SPRINT_LOG_MS then
                    local dx, dy = z:getX() - e.lx, z:getY() - e.ly
                    local tx, ty = z:getX() - (e.sx or e.lx), z:getY() - (e.sy or e.ly)
                    print(LOG .. "sprint progress zid=" .. tostring(e.zid)
                        .. " moved=" .. string.format("%.2f", math.sqrt(dx * dx + dy * dy))
                        .. " total=" .. string.format("%.2f", math.sqrt(tx * tx + ty * ty))
                        .. " state=" .. tostring(z:getCurrentActionContextStateName())
                        .. " ai=" .. tostring(z:getCurrentStateName()))
                    e.lx, e.ly, e.lastLog = z:getX(), z:getY(), tnow
                end
            end
        end
    end

    -- 넘기를 끝낸 슬래머 넘어뜨리기 (crashFall 참고)
    for z, p in pairs(_pendingKnock) do
        local st = z and not z:isDead() and W.normState(z:getCurrentActionContextStateName())
        if not st then
            _pendingKnock[z] = nil
        elseif st ~= "climbfence" then
            _pendingKnock[z] = nil
            knockDownNow(z, p.zid)
        elseif tnow - p.t > KNOCK_WAIT_MS then
            _pendingKnock[z] = nil
            print(LOG .. "crash knockdown failed: still climbfence zid=" .. tostring(p.zid))
        end
    end

    -- 공격 종료 처리 뒤 idle 로 떨어진 슬래머 다시 쫓기 (resumeVanilla attack 참고)
    for z, t0 in pairs(_pendingChase) do
        if not z or z:isDead() or tnow - t0 > CHASE_WAIT_MS then
            _pendingChase[z] = nil
        elseif W.normState(z:getCurrentActionContextStateName()) == "idle" then
            _pendingChase[z] = nil
            local t = validTarget(z)
            if t then
                z:pathToCharacter(t)
                z:changeState(WalkTowardState.instance())
                print(LOG .. "chase resumed zid=" .. tostring(z:getOnlineID()) .. " after attack end")
            end
        end
    end

    -- 넘어짐 변수 정리: bumped 를 벗어났으면(일어나기 시작) 끈다
    for p, t0 in pairs(_fallVar) do
        local age = tnow - t0
        local st = p and W.normState(p:getCurrentActionContextStateName())
        if not p or age > FALL_VAR_MAX_MS or (age > FALL_VAR_MIN_MS and st ~= "bumped") then
            if p then
                p:clearVariable(W.VAR_PLAYER_FALL)
                print(LOG .. "fall var cleared player=" .. tostring(p:getUsername()) .. " state=" .. tostring(st)
                    .. " age=" .. tostring(age))
            end
            _fallVar[p] = nil
        end
    end

    -- 돌진이 끝난 뒤 감시 (소유 클라): 애니메이션은 climbfence/climbwindow 인데 AI 가 짝이 아니면
    -- 그 자세로 굳으므로 짝 상태로 맞춘다. 그 밖엔 상태만 기록한다(멀뚱히 서 있는 원인 추적용).
    for k, w in pairs(_watch) do
        local z = w.z
        if not z or z:isDead() or tnow > w.untilMs or not isOwner(z) then
            _watch[k] = nil
        else
            local raw = z:getCurrentActionContextStateName()
            local name = W.normState(raw)
            if RESYNC_STATES[name or ""] then
                local want = z:tryGetAIState(raw)
                if want and z:getCurrentState() ~= want then
                    print(LOG .. "resync zid=" .. tostring(w.zid) .. " anim=" .. tostring(raw)
                        .. " ai=" .. tostring(z:getCurrentStateName()) .. " -> " .. tostring(raw))
                    z:changeState(want)
                end
            end
            if tnow - w.lastLog >= WATCH_LOG_MS then
                w.lastLog = tnow
                local t = z:getTarget()
                print(LOG .. "after zid=" .. tostring(w.zid) .. " anim=" .. tostring(raw)
                    .. " ai=" .. tostring(z:getCurrentStateName())
                    .. " target=" .. tostring(t and instanceof(t, "IsoPlayer") and t:getUsername() or t)
                    .. " moving=" .. tostring(z:isMoving())
                    .. " at " .. string.format("%.2f,%.2f", z:getX(), z:getY()))
            end
        end
    end
end)

Events.OnCharacterCollide.Add(onCollide)

Events.OnZombieDead.Add(function(zombie)
    for k, e in pairs(_act) do
        if e.z == zombie then _act[k] = nil end
    end
    for k, w in pairs(_watch) do
        if w.z == zombie then _watch[k] = nil end
    end
end)
