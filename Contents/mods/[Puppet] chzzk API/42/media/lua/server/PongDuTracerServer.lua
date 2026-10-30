-- PongDuTracerServer: 트레이서(PongDuMutant_04) 시체의 후드티 색 (서버, SP 겸용).
--
-- 후드티(HoodieUP_WhiteTINT)는 클라가 좀비마다 마젠타로 칠한다(mutantspawn.lua tintTracer).
-- 서버 쪽 옷은 아웃핏 시드의 무작위 색이라 그대로 두면 시체와 루팅한 후드티가 다른 색이 된다
-- -> 죽을 때 서버에서도 칠한다. 마스크·고글 루팅은 PongDuMutantLoot.lua 가 맡는다.
--
-- IsoZombie.onKilled (서버/SP): DoZombieInventory(입은 옷 -> wornItems·인벤토리) -> OnZombieDead -> DoDeath(시체로 이동).
-- 시체 외형은 isUsingWornItems() 면 wornItems(= 인벤토리 아이템)의 외형으로, 아니면 좀비 itemVisuals 로 만들어진다.

if isClient() then return end

local LOG = "[PongDu][TracerServer] "
local HOODIE = "HoodieUP_WhiteTINT"
local HOODIE_HEX = "0xb3206f"   -- mutantspawn.lua 와 같은 값
local _hoodieColor = nil

Events.OnZombieDead.Add(function(z)
    if not z or not PongDuMutantId or PongDuMutantId.kindOf(z) ~= "tracer" then return end
    if not _hoodieColor then _hoodieColor = ImmutableColor.decode(HOODIE_HEX) end
    local inv = z:getInventory()
    local n = 0
    if inv then
        local items = inv:getItems()
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            if it and it:getClothingItemName() == HOODIE and it:getVisual() then
                it:getVisual():setTint(_hoodieColor)
                it:synchWithVisual()
                n = n + 1
            end
        end
    end
    -- 착용 아이템 모드면 getItemVisuals() 가 wornItems 로 다시 만들어지므로 위에서 칠한 걸로 충분하다.
    local v = 0
    if not z:isUsingWornItems() then
        local iv = z:getItemVisuals()
        for i = 0, iv:size() - 1 do
            local vis = iv:get(i)
            if vis and vis:getClothingItemName() == HOODIE then
                vis:setTint(_hoodieColor)
                v = v + 1
            end
        end
    end
    print(LOG .. "hoodie tinted on death items=" .. tostring(n) .. " visuals=" .. tostring(v)
        .. " zid=" .. tostring(z:getOnlineID()))
end)
