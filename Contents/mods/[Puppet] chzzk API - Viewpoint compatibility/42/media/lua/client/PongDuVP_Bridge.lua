-- ═══════════════════════════════════════════════════════════════════════════
--  [PongDu] Viewpoint 호환 브리지 (t3chzzkDonationB42_ViewpointComp)
--
--  퐁듀 본체는 1·3인칭(Viewpoint 3D 시점)에서 2D 연출(예광탄 선, 가스 퍼프)을 그리지 않고
--  전역 훅 PongDuVPHook 으로 넘긴다. 이 파일이 훅을 받아 Lua 전역 큐에 쌓고, 같은 모드의
--  자바 부분(42/media/java/client/PongDuVP.jar, 소스 42/src/pongduvp/Fx3D.java)이
--  Viewpoint 의 3D 렌더 패스 안에서 그린다. 자바 부분은 ZombieBuddy 가 불러온다.
--
--  가스  : 배그 연막탄처럼 짙은 색 연기 덩어리. 반경 r 원판을 퍼프 수십 장으로 채우고
--          중앙부터 바깥으로 퍼졌다가 효과 시간 + 5초 동안 걷힌다. 카메라가 구름 안이면
--          화면 전체를 구름 색으로 가린다.
--  예광탄: 기체(헬기·드론)/저격 원점에서 목표 좀비 가슴께로 날아가는 3D 선 + 총구·탄착 섬광.
--
--  큐는 자바가 Viewpoint 프레임마다 비운다. 아이소 시점이거나 자바 부분이 안 돌면 비워지지
--  않으므로 QUEUE_MAX 로 오래된 것부터 버린다. 시각은 getTimestampMs()(= 자바
--  System.currentTimeMillis)로 넘겨, 아이소에서 발동한 구름도 1·3인칭으로 오면 제 나이로 보인다.
-- ═══════════════════════════════════════════════════════════════════════════

PongDuVPHook = PongDuVPHook or {}
local H = PongDuVPHook

PongDuVP_GasQueue = PongDuVP_GasQueue or {}
PongDuVP_TracerQueue = PongDuVP_TracerQueue or {}

local LEVEL_M = 2.4494896          -- 층당 높이(m). Viewpoint 렌더 공간과 같은 값
local QUEUE_MAX = 64

-- ── 가스 ────────────────────────────────────────────────────────────────────
-- 본체 gasCloud.lua 의 SPREAD_CAP / FADE_CAP 과 같은 규칙(확산 = 시간의 25%, 소산 = 30%)
local GAS_SPREAD_CAP = 1500
local GAS_FADE_CAP   = 2000

-- ── 예광탄 ──────────────────────────────────────────────────────────────────
local TRACER_AIM_H = 1.1           -- 목표 좀비 바닥에서 조준 높이(m, 가슴께)
-- 기체 몸통 안에서 선이 시작하지 않게 방향을 따라 이만큼 앞에서 출발(m)
local SRC_OFFSET = { heli = 4.0, drone = 1.2, sniper = 0.6 }
-- 2D 에서 드론 예광탄은 옅은 선(알파 0.14)이다. 3D 는 가산 합성이라 조금 더 높게 둔다
local SRC_ALPHA  = { heli = 0.9, drone = 0.35, sniper = 0.9 }

local _logged = {}
local function logOnce(key, msg)
    if _logged[key] then return end
    _logged[key] = true
    print("[PongDu][VP] " .. msg)
end

local function push(q, e)
    q[#q + 1] = e
    while #q > QUEUE_MAX do table.remove(q, 1) end
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- 자바 부분이 최근에 프레임을 돌렸는지(PongDuVP_JavaFrame 이 늘고 있는지). 로그 판단용.
local _lastJavaFrame, _javaSeenAt = nil, nil
local function javaAlive(now)
    local f = PongDuVP_JavaFrame
    if f ~= nil and f ~= _lastJavaFrame then
        _lastJavaFrame = f
        _javaSeenAt = now
    end
    return _javaSeenAt ~= nil and now - _javaSeenAt < 3000
end

-- src: "heli" | "drone" | "sniper", altM: 원점 바닥(oz)에서의 고도(m)
function H.tracer(src, ox, oy, oz, altM, tx, ty, tz)
    local now = getTimestampMs()
    if not javaAlive(now) then
        logOnce("tracerNoJava", "3D tracer queued but java part has not drawn yet (ZombieBuddy jar not loaded?)")
    end
    local ou = (tonumber(oz) or 0) * LEVEL_M + (tonumber(altM) or 0)
    local tu = (tonumber(tz) or 0) * LEVEL_M + TRACER_AIM_H
    local dx, dy, du = tx - ox, ty - oy, tu - ou
    local dist = math.sqrt(dx * dx + dy * dy + du * du)
    if dist < 0.5 then return end
    local off = math.min(SRC_OFFSET[src] or 0.6, dist * 0.5) / dist
    push(PongDuVP_TracerQueue, {
        ox = ox + dx * off, oy = oy + dy * off, ou = ou + du * off,
        tx = tx, ty = ty, tu = tu,
        t0 = now, a = SRC_ALPHA[src] or 0.9, flash = (src ~= "drone"),
    })
    logOnce("tracerFirst", string.format("first 3D tracer queued src=%s dist=%.1fm", tostring(src), dist))
end

function H.gasSpawn(x, y, z, r, durMs, cr, cg, cb)
    local now = getTimestampMs()
    local dur = tonumber(durMs) or 0
    push(PongDuVP_GasQueue, {
        x = x, y = y, z = tonumber(z) or 0, r = tonumber(r) or 0,
        t0 = now, dur = dur,
        spread = clamp(dur * 0.25, 0, GAS_SPREAD_CAP),
        fade = clamp(dur * 0.30, 0, GAS_FADE_CAP),
        cr = cr or 0.6, cg = cg or 0.6, cb = cb or 0.6,
    })
    print(string.format("[PongDu][VP] 3D gas queued at %.0f,%.0f r=%.0f durMs=%d java=%s",
        x, y, tonumber(r) or 0, math.floor(dur), tostring(javaAlive(now))))
end

local function onGameStart()
    PongDuVP_GasQueue = {}
    PongDuVP_TracerQueue = {}
    print("[PongDu][VP] bridge ready: view=" .. tostring(PongDuViewpointView ~= nil)
        .. " (java part logs '[PongDu][VPJ]' when ZombieBuddy loads it)")
end
Events.OnGameStart.Add(onGameStart)
