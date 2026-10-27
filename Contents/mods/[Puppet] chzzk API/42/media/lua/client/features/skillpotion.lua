-- 강화혈청(Enhancement Serum).
--
-- 아이템은 14스킬 x 3등급 = 42종이 t3_rewards_items.txt 에 전부 정적으로
-- 정의돼 있다. 표시명(ItemName_*)과 툴팁(Tooltip_*)도 번역파일에 박혀 있어서
-- 세이브/네트워크 직렬화를 신경 쓸 필요가 없다.
--
-- 여기가 하는 일은 두 가지뿐이다:
--   1) roll()  - 샌드박스 옵션을 보고 어떤 혈청을 지급할지 추첨
--   2) (OnEat_serum 은 shared/PongDuSerum.lua 로 옮겼다)

local serum = {}

-- 등급·스킬 표와 섭취 핸들러(OnEat_serum)는 shared/PongDuSerum.lua 에 있다.
-- B42 MP 는 먹기 OnEat 이 서버에서도 돌기 때문에 서버가 함수를 가져야 한다.
require "PongDuSerum"
serum.GRADES = PongDuSerum.GRADES
serum.SKILLS = PongDuSerum.SKILLS

-- 샌드박스 드롭박스 값 -> 획득 가능한 등급 수.
--   1: 일반+희귀+특급 -> 3 / 2: 일반+희귀 -> 2 / 3: 일반만 -> 1 / 4: 획득 불가 -> 0
-- SandboxVars 는 게임 로드 후 항상 채워지므로 fallback 을 두지 않는다.
local function allowedGradeCount(perkId)
    local v = SandboxVars.PongDu["Serum_" .. perkId]
    if v == 4 then return 0 end
    return 4 - v
end

-- 스킬 1/N 균등 추첨 -> 해당 스킬에 허용된 등급 안에서 가중 추첨.
-- 특급이 막혀 있으면 가중치 합이 13이 되어 자연스럽게 10:3 이 된다.
-- 반환: 아이템 타입 문자열 (모든 스킬이 획득 불가면 nil)
function serum.roll()
    local candidates = {}
    for _, perkId in ipairs(serum.SKILLS) do
        if allowedGradeCount(perkId) > 0 then
            table.insert(candidates, perkId)
        end
    end

    if #candidates == 0 then
        print("[PongDu] Serum roll aborted: every skill is disabled by sandbox")
        return nil
    end

    local perkId = candidates[ZombRand(#candidates) + 1]
    local maxGrade = allowedGradeCount(perkId)

    local total = 0
    for i = 1, maxGrade do
        total = total + serum.GRADES[i].weight
    end

    local roll = ZombRand(total)
    local acc = 0
    for i = 1, maxGrade do
        acc = acc + serum.GRADES[i].weight
        if roll < acc then
            print("[PongDu] Serum rolled: perk=" .. perkId .. ", grade=" .. serum.GRADES[i].id
                .. " (candidates=" .. #candidates .. ", maxGrade=" .. maxGrade
                .. ", roll=" .. roll .. "/" .. total .. ")")
            return "serum_" .. serum.GRADES[i].id .. "_" .. perkId
        end
    end

    -- 안전망. 정수 연산이라 위 루프에서 반드시 반환되지만 방어적으로 둔다.
    return "serum_" .. serum.GRADES[maxGrade].id .. "_" .. perkId
end

return serum
