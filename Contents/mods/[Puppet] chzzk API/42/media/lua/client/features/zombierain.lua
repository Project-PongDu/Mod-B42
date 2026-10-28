local _a = {}
require("ISUI/ISPanel")
local timerStack = require("utils/timerStack")
local colorMap = require("utils/colorMap")
local labelKey = require("utils/labelKey")
local timerText = require("utils/timerText")
local fx = require("utils/fx")
local deltaTime = require("utils/deltaTime")
local mutantspawn = require("features/mutantspawn")
local vxf = require("utils/vehtransform")
local vpView = require("utils/viewpointView")

-- ── 좀비 레인 (zombie_rain) 클라이언트 ── [z 리프트 + 최상층 스퀘어 1칸] ─────────
-- 역할 4가지:
--  ① 시작: 샌드박스 반경/지속시간/종류별 마리수를 읽어 서버에 세션 시작 요청
--  ② 컬럼 준비: 서버 Prep(컬럼 좌표) 수신 시 낙하 시작 층(dropZ) 빈 스퀘어 1칸만 로컬 생성.
--     클라 생성 관문(NetworkZombieSimulator.parseZombie)이 "이 클라"의
--     getGridSquare(realZ)를 처음 생성할 때만 보므로 시작 층만 있으면 된다. 중간 층은
--     B42 낙하 물리가 아래층을 찾아 내려가 필요 없다(서버 PongDuRainServer.lua 머리 주석).
--     createNewGridSquare는 멱등(있으면 그대로 반환) -- 중복 안전.
--  ③ 남은시간 UI: 폭격 타이머와 동일 스타일의 30초 카운트다운 패널
--  ④ 낙하 처리: 서버 RainMark(zedId+종류)를 받아 공중에 있는 동안
--     - 소유 클라: 낙하 속도(lastFallSpeed)를 매 틱 직접 정한다 (아래 낙하 속도 절).
--       낙하산은 데미지 없이 사뿐히, 자유낙하도 바닥 1층 위부터 감속해 데미지·넘어짐 없이 착지
--     - 전 클라: 바라보는 방향 고정 (플레이어 쪽으로 돌며 낙하산이 회전하는 것 방지)
--     - 전 클라: 낙하 자세 고정 (아래 낙하 애니메이션 절)
--     - 낙하산 연출이면 낙하산 부착 + 감속 (아래 Rain_Parachute 절)
--     착지하면 대기열에서 뺀다. 체력은 건드리지 않는다 -- 서버 설정(좀비 강인함,
--     특좀 체력 옵션) 그대로다. 종류(k)가 있으면 특좀 적용기(mutantspawn.mark)에
--     넘긴다 -- 스프린터 포함 전 특좀이 도네 특좀과 같은 경로로 능력/이름표를 받는다.
--
-- [B42 낙하 판정] 착지 데미지·넘어짐은 fallTime 이 아니라 착지 순간 속도로 정한다.
-- IsoGameCharacter.updateFalling 이 매 틱 lastFallSpeed 에 중력(5.0 층/초^2)을 더하고
-- fallTime 도 그 속도에서 다시 계산하므로 setFallTime(0) 은 효과가 없다(B41 방식).
-- 착지 시 IsoZombie.handleLandingImpact 가 속도로 등급을 나눈다 (FallingConstants):
--   2.24 미만 = 데미지 없음 / 3.87 이상 = 넘어짐 + 50% 죽은척(FakeDead)
--   5.00 이상 = 확률로 기어다니는 좀비 / 데미지 = 속도/14.14 비례 x 샌드박스 좀비 낙하 데미지
-- 7층 자유낙하는 약 8.4 라 기어다니는 좀비·즉사가 나오고, z 만 붙잡는 감속은
-- 속도가 계속 쌓여 착지 속도가 더 커진다(낙하산 좀비가 대부분 즉사한 원인).
-- 그래서 소유 클라가 공중에 있는 동안 lastFallSpeed 를 매 틱 직접 정한다. 공중 감지는
-- OnZombieUpdate가 아닌 좀비 리스트 스캔을 쓴다 -- OnZombieUpdate는
-- ZombieFallDownState 동안 발화가 배제되므로(IsoZombie:2096) 놓칠 수 있다.
--
-- 표시명은 "좀비 공습"(IGUI_donation_zombie_rain). 공습 방식은 Rain_Style 드롭다운:
-- 1 = 좀비 레인(플레이어 중심 원), 2 = 수송기 투하. 투하는 서버가 보내는 비행
-- 정보(Flight, A->B)로 바닥에 수송기 그림자를 그린다 (실제 차량 없음, 렌더만).
-- 그림자는 OnPreUIDraw 에서 월드 위에 반투명으로 그린다 (B42 FBO 렌더러는
-- OnPostFloorLayerDraw 를 발화하지 않는다 -- drawFlights 주석).
--
-- [알려진 엣지] 낙하 도중 뒤늦게 스트림인한 클라는 컬럼 청크가 로드 전이라
-- 스퀘어 생성이 스킵될 수 있다 -> 해당 좀비는 착지(z=0) 후 패킷부터 정상
-- 재생성된다 (일시적 비표시만 발생, 유실 아님).

local PENDING_MS = 60000    -- RainMark 유효시간 (스트림아웃/원격 소유 잔여분 청소)
-- 서버 PongDuRainServer.lua 의 PREP_DELAY_MS 와 같은 값이어야 한다.
-- 서버는 Start 수신 후 이만큼 기다렸다가 첫 마리를 스폰하므로, 카운터/반경 마커도
-- 같은 만큼 늘려 "마지막 마리 스폰 = 카운터 0" 에 맞춘다.
local SERVER_PREP_MS = 1000

-- ── 샌드박스 옵션 (사용 시점에 읽음 -- 파일 로드 시점엔 SandboxVars 비어있음) ──
-- 반경(Rain_Radius), 지속시간(Rain_Duration, 초), 종류별 마리수(Rain_Count_<종류>)를
-- 서버에 전달한다. 클라 UI 타이머 길이도 지속시간을 따른다 (실제 경과 ms 감산).
-- kinds 키는 서버 RAIN_KINDS / 특좀 kind 이름과 같다.
-- 공습 방식 번호. 서버 PongDuRainServer.lua STYLE_* 와 번호를 맞춘다.
-- 새 방식 추가 시: 여기 + sandbox-options.txt numValues + Sandbox_KO option<N>
-- + 서버 STYLE_NAMES 를 함께 늘린다.
local STYLE_RAIN    = 1
local STYLE_AIRDROP = 2
local STYLE_MAX     = 2

local function styleNow()
    local st = SandboxVars.PongDu.Rain_Style
    if type(st) ~= "number" or st < 1 or st > STYLE_MAX then return STYLE_RAIN end
    return st
end

local function rainCfg()
    local sv = SandboxVars.PongDu
    local kinds = {
        ["normal"]   = sv.Rain_Count_Normal,
        ["sprinter"] = sv.Rain_Count_Sprinter,
        ["screamer"] = sv.Rain_Count_Screamer,
        ["brute"]    = sv.Rain_Count_Brute,
        ["roach"]    = sv.Rain_Count_Roach,
        ["tracer"]   = sv.Rain_Count_Tracer,
    }
    return sv.Rain_Radius, sv.Rain_Duration, kinds
end

