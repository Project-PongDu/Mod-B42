local _a = {}

local zone   = require("utils/zone")
local global = require("global")
local aggro  = require("features/aggro")

-- 좀비별 로컬 상태(체력 스냅샷·비명 쿨다운·이름표·벽등반 큐)의 테이블 키.
-- MP 는 onlineID 가 좀비마다 다르지만 싱글은 전부 -1 이다(서버에서만 발급:
-- IsoZombie.java onlineId 는 GameServer.server 일 때만 getUniqueZombieId()).
-- 그래서 싱글에서 onlineID 를 키로 쓰면 모든 특수좀비가 한 칸을 공유한다 -- 실측으로
-- 브루트(HP 5)가 다른 특좀의 체력 스냅샷(3)으로 깎이고, 죽은 특좀의 낮은 스냅샷이
-- 새로 소환된 특좀에 덮여 "소환되자마자 사망"했다. 싱글은 좀비 객체 자체를 키로 쓴다.
-- 객체 풀 재활용 오염은 OnZombieDead 정리가 그대로 막는다(같은 키로 지운다).
-- modData 의 PuppetMutantZid 는 객체를 담을 수 없어 계속 onlineID 를 쓴다.
local function zkey(zombie)
    if isClient() or isServer() then return zombie:getOnlineID() end
    return zombie
end

