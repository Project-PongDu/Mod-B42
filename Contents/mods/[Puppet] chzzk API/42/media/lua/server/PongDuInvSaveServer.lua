-- PongDuInvSaveServer: 인벤세이브권(inv_save_ticket)의 MP 서버 처리.
--
-- [왜 서버인가]
--   B42 MP 는 아이템이 서버 권위다. B41 처럼 클라가 사망 때 자기 인벤을 비우고 리스폰 때
--   AddItem 으로 되돌리면 (1) 되돌린 아이템이 서버에 없어 보이기만 하고 쓰이지 않고
--   (2) 서버의 시체에는 원래 인벤이 그대로 남는다(시체는 서버 인벤으로 만든다). 클라 파일
--   스냅샷 복원은 클라가 아이템을 만들어 내는 구조라 복제 악용도 가능하다.
--   그래서 MP 는 서버가 사망 시점에 아이템 "객체"를 붙잡아 두고, 리스폰 때 새 캐릭터 인벤에
--   그 객체를 다시 넣는다. SP 는 기존 client/features/invsave.lua 경로를 그대로 쓴다.
--
-- [사망 순서 근거, b42.21 소스]
--   서버 IsoGameCharacter.die():
--     Kill() -> onKilled() -> IsoPlayer.DoDeath -> OnDeath -> "OnCharacterDeath" 이벤트
--     -> dropHeldItems(서버: 손 아이템 바닥에) -> becomeCorpse() (IsoDeadBody 가 인벤·착용을 복사)
--   IsoPlayer.OnDeath 의 "OnPlayerDeath" 는 !GameServer.server 에서만 발화하므로 서버는
--   OnCharacterDeath 를 쓴다. 여기서 인벤·착용·손을 비우면 시체와 바닥에 아무것도 안 남는다.
--   클라의 dropHandItems 가 나중에 보내는 PlayerDropHeldItems 는 서버 손이 이미 비어 있어 무동작.
--
-- [손 아이템] 사망 전에 피격 등으로 이미 바닥에 떨어진 손 아이템은 인벤에 없다. 서버에서도
--   setPrimaryHandItem 이 OnEquipPrimary 를 발화하므로(IsoGameCharacter.setPrimaryHandItem)
--   플레이어별 "마지막으로 든 아이템"을 기억했다가, 사망 때 아직 바닥에 있으면(getWorldItem)
--   회수한다. client/features/invsave.lua v3 와 같은 판정.
--
-- [복원] 클라가 리스폰(OnCreatePlayer) 3초 뒤 "Restore" 를 요청하면 새 캐릭터의 시작 장비를
--   치우고 붙잡아 둔 객체를 넣는다. 착용(setWornItem)·손(setPrimaryHandItem)은 서버에서 하면
--   엔진이 SyncClothing / Equip 패킷으로 알아서 동기화한다. 핫바 부착은 클라 UI 상태라
--   아이템 ID 목록을 돌려보내 클라가 붙인다.
--
-- [한계] 붙잡아 둔 객체는 서버 메모리에만 있다. 사망 후 리스폰 전에 서버가 재시작되면 사라진다.
--
-- media/lua/server 는 MP 클라에서도 로드된다. 서버에서만 동작하도록 맨 위에서 거른다.

if not isServer() then return end

local LOG         = "[PongDu][InvSaveServer] "
local MODULE      = "PongDuInvSave"
local TICKET_TYPE = "t3chzzkDonation.inv_save_ticket"

-- username -> { p = item, s = item }  (마지막으로 든 손 아이템. nil 로 덮지 않는다)
local _hand = {}
-- username -> { { item=, worn=ItemBodyLocation|nil, hand="P"|"S"|"B"|nil,
--                 slotType=string|nil, model=string|nil }, ... }
local _pending = {}