-- ── 낙하 애니메이션 고정 ────────────────────────────────────────────────────
-- 바닐라 낙하 자세(fall_loop = Bob_FallIdle, 두 팔을 든 Y자)는 액션 상태가 "falling"일
-- 때만 나온다. 그런데 스폰 직후 좀비는 idle 상태이고 idle에는 falling 전이가 없으며,
-- falling 전이 조건 bFalling 도 낙하산 속도(PARA_DESCENT)에서는 서지 않는다
-- -> 서 있는 자세/걷기/돌아보기 등이 나왔다.
-- 해결: 공중에 있는 동안 전 클라가 로컬로 FALL_ANIM_VAR 를 세우고, 모드 AnimSets
-- (media/AnimSets/zombie/<상태>/PongDuRainFall.xml)가 그 변수가 참이면 어느 상태에서든
-- Bob_FallIdle 을 고른다 (조건 개수가 가장 많은 노드가 선택되므로 조건을 반복해 둠).
-- 상태 전이는 건드리지 않으므로 피격/사망/착지 판정은 바닐라 그대로다.
-- 착지/사망/만료 시 변수를 지운다. 기어다니는 좀비·로치는 zombie-crawler 애님셋을 쓰므로
-- 같은 노드를 media/AnimSets/zombie-crawler/<상태>/ 에도 둔다 (바닐라 crawler에는
-- falling 상태 자체가 없어 원래는 엎드린 채 떨어진다).
local FALL_ANIM_VAR     = "PongDuRainFall"
local FALL_ANIM_LOG_MAX = 3     -- 공습 1회당 상세 로그 상한
local _fallAnimLogLeft  = FALL_ANIM_LOG_MAX
local _fallAnimCount    = 0

local function fallAnimOff(z, p)
    if p.anim then
        z:clearVariable(FALL_ANIM_VAR)
        p.anim = false
    end
end

-- ── 낙하산 연출 (Rain_Parachute) ────────────────────────────────────────────
-- 낙하 좀비 등에 펼친 낙하산을 씌우고(ItemVisual, 전 클라 각자 로컬), 소유 클라는
-- 낙하 속도를 PARA_DESCENT(층/초)로 늦춘다. 착지하면 낙하산을 벗긴다.
--  * 모델/텍스처/clothing은 Parachuting Start 모드(Panopticon 외) 에셋을 자체
--    네임스페이스로 복사해 쓴다 (t3_rewards_items.txt PongDuZombieParachute).
--  * 서버 좀비에는 씌우지 않는다 -> 서버가 만드는 시체 인벤토리에 안 들어간다.
--  * 낙하 중 사살: Kill()이 OnZombieDead 전에 itemVisuals를 인벤토리 아이템으로
--    바꾸므로(IsoZombie.DoZombieInventory) OnZombieDead에서 비주얼+아이템을 지운다.
--  * 감속: 소유 클라가 좀비별 목표 높이(p.pz)를 PARA_DESCENT(층/초)로 매 틱 내리고,
--    실제 z를 그 값에 고정한다. 엔진 낙하와 무관하게 일정 속도로 내려오며 절대
--    처음 높이보다 올라가지 않는다. lastFallSpeed 도 매 틱 PARA_DESCENT 로 고정해 착지 데미지가 없다.
--    (아래 2줄은 B41 기록) fallTime도 매 틱 0 -> 착지 시 DoLand가 20
--    미만이라 넘어짐/낙하 데미지 없음.
--    (구버전은 매 틱 lastFallSpeed의 70%를 되올렸는데, 엔진이 그 틱에 실제로 안
--     떨어뜨린 경우에도 lastFallSpeed가 남아 있어 좀비가 계속 위로 떠올랐다 ->
--     대기열 만료(60초) 후 고공에서 추락사. 09-18 실측)
--  * 부착 유지: 원격 좀비는 도착 직후 엔진이 옷(persistent outfit)을 입히며
--    itemVisuals를 통째로 다시 채울 수 있어, 공중에 있는 동안 매 틱 낙하산이
--    남아 있는지 확인하고 없으면 다시 씌운다.
local PARA_ITEM      = "t3chzzkDonation.PongDuZombieParachute"
local PARA_CLOTHING  = "PongDu_ZombieParachute"
local PARA_DESCENT   = 2.4      -- 낙하산 하강 속도 (층/초). 레인 7층 약 3초, 공중투하 14층 약 6초.
                                -- (1.2 에서 2배로 올림: 체공이 너무 길었다. 2026-10-28)
                                -- 2.24(데미지 기준)를 넘으므로 바닥 FREE_FALL_BRAKE_H 층 위부터는
                                -- 아래 LAND_SPEED 로 감속해 착지한다(자유낙하와 같은 방식).
-- 자유낙하 속도 상한 (층/초). 공중에서 보이는 낙하 속도만 정한다.
-- 예전엔 이 값 그대로 착지시켜 넘어짐 연출을 남겼는데, 착지 속도 3.87 이상이면
-- IsoZombie.handleLandingImpact 가 50% 확률로 setFakeDead(true) 를 건다. 죽은척 좀비는
-- ZombieOnGroundState 에서 isFakeDead 동안 일어나지 않아 "시체처럼 굳은 좀비"가 됐다
-- (시체가 아니라 파밍 인벤토리도 안 뜨고, 좀비 삭제로만 지워짐. 2026-10-27 제보).
-- 그래서 바닥 FREE_FALL_BRAKE_H 층 위부터는 LAND_SPEED 로 감속해 착지 속도를
-- noDamageThreshold(약 2.24, FallingConstants: 0.5층 낙하 속도) 아래로 맞춘다
-- -> isDamagingFall=false -> 데미지·넘어짐·죽은척 전부 없음.
local FREE_FALL_CAP    = 4.2
local FREE_FALL_BRAKE_H = 1.0   -- 바닥에서 이 높이(층)부터 감속
-- 착지 속도. updateFalling 이 착지 틱에 중력분(5.0 x dt)을 한 번 더하므로
-- 10fps(dt 0.1)에서도 1.2 + 0.5 = 1.7 < 2.24 로 여유가 있다. 낙하산·자유낙하 공통.
local LAND_SPEED       = 1.2
local LAND_LOG_MAX   = 3        -- 공습 1회당 체력 원복 상세 로그 상한
local _landLogLeft   = LAND_LOG_MAX
local _landRestored  = 0
local _landFakeDeadCleared = 0

-- 공중 수평 위치 고정 (소유 클라). 스폰 직후 좀비는 플레이어를 노리며(setTarget/lunger)
-- 걷는 상태인데, 방향 고정 때문에 처음 바라본 무작위 방향으로 공중에서 계속 걸어
-- 컬럼(반경 안)에서 벗어난 곳에 착지했다. 낙하산으로 체공이 몇 초로 길어지며 드러남.
-- 공중에 있는 동안 처음 본 x,y 로 매 틱 되돌린다 (setForceX/Y = x/next/last 동시 설정).
-- 반경 검증용: 좀비 레인 방식은 발동 위치·반경을 기억해 착지 위치가 원 밖이면 센다.
local _rainCenter    = nil      -- { x, y, r } (좀비 레인 방식만)
local _landCount     = 0
local _landOutside   = 0
local _landMaxDist   = 0

-- 일시정지 보정 (서버 PongDuRainServer.lua 와 같은 기준). 대기열 만료 시각(p.e)과
-- 수송기 그림자 시작 시각(f.t0)이 실시간 기준이라 일시정지만큼 뒤로 민다.
local PAUSE_GAP_MS   = 500
local _lastTickAt    = nil
local PARA_LOG_MAX   = 5        -- 공습 1회당 부착/재부착 상세 로그 상한
local _paraScriptOk  = nil      -- 아이템 스크립트 존재 여부 캐시
local _paraLogLeft   = PARA_LOG_MAX
local _paraStats     = { attach = 0, reattach = 0, detach = 0, noAsset = 0 }

local function paraEnabled()
    return SandboxVars.PongDu.Rain_Parachute
end

-- 낙하산 ItemVisual 이 지금 붙어 있는가
local function chuteHas(z)
    local found = false
    pcall(function()
        local ivs = z:getItemVisuals()
        for i = 0, ivs:size() - 1 do
            local iv = ivs:get(i)
            if iv and iv:getItemType() == PARA_ITEM then found = true; return end
        end
    end)
    return found
end

