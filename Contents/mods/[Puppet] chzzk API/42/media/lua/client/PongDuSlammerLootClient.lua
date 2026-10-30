-- PongDu: MP 에서 슬래머 시체의 바닐라 방독면을 옮기면 서버에 알린다.
-- MP 의 아이템 이동은 서버 자바가 처리해 서버 Lua 훅(PongDuSlammerServer.lua 의 ISTransferAction 감싸기)이 안 돈다.
-- 클라에선 이동이 끝난 뒤 ISInventoryTransferAction:playTransferCompleteSound 가 아이템마다 불리므로 거기서 보고한다.
-- 서버는 그 칸 시체 중 표식 방독면이 없어진 시체의 숨김 장식 방독면을 빼서 시체에서도 벗겨지게 한다.
-- SP 는 서버 Lua 훅이 직접 처리하므로 여기선 아무것도 안 한다.
local NET = "PongDuSlammerLoot"
local LOOT_MASK = "Base.Hat_GasMask"
local COSMETIC_MASK = "t3chzzkDonation.PongDuSlammerGasMask"
local LOG = "[PongDu][SlammerLoot] "

local function hasCosmetic(container)
    local items = container:getItems()
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if it and it:getFullType() == COSMETIC_MASK then return true end
    end
    return false
end

if ISInventoryTransferAction and ISInventoryTransferAction.playTransferCompleteSound then
    local orig = ISInventoryTransferAction.playTransferCompleteSound
    ISInventoryTransferAction.playTransferCompleteSound = function(self, item)
        if isClient() and item and item:getFullType() == LOOT_MASK then
            local src = self.srcContainer
            local body = src and src:getParent()
            if body and instanceof(body, "IsoDeadBody") and hasCosmetic(src) then
                local sq = body:getSquare()
                if sq then
                    sendClientCommand(self.character, NET, "MaskLooted",
                        { ["x"] = sq:getX(), ["y"] = sq:getY(), ["z"] = sq:getZ() })
                    print(LOG .. "mask looted from corpse at " .. sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ()
                        .. " -> server")
                else
                    print(LOG .. "mask looted but corpse has no square")
                end
            end
        end
        return orig(self, item)
    end
    print(LOG .. "client transfer hook installed")
else
    print(LOG .. "client transfer hook skipped (ISInventoryTransferAction missing)")
end
