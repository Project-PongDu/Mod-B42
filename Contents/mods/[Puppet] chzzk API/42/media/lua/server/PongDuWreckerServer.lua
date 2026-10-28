-- PongDuWreckerServer: 레커 돌진의 단계 결정·피해·장애물 파괴 (서버, SP 겸용).
-- 설계는 shared/PongDuWrecker.lua 머리 주석 참고.
--
-- [흐름]
--   2초마다 셀 좀비 목록에서 레커(modData PuppetMutant == "wrecker")를 모으고(물지 않게 setNoTeeth),
--   0.1초마다 레커별 단계를 진행한다.
--     none     : 쿨다운이 끝났고 대상 플레이어가 0~5칸, 같은 층, 사이가 트여 있고, 차에 타지 않았고
--                레커가 고정 가능한 애니메이션 상태(W.START_STATES)면 warn
--     warn     : 1.5초. 클라가 대상을 계속 바라본다. 끝나면 sprint (방향은 이때 대상 쪽으로 한 번 잡는다)
--     sprint   : W.CHARGE_DISTANCE 칸을 갔거나 4초가 지나면 recovery
--                피격자 클라 Hit 보고 -> 그 플레이어에게 피해. 돌진은 계속된다(여러 명 관통)
--                소유 클라 Crash 보고(부딪힌 칸 + 방향) -> 그 면의 장애물 파괴 + crash(레커 넘어짐)
--     recovery : 0.833초 뒤 none (돌진 끝 직후 늦게 도착한 Hit 도 이 단계까지 받는다)
--     crash    : 1틱 뒤 none (넘어짐 이후는 바닐라 넉다운이 처리)
--   취소 (원본 PZM_canContinue / 상태 정책과 같음): 단계 중 레커가 넘어졌거나, 예고 중 대상이 사라졌거나,
--   레커 애니메이션 상태가 그 단계 표(W.HOLD_STATES)에 없으면(울타리 넘기 등) none 으로 끊고
--   W.CANCEL_RETRY_MS 뒤 다시 시도한다.
--
-- [보고 검증] seq(돌진마다 증가)가 다르면 지난 돌진의 늦은 보고로 보고 버린다.
--   Hit 은 보낸 본인에게만 피해를 준다(다른 플레이어를 지정할 수 없다).
--   Crash 는 보낸 플레이어가 레커 40칸 안일 때만 받는다.

if isClient() then return end

require "PongDuWrecker"
require "PongDuBody"
require "PongDuClock"

local W  = PongDuWrecker
local PH = W.PH
local LOG = "[PongDu][WreckerServer] "

local SCAN_MS        = 2000
local TICK_MS        = 100
local SPAWN_GRACE_MS = 2000    -- 처음 발견한 레커는 이만큼 기다린 뒤 돌진 후보
local CLAIM_RANGE    = 40      -- Crash 보고자와 레커의 최대 거리 (칸)
local IMPACT_RANGE   = 2       -- Crash 보고 칸과 서버 레커 위치의 최대 차이 (칸)
local THUMP_BIG      = 30000   -- IsoObject:Thump 이벤트 수 (short 범위 안)
local MAX_DESTROY_PASSES = 32  -- 한 면에 겹친 장애물(바리케이드+문 등)을 차례로 벗기는 최대 횟수


local _st        = {}   -- [zombie] = { phase, seq, untilMs, cooldownUntil, dx, dy, sx, sy, hit }
local _byZid     = {}   -- [onlineID] = zombie (MP 보고 매칭용)
local _seq       = 0
local _lastScan  = 0
local _lastTick  = 0

local function now() return PongDuClock.now() end

local function zidOf(z) return z:getOnlineID() end

local function norm(dx, dy)
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.0001 then return nil, nil end
    return dx / len, dy / len
end