local function chuteAttach(z)
    if _paraScriptOk == nil then
        local item = getScriptManager():FindItem(PARA_ITEM)
        _paraScriptOk = item ~= nil
        if not _paraScriptOk then
            print("[PongDuRain] WARN parachute item script missing: " .. PARA_ITEM)
        else
            -- 스크립트 -> clothing xml(GUID) -> 모델 연결이 살아있는지 1회 확인
            local okC, ci = pcall(function() return item:getClothingItemAsset() end)
            print("[PongDuRain] parachute asset check clothingItem=" .. tostring(okC and ci ~= nil))
        end
    end
    if not _paraScriptOk then
        _paraStats.noAsset = _paraStats.noAsset + 1
        return false
    end
    local ok, err = pcall(function()
        local iv = ItemVisual.new()
        iv:setItemType(PARA_ITEM)
        iv:setClothingItemName(PARA_CLOTHING)
        z:getItemVisuals():add(iv)
        z:resetModelNextFrame()
    end)
    if not ok then
        print("[PongDuRain] parachute attach FAILED zid=" .. tostring(z:getOnlineID()) .. " err=" .. tostring(err))
    end
    return ok
end

local function chuteDetach(z)
    local removed = 0
    pcall(function()
        local ivs = z:getItemVisuals()
        for i = ivs:size() - 1, 0, -1 do
            local iv = ivs:get(i)
            if iv and iv:getItemType() == PARA_ITEM then
                ivs:remove(iv)
                removed = removed + 1
            end
        end
        if removed > 0 then z:resetModelNextFrame() end
    end)
    return removed
end

-- 반경 표시 (Rain_ShowRadius)
local function showRadiusEnabled()
    return SandboxVars.PongDu.Rain_ShowRadius
end

-- 바닥 반경 마커/효과음은 utils/fx 가 처리한다 (본인 로컬 + 주변 브로드캐스트).
-- 레인 마커는 지속시간 동안 유지 (강령술의 3초와 달리 낙하가 계속되므로).

-- ── 남은시간 표시 패널 (BombardTimerDisplay와 동일 스타일) ─────────────────────
local _rainRemainMs = 0   -- 남은 시간(ms). OnTick에서 실제 경과시간만큼 감산
local _panel     = nil

local RainTimerDisplay = ISPanel:derive("RainTimerDisplay")

function RainTimerDisplay:new()
    local w = getCore():getScreenWidth()
    -- y좌표는 timerStack이 등록 순서에 맞춰 잡아준다(register 전까지는 임시값 0).
    -- 폭/높이는 카운터 패널 공통 규격(utils/timerText)을 따른다.
    local o = ISPanel:new((w - timerText.PANEL_W) / 2, 0,
        timerText.PANEL_W, timerText.PANEL_H)
    setmetatable(o, self)
    self.__index = self
    o:noBackground()
    return o
end

function RainTimerDisplay:render()
    -- 남은 시간에는 서버 준비 대기(SERVER_PREP_MS)가 포함돼 있다. 표시에선 그만큼 빼서
    -- 시작 순간 설정값(예: 30초)이 그대로 보이게 한다. 00:00 은 마지막 1초 동안 표시.
    local totalSec = math.ceil((_rainRemainMs - SERVER_PREP_MS) / 1000)
    if totalSec < 0 then totalSec = 0 end
    local col = colorMap.get("zombie_rain")
    -- 카테고리 이름("좀비 공습")이 아니라 지금 설정된 방식 이름을 쓴다 --
    -- 큐박스 슬롯/호버 툴팁과 같은 이름이 떠야 한다.
    -- 방식 -> 번역키 판정은 utils/labelKey.resolve 한 곳에만 둔다.
    timerText.draw(self, getText(labelKey.resolve("zombie_rain")), totalSec, col)
end

function RainTimerDisplay:update()
    if _rainRemainMs <= 0 then
        timerStack.unregister(self)
        self:removeFromUIManager()
        _panel = nil
    end
end

-- ── 투하 모드: 수송기 그림자 ─────────────────────────────────────────────────
-- 위에서 본 수송기 실루엣(기수가 텍스처 위쪽). 경로 방향으로 회전한 정사각형
-- 네 꼭짓점을 월드 좌표로 잡아 화면에 투영하므로 아이소 시점에 맞게 찌그러진다.
-- renderPoly UV: 1=좌상, 2=우상, 3=우하, 4=좌하 (GenericSpriteRenderState.renderPoly).
local SHADOW_TEX    = getTexture("media/textures/Shadows/shadowPongDuAirdrop.png")
local SHADOW_SIZE   = 52     -- 그림자 한 변 (타일 = m). 날개폭이 텍스처 폭을 채운다. C-17 실기 날개폭 51.5 m 에 맞춤
local SHADOW_ALPHA  = 0.38
local SHADOW_FADE   = 800    -- 등장/퇴장 페이드 (ms)
local SHADOW_TAIL   = 2500   -- 마지막 투하 후 화면 밖으로 빠져나가는 시간 (ms)
local FLIGHT_CULL   = 100    -- 경로 중점에서 (경로 절반 길이 + 이 값)보다 멀면 수신 무시 (타일)
local _flights = {}

-- [B42] UI 좌표(OnPreUIDraw). 월드 -> 화면 변환은 바닐라 isoToScreenX/Y(줌·화면 원점 반영).
local function toScreen(x, y)
    return isoToScreenX(0, x, y, 0), isoToScreenY(0, x, y, 0)
end

-- 수송기 현재 위치와 페이드 계수(0~1). 비행이 끝났으면 nil.
-- 진행률: prep 시점에 A(0), prep+dur 시점에 B(1) (서버 스폰 시각과 같은 식).
-- 범위 밖은 연장선으로 외삽 -- 시작 전/도착 후에도 같은 속도로 날아간다.
local function flightState(f, now)
    local t = now - f.t0
    local endT = f.prep + f.dur + SHADOW_TAIL
    if t > endT then return nil end
    local frac = (t - f.prep) / f.dur
    local k = 1
    if t < SHADOW_FADE then k = t / SHADOW_FADE end
    if endT - t < SHADOW_FADE then k = k * (endT - t) / SHADOW_FADE end
    if k < 0 then k = 0 end
    return f.ax + (f.bx - f.ax) * frac, f.ay + (f.by - f.ay) * frac, k
end

-- [B42] OnPostFloorLayerDraw 는 구 렌더러(IsoCell.renderInternal)에서만 발화하고, B42 기본
-- FBO 렌더러(FBORenderCell.renderInternal, PerformanceSettings.fboRenderChunk=true)에서는
-- 아예 불리지 않아 그림자가 안 그려졌다. OnPreUIDraw(월드 렌더 후, UI 전)로 옮긴다.
-- 대가: 바닥 위가 아니라 월드 전체 위에 그려져 캐릭터·차량도 그림자에 덮인다
-- (반투명 그림자라 실제 그림자처럼 보인다).
-- [Viewpoint] 1·3인칭(Viewpoint 3D 시점)에서는 그리지 않는다. 아이소 화면 좌표로 그린 2D 그림자가
-- 3D 화면과 어긋난 위치에 뜬다. 그 시점에서 기체(차량)는 Viewpoint 가 3D 모델로 그리고
-- 차량 그림자 패스로 실제 그림자를 드리운다(utils/viewpointView.lua).
local _shadowHiddenLogged = false
local function drawFlights()
    if #_flights == 0 then return end
    if not SHADOW_TEX then return end
    if vpView.isPerspective() then
        if not _shadowHiddenLogged then
            _shadowHiddenLogged = true
            print("[PongDuRain] airdrop shadow hidden (viewpoint " .. vpView.mode() .. " view)")
        end
        return
    end
    _shadowHiddenLogged = false
    -- OnPreUIDraw 는 일시정지 중에도 매 프레임 불린다. 마지막 틱 이후 PAUSE_GAP_MS 가 지났으면
    -- (일시정지 중, 또는 재개 직후 OnTick 이 시각을 밀기 전) 마지막 틱 시각에 멈춰 그린다.
    local now = getTimestampMs()
    if _lastTickAt and now - _lastTickAt > PAUSE_GAP_MS then now = _lastTickAt end
    local renderer = getRenderer()
    for i = 1, #_flights do
        local f = _flights[i]
        local mx, my, k = flightState(f, now)
        if mx then
            local a = SHADOW_ALPHA * k
            local h  = SHADOW_SIZE / 2
            local fx_, fy_ = f.ux * h, f.uy * h      -- 기수 방향
            local rx, ry   = -f.uy * h, f.ux * h     -- 오른쪽 날개 방향
            local x1, y1 = toScreen(mx + fx_ - rx, my + fy_ - ry)   -- 기수-왼쪽
            local x2, y2 = toScreen(mx + fx_ + rx, my + fy_ + ry)   -- 기수-오른쪽
            local x3, y3 = toScreen(mx - fx_ + rx, my - fy_ + ry)   -- 꼬리-오른쪽
            local x4, y4 = toScreen(mx - fx_ - rx, my - fy_ - ry)   -- 꼬리-왼쪽
            renderer:renderPoly(SHADOW_TEX, x1, y1, x2, y2, x3, y3, x4, y4, 0, 0, 0, a)
        end
    end
