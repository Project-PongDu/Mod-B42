-- PongDuRisenOutfit.lua : 강령술로 일어난 좀비를 서버의 실제 복장대로 그린다 (MP 클라 전용)
--
-- 클라는 부활 좀비를 옷 ID 로 아웃핏 전체를 입혀 그린다(wasFakeDead 미동기화 -> ModelManager.dressInRandomOutfit).
-- 서버(PongDuRisenOutfitServer.lua)가 보낸 '실제로 남은 옷·부착 아이템' 목록에 없는 것만 뺀다.
-- 같은 옷 ID 시드로 입히므로 남은 옷의 색·텍스처·속옷은 서버와 같다 -> 빼기만 하면 일치한다.
--
-- 적용 시점: 클라가 옷을 다 입힌 뒤(isPersistentOutfitInit). 그 전에 빼면 입히면서 다시 채워진다.
-- 객체 재사용(resetForReuse)은 modData 와 옷을 같이 지우고 다시 입히므로 표시가 지워져 다시 뺀다.
-- 같은 zid 가 다른 좀비에 재사용될 수 있어 옷 ID 까지 같을 때만 적용한다.

if not isClient() then return end

local LOG     = "[PongDu][RisenOutfit] "
local MODULE  = "PongDuRiseUp"
local SCAN_MS = 200
local APPLIED = "PongDuRisenStripped"

local _cache = {}     -- [zid] = { pid, worn = set, att = set, nWorn, nAtt }
local _n     = 0
local _last  = 0

local function toSet(list)
    local s, n = {}, 0
    if type(list) == "table" then
        for _, v in pairs(list) do
            if type(v) == "string" then
                s[v] = true
                n = n + 1
            end
        end
    end
    return s, n
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= MODULE or type(args) ~= "table" then return end
    if command == "RisenWorn" then
        local zid = tonumber(args["zid"])
        if not zid then return end
        local worn, nWorn = toSet(args["worn"])
        local att, nAtt = toSet(args["att"])
        if not _cache[zid] then _n = _n + 1 end
        _cache[zid] = { pid = tonumber(args["pid"]), worn = worn, att = att, nWorn = nWorn, nAtt = nAtt }
        print(LOG .. "worn received zid=" .. tostring(zid) .. " worn=" .. nWorn .. " att=" .. nAtt)
    elseif command == "RisenClear" then
        local zid = tonumber(args["zid"])
        if zid and _cache[zid] then
            _cache[zid] = nil
            _n = _n - 1
        end
    end
end)

local function apply(z, zid, rec)
    local removed = {}
    -- 옷: 이 좀비는 착용 아이템 모드가 아니라 getItemVisuals() 가 실제 그리기 목록을 그대로 돌려준다.
    -- 지울 때는 객체로 지운다(remove(Object)). 숫자 인덱스는 Kahlua 가 Double 로 넘겨 remove(int) 가 안 잡힌다.
    local iv = z:getItemVisuals()
    local dropV = {}
    if iv then
        for i = 0, iv:size() - 1 do
            local v = iv:get(i)
            local name = v and v:getClothingItemName()
            if v and not (name and rec.worn[name]) then dropV[#dropV + 1] = v end
        end
        for _, v in ipairs(dropV) do
            removed[#removed + 1] = tostring(v:getClothingItemName())
            iv:remove(v)
        end
    end
    -- 부착 아이템(허리 진압봉 등): 클라는 옷을 입히며 AttachedWeaponDefinitions 로 다시 붙인다.
    local ai = z:getAttachedItems()
    local dropA = {}
    if ai then
        for i = 0, ai:size() - 1 do
            local it = ai:getItemByIndex(i)
            if it and not rec.att[it:getFullType()] then dropA[#dropA + 1] = it end
        end
        for _, it in ipairs(dropA) do
            removed[#removed + 1] = tostring(it:getFullType())
            ai:remove(it)
        end
    end
    if #removed > 0 then z:resetModel() end
    print(LOG .. "stripped zid=" .. tostring(zid) .. " removed=" .. #removed
        .. " keptWorn=" .. tostring(rec.nWorn) .. " keptAtt=" .. tostring(rec.nAtt)
        .. (#removed > 0 and (" items=" .. table.concat(removed, ",")) or ""))
end

Events.OnTick.Add(function()
    if _n <= 0 then return end
    local now = getTimestampMs()
    if now - _last < SCAN_MS then return end
    _last = now
    local cell = getCell()
    if not cell then return end
    local zl = cell:getZombieList()
    if not zl then return end
    for i = 0, zl:size() - 1 do
        local z = zl:get(i)
        if z and not z:isDead() then
            local zid = z:getOnlineID()
            local rec = _cache[zid]
            if rec then
                local md = z:getModData()
                if not md[APPLIED] and not z:isUsingWornItems() and z:isPersistentOutfitInit() then
                    md[APPLIED] = true
                    local pid = z:getPersistentOutfitID()
                    if rec.pid and rec.pid ~= pid then
                        print(LOG .. "skip zid=" .. tostring(zid) .. " pid mismatch server=" .. tostring(rec.pid)
                            .. " client=" .. tostring(pid))
                    else
                        apply(z, zid, rec)
                    end
                end
            end
        end
    end
end)

-- 접속 직후: 이미 살아 있는 부활 좀비 목록을 서버에서 받는다.
Events.OnGameStart.Add(function()
    sendClientCommand(MODULE, "RisenSync", {})
end)
