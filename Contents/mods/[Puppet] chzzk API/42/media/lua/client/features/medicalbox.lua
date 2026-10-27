local _a = {}

-- ── 의약품 랜덤박스 (medical_box) 클라이언트 ─────────────────────────────────
--
-- 서버 후원(PongDu_Server 탭) 계열. 서버장에게 후원이 들어오면 접속자 전원이
-- 의약품 보급상자를 1개씩 받고, 각자 개봉하면 활성화된 품목(주사기 4종 + 백신)이
-- 전부 나온다 (개봉 지급 로직은 shared/t3MedicalBox.lua, 레시피 OnCreate 에서 서버 실행).
--
-- [B42 MP] 아이템은 서버 권위라 상자도 서버가 넣는다. 이 파일은 요청만 한다.
--   MP : 서버에 Request -> server/PongDuMedBoxServer.lua 가 서버장 판정 후 접속자 전원 인벤에
--        PongDuGrant.supply 로 직접 지급 -> 각자 "Delivered" 를 받아 PongDuGrant 가 보급음
--   SP : "전원"이 자기 자신이라 왕복 없이 바로 지급 (SP 에선 sendServerCommand 가 동작하지 않는다,
--        LuaManager.sendServerCommand: GameServer.server 일 때만)

require "PongDuGrant"

local BOX_ITEM = "medical_box"

function _a.a(sender)
    if isClient() then
        sendClientCommand("PongDuMedBox", "Request", { ["sender"] = sender or "" })
        print("[PongDuMedBox] grant requested sender=" .. tostring(sender))
        return
    end

    print("[PongDuMedBox] singleplayer path, granting locally sender=" .. tostring(sender))
    local player = getPlayer()
    if PongDuGrant.supply(player, BOX_ITEM, sender or "") then
        PongDuGrant.playSupplySound()
        print("[PongDuMedBox] box delivered sender=" .. tostring(sender))
    else
        print("[PongDuMedBox] grant FAILED sender=" .. tostring(sender))
    end
end

return _a