end
Events.OnPreUIDraw.Add(drawFlights)

-- ── 투하 모드: 수송기 엔진음 ─────────────────────────────────────────────────
-- 화력지원 헬기 로터음(firesupport.lua)과 같은 방식:
--  * 로컬 플레이어 emitter 로 로컬 재생 (네트워크 전송 없음 -- Flight 를 받은 클라가 각자 튼다)
--  * 정지는 재생한 그 emitter 로 핸들 + 이름 둘 다 (플레이어 교체 시 잔존 방지)
-- 실제 제트 수송기 통과음에 가깝게 세 가지를 매 틱 갱신한다 (가장 크게 들리는 비행 1개 기준):
--  1) 앞/뒤 음색 크로스페이드: 가까이 다가올수록 밝은 굉음(1~4kHz 와 지글거리는 크래클),
--     멀어지면 저음 위주의 어두운 굉음이 된다(실녹음 레퍼런스의 접근·이탈 구간 스펙트럼).
--     다가올 때는 pongdu_airdrop_plane(앞), 지나간 뒤에는 pongdu_airdrop_plane_rear(뒤)로
--     넘어간다. 두 루프를 같이 틀고 볼륨만 나눈다.
--  2) 도플러: 다가올 때 음이 높고 지나가면 낮아진다. 게임 속 비행 속도(초당 4~12칸)로는
--     변화가 3% 남짓이라 안 들리므로, 실제 C-17 투하 속도(약 130노트 = 65 m/s)로 계산한다.
--  3) 거리 감쇠: 고도를 포함한 3D 거리 기준 1/거리. 머리 위에서 최대, PLANE_HEAR 에서 0.
--  4) 날카로운 금속음: 실녹음 21.5~23.3초(머리 위를 지나는 순간과 직후)에 팬 날개 통과음이
--     솟는다. 기본음 약 1776 Hz 와 배음, 특히 2배음 3.55kHz 가 그 구간 에너지의 약 9%.
--     3.52~3.58kHz 에 선이 여럿(엔진 4발 회전수 1~2% 차) -> 맥놀이가 금속성으로 들린다.
--     별도 루프 pongdu_airdrop_plane_tear 를 근접 계수^3.5 x 뒤쪽 가중(4*(1-front)^2, 최대 1)으로
--     키운다. 통과 모의 합성에서 3.5kHz 대역 비율: 접근 -22 dB(실녹음 -21.5), 머리 위 -9.6(-10.3),
--     이탈 30칸 -26(-24). 도플러 피치는 다른 루프와 같이 걸려 지나가며 음이 떨어진다.
-- 음원은 합성 루프(12초, 무이음). 사용자가 준 C-17 실녹음(32초)의 옥타브 스펙트럼을
-- 2 dB 안팎으로 맞추고, 실녹음에서 측정한 0.6~1.7 Hz 공기 요동과 고역 크래클(첨도 약 5~6)을 넣었다.
-- 실녹음에 뚜렷한 팬 톤(휘이잉)은 없어서 넣지 않았다. 실녹음 자체는 저작권 때문에 쓰지 않는다.
-- 금속음 루프는 실녹음 21.5~23.3초의 팬 톤(1776 Hz 계열, 배음 비율·4발 회전수 차)에 맞췄다.
local PLANE_ALIAS      = "pongdu_airdrop_plane"        -- 앞쪽 음색 (접근·통과 밝은 굉음)
local PLANE_ALIAS_REAR = "pongdu_airdrop_plane_rear"   -- 뒤쪽 음색 (이탈 어두운 저음 굉음)
local PLANE_ALIAS_TEAR = "pongdu_airdrop_plane_tear"   -- 날카로운 금속음 (팬 날개 통과음, 머리 위·직후만)
local PLANE_ALIASES    = { PLANE_ALIAS, PLANE_ALIAS_REAR, PLANE_ALIAS_TEAR }
local PLANE_FLOORS     = 15       -- 수송기 고도 (층). 아래 PLANE_FLY_ALT 와 공용
local PLANE_ALT_M      = PLANE_FLOORS * 2.46   -- 1 타일 = 1 m 기준 고도
local PLANE_VOL_NEAR   = 0.60     -- 머리 위 통과 시
local PLANE_HEAR       = 90       -- 이 거리(타일, 3D)부터 들리기 시작 (경로 끝 D = 반경 + 50)
local PLANE_TEAR_GAIN  = 0.5      -- 금속음 볼륨 배율 (위 4) 주석의 실녹음 맞춤값)
local SOUND_C          = 343      -- 음속 (m/s)
local DOPPLER_V        = 65       -- 도플러 계산용 비행 속도 (m/s)
-- 투하가 끝난 뒤에도 소리는 이만큼 더 이어지며 꺼진다 (ms). 수송기는 같은 속도로 계속 멀어지고
-- (경로 연장선), 볼륨도 이 시간 동안 코사인 곡선으로 0 까지 내려간다. 지속시간 10초면 소리는
-- 15초, 5초면 10초 (준비 지연 동안 다가오는 소리는 별도). 그림자(SHADOW_TAIL)보다 길어서
-- 비행 항목은 소리가 끝날 때 지운다.
local PLANE_SOUND_TAIL = 5000
local _planeSnd = nil   -- { em = emitter, h = { [alias] = 핸들 }, v = { [alias] = 마지막 볼륨 }, p = 마지막 피치 }
local _planeSwept = false

local function planeSoundStop(reason)
    local s = _planeSnd
    if s and s.em then
        for _, alias in ipairs(PLANE_ALIASES) do
            local h = s.h[alias]
            if h then pcall(function() s.em:stopSound(h) end) end
            pcall(function() s.em:stopSoundByName(alias) end)
        end
    end
    local pl = getSpecificPlayer(0)
    if pl then
        for _, alias in ipairs(PLANE_ALIASES) do
            pcall(function() pl:getEmitter():stopSoundByName(alias) end)
        end
    end
    if s then
        print("[PongDuRain] airdrop plane sound stopped (" .. tostring(reason) .. ")")
    end
    _planeSnd = nil
end

local function planeSoundEnsure()
    if _planeSnd then return end
    local pl = getSpecificPlayer(0)
    if not pl then return end
    local okE, em = pcall(function() return pl:getEmitter() end)
    if not okE or not em then return end
    local hs, n, info = {}, 0, ""
    for _, alias in ipairs(PLANE_ALIASES) do
        local ok, h = pcall(function() return em:playSound(alias) end)
        if ok and h and h ~= 0 then
            hs[alias] = h
            n = n + 1
            pcall(function() em:setVolume(h, 0) end)
        end
        info = info .. " " .. alias .. "=" .. tostring(hs[alias] ~= nil)
    end
    if n == 0 then
        print("[PongDuRain] airdrop plane sound start FAILED")
        return
    end
    _planeSnd = { em = em, h = hs, v = {}, logged = false }
    print("[PongDuRain] airdrop plane sound started" .. info)
end