local function send(z, st, phase, reason)
    st.phase = phase
    local t = st.target
    W.sendPhase({
        ["zid"] = zidOf(z),
        ["ph"]  = phase,
        ["seq"] = st.seq,
        ["dx"]  = st.dx or 0,
        ["dy"]  = st.dy or 0,
        ["tid"] = t and t:getOnlineID() or -1,   -- 예고 중 바라볼 대상 (원본 TRACK_TARGET)
    }, z)
    print(LOG .. "phase zid=" .. tostring(zidOf(z)) .. " seq=" .. tostring(st.seq)
        .. " -> " .. phase .. " reason=" .. tostring(reason)
        .. " at " .. string.format("%.1f,%.1f", z:getX(), z:getY()))
end

local function isDown(z)
    return z:isOnFloor() or z:isKnockedDown()
end

-- 돌진 대상: 좀비가 노리는 플레이어. 같은 층, 거리 범위, 사이가 트여 있어야 한다.
local function chargeTarget(z)
    local t = z:getTarget()
    if not t or not instanceof(t, "IsoPlayer") or t:isDead() then return nil end
    local zz = math.floor(z:getZ())
    if math.floor(t:getZ()) ~= zz then return nil end
    local dx, dy = t:getX() - z:getX(), t:getY() - z:getY()
    local d = math.sqrt(dx * dx + dy * dy)
    if d < W.TRIGGER_MIN or d > W.TRIGGER_MAX then return nil end
    if t:getVehicle() then return nil end
    -- lineClearCollide 는 막혀 있으면 true (LosUtil.java:191)
    if LosUtil.lineClearCollide(math.floor(z:getX()), math.floor(z:getY()), zz,
                                math.floor(t:getX()), math.floor(t:getY()), zz, false) then
        return nil
    end
    return t
end

local function startWarn(z, st, t, tnow)
    _seq = _seq + 1
    st.seq = _seq
    st.dx, st.dy = norm(t:getX() - z:getX(), t:getY() - z:getY())
    st.untilMs = tnow + W.WARN_MS
    st.hit = {}
    st.target = t
    send(z, st, PH.WARN, "target=" .. tostring(t:getUsername()) .. " state=" .. tostring(W.stateOf(z)))
end

local function startSprint(z, st, tnow)
    local t = st.target
    if t and not t:isDead() then
        local dx, dy = norm(t:getX() - z:getX(), t:getY() - z:getY())
        if dx then st.dx, st.dy = dx, dy end
    end
    st.target = nil   -- 원본 PZM_onWarnExit: 돌진 중엔 대상을 따라 돌지 않는다
    st.sx, st.sy = z:getX(), z:getY()
    st.untilMs = tnow + W.SPRINT_MAX_MS
    st.cooldownUntil = tnow + W.COOLDOWN_MS
    send(z, st, PH.SPRINT, "warn done")
end

local function toPhase(z, st, phase, ms, tnow, reason)
    st.untilMs = tnow + ms
    send(z, st, phase, reason)
end

local function toNone(z, st, reason)
    st.untilMs = nil
    st.target = nil
    send(z, st, PH.NONE, reason)
end

-- 중간 취소: none + 원본 CANCEL_RETRY 만큼 뒤 재시도 (원본 PZM_onActionCancel)
local function cancel(z, st, tnow, reason)
    st.cooldownUntil = math.max(st.cooldownUntil or 0, tnow + W.CANCEL_RETRY_MS)
    toNone(z, st, "cancel " .. reason)
end

