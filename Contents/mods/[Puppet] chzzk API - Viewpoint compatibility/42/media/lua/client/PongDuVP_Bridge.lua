-- ═══════════════════════════════════════════════════════════════════════════
--  [PongDu] Viewpoint 호환 브리지 (t3chzzkDonationB42_ViewpointComp)
--
--  퐁듀 본체는 1·3인칭(Viewpoint 3D 시점)에서 2D 연출(예광탄 선, 가스 퍼프)을 그리지 않고
--  전역 훅 PongDuVPHook 으로 넘긴다. 이 파일이 그 훅을 채워, 설치된 Viewpoint 애드온의
--  공개 Lua API 로 3D 연출을 대신 그린다. 애드온이 없으면 해당 연출만 조용히 빠진다.
--
--  예광탄 -> Viewpoint True Ballistics (워크샵 3812864848, mod id ViewpointTrueBallistics)
--    VTB_npcVisual(launch): NPC 모드용 "클라 시각 전용" 탄 재생 API. 원점(ox,oy,ou[m])과
--    3D 방향(dirs[i].x/y/u)을 그대로 받으므로 하늘의 헬기에서 지면으로 내리꽂는 선이 된다.
--    데미지·유리 파손 없음(NpcBallistics.visual -> authoritative=false). 벽·지면에 닿으면
--    멈추고 탄흔/파편을 남긴다. 탄 진행은 VTB_npcTick() 을 누군가 매 틱 불러야 한다
--    (VTB 클라는 스스로 부르지 않는다 -- VTB_Client.lua 확인).
--    Viewpoint3DTracerFix 의 VFA_ShotQueue 는 수평(dx,dy)만 받아 위에서 쏘는 연출이 안 된다.
--
--  가스   -> Viewpoint - Advanced Throwables (워크샵 3813194971, mod id ViewpointAdvancedThrowables)
--    VAT_fx("smoke", x, y, z, 0, range, seconds, r, g, b): 연막탄 분출기(Fx.smoke). 3D 연기
--    파티클이 장면 조명·바람을 받고 깊이 판정된다. Viewpoint 가 그리고 있을 때만 생성되고
--    (Fx.drawing), Viewpoint 가 1초 넘게 안 그리면 분출기가 전부 지워진다(Fx.capture).
--    그래서 1·3인칭으로 돌아올 때마다 남은 구름을 다시 뿌린다.
-- ═══════════════════════════════════════════════════════════════════════════

PongDuVPHook = PongDuVPHook or {}
local H = PongDuVPHook

local LEVEL_M = 2.4494896          -- 층당 높이(m). Viewpoint/VTB 공통(BallisticsUnits.LEVEL_HEIGHT_M)

-- ── 예광탄 ──────────────────────────────────────────────────────────────────
local TRACER_V0    = 160           -- 탄속(m/s). 실탄보다 느리게 해 몇 프레임 보이게 한다
local TRACER_PAD   = 4             -- 목표 지점 너머로 더 날리는 거리(m). 지면/좀비에 닿아 멈추게
local TRACER_AIM_H = 1.1           -- 목표 좀비 바닥에서 조준 높이(m, 가슴께)
local TRACER_LIFE_PAD = 0.3        -- 탄 수명 여유(s)
local TICK_TAIL_MS = 500           -- 마지막 탄 수명 뒤로 VTB_npcTick 을 더 부르는 시간
-- 발사원 몸통 안에서 출발하면 첫 구간에서 자기 차량 상자에 맞아 바로 멈춘다(VTB 충돌은
-- 차량을 포함). 방향을 따라 이만큼 앞에서 출발시킨다.
local SRC_OFFSET   = { heli = 4.0, drone = 1.2, sniper = 0.6 }
-- 드론은 2D 에서 옅은 선(알파 0.14)이다. VTB 예광탄은 색·알파가 고정이라 대신 발 수를 줄인다.
local DRONE_EVERY  = 3