-- 비행 f 의 현재 소리 파라미터: 볼륨(0~1), 앞쪽 비율(0~1), 피치, 근접 계수(0~1).
-- 소리가 끝난 비행이면 nil (그림자보다 늦게, 투하 종료 + PLANE_SOUND_TAIL 에 끝난다).
local function planeSoundParams(f, now, px, py)
    local t = now - f.t0
    local dropEnd = f.prep + f.dur
    if t > dropEnd + PLANE_SOUND_TAIL then return nil end
    -- 위치는 그림자와 같은 식(범위 밖은 연장선으로 외삽 -> 투하 후에도 계속 멀어진다)
    local frac = (t - f.prep) / f.dur
    local mx = f.ax + (f.bx - f.ax) * frac
    local my = f.ay + (f.by - f.ay) * frac
    local k = 1
    if t < SHADOW_FADE then k = t / SHADOW_FADE end
    if t > dropEnd then
        local u = (t - dropEnd) / PLANE_SOUND_TAIL
        k = k * 0.5 * (1 + math.cos(math.pi * u))
    end
    if k < 0 then k = 0 end
    local rx, ry = px - mx, py - my                     -- 수송기 -> 플레이어
    local d3 = math.sqrt(rx * rx + ry * ry + PLANE_ALT_M * PLANE_ALT_M)
    local near = PLANE_ALT_M / d3
    local edge = PLANE_ALT_M / PLANE_HEAR
    local q = (near - edge) / (1 - edge)
    if q < 0 then q = 0 elseif q > 1 then q = 1 end
    local v = PLANE_VOL_NEAR * q * k
    -- 진행 방향과 플레이어 방향 사이 코사인 (3D). +1 = 정면에서 다가옴, -1 = 지나감
    local c = (rx * f.ux + ry * f.uy) / d3
    local front = (1 + c) / 2
    local pitch = SOUND_C / (SOUND_C - DOPPLER_V * c)
    return v, front, pitch, q * k
end

-- 볼륨은 값이 실제로 바뀔 때만 보낸다(아래 setPitch 주석과 같은 이유).
local function planeSetVol(s, alias, vol)
    local h = s.h[alias]
    if not h then return end
    local last = s.v[alias]
    if last and math.abs(vol - last) < 0.005 then return end
    s.v[alias] = vol
    pcall(function() s.em:setVolume(h, vol) end)
end

-- 매 틱: 끝난 비행 정리 + 엔진음 볼륨·음색·피치 갱신
local function planeTick()
    -- 로드 직후 1회: 핫리로드로 핸들을 잃은 루프 잔존분을 이름으로 정리
    if not _planeSwept then
        local pl = getSpecificPlayer(0)
        if pl then
            _planeSwept = true
            for _, alias in ipairs(PLANE_ALIASES) do
                pcall(function() pl:getEmitter():stopSoundByName(alias) end)
            end
        end
    end
    if #_flights == 0 then
        if _planeSnd then planeSoundStop("no flight") end
        return
    end
    local now = getTimestampMs()
    -- 재개 직후 첫 틱: 이 핸들러가 onTick(시각 보정)보다 먼저 돌아 보정 전 시각으로
    -- 비행이 끝난 것으로 판정돼 지워졌다. 간격이 크면 이번 틱은 건너뛴다(_lastTickAt 은 아직 이전 틱 값).
    if _lastTickAt and now - _lastTickAt > PAUSE_GAP_MS then return end
    local pl = getSpecificPlayer(0)
    local px, py = 0, 0
    if pl then px, py = pl:getX(), pl:getY() end
    local bv, bfront, bpitch, bq = nil, 0.5, 1, 0
    for i = #_flights, 1, -1 do
        local v, front, pitch, q = planeSoundParams(_flights[i], now, px, py)
        if not v then
            table.remove(_flights, i)
            print("[PongDuRain] airdrop flight done (shadow + sound tail)")
        elseif not bv or v > bv then
            bv, bfront, bpitch, bq = v, front, pitch, q
        end
    end
    if not bv then
        if _planeSnd then planeSoundStop("flights done") end
        return
    end
    planeSoundEnsure()
    local s = _planeSnd
    if not s then return end
    -- 등전력 크로스페이드 (합친 크기가 중간에 꺼지지 않게)
    local vf = bv * math.sqrt(bfront)
    local vr = bv * math.sqrt(1 - bfront)
    -- 금속음: 근접 계수^3.5 (머리 위에서만) x 뒤쪽 가중 (다가올 땐 약하고 머리 위부터 최대)
    local back = 4 * (1 - bfront) * (1 - bfront)
    if back > 1 then back = 1 end
    local tw = bq ^ 3.5 * back
    local vt = bv * PLANE_TEAR_GAIN * tw
    -- 값이 실제로 바뀔 때만 보낸다. 엔진이 setPitch 마다 "Set pitch for Instance" 를
    -- 로그에 남겨 매 틱 호출하면 한 세션에 7천 줄이 쌓였다(2026-10-27 로그). 들리는 차이가
    -- 없는 범위(피치 0.3%, 볼륨 0.005)는 건너뛴다.
    if not s.p or math.abs(bpitch - s.p) >= 0.003 then
        s.p = bpitch
        for _, alias in ipairs(PLANE_ALIASES) do
            local h = s.h[alias]
            if h then pcall(function() s.em:setPitch(h, bpitch) end) end
        end
    end
    planeSetVol(s, PLANE_ALIAS, vf)
    planeSetVol(s, PLANE_ALIAS_REAR, vr)
    planeSetVol(s, PLANE_ALIAS_TEAR, vt)
    if not s.logged and bv > 0.3 then
        s.logged = true
        print(string.format("[PongDuRain] airdrop plane sound near vol=%.2f front=%.2f pitch=%.3f tear=%.2f", bv, bfront, bpitch, vt))
    end
end
Events.OnTick.Add(planeTick)

-- ── 투하 모드: 실체 수송기 (Base.PongDuC17) ─────────────────────────────────
-- 서버(PongDuRainServer.lua planeSpawn)가 플레이어 근처 구간에서만 차량을 띄우고 PlaneStart 로
-- vid / 파일럿(onlineID) / 경로(A->B) / 현재 진행률(frac) / 비행시간(dur) 을 보낸다.
-- 파일럿 클라만 매 틱 경로 좌표로 옮긴다(화력지원 헬기 heliMoveTo 와 같은 setWorldTransform).
-- 다른 클라는 엔진 차량 보간으로 받는다. 진행률 식은 그림자(flightState)와 같아서
-- 기체와 그림자가 같은 지점을 지난다.
-- 고도: 물리 y 단위, iso 층 = y / 2.46 (firesupport.lua HELI_FLY_ALT 주석). 15층(약 37 m).
-- 투하 좀비 낙하 시작 높이(서버 AIRDROP_DROP_Z = 14층)보다 한 층 위.
-- 고정 아이소 시점이라 1층 올릴 때마다 기체가 화면에서 지면 6칸만큼 위로 밀린다
-- (IsoUtils.YToScreen: 층당 96, 타일당 16). 더 올리면 기체가 화면에 들어오는 경로가 줄어든다.
local PLANE_SCRIPT   = "Base.PongDuC17"
local PLANE_FLY_ALT  = PLANE_FLOORS * 2.46   -- PLANE_FLOORS 는 엔진음 절에서 정의
local PLANE_YAW_OFF  = 0        -- fbx 기수 방향 보정(도). 기수가 거꾸로 보이면 180
local _planes = {}              -- [vid] = { pilot, ax, ay, bx, by, frac0, dur, f1, t0, amPilot }

local function planeFind(vid)
    local ok, v = pcall(function() return getVehicleById(vid) end)
    if not ok or not v then return nil end
    -- VehicleID 는 재활용되므로 스크립트명으로 거른다 (firesupport.lua findHeliVehicle 참고)
    local okS, sn = pcall(function() return v:getScriptName() end)
    if okS and sn == PLANE_SCRIPT then return v end
    return nil
end

