-- ── 좀비 레인 (zombie_rain) 서버 ── [z 리프트 + 클라 최상층 스퀘어 1칸] ────────
-- 야외 공중(z>0)에는 그리드 스퀘어가 없다. B42.21 소스 기준으로 막히는 곳은 한 군데뿐이다.
--  ① 클라 생성 관문: NetworkZombieSimulator.parseZombie 가 처음 보는 좀비를
--     getGridSquare(realX, realY, realZ) 가 있을 때만 만든다 (realZ = floor(좀비 z),
--     NetworkZombieAI). 한 번 만들어진 뒤의 갱신 패킷은 스퀘어를 보지 않는다.
--  (B41 의 ② 낙하 물리 문제는 B42 에 없다: IsoMovingObject.findCurrentGridSquare 가 없는 층을
--   아래로 내려가며 찾고, getHeightAboveFloor 도 아래층 바닥을 찾는다. 카오스모드(ChaosMod)
--   EffectZombiesRain 이 스퀘어 없이 setZ(+3) 만으로 떨어뜨리는 것도 이 덕분이다.)
--
-- 그래서 (2026-10-27 개량, 이전엔 서버·클라 모두 z=1..DROP_Z 전 층을 만들었다)
--  - 서버: 스퀘어를 만들지 않는다. 지면(z=0)에 스폰한 뒤 바로 setZ(dropZ). 서버가 만든
--    스퀘어는 월드 저장에 남고 지울 API 가 없어서, 이전엔 발동마다 저장이 커졌다.
--  - MP 클라: Prep 을 받으면 컬럼마다 낙하 시작 층(dropZ) 1칸만 만든다(관문 ① 통과용).
--    클라 스퀘어는 서버 저장에 안 들어간다. createNewGridSquare 는 멱등.
--  - SP: 네트워크 관문이 없어 스퀘어가 필요 없다(Prep 도 안 보냄).
-- 대가: 낙하 도중 처음 범위에 들어온 클라는 그 층 스퀘어가 없어 착지 후에 좀비가 보인다.
--
-- 플로우:
--  Start 수신 → 컬럼 일괄 선정 → 서버 스퀘어 생성 → Prep 브로드캐스트(클라 생성)
--  → PREP_DELAY 대기 → z=DROP_Z에 직접 스폰(페이스 유지) → RainMark(체력/스프린터)
--
-- 낙하 데미지(DoLand)는 좀비 체력이 클라 권한이라 서버에서 못 막는다
-- → RainMark를 받은 소유 클라가 공중에 있는 동안 매 틱 fallTime을 0으로 돌려
-- 착지 데미지/넘어짐 자체를 없앤다 (client/features/zombierain.lua).
-- 체력은 따로 저장/원복하지 않는다 -- 서버 설정(좀비 강인함, 특좀 체력 옵션) 그대로.
--
-- [실험 유의] 생성된 빈 스퀘어는 지울 수 있는 API가 없어 월드에 잔류한다.
-- 발동당 최대 (총 마리수) x DROP_Z개. 실험 월드에서 세이브 크기/부하 실측 후
-- 본 규모(500) 확장 여부를 결정한다.

-- 지속시간/종류별 마리수는 샌드박스(Rain_Duration/Rain_Count_<종류>)를 클라가
-- Start에 실어 보내고, 여기 값들은 파라미터 누락(구버전 클라) 시 폴백 + 클램프
-- 한계로 쓴다.
local RAIN_DUR_DEFAULT_S = 30                               -- 지속시간 폴백 (초)
local RAIN_DUR_MIN_S     = 5
local RAIN_DUR_MAX_S     = 120
local RAIN_CNT_MAX       = 500                              -- 전 종류 합계 상한 (스퀘어 생성 부하)

-- 낙하 종류. "normal" 외에는 특좀 파이프라인(PuppetMutant kind)과 같은 이름이다
-- (sprinter = server.lua spawnZombies 뛰좀, 나머지 = features/mutantspawn.lua KINDS).
-- 순서는 로그 출력 순서일 뿐, 실제 낙하 순서는 셔플된다.
local RAIN_KINDS = { "normal", "sprinter", "screamer", "brute", "roach", "tracer", "wrecker" }
local RAIN_DROP_Z        = 7                                -- 좀비 레인 낙하 시작 높이 (층)
-- 수송기 투하 낙하 시작 높이 (층). 수송기 고도(클라 zombierain.lua PLANE_FLOORS = 15층) 바로 아래라
-- 화면에서 좀비가 기체 배 밑에서 떨어져 나온다. 스퀘어 상한은 31층(IsoChunkMap.TOP_LEVEL)이라 14층 생성 가능.
-- 대가: 낙하산 하강 시간 약 6초(2.4층/초, 클라 zombierain.lua PARA_DESCENT). 스퀘어는 층수와 무관하게 클라 컬럼당 1칸.
local AIRDROP_DROP_Z     = 14
local RAIN_MIN_DIST      = 3                                -- 플레이어 직격 방지 최소 거리
local SPAWN_CAP_PER_TICK = 5                                -- 랙 스파이크 후 몰아치기 상한
local PICK_TRIES         = 20                               -- 컬럼 후보 탐색 시도 횟수
local PREP_DELAY_MS      = 1000                             -- 클라 스퀘어 생성 대기 (클라 zombierain.lua SERVER_PREP_MS 와 동일값 유지)

