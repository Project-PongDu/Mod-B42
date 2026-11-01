-- PongDuRisenOutfitServer.lua : 강령술로 일어난 좀비의 '실제 복장'을 클라에 알린다 (MP 서버 전용)
--
-- ── 문제 ────────────────────────────────────────────────────────────────────
-- 강령술은 시체를 fakeDead 경로로 일으킨다(server.lua markFakeDead). 서버 좀비는
-- IsoDeadBody.reanimate 에서 시체의 wornItems·attachedItems·인벤토리를 그대로 물려받고
-- wasFakeDead=true 가 된다 -> 루팅으로 빠진 옷은 서버 좀비에도 없다.
-- 그런데 wasFakeDead 는 패킷에 실리지 않아 클라는 이 좀비를 평범한 좀비로 보고
-- ModelManager.dressInRandomOutfit 에서 옷 ID(persistentOutfitID)로 아웃핏 전체를 다시 입힌다.
-- 결과: 루팅으로 벗겨진 시체가 클라 화면에선 다 입은 채로 일어나고, 죽이면 서버 시체(벗겨진 상태)가 나온다.
--
-- ── 해결 ────────────────────────────────────────────────────────────────────
-- 서버가 부활 좀비를 찾으면 실제로 입은 옷(ItemVisual 의 clothingItemName)과 허리 무기 등
-- 부착 아이템(fullType) 목록을 클라에 보낸다. 클라(PongDuRisenOutfit.lua)는 옷 ID 로 입힌 뒤
-- 목록에 없는 것만 뺀다. 클라·서버 모두 같은 옷 ID 시드(OutfitRNG)로 입히므로 남은 옷의
-- 종류·색·속옷은 서버와 같고, 클라는 '빼기'만 하면 된다.
--
-- ── 한계 (의도적으로 그대로 둠) ─────────────────────────────────────────────
-- 부활 좀비가 가상화(주변 플레이어 이탈·서버 재시작)되면 엔진이 옷 ID 로 전체 복장을 다시 입혀
-- 서버·클라 모두 다 입은 상태로 돌아온다. 그때는 이 목록도 지운다(RisenClear).

if isClient() then return end

local LOG     = "[PongDu][RisenOutfit] "
local MODULE  = "PongDuRiseUp"
local SCAN_MS = 250

local _sent     = {}      -- [onlineID] = { z = IsoZombie, pid, worn = {...}, att = {...} }
local _lastScan = 0
local _api      = nil     -- nil = 미확인, true = wasFakeDead() 사용 가능, false = 사용 불가(기능 끔)

-- wasFakeDead() 는 public 메서드라 Lua 노출이 정상이지만, 처음 한 번만 pcall 로 확인한다.
local function checkApi(z)
    local ok, v = pcall(function() return z:wasFakeDead() end)
    _api = ok and (v == true or v == false)
    print(LOG .. "wasFakeDead() callable=" .. tostring(_api))
end

local function collect(z)
    local worn, att = {}, {}
    local wi = z:getWornItems()
    if wi then
        for i = 0, wi:size() - 1 do
            local it = wi:getItemByIndex(i)
            local v = it and it:getVisual()
            local name = v and v:getClothingItemName()
            if name then worn[#worn + 1] = name end
        end
    end
    local ai = z:getAttachedItems()
    if ai then
        for i = 0, ai:size() - 1 do
            local it = ai:getItemByIndex(i)
            if it then att[#att + 1] = it:getFullType() end
        end
    end
    return worn, att
end

local function payload(zid, rec)
    return { ["zid"] = zid, ["pid"] = rec.pid, ["worn"] = rec.worn, ["att"] = rec.att }
end

local function scan()
    local cell = getCell()
    if not cell then return end
    local zeds = cell:getZombieList()
    if not zeds then return end
    local seen = {}
    for i = 0, zeds:size() - 1 do
        local z = zeds:get(i)
        if z and not z:isDead() then
            local zid = z:getOnlineID()
            local rec = _sent[zid]
            if rec and rec.z == z then
                seen[zid] = true
            elseif not z:isReanimatedPlayer() then          -- 좀비화 플레이어는 디스크립터 경로라 대상 아님
                if _api == nil then checkApi(z) end
                if not _api then return end
                if z:wasFakeDead() then
                    local worn, att = collect(z)
                    rec = { z = z, pid = z:getPersistentOutfitID(), worn = worn, att = att }
                    _sent[zid] = rec
                    seen[zid] = true
                    sendServerCommand(MODULE, "RisenWorn", payload(zid, rec))
                    local kind = PongDuMutantId and PongDuMutantId.kindOf(z)
                    print(LOG .. "worn sent zid=" .. tostring(zid) .. " pid=" .. tostring(rec.pid)
                        .. " kind=" .. tostring(kind) .. " worn=" .. #worn .. " att=" .. #att)
                end
            end
        end
    end
    for zid, rec in pairs(_sent) do
        if not seen[zid] then
            _sent[zid] = nil
            sendServerCommand(MODULE, "RisenClear", { ["zid"] = zid })
            print(LOG .. "cleared zid=" .. tostring(zid) .. " (dead or unloaded)")
        end
    end
end

-- SP 는 한 객체를 같이 쓰므로(서버 좀비 = 화면 좀비) 어긋남이 없다. MP 서버에서만 돈다.
if isServer() then
    Events.OnTick.Add(function()
        if _api == false then return end
        local now = getTimestampMs()
        if now - _lastScan < SCAN_MS then return end
        _lastScan = now
        scan()
    end)

    -- 늦게 접속한 클라: 지금 살아 있는 부활 좀비 목록을 통째로 받는다.
    Events.OnClientCommand.Add(function(module, command, player, args)
        if module ~= MODULE or command ~= "RisenSync" or not player then return end
        local n = 0
        for zid, rec in pairs(_sent) do
            sendServerCommand(player, MODULE, "RisenWorn", payload(zid, rec))
            n = n + 1
        end
        print(LOG .. "sync sent to=" .. tostring(player:getUsername()) .. " entries=" .. n)
    end)
end
