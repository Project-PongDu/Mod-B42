-- PongDuSyringe.lua : 주사기 4종(전투자극제 / 광범위 항생제 / 모르핀 / 응급 재생) 효과 + 타임드 액션
--
-- [B42 MP] 몸 상태·스탯·아이템은 서버 권위다. 그래서 이 파일을 shared 로 옮겼다
-- (원래 client/features/syringe.lua 에 전부 있었다).
--   * PongDuSyringeAction 에 complete() 가 있어서 MP 클라는 NetTimedAction 으로 서버에 액션을 보내고,
--     서버가 같은 클래스를 new 로 다시 만들어 complete() 를 돌린다(LuaTimedActionNew: complete 가
--     있으면 서버 동기화, IsoGameCharacter: perform 뒤 !GameClient.client 에서 complete).
--     SP 는 perform -> complete 를 로컬에서 순서대로 돈다.
--   * 효과 적용·주사기 소모는 complete() 에서 한다. 스탯은 PongDuStats.applyLocal(서버면 syncPlayerStats),
--     부위는 PongDuBody.syncPart / syncBodyPart, 아이템 제거는 sendRemoveItemFromContainer.
--   * 응급 재생의 부위 체력 바닥값 강제도 서버가 한다. 서버에선 OnPlayerUpdate 가 원격 플레이어에
--     발화하지 않으므로(IsoPlayer.update -> updateRemotePlayer 분기에서 return) OnTick 으로
--     접속자를 돈다. SP 는 기존대로 OnPlayerUpdate.
--   * 모르핀의 공격속도 보정(onWeaponSwing)은 로컬 애니메이션 변수라 클라(client/features/syringe.lua)에
--     남긴다. 그래서 서버는 "Applied" 로 만료 시각을 돌려보내고 클라가 자기 modData 에 미러링한다.
--
-- 아래는 원래 syringe.lua 머리말.
--
-- Syringe_Adrenaline(전투자극제) / Syringe_Doxycycline(광범위 항생제)는
-- FirstAidOverhaul 모드(BB_FAO_ISTimedAction / BB_FAO_ISFillInventoryContextMenu)에서
-- 이식. 원본은 EmptySyringe -> 각종 소재 조합으로 제작하는 레시피 체인이 있었으나,
-- 퐁듀는 후원으로 완성품을 바로 지급하는 구조라 레시피 전체를 제외했다. 그에 따라
-- "사용 후 빈 주사기 반환" 로직도 함께 제외한다(레시피가 없으면 빈 주사기가 아무
-- 데도 못 쓰이는 죽은 아이템이 되므로).
--
-- Syringe_Adrenaline(전투자극제) : 피로/지구력 즉시 회복. 빈사(HP<1) 시 소량 회복.
--                                  FAO 원본의 부작용(배고픔/갈증/패닉)은 주석 처리해뒀다.
-- Syringe_Doxycycline(광범위 항생제) : 감기 + 식중독 + 시체 악취 메스꺼움 +
--                                      상처 세균감염 치료. 좀비 감염(Knox Infection,
--                                      bitten/IsInfected 계열)은 건드리지 않는다 --
--                                      그쪽은 백신(Zomboxivir) 담당.
--
-- Syringe_Morphine(모르핀) / Syringe_Emergency(응급 재생)은 신규 추가. 둘 다
-- "지속시간" 개념이 있는데, 바닐라 PainEffect/PainReduction(BodyDamage.java)은
-- 프레임 단위로 게임속도 배율에 맞춰 감쇠하는 구조라 "정확히 인게임 N시간"을
-- 보장하려면 상수를 역산해야 하고 게임 패치로 조용히 틀어질 위험이 있다.
-- 대신 만료 시각(인게임 ms)을 player modData에 직접 저장하고 Events.EveryOneMinute로
-- 매 틱 강제 재적용하는 방식을 쓴다. 바닐라 내부 상수에 의존하지 않아 인게임 시간
-- 계산이 항상 정확하다.
--
-- Syringe_Morphine  : 즉시 통증 0 + 2인게임시간 동안 통증 억제.
--                     같은 시간 동안 "팔 부상으로 인한 근접 공격속도 감소"도 무시한다.
-- Syringe_Emergency : 즉시 회복은 없다. 주사 시점의 "부위별" 체력을 바닥값으로 잡고,
--                     지속시간 동안 상처 드레인으로 인한 감소만 되돌린다.
--                     자연회복은 그대로 반영(바닥값 동반 상승), 급성 피해도 그대로
--                     들어간다(바닥값 동반 하락). 녹스 감염/저체온 상한은 예외로
--                     두어 그쪽으로는 정상적으로 죽는다.

PongDuSyringe = PongDuSyringe or {}
PongDuSyringe.NET_MODULE = "PongDuSyringe"

require "TimedActions/ISBaseTimedAction"
require "PongDuBody"

local SYRINGE_TYPES = {
    ["t3chzzkDonation.Syringe_Adrenaline"]  = true,
    ["t3chzzkDonation.Syringe_Doxycycline"] = true,
    ["t3chzzkDonation.Syringe_Morphine"]    = true,
    ["t3chzzkDonation.Syringe_Emergency"]   = true,
}

local MORPHINE_DURATION_HOURS = 2
local REGEN_DURATION_HOURS    = 0.5    -- 테스트값. 원래 설계는 1