-- ── 연출 방식 (Rain_Style, 샌드박스 드롭다운) ──
-- 기능 표시명은 "좀비 공습"(featureId는 zombie_rain 유지), 방식은 샌드박스 드롭다운.
-- 1 = 좀비 레인: 플레이어 중심 반경(Rain_Radius) 원 안에 균등 간격으로 낙하
-- 2 = 수송기 투하: 아래 투하 모드
-- 새 방식을 추가하면 번호를 이어 붙이고, 클라 zombierain.lua STYLE_* 와
-- sandbox-options.txt numValues, Sandbox_KO option<N> 도 같이 늘린다.
-- 모르는 번호는 1로 처리한다.
local STYLE_RAIN    = 1
local STYLE_AIRDROP = 2
local STYLE_NAMES   = { [STYLE_RAIN] = "rain", [STYLE_AIRDROP] = "airdrop" }

-- ── 투하 모드 (Rain_Style = 2) ──
-- 경로는 화력지원 헬기(server.lua Heli 핸들러)와 같은 방식:
--   A = 플레이어 중심 반경 D 원 위 무작위 각도, B = 반대편(±30도 지터).
--   D = 투하 반경 + AIR_PATH_EXTRA -> 시작/소멸이 화면 밖. 지터 때문에 머리 위가
--   아니라 근처(최대 약 0.26D)를 스치듯 지나가기도 한다.
-- 수송기는 A 에 도달하기 전·B 를 지난 뒤에도 같은 속도로 난다: 비행 경로는 AB 를 양쪽으로
-- AB 길이 x (AIR_PATH_SCALE - 1) / 2 만큼 늘인 A' -> B' (A' A B B' 순)이다.
-- 지속시간 설정값 = A' -> B' 체공 시간. PREP_DELAY_MS 시점에 A' 에서 나타나 지속시간 끝에 B' 에서
-- 사라진다. 좀비 투하는 A -> B 구간(가운데 1/AIR_PATH_SCALE)에서만 한다.
-- 예: AIR_PATH_SCALE 2, 지속 10초 -> 0~2.5초 접근, 2.5~7.5초 투하, 7.5~10초 이탈.
-- 클라에는 Flight 로 A'/B' 와 체공 시간을 보내 그림자·엔진음이 A' -> B' 를 따라가게 한다.
-- 각 좀비는 스폰 시각 t의 수송기 위치 P(t)를 중심으로 투하 반경(r) 원 안에 떨어진다
-- (그림자가 움직이면 투하 범위도 같이 움직인다). 스퀘어 선행 생성(Prep) 때문에
-- 시각과 위치는 Start 시점에 전부 미리 정한다. 그림자는 클라가 Flight로 그린다.
local AIR_PATH_EXTRA     = 50                               -- 헬기와 동일 (D = r + 50)
local AIR_JITTER         = 0.52                             -- B 각도 지터 (rad, 약 ±30도)
local AIR_PATH_SCALE     = 2                                -- 비행 경로 A'B' = AB x 이 값 (투하는 AB 만)

local _sessions = {}

-- [B42 SP 브리지] Lua sendServerCommand 는 GameServer.server 일 때만 패킷을 보낸다
-- (LuaManager.sendServerCommand). SP 에선 아무 일도 안 일어나 RainMark/Flight 가
-- 클라에 안 닿고, 낙하산·수송기 그림자·엔진음이 통째로 빠졌다(B41 SP 도 동일).
-- SP 는 서버·클라 Lua 가 한 VM 이므로 클라 OnServerCommand 핸들러를 직접 발화시킨다.
local function isSP()
    return not isClient() and not isServer()
end

local function toClients(command, args)
    if isSP() then
        triggerEvent("OnServerCommand", "PongDuRain", command, args)
    else
        sendServerCommand("PongDuRain", command, args)
    end
end

-- 건물 없는 야외 지상(z=0) 컬럼 선정.
--  ① sq:isOutside()            : 실외
--  ② sq:getBuilding() == nil   : 맵 건물 스퀘어 제외 (지붕 착지 방지)
--  ③ 물 스퀘어 제외             : 강/호수 수장 방지
--  ④ 위층(z=1..DROP_Z) 바닥 없음: 플레이어 건축물 지붕/2층 바닥 방지.
--     스퀘어가 존재해도 바닥이 없으면 통과 (이전 레인이 만든 빈 스퀘어 재사용)
local function isRainColumn(cell, x, y, dropZ)
    local sq = cell:getGridSquare(x, y, 0)
    if not sq or not sq:isOutside() or sq:getBuilding() ~= nil
        or sq:has(IsoFlagType.water) then
        return false
    end
    for zz = 1, dropZ do
        local up = cell:getGridSquare(x, y, zz)
        if up and up:getFloor() ~= nil then return false end
    end
    return true
end

