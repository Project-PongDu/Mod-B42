-- PongDuWreckerServer: 레커 돌진의 단계 결정·피해·장애물 파괴 (서버, SP 겸용).
-- 설계는 shared/PongDuWrecker.lua 머리 주석 참고.
--
-- [흐름]
--   2초마다 셀 좀비 목록에서 레커(modData PuppetMutant == "wrecker")를 모으고,
--   0.1초마다 레커별 단계를 진행한다.
--     none     : 쿨다운이 끝났고 대상 플레이어가 1.5~5칸, 같은 층, 사이가 트여 있으면 warn
--     warn     : 1.5초 뒤 sprint. 방향은 이때의 대상 위치로 한 번 다시 잡고 고정한다
--     sprint   : Wrecker_ChargeDistance 칸을 갔거나 4초가 지나면 recovery
--                피격자 클라 Hit 보고 -> 그 플레이어에게 피해. 돌진은 계속된다(여러 명 관통)
--                소유 클라 Crash 보고 -> 앞을 막은 문·창문·바리케이드 파괴 + crash(레커 넘어짐)
--     recovery : 1초 뒤 none (돌진 끝 직후 늦게 도착한 Hit 도 이 단계까지 받는다)
--     crash    : 0.3초 뒤 none (넘어짐 이후는 바닐라 넉다운이 처리)
--   단계 중 레커가 넘어지면(플레이어 밀치기 등) 바로 none 으로 끊는다.
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
local THUMP_BIG      = 30000   -- IsoObject:Thump 이벤트 수 (short 범위 안)


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
    W.sendPhase({
        ["zid"] = zidOf(z),
        ["ph"]  = phase,
        ["seq"] = st.seq,
        ["dx"]  = st.dx or 0,
        ["dy"]  = st.dy or 0,
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
    send(z, st, PH.WARN, "target=" .. tostring(t:getUsername()))
end

local function startSprint(z, st, tnow)
    local t = z:getTarget()
    if t and instanceof(t, "IsoPlayer") and not t:isDead() then
        local dx, dy = norm(t:getX() - z:getX(), t:getY() - z:getY())
        if dx then st.dx, st.dy = dx, dy end
    end
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
    send(z, st, PH.NONE, reason)
end

-- ── 피해 ─────────────────────────────────────────────────────────────────────
-- 전 부위(손~발, 머리·목·사타구니 포함)에서 무작위 1~2곳, 같은 부위가 두 번 뽑힐 수 있다.
-- 부위마다 피해 + 통증 + 부상 1개:
--   목·사타구니 -> 깊은 상처 (바닐라 차량 충돌도 이 두 곳의 골절을 깊은 상처로 바꾼다)
--   그 외       -> Wrecker_FractureChance % 골절, 나머지 깊은 상처
--                  바닐라 골절이 꺼진 서버(SandboxVars.BoneFracture=false)면 항상 깊은 상처
-- 서버에서 바꾸고 부위마다 syncBodyPart.
local function applyHit(player)
    if player:isGodMod() or player:isInvincible() then
        print(LOG .. "hit skipped (god/invincible) player=" .. tostring(player:getUsername()))
        return
    end
    local bd = player:getBodyDamage()
    if not bd then return end
    local dmg = SandboxVars.PongDu.Wrecker_HitDamage
    local fracChance = SandboxVars.PongDu.Wrecker_FractureChance
    local allowFracture = SandboxVars.BoneFracture
    local first = BodyPartType.ToIndex(BodyPartType.Hand_L)
    local last = BodyPartType.ToIndex(BodyPartType.MAX)   -- 미포함
    local count = ZombRand(1, 3)   -- 1~2
    local log = {}
    for _ = 1, count do
        local bpt = BodyPartType.FromIndex(ZombRand(first, last))
        local part = bpt and bd:getBodyPart(bpt)
        if part then
            part:AddDamage(dmg)
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
            PongDuBody.syncPart(part)
            log[#log + 1] = tostring(BodyPartType.ToString(bpt)) .. ":" .. injury
        end
    end
    print(LOG .. "hit applied player=" .. tostring(player:getUsername())
        .. " parts=" .. table.concat(log, ",") .. " dmg=" .. tostring(dmg))
end

-- ── 장애물 파괴 ───────────────────────────────────────────────────────────────
-- 돌진 방향으로 레커 칸과 다음 칸 사이의 모서리를 찾는다.
--   PZ 모서리 오브젝트: north=true 면 자기 칸의 북쪽 모서리, false 면 서쪽 모서리.
--   +x 이동: 다음 칸(x+1)의 서쪽 / -x: 현재 칸의 서쪽 / +y: 다음 칸(y+1)의 북쪽 / -y: 현재 칸의 북쪽.
local function blockingEdge(z, dx, dy)
    local x, y, fz = math.floor(z:getX()), math.floor(z:getY()), math.floor(z:getZ())
    if math.abs(dx) >= math.abs(dy) then
        if dx > 0 then return x + 1, y, fz, false end
        return x, y, fz, false
    end
    if dy > 0 then return x, y + 1, fz, true end
    return x, y, fz, true
end

local function breakObstacles(z, dx, dy)
    local ex, ey, ez, north = blockingEdge(z, dx, dy)
    local sq = getCell():getGridSquare(ex, ey, ez)
    if not sq then
        print(LOG .. "break: no square at " .. ex .. "," .. ey .. "," .. ez)
        return 0
    end
    local objs = sq:getObjects()
    local targets = {}
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if (instanceof(o, "IsoDoor") or instanceof(o, "IsoWindow") or instanceof(o, "IsoThumpable"))
            and o:getNorth() == north then
            targets[#targets + 1] = o
        end
    end
    local broken = 0
    for _, o in ipairs(targets) do
        local ok, err = pcall(function()
            if instanceof(o, "IsoDoor") then
                o:setHealth(0)
                o:Thump(z, 1)
            else
                o:Thump(z, THUMP_BIG)
            end
        end)
        if ok then
            broken = broken + 1
        else
            print(LOG .. "break failed obj=" .. tostring(o) .. " err=" .. tostring(err))
        end
    end
    print(LOG .. "break edge=" .. ex .. "," .. ey .. "," .. ez .. " north=" .. tostring(north)
        .. " candidates=" .. #targets .. " broken=" .. broken)
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
        if st.phase ~= PH.SPRINT and st.phase ~= PH.RECOVERY then
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
        if SandboxVars.PongDu.Wrecker_BreakObstacles then
            breakObstacles(z, st.dx or 0, st.dy or 0)
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
        if t then startWarn(z, st, t, tnow) end
        return
    end

    if isDown(z) and ph ~= PH.CRASH then
        toNone(z, st, "interrupted (down)")
        return
    end

    if ph == PH.WARN then
        if tnow >= st.untilMs then startSprint(z, st, tnow) end
    elseif ph == PH.SPRINT then
        local dx, dy = z:getX() - st.sx, z:getY() - st.sy
        local traveled = math.sqrt(dx * dx + dy * dy)
        if traveled >= SandboxVars.PongDu.Wrecker_ChargeDistance then
            toPhase(z, st, PH.RECOVERY, W.RECOVERY_MS, tnow, "distance " .. string.format("%.1f", traveled))
        elseif tnow >= st.untilMs then
            toPhase(z, st, PH.RECOVERY, W.RECOVERY_MS, tnow, "timeout traveled=" .. string.format("%.1f", traveled))
        end
    elseif ph == PH.RECOVERY or ph == PH.CRASH then
        if tnow >= st.untilMs then toNone(z, st, ph .. " done") end
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