-- 바닐라 진통제(IsoGameCharacter.PainMeds)가 쓰는 값과 동일.
-- painEffect는 "남은 틱 수" 카운터라 인게임 시간과 직결되지 않으므로 지속시간
-- 판정에는 쓰지 않는다. 우리 만료 시각(인게임 ms)이 남아있는 동안 주기적으로
-- 다시 채워 넣기만 한다.
local MORPHINE_PAIN_EFFECT_TICKS = 5400

local MORPHINE_EXPIRE_KEY = "PongDu_MorphineExpireMS"
local MORPHINE_LOGGED_KEY = "PongDu_MorphineSpeedLogged"
local REGEN_EXPIRE_KEY    = "PongDu_RegenExpireMS"

-- 급성 피해 판정 임계값 (부위 체력 0~100 스케일, 1프레임 기준).
--
-- 아래 enforceHealthFloor는 매 프레임 부위 체력을 바닥값으로 되돌리므로, 관측되는
-- 하락폭은 항상 "정확히 한 프레임분"이다.
--   상처 드레인 최대치: (WoundDamage 3.125 + BiteDamage 2.1875 + BurnDamage 3.75
--     + BulletDamage 3.125 + FractureDamage 3.125) * DamageScaler 0.0057143
--     * multiplier 1.6 = 약 0.14 /프레임
--   좀비 타격 한 방: BodyDamage.DamageFromZombie()에서
--     Rand.Next(1000)/1000 * (Rand.Next(10)+10) = 0~20, 실측 대부분 5 이상
-- 1.0이면 양쪽에서 5~10배 여유가 있다. 드레인은 GameTime multiplier에 선형
-- 비례하므로 임계값도 같이 스케일한다.
local REGEN_HIT_MIN_DROP = 1.0

-- BodyPartType.getDamageModifyer(index) 이식 (41.78.19).
-- BodyDamage.calculateOverallHealth()가
--   overall = 100 - sum((100 - part.Health) * modifier[i])
-- 로 전체 체력을 만들기 때문에, 부위 바닥값 -> 전체 체력 환산에 필요하다.
-- 진단 로그와 엔진 상한 비교에만 쓰고, 복원 자체는 부위 단위로 하므로
-- 이 값이 틀려도 체력 복원 정확도에는 영향이 없다.
local DAMAGE_MOD = {
    [0]  = 0.1,  [1]  = 0.1,  [2]  = 0.2,  [3]  = 0.2,
    [4]  = 0.3,  [5]  = 0.3,  [6]  = 0.35, [7]  = 0.4,
    [8]  = 0.6,  [9]  = 0.7,  [10] = 0.4,  [11] = 0.3,
    [12] = 0.3,  [13] = 0.2,  [14] = 0.2,  [15] = 0.2,
    [16] = 0.2,
}

-- 부위별 바닥값 + 진단 카운터. modData에 넣으면 매 프레임 세이브 대상이 커지므로
-- 런타임 로컬 캐시로만 둔다. 재접속하면 비지만 첫 프레임에 현재 체력으로 다시 잡힌다.
-- regenState[regenKey] = {  (서버=계정명, SP=분할화면 번호)
--     floor    = { [0..16] = 부위 바닥값 },
--     restored = 지난 진단 로그 이후 되돌린 총량(부위 체력 합산),
--     hits     = 지난 진단 로그 이후 급성 피해 감지 횟수,
--     capped   = 엔진 상한(감염/저체온)에 걸려 복원을 포기한 프레임 수,
-- }
local regenState = {}

local function nowMS()
    return getGameTime():getCalender():getTimeInMillis()
end

local function hoursToMS(hours)
    return hours * 3600000
end

-- 로컬 플레이어 순회 (분할화면 대응). getPlayer()는 0번 플레이어만 돌려주므로
-- 코옵에서 2P 이후의 효과가 통째로 죽는다.
local function forEachLocalPlayer(fn)
    for i = 0, 3 do
        local p = getSpecificPlayer(i)
        if p and not p:isDead() then fn(p) end
    end
end

PongDuSyringe.TYPES               = SYRINGE_TYPES
PongDuSyringe.MORPHINE_EXPIRE_KEY = MORPHINE_EXPIRE_KEY
PongDuSyringe.MORPHINE_LOGGED_KEY = MORPHINE_LOGGED_KEY
PongDuSyringe.REGEN_EXPIRE_KEY    = REGEN_EXPIRE_KEY

-- 바닥값 상태 키. 서버는 접속자 여럿이라 계정명, SP/클라는 분할화면 번호.
local function regenKey(playerObj)
    if isServer() then return playerObj:getUsername() end
    return playerObj:getPlayerNum()
end

local function newRegenState(floor)
    return { floor = floor, restored = 0.0, hits = 0, capped = 0, dirty = {}, syncAt = 0 }
end

