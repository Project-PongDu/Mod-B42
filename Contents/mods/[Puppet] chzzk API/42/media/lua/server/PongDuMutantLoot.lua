-- PongDuMutantLoot.lua : 특좀 머리 장비 고정 + 루팅용 바닐라 아이템 (서버/SP)
--
-- 특좀은 종류마다 외형이 하나로 고정이라, 모자·안경·마스크가 맞거나 밀쳐져서 떨어지면 안 된다.
-- 바닐라는 ChanceToFall > 0 인 옷을 IsoZombie.helmetFallFromVisuals 에서 떨어뜨린다
-- (CombatManager 타격마다 호출, 머리 타격이면 +40). 그래서 아웃핏에는 같은 모델의 숨김 장식
-- (ChanceToFall 없음, zeddmg·hidden)을 입히고, 죽을 때 바닐라 아이템을 인벤토리에 넣어 루팅되게 한다.
-- 표식 달린 바닐라 아이템을 시체에서 꺼내면 같은 시체의 장식도 빼서 벗겨지는 연출을 맞춘다.
--
-- 새 특좀 장비를 이 방식으로 고정하려면 COSMETIC_LOOT 에 한 줄 추가 + 장식 의류(xml·스크립트·GUID)를 만든다.
-- ifWorn = true 인 항목은 그 장식을 실제로 입었을 때만 지급한다 (아웃핏 subItems 로 여럿 중 하나를 고르는 장비용).
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
    -- 트레이서: 방진 마스크 + 고글 3종 중 하나 (PongDu_tracer_items.txt)
    tracer = {
        { loot = "Base.Hat_BuildersRespirator", cosmetic = "t3chzzkDonation.PongDuTracerRespirator" },
        { loot = "Base.Glasses_SafetyGoggles",  cosmetic = "t3chzzkDonation.PongDuTracerSafetyGoggles", ifWorn = true },
        { loot = "Base.Glasses_SkiGoggles",     cosmetic = "t3chzzkDonation.PongDuTracerSkiGoggles",    ifWorn = true },
        { loot = "Base.Glasses_Macho",          cosmetic = "t3chzzkDonation.PongDuTracerMacho",         ifWorn = true },
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
        if e.ifWorn and not inv:containsType(e.cosmetic) then
            -- 이 좀비는 다른 하위 항목을 골랐다
        else
            local it = inv:AddItem(e.loot)
            if it then it:getModData()[LOOT_TAG] = e.cosmetic end
            print(LOG .. "loot added kind=" .. tostring(kind) .. " item=" .. e.loot
                .. " ok=" .. tostring(it ~= nil) .. " zid=" .. tostring(z:getOnlineID()))
        end
    end
end)

-- 바닐라는 시체 인벤토리에서 착용 아이템이 빠지면 ItemContainer.DoRemoveItem -> IsoDeadBody.checkClothing 으로
-- 착용 슬롯에서도 빼 다시 그린다. 루팅되는 건 바닐라 아이템이고 시체가 입은 건 장식이라 장식을 직접 뺀다.
-- ISTransferAction.transferItem 은 SP 에서만 돈다. MP 의 아이템 이동은 서버 자바 트랜잭션(Transaction.updateItem)이
-- 처리해 이 훅을 거치지 않으므로, 클라(PongDuMutantLootClient.lua)가 보고하면 아래 OnClientCommand 가 뺀다.
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

-- ── MP: 클라가 알려 준 시체 아이템 루팅 ──────────────────────────────────────
-- 클라는 퐁듀 장식이 남은 시체에서 아이템을 옮기면 칸 좌표와 아이템 fullType 을 보낸다.
-- 그 칸 시체마다 해당 바닐라 아이템과 짝인 장식이 있는데 표식 달린 바닐라 아이템은 더 없으면 장식을 뺀다.
local LOOT_NET = "PongDuMutantLoot"

local function hasTagged(container, lootType, cosmetic)
    local items = container:getItems()
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if it and it:getFullType() == lootType and it:getModData()[LOOT_TAG] == cosmetic then return true end
    end
    return false
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= LOOT_NET or command ~= "LootTaken" then return end
    local who = player and player:getUsername() or "?"
    local x = tonumber(args and args["x"])
    local y = tonumber(args and args["y"])
    local zz = tonumber(args and args["z"])
    local lootType = args and args["type"]
    if not x or not y or not zz or type(lootType) ~= "string" then
        print(LOG .. "LootTaken ignored: bad args from=" .. who)
        return
    end
    if player and (math.abs(player:getX() - x) > 4 or math.abs(player:getY() - y) > 4) then
        print(LOG .. "LootTaken ignored: reporter too far from=" .. who)
        return
    end
    local cell = getCell()
    local sq = cell and cell:getGridSquare(x, y, zz)
    if not sq then
        print(LOG .. "LootTaken ignored: no square " .. x .. "," .. y .. "," .. zz .. " from=" .. who)
        return
    end
    local bodies = sq:getDeadBodys()
    local n, removed = 0, 0
    for i = 0, bodies:size() - 1 do
        local b = bodies:get(i)
        local c = b and b:getContainer()
        if c then
            n = n + 1
            for _, list in pairs(COSMETIC_LOOT) do
                for k = 1, #list do
                    local e = list[k]
                    if e.loot == lootType and c:containsType(e.cosmetic) and not hasTagged(c, e.loot, e.cosmetic) then
                        if removeCosmetic(c, e.cosmetic) then removed = removed + 1 end
                    end
                end
            end
        end
    end
    print(LOG .. "LootTaken item=" .. lootType .. " at " .. x .. "," .. y .. "," .. zz .. " bodies=" .. n
        .. " cosmeticRemoved=" .. removed .. " by=" .. who)
end)
