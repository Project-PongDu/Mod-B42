local _a = {}

-- ── 즉시 치유 (instant_heal) 클라이언트 ──────────────────────────────────────
--
-- 후원자 개인 버프. 전신 부위의 물리적 부상(긁힘/베임/깊은 상처/물린 상처/
-- 화상/유리 파편/총알/골절/출혈/붕대·봉합 상태)과 부위 체력을 전부 원상복구한다.
-- 좀비 감염은 기본적으로 건드리지 않으며, 샌드박스 Heal_CureBiteInfection 을
-- 켰을 때만 백신과 동일하게 완전 치료한다. 실제 조작 코드와 근거는 shared/PongDuBody.lua.
--
-- [B42 MP] 몸 상태는 서버 값이 정답이다. 클라에서만 고치면 서버에 남아 있는 상처가
-- 다시 내려와 덮는다. 그래서
--   SP : 여기서 바로 PongDuBody.instantHeal
--   MP : 서버에 요청 -> server/PongDuBodyServer.lua 가 치료하고 syncBodyPart -> 결과를 받아 연출
--
-- 사운드는 클라 로컬(getSoundManager():PlaySound)이라 좀비 어그로가 붙지 않는다.

local global = require("global")
require "PongDuBody"

local LOG = "[PongDu][InstantHeal] "

local function playFeedback(player)
    if not player then return end
    local audio = getSoundManager():PlaySound("pongdu_syringe_inject", false, 1.0)
    if audio then audio:setVolume(0.6) end
    player:Say(getText("IGUI_donation_instant_heal_say"))
end

function _a.a(sender)
    local player = global.player
    if not player then
        print(LOG .. "heal aborted: player is nil")
        return
    end

    if isClient() then
        sendClientCommand(player, PongDuBody.NET_MODULE, "InstantHeal", { ["sender"] = sender or "" })
        print(LOG .. "requested server heal sender=" .. tostring(sender))
        return
    end

    PongDuBody.instantHeal(player, sender)
    playFeedback(player)
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= PongDuBody.NET_MODULE or command ~= "InstantHealDone" then return end
    if type(args) ~= "table" then
        print(LOG .. "server result ignored: bad payload")
        return
    end
    print(LOG .. "server result healed=" .. tostring(args["healed"])
        .. " sender=" .. tostring(args["sender"]))
    playFeedback(global.player or getPlayer())
end)

return _a