-- ── 응급 재생: 부위별 HP 바닥값 강제 ─────────────────────────────────────────
--
-- 상처는 일절 건드리지 않는다 -- 물림/화상/골절/총알/찢어진 상처/출혈 전부 그대로
-- 남고, 치료는 플레이어가 직접 해야 한다. 막는 건 오직 "상처 드레인"
-- (BodyPart.DamageUpdate()의 프레임당 지속 감소)뿐이다.
--
-- [왜 전체 체력(OverallBodyHealth) 바닥값을 버리고 부위별로 바꿨는가]
--
-- 이전 구현은 전체 체력 하나를 바닥값으로 잡고 부족분을
-- BodyDamage.AddGeneralHealth()로 밀어넣었는데, 두 가지 이유로 바닥값이 뚫렸다.
--
--  1) 복원 게인이 1보다 작다. ReduceGeneralHealth()는 부위별로
--     (Val/17) / damageModifyer 만큼 깎아서 전체 체력이 정확히 Val 감소하지만,
--     AddGeneralHealth()는 modifier로 나누지 않고 손상 부위 n개에 Val/n씩 그냥
--     더한다. 그래서 실제 전체 체력 회복량은 Val * (sum(mod)/n) 이고, 전 부위
--     손상 시 약 0.30배, 손 하나만 다친 상태면 0.10배까지 떨어진다.
--  2) 호출 순서가 불리하다. 이 훅은 OnPlayerUpdate(IsoPlayer.update 1730행)에서
--     도는데, 드레인(BodyDamage.Update -> DamageUpdate, 2286행)과 전체 체력
--     재계산(2289행)은 그보다 뒤다. 즉 "복원하고 나서 한 프레임분 드레인을 다시
--     맞는" 구조다.
--
--  1 + 2 => 게인 g, 프레임당 드레인 D 인 비례제어기가 되어 바닥값이 아니라
--  gap = D/g 에서 평형을 잡는다. 붕대를 감으면 D가 0이나 절반이라 gap이 거의
--  없어 붙어 보이지만, 붕대를 풀면 D가 튀면서 그만큼 아래로 주저앉는다.
--  (실제 제보 증상: 살균붕대 감았다 풀었더니 바닥값이 뚫림)
--
-- 지금 구현은 부위별 바닥값을 들고 BodyPart:SetHealth()로 직접 되돌린다.
-- 희석이 없어 게인이 정확히 1이고, calculateOverallHealth()는 부위 체력의 순수
-- 함수이므로 전체 체력도 자동으로 맞는다.
--
-- 바닥값은 부위 단위로 이렇게 움직인다:
--   (1) 자연회복 등으로 부위 체력이 바닥값 위로 오르면 바닥값도 같이 올린다.
--   (2) 한 프레임에 임계값 이상 급락하면 급성 피해로 보고 바닥값을 내린다.
--   (3) 그 외 하락(= 상처 드레인)은 되돌린다.
--
-- (2)의 감지를 이벤트가 아니라 체력 급락으로 하는 이유: 좀비의 물기/할큄/베임은
-- BodyDamage.DamageFromZombie()가 BodyPart.AddDamage()를 직접 부르고 끝이라 Lua
-- 이벤트가 아예 발생하지 않는다. OnPlayerGetDamage는 WEAPONHIT/FIRE/FALLDOWN/
-- CAR*/BLEEDING 등에만 붙어 있고, LuaEventManager에 등록만 돼 있는
-- OnBeingHitByZombie는 어디서도 트리거되지 않는 죽은 이벤트다.

-- 엔진이 전체 체력에 거는 상한을 계산한다. 상한이 걸린 동안은 복원을 포기하고
-- 바닥값을 현재 체력에 맞춰 내린다 -- 안 그러면 매 프레임 서로 밀고 당기면서
-- 녹스 감염으로 죽지 않는 사실상 무적 상태가 된다.
--
--  - 녹스 감염 (BodyDamage.Update 2276행)
--        float7 = (1 - p^4) * 100,  p = InfectionLevel/100
--        if overall > float7 and float7 <= 99 then ReduceGeneralHealth(overall - float7)
--    p == 1 이면 ReduceGeneralHealth(110)으로 즉사시킨다.
--  - 저체온 (BodyDamage.UpdateTemperatureState 2393행)
--        float1 = 100 - ColdDamageStage * 100
--        if overall > float1 then ReduceGeneralHealth(overall - float1)
--
-- 둘 다 이 훅보다 뒤에 돌기 때문에 우리가 복원해도 같은 프레임에 다시 깎인다.
local function getEngineHealthCap(bodyDamage)
    local cap = 100.0

    if bodyDamage:isInfected() then
        -- B42: BodyDamage:getInfectionLevel() 제거 -> Stats ZOMBIE_INFECTION (0~100)
        local p = bodyDamage:getParentChar():getStats():get(CharacterStat.ZOMBIE_INFECTION) / 100.0
        local p4 = p * p
        p4 = p4 * p4
        local c = (1.0 - p4) * 100.0
        if c <= 99.0 and c < cap then cap = c end
    end

    local cold = bodyDamage:getColdDamageStage()
    if cold > 0.0 then
        local c = 100.0 - cold * 100.0
        if c < cap then cap = c end
    end

    return cap
end

-- 부위 바닥값 -> 전체 체력 환산 (calculateOverallHealth 이식). 진단 로그와
-- 엔진 상한 비교에만 쓴다.
local function floorToOverall(floor)
    local deficit = 0.0
    for i = 0, 16 do
        deficit = deficit + (100.0 - floor[i]) * DAMAGE_MOD[i]
    end
    if deficit > 100.0 then deficit = 100.0 end
    return 100.0 - deficit
end

local function seedFloor(bodyDamage)
    local parts = bodyDamage:getBodyParts()
    local floor = {}
    for i = 0, 16 do
        floor[i] = parts:get(i):getHealth()
    end
    return floor
