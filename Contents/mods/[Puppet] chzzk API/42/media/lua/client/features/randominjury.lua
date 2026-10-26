local _a = {}

-- ── 랜덤 부위 랜덤 부상 (random_injury) 클라이언트 ───────────────────────────
--
-- 후원자 개인 디버프. 머리/목을 제외한 부위 중 하나를 뽑아 부상 1종을 입힌다.
-- 부상 종류는 샌드박스에서 종류별로 개별 on/off 가능하며, 발동 1회당 몇 개를
-- 입힐지는 Injury_Count 로 정한다. 실제 조작 코드와 근거는 shared/PongDuBody.lua.
--
-- [B42 MP] 몸 상태는 서버 값이 정답이라 클라가 직접 입힌 상처는 몇 초 안에 서버 값에
-- 덮여 사라진다 (2026-10-26 멀티 4B #3). 그래서
--   SP : 여기서 바로 PongDuBody.randomInjury
--   MP : 서버에 요청 -> server/PongDuBodyServer.lua 가 입히고 syncBodyPart -> 결과를 받아 말풍선
-- 소리를 내지 않으므로 좀비 어그로도 붙지 않는다.

local global = require("global")
require "PongDuBody"

local LOG = "[PongDu][RandomInjury] "

-- 여러 개를 한 번에 입힌 경우 마지막 1건만 말풍선에 띄운다. 부위/부상마다
-- Say 를 반복하면 이전 대사가 즉시 덮여서 어차피 마지막 것만 보인다.
local function sayResult(player, r)
    if not player or not r then return end
    if (r.applied or 0) <= 0 then
        print(LOG .. "injury FAILED: nothing applied (sender=" .. tostring(r.sender) .. ")")
        return
    end
    if r.part == nil or r.key == nil then
        print(LOG .. "result missing part/key, say skipped")
        return
    end
    local partName = BodyPartType.getDisplayName(BodyPartType.FromIndex(r.part))
    player:Say(getText("IGUI_donation_injury_say", partName, getText(r.key)))
end

function _a.a(sender)
    local player = global.player
    if not player then
        print(LOG .. "injury aborted: player is nil")
        return
    end

    if isClient() then
        sendClientCommand(player, PongDuBody.NET_MODULE, "RandomInjury", { ["sender"] = sender or "" })
        print(LOG .. "requested server injury sender=" .. tostring(sender))
        return
    end

    local r = PongDuBody.randomInjury(player, sender)
    r.sender = sender
    sayResult(player, r)
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= PongDuBody.NET_MODULE or command ~= "RandomInjuryDone" then return end
    if type(args) ~= "table" then
        print(LOG .. "server result ignored: bad payload")
        return
    end
    print(LOG .. "server result applied=" .. tostring(args["applied"])
        .. "/" .. tostring(args["count"])
        .. " skipped=" .. tostring(args["skipped"])
        .. " sender=" .. tostring(args["sender"]))
    sayResult(global.player or getPlayer(), {
        applied = args["applied"],
        part    = args["part"],
        key     = args["key"],
        sender  = args["sender"],
    })
end)

return _a