local function planePilotTick()
    local now = getTimestampMs()
    local expired = nil
    for vid, pl in pairs(_planes) do
        local frac = pl.frac0 + (now - pl.t0) / pl.dur
        if frac > pl.f1 + 0.2 then
            -- 서버 PlaneStop 유실 대비 자체 정리 (차량 제거는 서버 몫). 순회 중 삭제를 피해 모아 둔다.
            expired = expired or {}
            expired[#expired + 1] = vid
        elseif pl.amPilot then
            local v = planeFind(vid)
            if v then
                if pl.lostAt then
                    print(string.format("[PongDuRain] plane vehicle acquired vid=%s after %dms", tostring(vid), now - pl.lostAt))
                    pl.lostAt = nil
                end
                local wx = pl.ax + (pl.bx - pl.ax) * frac
                local wy = pl.ay + (pl.by - pl.ay) * frac
                -- 기수 방향은 매 틱 다시 건다. 한 번만 걸면 물리 권한(authorizationChanged)이 오기 전
                -- 서버 차량 갱신이 회전을 스폰 방향(N)으로 되돌릴 수 있고, 아래 이동은 현재 회전을
                -- 그대로 쓰므로 그 뒤로 기체가 옆으로 난다(2026-10-27 제보, 원인은 추정).
                -- 화력지원 헬기도 매 틱 setAngles 를 부른다(firesupport.lua heliShadowRefreshTick).
                -- setAngles 는 정수 각도가 같으면 아무것도 안 한다(BaseVehicle.setAngles).
                if not pl.yaw then
                    pl.yaw = math.deg(math.atan2(pl.bx - pl.ax, pl.by - pl.ay)) + PLANE_YAW_OFF
                end
                local okY, errY = pcall(function() v:setAngles(0, pl.yaw, 0) end)
                if not pl.yawSet then
                    pl.yawSet = true
                    print(string.format("[PongDuRain] plane yaw %.1f ok=%s", pl.yaw, tostring(okY))
                        .. (okY and "" or (" err=" .. tostring(errY))))
                end
                local ok, err = pcall(function()
                    local tr, origin = vxf.get(v)
                    origin:set(origin:x() + (wx - v:getX()), PLANE_FLY_ALT, origin:z() + (wy - v:getY()))
                    v:setWorldTransform(tr)
                end)
                if not ok and not pl.moveErr then
                    pl.moveErr = true
                    print("[PongDuRain] plane move FAILED vid=" .. tostring(vid) .. " err=" .. tostring(err))
                end
            elseif not pl.lostAt then
                pl.lostAt = now
            end
        end
    end
    if expired then
        for _, vid in ipairs(expired) do
            _planes[vid] = nil
            print("[PongDuRain] plane local entry expired vid=" .. tostring(vid))
        end
    end
end
Events.OnTick.Add(planePilotTick)

-- ── 착지 처리 대기열 ──────────────────────────────────────────────────────────
-- [onlineID] = { k=특좀 종류(nil=일반), e=만료(ms), para=낙하산 대상,
--               chute=낙하산 부착 여부, pz=감속 목표 높이, ang=고정할 방향(도) }
local _pending      = {}
local _pendingCount = 0
local _sweepAcc     = 0

-- 대기열 키. MP 는 onlineID, SP 는 좀비 객체 자체.
-- SP 는 onlineID 가 전부 -1 이라 키로 쓰면 모든 좀비가 한 항목을 공유한다
-- (특좀 스폰 즉사 버그와 같은 원인, features/mutantspawn.lua zkey 참고).
-- 서버 SP 브리지(PongDuRainServer.lua toClients)가 RainMark 항목에 obj 를 실어 보낸다.
local function zkey(zombie)
    if isClient() or isServer() then return zombie:getOnlineID() end
    return zombie
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= "PongDuRain" then return end

    -- ── 컬럼 공중 스퀘어 생성 (서버 스폰 전 선행) ──
    if command == "Prep" then
        local cols = args and args["cols"]
        if type(cols) ~= "table" then return end
        local dropZ = tonumber(args["z"]) or 4
        local cell  = getCell()
        if not cell then return end
        -- [계측] 클라 로컬 생성 소요시간 + 성공/스킵 카운트 (서버 로그와 대조용)
        local t0 = getTimestampMs()
        local created, reused, failed = 0, 0, 0
        for _, c in pairs(cols) do
            local x = c and tonumber(c["x"])
            local y = c and tonumber(c["y"])
            if x and y then
                if cell:getGridSquare(x, y, dropZ) then
                    reused = reused + 1
                else
                    local ok = pcall(function() cell:createNewGridSquare(x, y, dropZ, true) end)
                    if ok and cell:getGridSquare(x, y, dropZ) then
                        created = created + 1
                    else
                        failed = failed + 1
                    end
                end
            end
        end
        print("[PongDuRain] client prep ms=" .. tostring(getTimestampMs() - t0)
            .. " created=" .. tostring(created) .. " reused=" .. tostring(reused)
            .. " failed=" .. tostring(failed))
        return
    end

    -- ── 투하 모드 비행 정보 (그림자 연출) ──
    if command == "Flight" then
        local ax, ay = tonumber(args["ax"]), tonumber(args["ay"])
        local bx, by = tonumber(args["bx"]), tonumber(args["by"])
        local dur    = tonumber(args["dur"])
        local ldx, ldy = (bx or 0) - (ax or 0), (by or 0) - (ay or 0)
        local len = math.sqrt(ldx * ldx + ldy * ldy)
        if not (ax and ay and bx and by and dur) or dur <= 0 or len < 1 then
            print("[PongDuRain] airdrop flight ignored (bad args)")
            return
        end
        local me = getPlayer()
        -- 발동자 본인: 남은시간 패널 = 수송기 체공 시간(A'->B', 서버 flyMs = 지속시간 설정값).
        -- 좀비가 떨어지는 구간은 그중 A->B(가운데 1/3)뿐이지만 타이머는 수송기가 떠 있는 동안을
        -- 센다. 요청 시점에 켠 dur 와 같은 값이지만 서버 계산을 기준으로 다시 맞춘다. 패널 표시는
        -- SERVER_PREP_MS 를 빼므로 서버 prep 을 더한다(둘은 같은 값 1000ms).
        local pid = tonumber(args["pid"])
        if me and pid and me:getOnlineID() == pid then
            local totalMs = dur + (tonumber(args["prep"]) or SERVER_PREP_MS)
            if _rainRemainMs < totalMs then _rainRemainMs = totalMs end
            print("[PongDuRain] client timer set to airdrop flight time flyMs=" .. tostring(math.floor(dur))
                .. " remainMs=" .. tostring(math.floor(_rainRemainMs)))
        end
        if me then
            local dx = me:getX() - (ax + bx) / 2
            local dy = me:getY() - (ay + by) / 2
            local lim = len / 2 + FLIGHT_CULL
            if dx * dx + dy * dy > lim * lim then return end
        end
        if not SHADOW_TEX then
            print("[PongDuRain] WARN airdrop shadow texture missing")
        end
        _flights[#_flights + 1] = {
            ax = ax, ay = ay, bx = bx, by = by,
            ux = ldx / len, uy = ldy / len,   -- 기수 방향 (단위벡터)
            prep = tonumber(args["prep"]) or SERVER_PREP_MS,
            dur = dur,
            t0 = getTimestampMs(),
        }
        print(string.format("[PongDuRain] airdrop shadow start A=(%.0f,%.0f) B=(%.0f,%.0f) durMs=%.0f",
            ax, ay, bx, by, dur))
        return
    end

    if command == "PlaneStart" then
        local vid = tonumber(args and args["vid"])
        if not vid then return end
        local me = getPlayer()
        local myId = me and me:getOnlineID()
        local pilot = tonumber(args["pilot"])
        _planes[vid] = {
            ax = tonumber(args["ax"]), ay = tonumber(args["ay"]),
            bx = tonumber(args["bx"]), by = tonumber(args["by"]),
            frac0 = tonumber(args["frac"]) or 0, dur = tonumber(args["dur"]) or 30000,
            f1 = tonumber(args["f1"]) or 1, t0 = getTimestampMs(),
            amPilot = (myId ~= nil and pilot ~= nil and pilot == myId),
        }
        print(string.format("[PongDuRain] plane start vid=%d pilot=%s amPilot=%s frac=%.2f",
            vid, tostring(pilot), tostring(_planes[vid].amPilot), _planes[vid].frac0))
        return
    end
    if command == "PlaneStop" then
        local vid = tonumber(args and args["vid"])
        if vid and _planes[vid] then
            _planes[vid] = nil
            print("[PongDuRain] plane stop vid=" .. tostring(vid))
        end
        return
    end

    if command ~= "RainMark" then return end
    local zeds = args and args["zeds"]
    if type(zeds) ~= "table" then return end
    local sender = tostring(args["sender"] or "")   -- 세션 공통 (이름표용)
    local para   = args["para"] == true               -- 세션 공통 (낙하산 연출)
    local now = getTimestampMs()
    for _, e in pairs(zeds) do
        local id  = e and tonumber(e["id"])
        local obj = e and e["obj"]
        local key = obj or id
        if key then
            if not _pending[key] then _pendingCount = _pendingCount + 1 end
            local kind = e["k"]
            _pending[key] = {
                k = kind,
                e = now + PENDING_MS,
                para = para,     -- 낙하산 대상
                chute = false,   -- 이 클라에서 낙하산을 씌웠는지
            }
            -- 특좀: 도네 특좀(MutantMark)과 같은 대기열에 등록 -> OnZombieUpdate
            -- 적용기가 onlineID로 매칭해 능력/체력/이름표를 입힌다 (전 클라 각자).
            -- SP(obj 있음)는 건너뛴다: id 가 -1 이라 mark 하면 모든 좀비가 특좀이 되고,
            -- 서버가 같은 객체에 심은 modData PuppetMutant/PuppetMutantZid(-1) 경로로
            -- 적용기가 이미 정확히 매칭한다.
            if kind and not obj then mutantspawn.mark(id, kind, sender) end
        end
    end
end)

