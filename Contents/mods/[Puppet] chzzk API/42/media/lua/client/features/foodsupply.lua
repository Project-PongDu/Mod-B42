local _a = {}

-- ── 식량 보급 (food_supply) 클라이언트 ───────────────────────────────────────
--
-- 후원자 개인 버프 계열. 후원이 발동하면 샌드박스 FoodSupply_Item 에 적힌
-- 아이템(기본값 Base.Crisps)을 FoodSupply_Count 개수만큼 인벤토리에 넣는다.
--
-- [B42 MP] 아이템은 서버 권위다. 클라가 AddItem 한 아이템은 인벤에 보이기만 하고
-- 먹기·버리기가 안 된다. 그래서 실제 지급(아이템 해석·개수·표시명)은 전부
-- shared/PongDuGrant.lua 의 PongDuGrant.food 에 있고
--   SP : 여기서 바로 PongDuGrant.food + 보급음
--   MP : 서버에 요청 -> server/PongDuGrantServer.lua 가 서버 샌드박스 값으로 지급
--        -> "Delivered" 를 받아 PongDuGrant 가 보급음
-- 잘못된 FoodSupply_Item 의 감자칩 대체, 번역키 IGUI_donation_food_supply_item 이 있을
-- 때만 이름 덮어쓰기 규칙도 PongDuGrant.food 쪽 주석 참고.
--
-- 이름 변경이 저장되는 근거: InventoryItem.save() 가 `name != originalName` 일 때만
-- 이름을 직렬화하므로 setName() 만 해도 세이브/로드·네트워크 전송 후 유지된다.
--
-- 1개도 못 넣었으면 사운드를 재생하지 않는다 -- "소리는 났는데 아이템은 없다"가
-- 제일 추적하기 어렵다.

local global = require("global")
require "PongDuGrant"

local LOG = "[PongDu][FoodSupply] "

function _a.a(sender)
    local player = global.player
    if not player then
        print(LOG .. "supply aborted: player is nil")
        return
    end

    if isClient() then
        PongDuGrant.request("Food", { ["sender"] = sender or "" })
        return
    end

    local delivered = PongDuGrant.food(player, sender)
    if delivered <= 0 then
        print(LOG .. "supply FAILED: nothing delivered (sender=" .. tostring(sender) .. ")")
        return
    end
    PongDuGrant.playSupplySound()
end

return _a
