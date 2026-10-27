-- PongDuVaccine.lua : Zomboxivir 앰퓰 (좀비 감염 완전 치료)
--
-- zRe Vaccin("They Knew") 모드의 TheyKnew.Zomboxivir 아이템 + OnEat_Zomboxivir
-- (원본: TheyKnew_BreakAmpule.lua)를 퐁듀 전용 아이템으로 이식. vaccine 후원
-- (rewardManager.lua)이 그 모드가 로드돼 있어야만 지급 가능했던 의존성을 제거하는
-- 게 목적이라, 아이템/사운드/이 함수를 통째로 옮겨왔다.
--
-- 원본 아이템 스크립트의 CustomContextMenu = Break_Ampule은 실제로 연결된 Lua
-- 함수가 원본 모드 어디에도 없는 죽은 참조였다(전체 파일 검색으로 확인). 그래서
-- 이식하지 않았고, 순수 OnEat(우클릭 Eat) 소모형 아이템으로만 동작한다.
--
-- [B42] client/features/vaccine.lua 에서 shared 로 옮겼다.
--   B42 MP 에서 먹기는 ISEatFoodAction:complete() -> 서버의 IsoGameCharacter.Eat 에서 처리되고
--   (OnEat 호출: IsoGameCharacter.java:6487), 클라는 EatFood 패킷을 받아 EatOnClient(:6400)로
--   OnEat 을 한 번 더 부른다. client 폴더에 두면 서버에선 함수가 없어 감염 치료가 서버에
--   반영되지 않는다. 양쪽에서 불려도 결과가 같도록(멱등) 짠다.
--   감염 수치는 B42에서 Stats ZOMBIE_INFECTION 으로 옮겨졌다 (shared/PongDuStats.lua).

function OnEat_Zomboxivir(food, player, percent)
    local bodyDamage = player:getBodyDamage()
    if not bodyDamage then
        print("[PongDu] vaccine: missing bodyDamage, aborting")
        return
    end

    bodyDamage:setInfected(false)
    bodyDamage:setInfectionMortalityDuration(-1)
    bodyDamage:setInfectionTime(-1)
    PongDuStats.applyLocal(player, { { op = "set", stat = "ZOMBIE_INFECTION", v = 0 } }, "vaccine")

    -- 부위 감염 플래그는 서버에서 바꾼 뒤 syncBodyPart 로 내려보내야 클라에 반영된다
    -- (PongDuBody.syncPart: isServer 일 때만 동작). BodyDamage 전체 플래그(setInfected 등)는
    -- BodyPartSyncPacket 에 없지만(BodyPart.sync 는 1~41번 필드뿐), 클라도 EatOnClient 로 이 함수를
    -- 한 번 더 돌려 같은 값이 된다. 부위 플래그가 서버에 남아 있으면 BodyDamage.Update 가
    -- 전체 플래그를 다시 켜므로(isInfected 가 false 일 때 부위를 훑어 setInfected(true)) 부위 sync 가 핵심이다.
    local bodyParts = bodyDamage:getBodyParts()
    local synced = 0
    for i = bodyParts:size() - 1, 0, -1 do
        local bodyPart = bodyParts:get(i)
        bodyPart:SetInfected(false)
        if isServer() then
            PongDuBody.syncPart(bodyPart)
            synced = synced + 1
        end
    end

    print("[PongDu] vaccine: Zomboxivir applied, infection cleared (server=" .. tostring(isServer())
        .. ", client=" .. tostring(isClient()) .. ", syncedParts=" .. synced .. ")")
end
