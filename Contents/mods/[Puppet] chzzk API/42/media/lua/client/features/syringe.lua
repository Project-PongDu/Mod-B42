-- syringe.lua : 주사기 4종의 클라 전용 부분 (인벤 우클릭 "주사하기" + 모르핀 공격속도 보정)
--
-- [B42] 효과·소모·응급 재생 바닥값·지속시간 관리와 타임드 액션 클래스(PongDuSyringeAction)는
-- 서버 권위 때문에 shared/PongDuSyringe.lua 로 옮겼다. 각 주사기의 효과 설명도 그쪽 머리말 참고.
-- 여기 남은 건 로컬 플레이어 UI/애니메이션에만 걸리는 것들이다.

require "PongDuSyringe"

local SYRINGE_TYPES       = PongDuSyringe.TYPES
local MORPHINE_EXPIRE_KEY = PongDuSyringe.MORPHINE_EXPIRE_KEY
local MORPHINE_LOGGED_KEY = PongDuSyringe.MORPHINE_LOGGED_KEY

-- ── 모르핀: 팔 부상 공격속도 페널티 무시 ──────────────────────────────────────
--
-- IsoGameCharacter.calculateCombatSpeed()는 마지막에
--     float0 *= this.combatSpeedModifier;
--     float0 *= this.getArmsInjurySpeedModifier();
--     float0 = clamp(float0, 0.8, 1.6);
-- 를 거쳐 IsoPlayer.combatSpeed(= 애님 변수 "CombatSpeed")에 들어간다.
-- getArmsInjurySpeedModifier()와 calculateInjurySpeed()는 전부 private라
-- Lua에서 갈아끼울 수 없다. 대신 그 두 함수가 읽는 입력(BodyPart의 상처 시간과
-- 속도 모디파이어)은 전부 public getter로 노출돼 있으므로, 같은 계산을 Lua에서
-- 재현해 배율을 구한 뒤 CombatSpeed를 나눠서 되돌린다.
--
-- 한계 두 가지 (의도적으로 감수한다):
--  1) 바닐라가 이미 [0.8, 1.6]으로 클램프한 뒤라, 부상이 하한을 때린 경우
--     원래 값을 정확히 복원할 수는 없다. 상한 1.6은 그대로 지킨다.
--  2) 이식한 계산식은 41.78.19 기준이다. 바닐라가 공식을 바꾸면 같이 손봐야 한다.
--     (그래서 배율이 1 이상이면 아무것도 건드리지 않고 조용히 빠진다)

local function calcFractureInjurySpeed(bp)
    local v = 0.4
    if bp:getFractureTime() > 10.0 then v = 0.7 end
    if bp:getFractureTime() > 20.0 then v = 1.0 end
    if bp:getSplintFactor() > 0.0 then
        v = v - 0.2
        v = v - math.min(bp:getSplintFactor() / 10.0, 0.8)
    end
    if v < 0.0 then v = 0.0 end
    return v
end

-- IsoGameCharacter.calculateInjurySpeed(bodyPart, true) 의 팔(arm) 경로 이식.
-- 발(Foot_L/R) 전용 분기는 팔에서 절대 타지 않으므로 제외했다.
local function calcArmInjurySpeed(bp)
    if bp:haveBullet() then return 1.0 end

    local v = 0.0
    if bp:getScratchTime() > 2.0
        or bp:getCutTime() > 5.0
        or bp:getBurnTime() > 0.0
        or bp:getDeepWoundTime() > 0.0
        or bp:isSplint()
        or bp:getFractureTime() > 0.0
        or bp:getBiteTime() > 0.0 then

        v = v + bp:getScratchTime()   / bp:getScratchSpeedModifier()
              + bp:getCutTime()       / bp:getCutSpeedModifier()
              + bp:getBurnTime()      / bp:getBurnSpeedModifier()
              + bp:getDeepWoundTime() / bp:getDeepWoundSpeedModifier()
        v = v + bp:getBiteTime() / 20.0

        if bp:bandaged() then v = v / 2.0 end
        if bp:getFractureTime() > 0.0 then v = calcFractureInjurySpeed(bp) end
    end

    -- boolean0(= 팔 판정)일 때만 붙는 항. 여기서 쓰는 pain은 부위 통증이라
    -- painEffect(모르핀의 전체 통증 억제)로는 절대 0이 되지 않는다.
    if bp:getPain() > 20.0 then
        v = v + bp:getPain() / 10.0
    end

    return v
end

local ARM_PARTS = { BodyPartType.Hand_R, BodyPartType.ForeArm_R, BodyPartType.UpperArm_R }

local function getArmsInjurySpeedModifier(bodyDamage)
    local mod = 1.0
    for i = 1, 3 do
        local v = calcArmInjurySpeed(bodyDamage:getBodyPart(ARM_PARTS[i]))
        if v > 0.0 then mod = mod - v end
    end
    return mod
end

-- GameTime.getAnimSpeedFix()는 상수 0.8. calculateCombatSpeed()는
--     return float0 * (boolean0 ? GameTime.getAnimSpeedFix() : 1.0F);
-- 로 끝나는데, boolean0은 "Axeman 특성 + 도끼 카테고리 무기로 나무를 베는 중"일
-- 때만 false가 되고 그 외 모든 전투(사실상 전부)에서는 이 0.8이 최종값에
-- 곱해진다. 즉 엔진의 [0.8, 1.6] 클램프는 실제로 관측되는 CombatSpeed 값에서
-- [0.64, 1.28] 구간으로 나타난다(하한이 0.8이 아니라 0.8*0.8=0.64).
-- 이 배율을 몰랐을 땐 클램프 감지 임계값이 어긋나 있었다.
local function getAnimSpeedFixMultiplier(playerObj, weapon)
    -- B42: getTraits():contains("X") -> hasTrait(CharacterTrait.X) (IsoGameCharacter.java:6254),
    --      weapon:getCategories() -> getScriptItem():containsWeaponCategory (바닐라 ISRemoveBush.lua:43)
    if weapon and playerObj:hasTrait(CharacterTrait.AXEMAN)
            and weapon:getScriptItem():containsWeaponCategory(WeaponCategory.AXE) then
        return 1.0
    end
    return 0.8