end

local function enforceHealthFloor(playerObj)
    local md = playerObj:getModData()
    if not md[REGEN_EXPIRE_KEY] then return end

    local bodyDamage = playerObj:getBodyDamage()
    if not bodyDamage then return end

    local key = regenKey(playerObj)
    local st = regenState[key]
    if not st then
        st = newRegenState(seedFloor(bodyDamage))
        regenState[key] = st
        print("[PongDu] syringe: regen floor seeded (no state), player=" .. tostring(key)
            .. ", overall=" .. tostring(floorToOverall(st.floor)))
        return
    end

    local floor = st.floor
    local parts = bodyDamage:getBodyParts()

    -- 엔진 상한이 우리 목표보다 낮으면 복원을 포기한다.
    local cap = getEngineHealthCap(bodyDamage)
    local target = floorToOverall(floor)
    if cap < target then
        for i = 0, 16 do
            floor[i] = parts:get(i):getHealth()
        end
        st.capped = st.capped + 1
        return
    end

    local threshold = REGEN_HIT_MIN_DROP * (getGameTime():getMultiplier() / 1.6)

    for i = 0, 16 do
        local bp = parts:get(i)
        local h = bp:getHealth()
        local f = floor[i]

        if h > f then
            -- (1) 자연회복. 바닥값 동반 상승
            floor[i] = h
        elseif h < f then
            local drop = f - h
            if drop > threshold then
                -- (2) 급성 피해. 바닥값을 내리고 되돌리지 않는다
                floor[i] = h
                st.hits = st.hits + 1
                print("[PongDu] syringe: regen floor lowered by damage, part="
                    .. BodyPartType.ToString(BodyPartType.FromIndex(i))
                    .. ", drop=" .. tostring(drop)
                    .. ", floor=" .. tostring(h))
            else
                -- (3) 상처 드레인. 되돌린다
                bp:SetHealth(f)
                st.restored = st.restored + drop
                st.dirty[i] = true
            end
        end
    end

    -- [B42 MP] 서버에서 되돌린 부위 체력은 syncBodyPart(BD_Health = 1)로 소유 클라에 내려보낸다.
    -- 매 프레임 보내면 패킷이 넘치므로 1초에 한 번, 바뀐 부위만. 그 사이 클라 표시는 서버의
    -- 주기 동기화를 따른다.
    if isServer() then
        local now = getTimestampMs()
        if now - st.syncAt >= 1000 then
            st.syncAt = now
            for i = 0, 16 do
                if st.dirty[i] then
                    syncBodyPart(parts:get(i), 1)
                    st.dirty[i] = nil
                end
            end
        end
    end
end

-- ── 타임드 액션: 실제 주사 수행 ────────────────────────────────────────────────

PongDuSyringeAction = ISBaseTimedAction:derive("PongDuSyringeAction")

function PongDuSyringeAction:isValid()
    return self.character:getInventory():contains(self.syringeItem)
end

function PongDuSyringeAction:start()
    self:setActionAnim(CharacterActionAnims.Bandage)
    self:setAnimVariable("BandageType", "LeftArm")
    -- 4종 공통 주사음. 23a2cddc59fe561bba91dd21a3759f1ee96207c0에서 추가된
    -- SFX_Inject.wav를 t3_rewards_sounds.txt에 pongdu_syringe_inject로 등록해 재생한다.
    -- 실패(성공/실패 판정)와 무관하게 "주사 행위" 자체에 붙는 소리라 start()에서 1회 재생.
    self.character:getEmitter():playSound("pongdu_syringe_inject")
end

function PongDuSyringeAction:stop()
    ISBaseTimedAction.stop(self)
end


-- 회복 수치는 FAO 원본 그대로이나, 부작용(배고픔 +0.3 / 갈증 +0.5)은
-- 비활성화했다. 원본은 플레이어가 직접 제작하는 소모품이라 대가가 있었지만, 퐁듀에서는
-- 시청자가 후원으로 보내주는 보상이라 페널티가 붙을 이유가 없다. 되살릴 때를 대비해
-- 지우지 않고 주석으로 남겨둔다.
--
-- 참고: 아래 getHealth()/setHealth()는 IsoGameCharacter의 레거시 Health 필드(0~1)로,
-- 플레이어 체력바(BodyDamage.OverallBodyHealth, 0~100)와는 별개이고 플레이어에서는
-- 사실상 항상 1이다. 즉 이 체력 회복 분기는 실제로는 거의 발동하지 않는다.
-- 원본 동작을 그대로 두기로 한 결정이므로 손대지 않는다.
local function applyAdrenaline(playerObj, stats)
    -- B42: 개별 setter 제거 + MP 서버 권위 -> shared/PongDuStats.lua (범위 clamp 는 엔진이 한다)
    PongDuStats.applyLocal(playerObj, {
        { op = "add", stat = "FATIGUE",   v = -0.7 },
        { op = "add", stat = "ENDURANCE", v = 0.85 },
        { op = "add", stat = "PANIC",     v = 15 },
    }, "syringe_adrenaline")

    if playerObj:getHealth() < 1 then
        playerObj:setHealth(playerObj:getHealth() + 0.2)
    end

    print("[PongDu] syringe: Syringe_Adrenaline applied")
end

