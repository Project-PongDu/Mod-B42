-- ── 의약품 랜덤박스 (medical_box) 서버 ───────────────────────────────────────
--
-- 서버 후원 계열. 서버장에게 후원이 들어오면 접속자 전원에게 의약품 보급상자를
-- 1개씩 지급한다. 서버가 하는 일:
--   ① 서버장 게이트 (PongDuHost.check)
--   ② 접속자 전원 인벤에 직접 지급 (shared/PongDuGrant.lua, sendAddItemToContainer 로 각 소유 클라 동기화)
--   ③ 받은 사람마다 "Delivered" 를 돌려보내 보급음 재생
--
-- B42 MP 는 아이템이 서버 권위다. B41 처럼 각 클라가 자기 인벤에 AddItem 하면 아이템이 보이기만
-- 하고 개봉·버리기가 안 된다(서버에 없는 아이템이라 ItemTransactionPacket 이 Reject).
--
-- 이 파일은 media/lua/server/ 에 있어 MP 클라에서도 로드된다. OnClientCommand
-- 핸들러에 isAuthority() 가드가 반드시 있어야 한다.

require "PongDuGrant"

local LOG = "[PongDuMedBox] "
local BOX_ITEM = "medical_box"

local function mlog(msg)
    print(LOG .. msg)
end

-- isAuthority() 는 B41 바닐라 전역이 아니다. PongDuHordeServer 와 동일하게
-- 로컬로 정의한다. SP 는 isClient()/isServer() 둘 다 false 이므로 not isClient().
local function isAuthority()
    return not isClient()
end

Events.OnClientCommand.Add(function(module, command, player, data)
    if module ~= "PongDuMedBox" then return end
    if not isAuthority() then return end
    if command ~= "Request" then return end

    -- 서버장 게이트. isAuthority() 는 "이 코드가 서버에서 도는가"만 보지 누가
    -- 보냈는지는 안 본다. 접속자 전원에게 아이템이 나가는 효과라 서버장에게
    -- 들어온 후원만 통과시킨다. 클라 쪽 검사는 전부 우회 가능하므로 여기가
    -- 유일한 강제 지점이다.
    local verdict = PongDuHost.check(player)
    if verdict ~= PongDuHost.OK then
        mlog("REQUEST DENIED user=" .. tostring(player and player:getUsername())
            -- Kahlua 는 SteamID64 를 double 로 넘기므로 tostring() 하면 지수표기가
            -- 나와 샌박 값과 육안 대조가 안 된다. %.0f 로 정수 형태를 강제한다.
            .. " steamID=" .. string.format("%.0f", (player and player:getSteamID()) or 0)
            .. " reason=" .. tostring(verdict))
        -- 거부 안내는 공용 클라 핸들러(client/PongDuHostClient.lua)가 처리한다.
        sendServerCommand(player, "PongDuHost", "Denied", { ["why"] = verdict })
        return
    end

    local sender = tostring(data and data["sender"] or "")
    local players = getOnlinePlayers()
    local total = players and players:size() or 0
    local given = 0
    for i = 0, total - 1 do
        local p = players:get(i)
        if p and not p:isDead() then
            if PongDuGrant.supply(p, BOX_ITEM, sender) then
                given = given + 1
                sendServerCommand(p, PongDuGrant.NET_MODULE, "Delivered", {
                    ["kind"] = "medical_box", ["item"] = BOX_ITEM, ["count"] = 1, ["sender"] = sender,
                })
            else
                mlog("GRANT FAILED user=" .. tostring(p:getUsername()))
            end
        end
    end
    mlog("GRANT done sender=" .. sender .. " given=" .. given .. "/" .. total)
end)
