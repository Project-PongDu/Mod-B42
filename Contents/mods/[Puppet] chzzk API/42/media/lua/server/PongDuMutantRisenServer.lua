-- PongDuMutantRisenServer.lua : 강령술로 일어난 특좀을 부활 아웃핏으로 바꾼다 (서버/SP)
--
-- [왜]
--   가상화(청크 언로드)·서버 재시작을 거치면 엔진은 좀비를 옷 ID 하나로 다시 만든다. modData·입은 옷·
--   wasFakeDead·인벤토리는 사라진다. 그래서 일어난 특좀이 다 입은 처음 특좀으로 돌아와 루팅·보상이 다시 나왔다.
--   옷 ID 를 "부활 아웃핏"(PongDuMutantId.RISEN_SLOT)으로 바꿔 두면 다시 만들어져도 같은 모습·같은 규칙이다.
--
-- [일어날 때 하는 일]  (server.lua RiseUp 이 reanimate 직후, 첫 좀비 패킷이 나가기 전에 부른다)
--   1. 남은 장식(COSMETICS) 조합으로 부활 슬롯을 고른다.
--   2. 시체에 남아 있던 것은 하나도 버리지 않는다. 입고 있던 옷(바닐라 옷 포함)은 그대로 입고,
--      들고 있던 소지품도 그대로 든다. 다시 죽이면 그대로 시체로 넘어간다. 플레이어가 가져가거나 버린 것만 빠진다.
--      화면 외형은 옷 ID(부활 아웃핏 = 몸 + 남은 장식)로 입혀지므로, 바닐라 옷은 PongDuRisenOutfitServer 가
--      실제 착용 목록(색·텍스처 포함)을 클라에 보내 클라가 덧입힌다(client/PongDuRisenOutfit.lua).
--      부착 무기(몸에 박힌 포크·허리 진압봉 등)도 그대로 붙여 둔다. 클라는 위치·종류 목록을 받아 같은 아이템을 붙인다.
--      가상화(청크 언로드·서버 종료)되면 엔진이 인벤토리를 저장하지 않아 사라진다 -- 그 전에 잡거나 도망친다는 전제로 감수.
--   3. 남은 장식의 짝인 루팅용 바닐라 아이템(표식 달린 호흡기·조끼·죄수복·방독면)도 그대로 둔다.
--      다시 죽을 때 루팅 지급은 "표식 아이템이 이미 있으면 건너뜀"이라 중복되지 않는다
--      (PongDuMutantLoot / PongDuSlammerServer). 가상화로 인벤토리가 사라졌으면 장식 기준으로 1번 다시 지급된다.
--   4. 옷 ID 를 부활 슬롯으로 바꾼다(성별·후원자 번호 유지, 모자 탈락 비트 끔). 클라는 첫 패킷의 옷 ID 로만 입힌다.
--
-- 바닐라 속옷은 아웃핏과 무관하게 엔진이 입힐 때 붙인다(UnderwearDefinition). 다시 만들어진 부활 특좀의
-- 속옷은 PongDuRisenOutfitServer.lua 가 서버에서 벗기고 클라에 알린다.

if isClient() then return end

PongDuMutantRisen = PongDuMutantRisen or {}
local R = PongDuMutantRisen
local M = PongDuMutantId

local LOG = "[PongDu][MutantRisen] "

local function toSet(list)
    local s = {}
    if list then
        for i = 1, #list do s[list[i]] = true end
    end
    return s
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
    local present = {}
    if worn then
        for i = 0, worn:size() - 1 do
            local it = worn:getItemByIndex(i)
            if it then
                local ft = it:getFullType()
                for k = 1, #cos do
                    if cos[k] == ft then
                        present[k] = true
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

    -- 2·3. 아이템 정리: 버리지도 지우지도 않는다. 입은 옷·부착물·소지품을 전부 그대로 둔다(개수만 센다).
    local kept, wornKept, carried = 0, 0, 0
    local wornNames, attNames = {}, {}
    if worn then
        for i = 0, worn:size() - 1 do
            local it = worn:getItemByIndex(i)
            local ft = it and it:getFullType()
            if it and (bodySet[ft] or cosSet[ft]) then
                kept = kept + 1
            elseif it then
                wornKept = wornKept + 1
                wornNames[#wornNames + 1] = ft
            end
        end
    end
    if att then
        for i = 0, att:size() - 1 do
            local a = att:get(i)
            local it = a and a:getItem()
            if it then attNames[#attNames + 1] = tostring(a:getLocation()) .. "=" .. it:getFullType() end
        end
    end
    if inv then carried = inv:getItems():size() - kept - wornKept - #attNames end

    -- 4. 옷 ID
    local before = zed:getPersistentOutfitID()
    zed:setPersistentOutfitID(newPid, true)
    pcall(function() zed:onWornItemsChanged() end)
    print(LOG .. "risen kind=" .. tostring(kind) .. " slot=" .. slot .. " zid=" .. zid
        .. " pid " .. tostring(before) .. " -> " .. tostring(zed:getPersistentOutfitID())
        .. " recorded=" .. tostring(recPid) .. " kept=" .. kept .. " wornKept=" .. wornKept .. " carried=" .. carried
        .. " attached=" .. #attNames
        .. (#wornNames > 0 and (" worn=" .. table.concat(wornNames, ",")) or "")
        .. (#attNames > 0 and (" att=" .. table.concat(attNames, ",")) or ""))
    return true
end