-- ── 피해 ─────────────────────────────────────────────────────────────────────
-- 전체 체력(100)에서 W.HIT_DAMAGE 만큼 깎는다: BodyDamage:ReduceGeneralHealth(20).
--   전체 체력 = 100 - Σ(부위 손실 × 부위 가중치)(BodyDamage.java:2458). 가중치가 손 0.1 ~ 목 0.7 이라
--   한 부위에 AddDamage(20) 을 하면 전체 체력은 2~14 만 깎인다(이전 구현의 "이상한 수치").
--   ReduceGeneralHealth 는 20/17 을 부위마다 가중치로 나눠 깎아 합이 정확히 20 이 된다(BodyDamage.java:1060).
-- 부상: 전 부위(머리·목·사타구니 포함)에서 무작위 1~2곳, 같은 부위 중복 가능. 부위마다 부상 1개 + 통증:
--   목·사타구니 -> 깊은 상처 (바닐라 차량 충돌도 이 두 곳의 골절을 깊은 상처로 바꾼다)
--   그 외       -> W.FRACTURE_CHANCE % 골절, 나머지 깊은 상처
--                  바닐라 골절이 꺼진 서버(SandboxVars.BoneFracture=false)면 항상 깊은 상처
--   깊은 상처는 이후 바닐라 출혈 피해가 따로 계속 들어간다(지혈 전까지).
-- 서버에서 바꾸고 전 부위 syncBodyPart.
local function applyHit(player)
    if player:isGodMod() or player:isInvincible() then
        print(LOG .. "hit skipped (god/invincible) player=" .. tostring(player:getUsername()))
        return
    end
    local bd = player:getBodyDamage()
    if not bd then return end
    local before = bd:getOverallBodyHealth()
    local fracChance = W.FRACTURE_CHANCE
    local allowFracture = SandboxVars.BoneFracture
    local first = BodyPartType.ToIndex(BodyPartType.Hand_L)
    local last = BodyPartType.ToIndex(BodyPartType.MAX)   -- 미포함

    bd:ReduceGeneralHealth(W.HIT_DAMAGE)

    local count = ZombRand(1, 3)   -- 1~2
    local log = {}
    for _ = 1, count do
        local bpt = BodyPartType.FromIndex(ZombRand(first, last))
        local part = bpt and bd:getBodyPart(bpt)
        if part then
            part:setAdditionalPain(60)
            local injury
            if bpt == BodyPartType.Neck or bpt == BodyPartType.Groin then
                injury = "deep"
            elseif allowFracture and ZombRand(100) < fracChance then
                injury = "fracture"
            else
                injury = "deep"
            end
            if injury == "fracture" then
                part:setFractureTime(ZombRand(30, 51))
            else
                part:generateDeepWound()
            end
            log[#log + 1] = tostring(BodyPartType.ToString(bpt)) .. ":" .. injury
        end
    end
    for i = first, last - 1 do
        PongDuBody.syncPart(bd:getBodyPart(BodyPartType.FromIndex(i)))
    end
    bd:calculateOverallHealth()
    print(LOG .. "hit applied player=" .. tostring(player:getUsername())
        .. " parts=" .. table.concat(log, ",") .. " health " .. string.format("%.1f -> %.1f", before, bd:getOverallBodyHealth()))
end

-- ── 장애물 파괴 ───────────────────────────────────────────────────────────────
-- 원본 레커(PZM_Wrecker_Impact)와 같은 방식. 소유 클라가 부딪힌 칸(hx,hy)과 방향(N/S/E/W,
-- isCollidedN 등 중 돌진 방향과 가장 맞는 것)을 보고하면 그 칸의 그 면을 부순다.
--   PZ 는 북·서 면 오브젝트를 자기 칸에, 남·동 면 오브젝트를 이웃 칸에 둔다 -> boundary 칸.
--   후보: 문·창문·창문 바리케이드·넘을 수 있는 울타리·면 위의 모든 오브젝트·건너편 칸의 고체 오브젝트.
--   휘는 울타리(BentFences, 바닐라 server/Items/BentFences.lua 에 등록된 철망·철제·나무 울타리 등)는
--   안 휜 것은 휘고(bendFence), 휜 것은 무너뜨린다(smashFence). 한 번 충돌에 한 단계만.
--   그 밖에는 getThumpableFor 가 고른 것(바리케이드가 있으면 바리케이드 먼저)을 부수고 다음 것을 다시 고른다.
--   문은 setHealth(0) + Thump, 나머지는 Thump(30000).
-- BentFences 의 휘기·무너뜨리기는 자체적으로 transmitUpdatedSprite/transmitRemoveItemFromSquare 한다.
local DIRS = {
    N = { dx = 0,  dy = -1, north = true,  iso = IsoDirections.N, edge = GridSquareEdgeFacingDirection.NORTH_SOUTH },
    S = { dx = 0,  dy = 1,  north = true,  iso = IsoDirections.S, edge = GridSquareEdgeFacingDirection.NORTH_SOUTH },
    E = { dx = 1,  dy = 0,  north = false, iso = IsoDirections.E, edge = GridSquareEdgeFacingDirection.EAST_WEST },
    W = { dx = -1, dy = 0,  north = false, iso = IsoDirections.W, edge = GridSquareEdgeFacingDirection.EAST_WEST },
}

local function spriteOf(o)
    local spr = o and o:getSprite()
    return spr and spr:getName() or tostring(o and o:getObjectName())
end

local function onFace(o, north)
    local pr = o:getProperties()
    if not pr then return false end
    if north then
        return pr:has(IsoFlagType.collideN) or pr:has(IsoFlagType.HoppableN) or pr:has(IsoFlagType.TallHoppableN)
    end
    return pr:has(IsoFlagType.collideW) or pr:has(IsoFlagType.HoppableW) or pr:has(IsoFlagType.TallHoppableW)
end

local function solidTile(o)
    local pr = o:getProperties()
    if not pr then return false end
    return pr:has(IsoFlagType.solid) or pr:has(IsoFlagType.solidtrans) or o:isMovedThumpable()
end

local function collect(face)
    local list, seen = {}, {}
    local function add(o)
        if o and not seen[o] then
            seen[o] = true
            list[#list + 1] = o
        end
    end
    local sq, op, bd, north = face.sq, face.op, face.bd, face.dir.north
    add(sq:getDoorTo(op))
    add(sq:getWindowTo(op))
    add(sq:getWindowThumpableTo(op))
    add(sq:getHoppableThumpableTo(op))
    add(sq:getHoppableTo(op))
    add(bd:getThumpable(north))
    add(bd:getThumpableWall(north))
    add(bd:getHoppableWall(north))
    local objs = bd:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if onFace(o, north) then add(o) end
    end
    objs = op:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if solidTile(o) then add(o) end
    end
    return list
end

-- 이번 패스에 부술 것. 반환: 대상, 후보 목록
local function topTarget(face, z)
    local bf = BentFences.getInstance()
    local cands = collect(face)
    for _, c in ipairs(cands) do
        if c:getObjectIndex() ~= -1 then
            if bf:isBentObject(c) or bf:isUnbentObject(c, face.dir.edge) then
                return c, cands
            end
            local t = c:getThumpableFor(z)
            if t then return t, cands end
        end
    end
    return nil, cands
end

local function destroyOne(t, z, dir)
    local bf = BentFences.getInstance()
    if bf:isBentObject(t) then          -- 반쯤 휜 것은 두 조건 모두 참이라 먼저 본다
        bf:smashFence(t, dir.iso)
        return "smash-fence"
    end
    if bf:isUnbentObject(t, dir.edge) then
        bf:bendFence(t, dir.iso)
        return "bend-fence"
    end
    if instanceof(t, "IsoDoor") then
        t:setHealth(0)
        t:Thump(z, 1)
        return "door"
    end
    t:Thump(z, THUMP_BIG)
    return "thump"
end

-- 반환: 부순 수
local function breakObstacles(z, hx, hy, dirName)
    local dir = DIRS[dirName or ""]
    local fz = math.floor(z:getZ())
    if not dir then
        print(LOG .. "break skipped: no wall face dir=" .. tostring(dirName) .. " (vehicle or corner)")
        return 0
    end
    local cell = getCell()
    local sq = cell:getGridSquare(hx, hy, fz)
    local op = cell:getGridSquare(hx + dir.dx, hy + dir.dy, fz)
    if not sq or not op then
        print(LOG .. "break skipped: square not loaded at " .. tostring(hx) .. "," .. tostring(hy) .. " dir=" .. dirName)
        return 0
    end
    local face = { sq = sq, op = op, bd = (dirName == "S" or dirName == "E") and op or sq, dir = dir }

    local done = {}
    local broken = 0
    local firstCands = nil
    for _ = 1, MAX_DESTROY_PASSES do
        local t, cands = topTarget(face, z)
        if not firstCands then firstCands = cands end
        if not t then break end
        local spr = spriteOf(t)
        local ok, kind = pcall(destroyOne, t, z, dir)
        if not ok then
            print(LOG .. "break failed obj=" .. tostring(spr) .. " err=" .. tostring(kind))
            break
        end
        broken = broken + 1
        done[#done + 1] = tostring(kind) .. ":" .. tostring(spr)
        if kind == "bend-fence" or kind == "smash-fence" then break end   -- 울타리는 충돌 1번에 1단계
        local nt = topTarget(face, z)
        if nt == t then
            print(LOG .. "break no progress obj=" .. tostring(spr) .. " kind=" .. tostring(kind))
            break
        end
    end

    local names = {}
    for _, c in ipairs(firstCands or {}) do names[#names + 1] = spriteOf(c) end
    print(LOG .. "break at " .. hx .. "," .. hy .. "," .. fz .. " dir=" .. dirName
        .. " candidates=" .. #names .. " [" .. table.concat(names, ",") .. "]"
        .. " broken=" .. broken .. " [" .. table.concat(done, ",") .. "]")
    return broken
end

-- ── 보고 처리 ────────────────────────────────────────────────────────────────
W.serverHandler = function(command, player, args, zombieObj)
    args = args or {}
    local z = zombieObj
    if not z then
        local zid = tonumber(args["zid"])
        z = zid and _byZid[zid]
    end
    local st = z and _st[z]
    local who = player and player:getUsername() or "nil"
    if not st then
        print(LOG .. command .. " ignored: unknown wrecker zid=" .. tostring(args["zid"]) .. " from=" .. who)
        return
    end
    if tonumber(args["seq"]) ~= st.seq then
        print(LOG .. command .. " ignored: stale seq=" .. tostring(args["seq"]) .. " cur=" .. tostring(st.seq)
            .. " from=" .. who)
        return
    end
    local tnow = now()

    if command == "Hit" then
        if st.phase ~= PH.SPRINT and st.phase ~= PH.RECOVERY and st.phase ~= PH.CRASH then
            print(LOG .. "Hit ignored: phase=" .. tostring(st.phase) .. " from=" .. who)
            return
        end
        local key = player and player:getOnlineID() or who
        if st.hit[key] then return end
        st.hit[key] = true
        print(LOG .. "hit zid=" .. tostring(zidOf(z)) .. " seq=" .. tostring(st.seq) .. " victim=" .. who
            .. " phase=" .. tostring(st.phase))
        if player then applyHit(player) end
    elseif command == "Crash" then
        if st.phase ~= PH.SPRINT then
            print(LOG .. "Crash ignored: phase=" .. tostring(st.phase) .. " from=" .. who)
            return
        end
        if player and player:DistTo(z) > CLAIM_RANGE then
            print(LOG .. "Crash ignored: reporter too far from=" .. who)
            return
        end
        local hx, hy = tonumber(args["hx"]), tonumber(args["hy"])
        if hx and hy and math.abs(hx - z:getX()) <= IMPACT_RANGE and math.abs(hy - z:getY()) <= IMPACT_RANGE then
            breakObstacles(z, hx, hy, args["dir"])
        else
            print(LOG .. "break skipped: impact square " .. tostring(hx) .. "," .. tostring(hy)
                .. " too far from wrecker " .. string.format("%.1f,%.1f", z:getX(), z:getY()))
        end
        toPhase(z, st, PH.CRASH, W.CRASH_MS, tnow, "crash " .. who)
    else
        print(LOG .. "unknown command " .. tostring(command) .. " from=" .. who)
    end
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= W.NET then return end
    W.serverHandler(command, player, args, nil)
end)

-- ── 스캔·단계 진행 ───────────────────────────────────────────────────────────
local function scan(tnow)
    local cell = getCell()
    if not cell then return end
    local zeds = cell:getZombieList()
    if not zeds then return end
    local seen = {}
    local byZid = {}
    for i = 0, zeds:size() - 1 do
        local z = zeds:get(i)
        if z and not z:isDead() and W.isWrecker(z) then
            seen[z] = true
            byZid[zidOf(z)] = z
            if not z:isNoTeeth() then z:setNoTeeth(true) end   -- 서버가 직접 굴리는 좀비용 (클라는 mutantspawn)
            if not _st[z] then
                _st[z] = { phase = PH.NONE, seq = 0, cooldownUntil = tnow + SPAWN_GRACE_MS, hit = {} }
                print(LOG .. "tracking wrecker zid=" .. tostring(zidOf(z)))
            end
        end
    end
    for z, _ in pairs(_st) do
        if not seen[z] then
            _st[z] = nil
            print(LOG .. "untracked wrecker zid=" .. tostring(zidOf(z)) .. " (dead or unloaded)")
        end
    end
    _byZid = byZid
end

local function step(z, st, tnow)
    local ph = st.phase
    if ph == PH.NONE then
        if tnow < st.cooldownUntil or isDown(z) or z:isCrawling() then return end
        local t = chargeTarget(z)
        if not t then return end
        -- 울타리 넘기·피격 경직 등 바닐라 상태 중엔 시작하지 않는다 (그 상태를 끊으면 굳는다)
        local state = W.stateOf(z)
        if not W.START_STATES[state or ""] then
            if st.blockedState ~= state then
                st.blockedState = state
                print(LOG .. "charge waits zid=" .. tostring(zidOf(z)) .. " state=" .. tostring(state))
            end
            return
        end
        st.blockedState = nil
        startWarn(z, st, t, tnow)
        return
    end

    if ph == PH.CRASH then
        if tnow >= st.untilMs then toNone(z, st, "crash done") end
        return
    end

    if isDown(z) then
        cancel(z, st, tnow, "down")
        return
    end
    if ph == PH.WARN then
        local t = st.target
        if not t or t:isDead() or not t:getCurrentSquare() then
            cancel(z, st, tnow, "target lost")
            return
        end
    end
    -- 단계 표에 없는 애니메이션 상태(울타리 넘기 등)면 취소하고 바닐라에 맡긴다.
    -- 서버는 표에 있으면(hold·suppress 모두) 계속 간다 (원본 PZM_resolveAnimationStatePolicy).
    local state = W.stateOf(z)
    local tbl = W.HOLD_STATES[ph]
    if tbl and not tbl[state or ""] then
        cancel(z, st, tnow, "state " .. tostring(state))
        return
    end

    if ph == PH.WARN then
        if tnow >= st.untilMs then startSprint(z, st, tnow) end
    elseif ph == PH.SPRINT then
        local dx, dy = z:getX() - st.sx, z:getY() - st.sy
        local traveled = math.sqrt(dx * dx + dy * dy)
        if traveled >= W.CHARGE_DISTANCE then
            toPhase(z, st, PH.RECOVERY, W.RECOVERY_MS, tnow, "distance " .. string.format("%.1f", traveled))
        elseif tnow >= st.untilMs then
            toPhase(z, st, PH.RECOVERY, W.RECOVERY_MS, tnow, "timeout traveled=" .. string.format("%.1f", traveled))
        end
    elseif ph == PH.RECOVERY then
        if tnow >= st.untilMs then toNone(z, st, "recovery done") end
    end
end

Events.OnTick.Add(function()
    local tnow = now()
    if tnow - _lastScan >= SCAN_MS then
        _lastScan = tnow
        scan(tnow)
    end
    if tnow - _lastTick < TICK_MS then return end
    _lastTick = tnow
    for z, st in pairs(_st) do
        if z:isDead() then
            _st[z] = nil
        else
            step(z, st, tnow)
        end
    end
end)
