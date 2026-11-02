HitmanNotifications = HitmanNotifications or {}

HitmanNotifications.EVENT_TOGGLE_DOOR = "OnHitmanDoorToggled"
LuaEventManager.AddEvent(HitmanNotifications.EVENT_TOGGLE_DOOR)

HitmanNotifications.DoorToggled = function(hitman, object, open)
    if not hitman or not object then return end

    local square = object:getSquare()
    if not square then return end

    local info = {
        x = square:getX(),
        y = square:getY(),
        z = square:getZ(),
        idx = object:getObjectIndex(),
        open = open == true,
    }

    LuaEventManager.triggerEvent(HitmanNotifications.EVENT_TOGGLE_DOOR, hitman, object, info)
end