-- ── 가스 ────────────────────────────────────────────────────────────────────
local GAS_RING_SPACING = 10        -- 바깥 고리 분출기 간격(타일)
local GAS_RING_MAX     = 8
local GAS_RING_FRAC    = 0.55      -- 고리 반지름 = 구름 반경 x 이 값
local GAS_EMIT_R_MIN, GAS_EMIT_R_MAX = 2, 10   -- 분출기 range 인자 (VAT 퍼프 크기·확산 속도)
local GAS_TAIL_S       = 6         -- 분출기는 이만큼 일찍 끈다(남은 연기 파티클 수명 7~11초)
local GAS_MIN_LEFT_MS  = 4000      -- 남은 시간이 이보다 짧으면 새로 뿌리지 않는다
local GAS_REEMIT_GAP_MS = 700      -- 1·3인칭이 이만큼 끊겼다 돌아오면 다시 뿌린다(VAT 는 1초)

local _logged = {}
local function logOnce(key, msg)
    if _logged[key] then return end
    _logged[key] = true
    print("[PongDu][VP] " .. msg)
end

local function vtbReady()
    return TrueBallisticsJ ~= nil and VTB_npcVisual ~= nil and VTB_npcTick ~= nil
end

local function vatReady()
    return VATJ ~= nil and VAT_fx ~= nil
end

local function isPerspective()
    local v = PongDuViewpointView
    return v ~= nil and v.isPerspective()
end

-- ═══════════════════════════════════════════════════════════════════════════
--  예광탄
-- ═══════════════════════════════════════════════════════════════════════════
local _tickUntil   = 0
local _foreignTick = false
local _droneN      = 0
local _tracerCount = 0

-- src: "heli" | "drone" | "sniper", altM: 원점 바닥(oz)에서의 고도(m)
function H.tracer(src, ox, oy, oz, altM, tx, ty, tz)
    if not vtbReady() then
        logOnce("vtbMissing", "3D tracer skipped: Viewpoint True Ballistics (Java part) not running")
        return
    end
    if src == "drone" then
        _droneN = _droneN + 1
        if _droneN % DRONE_EVERY ~= 0 then return end
    end
    local ou = (tonumber(oz) or 0) * LEVEL_M + (tonumber(altM) or 0)
    local tu = (tonumber(tz) or 0) * LEVEL_M + TRACER_AIM_H
    local dx, dy, du = tx - ox, ty - oy, tu - ou
    local dist = math.sqrt(dx * dx + dy * dy + du * du)
    if dist < 0.5 then return end
    dx, dy, du = dx / dist, dy / dist, du / dist
    local off = math.min(SRC_OFFSET[src] or 0.6, dist * 0.5)
    local range = dist - off + TRACER_PAD
    local life = range / TRACER_V0 + TRACER_LIFE_PAD
    local launch = {
        ox = ox + dx * off, oy = oy + dy * off, ou = ou + du * off,
        v0 = TRACER_V0, g = 0, k = 0,
        range = range, life = life,
        dirs = { { x = dx, y = dy, u = du } },
    }
    local ok, err = pcall(VTB_npcVisual, launch)
    if not ok then
        logOnce("vtbErr", "VTB_npcVisual error: " .. tostring(err))
        return
    end
    _tracerCount = _tracerCount + 1
    if _tracerCount == 1 then
        print(string.format("[PongDu][VP] first 3D tracer src=%s origin=%.1f,%.1f,%.2fm dist=%.1fm",
            tostring(src), launch.ox, launch.oy, launch.ou, dist))
    end
    local untilMs = getTimestampMs() + life * 1000 + TICK_TAIL_MS
    if untilMs > _tickUntil then _tickUntil = untilMs end
end

