-- PongDuBodyServer: 몸 상태 후원 효과의 MP 서버 처리.
--
-- 클라(features/randominjury.lua, features/instantheal.lua)가 MP 에서 보내는 요청을 받아
-- 보낸 본인에게만 shared/PongDuBody.lua 의 조작을 실행하고, 결과를 본인에게 돌려준다.
-- 상처 동기화(syncBodyPart)는 PongDuBody 안에서 부위마다 한다.
-- 말풍선·효과음은 표시 문자열 조립(번역)이 필요해 클라가 결과를 받아서 처리한다.
--
-- [보안] 대상은 항상 명령을 보낸 player 다. args 로 다른 플레이어를 지정할 수 없다.

require "PongDuBody"

local LOG = "[PongDu][BodyServer] "
local MODULE = PongDuBody.NET_MODULE

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= MODULE then return end
    if not player then
        print(LOG .. "command " .. tostring(command) .. " ignored: player is nil")
        return
    end

    local sender = ""
    if type(args) == "table" and args["sender"] ~= nil then
        sender = tostring(args["sender"])
    end

    if command == "RandomInjury" then
        local r = PongDuBody.randomInjury(player, sender)
        sendServerCommand(player, MODULE, "RandomInjuryDone", {
            ["applied"] = r.applied,
            ["count"]   = r.count,
            ["part"]    = r.part,
            ["key"]     = r.key,
            ["skipped"] = r.skipped and true or false,
            ["sender"]  = sender,
        })
    elseif command == "InstantHeal" then
        local r = PongDuBody.instantHeal(player, sender)
        sendServerCommand(player, MODULE, "InstantHealDone", {
            ["healed"] = r.healed,
            ["sender"] = sender,
        })
    else
        print(LOG .. "unknown command " .. tostring(command)
            .. " from " .. tostring(player:getUsername()))
    end
end)