-- ═══════════════════════════════════════════════════════════════════════════
--  뮤턴트 (mutant_spawn): 스크리머 / 브루트 / 로치 중 1마리 랜덤 소환.
--
--  CDDA Zombies 모드에서 스크리머·브루트의 동작 로직만 떼어 자체 이식했다
--  (밴딧 -> 히트맨 이식과 동일 방식). CDDA 모드 의존성 없음.
--  종류·후원자 = 좀비가 입은 전용 아웃핏 PongDuMutant_<슬롯> + 옷 ID 변형 번호
--  (shared/PongDuMutantId.lua). 아웃핏은 청크 가상화·서버 재시작·시체·강령술 부활·MP 패킷을
--  모두 통과하므로, 서버 표식 패킷이나 레지스트리 없이 각 클라가 직접 알아본다.
--  modData["PuppetMutant"/"PuppetMutantSender"/"PuppetMutantZid"] 는 적용기가 매 틱 아웃핏에서
--  다시 채우는 클라 로컬 캐시일 뿐이다 (isTracer·이름표가 읽는다).
--
--    스크리머 : HP 1, 일반 걸음. 타깃이 생기면 주기적으로 비명
--               (mutant_scream1/2 재생 + 반경 50 월드사운드로 주변 좀비 유인).
--               플레이어를 표적으로 잡은 채 비명을 지르면 들은 좀비도 그 플레이어를 인지.
--               CDDA_ZombieFunction.Scream 이식.
--    브루트   : HP 3, 스프린터, 괴력(Strength=1), 넉다운 면역(keepstand),
--               공격 중 플레이어를 밀쳐냄(attackFromWindowsLunge).
--               CDDA_ZombieFunction.Push + keepstand 이식.
--    로치     : HP 1, 크롤 전용 + 크롤 속도 3배. 자체 제작 —
--               AnimSets/zombie-crawler/*/roach_*.xml 노드가 PuppetRoach
--               애님 변수 조건으로 3배속 크롤을 재생 (조건 수가 많은 노드가
--               우선 선택되는 PZ 애님 규칙, Hitman 애님 변형과 동일 기법).
--               외형은 하반신이 없는 몸통 크롤러: 아웃핏 PongDuMutant_03 의
--               PongDuRoachTorso_M/F 아이템(다리 마스크 + 내장 모델)과
--               Zombie_PongDuRoach_* 클립. Gore Crawlers & Torn Zombies
--               (DeadWorksZeds) 의 CrawlerTorso 에셋·애님 노드를 복사해 쓴다.
--    슬래머     : 빠른 걸음(바닐라 fast shambler) 고정, 평소엔 일반 좀비처럼 문다(원본 레커와 같음). 대상이 5칸 안이면
--               예고 후 직선 돌진, 닿은 플레이어는 넘어뜨리고 피해(돌진은 계속, 여러 명 관통),
--               벽·문·울타리에 막히면 문·창문·바리케이드를 부수거나 울타리를 휘고 자기가 넘어진다.
--               단계 결정은 서버(server/PongDuSlammerServer.lua), 연출·이동은 features/slammer.lua.
--               여기서는 종류 등록·체력·이름표만 한다.
--
--  권한 구조: 좀비는 클라이언트 권한이므로 서버는 전용 아웃핏 소환 + 후원자 번호만 하고
--  (server.lua MutantSpawn 핸들러), 실제 스탯/행동은 각 클라이언트의
--  OnZombieUpdate 적용기가 처리한다. 좀비 스트리밍/재사용으로 애님 변수가
--  풀리면 PuppetMutantInit 가드가 리셋되므로 다음 틱에 자동 재적용된다.
-- ═══════════════════════════════════════════════════════════════════════════

local KINDS = { "screamer", "brute", "roach", "tracer", "slammer" }

-- 샌드박스 타입 필터: PongDu.Mutant_<종류> 체크된 것만 등장 풀에 포함.
-- 5종 전부 해제면 스프린터 1마리로 폴백
-- (서버 spawnSpecialZombie는 kind="sprinter"도 전용 아웃핏(슬롯 06)으로 소환,
--  클라 initMutant가 walkType 적용).
local KIND_OPTION = {
    screamer = "Mutant_Screamer",
    brute    = "Mutant_Brute",
    roach    = "Mutant_Roach",
    tracer   = "Mutant_Tracer",
    slammer  = "Mutant_Slammer",
}

local function pickKind()
    local sv = SandboxVars.PongDu
    local pool = {}
    for _, k in ipairs(KINDS) do
        if sv[KIND_OPTION[k]] then
            pool[#pool + 1] = k
        end
    end
    if #pool == 0 then return "sprinter" end
    return pool[ZombRand(#pool) + 1]
end

local haloKey = {
    screamer = "IGUI_mutant_name_screamer",
    brute    = "IGUI_mutant_name_brute",
    roach    = "IGUI_mutant_name_roach",
    tracer   = "IGUI_mutant_name_tracer",
    slammer  = "IGUI_mutant_name_slammer",
    sprinter = "IGUI_mutant_name_sprinter",
}

-- 소환 외침: 욕(SWEAR) + 종류(mutateType) + 마무리(ENDMENT) 3파트를 랜덤 조합.
-- 예) "시발, 브루트잖아!" / "젠장, 로치 출현!"  (ENDMENT 쪽에 필요한 공백을 미리 포함시켜둠)
local SWEAR_KEYS = {
    "IGUI_mutant_swear_1", "IGUI_mutant_swear_2", "IGUI_mutant_swear_3",
    "IGUI_mutant_swear_4", "IGUI_mutant_swear_5", "IGUI_mutant_swear_6",
    "IGUI_mutant_swear_7", "IGUI_mutant_swear_8", "IGUI_mutant_swear_9",
    "IGUI_mutant_swear_10",
}
local ENDMENT_KEYS = {
    "IGUI_mutant_endment_1", "IGUI_mutant_endment_2", "IGUI_mutant_endment_3",
    "IGUI_mutant_endment_4", "IGUI_mutant_endment_5", "IGUI_mutant_endment_6",
    "IGUI_mutant_endment_7",
}

-- 비명 쿨다운(ms, 실시간). CDDA는 인게임 5분(기본 낮길이 기준 실시간 ~12.5초)
-- 주기였는데, 인게임 분 카운터 동기화 기계장치 대신 실시간 쿨다운으로 단순화.
local SCREAM_COOLDOWN_MS = 15000
local _nextScream = {}   -- [onlineID] = 다음 비명 허용 시각(ms). 클라 로컬.

-- 도네 발동 진입점 (rewardManager가 안전지대 대기까지 끝낸 뒤 호출).
-- 종류를 클라에서 굴리고, 좌표와 함께 서버에 스폰 요청. [public name: .a]
function _a.a(sender)
    local player = getPlayer()
    if not player then return end
    local kind = pickKind()
    sendClientCommand("PongDuMutant", "MutantSpawn", {
        ["ZedX"]   = player:getX() + zone.b(),
        ["ZedY"]   = player:getY() + zone.b(),
        ["ZedZ"]   = player:getZ(),
        ["kind"]   = kind,
        ["sender"] = sender or "",
    })
    local key = haloKey[kind]
    if key then
        local swear   = getText(SWEAR_KEYS[ZombRand(#SWEAR_KEYS) + 1])
        local endment = getText(ENDMENT_KEYS[ZombRand(#ENDMENT_KEYS) + 1])
        local msg = swear .. ", " .. getText(key) .. endment
        processShoutMessage(msg)
        addSound(player, player:getX(), player:getY(), player:getZ(), 30, 30)
    end
end

-- ── 종류별 체력 ──────────────────────────────────────────────────────────────
-- 종류별 체력 샌드박스 옵션. 값을 못 찾는 종류(sprinter)는 nil -> setHealth를
-- 아예 하지 않고 바닐라 기본 체력(ZombieLore.Toughness 기준)을 그대로 쓴다.
-- 참고: 바닐라 기본은 Normal=1.8~2.1 / Tough=3.5~3.8 / Fragile=0.5~0.8
-- (IsoZombie.DoZombieStats). 예전 하드코딩 값(브루트 3.0, 스크리머·로치 1.0)은
-- CDDA 원본 수치를 그대로 가져온 것이라 일반좀비보다 오히려 약했다.
local HEALTH_OPT = {
    brute    = "PongDu.Mutant_Health_Brute",
    screamer = "PongDu.Mutant_Health_Screamer",
    roach    = "PongDu.Mutant_Health_Roach",
    tracer   = "PongDu.Mutant_Health_Tracer",
    slammer  = "PongDu.Mutant_Health_Slammer",
}

local function mutantHealth(kind)
    local name = HEALTH_OPT[kind]
    if not name then return nil end
    local opt = getSandboxOptions():getOptionByName(name)
    if not opt then return nil end
    return opt:getValue()
end

-- 트레이서 발라클라바·돈가방 고정 회색. 두 아이템은 무작위 착색(m_AllowRandomTint=true)이고
-- 아웃핏 XML 에는 색 지정 항목이 없어(ClothingItemReference: 확률·GUID·하위아이템뿐) 클라가 칠한다.
-- 좀비가 다시 만들어질 때마다 아웃핏 시드대로 색이 돌아오지만 initMutant 가 그때마다 다시 칠한다.
-- ImmutableColor.new 는 int/float 오버로드가 겹쳐 decode(String) 로 만든다 (0x737373 = 0.45 회색).
local TINT_GREY = nil
local TRACER_GREY_ITEMS = { Hat_BalaclavaFull = true, Bag_MoneyBag = true }

-- 클라는 좀비 옷을 모델이 처음 붙을 때 입힌다(ModelManager.dressInRandomOutfit:555~561,
-- isPersistentOutfitInit=false 일 때 dressInPersistentOutfitID). 스폰 직후 첫 틱엔 itemVisuals 가
-- 비어 있어(2026-10-30 로그: init 시 visuals=0, tracer grey tinted=0) 옷을 입은 뒤에 칠해야 한다.
-- 그래서 initMutant 가 아니라 매 틱 부르고, 입은 뒤 한 번 칠하면 modData 표시로 멈춘다.
-- 객체 재사용(resetForReuse)은 modData 와 옷을 같이 지우므로 다시 입으면 다시 칠한다.
local function tintTracerGrey(zombie, md)
    if md["PuppetTracerTinted"] then return end
    -- 착용 아이템 모드(강령술 fakeDead 부활 등)에서 getItemVisuals() 를 부르면 좀비 자신의
    -- itemVisuals 를 wornItems 로 덮어써 옷이 지워진다(IsoZombie.java:4709~4725) -> 건너뛴다.
    if zombie:isUsingWornItems() then
        md["PuppetTracerTinted"] = true
        print("[PuppetMutant] tracer grey skipped (worn-items mode) zid=" .. tostring(zombie:getOnlineID()))
        return
    end
    if not zombie:isPersistentOutfitInit() then return end   -- 아직 옷을 안 입었다
    if not TINT_GREY then TINT_GREY = ImmutableColor.decode("0x737373") end
    local iv = zombie:getItemVisuals()
    if not iv then return end
    md["PuppetTracerTinted"] = true
    local n = 0
    for i = 0, iv:size() - 1 do
        local v = iv:get(i)
        if v and TRACER_GREY_ITEMS[v:getClothingItemName()] then
            v:setTint(TINT_GREY)
            n = n + 1
        end
    end
    if n > 0 then zombie:resetModel() end
    print("[PuppetMutant] tracer grey tinted=" .. tostring(n) .. " of " .. tostring(iv:size())
        .. " zid=" .. tostring(zombie:getOnlineID()))
end

-- 옷 진단: 특좀이 실제로 입은 아이템을 옷을 입은 직후 한 번 남긴다 (아웃핏 XML 검증용).
-- 위와 같은 이유로 init 시점이 아니라 isPersistentOutfitInit 이 선 뒤에 찍는다.
local function logDressOnce(zombie, kind, md)
    if md["PuppetDressLogged"] then return end
    if zombie:isUsingWornItems() then
        md["PuppetDressLogged"] = true
        print("[PuppetMutant] dressed kind=" .. tostring(kind) .. " zid=" .. tostring(zombie:getOnlineID())
            .. " skipped (worn-items mode)")
        return
    end
    if not zombie:isPersistentOutfitInit() then return end
    md["PuppetDressLogged"] = true
    local iv = zombie:getItemVisuals()
    local names = {}
    local n = iv and iv:size() or 0
    for i = 0, n - 1 do
        local v = iv:get(i)
        names[#names + 1] = v and tostring(v:getClothingItemName()) or "nil"
    end
    print("[PuppetMutant] dressed kind=" .. tostring(kind) .. " zid=" .. tostring(zombie:getOnlineID())
        .. " female=" .. tostring(zombie:isFemale()) .. " n=" .. tostring(n)
        .. " items=" .. table.concat(names, ","))
end

-- 고정 피부 (PongDuMutantId.FIXED_SKIN, 지금은 슬래머 회색). 옷을 입은 뒤 한 번 피부 텍스처 이름을 바꾸고
-- 다시 그린다. 근육 상체 옷은 회색 텍스처 한 장뿐이라 따로 고를 것이 없다.
-- 객체 재사용 시 modData 와 HumanVisual 이 같이 지워지므로 다시 입으면 다시 넣는다.
local function applyFixedSkin(zombie, kind, md)
    if md["PuppetSkinFixed"] then return end
    if not PongDuMutantId.FIXED_SKIN[kind] then return end
    if not zombie:isPersistentOutfitInit() then return end   -- 아직 옷을 안 입었다
    md["PuppetSkinFixed"] = true
    local hv = zombie:getHumanVisual()
    if not hv then
        print("[PuppetMutant] fixed skin failed (no HumanVisual) kind=" .. tostring(kind)
            .. " zid=" .. tostring(zombie:getOnlineID()))
        return
    end
    local before = hv:getSkinTexture()
    local changed = PongDuMutantId.applyFixedSkin(zombie, kind)
    -- SP 에선 서버 스캔이 같은 객체에 이름을 먼저 넣을 수 있다(changed=false). 그때도 모델은 옛 피부로
    -- 그려졌을 수 있으므로 처음 한 번은 항상 다시 그린다.
    zombie:resetModel()
    print("[PuppetMutant] fixed skin kind=" .. tostring(kind) .. " before=" .. tostring(before)
        .. " now=" .. tostring(hv:getSkinTexture()) .. " changed=" .. tostring(changed)
        .. " hair=" .. tostring(hv:getHairModel()) .. " beard=" .. tostring(hv:getBeardModel())
        .. " zid=" .. tostring(zombie:getOnlineID()))
end

-- ── 1회 초기화 (클라별) ───────────────────────────────────────────────────────
-- 스탯류는 매 틱 재적용하면 안 되는 것들이라 PuppetMutantInit 애님 변수로
-- 가드. 변수는 좀비가 스트림 아웃되면 리셋 -> 다시 로드될 때 자동 재초기화.
local function initMutant(zombie, kind)
    if kind == "brute" then
        -- 괴력: CDDA_UpdateZombie와 동일하게 샌드박스 스왑 + DoZombieStats.
        local origStr = getSandboxOptions():getOptionByName("ZombieLore.Strength"):getValue()
        getSandboxOptions():set("ZombieLore.Strength", 1)   -- 1 = Superhuman
        zombie:DoZombieStats()
        getSandboxOptions():set("ZombieLore.Strength", origStr)
        zombie:setWalkType("sprint" .. tostring(ZombRand(5) + 1))
    elseif kind == "screamer" then
        -- 걸음은 기본값 유지
    elseif kind == "roach" then
        zombie:setVariable("PuppetRoach", true)
    elseif kind == "sprinter" then
        -- 부활한 뛰좀 재적용 경로 (원 스폰은 서버 makeSprinter가 처리)
        zombie:setWalkType("sprint" .. tostring(ZombRand(5) + 1))
    elseif kind == "tracer" then
        -- 트레이서: 스프린터 워크타입.
        -- ※3차 정정: DoZombieSpeeds()도 무효 - 이 함수가 만지는
        -- def.AnimFrameIncrease는 구세대 2D 스프라이트 프레임 전진에만 읽히는
        -- 레거시 필드로(B41 3D 좀비 이동은 advanced animator의 루트모션이 전담),
        -- 이속에 아무 영향이 없다. 실제 이속 조절은 locomotion 애님 노드의
        -- m_SpeedScale 오버라이드로만 가능(TR locomotion 노드, 별도 작업).
        zombie:setWalkType("sprint" .. tostring(ZombRand(5) + 1))
    elseif kind == "slammer" then
        -- 슬래머: 빠른 걸음 고정 (speedType 2, walkType "1"~"5", IsoZombie.doFastShambler).
        -- speedType 을 2 로 박아 두므로 이후 DoZombieStats 도 같은 속도로 다시 만든다.
        -- 돌진은 서버 단계 방송을 받아 features/slammer.lua 가 처리한다.
        zombie:doFastShambler()
        -- 무는 능력은 건드리지 않는다 (원본 PZM_MutantProperties 의 Wrecker 에 noTeeth 없음).
        -- 돌진 중엔 AI 가 무동작 상태로 고정돼 AttackState 가 없으므로 물지 못한다.
    end
    -- 체력은 분기 뒤에 일괄 적용한다. 브루트는 위에서 DoZombieStats()를 부르는데
    -- 그 안에서 Toughness 기준으로 setHealth가 다시 걸리므로(IsoZombie.java:3350)
    -- 반드시 그 뒤여야 한다.
    local hp = mutantHealth(kind)
    if hp then zombie:setHealth(hp) end
    -- 옷 진단: 강령술 부활 특좀이 알몸으로 보이는 문제 추적용.
    --   wornItems 로 그리는 좀비(isUsingWornItems: 부활 플레이어 플래그·죽은척 출신)는 클라에
    --   wornItems 가 없으면 알몸이 된다(IsoZombie.java:4715, 4725).
    -- getItemVisuals() 는 wornItems 모드일 때 좀비 자신의 itemVisuals 를 wornItems 내용으로 덮어쓰므로
    -- (IsoZombie.java:4709~4720, WornItems.java:156) 그때는 부르지 않는다.
    local wornMode = zombie:isUsingWornItems()
    local nVis = "skip"
    if not wornMode then
        local iv = zombie:getItemVisuals()
        nVis = iv and iv:size()
    end
    print("[PuppetMutant] init " .. tostring(kind)
        .. " hp=" .. tostring(hp or zombie:getHealth())
        .. " zid=" .. tostring(zombie:getOnlineID())
        .. " outfit=" .. tostring(zombie:getOutfitName())
        .. " pid=" .. tostring(zombie:getPersistentOutfitID())
        .. " visuals=" .. tostring(nVis)
        .. " dressed=" .. tostring(zombie:isPersistentOutfitInit())
        .. " wornMode=" .. tostring(wornMode)
        .. " rp=" .. tostring(zombie:isReanimatedPlayer())
        .. " noTeeth=" .. tostring(zombie:isNoTeeth()))
    zombie:setVariable("PuppetMutantInit", true)
end

-- ── 외부 모드 스탯 덮어쓰기 감시 ─────────────────────────────────────────────
-- 좀비 랜덤화 모드들(BLTRandomZombies 등)은 셀 전체를 훑으며 makeInactive
-- (true/false) 또는 toggleCrawling()으로 DoZombieStats()를 강제 호출한다
-- (IsoZombie.java 4079 / 3786). DoZombieStats()는 speedType 기준으로 walkType을
-- 무조건 재생성하고(2644) 근력도 샌드박스 값으로 되돌리므로, 퐁듀가 준
-- sprintN 걸음과 브루트 초인근력이 통째로 날아간다. PuppetMutantInit은 애님
-- 변수라 이때 그대로 남아 재적용이 안 걸리고, 결과적으로 특좀이 소환 몇 초 뒤
-- 일반좀비처럼 행동하게 된다.
--
-- 알려진 모드(RZ, BLT)는 PongDuCompatRandomZombies.lua에서 원천 차단하므로
-- 여기까지 오지 않는다. 이 함수는 그 차단이 실패했을 때를 위한 최후 방어선이다
-- (모드 업데이트로 내부 구조가 바뀌어 스킵 캐시 키가 달라진 경우, 또는 아직
-- 모르는 제3의 좀비 랜덤화 모드). 상태가 어긋나면 초기화 가드를 풀어 다음
-- 틱에 재적용시킨다. 이런 모드들은 좀비 1마리를 사이클당 1회만 건드리므로
-- 재적용이 항상 마지막 쓰기가 된다. 다만 "덮어씀 -> 다음 틱 복구" 순서라
-- 한 틱짜리 깜빡임이 생기므로, 정상 경로는 어디까지나 원천 차단 쪽이다.
--
-- 비용은 특좀 1마리당 문자열 조회 1회. 판별 대상이 아닌 일반좀비는 applyMutant
-- 상단 kind 검사에서 이미 걸러져 여기까지 오지 않는다.
--
-- 체력 스냅샷은 modData가 아니라 클라 로컬 테이블에 둔다. modData는 B41의
-- IsoZombie 객체 풀 재활용 때 그대로 딸려와, 죽기 직전 체력이 새 좀비에게
-- 적용되는 사고를 낸다(호드매니저 둔갑 버그와 동일 원인). OnZombieDead에서
-- 항목을 지워 onlineID 재사용에도 오염되지 않게 한다.
local _hpSnap = {}
local SPRINT_KIND = { brute = true, tracer = true, sprinter = true }
-- 빠른 걸음이어야 하는 종류: walkType 이 숫자만("1"~"5")이어야 한다 (sprint*/slow* 면 덮어써진 것)
local FAST_KIND = { slammer = true }

