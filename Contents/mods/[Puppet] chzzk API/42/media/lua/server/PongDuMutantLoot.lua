-- PongDuMutantLoot.lua : 특좀 머리 장비 고정 + 루팅용 바닐라 아이템 (서버/SP)
--
-- 특좀은 종류마다 외형이 하나로 고정이라, 모자·안경·마스크가 맞거나 밀쳐져서 떨어지면 안 된다.
-- 바닐라는 ChanceToFall > 0 인 옷을 IsoZombie.helmetFallFromVisuals 에서 떨어뜨린다
-- (CombatManager 타격마다 호출, 머리 타격이면 +40). 그래서 아웃핏에는 같은 모델의 숨김 장식
-- (ChanceToFall 없음, zeddmg·hidden)을 입히고, 죽을 때 바닐라 아이템을 인벤토리에 넣어 루팅되게 한다.
-- 표식 달린 바닐라 아이템을 시체에서 꺼내면 같은 시체의 장식도 빼서 벗겨지는 연출을 맞춘다.
--
-- 새 특좀 장비를 이 방식으로 고정하려면 COSMETIC_LOOT 에 한 줄 추가 + 장식 의류(xml·스크립트·GUID)를 만든다.
-- 슬래머 방독면은 상체 확대 셰이더가 걸린 장식이라 PongDuSlammerServer.lua 가 같은 방식으로 따로 처리한다.
--
-- 호출 순서: IsoZombie.onKilled (서버/SP) -> DoZombieInventory(입은 옷 -> 인벤토리) -> OnZombieDead -> DoDeath.
-- MP 에선 서버 시체 인벤토리가 DeadZombiePacket 으로 클라에 간다.

if isClient() then return end

local LOG = "[PongDu][MutantLoot] "
local LOOT_TAG = "PongDuMutantLoot"   -- 바닐라 아이템 modData: 같이 뺄 장식 아이템 fullType

-- 종류 -> { { loot = 루팅용 바닐라 아이템, cosmetic = 아웃핏에 입힌 장식 아이템 }, ... }
local COSMETIC_LOOT = {
    roach = {
        { loot = "Base.Hat_BuildersRespirator", cosmetic = "t3chzzkDonation.PongDuRoachRespirator" },
    },
}

Events.OnZombieDead.Add(function(z)
    if not z or not PongDuMutantId then return end
    local kind = PongDuMutantId.kindOf(z)
    local list = kind and COSMETIC_LOOT[kind]
    if not list then return end
    local inv = z:getInventory()
    if not inv then
        print(LOG .. "loot skipped (no inventory) kind=" .. tostring(kind) .. " zid=" .. tostring(z:getOnlineID()))
        return
    end
    for i = 1, #list do
        local e = list[i]
        local it = inv:AddItem(e.loot)
        if it then it:getModData()[LOOT_TAG] = e.cosmetic end
        print(LOG .. "loot added kind=" .. tostring(kind) .. " item=" .. e.loot
            .. " ok=" .. tostring(it ~= nil) .. " zid=" .. tostring(z:getOnlineID()))
    end
end)

-- 바닐라는 시체 인벤토리에서 착용 아이템이 빠지면 ItemContainer.DoRemoveItem -> IsoDeadBody.checkClothing 으로
-- 착용 슬롯에서도 빼 다시 그린다. 루팅되는 건 바닐라 아이템이고 시체가 입은 건 장식이라 장식을 직접 뺀다.
-- ISTransferAction.transferItem 은 SP 에선 로컬, MP 에선 서버에서만 돈다 (ISInventoryTransferAction:perform).
local function removeCosmetic(container, fullType)
    local items = container:getItems()
    for i = items:size() - 1, 0, -1 do
        local it = items:get(i)
        if it and it:getFullType() == fullType then
            container:DoRemoveItem(it)
            if isServer() then sendRemoveItemFromContainer(container, it) end
            return true
        end
    end
    return false
end

if ISTransferAction and ISTransferAction.transferItem then
    local origTransferItem = ISTransferAction.transferItem
    ISTransferAction.transferItem = function(self, character, item, srcContainer, destContainer, dropSquare)
        local result = origTransferItem(self, character, item, srcContainer, destContainer, dropSquare)
        local body = srcContainer and srcContainer:getParent()
        if item and body and instanceof(body, "IsoDeadBody") then
            local md = item:getModData()
            local cosmetic = md[LOOT_TAG]
            if type(cosmetic) == "string" then
                md[LOOT_TAG] = nil
                local removed = removeCosmetic(srcContainer, cosmetic)
                print(LOG .. "corpse item looted item=" .. tostring(item:getFullType())
                    .. " cosmeticRemoved=" .. tostring(removed)
                    .. " by=" .. tostring(character and character:getUsername()))
            end
        end
        return result
    end
    print(LOG .. "transfer hook installed")
else
    print(LOG .. "transfer hook skipped (ISTransferAction missing)")
end