local function pickRainColumn(cell, px, py, radius)
    for _ = 1, PICK_TRIES do
        local angle = ZombRand(628) / 100.0
        -- sqrt 분포 -> 원판 내 균등 (반경 비례 편중 방지)
        local dist  = RAIN_MIN_DIST
            + math.sqrt(ZombRand(10000) / 10000.0) * (radius - RAIN_MIN_DIST)
        local x  = math.floor(px + math.cos(angle) * dist)
        local y  = math.floor(py + math.sin(angle) * dist)
        if isRainColumn(cell, x, y, RAIN_DROP_Z) then return x, y end
    end
    return nil
end

-- 투하 모드 컬럼: 수송기 위치 (cx, cy) 중심 반경 radius 원 안 (원판 균등).
-- 시도 절반을 넘기면 반경을 2배로 넓혀 다시 찾는다 (도심/물가 대비).
-- 플레이어 직격 방지(RAIN_MIN_DIST)는 기존과 동일.
local function pickAirdropColumn(cell, px, py, cx, cy, radius)
    for try = 1, PICK_TRIES do
        local rr = radius
        if try > PICK_TRIES / 2 then rr = radius * 2 end
        local angle = ZombRand(628) / 100.0
        local dist  = math.sqrt(ZombRand(10000) / 10000.0) * rr
        local x = math.floor(cx + math.cos(angle) * dist)
        local y = math.floor(cy + math.sin(angle) * dist)
        local dx, dy = x + 0.5 - px, y + 0.5 - py
        if dx * dx + dy * dy >= RAIN_MIN_DIST * RAIN_MIN_DIST
            and isRainColumn(cell, x, y, AIRDROP_DROP_Z) then
            return x, y
        end
    end
    return nil
end