local function guardStats(zombie, kind)
    if not zombie:getVariableBoolean("PuppetMutantInit") then return end
    local zid = zkey(zombie)
    local reason = nil

    -- ① 걸음타입: sprint 계열이어야 할 종류가 다른 값으로 재생성됨
    if SPRINT_KIND[kind] then
        local wt = zombie:getVariableString("zombiewalktype")
        if not (wt and string.sub(wt, 1, 6) == "sprint") then
            reason = "walkType=" .. tostring(wt)
        end
    elseif FAST_KIND[kind] then
        local wt = zombie:getVariableString("zombiewalktype")
        if not wt or string.sub(wt, 1, 6) == "sprint" or string.sub(wt, 1, 4) == "slow" then
            reason = "walkType=" .. tostring(wt)
        end
    end

    -- ② 크롤: 로치가 아닌데 정당한 사유 없이 기고 있음(크롤러 버킷 배정).
    --    다리 부러짐/넉다운 등 정상 크롤과 싸우지 않도록 바닐라와 동일한
    --    조건일 때만 되돌린다.
    if not reason and kind ~= "roach" and zombie:isCrawling()
        and not zombie:isKnockedDown() and zombie:getCrawlerType() == 0
        and not zombie:wasFakeDead() then
        zombie:toggleCrawling()
        zombie:setCanWalk(true)
        reason = "forced-crawl"
    end

    -- ③ 체력: 마지막 정상 스냅샷보다 높아짐. 체력은 피해로만 내려가므로
    --    올라갔다면 외부에서 setHealth한 것이 확실하다(오탐 없음).
    local last = _hpSnap[zid]
    if not reason and last and zombie:getHealth() > last + 0.01 then
        reason = "health=" .. tostring(zombie:getHealth()) .. " expected<=" .. tostring(last)
        zombie:setHealth(last)
    end

    if not reason then
        _hpSnap[zid] = zombie:getHealth()           -- 정상 구간에서만 갱신
        return
    end

    print("[PuppetMutant] stats overwritten by another mod - reasserting kind="
        .. tostring(kind) .. " " .. reason
        .. " zid=" .. tostring(zombie:getOnlineID()))
    zombie:setVariable("PuppetMutantInit", false)
end

-- 외부 기능의 정당한 회복 통로 [public name: .restoreHealth]
-- guardStats ③은 "체력이 스냅샷보다 오르면 타 모드의 덮어쓰기"로 보고 되돌린다.
-- 좀비 레인의 착지 후 낙하피해 원복처럼 퐁듀가 의도적으로 체력을 올리는 경우엔
-- 스냅샷을 같은 값으로 함께 갱신해야 guardStats와 싸우지 않는다.
function _a.restoreHealth(zombie, hp)
    if not zombie or not hp then return end
    zombie:setHealth(hp)
    _hpSnap[zkey(zombie)] = hp
end

