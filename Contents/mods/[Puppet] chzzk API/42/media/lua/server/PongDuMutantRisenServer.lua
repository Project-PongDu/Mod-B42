-- PongDuMutantRisenServer.lua : 강령술로 일어난 특좀을 부활 아웃핏으로 바꾼다 (서버/SP)
--
-- [왜]
--   가상화(청크 언로드)·서버 재시작을 거치면 엔진은 좀비를 옷 ID 하나로 다시 만든다. modData·입은 옷·
--   wasFakeDead·인벤토리는 사라진다. 그래서 일어난 특좀이 다 입은 처음 특좀으로 돌아와 루팅·보상이 다시 나왔다.
--   옷 ID 를 "부활 아웃핏"(PongDuMutantId.RISEN_SLOT)으로 바꿔 두면 다시 만들어져도 같은 모습·같은 규칙이다.
--
-- [일어날 때 하는 일]  (server.lua RiseUp 이 reanimate 직후, 첫 좀비 패킷이 나가기 전에 부른다)
--   1. 남은 장식(COSMETICS) 조합으로 부활 슬롯을 고른다.
--   2. 몸 메시 + 남은 장식만 입힌 채로 두고, 나머지 입은 옷·부착 무기·인벤토리는 그 칸 바닥에 떨군다.
--      바닥 아이템은 가상화되지 않아 사라지지 않는다. 일어난 좀비 인벤토리에 남기면 가상화 때 사라진다.
--   3. 남은 장식의 짝인 루팅용 바닐라 아이템(표식 달린 마스크·조끼·죄수복·방독면)은 지운다.
--      장식을 계속 입고 있으므로 이 좀비가 죽을 때 다시 1번 지급된다 (PongDuMutantLoot / PongDuSlammerServer).
--   4. 옷 ID 를 부활 슬롯으로 바꾼다(성별·후원자 번호 유지, 모자 탈락 비트 끔). 클라는 첫 패킷의 옷 ID 로만 입힌다.
--
-- 바닐라 속옷은 아웃핏과 무관하게 엔진이 입힐 때 붙인다(UnderwearDefinition). 다시 만들어진 부활 특좀의
-- 속옷은 PongDuRisenOutfitServer.lua 가 서버에서 벗기고 클라에 알린다.

if isClient() then return end

PongDuMutantRisen = PongDuMutantRisen or {}
local R = PongDuMutantRisen
local M = PongDuMutantId

local LOG = "[PongDu][MutantRisen] "
local LOOT_TAG = "PongDuMutantLoot"      -- PongDuMutantLoot.lua: 값 = 짝 장식 fullType
local SLAMMER_TAG = "PongDuSlammerLoot"  -- PongDuSlammerServer.lua: 값 = "mask"
local SLAMMER_MASK = "t3chzzkDonation.PongDuSlammerGasMask"

local function toSet(list)
    local s = {}
    if list then
        for i = 1, #list do s[list[i]] = true end
    end
    return s
end

local function dropOnSquare(sq, it)
    sq:AddWorldInventoryItem(it, ZombRandFloat(0.1, 0.9), ZombRandFloat(0.1, 0.9), 0.0)
end

--- 일어난 특좀(zed)을 부활 아웃핏으로 바꾼다. recPid = 시체 modData 에 적힌 원래 옷 ID(없으면 nil)
--- 반환: 성공 여부
function R.apply(zed, kind, recPid, sq)
    sq = zed:getCurrentSquare() or sq
    local zid = tostring(zed:getOnlineID())
    if not sq then
        print(LOG .. "skip: no square kind=" .. tostring(kind) .. " zid=" .. zid)
        return false
    end
    local inv = zed:getInventory()
    local worn = zed:getWornItems()
    local att = zed:getAttachedItems()
    local cos = M.COSMETICS[kind] or {}
    local cosSet = toSet(cos)
    local bodySet = toSet(M.BODY_ITEMS[kind])

    -- 1. 남은 장식
    local present, keptCos = {}, {}
    if worn then
        for i = 0, worn:size() - 1 do
            local it = worn:getItemByIndex(i)
            if it then
                local ft = it:getFullType()
                for k = 1, #cos do
                    if cos[k] == ft then
                        present[k] = true
                        keptCos[ft] = true
                    end
                end
            end
        end
    end
    local slot = M.risenSlotFor(kind, present)

    -- 원래 옷 ID: 시체 기록 > 좀비 현재 값(특좀일 때만) > 없으면 후원자 없음 + 좀비 성별
    local base = recPid
    if not base or not M.kindOfPid(base) then
        local cur = zed:getPersistentOutfitID()
        base = M.kindOfPid(cur) and cur or nil
    end
    local female = zed:isFemale()
    local variant = M.NO_DONOR
    if base then
        female = base < 0
        variant = M.variantOf(base) or M.NO_DONOR
    end
    local newPid = slot and M.pidForSlot(slot, female, variant)
    if not newPid then
        print(LOG .. "FAILED no risen outfit index kind=" .. tostring(kind) .. " slot=" .. tostring(slot)
            .. " zid=" .. zid .. " (clothing.xml PongDuMutant_R* missing?)")
        return false
    end

    -- 2·3. 아이템 정리
    local list = {}
    if inv then
        local items = inv:getItems()
        for i = 0, items:size() - 1 do list[#list + 1] = items:get(i) end
    end
    local dropped, deleted, kept = 0, 0, 0
    local droppedNames = {}
    for _, it in ipairs(list) do
        local ft = it:getFullType()
        local isWorn = worn and worn:contains(it)
        if isWorn and (bodySet[ft] or cosSet[ft]) then
            kept = kept + 1
        else
            local md = it:getModData()
            local linked = (type(md[LOOT_TAG]) == "string" and keptCos[md[LOOT_TAG]])
                or (md[SLAMMER_TAG] ~= nil and keptCos[SLAMMER_MASK])
            if isWorn then worn:remove(it) end
            if att and att:contains(it) then att:remove(it) end
            inv:DoRemoveItem(it)
            if linked then
                deleted = deleted + 1
            else
                dropOnSquare(sq, it)
                dropped = dropped + 1
                droppedNames[#droppedNames + 1] = ft
            end
        end
    end
    -- 인벤토리에 없는 입은 옷·부착 아이템(보통 없음)도 떨군다
    if worn then
        for i = worn:size() - 1, 0, -1 do
            local it = worn:getItemByIndex(i)
            if it and not (bodySet[it:getFullType()] or cosSet[it:getFullType()]) then
                worn:remove(it)
                dropOnSquare(sq, it)
                dropped = dropped + 1
                droppedNames[#droppedNames + 1] = it:getFullType()
            end
        end
    end
    if att then
        for i = att:size() - 1, 0, -1 do
            local it = att:getItemByIndex(i)
            if it then
                att:remove(it)
                dropOnSquare(sq, it)
                dropped = dropped + 1
                droppedNames[#droppedNames + 1] = it:getFullType()
            end
        end
    end

    -- 4. 옷 ID
    local before = zed:getPersistentOutfitID()
    zed:setPersistentOutfitID(newPid, true)
    pcall(function() zed:onWornItemsChanged() end)
    print(LOG .. "risen kind=" .. tostring(kind) .. " slot=" .. slot .. " zid=" .. zid
        .. " pid " .. tostring(before) .. " -> " .. tostring(zed:getPersistentOutfitID())
        .. " recorded=" .. tostring(recPid) .. " kept=" .. kept .. " dropped=" .. dropped
        .. " lootDeleted=" .. deleted
        .. (#droppedNames > 0 and (" items=" .. table.concat(droppedNames, ",")) or ""))
    return true
end
