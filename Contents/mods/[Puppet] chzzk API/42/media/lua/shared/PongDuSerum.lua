-- PongDuSerum.lua : 강화혈청(Enhancement Serum) 등급·스킬 표 + 섭취 핸들러 OnEat_serum (B42).
--
-- [왜 shared 인가]
--   B42 MP 에서 먹기는 ISEatFoodAction:complete() -> 서버 IsoGameCharacter.Eat 에서 OnEat 을 부르고,
--   클라는 EatFood 패킷을 받아 EatOnClient 로 OnEat 을 한 번 더 부른다(shared/PongDuVaccine.lua 와 같은 경로).
--   OnEat_serum 이 client/features/skillpotion.lua 에만 있으면 서버에는 함수가 없어 아무 일도 안 하고,
--   클라 LevelPerk 만 남는다. 클라에서 바꾼 레벨은 서버에 없는 값이다.
--   그래서 MP 는 서버가 addXpNoMultiplier 로 "목표 레벨까지 모자란 XP" 를 넣는다.
--   * LuaManager.addXpNoMultiplier -> GameServer.addXp: AddXP 가 레벨 경계를 넘을 때마다 LevelPerk 를
--     부르고, 끝에 NetworkCharacterAI.updateXpChecker() 로 안티치트 XP 기준값을 갱신한다.
--     그래서 한 번에 수천 XP 를 넣어도 AntiCheatXPUpdate(1000 x 배율 초과 검사)에 걸리지 않는다.
--   * 바닐라도 서버 액션 complete() 에서 addXp 를 쓴다(ISRepairEngine 등).
--   SP 는 기존 동작(LevelPerk 반복) 그대로. MP 클라는 아무것도 하지 않는다(서버 값이 내려온다).

PongDuSerum = PongDuSerum or {}

-- 등급.
--   levels : 상승 레벨 수
--   weight : 등급 추첨 가중치. 일반:희귀:특급 = 10:3:1
-- 순서가 곧 등급 서열이다. allowedGradeCount() 가 앞에서부터 n개를 잘라 쓴다.
PongDuSerum.GRADES = {
    { id = "common", levels = 1, weight = 10 },
    { id = "rare",   levels = 2, weight = 3  },
    { id = "epic",   levels = 3, weight = 1  },
}

-- 대상 스킬 14종. id 는 Perks.FromString() 키이자 아이템 타입/번역/샌드박스
-- 옵션의 접미사다. 재장전(Reloading)은 의도적으로 제외했다.
PongDuSerum.SKILLS = {
    "Fitness", "Strength",
    "Sprinting", "Lightfoot", "Nimble", "Sneak",
    "Axe", "Blunt", "SmallBlunt", "LongBlade", "SmallBlade", "Spear",
    "Maintenance", "Aiming",
}

-- 아이템 타입 -> 효과. OnEat 이 문자열 파싱 없이 바로 찾아 쓴다.
local EFFECT = {}
for _, grade in ipairs(PongDuSerum.GRADES) do
    for _, perkId in ipairs(PongDuSerum.SKILLS) do
        EFFECT["serum_" .. grade.id .. "_" .. perkId] = {
            perkId = perkId,
            levels = grade.levels,
        }
    end
end

local MAX_LEVEL = 10

-- ── OnEat (42종 공용) ────────────────────────────────────────────────────
-- food:getType() 은 모듈 prefix 없는 타입명("serum_epic_Aiming")을 돌려준다.
function OnEat_serum(food, player, percent)
    local itemType = food:getType()
    local effect = EFFECT[itemType]

    if not effect then
        print("[PongDu] Serum consume FAILED: unknown item type=" .. tostring(itemType))
        return
    end

    local perk = Perks.FromString(effect.perkId)

    if isClient() then
        -- MP 클라: 서버가 XP 를 넣고 엔진이 내려준다. 여기서 LevelPerk 하면 서버와 어긋난다.
        print("[PongDu] Serum consumed (client, server applies): type=" .. itemType)
        return
    end

    if isServer() then
        local cur    = player:getPerkLevel(perk)
        local target = math.min(MAX_LEVEL, cur + effect.levels)
        local curXp  = player:getXp():getXP(perk)
        local need   = perk:getTotalXpForLevel(target) - curXp
        if need > 0 then
            addXpNoMultiplier(player, perk, need)
        end
        print("[PongDu] Serum consumed (server): type=" .. itemType
            .. ", perk=" .. effect.perkId .. ", level " .. cur .. " -> " .. tostring(player:getPerkLevel(perk))
            .. " (target=" .. target .. ", xpAdded=" .. tostring(need) .. ")"
            .. ", user=" .. tostring(player:getUsername()))
        return
    end

    -- SP: LevelPerk() 는 호출 1회당 정확히 +1레벨이며 이미 만렙이면 무시된다.
    for i = 1, effect.levels do
        player:LevelPerk(perk)
    end
    print("[PongDu] Serum consumed: type=" .. itemType
        .. ", perk=" .. effect.perkId .. ", levels=+" .. effect.levels)
end
