-- PongDuEatFoodPatch.lua : 독시사이클린(Antibiotics) 복용 시 식중독성 Sickness(FOOD_SICKNESS)도 함께 치료
--
-- 바닐라 Antibiotics는 ReduceInfectionPower로 상처감염(ZOMBIE_FEVER, 구 FakeInfectionLevel)만 줄인다.
-- Sick 무들은 getApparentInfectionLevel() = max(ZOMBIE_FEVER, ZOMBIE_INFECTION, ...) 계열이라
-- (BodyDamage.java:1664), FOOD_SICKNESS 가 남아 있으면 상처감염을 치료해도 Sick 배지가 안 사라진다.
--
-- [B42] client/TimedActions/ISEatFoodActionPatch.lua 에서 옮겼다.
--   B41은 ISEatFoodAction:perform() 에서 Eat 했지만 B42는 complete() 에서 한다
--   (ISEatFoodAction.lua:173). complete() 는 싱글=로컬, MP=서버에서만 돈다
--   (LuaTimedActionNew.complete: !GameClient.client). 그래서 shared 에 두고 complete 를 감싼다.
--   FoodSicknessLevel 은 Stats FOOD_SICKNESS 로 바뀌었고, 서버에서 바꾸면 syncPlayerStats 로 내려준다.

require "TimedActions/ISEatFoodAction"

local ANTIBIOTICS_FULLTYPE = "Base.Antibiotics"

local complete = ISEatFoodAction.complete

function ISEatFoodAction:complete()
    local isAntibiotics = self.item and self.item:getFullType() == ANTIBIOTICS_FULLTYPE

    local result = complete(self)

    if isAntibiotics and self.character then
        PongDuStats.applyLocal(self.character, { { op = "set", stat = "FOOD_SICKNESS", v = 0 } }, "antibiotics")
        print("[PongDu] Antibiotics consumed: FOOD_SICKNESS reset to 0")
    end
    return result
end
