-- PongDu: MP 에서 특좀 시체의 루팅용 바닐라 아이템을 옮기면 서버에 알린다.
-- MP 의 아이템 이동은 서버 자바(Transaction.updateItem)가 처리해 서버 Lua 의 ISTransferAction 감싸기가 안 돈다.
-- 클라에선 이동이 끝난 뒤 ISInventoryTransferAction:playTransferCompleteSound 가 아이템마다 불리므로 거기서 보고한다.
--   슬래머 방독면          -> PongDuSlammerLoot / MaskLooted (PongDuSlammerServer.lua)
--   그 밖의 장식 짝 아이템 -> PongDuMutantLoot / LootTaken   (PongDuMutantLoot.lua)
-- 서버는 그 칸 시체 중 표식 바닐라 아이템이 없어진 시체의 숨김 장식을 빼서 시체에서도 벗겨지게 한다.
-- SP 는 서버 Lua 훅이 직접 처리하므로 여기선 아무것도 안 한다.
local LOG = "[PongDu][MutantLootClient] "
local SLAMMER_MASK = "Base.Hat_GasMask"
local SLAMMER_COSMETIC = "t3chzzkDonation.PongDuSlammerGasMask"
local MOD_PREFIX = "t3chzzkDonation."

local function scanCorpse(container)
    local hasSlammerMask, hasPongDu = false, false
    local items = container:getItems()
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        local ft = it and it:getFullType()
        if ft then
            if ft == SLAMMER_COSMETIC then hasSlammerMask = true end
            if string.find(ft, MOD_PREFIX, 1, true) == 1 then hasPongDu = true end
        end
    end
    return hasSlammerMask, hasPongDu
end

if ISInventoryTransferAction and ISInventoryTransferAction.playTransferCompleteSound then
    local orig = ISInventoryTransferAction.playTransferCompleteSound
    ISInventoryTransferAction.playTransferCompleteSound = function(self, item)
        if isClient() and item then
            local src = self.srcContainer
            local body = src and src:getParent()
            local ft = item:getFullType()
            if body and instanceof(body, "IsoDeadBody") and ft and string.find(ft, MOD_PREFIX, 1, true) ~= 1 then
                local hasSlammerMask, hasPongDu = scanCorpse(src)
                local sq = body:getSquare()
                if sq and hasPongDu then
                    local args = { ["x"] = sq:getX(), ["y"] = sq:getY(), ["z"] = sq:getZ(), ["type"] = ft }
                    if ft == SLAMMER_MASK and hasSlammerMask then
                        sendClientCommand(self.character, "PongDuSlammerLoot", "MaskLooted", args)
                    else
                        sendClientCommand(self.character, "PongDuMutantLoot", "LootTaken", args)
                    end
                    print(LOG .. "corpse item moved item=" .. ft .. " at " .. sq:getX() .. "," .. sq:getY() .. ","
                        .. sq:getZ() .. " -> server")
                end
            end
        end
        return orig(self, item)
    end
    print(LOG .. "client transfer hook installed")
else
    print(LOG .. "client transfer hook skipped (ISInventoryTransferAction missing)")
end