-- 낙하산 공습 결과 요약 (대기열이 비는 시점에 1회)
local function paraStatsFlush()
    if _fallAnimCount > 0 then
        print("[PongDuRain] fall anim summary set=" .. _fallAnimCount
            .. " landHpRestored=" .. _landRestored
            .. " fakeDeadCleared=" .. _landFakeDeadCleared
            .. " landed=" .. _landCount .. " landOutsideRadius=" .. _landOutside
            .. string.format(" landMaxDist=%.1f", _landMaxDist))
        _landRestored    = 0
        _landFakeDeadCleared = 0
        _landCount       = 0
        _landOutside     = 0
        _landMaxDist     = 0
        _landLogLeft     = LAND_LOG_MAX
        _fallAnimCount   = 0
        _fallAnimLogLeft = FALL_ANIM_LOG_MAX
    end
    local s = _paraStats
    if s.attach + s.reattach + s.detach + s.noAsset == 0 then return end
    print("[PongDuRain] parachute summary attach=" .. s.attach .. " reattach=" .. s.reattach
        .. " detach=" .. s.detach .. " noAsset=" .. s.noAsset)
    _paraStats = { attach = 0, reattach = 0, detach = 0, noAsset = 0 }
    _paraLogLeft = PARA_LOG_MAX
end