end

local function onWeaponSwing(playerObj, weapon)
    if not playerObj then return end
    if not instanceof(playerObj, "IsoPlayer") then return end
    if not playerObj:isLocalPlayer() then return end

    local md = playerObj:getModData()
    if not md[MORPHINE_EXPIRE_KEY] then return end

    local bodyDamage = playerObj:getBodyDamage()
    if not bodyDamage then return end

    local mod = getArmsInjurySpeedModifier(bodyDamage)
    if mod >= 1.0 then return end          -- 부상 페널티 없음. 손댈 이유가 없다
    if mod < 0.05 then mod = 0.05 end      -- 0/음수 방어 (총알+골절+통증이 겹치면 음수 가능)

    local current = playerObj:getVariableFloat("CombatSpeed", 1.0)
    local animFix = getAnimSpeedFixMultiplier(playerObj, weapon)

    -- IsoGameCharacter.calculateCombatSpeed()는 mod를 곱한 직후 [0.8, 1.6]으로
    -- 클램프하고, 그 결과에 animFix(위 참고)를 곱해 반환한다. animFix는 순수
    -- 무기/특성만으로 결정되는 값이라(랜덤 요소 없음) 여기서 그대로 나눠 없애면
    -- "엔진이 클램프한 원래 값"을 정확히 복원할 수 있다.
    --
    -- 부상이 심해 float0이 0.8 밑으로 떨어지면 엔진이 0.8로 깎아버리고, 그
    -- 사실이 CombatSpeed 변수에는 남지 않는다. 이 상태에서 current를 그대로
    -- mod로 나누면 실제보다 훨씬 큰 값이 나온다(예: 관측 0.64, mod=0.3이면
    -- 2.67 -> 1.6으로 재클램프. 즉 미부상 정상 속도보다 더 빠른 "부스트" 발생.
    -- 실제로 이 버그가 제보됐다). 나눗셈으로 정확히 복원 가능한 경우는 엔진
    -- 클램프가 걸리지 않았을 때뿐이다.
    --
    -- animFix를 나눠 없앤 clampedPart는 [0.8, 1.6] 구간의 엔진 클램프 결과와
    -- 정확히 대응하므로, 그 값이 하한/상한 근처인지로 클램프 여부를 정확히
    -- 판정할 수 있다(이전처럼 animFix를 무시한 채 관측값에 임의 임계값을
    -- 대는 방식보다 정확함).
    local clampedPart = current / animFix
    local fixed
    local clamped = clampedPart <= 0.81 or clampedPart >= 1.59
    if clamped then
        -- 클램프가 걸린 프레임은 엔진이 얼마나 깎았는지(혹은 올렸는지) 정보가
        -- 사라져서 정확한 역산이 불가능하다. mod로 나누는 대신 정상 기준값
        -- (미부상 시 흔한 대역인 1.0)을 animFix와 같은 단위로 맞춰 되돌린다.
        fixed = 1.0 * animFix
    else
        -- 클램프가 안 걸렸다면 clampedPart == base * mod 이므로 나눗셈이
        -- 수학적으로 정확하다. base 자체가 [0.8, 1.6]을 벗어나지 않게만
        -- 다시 클램프해서 animFix를 곱한다.
        local base = clampedPart / mod
        if base > 1.6 then base = 1.6 end
        if base < 0.8 then base = 0.8 end
        fixed = base * animFix
    end
    playerObj:setVariable("CombatSpeed", fixed)

    if not md[MORPHINE_LOGGED_KEY] then
        md[MORPHINE_LOGGED_KEY] = true
        print("[PongDu] syringe: morphine combat speed override, injuryMod=" .. tostring(mod)
            .. ", animFix=" .. tostring(animFix)
            .. ", clamped=" .. tostring(clamped)
            .. ", " .. tostring(current) .. " -> " .. tostring(fixed))
    end
end

-- ── 인벤토리 우클릭 메뉴: "주사하기" ──────────────────────────────────────────

local function tryInjectSyringe(playerObj, item)
    if not item then return end
    ISInventoryPaneContextMenu.transferIfNeeded(playerObj, item)
    ISTimedActionQueue.add(PongDuSyringeAction:new(playerObj, item))
end

local function onFillInventoryObjectContextMenu(player, context, items)
    local playerObj = getSpecificPlayer(player)
    if not playerObj then return end

    local seen = {}

    for i = 1, #items do
        local entry = items[i]
        local item = instanceof(entry, "InventoryItem") and entry or entry.items[1]
        if item then
            local fullType = item:getFullType()
            if SYRINGE_TYPES[fullType] and not seen[fullType] then
                seen[fullType] = true
                context:addOptionOnTop(getText("ContextMenu_InjectSyringe"), playerObj, tryInjectSyringe, item)
            end
        end
    end
end

Events.OnFillInventoryObjectContextMenu.Add(onFillInventoryObjectContextMenu)

Events.OnWeaponSwing.Add(onWeaponSwing)
