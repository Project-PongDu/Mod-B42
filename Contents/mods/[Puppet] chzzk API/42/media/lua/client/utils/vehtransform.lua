-- 차량 물리 원점(월드 트랜스폼) 읽기/쓰기 공용 헬퍼.
--
-- B41 은 BaseVehicle 의 private tempTransform 을 리플렉션(getNumClassFields /
-- getClassField / getClassFieldVal)으로 꺼내 썼다. B42 에서는 둘 다 막혔다.
--   - 리플렉션 전역 함수는 디버그 모드가 아니면 예외를 던진다
--     (LuaManager.validateReflectionAccess: !Core.debug -> "Not in debug")
--   - BaseVehicle 에 tempTransform 필드 자체가 없다
-- 대신 B42 는 zombie.core.physics.Transform 을 Lua 에 노출한다
-- (LuaManager.java setExposed(Transform.class), 기본 생성자 + getOrigin()).
-- getWorldTransform(out) 은 out 에 복사만 하므로 Transform 하나를 재사용한다.
--
-- 물리축: origin.x = iso x(월드심 오프셋 좌표계), origin.y = 고도, origin.z = iso y.
-- setWorldTransform 은 클라에서 Bullet.teleportVehicle 을 호출한다 (BaseVehicle.java:4105).

local M = {}

local _tr = nil

--- 차량의 월드 트랜스폼과 그 origin(Vector3f)을 돌려준다.
--- 반환된 tr 은 공용 객체이므로 다음 호출 전에 setWorldTransform 까지 끝낼 것.
function M.get(v)
    if not _tr then _tr = Transform.new() end
    local tr = v:getWorldTransform(_tr)
    return tr, tr:getOrigin()
end

--- origin 을 (ox, oy, oz) 로 바꿔 텔레포트한다.
function M.set(v, ox, oy, oz)
    local tr, origin = M.get(v)
    origin:set(ox, oy, oz)
    v:setWorldTransform(tr)
end

return M
