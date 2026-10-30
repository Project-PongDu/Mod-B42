-- PongDuSlammerServer: 슬래머 돌진의 단계 결정·피해·장애물 파괴 (서버, SP 겸용).
-- 설계는 shared/PongDuSlammer.lua 머리 주석 참고.
--
-- [흐름]
--   2초마다 셀 좀비 목록에서 슬래머(modData PuppetMutant == "slammer")를 모으고,
--   0.1초마다 슬래머별 단계를 진행한다.
--     none     : 쿨다운이 끝났고 대상 플레이어가 0~5칸, 같은 층, 사이가 트여 있고, 차에 타지 않았고
--                슬래머가 고정 가능한 애니메이션 상태(S.START_STATES)면 warn
--     warn     : 1.5초. 클라가 대상을 계속 바라본다. 끝나면 sprint (방향은 이때 대상 쪽으로 한 번 잡는다)
--     sprint   : 소유 클라 Arrive 보고(자기 쪽 위치로 S.CHARGE_DISTANCE 칸 도달)나 4초가 지나면 recovery.
--                서버 위치로도 재지만 소유 클라 패킷이 늦어 예비용이다(실측 18~26칸에서야 걸렸다)
--                피격자 클라 Hit 보고 -> 그 플레이어에게 피해. 돌진은 계속된다(여러 명 관통)
--                소유 클라 Crash 보고(부딪힌 칸 + 방향) -> 그 면의 장애물 파괴 + crash(슬래머 넘어짐)
--     recovery : 0.833초 뒤 none (돌진 끝 직후 늦게 도착한 Hit 도 이 단계까지 받는다)
--     crash    : 1틱 뒤 none (넘어짐 이후는 바닐라 넉다운이 처리)
--   취소 (원본 PZM_canContinue / 상태 정책과 같음): 단계 중 슬래머가 넘어졌거나, 예고 중 대상이 사라졌거나,
--   슬래머 애니메이션 상태가 그 단계 표(S.HOLD_STATES)에 없으면(울타리 넘기 등) none 으로 끊고
--   S.CANCEL_RETRY_MS 뒤 다시 시도한다.
--
-- [보고 검증] seq(돌진마다 증가)가 다르면 지난 돌진의 늦은 보고로 보고 버린다.
--   Hit 은 보낸 본인에게만 피해를 준다(다른 플레이어를 지정할 수 없다).
--   Crash 는 보낸 플레이어가 슬래머 40칸 안이고 부딪힌 칸이 슬래머와 같은 층일 때만 받는다
--   (원본 resolveClaimFace 와 같이 층만 본다. 서버 슬래머 위치는 늦게 따라와 가로 거리로 거르면
--   정상 충돌도 버려진다 -> 이전 'impact square too far' 로 파괴 0).
--   Arrive 는 sprint 중일 때만 받는다.

if isClient() then return end

require "PongDuSlammer"
require "PongDuBody"
require "PongDuClock"

local S  = PongDuSlammer
local PH = S.PH
local LOG = "[PongDu][SlammerServer] "