-- 종류별 마리수 -> 셔플된 종류 목록. 지속시간 동안 종류가 고르게 섞여 떨어지게
-- 한다 (셔플 없이 이어붙이면 특좀이 마지막에 몰린다). 합계가 상한을 넘으면
-- 셔플 후 앞에서부터 잘라 설정 비율을 대략 유지한다.
local function buildKindList(kinds)
    local list = {}
    for _, k in ipairs(RAIN_KINDS) do
        local n = math.floor(tonumber(kinds and kinds[k]) or 0)
        if n < 0 then n = 0 elseif n > RAIN_CNT_MAX then n = RAIN_CNT_MAX end
        for _ = 1, n do list[#list + 1] = k end
    end
    local requested = #list
    -- Fisher-Yates
    for i = #list, 2, -1 do
        local j = ZombRand(i) + 1
        list[i], list[j] = list[j], list[i]
    end
    if #list > RAIN_CNT_MAX then
        for i = #list, RAIN_CNT_MAX + 1, -1 do list[i] = nil end
    end
    return list, requested
end

-- 1마리 스폰: 지면(z=0)에 생성 후 바로 z=session.dropZ 로 올린다(파일 머리 주석). 랜덤 아웃핏(outfit=nil),
-- 체력 캡처 후 세션 배치에 적재. 특좀 종류는 서버 modData에 마킹만 하고
-- 스탯/행동 적용은 RainMark를 받은 클라가 특좀 적용기(mutantspawn)에 넘겨
-- 처리한다 (B41 MP 좀비는 클라 권한).
local function spawnRainZombie(session, col, kind)
    -- addZombiesInOutfit 는 해당 z 스퀘어가 있어야 스폰한다(LuaManager). 지면은 isRainColumn 이 보장.
    local zeds = addZombiesInOutfit(col.x, col.y, 0, 1, nil, nil)
    if not zeds or zeds:size() == 0 then return false end
    local zed = zeds:get(0)
    zed:setZ(session.dropZ)
    zed:setLastZ(session.dropZ)
    zed:DoZombieStats()
    -- 후원받은 플레이어 쪽으로 어그로
    local p = session.player
    pcall(function() zed:setTarget(p) end)
    pcall(function() zed:setTurnAlertedValues(math.floor(p:getX()), math.floor(p:getY())) end)
    -- 서버측 특좀 마킹: 이게 있어야 시체(IsoDeadBody)에 계승되어 강령술
    -- (RiseUp)이 b:getModData()["PuppetMutant"]를 읽고 같은 종류로 부활시킨다.
    -- PuppetMutantZid 스탬프 필수 -- 없으면 staleSweep이 풀 재활용으로 오인해 즉시 지운다.
    local mutant = kind ~= nil and kind ~= "normal"
    if mutant then
        local md = zed:getModData()
        md["PuppetMutant"]    = kind
        md["PuppetMutantZid"] = zed:getOnlineID()
        if session.sender and session.sender ~= "" then
            md["PuppetMutantSender"] = session.sender
        end
    end
    session.batch[#session.batch + 1] = {
        ["id"] = zed:getOnlineID(),
        ["k"]  = mutant and kind or nil,
        -- SP 는 onlineID 가 전부 -1 이라 키로 못 쓴다. 같은 자바 객체를 그대로 넘겨
        -- 클라가 객체로 매칭한다 (MP 는 nil -- 객체는 직렬화 대상이 아니다).
        ["obj"] = isSP() and zed or nil,
    }
    return true
end

local function flushBatch(session, force)
    if #session.batch == 0 then return end
    local now = getTimestampMs()
    -- 매 틱 즉시 보낸다: 클라가 RainMark를 받아야 낙하 데미지 방지/방향 고정/
    -- 낙하산을 적용하므로, 묶어 보내면 그동안 무방비로 떨어진다.
    session.lastFlush = now
    toClients("RainMark", {
        ["zeds"]   = session.batch,
        ["sender"] = session.sender or "",   -- 스프린터 이름표용 (세션 공통)
        ["para"]   = session.para,           -- 낙하산 연출 (Rain_Parachute, 세션 공통)
    })
    -- 어그로 스코프 공급: 이번 배치의 zid를 열려있는 어그로 창(pid 매칭)에
    -- 추가한다 (features/aggro.lua "AddIds" 수신부). 낙하 좀비는 배치 분산
    -- 스폰이라 창 오픈 시점엔 id가 없다 — 배치마다 증분 공급.
    pcall(function()
        local ids = {}
        for i = 1, #session.batch do ids[i] = session.batch[i]["id"] end
        sendServerCommand("PongDuAggro", "AddIds", {
            ["pid"]  = session.player:getOnlineID(),
            ["zeds"] = ids,
        })
    end)
    session.batch = {}
end

-- 종류별 실제 소환 수 로그 문자열 (" normal=93 sprinter=5 ..."). 컬럼 부족으로
-- 잘린 종류와 스폰 실패분이 반영된 서버 기준 값이다.
local function kindTally(s)
    local out = ""
    for _, k in ipairs(RAIN_KINDS) do
        out = out .. " " .. k .. "=" .. tostring(s.byKind[k] or 0)
    end
    return out
end

-- 일시정지(SP) 보정: 스폰 시각은 실시간(getTimestampMs) 기준인데 일시정지 중엔 OnTick 이
-- 안 돈다. 재개 첫 틱에 경과시간이 통째로 들어가 밀린 컬럼이 한꺼번에 쏟아지고
-- (틱당 상한까지), durMs+5초를 넘기면 남은 컬럼을 버리고 세션이 끝났다.
-- 틱 간격이 이보다 크면 그 공백만큼 세션 시각 기준을 뒤로 민다 (차량보급과 같은 방식).
local PAUSE_GAP_MS = 500
local _lastTickAt = nil

local function onTick()
    local now = getTimestampMs()
    local gap = _lastTickAt and (now - _lastTickAt) or 0
    _lastTickAt = now
    if #_sessions == 0 then return end
    if gap > PAUSE_GAP_MS then
        for _, s in ipairs(_sessions) do
            if s.startMs then s.startMs = s.startMs + gap end
            s.readyAt = s.readyAt + gap
            s.flightAt = s.flightAt + gap
        end
        print(string.format("[PongDuRain] tick gap %dms (pause?) -> %d session(s) shifted", gap, #_sessions))
    end
    for i = #_sessions, 1, -1 do
        local s = _sessions[i]
        -- 플레이어 접속 종료 등으로 무효화되면 세션 폐기
        local alive = s.player and pcall(function() return s.player:getX() end)
        if not alive then
            print("[PongDuRain] session dropped (player gone) spawned=" .. tostring(s.spawned)
                .. " hits=" .. tostring(s.hits) .. kindTally(s))
            table.remove(_sessions, i)
        elseif now >= s.readyAt then
            if not s.startMs then s.startMs = now end
            local elapsed = now - s.startMs
            -- 컬럼별 스폰 시각(t)이 지난 만큼 스폰 (틱당 상한으로 폭주 방지).
            -- 일반 모드는 t = i x 간격(균등), 투하 모드는 비행기 통과 시각.
            local n = 0
            while s.spawned + n < #s.cols and s.cols[s.spawned + n + 1].t <= elapsed do
                n = n + 1
            end
            if n > SPAWN_CAP_PER_TICK then n = SPAWN_CAP_PER_TICK end
            for _ = 1, n do
                s.spawned = s.spawned + 1
                local ok, res = pcall(spawnRainZombie, s, s.cols[s.spawned], s.kinds[s.spawned])
                if not ok then
                    print("[PongDuRain] spawn error: " .. tostring(res))
                elseif res then
                    s.hits = s.hits + 1
                    local k = s.kinds[s.spawned] or "normal"
                    s.byKind[k] = (s.byKind[k] or 0) + 1
                end
            end
            if n > 0 then
                -- 투하 시각 검증용: 발동 + PREP_DELAY_MS(투하 모드는 수송기가 A' 에 나타나는 시각) 기준 ms
                local rel = now - s.flightAt
                if not s.firstDropMs then
                    s.firstDropMs = rel
                    print(string.format("[PongDuRain] first drop at %dms (expected %d..%d)",
                        math.floor(rel), math.floor(s.leadMs), math.floor(s.leadMs + s.durMs)))
                end
                s.lastDropMs = rel
            end
            flushBatch(s, false)
            if s.spawned >= #s.cols or elapsed > s.durMs + 5000 then
                flushBatch(s, true)
                print("[PongDuRain] session done player=" .. tostring(s.player:getUsername())
                    .. " spawned=" .. tostring(s.spawned) .. " hits=" .. tostring(s.hits)
                    .. " cols=" .. tostring(#s.cols) .. kindTally(s)
                    .. " firstDropMs=" .. tostring(s.firstDropMs and math.floor(s.firstDropMs) or -1)
                    .. " lastDropMs=" .. tostring(s.lastDropMs and math.floor(s.lastDropMs) or -1)
                    .. " expected=" .. tostring(math.floor(s.leadMs)) .. ".." .. tostring(math.floor(s.leadMs + s.durMs)))
                table.remove(_sessions, i)
            end
        end
    end
end
Events.OnTick.Add(onTick)

-- ── 투하 모드: 실체 수송기 (Base.PongDuC17 차량) ─────────────────────────────
-- 화력지원 헬기(server.lua heliSpawnVehicle)와 같은 방식이다:
--   서버가 addVehicleDebug 로 스폰 -> 요청 플레이어에 Local 물리 권한(authorizationChanged)
--   -> 그 클라(파일럿)가 매 틱 경로 좌표로 setWorldTransform -> 엔진이 전 클라에 보간 전파.
--   종료는 서버 permanentlyRemove (제거 패킷 브로드캐스트 + VehiclesDB 삭제).
-- 헬기와 다른 점: 경로 전체를 날지 않고 플레이어 근처 구간(PLANE_VIS_R 안)만 띄운다.
--   경로 양끝(D = 반경 + 50 타일)은 클라 차량 전송 판정(UdpConnection.RelevantTo) 경계라
--   헬기에서 "차량이 안 오거나 도중에 회수"되는 문제가 있었고, 그 구간은 어차피 화면 밖이다.
--   지면 그림자는 지금처럼 클라가 경로 전체에 그린다.
-- 스폰이 실패해도 그림자·엔진음·좀비 투하는 그대로라 후원은 죽지 않는다.
local PLANE_SCRIPT   = "Base.PongDuC17"
local PLANE_VIS_R    = 45      -- 플레이어(발동 시점 위치)에서 이 거리 안 구간만 실체를 띄운다 (타일)
local PLANE_TAIL_MS  = 500     -- 구간 끝 이후 제거까지 여유
local _planes = {}

-- 경로 진행률 f(0=A, 1=B) 중 (px,py) 에서 R 안에 드는 구간 [f0, f1]. 없으면 nil.
local function planeWindow(fl, px, py, R)
    local dx, dy = fl.bx - fl.ax, fl.by - fl.ay
    local ox, oy = fl.ax - px, fl.ay - py
    local a = dx * dx + dy * dy
    if a <= 0 then return nil end
    local b = 2 * (ox * dx + oy * dy)
    local c = ox * ox + oy * oy - R * R
    local disc = b * b - 4 * a * c
    if disc <= 0 then return nil end
    local sq = math.sqrt(disc)
    local f0 = (-b - sq) / (2 * a)
    local f1 = (-b + sq) / (2 * a)
    if f0 < 0 then f0 = 0 end
    if f1 > 1 then f1 = 1 end
    if f1 <= f0 then return nil end
    return f0, f1
end

local function planeRemove(pl, reason)
    if pl.vehicle then
        local ok, err = pcall(function() pl.vehicle:permanentlyRemove() end)
        print("[PongDuRain] plane vehicle removed vid=" .. tostring(pl.vid) .. " ok=" .. tostring(ok)
            .. (ok and "" or (" err=" .. tostring(err))) .. " (" .. tostring(reason) .. ")")
        toClients("PlaneStop", { ["vid"] = pl.vid })
    end
    pl.vehicle = nil
end

local function planeSpawn(pl, frac)
    local x = pl.fl.ax + (pl.fl.bx - pl.fl.ax) * frac
    local y = pl.fl.ay + (pl.fl.by - pl.fl.ay) * frac
    local okP, px, py = pcall(function() return pl.player:getX(), pl.player:getY() end)
    if not okP then return false end
    -- 스폰 칸이 서버에 로드돼 있어야 한다. 없으면 플레이어 쪽으로 10%씩 당긴다(헬기와 같음).
    -- 파일럿 클라가 첫 틱에 경로 좌표로 옮기므로 스폰 칸 위치는 보이지 않는다.
    local sq = nil
    for step = 0, 9 do
        local t = step * 0.1
        sq = getSquare(math.floor(x + (px - x) * t), math.floor(y + (py - y) * t), 0)
        if sq then break end
    end
    if not sq then
        print("[PongDuRain] plane spawn FAILED: no loaded square near " .. math.floor(x) .. "," .. math.floor(y))
        return false
    end
    local ok, v = pcall(function() return addVehicleDebug(PLANE_SCRIPT, IsoDirections.N, 0, sq) end)
    if not ok or not v then
        print("[PongDuRain] plane spawn FAILED err=" .. tostring(v))
        return false
    end
    pl.vehicle = v
    pl.vid = v:getId()
    local pilot = nil
    local okA, errA = pcall(function()
        pilot = pl.player:getOnlineID()
        v:authorizationChanged(pl.player)
    end)
    if not okA then print("[PongDuRain] plane authorization FAILED err=" .. tostring(errA)) end
    toClients("PlaneStart", {
        ["vid"] = pl.vid, ["pilot"] = pilot,
        ["ax"] = pl.fl.ax, ["ay"] = pl.fl.ay, ["bx"] = pl.fl.bx, ["by"] = pl.fl.by,
        ["frac"] = frac, ["dur"] = pl.durMs, ["f1"] = pl.f1,
    })
    print(string.format("[PongDuRain] plane spawned vid=%s at %d,%d frac=%.2f..%.2f pilot=%s",
        tostring(pl.vid), sq:getX(), sq:getY(), frac, pl.f1, tostring(pilot)))
    return true
end

-- 투하 세션 시작 시 호출. startAt = 수송기가 A 에 있는 시각(= 발동 + PREP_DELAY_MS).
local function planeQueue(player, fl, durMs, startAt)
    local px, py = player:getX(), player:getY()
    local f0, f1 = planeWindow(fl, px, py, PLANE_VIS_R)
    if not f0 then
        print("[PongDuRain] plane skipped: path never within " .. PLANE_VIS_R .. " tiles of player")
        return
    end
    _planes[#_planes + 1] = {
        player = player, fl = fl, durMs = durMs,
        f0 = f0, f1 = f1,
        spawnAt  = startAt + f0 * durMs,
        removeAt = startAt + f1 * durMs + PLANE_TAIL_MS,
    }
    print(string.format("[PongDuRain] plane queued window frac=%.2f..%.2f (in %dms, out %dms)",
        f0, f1, math.floor(f0 * durMs), math.floor(f1 * durMs)))
end

local _planeLastTick = nil
local function planeTick()
    local now = getTimestampMs()
    local gap = _planeLastTick and (now - _planeLastTick) or 0
    _planeLastTick = now
    if #_planes == 0 then return end
    if gap > 500 then
        for _, pl in ipairs(_planes) do
            pl.spawnAt = pl.spawnAt + gap
            pl.removeAt = pl.removeAt + gap
        end
    end
    for i = #_planes, 1, -1 do
        local pl = _planes[i]
        local okP, dead = pcall(function() return pl.player:isDead() end)
        if not okP or dead then
            planeRemove(pl, "owner gone")
            table.remove(_planes, i)
        elseif now >= pl.removeAt then
            planeRemove(pl, "window end")
            table.remove(_planes, i)
        elseif not pl.tried and now >= pl.spawnAt then
            pl.tried = true
            local frac = pl.f0 + (now - pl.spawnAt) / pl.durMs
            local ok, res = pcall(planeSpawn, pl, frac)
            if not ok then print("[PongDuRain] plane spawn error: " .. tostring(res)) end
        end
    end
end
Events.OnTick.Add(planeTick)

-- ── 남은 수송기 정리 (고아 차량) ─────────────────────────────────────────────
-- _planes 는 서버 메모리에만 있다. 비행 중에 서버가 꺼지면(정상 종료 포함 -- 종료 훅이 없다)
-- 목록은 사라지지만 addVehicleDebug 로 스폰한 차량은 VehiclesDB 에 남아 재시작 후 그 자리에
-- 굳어 있고, 아무도 옮기거나 지우지 않는다. 화력지원 헬기·드론(server.lua
-- sweepOrphanFireSupportVehicles)과 같은 방식으로, 로드된 셀의 차량 중 스크립트가
-- PongDuC17 인데 _planes 어디에도 vid 가 없는 것을 permanentlyRemove 한다.
-- 첫 틱에 바로 1회 돌아서 재시작 전 잔존물도 곧바로 지운다. 이후 10초 간격.
-- 셀이 로드돼 있지 않은 잔존물은 그 셀이 로드된 뒤의 다음 주기에 지워진다.
-- 서버와 SP 에서만 돈다(MP 클라의 _planes 는 항상 비어 있어 살아 있는 기체를 지울 수 있다).
local PLANE_ORPHAN_INTERVAL_MS = 10000
local _planeOrphanAt = nil

local function planeIsTracked(vid)
    for i = 1, #_planes do
        if _planes[i].vid == vid then return true end
    end
    return false
end

local function planeSweepOrphans()
    local okC, cell = pcall(getCell)
    if not okC or not cell then return end
    -- B42: getVehicles() 는 Set 이라 get(int) 가 없다. toArray() 사본이라 순회 중 제거해도 안전
    local okV, vehicles = pcall(function() return cell:getVehicles():toArray() end)
    if not okV or not vehicles then return end
    for _, v in ipairs(vehicles) do
        if v then
            local okS, sn = pcall(function() return v:getScriptName() end)
            if okS and sn == PLANE_SCRIPT then
                local vid = v:getId()
                if not planeIsTracked(vid) then
                    local okR, err = pcall(function() v:permanentlyRemove() end)
                    print("[PongDuRain] orphan plane vid=" .. tostring(vid)
                        .. (okR and " removed" or (" remove FAILED err=" .. tostring(err))))
                end
            end
        end
    end
end

local function planeOrphanTick()
    local now = getTimestampMs()
    if _planeOrphanAt and now - _planeOrphanAt < PLANE_ORPHAN_INTERVAL_MS then return end
    _planeOrphanAt = now
    local ok, err = pcall(planeSweepOrphans)
    if not ok then print("[PongDuRain] orphan plane sweep error: " .. tostring(err)) end
end
if not isClient() then
    Events.OnTick.Add(planeOrphanTick)
end

Events.OnClientCommand.Add(function(module, command, player, data)
    if module ~= "PongDuRain" or command ~= "Start" then return end
    if not player then return end
    local cell = getCell()
    if not cell then return end
    local r      = tonumber(data and data["r"]) or 55
    local durS   = tonumber(data and data["dur"]) or RAIN_DUR_DEFAULT_S
    local sender = tostring(data and data["sender"] or "")
    local style  = math.floor(tonumber(data and data["style"]) or STYLE_RAIN)
    local para   = data and data["para"] == true
    if not STYLE_NAMES[style] then
        print("[PongDuRain] WARN unknown style " .. tostring(style) .. ", fallback to rain")
        style = STYLE_RAIN
    end
    if r < 3 then r = 3 elseif r > 100 then r = 100 end
    if durS < RAIN_DUR_MIN_S then durS = RAIN_DUR_MIN_S
    elseif durS > RAIN_DUR_MAX_S then durS = RAIN_DUR_MAX_S end
    local durMs = durS * 1000
    -- 좀비가 실제로 떨어지는 구간 시간. 레인은 지속시간 그대로. 공중투하는 지속시간이 수송기
    -- 체공 시간(A'->B')이고, 좀비는 그중 A->B(가운데 1/AIR_PATH_SCALE)에서만 떨어진다.
    local dropMs = (style == STYLE_AIRDROP) and (durMs / AIR_PATH_SCALE) or durMs
    local dropZ = (style == STYLE_AIRDROP) and AIRDROP_DROP_Z or RAIN_DROP_Z

    local kinds  = type(data and data["kinds"]) == "table" and data["kinds"] or nil
    local kindList, requested = buildKindList(kinds)
    local cntLog = ""
    for _, k in ipairs(RAIN_KINDS) do
        cntLog = cntLog .. " " .. k .. "=" .. tostring(kinds and kinds[k] or 0)
    end
    print("[PongDuRain] request" .. cntLog .. " total=" .. tostring(requested)
        .. " used=" .. tostring(#kindList))
    if not kinds then
        print("[PongDuRain] WARN no kinds table in Start (client/server version mismatch?)")
    end
    if #kindList == 0 then
        print("[PongDuRain] session aborted (total count 0) player=" .. tostring(player:getUsername()))
        return
    end
    local cnt = #kindList

    -- 컬럼 일괄 선정 + 서버 스퀘어 생성 + 클라 브로드캐스트 페이로드 구성
    -- [계측] 시작 틱 스파이크 실측용: 선정/생성 각 단계 소요시간을 분리 측정
    local tPick0 = getTimestampMs()
    local px, py = player:getX(), player:getY()
    local cols, payload = {}, {}
    local missedPick = 0
    local flight = nil
    local leadMs = 0      -- 투하 모드: 수송기가 A' 에서 A 까지 오는 시간. 좀비 스폰은 그만큼 늦게 시작
    if style == STYLE_AIRDROP then
        -- 비행 경로 A -> B (화력지원 헬기와 같은 산출식)
        local D    = r + AIR_PATH_EXTRA
        local ang  = ZombRand(628) / 100.0
        local jit  = (ZombRand(105) - 52) / 100.0
        local ang2 = ang + 3.1416 + jit
        flight = {
            ax = px + math.cos(ang)  * D, ay = py + math.sin(ang)  * D,
            bx = px + math.cos(ang2) * D, by = py + math.sin(ang2) * D,
        }
        -- 층화 추출: 지속시간을 cnt 칸으로 나눠 칸마다 1마리. 칸 순서대로 t가
        -- 오름차순이라 정렬 없이 스폰 시각이 단조 증가한다.
        for i = 1, cnt do
            local frac = ((i - 1) + ZombRand(10000) / 10000.0) / cnt
            local cx = flight.ax + (flight.bx - flight.ax) * frac
            local cy = flight.ay + (flight.by - flight.ay) * frac
            local x, y = pickAirdropColumn(cell, px, py, cx, cy, r)
            if x then
                cols[#cols + 1]       = { x = x, y = y, t = frac * dropMs }
                payload[#payload + 1] = { ["x"] = x, ["y"] = y }
            else
                missedPick = missedPick + 1
            end
        end
    else
        for _ = 1, cnt do
            local x, y = pickRainColumn(cell, px, py, r)
            if x then
                cols[#cols + 1]       = { x = x, y = y }
                payload[#payload + 1] = { ["x"] = x, ["y"] = y }
            else
                missedPick = missedPick + 1
            end
        end
        -- 균등 간격. 간격은 요청 마리수(cnt)가 아니라 실제 확보된 컬럼 수 기준 --
        -- cnt 기준이면 missedPick 발생 시 지속시간보다 일찍 끝난다.
        if #cols > 0 then
            local intervalMs = durMs / #cols
            for i = 1, #cols do cols[i].t = i * intervalMs end
        end
    end
    local tPick1 = getTimestampMs()
    if #cols == 0 then
        print("[PongDuRain] session aborted (no columns) player=" .. tostring(player:getUsername()))
        return
    end
    -- 컬럼이 모자라면 종류 목록도 같은 길이로 자른다 (이미 셔플돼 있어 무작위 탈락)
    for i = #kindList, #cols + 1, -1 do kindList[i] = nil end

    -- SP 는 네트워크 생성 관문이 없어 스퀘어가 필요 없다 (파일 머리 주석)
    if isSP() then
        print("[PongDuRain] SP bridge on (Prep skipped, shared cell)")
    else
        sendServerCommand("PongDuRain", "Prep", { ["cols"] = payload, ["z"] = dropZ })
    end

    -- 투하 모드: 그림자 연출용 비행 정보. 수송기는 PREP_DELAY_MS 시점에 A', + leadMs 에 A,
    -- 그로부터 dropMs 뒤 B, 지속시간(durMs) 끝에 B' 에 도달한다 (서버 스폰 시각 t와 같은 기준).
    if flight then
        -- 비행 경로 A' -> B': AB 를 양쪽으로 (AIR_PATH_SCALE - 1) / 2 배씩 연장. 등속이라
        -- 비행 시간 = 지속시간 = dropMs x AIR_PATH_SCALE, A 도달은 PREP_DELAY_MS + leadMs.
        local ldx, ldy = flight.bx - flight.ax, flight.by - flight.ay
        local ext = (AIR_PATH_SCALE - 1) / 2
        leadMs = dropMs * ext
        local flyMs = durMs
        local flightExt = {
            ax = flight.ax - ldx * ext, ay = flight.ay - ldy * ext,
            bx = flight.bx + ldx * ext, by = flight.by + ldy * ext,
        }
        toClients("Flight", {
            ["ax"] = flightExt.ax, ["ay"] = flightExt.ay,
            ["bx"] = flightExt.bx, ["by"] = flightExt.by,
            ["prep"] = PREP_DELAY_MS, ["dur"] = flyMs,
            -- 발동자 클라는 이걸 받아 남은시간 패널을 수송기 체공 시간(A'->B')으로 맞춘다
            ["pid"] = player:getOnlineID(),
        })
        planeQueue(player, flightExt, flyMs, getTimestampMs() + PREP_DELAY_MS)
        local len = math.sqrt(ldx * ldx + ldy * ldy)
        print(string.format("[PongDuRain] airdrop flight A'=(%d,%d) A=(%d,%d) B=(%d,%d) B'=(%d,%d) dropLen=%.0f flyLen=%.0f speed=%.2f tiles/s leadMs=%d flyMs=%d dropR=%d",
            math.floor(flightExt.ax), math.floor(flightExt.ay),
            math.floor(flight.ax), math.floor(flight.ay), math.floor(flight.bx), math.floor(flight.by),
            math.floor(flightExt.bx), math.floor(flightExt.by),
            len, len * AIR_PATH_SCALE, len / (dropMs / 1000), math.floor(leadMs), math.floor(flyMs), r))
    end

    -- 낙하 좀비 플레이어 어그로 창 (클라 features/aggro.lua 수신).
    -- 아래 spawnRainZombie의 서버측 setTarget은 좀비 클라 권한 구조상 소유
    -- 클라 동기화에 덮여 실효가 없다 — 실제 어그로는 이 브로드캐스트를 받은
    -- 각 클라가 자기 소유 좀비에 건다. 좀비가 지속시간 내내 낙하하므로 창은
    -- 준비지연 + 지속시간 + 착지 여유(8초)까지 연다.
    -- v4: 반경 필터 폐지 — zid는 위 flushBatch가 배치마다 AddIds로 공급하므로
    -- 여기선 빈 창만 연다. 주변 기존 좀비는 더 이상 어그로 대상이 아니다.
    sendServerCommand("PongDuAggro", "Window", {
        ["dur"] = PREP_DELAY_MS + leadMs + dropMs + 8000,
        ["pid"] = player:getOnlineID(),
        ["src"] = "rain",
    })

    print("[PongDuRain] prep pickMs=" .. tostring(tPick1 - tPick0)
        .. " serverSquares=0"
        .. " cols=" .. tostring(#cols) .. " missedPick=" .. tostring(missedPick)
        .. " clientSquaresPerCol=1")

    _sessions[#_sessions + 1] = {
        player     = player,
        cols       = cols,
        kinds      = kindList,   -- cols[i] 에 떨어질 종류
        durMs      = dropMs,     -- 낙하 구간 길이 (세션 시간초과 판정 기준)
        dropZ      = dropZ,
        sender     = sender,
        para       = para,
        readyAt   = getTimestampMs() + PREP_DELAY_MS + leadMs,   -- 투하 모드는 수송기가 A 에 올 때
        flightAt  = getTimestampMs() + PREP_DELAY_MS,            -- 투하 시각 로그 기준 (수송기 A' 출현)
        leadMs    = leadMs,
        firstDropMs = nil,
        lastDropMs  = nil,
        startMs   = nil,
        spawned   = 0,
        hits      = 0,
        byKind    = {},  -- 종류별 실제 소환 수 (kindTally)
        batch     = {},
        lastFlush = 0,
    }
    print("[PongDuRain] session start para=" .. tostring(para) .. " player=" .. tostring(player:getUsername())
        .. " style=" .. STYLE_NAMES[style] .. " dropZ=" .. tostring(dropZ) .. " r=" .. tostring(r)
        .. " dur=" .. tostring(durS) .. "s cnt=" .. tostring(cnt)
        .. " dropMs=" .. tostring(math.floor(dropMs))
        .. " cols=" .. tostring(#cols) .. " intervalMs=" .. tostring(math.floor(dropMs / #cols)))
end)