local function onTick()
    local dtMs = deltaTime.ms()
    local tNow = getTimestampMs()
    local gap  = _lastTickAt and (tNow - _lastTickAt) or 0
    _lastTickAt = tNow
    if gap > PAUSE_GAP_MS and (_pendingCount > 0 or #_flights > 0) then
        for _, p in pairs(_pending) do p.e = p.e + gap end
        for i = 1, #_flights do _flights[i].t0 = _flights[i].t0 + gap end
        for _, pl in pairs(_planes) do pl.t0 = pl.t0 + gap end
        print(string.format("[PongDuRain] tick gap %dms (pause?) -> pending/flights shifted", gap))
    end
    -- ① 타이머 감산 (패널 update()가 0에서 자가 제거). 프레임 수가 아닌 실제 경과시간.
    if _rainRemainMs > 0 then
        _rainRemainMs = _rainRemainMs - dtMs
        if _rainRemainMs < 0 then _rainRemainMs = 0 end
    end

    -- ② 착지 스캔 (대기 항목 있을 때만)
    if _pendingCount == 0 then return end
    local now  = getTimestampMs()
    local cell = getCell()
    local zl   = cell and cell:getZombieList()
    if zl then
        for i = 0, zl:size() - 1 do
            local z   = zl:get(i)
            local id  = z and z:getOnlineID()
            local key = z and zkey(z)
            local p   = key and _pending[key]
            if p then
                local zz = z:getZ()
                if now > p.e then
                    fallAnimOff(z, p)
                    if p.chute then
                        chuteDetach(z)
                        print("[PongDuRain] WARN parachute expired in air zid=" .. tostring(id)
                            .. " z=" .. tostring(zz))
                    end
                    _pending[key] = nil
                    _pendingCount = _pendingCount - 1
                elseif zz > 0.05 and not z:isDead() then
                    -- ── 공중 ──
                    -- 방향 고정 (전 클라): 처음 본 방향을 매 틱 되돌린다
                    if not p.ang then p.ang = z:getDirectionAngle() end
                    z:setDirectionAngle(p.ang)
                    -- 낙하 속도 고정 (소유 클라, 위 [B42 낙하 판정] 절). 낙하산은 PARA_DESCENT,
                    -- 자유낙하는 FREE_FALL_CAP 을 넘지 않게 한다. 넘어짐(bHardFall)·죽은척은
                    -- 엔진이 착지 속도로 직접 정하므로 Lua 가 변수를 세우지 않는다.
                    -- 기어다니는 좀비·로치도 공중에서는 Y자 낙하 자세라 낙하산을 그대로 씌운다.
                    local crawl = z:isCrawling() or p.k == "roach"
                    local usePara = p.para
                    -- 낙하 자세 고정 (전 클라, 기어다니는 좀비 포함): 매 틱 세운다
                    -- (엔진이 변수를 지워도 복구)
                    z:setVariable(FALL_ANIM_VAR, true)
                    if not p.anim then
                        p.anim = true
                        _fallAnimCount = _fallAnimCount + 1
                        if _fallAnimLogLeft > 0 then
                            _fallAnimLogLeft = _fallAnimLogLeft - 1
                            print(string.format("[PongDuRain] fall anim on zid=%d z=%.2f state=%s crawl=%s remote=%s",
                                id, zz, tostring(z:getActionStateName()), tostring(crawl),
                                tostring(PongDuZombieId.IsRemote(z))))
                        end
                    end
                    if not PongDuZombieId.IsRemote(z) then
                        if not p.hp then p.hp = z:getHealth() end
                        -- 수평 위치 고정 (위 _rainCenter 절)
                        if not p.ax then p.ax, p.ay = z:getX(), z:getY() end
                        if z:getX() ~= p.ax or z:getY() ~= p.ay then
                            z:setForceX(p.ax)
                            z:setForceY(p.ay)
                        end
                    end
                    -- 낙하 속도 (전 클라). 착지 판정(updateFalling -> DoLand)은 각 클라가 자기
                    -- lastFallSpeed 로 로컬에서 하므로 원격 좀비도 같이 묶어야 그 클라에서 안 넘어진다.
                    local h = zz
                    pcall(function() h = z:getHeightAboveFloor() end)
                    if usePara then
                        -- 낙하산: 공중에선 PARA_DESCENT, 바닥 FREE_FALL_BRAKE_H 층 위부터 LAND_SPEED
                        if h < FREE_FALL_BRAKE_H then
                            z:setLastFallSpeed(LAND_SPEED)
                        else
                            z:setLastFallSpeed(PARA_DESCENT)
                        end
                    else
                        if h < FREE_FALL_BRAKE_H then
                            if z:getLastFallSpeed() > LAND_SPEED then z:setLastFallSpeed(LAND_SPEED) end
                        elseif z:getLastFallSpeed() > FREE_FALL_CAP then
                            z:setLastFallSpeed(FREE_FALL_CAP)
                        end
                    end
                    if usePara then
                        -- 부착/재부착: 엔진이 옷을 다시 입히며 지웠으면 다시 씌운다
                        if not chuteHas(z) then
                            if chuteAttach(z) then
                                if p.chute then
                                    _paraStats.reattach = _paraStats.reattach + 1
                                else
                                    _paraStats.attach = _paraStats.attach + 1
                                end
                                if _paraLogLeft > 0 then
                                    _paraLogLeft = _paraLogLeft - 1
                                    print(string.format("[PongDuRain] parachute %s zid=%d z=%.2f remote=%s",
                                        p.chute and "REATTACH" or "attach", id, zz,
                                        tostring(PongDuZombieId.IsRemote(z))))
                                end
                                p.chute = true
                            end
                        end
                        -- 감속 (소유 클라만): 목표 높이를 일정 속도로 내리고 z를 그 이하로 고정.
                        -- 목표는 절대 올라가지 않으므로 좀비가 떠오를 수 없다.
                        if not PongDuZombieId.IsRemote(z) then
                            if not p.pz or p.pz > zz + 1 then p.pz = zz end
                            p.pz = p.pz - PARA_DESCENT * dtMs / 1000
                            if p.pz < 0 then p.pz = 0 end
                            if zz < p.pz then
                                -- 엔진 낙하가 목표보다 빨랐다 -> 목표 높이로 되돌림 (감속)
                                z:setZ(p.pz)
                            end
                        end
                    end
                else
                    -- ── 착지 또는 사망 ──
                    fallAnimOff(z, p)
                    -- 착지 위치 검증 (좀비 레인 방식, 공중에서 위치를 잡아둔 좀비만)
                    if p.ax and _rainCenter and not z:isDead() then
                        _landCount = _landCount + 1
                        local dx, dy = z:getX() - _rainCenter.x, z:getY() - _rainCenter.y
                        local lim = _rainCenter.r + 1
                        local d = math.sqrt(dx * dx + dy * dy)
                        if d > _landMaxDist then _landMaxDist = d end
                        if dx * dx + dy * dy > lim * lim then
                            _landOutside = _landOutside + 1
                            if _landLogLeft > 0 then
                                _landLogLeft = _landLogLeft - 1
                                print(string.format("[PongDuRain] WARN landed outside radius zid=%d d=%.1f r=%d air=(%.1f,%.1f) land=(%.1f,%.1f)",
                                    id, math.sqrt(dx * dx + dy * dy), _rainCenter.r, p.ax, p.ay, z:getX(), z:getY()))
                            end
                        end
                    end
                    -- 안전망: 그래도 죽은척이 걸렸으면 푼다 (전 클라). fakeDead 가 꺼지면
                    -- ZombieOnGroundState 가 바닐라 경로로 일으켜 세운다.
                    if not z:isDead() and z:isFakeDead() then
                        z:setFakeDead(false)
                        _landFakeDeadCleared = _landFakeDeadCleared + 1
                        print(string.format("[PongDuRain] WARN fake-dead cleared on landing zid=%d para=%s remote=%s",
                            id, tostring(p.para), tostring(PongDuZombieId.IsRemote(z))))
                    end
                    -- 착지 데미지 원복 안전망 (소유 클라, FREE_FALL_CAP 참고)
                    if p.hp and not z:isDead() and not PongDuZombieId.IsRemote(z)
                        and z:getHealth() < p.hp then
                        if _landLogLeft > 0 then
                            _landLogLeft = _landLogLeft - 1
                            print(string.format("[PongDuRain] landing hp restored zid=%d %.2f -> %.2f para=%s",
                                id, z:getHealth(), p.hp, tostring(p.para)))
                        end
                        z:setHealth(p.hp)
                        _landRestored = _landRestored + 1
                    end
                    if p.chute then
                        chuteDetach(z)
                        p.chute = false
                        _paraStats.detach = _paraStats.detach + 1
                    end
                    _pending[key] = nil
                    _pendingCount = _pendingCount - 1
                end
            end
        end
    end

    -- ③ 만료 청소 (스트림아웃/원격 소유라 리스트 스캔에 안 잡히는 잔여분, ~10초마다)
    _sweepAcc = _sweepAcc + 1
    if _sweepAcc >= 600 then
        _sweepAcc = 0
        for id, p in pairs(_pending) do
            if now > p.e then
                _pending[id]  = nil
                _pendingCount = _pendingCount - 1
            end
        end
    end
    if _pendingCount == 0 then paraStatsFlush() end
end
Events.OnTick.Add(onTick)

-- 낙하 중 사살: Kill()이 이미 itemVisuals를 인벤토리로 옮긴 뒤 발화한다.
-- 비주얼과 인벤토리의 낙하산을 둘 다 지워 시체에 남지 않게 한다.
Events.OnZombieDead.Add(function(zombie)
    if _pendingCount == 0 or not zombie then return end
    local p = _pending[zkey(zombie)]
    if not p or not p.chute then return end
    local n = chuteDetach(zombie)
    pcall(function() zombie:getInventory():RemoveAll("PongDuZombieParachute") end)
    p.chute = false
    print("[PongDuRain] parachute removed on death zid=" .. tostring(zombie:getOnlineID())
        .. " visuals=" .. tostring(n))
end)

-- ── 활성 여부 조회 (rewardManager의 random_teleport 락용) ────────────────────
-- [public name: .c]
function _a.c()
    return _rainRemainMs > 0
end

-- ── 시작 (rewardManager에서 호출) ────────────────────────────────────────────
function _a.b(player, sender)
    local r, dur, kinds = rainCfg()
    local style = styleNow()
    sendClientCommand("PongDuRain", "Start", {
        ["r"] = r, ["dur"] = dur, ["kinds"] = kinds,
        ["sender"] = sender or "",
        ["style"] = style,
        ["para"]  = paraEnabled(),
    })
    print("[PongDuRain] start request style=" .. tostring(style) .. " para=" .. tostring(paraEnabled()) .. " r=" .. tostring(r) .. " dur=" .. tostring(dur)
        .. " normal=" .. tostring(kinds["normal"]) .. " sprinter=" .. tostring(kinds["sprinter"])
        .. " screamer=" .. tostring(kinds["screamer"]) .. " brute=" .. tostring(kinds["brute"])
        .. " roach=" .. tostring(kinds["roach"]) .. " tracer=" .. tostring(kinds["tracer"]))
    -- 효과음/반경 표시: 본인은 즉시 로컬, 나머지 접속자는 서버 거리컷 브로드캐스트.
    -- 반경 표시는 Rain_ShowRadius 를 따르고(꺼져 있으면 markerRadius=0 -> 아무에게도
    -- 안 뜸), 마커는 낙하가 이어지는 지속시간 내내 유지된다.
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    -- 착지 위치 검증용 (좀비 레인 방식만. 서버 pickRainColumn 도 이 위치·반경으로 고른다)
    _rainCenter = (style == STYLE_RAIN) and { x = px, y = py, r = r } or nil
    -- 투하 모드는 원형 반경이 실제 낙하 범위(경로 띠)와 달라 마커를 띄우지 않는다.
    -- 그림자가 범위 표시를 대신한다.
    local showRadius = showRadiusEnabled() and style == STYLE_RAIN
    local totalMs = dur * 1000 + SERVER_PREP_MS   -- 서버 준비 대기 포함
    -- 발동 효과음은 좀비 레인 방식만. 수송기 투하는 엔진음(planeTick)이 대신한다.
    local startSound = (style == STYLE_RAIN) and "zombie_rain" or nil
    if startSound then fx.playAt(startSound, px, py) end
    fx.broadcast({
        f = "zombie_rain",
        x = px, y = py, z = pz,
        sound = startSound,
        markerRadius = showRadius and r or 0,
        markerMs = totalMs,
    })
    if showRadius then
        fx.marker(px, py, pz, "zombie_rain", r, totalMs)
    end
    -- 독립 실행: 진행 중 재후원이 오면 서버는 세션을 병행하고,
    -- 클라 타이머는 "가장 늦게 끝나는 세션" 기준으로 지속시간만큼 리필한다.
    if _rainRemainMs < totalMs then _rainRemainMs = totalMs end
    print("[PongDuRain] client timer start durS=" .. tostring(dur) .. " totalMs=" .. tostring(totalMs)
        .. " remainMs=" .. tostring(math.floor(_rainRemainMs)))
    if not _panel then
        _panel = RainTimerDisplay:new()
        _panel:addToUIManager()
        _panel:setVisible(true)
        timerStack.register(_panel)
    end
end

return _a
