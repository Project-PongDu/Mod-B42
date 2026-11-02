HitmanZombieActions = HitmanZombieActions or {}

HitmanZombieActions.Idle = {}
HitmanZombieActions.Idle.onStart = function(zombie, task)
    return true
end

HitmanZombieActions.Idle.onWorking = function(zombie, task)
    return false
end

HitmanZombieActions.Idle.onComplete = function(zombie, task)
    local square = zombie:getCell():getGridSquare(task.x, task.y, task.z)
    return true
end