-- VTB_npcTick 은 실시간 dt 로 모든 NPC 탄을 진행시키므로 두 모드가 같이 불러도 탄이 두 배로
-- 빨라지지 않는다. 다만 반환값(권위 탄 = NPC 모드가 쏜 실탄의 명중 목록)은 먼저 부른 쪽이
-- 가져간다. 권위 탄 명중이 한 번이라도 돌아오면 다른 NPC 모드(A-Life 패치 등)가 틱을 돌리는
-- 것이므로 그 뒤로는 부르지 않는다(그쪽 틱이 우리 시각 탄도 함께 진행시킨다).
local function tickTracers()
    if _foreignTick then return end
    if getTimestampMs() > _tickUntil then return end
    if not vtbReady() then return end
    local ok, res = pcall(VTB_npcTick)
    if not ok then
        logOnce("vtbTickErr", "VTB_npcTick error: " .. tostring(res))
        return
    end
    if res ~= nil then
        _foreignTick = true
        print("[PongDu][VP] another mod owns VTB NPC rounds; leaving VTB_npcTick to it")
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
--  가스
-- ═══════════════════════════════════════════════════════════════════════════
local _clouds      = {}     -- { x, y, z, r, t0, dur, cr, cg, cb, emitted }
local _lastPerspAt = nil

function H.gasSpawn(x, y, z, r, durMs, cr, cg, cb)
    _clouds[#_clouds + 1] = {
        x = x, y = y, z = z, r = r,
        t0 = getTimestampMs(), dur = durMs,
        cr = cr or 0.6, cg = cg or 0.6, cb = cb or 0.6,
        emitted = false,
    }
    if not vatReady() then
        logOnce("vatMissing", "3D gas skipped: Viewpoint - Advanced Throwables (Java part) not running")
    end
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function emitCloud(c, leftMs)
    local seconds = math.max(3, leftMs / 1000 - GAS_TAIL_S)
    local ringR = c.r * GAS_RING_FRAC
    local ring = clamp(math.floor(2 * math.pi * ringR / GAS_RING_SPACING), 0, GAS_RING_MAX)
    local emitR = clamp(c.r * (ring > 0 and 0.3 or 0.6), GAS_EMIT_R_MIN, GAS_EMIT_R_MAX)
    VAT_fx("smoke", c.x, c.y, c.z, 0, emitR, seconds, c.cr, c.cg, c.cb)
    for i = 1, ring do
        local a = (i - 1) * 2 * math.pi / ring
        VAT_fx("smoke", c.x + math.cos(a) * ringR, c.y + math.sin(a) * ringR, c.z,
            0, emitR, seconds, c.cr, c.cg, c.cb)
    end
    print(string.format("[PongDu][VP] 3D gas at %.0f,%.0f r=%.0f emitters=%d range=%.1f sec=%.0f",
        c.x, c.y, c.r, ring + 1, emitR, seconds))
end

local function tickGas()
    if #_clouds == 0 then return end
    local now = getTimestampMs()
    for i = #_clouds, 1, -1 do
        if now - _clouds[i].t0 >= _clouds[i].dur then table.remove(_clouds, i) end
    end
    if #_clouds == 0 then return end
    if not isPerspective() then return end
    if _lastPerspAt and now - _lastPerspAt > GAS_REEMIT_GAP_MS then
        for i = 1, #_clouds do _clouds[i].emitted = false end
        print("[PongDu][VP] back in viewpoint view after " .. tostring(now - _lastPerspAt) .. "ms, re-emitting gas")
    end
    _lastPerspAt = now
    if not vatReady() then return end
    for i = 1, #_clouds do
        local c = _clouds[i]
        if not c.emitted then
            c.emitted = true
            local left = c.dur - (now - c.t0)
            if left >= GAS_MIN_LEFT_MS then
                local ok, err = pcall(emitCloud, c, left)
                if not ok then logOnce("vatErr", "VAT_fx error: " .. tostring(err)) end
            end
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
local function onTick()
    tickTracers()
    tickGas()
end
Events.OnTick.Add(onTick)

local function onGameStart()
    _clouds, _lastPerspAt, _tickUntil, _foreignTick = {}, nil, 0, false
    print(string.format("[PongDu][VP] bridge ready: view=%s vtb=%s vat=%s",
        tostring(PongDuViewpointView ~= nil), tostring(vtbReady()), tostring(vatReady())))
end
Events.OnGameStart.Add(onGameStart)