-- 광범위 항생제. 좀비 감염(Knox)을 제외한 병증 전부를 즉시 없앤다.
--
-- ── 아래 3줄을 비활성화한 이유 (전부 41.78.19 소스 확인) ──
--
--  stats:setSickness(0)
--    Stats.Sickness 는 독립 상태값이 아니라 파생 표시값이다. Moodle.java:236 이
--    Sick 무들 갱신 때마다 getApparentInfectionLevel()/100 으로 덮어쓴다
--    (= FakeInfectionLevel / InfectionLevel / FoodSicknessLevel 중 최댓값).
--    바닐라 전체에 setSickness 호출처가 없다. 근원을 지우면 자동으로 0이 된다.
--
--  bodyDamage:setInfected(false) / setInfectionLevel(0)
--    전신 플래그(BodyDamage.IsInfected)만 끄는 것이라 다음 프레임에 되살아난다.
--    BodyDamage.Update():2017 이 !isInfected() 일 때 부위별 플래그
--    (BodyPart.IsInfected -- 별개 필드)를 훑어 즉시 setInfected(true) 하고,
--    InfectionLevel 도 InfectionTime 기반으로 원래 진행도까지 재계산된다.
--    제대로 치료하려면 부위별 SetInfected(false) + InfectionTime 리셋까지
--    필요한데, 그건 백신(Zomboxivir)의 역할이라 항생제에서는 다루지 않는다.
local function applyDoxycycline(playerObj, stats, bodyDamage)
    -- stats:setSickness(0)
    -- bodyDamage:setInfected(false)
    -- bodyDamage:setInfectionLevel(0)

    -- 감기. ColdStrength 는 UpdateCold() 에서 자연 감소로만 0 이 되는 값이라
    -- (BodyDamage.java:891) 아이템으로 끝내려면 두 필드를 같이 눌러야 한다.
    -- getColdStrength() 가 HasACold 를 먼저 보고 분기하므로 순서는 무관.
    bodyDamage:setHasACold(false)
    bodyDamage:setColdStrength(0)

    -- 진행 중이던 재채기/기침도 즉시 끊는다. 감기가 나은 뒤에도 카운터가 남아
    -- 몇 초 더 기침하는 게 어색해서 함께 정리한다.
    bodyDamage:setSneezeCoughActive(0)
    bodyDamage:setSneezeCoughTime(0)

    -- 식중독. 상한 음식/날음식 섭취로 쌓이는 진짜 식중독은 PoisonLevel(B42: POISON) 이다
    -- (JustAteFood(): PoisonPower / isTaintedWater / bDangerousUncooked 경로).
    -- 시체 악취로 인한 메스꺼움(FoodSicknessLevel, B42: FOOD_SICKNESS). 이름과 달리 음식과
    -- 무관하며 주변 시체 수로만 올라간다. POISON 이 0 이 아니면 자연 감소가 막혀 있어
    -- POISON 을 먼저 내린다 (ops 는 배열 순서대로 적용된다).
    PongDuStats.applyLocal(playerObj, {
        { op = "set", stat = "POISON",        v = 0 },
        { op = "set", stat = "FOOD_SICKNESS", v = 0 },
    }, "syringe_doxycycline")

    -- 상처 세균감염. isInfectedWound() 만 끄면 woundInfectionLevel 이 남아 곧
    -- 재발하므로(BodyPart.DamageUpdate():293 이 확률로 다시 true) 근원값을
    -- 0 으로 내린다. setWoundInfectionLevel() 이 0 이하일 때 setInfectedWound(false)
    -- 까지 알아서 처리한다(BodyPart.java:1285).
    local bodyParts = bodyDamage:getBodyParts()
    local cured = 0
    for i = 0, BodyPartType.MAX:index() - 1 do
        local bodyPart = bodyParts:get(i)
        if bodyPart:getWoundInfectionLevel() > 0 then
            bodyPart:setWoundInfectionLevel(0)
            cured = cured + 1
            PongDuBody.syncPart(bodyPart)
        elseif bodyPart:isInfectedWound() then
            bodyPart:setInfectedWound(false)
            cured = cured + 1
            PongDuBody.syncPart(bodyPart)
        end
    end

    print("[PongDu] syringe: Syringe_Doxycycline applied, curedWounds=" .. tostring(cured))
end

-- 모르핀: 통증 억제는 바닐라 진통제와 같은 painEffect 메커니즘을 쓴다.
--
-- BodyDamage.Update()는 painEffect > 0 이면 통증을 매 틱 자동으로 깎고, 부위별
-- 통증에서 다시 계산하는 경로 자체를 건너뛴다. 즉 통증 억제를 자바가 대신
-- 굴려주므로 Lua는 매 틱 아무것도 안 해도 된다.
--
-- 다만 painEffect는 인게임 시간이 아니라 "남은 틱 수"라서 지속시간을 이걸로
-- 재면 게임 속도/프레임에 휘둘린다. 그래서 지속시간은 우리 만료 시각(인게임 ms)이
-- 관리하고, painEffect는 인게임 1분마다 다시 채우기만 한다.
--
-- 공격속도 페널티 무시는 onWeaponSwing 쪽에서 처리한다. painEffect는 Stats.Pain만
-- 누르고 BodyPart.getPain()(부위 통증)은 그대로 두는데, 공격속도 계산은 후자를
-- 보기 때문에 통증 억제만으로는 전혀 해결되지 않는다.
local function applyMorphine(playerObj, stats)
    PongDuStats.applyLocal(playerObj, { { op = "set", stat = "PAIN", v = 0 } }, "syringe_morphine")  -- 즉시 제거
    playerObj:setPainEffect(MORPHINE_PAIN_EFFECT_TICKS)       -- 이후 억제는 바닐라가 담당

    local md = playerObj:getModData()
    local expireAt = nowMS() + hoursToMS(MORPHINE_DURATION_HOURS)
    md[MORPHINE_EXPIRE_KEY] = expireAt
    md[MORPHINE_LOGGED_KEY] = nil

    print("[PongDu] syringe: Syringe_Morphine applied, expire=" .. tostring(expireAt))
