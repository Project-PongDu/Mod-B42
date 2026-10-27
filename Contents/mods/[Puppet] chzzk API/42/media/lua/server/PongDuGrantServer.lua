-- PongDuGrantServer: 후원 아이템 지급의 MP 서버 처리.
--
-- 클라(rewards/rewardManager.lua giveSupply, features/foodsupply.lua)가 MP 에서 보내는 요청을 받아
-- 보낸 본인 인벤에 shared/PongDuGrant.lua 로 아이템을 넣고, 결과를 본인에게 돌려준다.
--
-- [보안] 대상은 항상 명령을 보낸 player 다. args 로 다른 플레이어를 지정할 수 없다.
--   보급 itemId 는 PongDuGrant.isSupplyId 화이트리스트로 거른다. 후원 자체가 클라에서 들어오는
--   구조라 "후원이 진짜인가"는 서버가 판정할 수 없다(기존 기능들과 같은 한계).
--
-- media/lua/server 는 MP 클라에서도 로드되지만 OnClientCommand 는 서버(와 SP)에서만 발화한다.

require "PongDuGrant"

local LOG = "[PongDu][GrantServer] "
local MODULE = PongDuGrant.NET_MODULE

local function argString(args, key)
    if type(args) == "table" and args[key] ~= nil then return tostring(args[key]) end
    return ""
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= MODULE then return end
    if not player then
        print(LOG .. "command " .. tostring(command) .. " ignored: player is nil")
        return
    end

    local sender = argString(args, "sender")

    if command == "Supply" then
        local itemId = argString(args, "item")
        local item = PongDuGrant.supply(player, itemId, sender)
        if item then
            sendServerCommand(player, MODULE, "Delivered", {
                ["kind"] = "supply", ["item"] = itemId, ["count"] = 1, ["sender"] = sender,
            })
        else
            sendServerCommand(player, MODULE, "Failed", {
                ["kind"] = "supply", ["item"] = itemId, ["reason"] = "give failed", ["sender"] = sender,
            })
        end
    elseif command == "Food" then
        local delivered, itemType = PongDuGrant.food(player, sender)
        if delivered > 0 then
            sendServerCommand(player, MODULE, "Delivered", {
                ["kind"] = "food", ["item"] = itemType, ["count"] = delivered, ["sender"] = sender,
            })
        else
            sendServerCommand(player, MODULE, "Failed", {
                ["kind"] = "food", ["item"] = itemType, ["reason"] = "nothing delivered", ["sender"] = sender,
            })
        end
    else
        print(LOG .. "unknown command " .. tostring(command)
            .. " from " .. tostring(player:getUsername()))
    end
end)