-- ── 스크리머: 비명 (CDDA_ZombieFunction.Scream 이식) ─────────────────────────
-- playSound는 클라 로컬 렌더링이라 각 클라가 각자 재생 = 전원이 들림.
--
-- 월드사운드(주변 좀비 유인)는 소스를 nil 로 낸다. 소스가 좀비면 WorldSound.init 이
-- sourceIsZombie=true 를 세우고(WorldSoundManager.java:615), 좀비는 그런 소리를 전부 무시한다:
--   실좀비 getSoundAttract -> 0 (:356), getBiggestSoundZomb(ignoreBySameType=true) 제외 (:317),
--   가상 좀비 ZombiePopulationManager.addWorldSound 제외 (:493).
-- 예전엔 addSound(zombie, ...) 라 비명이 아무 좀비도 끌지 못했다 (B41 도 init 이 같다).
--
-- 월드사운드는 소유 클라 한 곳에서만 낸다. MP 클라 addSound 는 서버로 올라가고
-- (GameClient.sendWorldSound) 서버가 가상 좀비에 적용한 뒤 범위 안 다른 클라에 중계한다
-- (WorldSoundPacket.processServer) -> 한 번이면 전원의 좀비가 듣는다. 모든 클라가 내면
-- 접속자 수만큼 중복 중계된다. 반경 50 이상이어야 가상 좀비(청크 밖 인구)도 끈다.
--
-- 표적 위치 전달: 스크리머가 플레이어를 표적으로 잡은 채 비명을 지르면, 비명을
-- 들은 좀비에게 "그 순간의" 플레이어 위치를 한 번 알린다 (aggro.nudgeOnce):
--   모두      = pathToSound 로 비명 시점의 플레이어 좌표로 유인
--   18타일 이내 = 추가로 spotted(target,false) 비강제 스팟 → 성공하면 엔진 추격 인계
-- 비명마다 1회뿐이다. 예전엔 어그로 창(16초)이 2초마다 플레이어 현재 좌표로 다시
-- 유인해 좀비 무리가 2초 주기로 돌아보며 경로를 갈아탔다 (2026-10-29 실측 로그
-- "pulse lured=100" 2초 간격).
-- 좀비는 소유 클라 권한이라 각 클라가 자기 소유 좀비만 고른다. 원격 스크리머의
-- 표적도 ZombiePacket.target 으로 동기화되므로 비소유 클라도 표적을 안다 →
-- 전달은 월드사운드와 달리 모든 클라에서 돈다(서버 패킷 추가 없음).
local SCREAM_RADIUS = 50
local SCREAM_VOLUME = 50

-- 비명 청각 판정: WorldSoundManager.getSoundAttract(B42.21 :347) 재현.
-- 3D 거리(z 는 3배 가중) <= 반경 x 좀비별 청각 배율(착용 장비·날씨 포함),
-- 방이 다르면 x1.2, 한쪽이 실외면 추가 x1.4 감쇠 후 1 미만이면 들은 것.
local function heardScream(z, sx, sy, sz, sq0, wsm)
    local mult = 1.0
    pcall(function() mult = wsm:getHearingMultiplier(z) end)
    local r = SCREAM_RADIUS * mult
    local dx = z:getX() - sx
    local dy = z:getY() - sy
    local dz = (z:getZ() - sz) * 3.0
    local f = (dx * dx + dy * dy + dz * dz) / (r * r)
    if f > 1 then return false end
    local sq1 = z:getCurrentSquare()
    if sq0 and sq1 then
        local r0 = sq0:getRoom()
        local r1 = sq1:getRoom()
        if r0 ~= r1 then
            f = f * 1.2
            if r0 == nil or r1 == nil then f = f * 1.4 end
        end
    end
    return f < 1
end