end

-- 응급 재생: 즉시 회복도, 지속 회복도 없다. 지금 부위별 체력을 그대로 바닥값으로 잡는다.
local function applyEmergencyRegen(playerObj)
    local md = playerObj:getModData()
    local bodyDamage = playerObj:getBodyDamage()
    local key = regenKey(playerObj)

    local expireAt = nowMS() + hoursToMS(REGEN_DURATION_HOURS)
    md[REGEN_EXPIRE_KEY] = expireAt

    local floor = seedFloor(bodyDamage)
    regenState[key] = newRegenState(floor)

    print("[PongDu] syringe: Syringe_Emergency applied, player=" .. tostring(key)
        .. ", overall=" .. tostring(bodyDamage:getOverallBodyHealth())
        .. ", floorOverall=" .. tostring(floorToOverall(floor))
        .. ", cap=" .. tostring(getEngineHealthCap(bodyDamage))
        .. ", expire=" .. tostring(expireAt))
end

function PongDuSyringeAction:perform()
    -- 효과·소모는 complete() 에서 한다 (MP 는 서버, SP 는 perform 직후 로컬).
    ISBaseTimedAction.perform(self)
end

function PongDuSyringeAction:complete()
    local playerObj = self.character
    local item = self.syringeItem
    local stats = playerObj and playerObj:getStats()
    local bodyDamage = playerObj and playerObj:getBodyDamage()

    if not item or not stats or not bodyDamage then
        print("[PongDu] syringe: missing item/stats/bodyDamage, aborting (server=" .. tostring(isServer()) .. ")")
        return false
    end

    local fullType = item:getFullType()

    if fullType == "t3chzzkDonation.Syringe_Adrenaline" then
        applyAdrenaline(playerObj, stats)
    elseif fullType == "t3chzzkDonation.Syringe_Doxycycline" then
        applyDoxycycline(playerObj, stats, bodyDamage)
    elseif fullType == "t3chzzkDonation.Syringe_Morphine" then
        applyMorphine(playerObj, stats)
    elseif fullType == "t3chzzkDonation.Syringe_Emergency" then
        applyEmergencyRegen(playerObj)
    else
        print("[PongDu] syringe: unknown syringe type " .. tostring(fullType))
        return false
    end

    local container = item:getContainer()
    if container then
        container:Remove(item)
        sendRemoveItemFromContainer(container, item)
    end

    if isServer() then
        local md = playerObj:getModData()
        sendServerCommand(playerObj, PongDuSyringe.NET_MODULE, "Applied", {
            ["type"]           = fullType,
            ["morphineExpire"] = md[MORPHINE_EXPIRE_KEY],
            ["regenExpire"]    = md[REGEN_EXPIRE_KEY],
        })
    end
    print("[PongDu] syringe: consumed " .. tostring(fullType)
        .. " server=" .. tostring(isServer())
        .. " user=" .. tostring(playerObj:getUsername()))
    return true
end

-- ── 지속 효과 틱 핸들러 (인게임 1분) ──────────────────────────────────────────
-- 만료 판정, painEffect 갱신, 그리고 응급 재생 진단 로그.

local function tickMorphine(playerObj)
    local md = playerObj:getModData()
    local expireAt = md[MORPHINE_EXPIRE_KEY]
    if not expireAt then return end

    if nowMS() < expireAt then
        -- painEffect는 틱마다 소모되므로 주기적으로 다시 채운다.
        playerObj:setPainEffect(MORPHINE_PAIN_EFFECT_TICKS)
    else
        md[MORPHINE_EXPIRE_KEY] = nil
        md[MORPHINE_LOGGED_KEY] = nil
        playerObj:setPainEffect(0)   -- 남은 잔량을 끊어 즉시 종료시킨다
        print("[PongDu] syringe: Morphine effect ended")
    end
end

