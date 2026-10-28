--- Project Viewpoint(워크샵 3809306528, mod id Viewpoint) 시점 감지.
---
--- Viewpoint 는 자체 3D 렌더러로 1인칭/3인칭을 그린다. 이때 바닐라 아이소 화면 좌표
--- (isoToScreenX/Y)로 OnPreUIDraw 에 그리는 2D 오버레이(수송기 그림자 등)는 3D 화면과
--- 맞지 않는 엉뚱한 위치에 그려지므로, 1·3인칭에서는 그리지 않는다.
---
--- 공개 Lua API: Viewpoint.View.next() = "다음" 시점 이름 (Viewpoint_Pad.lua 의 v.next()).
--- 반환값과 현재 시점의 대응 (Viewpoint.jar FP.nextView: View.enabled / View.thirdPerson):
---   "first"     -> 지금 아이소 (Viewpoint 꺼짐)
---   "third"     -> 지금 1인칭
---   "isometric" -> 지금 3인칭
--- Viewpoint 가 없으면(전역 Viewpoint 없음) 항상 아이소.

local M = {}

local CHECK_MS = 250                 -- Java 호출 간격 (렌더 훅마다 부르지 않게)
local NEXT_TO_MODE = { first = "isometric", third = "first", isometric = "third" }

local _mode, _checkedAt = "isometric", nil

--- 현재 시점: "isometric" | "first" | "third"
function M.mode()
    local now = getTimestampMs()
    if _checkedAt and now - _checkedAt < CHECK_MS then return _mode end
    _checkedAt = now
    local api = Viewpoint and Viewpoint.View
    local mode = "isometric"
    local nxt = "none"
    if api and api.next then
        local ok, v = pcall(api.next)
        if ok and v then
            nxt = tostring(v)
            mode = NEXT_TO_MODE[nxt] or "isometric"
        else
            nxt = "error"
        end
    end
    if mode ~= _mode then
        print("[PongDu][View] viewpoint view " .. _mode .. " -> " .. mode .. " (next=" .. nxt .. ")")
        _mode = mode
    end
    return _mode
end

--- 1·3인칭(Viewpoint 3D 시점)이면 true. 아이소 화면 좌표 2D 오버레이를 그리면 안 되는 상태.
function M.isPerspective()
    return M.mode() ~= "isometric"
end

return M