-- 비명을 들은 자기 소유 좀비 목록.
-- 제외: 스크리머 본인, 이미 표적이 있는 좀비(다른 대상을 쫓는 중), 원격 좀비,
-- 죽은척(fakeDead)/무력화(useless) 좀비.
local function collectScreamListeners(screamer)
    local list = {}
    local cell = getCell()
    local zlist = cell and cell:getZombieList()
    if not zlist then return list end
    local wsm = getWorldSoundManager()
    local sx = math.floor(screamer:getX())
    local sy = math.floor(screamer:getY())
    local sz = math.floor(screamer:getZ())
    local sq0 = screamer:getCurrentSquare()
    for i = 0, zlist:size() - 1 do
        local z = zlist:get(i)
        if z and z ~= screamer and not z:isDead() and z:getTarget() == nil
            and not z:isFakeDead() and not z:isUseless() then
            local remote = false
            pcall(function() remote = PongDuZombieId.IsRemote(z) end)
            if not remote and heardScream(z, sx, sy, sz, sq0, wsm) then
                list[#list + 1] = z
            end
        end
    end
    return list
end

-- 표적 위치 전달 본체 (MP·SP 공통, 비명마다 1회).
local function propagateScreamTarget(screamer, target)
    local szid = screamer:getOnlineID()
    if not instanceof(target, "IsoPlayer") or target:isDead() then
        print("[PuppetMutant] scream zid=" .. tostring(szid) .. " target=non-player, no propagation")
        return
    end
    local ok, list = pcall(collectScreamListeners, screamer)
    if not ok then
        print("[PuppetMutant] scream listener scan error: " .. tostring(list))
        return
    end
    local nS, nL = 0, 0
    for i = 1, #list do
        local r = aggro.nudgeOnce(list[i], target)
        if r == "spotted" then nS = nS + 1 elseif r == "lure" then nL = nL + 1 end
    end
    print("[PuppetMutant] scream propagate zid=" .. tostring(szid)
        .. " targetPid=" .. tostring(target:getOnlineID())
        .. " heard=" .. tostring(#list) .. " spotted=" .. tostring(nS) .. " lureOnly=" .. tostring(nL))
end

local function updateScreamer(zombie)
    local target = zombie:getTarget()
    if not target then return end
    local zid = zkey(zombie)
    local now = getTimestampMs()
    if _nextScream[zid] and now < _nextScream[zid] then return end
    _nextScream[zid] = now + SCREAM_COOLDOWN_MS
    local player = getPlayer()
    if player and not player:hasTrait(CharacterTrait.DEAF) then
        zombie:playSound("mutant_scream" .. tostring(ZombRand(2) + 1))
    end
    propagateScreamTarget(zombie, target)
    if isClient() and zombie:isRemoteZombie() then return end
    addSound(nil, zombie:getX(), zombie:getY(), zombie:getZ(), SCREAM_RADIUS, SCREAM_VOLUME)
    print("[PuppetMutant] scream zid=" .. tostring(zombie:getOnlineID())
        .. " at " .. tostring(math.floor(zombie:getX())) .. "," .. tostring(math.floor(zombie:getY()))
        .. " radius=" .. tostring(SCREAM_RADIUS))
end

-- ── 브루트: 넉다운 면역 + 밀치기 (keepstand + Push 이식) ─────────────────────
-- attackFromWindowsLunge는 플레이어 객체를 직접 밀쳐내므로 로컬 플레이어에게만
-- 적용 (CDDA는 이 가드가 없는데, 원격 플레이어 프록시에 걸면 무의미/부정확).
local function updateBrute(zombie)
    zombie:setKnockedDown(false)
    if zombie:isAttacking() then
        local target = zombie:getTarget()
        if target and instanceof(target, "IsoPlayer") and target:isLocalPlayer() then
            target:attackFromWindowsLunge(zombie)
        end
    end
end

-- ── 트레이서: 파쿠르 시스템 ─────────────────────────────────────────────────
-- 검증된 워크샵 모드 3종을 트레이서 전용으로 게이팅해 이식:
--   Vaulting Zombies      : 낮은담장/창문 클라임 애님을 볼트로 교체
--                           (climbfence·climbwindow TR* 노드, 여기선 Sprint 버전)
--   Stay Away From Windows: 충돌한 닫힌 창문 즉시 파괴 (OnObjectCollide)
--   ZombieClimbsWall      : 높은담장(FenceTypeHigh) 클라임 (hitreaction TR* 노드
--                           + anims_X/Zombie/TR_ClimbWall_*.X 에셋)
-- + DiveThroughWindows의 창문 볼트 트릭: 창문을 깬 직후 climbOverFence를 직접
--   호출하면 climbfence 스테이트가 창문 개구부를 '담장'처럼 취급해 볼트로
--   관통한다 (스테이트의 isIgnoreCollide가 시작-도착 스퀘어 간 충돌을 무시).
-- 파쿠르 실패는 전 구간 0%: climbfence/climbwindow outcome을 매 틱 success로
-- 강제하고(트립·런지 차단), 높은담장 클라임은 확률 굴림 없이 무조건 Success.

-- 이벤트 핸들러(OnObjectCollide 등)용 트레이서 판별. applyMutant 경로 밖에서도
-- 쓰이므로 modData 직조회 + 풀 재활용 스테일 가드(Zid 대조)를 그대로 적용.
-- 진단 로그 스위치: 콘솔에서 Tracer.Verbose = true 로 켜기 (기본 꺼짐).
-- trLog는 좀비별x메시지별 0.5초 스로틀 - 콘솔 잠김 방지.
Tracer = Tracer or {}
Tracer.Verbose = false
local trLogLast = {}
local function trLog(zombie, msg)
    if not Tracer.Verbose then return end
    local zid = zombie:getOnlineID()
    local now = getTimestampMs()
    local key = tostring(zid) .. msg
    if trLogLast[key] and now - trLogLast[key] < 500 then return end
    trLogLast[key] = now
    print("[Tracer] zid=" .. tostring(zid) .. " " .. msg)
end

local function isTracer(zombie)
    local md = zombie:getModData()
    return md["PuppetMutant"] == "tracer"
        and md["PuppetMutantZid"] == zombie:getOnlineID()
end

-- ── 트레이서: 높은담장 클라임 (ZombieClimbsWall 이식, 리키잉 버전) ──────────
-- ※핵심 교훈: 진행 판정을 hitreaction 문자열로 하면 안 된다. hitreaction은
--   MP 동기화 변수(NetworkVariables.HitReaction)인 데다 ZombieHitReactionState.
--   exit()가 ""로 강제 클리어할 수 있어서, 상태 키로 쓰면 지워지는 순간
--   TRClimbWallStarted=true만 영구 잔류하는 데드락에 빠진다 (담장 앞에서
--   '아직 넘는 중'처럼 굳는 증상). 원본 ZombieClimbsWall처럼 진행 판정은
--   Started 변수로만 하고, hitreaction은 매 틱 재주입해 자가복구시킨다.
local function updateTracerWallClimb(zombie)
    -- 담장 볼트/창문 통과 스테이트 중에는 벽클라임 로직 전체 배제
    -- (해당 스테이트도 collidable을 만지므로 아래 정리 분기와 간섭 금지)
    local st = zombie:getCurrentState()
    if st == ClimbOverFenceState.instance()
        or st == ClimbThroughWindowState.instance() then
        return
    end

    -- 벽 클라임(z+1) 진행 중에는 높은담장 로직 배제 (상호 배타)
    if zombie:getVariableBoolean("TRWallUpActive") then
        return
    end

    -- [진행 구간] Start 애님 종료(Started=true) ~ Success 애님 종료
    if zombie:getVariableBoolean("TRClimbWallStarted") then
        zombie:setVariable("bPathfind", false)
        zombie:setVariable("bMoving", true)
        if zombie:isCollidable() then zombie:setCollidable(false) end
        -- 트레이서는 100% 성공: 굴림 없이 즉시 Success 노드 조건 재주입.
        -- 엔진이 hitreaction을 지워도 다음 틱에 복구된다.
        if not zombie:isVariable("hitreaction", "TRClimbWallReactionSuccess") then
            zombie:setVariable("hitreaction", "TRClimbWallReactionSuccess")
        end
        return
    end

    -- [정리 구간] Started=false인데 collidable이 꺼져 있으면 Success 애님이
    -- 방금 끝난 것 -> 관통 상태 복구 + hitreaction 잔여값 제거
    if not zombie:isCollidable() then
        zombie:setCollidable(true)
        if zombie:isVariable("hitreaction", "TRClimbWallReactionSuccess") then
            zombie:setVariable("hitreaction", nil)
        end
        return
    end

    -- [트리거 스캔] 전방 3타일 박스에서 FenceTypeHigh 탐색 -> 정면 응시 유도
    -- -> 충돌 프레임에 발동 (원본 ClimbWallFunction 이식). 이 지점은
    -- Started=false 확정 구간이므로 재트리거가 항상 열려 있다.
    if zombie:isOnFloor() or zombie:isStaggerBack() then return end
    if not zombie:getTarget() then return end
    local baseSq = zombie:getCurrentSquare()
    if not baseSq then return end

    local fdx, fdy, countX, countY
    if zombie:getForwardDirection():getX() >= 0 then
        fdx, countX = math.ceil(zombie:getForwardDirection():getX()), 1
    else
        fdx, countX = math.floor(zombie:getForwardDirection():getX()), -1
    end
    if zombie:getForwardDirection():getY() >= 0 then
        fdy, countY = math.ceil(zombie:getForwardDirection():getY()), 1
    else
        fdy, countY = math.floor(zombie:getForwardDirection():getY()), -1
    end

    local cell = getCell()
    for x = 0, fdx + countX * 3, countX do
        for y = 0, fdy + countY * 3, countY do
            local square = cell:getGridSquare(baseSq:getX() + x, baseSq:getY() + y, baseSq:getZ())
            if square then
                local objects = square:getObjects()
                for i = 0, objects:size() - 1 do
                    local object = objects:get(i)
                    local properties = object:getProperties()
                    if properties and properties:has("FenceTypeHigh") then
                        -- 경로탐색이 담장을 우회하지 않도록 직진 상태로 고정
                        if zombie:getVariableBoolean("bPathfind")
                            or not zombie:getVariableBoolean("bMoving") then
                            zombie:setVariable("bPathfind", false)
                            zombie:setVariable("bMoving", true)
                        end
                        if not zombie:isFacingObject(object, 0.5) then
                            zombie:faceThisObject(object)
                        end
                        if zombie:isCollidedThisFrame()
                            and zombie:isFacingObject(object, 0.5) then
                            zombie:setVariable("hitreaction", "TRClimbWallReactionStart")
                        end
                        return
                    end
                end
            end
        end
    end
end

-- ── 트레이서: 벽 클라임 - 한 층 위로 (ClimbWall 모드 포팅) ──────────────────
-- 원본(플레이어용)은 키 입력 -> TimedAction -> 텔레포트 구조지만 좀비에겐
-- TimedAction이 없으므로 검증된 hitreaction + Started-변수 패턴으로 재구성.
-- 판정 로직(전방 z+1 착지칸 유효성/상단 개방/모서리 플래그)은 원본
-- Climb.isClimbableWallInBounds를 그대로 이식. 애님은 기존 TR_ClimbWall_*
-- 클립 재사용, 완료 시 착지칸으로 텔레포트(원본도 텔레포트 방식).
local function trWallUpBlockedW(square)
    if not square then return false end
    return square:has(IsoFlagType.collideW) or square:has(IsoFlagType.WindowW)
        or square:has(IsoFlagType.doorW) or square:has(IsoFlagType.HoppableW)
end
local function trWallUpBlockedN(square)
    if not square then return false end
    return square:has(IsoFlagType.collideN) or square:has(IsoFlagType.WindowN)
        or square:has(IsoFlagType.doorN) or square:has(IsoFlagType.HoppableN)
end

-- 클라임 중 텔레포트 실시간 감시 큐. 좀비가 hitreaction 상태인 동안
-- OnZombieUpdate가 멎으므로(IsoZombie:2096 배제 목록), 상태와 무관하게
-- 매 틱 도는 OnTick으로 TRWallUpDone(애님 30% 지점 발화)을 잡아
-- 원본 ClimbWall과 동일한 미드애님 텔레포트를 수행한다.
local trWallUpQueue = {}

local function trWallUpTeleport(zombie)
    zombie:setVariable("TRWallUpDone", false)
    zombie:setVariable("TRWallUpActive", false)
    local tx = zombie:getVariableFloat("TRWallUpX", zombie:getX())
    local ty = zombie:getVariableFloat("TRWallUpY", zombie:getY())
    local tz = zombie:getVariableFloat("TRWallUpZ", zombie:getZ())
    trLog(zombie, "wallup: DONE teleport z=" .. tostring(tz))
    zombie:setX(tx)
    zombie:setY(ty)
    zombie:setZ(tz)
    -- setX/Y/Z 만으로는 z+1 상승이 다음 업데이트에 되돌려진다.
    -- IsoMovingObject.snapZToCurrentSquare(:1054)가 z를 current 스퀘어의
    -- z+0.99999 로 깎는데, current 는 아직 아래층 스퀘어이기 때문이다.
    -- setMovingSquareNow(:1967)는 movingSq 에 current 를 넘길 뿐이라 혼자서는
    -- 소용이 없다. 엔진도 IsoGameCharacter 생성자(:819~820)에서 current 를 먼저
    -- 잡고 setMovingSquareNow 를 부르는 순서다.
    local destSq = getCell():getGridSquare(math.floor(tx), math.floor(ty), math.floor(tz))
    if destSq then
        zombie:setCurrent(destSq)
        zombie:setMovingSquareNow()
    else
        trLog(zombie, "wallup: dest square is nil, current square left unchanged")
    end
end

Events.OnTick.Add(function()
    for zid, zombie in pairs(trWallUpQueue) do
        if zombie:isDead() or not zombie:getCurrentSquare()
            or not zombie:getVariableBoolean("TRWallUpActive") then
            -- 사망/피격중단/완료 후 잔여 엔트리 정리
            trWallUpQueue[zid] = nil
        elseif zombie:getVariableBoolean("TRWallUpDone") then
            trWallUpTeleport(zombie)
            trWallUpQueue[zid] = nil
        end
    end
end)

local function updateTracerWallUp(zombie)
    local st = zombie:getCurrentState()
    if st == ClimbOverFenceState.instance()
        or st == ClimbThroughWindowState.instance() then
        return
    end
    -- 높은담장 관통 진행 중 배제 (상호 배타)
    if zombie:getVariableBoolean("TRClimbWallStarted")
        or not zombie:isCollidable() then
        return
    end

    -- [완료 폴백] 정상 경로는 OnTick 큐가 애님 30% 지점에 미드애님 텔레포트를
    -- 수행한다(위 trWallUpQueue 주석 참고). 이 분기는 OnTick이 어떤 이유로
    -- 놓쳤을 때의 안전망 - 상태 탈출 후 OnZombieUpdate가 재개되면 잡힌다.
    if zombie:getVariableBoolean("TRWallUpDone") then
        trWallUpTeleport(zombie)
        trWallUpQueue[zkey(zombie)] = nil
        if zombie:isVariable("hitreaction", "TRWallUpReactionStart")
            or zombie:isVariable("hitreaction", "TRWallUpReactionSuccess") then
            zombie:setVariable("hitreaction", nil)
        end
        return
    end

    -- [진행] Start 애님 종료(Started=true) ~ Success 애님 종료: Success 재주입.
    -- 이 분기는 두 애님 '사이의 틈'(hitreaction 상태가 잠깐 풀리는 프레임)에서
    -- 실행된다 - 그 틈이 이 흐름이 동작하는 유일한 창구.
    if zombie:getVariableBoolean("TRWallUpStarted") then
        if not zombie:isVariable("hitreaction", "TRWallUpReactionSuccess") then
            zombie:setVariable("hitreaction", "TRWallUpReactionSuccess")
        end
        return
    end

    -- [중단 감지] Active인데 Done/Started 모두 아님
    if zombie:getVariableBoolean("TRWallUpActive") then
        if zombie:isVariable("hitreaction", "TRWallUpReactionStart") then
            return -- Start 애님 대기/재생 중: 정상
        end
        -- 외부 요인으로 흐름이 끊김: 텔레포트 없이 중단 - 다음 충돌에 재트리거
        zombie:setVariable("TRWallUpActive", false)
        trLog(zombie, "wallup: aborted (flow broken)")
        return
    end

    -- [트리거] 원본 Climb.OnPlayerUpdate + isClimbableWallInBounds 1:1 이식.
    -- (키 입력 -> 충돌 프레임으로 치환한 것 외에 판정 기하는 동일)
    if zombie:isOnFloor() or zombie:isStaggerBack() then return end
    if not zombie:getTarget() then return end
    if not zombie:isCollidedThisFrame() then return end
    local baseSq = zombie:getCurrentSquare()
    if not baseSq then return end
    if baseSq:HasStairs() then return end -- 원본: 계단 위 발동 금지
    if baseSq:getZ() >= 31 then return end -- B42 최상층 한계 (IsoCell.maxHeight=32 -> z 0..31)

    -- 원본과 동일: float 전방 0.5 지점으로 목표칸 산출 (4방향 스냅 없음)
    local fwd = zombie:getForwardDirection()
    local forwardX = zombie:getX() + fwd:getX() * 0.5
    local forwardY = zombie:getY() + fwd:getY() * 0.5
    local cell = getCell()
    local target = cell:getGridSquare(forwardX, forwardY, baseSq:getZ() + 1)
    if not target then
        trLog(zombie, "wallup: no target square z+1")
        return
    end
    if not target:TreatAsSolidFloor() then
        trLog(zombie, "wallup: target no solid floor")
        return
    end
    if target:isSolidTrans() or target:isSolid() or target:HasStairs() then
        trLog(zombie, "wallup: target occupied/stairs")
        return
    end
    local sx, sy = baseSq:getX(), baseSq:getY()
    local tx, ty = target:getX(), target:getY()
    if sx == tx and sy == ty then return end -- 같은 수직선상 (원본 동일)
    local up = cell:getGridSquare(sx, sy, baseSq:getZ() + 1)
    if up and (up:TreatAsSolidFloor() or up:isSolid() or up:isSolidTrans()) then
        trLog(zombie, "wallup: blocked overhead")
        return
    end

    -- 방향별 모서리 차단 플래그 (원본 분기 구조 그대로).
    -- ※대각 접근(X,Y 둘 다 다름)은 두 분기 어디에도 안 걸려 canClimb=true
    -- 초기값 그대로 통과한다 - 원본의 동작을 의도적으로 보존. 플레이어가
    -- 2층 울타리(Hoppable) 가장자리도 각도만 틀면 타고 오르는 이유가 이
    -- 루프홀이며, "원본과 100% 동일" 요구사항의 핵심.
    local canClimb = true
    if ty == sy then
        if tx > sx then
            canClimb = not trWallUpBlockedW(target)
        elseif tx < sx then
            canClimb = not up or not trWallUpBlockedW(up)
        else
            canClimb = false
        end
    elseif tx == sx then
        if ty > sy then
            canClimb = not trWallUpBlockedN(target)
        elseif ty < sy then
            canClimb = not up or not trWallUpBlockedN(up)
        else
            canClimb = false
        end
    end
    if not canClimb then
        trLog(zombie, "wallup: edge flag blocked")
        return
    end

    -- 발동: 원본과 동일하게 float 전방 좌표를 착지점으로 저장
    zombie:setVariable("TRWallUpX", forwardX)
    zombie:setVariable("TRWallUpY", forwardY)
    zombie:setVariable("TRWallUpZ", baseSq:getZ() + 1)
    zombie:setVariable("TRWallUpTop", false) -- 이전 클라임의 후반 페이즈 잔여값 리셋
    zombie:setVariable("TRWallUpActive", true)
    zombie:setVariable("hitreaction", "TRWallUpReactionStart")
    trWallUpQueue[zkey(zombie)] = zombie
    trLog(zombie, "wallup: TRIGGER -> (" .. forwardX .. "," .. forwardY .. "," .. (baseSq:getZ() + 1) .. ")")
end

-- ── 트레이서: 창문 즉시파괴 + 볼트 관통 ─────────────────────────────────────
-- Stay Away From Windows(충돌 즉시 파괴) + DiveThroughWindows(볼트 관통) 결합.
-- 닫힌 창문은 충돌 이벤트가 뜨는 순간 깨고, 같은 프레임에 climbOverFence를
-- 호출해 thump/climbwindow를 거치지 않고 바로 Sprint 볼트로 통과한다.
-- (열린/이미 깨진 창문은 충돌이 발생하지 않고 AI가 climbwindow 스테이트로
--  진입 -> climbwindow/TR* 노드가 같은 Sprint 볼트 애님을 재생.)
local function onTracerCollide(character, collider)
    if not instanceof(character, "IsoZombie") then return end
    if not instanceof(collider, "IsoWindow") then return end
    if not isTracer(character) then return end
    if character:getVariableBoolean("ClimbingFence") then return end -- 볼트 중 재트리거 방지
    if collider:isBarricaded() then return end   -- 바리케이드는 바닐라 thump에 위임

    if not collider:IsOpen() and not collider:isSmashed() then
        if collider:isInvincible() then return end
        collider:smashWindow()
        collider:update()
    end

    -- 창문의 부착 방향(N창/W창)과 좀비 위치로 클라임 방향을 산출해 담장 볼트
    -- 강제. climbOverFence는 목적지 walkable만 검사하는 제네릭 경로라 좀비에
    -- 안전하다 (ClimbOverWallState 하드캐스트 크래시 경로와 무관).
    local wsq = collider:getSquare()
    local zsq = character:getCurrentSquare()
    if not wsq or not zsq or wsq:getZ() ~= zsq:getZ() then return end
    local dir
    if collider:getNorth() then
        dir = (zsq:getY() >= wsq:getY()) and IsoDirections.N or IsoDirections.S
    else
        dir = (zsq:getX() >= wsq:getX()) and IsoDirections.W or IsoDirections.E
    end
    character:climbOverFence(dir)
end
Events.OnObjectCollide.Add(onTracerCollide)

-- 피격 시 클라임 강제 해제 (ZombieClimbsWall FixClimbHit 이식) - 애님이 끊겨도
-- collidable=false로 남아 영구 관통 상태가 되는 것을 차단.
Events.OnHitZombie.Add(function(zombie)
    -- hitreaction은 피격 순간 엔진이 먼저 지웠을 수 있으므로 Started도 함께 본다
    if zombie:getVariableBoolean("TRClimbWallStarted")
        or zombie:isVariable("hitreaction", "TRClimbWallReactionStart")
        or zombie:isVariable("hitreaction", "TRClimbWallReactionSuccess") then
        zombie:setCollidable(true)
        zombie:setVariable("TRClimbWallStarted", false)
        zombie:setVariable("hitreaction", nil)
    end
    -- 벽 클라임(z+1) 피격 중단: 텔레포트 없이 원위치 복귀
    if zombie:getVariableBoolean("TRWallUpActive")
        or zombie:getVariableBoolean("TRWallUpStarted") then
        zombie:setVariable("TRWallUpActive", false)
        zombie:setVariable("TRWallUpStarted", false)
        zombie:setVariable("TRWallUpDone", false)
        zombie:setVariable("TRWallUpTop", false)
        if zombie:isVariable("hitreaction", "TRWallUpReactionStart")
            or zombie:isVariable("hitreaction", "TRWallUpReactionSuccess") then
            zombie:setVariable("hitreaction", nil)
        end
    end
end)

-- ── 트레이서: 매 틱 적용기 ──────────────────────────────────────────────────
local function updateTracer(zombie)
    -- climbfence/climbwindow TR* 애님 노드 게이팅용 (매 틱 세팅)
    zombie:setVariable("PuppetTracer", true)

    -- 이속 배율: TR locomotion 노드(walktoward/lunge/pathfind + network 변형)의
    -- m_SpeedScale이 이 변수들을 읽는다. 재생배속=루트모션 이속이므로 이 값이
    -- 곧 이동속도. 바닐라 스프린터 0.80, 런지 0.90 기준 x1.2 배속.
    zombie:setVariable("TracerSpeed", 0.96)
    zombie:setVariable("TracerLungeSpeed", 1.08)

    -- 밀치기/약한 피격 넉다운 면역 (브루트 keepstand와 동일 기법).
    -- 엔진이 넉다운을 강한 피격과 구분하는 별도 플래그를 안 두므로
    -- 전체 넉다운 면역이 된다.
    zombie:setKnockedDown(false)

    -- 낙하 무력화: DoLand()가 fallTime>50이면 확률로 bHardFall을 세워 엎어짐
    -- 분기를 태운다. 매 틱 억제해 착지 후 즉시 추격을 잇는다.
    if zombie:getVariableBoolean("bHardFall") then
        zombie:setVariable("bHardFall", false)
    end

    -- 다리걸기(lunge) 공격 제거: 모드에 이미 있는 검증된 인프라 사용 -
    -- fenceLungePatched/windowLungePatched 노드는 NoLungeAttack==true 조건이
    -- 추가된(조건 수 우위로 바닐라 lunge 노드를 이기는) CheckAttack 이벤트
    -- 제거 변형이다 (HitmanUpdate.UpdateZombies와 동일 패턴). 스폰 직후부터
    -- 매 틱 세팅되므로 climb enter() 시점에 이미 true - 레이스 없음.
    zombie:setVariable("NoLungeAttack", true)

    -- 파쿠르 실패 0%: 스테이트 enter()가 확정한 outcome(lunge/fall/obstacle)을
    -- 매 틱 success로 덮어쓴다. ※주의: 이 덮어쓰기는 enter() '다음 틱'에야
    -- 반영되므로(enter 당일 틱의 애님 평가엔 늦음) lunge의 CheckAttack처럼
    -- 애님 초반에 터지는 이벤트는 이걸로 못 막는다 - 실측으로 다리걸기가
    -- 100% 발동했음. lunge 공격 억제는 위 NoLungeAttack이 전담하고, 이
    -- 블록은 트립/장애물 실패를 성공으로 전환하는 역할만 담당한다.
    -- 단 "falling"(반대편 바닥 없음)은 실패가 아니라 지형 낙하이므로 유지 -
    -- 덮어쓰면 허공에서 착지 모션이 재생된다.
    local state = zombie:getCurrentState()
    if state == ClimbOverFenceState.instance() then
        if not zombie:isVariable("ClimbFenceOutcome", "falling") then
            zombie:setVariable("ClimbFenceOutcome", "success")
        end
    elseif state == ClimbThroughWindowState.instance() then
        if not zombie:isVariable("ClimbWindowOutcome", "falling") then
            zombie:setVariable("ClimbWindowOutcome", "success")
        end
    end

    -- 폴백: 충돌 이벤트를 놓치고 thump 상태로 들어간 경우에도 창문은 즉시
    -- 파괴한다 (다음 프레임 충돌 볼트 or climbwindow로 자연 연결).
    local thumpTarget = zombie:getThumpTarget()
    if thumpTarget and instanceof(thumpTarget, "IsoWindow")
        and not thumpTarget:isDestroyed() then
        thumpTarget:smashWindow()
    end

    updateTracerWallClimb(zombie)
    updateTracerWallUp(zombie)
end
-- ── 로치: 크롤 상태 유지 ─────────────────────────────────────────────────────
-- CDDA_UpdateZombie의 walktype 4 처리와 동일 패턴 — 상태가 풀려도 매 틱 복구.
-- Gore Crawlers & Torn Zombies(DeadWorksZeds) 가 같이 켜져 있으면 그 모드의
-- FPZ_TorsoCrawlers.lua 가 기어다니는 좀비마다 형태를 굴려 FPZ.Crawler* 외형과
-- FPZTorso/FPZLegL/FPZLegR 애님 변수를 붙인다. 로치는 자기 몸통 외형이 따로 있으니
-- 판정 완료 표시(FPZTorsoChecked)를 먼저 세워 굴림을 막고, 이미 붙었으면 떼어 낸다.
-- FPZCrawlState 는 지우지 않는다: 서버 동기값과 같아야 그 모드가 다시 붙이지 않는다.
local function blockFPZCrawl(zombie)
    local md = zombie:getModData()
    md["FPZTorsoChecked"] = true
    local state = md["FPZCrawlState"]
    if state == nil or md["PuppetFPZCleared"] == state then return end
    md["PuppetFPZCleared"] = state
    md["FPZTorso"] = nil
    md["FPZLegVar"] = nil
    zombie:setVariable("FPZTorso", false)
    zombie:setVariable("FPZLegL", false)
    zombie:setVariable("FPZLegR", false)
    -- wornItems 모드에서 getItemVisuals() 를 부르면 외형이 덮어써지므로 건드리지 않는다.
    local removed = 0
    if not zombie:isUsingWornItems() then
        local visuals = zombie:getItemVisuals()
        for i = visuals:size() - 1, 0, -1 do
            local iv = visuals:get(i)
            local t = iv and iv:getItemType()
            if t and string.find(tostring(t), "FPZ.Crawler", 1, true) == 1 then
                visuals:remove(i)
                removed = removed + 1
            end
        end
    end
    if removed > 0 then zombie:resetModelNextFrame() end
    print("[PuppetMutant] roach blocked FPZ crawl state=" .. tostring(state)
        .. " removed=" .. tostring(removed) .. " wornMode=" .. tostring(zombie:isUsingWornItems()))
end

local function updateRoach(zombie)
    blockFPZCrawl(zombie)
    if not zombie:isCrawling() then
        zombie:toggleCrawling()
    end
    zombie:setFallOnFront(true)
    zombie:setCanWalk(false)

    -- 공격 패턴: 물기 대신 담장 런지의 다리걸기만 사용.
    -- 물기 데미지는 애님 오버라이드(roach_attack_success)에서
    -- AttackCollisionCheck 이벤트를 제거해 차단했고, 여기서 담장 런지와
    -- 동일한 효과 함수 attackFromWindowsLunge()를 호출한다. 함수 내부
    -- 게이트(lungeFallTimer 200 쿨다운, z/벽/문/창문 차단 검사, 좀비 오른손
    -- 본 1m 근접판정)가 스스로 제한하므로 공격 상태 동안 매 틱 호출해도
    -- 안전하다 - 손이 닿는 프레임에 정확히 한 번 걸린다.
    -- (AttackState는 IsoZombie OnZombieUpdate 배제 목록에 없어 매 틱 보장)
    local target = zombie:getTarget()
    if target and instanceof(target, "IsoPlayer")
        and zombie:getActionStateName() == "attack" then
        target:attackFromWindowsLunge(zombie)
    end
end

-- ── 적용기 본체 ───────────────────────────────────────────────────────────────
-- 종류는 persistentOutfitID 의 아웃핏 번호로 알아낸다(PongDuMutantId.kindOf).
-- 아웃핏 이름(getOutfitName)은 재사용된 좀비 객체에서 이전 좀비 것이 남아 일반 좀비를
-- 특좀으로 읽을 수 있어 쓰지 않는다. 옷 ID 는 패킷으로 바로 오므로 옷을 입기 전에도 판정된다.
local function outfitKind(zombie, md)
    return PongDuMutantId.kindOf(zombie)
end

local function applyMutant(zombie)
    local md = zombie:getModData()
    local curZid = zombie:getOnlineID()
    local kind = outfitKind(zombie, md)
    if not kind then
        -- 특좀이 아니다. 예전 표식이 남아 있으면(이전 버전 세이브의 시체 modData 등) 지운다.
        if md["PuppetMutant"] then
            print("[PuppetMutant] cleared legacy mark kind=" .. tostring(md["PuppetMutant"])
                .. " outfit=" .. tostring(zombie:getOutfitName()) .. " pid=" .. tostring(zombie:getPersistentOutfitID())
                .. " zid=" .. tostring(curZid))
            md["PuppetMutant"] = nil
            md["PuppetMutantSender"] = nil
            md["PuppetMutantZid"] = nil
            zombie:setVariable("PuppetMutantInit", false)
        end
        return
    end
    local sender = PongDuMutantId.senderOf(zombie)
    if md["PuppetMutant"] ~= kind then
        if md["PuppetMutant"] then
            print("[PuppetMutant] kind changed " .. tostring(md["PuppetMutant"]) .. " -> " .. kind
                .. " zid=" .. tostring(curZid))
        end
        zombie:setVariable("PuppetMutantInit", false)   -- 올바른 종류로 (재)초기화
    end
    -- 클라 로컬 캐시: isTracer·이름표가 modData만 보면 되게 매 틱 아웃핏 값으로 맞춘다.
    -- 후원자 표가 늦게 도착해도(MP 접속 직후) 다음 틱에 이름이 채워진다.
    md["PuppetMutant"] = kind
    md["PuppetMutantSender"] = sender
    md["PuppetMutantZid"] = curZid
    -- BLT 선제 차단: 패스 도중에 새로 스폰된 특좀은 PongDuCompat의 패스 시작
    -- 스캔을 놓치므로, 여기서 매 틱 도장을 갱신해 사각을 없앤다(modData 3필드
    -- 쓰기라 비용은 무시 가능). BLT 미설치 시 bltGen이 nil이라 no-op.
    if PongDuCompat and PongDuCompat.bltStamp then
        PongDuCompat.bltStamp(zombie)
    end
    guardStats(zombie, kind)                           -- 최후 방어선(사후 복구)
    if not zombie:getVariableBoolean("PuppetMutantInit") then
        initMutant(zombie, kind)
        -- 재적용은 initMutant의 초기 체력(샌드박스 설정값)을 다시 씌우므로,
        -- 그동안 입은 전투 피해가 회복돼버린다. 마지막 정상 스냅샷이 더 낮으면
        -- 그 값으로 되돌려 피해를 보존한다(최초 초기화 시엔 스냅샷이 없다).
        local lastHP = _hpSnap[zkey(zombie)]
        if lastHP and lastHP < zombie:getHealth() then
            zombie:setHealth(lastHP)
        end
        _a.pokeTag(zombie)                             -- 소환/부활 직후 잠깐 표기
    end
    _a.pokeTagOnHover(zombie)                          -- 조준+마우스 올림
    if zombie:isAttacking() then                       -- 나를 공격 중일 때
        local t = zombie:getTarget()
        if t and instanceof(t, "IsoPlayer") and t:isLocalPlayer() then
            _a.pokeTag(zombie)
        end
    end
    logDressOnce(zombie, kind, md)
    if kind == "tracer" then tintTracerGrey(zombie, md) end
    applyFixedSkin(zombie, kind, md)
    if kind == "screamer" then
        updateScreamer(zombie)
    elseif kind == "brute" then
        updateBrute(zombie)
    elseif kind == "roach" then
        updateRoach(zombie)
    elseif kind == "tracer" then
        updateTracer(zombie)
    end
end
Events.OnZombieUpdate.Add(applyMutant)

-- 죽을 때 로컬 캐시만 정리한다. 시체·강령술 부활의 특좀 유지는 아웃핏이 담당한다.
Events.OnZombieDead.Add(function(zombie)
    local k = zkey(zombie)
    _nextScream[k] = nil
    _hpSnap[k] = nil                 -- 이름표(_showTags)는 renderTags 가 사망 시 스스로 지운다
end)

-- ═══════════════════════════════════════════════════════════════════════════
--  네임태그: 특수좀비 머리 위 표기 (CDDA CDDA_ShowZombieType 이식)
--  트리거(각 100프레임 페이드): ① 소환/부활 직후  ② 조준 중 마우스 올림
--  ③ 좀비가 로컬 플레이어 공격  ④ 좀비를 타격
--  표기: 후원자가 있으면 "%1의 %2" ("테스트후원자의 브루트"), 없으면 이름만.
-- ═══════════════════════════════════════════════════════════════════════════
local TAG_TTL = 300

local NAME_KEY = {
    screamer = "IGUI_mutant_name_screamer",
    brute    = "IGUI_mutant_name_brute",
    roach    = "IGUI_mutant_name_roach",
    sprinter = "IGUI_mutant_name_sprinter",
    tracer   = "IGUI_mutant_name_tracer",
    slammer  = "IGUI_mutant_name_slammer",
}

local TAG_COLOR = {      -- 스크리머/브루트는 CDDA 원본 색, 로치는 바퀴 갈색
    brute    = {255, 0, 0},
    screamer = {139, 0, 81},
    roach    = {181, 101, 29},
    sprinter = {255, 165, 0},
    tracer   = {0, 200, 180},   -- 파쿠르 테마 청록
    slammer  = {230, 200, 0},   -- 중장비 노랑
}

local _showTags = {}     -- [onlineID] = { zombie=, ttl=, tdo=TextDrawObject }

-- 서버 샌드박스 스위치. 기존 Donation_ShowPanel과 동일하게
-- 사용 시점에 읽는다 (SandboxVars는 파일 로드 시점엔 비어있음).
local function nameTagEnabled()
    return SandboxVars.PongDu.Mutant_NameTag
end

-- CDDA_GetScreenXY 이식: 월드좌표 -> 화면좌표 (줌 보정 포함)
local function screenXY(zombie, offY)
    local sx = IsoUtils.XToScreen(zombie:getX(), zombie:getY(), zombie:getZ(), 0)
    local sy = IsoUtils.YToScreen(zombie:getX(), zombie:getY(), zombie:getZ(), 0)
    sx = sx - IsoCamera.getOffX() - zombie:getOffsetX()
    sy = sy - IsoCamera.getOffY() - zombie:getOffsetY() - offY
    local zoom = getCore():getZoom(0)
    return sx / zoom, sy / zoom
end

local function pokeTag(zombie)
    if not nameTagEnabled() then return end
    local zid = zkey(zombie)
    local t = _showTags[zid]
    if t then
        t.ttl = TAG_TTL
        t.zombie = zombie
    else
        _showTags[zid] = { zombie = zombie, ttl = TAG_TTL }
    end
end
_a.pokeTag = pokeTag

local function tagText(kind, sender)
    local name = getText(NAME_KEY[kind] or NAME_KEY.roach)
    if sender and sender ~= "" then
        return getText("IGUI_mutant_tag_owned", sender, name)
    end
    return name
end

-- 트리거 ②: 조준 중 마우스 올림 (applyMutant에서 특수좀비에 한해 호출)
local function pokeTagOnHover(zombie)
    local player = getPlayer()
    -- B42 는 IsAiming -> isAiming (IsoPlayer.java:3859). B41 이름이면 매 틱 nil 호출
    if not player or not player:isAiming() then return end
    if not zombie:isAlive() or not player:CanSee(zombie) then return end
    local zx, zy = screenXY(zombie, 90)
    local mx, my = getMouseX(), getMouseY()
    if math.abs(zx - mx) < 15 and math.abs(zy - my) < 30 then
        pokeTag(zombie)
    end
end
_a.pokeTagOnHover = pokeTagOnHover

-- 트리거 ④: 타격 시 (CDDA_FuncOnHit과 동일 이벤트)
Events.OnWeaponHitCharacter.Add(function(attacker, target, _weapon, _damage)
    if not instanceof(target, "IsoZombie") then return end
    if not (attacker and instanceof(attacker, "IsoPlayer") and attacker:isLocalPlayer()) then return end
    if target:getModData()["PuppetMutant"] then
        pokeTag(target)
    end
end)

-- 렌더: CDDA와 동일하게 OnTick에서 배치드로우, ttl로 페이드아웃
local function renderTags()
    local player = getPlayer()
    for zid, t in pairs(_showTags) do
        local zombie = t.zombie
        local kind, sender = nil, nil
        if zombie and player and t.ttl > 0
            and zombie:isAlive() and player:CanSee(zombie) then
            kind   = zombie:getModData()["PuppetMutant"]
            sender = zombie:getModData()["PuppetMutantSender"]
        end
        if kind then
            local sx, sy = screenXY(zombie, 190)
            t.tdo = t.tdo or TextDrawObject.new()
            local c = TAG_COLOR[kind] or {255, 255, 255}
            local a = t.ttl / TAG_TTL
            t.tdo:setDefaultColors(c[1] / 255, c[2] / 255, c[3] / 255, a)
            t.tdo:setOutlineColors(0, 0, 0, a)
            t.tdo:ReadString(UIFont.Medium, tagText(kind, sender), -1)
            t.tdo:AddBatchedDraw(sx, sy - t.tdo:getHeight(), true)
            t.ttl = t.ttl - 1
        else
            _showTags[zid] = nil
        end
    end
end
Events.OnTick.Add(renderTags)

return _a