-- 진단 로그. 바닥값이 또 뚫리면 이 로그만 보고 원인을 좁힐 수 있어야 한다.
--   overall  : 실제 전체 체력
--   target   : 부위 바닥값에서 환산한 목표 전체 체력 (overall과 벌어지면 복원 실패)
--   cap      : 엔진 상한. target보다 낮으면 그 프레임은 복원을 포기한 상태
--   restored : 지난 1분간 되돌린 부위 체력 총합 (드레인 강도)
--   hits     : 지난 1분간 급성 피해로 바닥값을 내린 횟수
--   capped   : 지난 1분간 엔진 상한 때문에 복원을 포기한 프레임 수
--   inf/cold : 상한을 만든 원인값
--   held     : 바닥값이 100 미만인 부위 수 (복원 대상 부위 수)
local function logRegenDiag(playerObj, bodyDamage, st)
    local floor = st.floor
    local held = 0
    for i = 0, 16 do
        if floor[i] < 100.0 then held = held + 1 end
    end

    print("[PongDu] syringe: regen diag player=" .. tostring(regenKey(playerObj))
        .. " overall=" .. tostring(bodyDamage:getOverallBodyHealth())
        .. " target=" .. tostring(floorToOverall(floor))
        .. " cap=" .. tostring(getEngineHealthCap(bodyDamage))
        .. " restored=" .. tostring(st.restored)
        .. " hits=" .. tostring(st.hits)
        .. " capped=" .. tostring(st.capped)
        .. " inf=" .. tostring(playerObj:getStats():get(CharacterStat.ZOMBIE_INFECTION))
        .. " cold=" .. tostring(bodyDamage:getColdDamageStage())
        .. " held=" .. tostring(held))

    st.restored = 0.0
    st.hits = 0
    st.capped = 0
end

local function tickRegen(playerObj)
    local md = playerObj:getModData()
    local expireAt = md[REGEN_EXPIRE_KEY]
    if not expireAt then return end

    local key = regenKey(playerObj)
    local bodyDamage = playerObj:getBodyDamage()

    if nowMS() < expireAt then
        local st = regenState[key]
        if st and bodyDamage then
            logRegenDiag(playerObj, bodyDamage, st)
        end
    else
        local st = regenState[key]
        if st and bodyDamage then
            print("[PongDu] syringe: EmergencyRegen effect ended, overall="
                .. tostring(bodyDamage:getOverallBodyHealth())
                .. ", target=" .. tostring(floorToOverall(st.floor))
                .. ", hits=" .. tostring(st.hits)
                .. ", capped=" .. tostring(st.capped))
        else
            print("[PongDu] syringe: EmergencyRegen effect ended (no state)")
        end
        md[REGEN_EXPIRE_KEY] = nil
        regenState[key] = nil
    end
end


-- 서버용: tickRegen 은 진단 로그를 같이 찍어서 1초마다 부르면 넘친다. 만료만 보고, 진단은 60초에 한 번.
local _diagAt = {}
local function tickRegenExpireOnly(playerObj)
    local md = playerObj:getModData()
    local expireAt = md[REGEN_EXPIRE_KEY]
    if not expireAt then return end
    local key = regenKey(playerObj)
    local now = getTimestampMs()
    if nowMS() >= expireAt or now - (_diagAt[key] or 0) >= 60000 then
        _diagAt[key] = now
        tickRegen(playerObj)
        if not md[REGEN_EXPIRE_KEY] then _diagAt[key] = nil end
    end
end

-- 급성 피해 보조 신호.
--
-- 주 판정은 부위 체력 급락이다. 이 이벤트는 그게 놓칠 수 있는 경우(여러 부위에
-- 임계값 미만으로 얕게 퍼진 피해)를 위한 보조로, 해당 프레임의 임계값을 0으로
-- 낮춰 어떤 하락이든 급성 피해로 처리하게 만든다.
-- 피격 데미지값은 무기 데미지 단위라 부위 체력 델타로 환산할 수 없으므로 쓰지 않는다.
-- BLEEDING/POISON/HUNGRY/SICK/THIRST/HEAVYLOAD/INFECTION 계열은 지속 드레인이라
-- 일부러 제외했다.
local REBASELINE_DAMAGE_TYPES = {
    WEAPONHIT      = true,
    FIRE           = true,
    FALLDOWN       = true,
    CARHITDAMAGE   = true,
    CARCRASHDAMAGE = true,
}

local function onPlayerGetDamage(character, damageType, amount)
    if not character or not REBASELINE_DAMAGE_TYPES[damageType] then return end

    -- IsoGameCharacter.Hit()은 *맞은 대상*으로 이벤트를 쏜다. 플레이어가 좀비를
    -- 때리면 좀비로 들어오므로 걸러낸다.
    if not instanceof(character, "IsoPlayer") then return end
    if not isServer() and not character:isLocalPlayer() then return end
    -- MP 클라는 바닥값을 갖지 않는다(서버가 강제). SP/서버만.
    if isClient() then return end

    local st = regenState[regenKey(character)]
    if not st then return end

    -- 이 이벤트는 한 프레임 안에서 BodyDamage.Update()보다 먼저 도착할 수 있어
    -- 즉시 바닥값을 내리면 아직 반영 안 된 피해까지 같이 잘라먹는다. 대신
    -- 부위 바닥값을 현재 체력으로 동기화해두면, 다음 프레임에 들어오는 피해분이
    -- 그대로 남는다.
    local bodyDamage = character:getBodyDamage()
    if not bodyDamage then return end
    local parts = bodyDamage:getBodyParts()
    for i = 0, 16 do
        local h = parts:get(i):getHealth()
        if h < st.floor[i] then st.floor[i] = h end
    end

    print("[PongDu] syringe: regen floor synced by event, type=" .. tostring(damageType)
        .. ", amount=" .. tostring(amount))
end


local function onEveryOneMinute()
    forEachLocalPlayer(function(playerObj)
        tickMorphine(playerObj)
        tickRegen(playerObj)
    end)
end