local function countOf(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

Events.OnEquipPrimary.Add(function(chr, item)
    if not item or not instanceof(chr, "IsoPlayer") then return end
    local u = chr:getUsername()
    if not u then return end
    _hand[u] = _hand[u] or {}
    _hand[u].p = item
end)

Events.OnEquipSecondary.Add(function(chr, item)
    if not item or not instanceof(chr, "IsoPlayer") then return end
    local u = chr:getUsername()
    if not u then return end
    _hand[u] = _hand[u] or {}
    _hand[u].s = item
end)

local function makeEntry(item, worn, hand)
    local e = { item = item, worn = worn, hand = hand }
    if item:getAttachedSlot() > -1 then
        e.slotType = item:getAttachedSlotType()
        e.model    = item:getAttachedToModel()
    end
    return e
end

local function onCharacterDeath(player)
    if not instanceof(player, "IsoPlayer") then return end
    local u = player:getUsername()
    if not u then return end

    local inv = player:getInventory()
    local ticket = inv and inv:getFirstTypeRecurse(TICKET_TYPE)
    if not ticket then
        _hand[u] = nil
        if _pending[u] then
            print(LOG .. "death without ticket user=" .. u .. ", earlier snapshot kept for next respawn")
        end
        return
    end

    local tc = ticket:getContainer()
    if tc then tc:Remove(ticket) end

    -- 리스폰 전에 또 죽은 경우: 아직 안 돌려준 것에 이번 것을 이어 붙인다.
    local entries = _pending[u] or {}
    local carried = #entries

    -- 손 아이템: 현재 손 + 마지막으로 든 것.
    local prim = player:getPrimaryHandItem()
    local sec  = player:getSecondaryHandItem()
    local h = _hand[u] or {}
    local lastP = prim or h.p
    local lastS = sec or h.s

    local hands = {}
    if lastP then hands[#hands + 1] = { item = lastP, slot = (lastS == lastP) and "B" or "P" } end
    if lastS and lastS ~= lastP then hands[#hands + 1] = { item = lastS, slot = "S" } end

    -- 이미 바닥에 떨어진 손 아이템은 회수해서 바로 넣고, 인벤에 있는 것은 아래 루프에서
    -- 손 표시만 붙인다.
    local fromFloor = 0
    local handInInv = {}
    for _, hd in ipairs(hands) do
        local it = hd.item
        local wi = it:getWorldItem()
        if wi then
            local sq = wi:getSquare()
            if sq then sq:transmitRemoveItemFromSquare(wi) end
            it:setWorldItem(nil)
            entries[#entries + 1] = makeEntry(it, nil, hd.slot)
            fromFloor = fromFloor + 1
        else
            handInInv[#handInInv + 1] = hd
        end
    end
    local function handSlotOf(it)
        for _, hd in ipairs(handInInv) do
            if hd.item == it then return hd.slot end
        end
        return nil
    end

    -- 인벤 최상위 아이템 (가방 안 내용물은 가방 객체에 같이 붙어 간다).
    local worn = player:getWornItems()
    local items = inv:getItems()
    local list = {}
    for i = 0, items:size() - 1 do list[#list + 1] = items:get(i) end
    for _, it in ipairs(list) do
        entries[#entries + 1] = makeEntry(it, worn:getLocation(it), handSlotOf(it))
    end

    -- 비우기. 손 -> 착용 -> 부착 -> 인벤 순. 서버 setWornItem 계열은 SyncClothing 을 보내지만
    -- clearWornItems 는 안 보낸다. 곧 시체 패킷이 클라 인벤·착용을 시체 기준으로 다시 맞춘다
    -- (DeadCharacterPacket.parseCharacterInventory).
    player:setPrimaryHandItem(nil)
    player:setSecondaryHandItem(nil)
    player:clearWornItems()
    local attached = player:getAttachedItems()
    if attached then attached:clear() end
    inv:clear()

    _pending[u] = entries
    _hand[u] = nil

    print(LOG .. "death user=" .. u .. " held " .. #entries .. " top-level items in server memory"
        .. " (carried=" .. carried .. ", fromFloor=" .. fromFloor .. ", pendingUsers=" .. countOf(_pending) .. ")")
end

Events.OnCharacterDeath.Add(function(chr)
    local ok, err = pcall(onCharacterDeath, chr)
    if not ok then print(LOG .. "death handler error: " .. tostring(err)) end
end)

-- 새 캐릭터 시작 장비 치우기 (각각 클라에 반영되도록 보내면서).
local function stripSpawnLoadout(player)
    local inv = player:getInventory()
    local items = inv:getItems()
    local list = {}
    for i = 0, items:size() - 1 do list[#list + 1] = items:get(i) end
    player:setPrimaryHandItem(nil)
    player:setSecondaryHandItem(nil)
    for _, it in ipairs(list) do
        if player:isEquippedClothing(it) then player:removeWornItem(it, false) end
        inv:Remove(it)
        sendRemoveItemFromContainer(inv, it)
    end
    return #list
end

local function restore(player)
    local u = player:getUsername()
    local entries = u and _pending[u]
    if not entries then
        sendServerCommand(player, MODULE, "Nothing", {})
        return
    end
    _pending[u] = nil

    local stripped = stripSpawnLoadout(player)
    local inv = player:getInventory()
    local hotbar = {}
    local restored, failed = 0, 0

    for _, e in ipairs(entries) do
        local ok, err = pcall(function()
            local it = e.item
            inv:AddItem(it)
            sendAddItemToContainer(inv, it)
            if e.worn then player:setWornItem(e.worn, it) end
            if e.hand == "P" or e.hand == "B" then player:setPrimaryHandItem(it) end
            if e.hand == "S" or e.hand == "B" then player:setSecondaryHandItem(it) end
            if e.slotType then
                hotbar[#hotbar + 1] = {
                    ["id"] = it:getID(), ["slotType"] = e.slotType, ["model"] = e.model,
                }
            end
        end)
        if ok then
            restored = restored + 1
        else
            failed = failed + 1
            print(LOG .. "restore item error user=" .. u .. ": " .. tostring(err))
        end
    end

    sendServerCommand(player, MODULE, "Restored", {
        ["restored"] = restored, ["failed"] = failed, ["hotbar"] = hotbar,
    })
    print(LOG .. "restored user=" .. u .. " items=" .. restored .. " failed=" .. failed
        .. " hotbar=" .. #hotbar .. " strippedSpawn=" .. stripped)
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= MODULE then return end
    if not player then return end
    if command == "Restore" then
        local ok, err = pcall(restore, player)
        if not ok then print(LOG .. "restore error: " .. tostring(err)) end
    else
        print(LOG .. "unknown command " .. tostring(command) .. " from " .. tostring(player:getUsername()))
    end
end)