local SCAN_MS        = 2000
local TICK_MS        = 100
local SPAWN_GRACE_MS = 2000    -- 처음 발견한 슬래머는 이만큼 기다린 뒤 돌진 후보
local CLAIM_RANGE    = 40      -- Crash 보고자와 슬래머의 최대 거리 (칸)
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
    S.sendPhase({
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

-- 쓰러져 있는지: 서버는 소유 클라가 보낸 애니 상태(realState)로 판단한다.
-- 서버의 원격 좀비 isOnFloor 는 네트워크로 갱신되지 않는다 (NetworkZombieVariables.setBooleanVariables 는
-- isReanimatedPlayer 일 때만 setOnFloor). 강령술로 일어난 좀비는 서버 사본이 IsoDeadBody.reanimate 의
-- setOnFloor(true) 로 생겨 일어난 뒤에도 서버에선 계속 누운 것으로 남아, 돌진을 한 번도 시작하지 못했다.
local DOWN_STATES = { onground = true, falldown = true, getup = true, getdown = true,
                      fakedead = true, falling = true }
local function isDown(z)
    local st = S.stateOf(z)
    if st then return DOWN_STATES[st] == true end
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
    if d < S.TRIGGER_MIN or d > S.TRIGGER_MAX then return nil end
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
    st.untilMs = tnow + S.WARN_MS
    st.hit = {}
    st.target = t
    send(z, st, PH.WARN, "target=" .. tostring(t:getUsername()) .. " state=" .. tostring(S.stateOf(z)))
end

local function startSprint(z, st, tnow)
    local t = st.target
    if t and not t:isDead() then
        local dx, dy = norm(t:getX() - z:getX(), t:getY() - z:getY())
        if dx then st.dx, st.dy = dx, dy end
    end
    st.target = nil   -- 원본 PZM_onWarnExit: 돌진 중엔 대상을 따라 돌지 않는다
    st.sx, st.sy = z:getX(), z:getY()
    st.untilMs = tnow + S.SPRINT_MAX_MS
    st.cooldownUntil = tnow + S.COOLDOWN_MS
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
    st.cooldownUntil = math.max(st.cooldownUntil or 0, tnow + S.CANCEL_RETRY_MS)
    toNone(z, st, "cancel " .. reason)
end

-- ── 피해 ─────────────────────────────────────────────────────────────────────
-- 전체 체력(100)에서 S.HIT_DAMAGE 만큼 깎는다: BodyDamage:ReduceGeneralHealth(20).
--   전체 체력 = 100 - Σ(부위 손실 × 부위 가중치)(BodyDamage.java:2458). 가중치가 손 0.1 ~ 목 0.7 이라
--   한 부위에 AddDamage(20) 을 하면 전체 체력은 2~14 만 깎인다(이전 구현의 "이상한 수치").
--   ReduceGeneralHealth 는 20/17 을 부위마다 가중치로 나눠 깎아 합이 정확히 20 이 된다(BodyDamage.java:1060).
-- 부상: 전 부위(머리·목·사타구니 포함)에서 무작위 1~2곳, 같은 부위 중복 가능. 부위마다 부상 1개 + 통증:
--   목·사타구니 -> 깊은 상처 (바닐라 차량 충돌도 이 두 곳의 골절을 깊은 상처로 바꾼다)
--   그 외       -> S.FRACTURE_CHANCE % 골절, 나머지 깊은 상처
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
    local fracChance = S.FRACTURE_CHANCE
    local allowFracture = SandboxVars.BoneFracture
    local first = BodyPartType.ToIndex(BodyPartType.Hand_L)
    local last = BodyPartType.ToIndex(BodyPartType.MAX)   -- 미포함

    bd:ReduceGeneralHealth(S.HIT_DAMAGE)

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
--   부서지는 울타리(BrokenFences, 바닐라 server/Items/BrokenFences.lua: 낮은 검은 철제·흰 나무·철망·
--   나무 울타리, 높은 콘크리트·철망·철제·나무 담장 등) 중 위 두 경로에 안 걸리는 맵 기본 오브젝트는
--   destroyFence 로 부순다. [원본과 다름] 바닐라에선 걷는 좀비의 getThumpableFor 가 이걸 nil 로 줘서
--   (기어가는 좀비만 대상, IsoObject.java:6057) 원본 레커는 못 부쉈다. 차량 충돌·기는 좀비와 같은 함수라
--   부서진 스프라이트·잔해·옆 칸 손상·소리·전송까지 바닐라가 처리한다(BrokenFences.java:169).
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
            if BrokenFences.getInstance():isBreakableObject(c) then return c, cands end
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
    if not instanceof(t, "IsoThumpable") and BrokenFences.getInstance():isBreakableObject(t) then
        BrokenFences.getInstance():destroyFence(t, dir.iso)
        return "break-fence"
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
    local names = nil
    for _ = 1, MAX_DESTROY_PASSES do
        local t, cands = topTarget(face, z)
        if not firstCands then
            firstCands = cands
            names = {}
            for _, c in ipairs(cands) do names[#names + 1] = spriteOf(c) end   -- 부수기 전 이름
        end
        if not t then break end
        local spr = spriteOf(t)
        local ok, kind = pcall(destroyOne, t, z, dir)
        if not ok then
            print(LOG .. "break failed obj=" .. tostring(spr) .. " err=" .. tostring(kind))
            break
        end
        broken = broken + 1
        done[#done + 1] = tostring(kind) .. ":" .. tostring(spr)
        if kind == "bend-fence" or kind == "smash-fence" or kind == "break-fence" then break end   -- 울타리는 충돌 1번에 1단계
        local nt = topTarget(face, z)
        if nt == t then
            print(LOG .. "break no progress obj=" .. tostring(spr) .. " kind=" .. tostring(kind))
            break
        end
    end

    names = names or {}
    print(LOG .. "break at " .. hx .. "," .. hy .. "," .. fz .. " dir=" .. dirName
        .. " candidates=" .. #names .. " [" .. table.concat(names, ",") .. "]"
        .. " broken=" .. broken .. " [" .. table.concat(done, ",") .. "]")
    return broken
end

-- ── 보고 처리 ────────────────────────────────────────────────────────────────
S.serverHandler = function(command, player, args, zombieObj)
    args = args or {}
    local z = zombieObj
    if not z then
        local zid = tonumber(args["zid"])
        z = zid and _byZid[zid]
    end
    local st = z and _st[z]
    local who = player and player:getUsername() or "nil"
    if not st then
        print(LOG .. command .. " ignored: unknown slammer zid=" .. tostring(args["zid"]) .. " from=" .. who)
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
        if player then
            S.sendFall({ ["pid"] = player:getOnlineID() })
            applyHit(player)
        end
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
        local hz = tonumber(args["hz"]) or math.floor(z:getZ())
        local climb = args["climb"] == "1"
        local broken = 0
        if hx and hy and hz == math.floor(z:getZ()) then
            broken = breakObstacles(z, hx, hy, args["dir"])
        else
            print(LOG .. "break skipped: impact square " .. tostring(hx) .. "," .. tostring(hy) .. "," .. tostring(hz)
                .. " not on slammer level " .. string.format("%.1f,%.1f,%d", z:getX(), z:getY(), math.floor(z:getZ())))
        end
        -- 넘기에서 온 충돌도 부순 게 있든 없든 다른 충돌과 같이 crash (모든 충돌에 같은 넘어짐)
        toPhase(z, st, PH.CRASH, S.CRASH_MS, tnow, (climb and "climb-crash " or "crash ") .. who)
    elseif command == "Arrive" then
        if st.phase ~= PH.SPRINT then
            print(LOG .. "Arrive ignored: phase=" .. tostring(st.phase) .. " from=" .. who)
            return
        end
        local dx, dy = z:getX() - st.sx, z:getY() - st.sy
        toPhase(z, st, PH.RECOVERY, S.RECOVERY_MS, tnow, "distance owner=" .. tostring(args["d"])
            .. " server=" .. string.format("%.1f", math.sqrt(dx * dx + dy * dy)) .. " from=" .. who)
    else
        print(LOG .. "unknown command " .. tostring(command) .. " from=" .. who)
    end
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= S.NET then return end
    S.serverHandler(command, player, args, nil)
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
        if z and not z:isDead() and S.isSlammer(z) then
            seen[z] = true
            byZid[zidOf(z)] = z
            -- 고정 피부(회색): 서버 HumanVisual 에도 넣어야 서버가 만든 시체·저장본이 같은 피부다.
            -- 옷을 다시 입으면 이름이 지워지므로 스캔마다 확인한다 (같으면 아무것도 안 함).
            if PongDuMutantId.applyFixedSkin(z, S.KIND) then
                print(LOG .. "fixed skin set zid=" .. tostring(zidOf(z)) .. " skin=" .. tostring(z:getHumanVisual():getSkinTexture()))
            end
            if not _st[z] then
                _st[z] = { phase = PH.NONE, seq = 0, cooldownUntil = tnow + SPAWN_GRACE_MS, hit = {} }
                print(LOG .. "tracking slammer zid=" .. tostring(zidOf(z)) .. " state=" .. tostring(S.stateOf(z))
                    .. " onFloor=" .. tostring(z:isOnFloor()) .. " crawling=" .. tostring(z:isCrawling()))
            end
        end
    end
    for z, _ in pairs(_st) do
        if not seen[z] then
            _st[z] = nil
            print(LOG .. "untracked slammer zid=" .. tostring(zidOf(z)) .. " (dead or unloaded)")
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
        local state = S.stateOf(z)
        if not S.START_STATES[state or ""] then
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
    local state = S.stateOf(z)
    local tbl = S.HOLD_STATES[ph]
    if tbl and not tbl[state or ""] then
        cancel(z, st, tnow, "state " .. tostring(state))
        return
    end

    if ph == PH.WARN then
        if tnow >= st.untilMs then startSprint(z, st, tnow) end
    elseif ph == PH.SPRINT then
        local dx, dy = z:getX() - st.sx, z:getY() - st.sy
        local traveled = math.sqrt(dx * dx + dy * dy)
        if traveled >= S.CHARGE_DISTANCE then
            toPhase(z, st, PH.RECOVERY, S.RECOVERY_MS, tnow, "distance " .. string.format("%.1f", traveled))
        elseif tnow >= st.untilMs then
            toPhase(z, st, PH.RECOVERY, S.RECOVERY_MS, tnow, "timeout traveled=" .. string.format("%.1f", traveled))
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

-- ── 루팅용 바닐라 방독면 ────────────────────────────────────────────────────
-- 슬래머 방독면은 상체 1.1배 셰이더용 숨김 장식(PongDuSlammerGasMask)이라 루팅창에 안 보인다.
-- 죽을 때 바닐라 Base.Hat_GasMask 를 인벤토리에 넣고 표식(modData)을 단다. 청바지는 바닐라를 그대로 입으므로 손대지 않는다.
-- IsoZombie.onKilled (서버/SP): DoZombieInventory(입은 옷 -> 인벤토리) -> OnZombieDead -> DoDeath(시체로 이동).
-- MP 에선 서버 시체 인벤토리가 DeadZombiePacket 으로 클라에 간다.
local LOOT_MASK = "Base.Hat_GasMask"
local COSMETIC_MASK = "t3chzzkDonation.PongDuSlammerGasMask"
local LOOT_TAG = "PongDuSlammerLoot"

Events.OnZombieDead.Add(function(z)
    if not z or not S.isSlammer(z) then return end
    local inv = z:getInventory()
    if not inv then
        print(LOG .. "loot skipped (no inventory) zid=" .. tostring(zidOf(z)))
        return
    end
    local mask = inv:AddItem(LOOT_MASK)
    if mask then mask:getModData()[LOOT_TAG] = "mask" end
    print(LOG .. "loot added zid=" .. tostring(zidOf(z)) .. " mask=" .. tostring(mask ~= nil))
end)

-- ── 시체에서 방독면을 벗기는 연출 ─────────────────────────────────────────────
-- 바닐라는 시체 인벤토리에서 착용 아이템이 빠지면 ItemContainer.DoRemoveItem -> IsoDeadBody.checkClothing 으로
-- 착용 슬롯에서도 빼 다시 그린다. 루팅되는 건 바닐라 방독면이고 시체가 입은 건 장식이라,
-- 표식 달린 바닐라 방독면이 시체에서 나가면 같은 시체의 장식도 같이 뺀다.
-- ISTransferAction.transferItem 은 SP 에선 로컬, MP 에선 서버에서만 돈다 (ISInventoryTransferAction:perform).
-- MP 제거는 바닐라 루팅과 같은 DoRemoveItem + sendRemoveItemFromContainer 경로라 클라 시체도 같이 벗겨진다.
local function removeCosmeticMask(container)
    local items = container:getItems()
    for i = items:size() - 1, 0, -1 do
        local it = items:get(i)
        if it and it:getFullType() == COSMETIC_MASK then
            container:DoRemoveItem(it)
            if isServer() then sendRemoveItemFromContainer(container, it) end
            return true
        end
    end
    return false
end

if ISTransferAction and ISTransferAction.transferItem then
    local origTransferItem = ISTransferAction.transferItem
    ISTransferAction.transferItem = function(self, character, item, srcContainer, destContainer, dropSquare)
        local result = origTransferItem(self, character, item, srcContainer, destContainer, dropSquare)
        local body = srcContainer and srcContainer:getParent()
        if item and body and instanceof(body, "IsoDeadBody") then
            local md = item:getModData()
            if md[LOOT_TAG] == "mask" then
                md[LOOT_TAG] = nil
                local removed = removeCosmeticMask(srcContainer)
                print(LOG .. "corpse mask looted cosmeticRemoved=" .. tostring(removed)
                    .. " by=" .. tostring(character and character:getUsername()))
            end
        end
        return result
    end
    print(LOG .. "transfer hook installed")
else
    print(LOG .. "transfer hook skipped (ISTransferAction missing)")
end

-- ── MP: 클라가 알려 준 시체 방독면 루팅 ───────────────────────────────────────
-- MP 의 아이템 이동은 서버 자바(Transaction.updateItem)가 처리해 위 ISTransferAction 훅을 거치지 않는다.
-- 클라가 시체에서 바닐라 방독면을 옮긴 뒤 칸 좌표를 보내면(PongDuSlammerLootClient.lua),
-- 그 칸의 시체 중 장식 방독면은 있는데 표식 달린 바닐라 방독면이 더는 없는 시체의 장식을 뺀다.
local LOOT_NET = "PongDuSlammerLoot"

local function hasMarkedMask(container)
    local items = container:getItems()
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if it and it:getFullType() == LOOT_MASK and it:getModData()[LOOT_TAG] == "mask" then return true end
    end
    return false
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= LOOT_NET or command ~= "MaskLooted" then return end
    local who = player and player:getUsername() or "?"
    local x = tonumber(args and args["x"])
    local y = tonumber(args and args["y"])
    local zz = tonumber(args and args["z"])
    if not x or not y or not zz then
        print(LOG .. "MaskLooted ignored: bad args from=" .. who)
        return
    end
    if player and (math.abs(player:getX() - x) > 4 or math.abs(player:getY() - y) > 4) then
        print(LOG .. "MaskLooted ignored: reporter too far from=" .. who)
        return
    end
    local cell = getCell()
    local sq = cell and cell:getGridSquare(x, y, zz)
    if not sq then
        print(LOG .. "MaskLooted ignored: no square " .. x .. "," .. y .. "," .. zz .. " from=" .. who)
        return
    end
    local bodies = sq:getDeadBodys()
    local n, removed = 0, 0
    for i = 0, bodies:size() - 1 do
        local b = bodies:get(i)
        local c = b and b:getContainer()
        if c then
            n = n + 1
            if not hasMarkedMask(c) and removeCosmeticMask(c) then removed = removed + 1 end
        end
    end
    print(LOG .. "MaskLooted at " .. x .. "," .. y .. "," .. zz .. " bodies=" .. n .. " cosmeticRemoved=" .. removed
        .. " by=" .. who)
end)