-- 바닥값 강제는 프레임 단위로 돌린다. 분 단위로는 그 사이 드레인이 눈에 보이게
-- 깎였다가 되돌아오는 톱니가 생긴다. 조기 return이 대부분이라 비용은 무시할 수준
-- (효과가 없으면 modData 조회 한 번에서 끝난다).
-- MP 클라는 강제하지 않는다. 클라에서 SetHealth 한 값은 서버 값에 덮이고, 서버가 같은 일을 한다.
local function onPlayerUpdate(playerObj)
    if not playerObj or isClient() then return end
    enforceHealthFloor(playerObj)
end

-- 서버: 접속자 전원. 바닥값 강제는 매 틱, 만료/모르핀 재충전은 1초마다.
-- (EveryOneMinute 를 서버에서 믿지 않고 실시간 1초 간격으로 만료를 본다. 만료 시각 자체는
--  인게임 ms 라 판정 결과는 같다.)
local _serverTickAt = 0
local function onServerTick()
    local players = getOnlinePlayers()
    if not players then return end
    local now = getTimestampMs()
    local doTimers = now - _serverTickAt >= 1000
    if doTimers then _serverTickAt = now end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p and not p:isDead() then
            local md = p:getModData()
            if md[REGEN_EXPIRE_KEY] then enforceHealthFloor(p) end
            if doTimers then
                if md[MORPHINE_EXPIRE_KEY] then tickMorphine(p) end
                if md[REGEN_EXPIRE_KEY] then tickRegenExpireOnly(p) end
            end
        end
    end
end

Events.EveryOneMinute.Add(onEveryOneMinute)
Events.OnPlayerUpdate.Add(onPlayerUpdate)
Events.OnPlayerGetDamage.Add(onPlayerGetDamage)
if isServer() then
    Events.OnTick.Add(onServerTick)
end

-- 클라: 서버 적용 결과 미러링 (OnServerCommand 는 클라에서만 발화).
-- 모르핀 공격속도 보정(client/features/syringe.lua onWeaponSwing)이 로컬 modData 의 만료 시각을 본다.
-- 항생제의 감기 필드(BodyDamage 전체 값)는 BodyPartSyncPacket 에 없어 클라에도 같이 끈다.
Events.OnServerCommand.Add(function(module, command, args)
    if module ~= PongDuSyringe.NET_MODULE or command ~= "Applied" then return end
    local player = getPlayer()
    if not player or type(args) ~= "table" then return end
    local md = player:getModData()
    local t = args["type"]
    if t == "t3chzzkDonation.Syringe_Morphine" then
        md[MORPHINE_EXPIRE_KEY] = args["morphineExpire"]
        md[MORPHINE_LOGGED_KEY] = nil
        player:setPainEffect(MORPHINE_PAIN_EFFECT_TICKS)
    elseif t == "t3chzzkDonation.Syringe_Emergency" then
        md[REGEN_EXPIRE_KEY] = args["regenExpire"]
    elseif t == "t3chzzkDonation.Syringe_Doxycycline" then
        local bd = player:getBodyDamage()
        if bd then
            bd:setHasACold(false)
            bd:setColdStrength(0)
            bd:setSneezeCoughActive(0)
            bd:setSneezeCoughTime(0)
        end
    end
    print("[PongDu] syringe: server applied " .. tostring(t)
        .. " morphineExpire=" .. tostring(args["morphineExpire"])
        .. " regenExpire=" .. tostring(args["regenExpire"]))
end)

-- [B42 MP] 서버는 NetTimedAction 으로 이 new 를 다시 부른다. 인자 이름(character, syringeItem)으로
-- 클라 액션 테이블의 같은 이름 필드를 읽어 보내므로(NetTimedAction.set: new 의 locvars 순회),
-- 인자 이름과 필드 이름이 반드시 같아야 한다. 예전 이름 playerObj 는 필드가 없어 null 로 갔다.
function PongDuSyringeAction:new(character, syringeItem)
    local action = ISBaseTimedAction.new(self, character)
    action.character = character
    action.syringeItem = syringeItem
    -- 이동하면서도 주사를 놓을 수 있어야 해서 걷기/뛰기로 액션이 취소되지 않게 한다.
    action.stopOnWalk = false
    action.stopOnRun = false
    -- ISBaseTimedAction:adjustMaxTime()은 ignoreHandsWounds가 꺼져 있으면
    -- Hand_L ~ ForeArm_R 4부위의 getPain()을 maxTime에 그대로 더한다(부위당 최대
    -- 100, 합쳐서 최대 +400). 그래서 maxTime을 아무리 줄여도 팔을 다치면
    -- 시전시간이 수백으로 뛴다. 응급용 주사기라 이 가산을 받지 않게 한다.
    -- (바닐라도 ISEatFoodAction, ISDrinkFromBottle, ISEquipWeaponAction 등에서
    --  같은 플래그를 쓴다)
    action.ignoreHandsWounds = true
    -- 응급 지혈제(Syringe_Emergency)는 즉효성이 생명이라 기존 시간(10) 유지.
    -- 나머지 3종(Adrenaline/Doxycycline/Morphine)은 시전시간을 10배(100)로 늘린다.
    if syringeItem:getFullType() == "t3chzzkDonation.Syringe_Emergency" then
        action.maxTime = 10
    else
        action.maxTime = 100
    end
    if action.character:isTimedActionInstant() then action.maxTime = 1 end
    return action
end
