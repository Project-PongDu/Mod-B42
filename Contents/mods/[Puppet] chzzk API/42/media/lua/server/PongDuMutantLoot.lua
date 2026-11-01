-- PongDuMutantLoot.lua : 특좀 머리 장비 고정 + 루팅용 바닐라 아이템 (서버/SP)
--
-- 특좀은 종류마다 외형이 하나로 고정이라, 모자·안경·마스크가 맞거나 밀쳐져서 떨어지면 안 된다.
-- 바닐라는 ChanceToFall > 0 인 옷을 IsoZombie.helmetFallFromVisuals 에서 떨어뜨린다
-- (CombatManager 타격마다 호출, 머리 타격이면 +40). 그래서 아웃핏에는 같은 모델의 숨김 장식
-- (ChanceToFall 없음, zeddmg·hidden)을 입히고, 죽을 때 바닐라 아이템을 인벤토리에 넣어 루팅되게 한다.
-- 표식 달린 바닐라 아이템을 시체에서 꺼내면 같은 시체의 장식도 빼서 벗겨지는 연출을 맞춘다.
--
-- 새 특좀 장비를 이 방식으로 고정하려면 COSMETIC_LOOT 에 한 줄 추가 + 장식 의류(xml·스크립트·GUID)를 만든다.
-- 장식 루팅 아이템은 그 장식을 실제로 입었을 때만 지급한다 (아웃핏 subItems 로 여럿 중 하나를 고르는 장비용).
-- REWARD_LOOT 는 장식과 무관한 처치 보상(트레이서 권총, 스크리머 의약품, 로치 공구)이다.
--
-- [루팅은 특좀 한 마리당 한 번]
-- 처치 보상: 처음 소환된 특좀(기본 아웃핏)이 죽을 때만 준다. 강령술로 일어난 특좀은 옷 ID 가 부활 아웃핏
--   (PongDuMutantId.isRisenPid)이라 가상화·서버 재시작을 거쳐도 다시 주지 않는다.
-- 장식 루팅: 장식을 입고 죽을 때 1번. 일어날 때 남은 장식의 짝 루팅 아이템은 지워지고(PongDuMutantRisenServer)
--   장식은 부활 아웃핏에 남으므로, 그 좀비가 다시 죽을 때 1번 준다. 장식을 가져가면 시체에서 장식이 빠져
--   다음 부활 아웃핏에서 그 장식이 없다. 같은 인벤토리에 이미 표식 달린 아이템이 있으면 주지 않는다.
-- 슬래머 방독면은 상체 확대 셰이더가 걸린 장식이라 PongDuSlammerServer.lua 가 같은 방식으로 따로 처리한다.
--
-- 호출 순서: IsoZombie.onKilled (서버/SP) -> DoZombieInventory(입은 옷 -> 인벤토리) -> OnZombieDead -> DoDeath.
-- MP 에선 서버 시체 인벤토리가 DeadZombiePacket 으로 클라에 간다.

if isClient() then return end

local LOG = "[PongDu][MutantLoot] "
local LOOT_TAG = "PongDuMutantLoot"   -- 바닐라 아이템 modData: 같이 뺄 장식 아이템 fullType

-- 종류 -> { { loot = 루팅용 바닐라 아이템, cosmetic = 아웃핏에 입힌 장식 아이템 }, ... }
local COSMETIC_LOOT = {
    roach = {
        { loot = "Base.Hat_BuildersRespirator", cosmetic = "t3chzzkDonation.PongDuRoachRespirator" },
        -- 형광 조끼: 좀비는 연두 형광 장식, 루팅은 바닐라 노랑 조끼
        { loot = "Base.Vest_HighViz",           cosmetic = "t3chzzkDonation.PongDuRoachVest" },
    },
    -- 트레이서(탈옥수): 허리에 묶은 죄수복은 입고 있을 때만 있는 장식, 루팅은 바닐라 죄수복 점프수트 (PongDu_tracer_items.txt)
    tracer = {
        { loot = "Base.Boilersuit_Prisoner",    cosmetic = "t3chzzkDonation.PongDuTracerTiedSuit" },
    },
}

-- 인벤토리에 표식 달린 루팅 아이템(짝 장식 = cosmetic)이 이미 있는가
local function hasTaggedLoot(inv, lootType, cosmetic)
    local items = inv:getItems()
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if it and it:getFullType() == lootType and it:getModData()[LOOT_TAG] == cosmetic then return true end
    end
    return false
end

-- 강령술(fakeDead 경로) 부활 좀비인지. 확인 못 하면 nil (지급은 그대로 진행).
local function wasFakeDead(z)
    local ok, v = pcall(function() return z:wasFakeDead() end)
    if ok then return v == true end
    return nil
end

-- ── 처치 보상 ──────────────────────────────────────────────────────────────
-- 아이템 이름은 B42 42.21 바닐라 generated/items 스크립트 기준.

-- 트레이서(탈옥수): 바닐라 루팅 테이블에 나오는 실총 권총 6종 중 하나를 무조건 지급 (장난감 Revolver_CapGun 제외).
-- 탄은 그 총 장탄수(getMaxAmmo)의 2배를 낱발로. 탄창식이면 빈 탄창을 끼운 상태(setContainsClip), 리볼버는 빈 실린더.
local TRACER_PISTOLS = {
    { gun = "Base.Pistol",          ammo = "Base.Bullets9mm" },   -- M9, 15발, 9mmClip
    { gun = "Base.Pistol2",         ammo = "Base.Bullets45" },    -- M1911, 7발, 45Clip
    { gun = "Base.Pistol3",         ammo = "Base.Bullets44" },    -- D-E, 8발, 44Clip
    { gun = "Base.Revolver",        ammo = "Base.Bullets357" },   -- .357, 6발
    { gun = "Base.Revolver_Long",   ammo = "Base.Bullets44" },    -- .44 매그넘, 6발
    { gun = "Base.Revolver_Short",  ammo = "Base.Bullets38" },    -- .38 단신, 5발
}

local function giveTracerPistol(z, inv, kind, zid)
    local e = TRACER_PISTOLS[ZombRand(#TRACER_PISTOLS) + 1]
    local gun = inv:AddItem(e.gun)
    if not gun or not instanceof(gun, "HandWeapon") then
        print(LOG .. "reward failed kind=" .. kind .. " gun=" .. e.gun .. " item=" .. tostring(gun) .. " zid=" .. zid)
        return
    end
    gun:setCurrentAmmoCount(0)
    gun:setRoundChambered(false)
    local mag = gun:getMagazineType()
    local hasMag = mag ~= nil and mag ~= ""
    gun:setContainsClip(hasMag)
    local cap = gun:getMaxAmmo()
    local want = cap * 2
    local got = 0
    for _ = 1, want do
        if inv:AddItem(e.ammo) then got = got + 1 end
    end
    print(LOG .. "reward added kind=" .. kind .. " gun=" .. e.gun .. " cap=" .. tostring(cap)
        .. " ammo=" .. e.ammo .. " x" .. got .. "/" .. want
        .. " mag=" .. (hasMag and mag or "none") .. " clipIn=" .. tostring(gun:isContainsClip())
        .. " zid=" .. zid)
end

-- 표 방식 보상. 한 줄 = { item 또는 oneOf, n (개수) 또는 nMin~nMax (무작위 개수), chance (0~100, 없으면 100) }
local REWARD_ITEMS = {
    -- 스크리머(전신화상 환자): 응급 처치 묶음
    screamer = {
        { item = "Base.AlcoholBandage", n = 4 },                          -- 소독된 붕대
        { oneOf = { "Base.Pills", "Base.PillsBeta" }, n = 1 },            -- 진통제 / 베타 차단제(긴장완화제)
        { item = "Base.SutureNeedle", n = 3 },                            -- 봉합용 바늘
        { item = "Base.Disinfectant", n = 1, chance = 50 },               -- 소독약 (50%)
    },
    -- 로치(공사장 인부): 바리케이드 공구 묶음
    roach = {
        { item = "Base.Plank", nMin = 1, nMax = 2 },                      -- 판자 1~2
        { item = "Base.Hammer", n = 1 },                                  -- 망치
        { oneOf = { "Base.Saw", "Base.GardenSaw" }, n = 1 },              -- 톱 / 정원용 톱
        { item = "Base.NailsBox", n = 1 },                                -- 못 상자
        { item = "Base.Rope", n = 2 },                                    -- 밧줄 2
    },
}

local function giveRewardItems(z, inv, kind, zid)
    local list = REWARD_ITEMS[kind]
    local parts = {}
    for i = 1, #list do
        local e = list[i]
        local chance = e.chance or 100
        if chance >= 100 or ZombRand(100) < chance then
            local item = e.item
            if e.oneOf then item = e.oneOf[ZombRand(#e.oneOf) + 1] end
            local n = e.n
            if not n then n = e.nMin + ZombRand(e.nMax - e.nMin + 1) end
            local got = 0
            for _ = 1, n do
                if inv:AddItem(item) then got = got + 1 end
            end
            parts[#parts + 1] = item .. " x" .. got .. "/" .. n
        else
            parts[#parts + 1] = tostring(e.item) .. " (chance " .. chance .. " miss)"
        end
    end
    print(LOG .. "reward added kind=" .. kind .. " " .. table.concat(parts, ", ") .. " zid=" .. zid)
end

local REWARD_LOOT = {
    tracer   = giveTracerPistol,
    screamer = giveRewardItems,
    roach    = giveRewardItems,
}

Events.OnZombieDead.Add(function(z)
    if not z or not PongDuMutantId then return end
    local kind = PongDuMutantId.kindOf(z)
    if not kind then return end
    local list = COSMETIC_LOOT[kind]
    local reward = REWARD_LOOT[kind]
    if not list and not reward then return end
    local zid = tostring(z:getOnlineID())
    local inv = z:getInventory()
    if not inv then
        print(LOG .. "loot skipped (no inventory) kind=" .. tostring(kind) .. " zid=" .. zid)
        return
    end
    local risen = PongDuMutantId.isRisenPid and PongDuMutantId.isRisenPid(z:getPersistentOutfitID())
    if reward then
        if risen or wasFakeDead(z) then
            print(LOG .. "reward skipped (risen by necromancy, loot once) kind=" .. tostring(kind)
                .. " slot=" .. tostring(PongDuMutantId.slotOfPid and PongDuMutantId.slotOfPid(z:getPersistentOutfitID()))
                .. " zid=" .. zid)
        else
            local ok, err = pcall(reward, z, inv, kind, zid)
            if not ok then print(LOG .. "reward error kind=" .. tostring(kind) .. " err=" .. tostring(err)) end
        end
    end

    if not list then return end
    for i = 1, #list do
        local e = list[i]
        if not inv:containsType(e.cosmetic) then
            -- 장식을 이미 루팅당했거나(부활 아웃핏에 없음) 아웃핏 subItems 로 다른 하위 항목을 골랐다
            print(LOG .. "loot skipped (cosmetic not worn) kind=" .. tostring(kind) .. " item=" .. e.loot
                .. " cosmetic=" .. e.cosmetic .. " zid=" .. zid)
        elseif hasTaggedLoot(inv, e.loot, e.cosmetic) then
            print(LOG .. "loot skipped (already in inventory) kind=" .. tostring(kind) .. " item=" .. e.loot
                .. " zid=" .. zid)
        else
            local it = inv:AddItem(e.loot)
            if it then it:getModData()[LOOT_TAG] = e.cosmetic end
            print(LOG .. "loot added kind=" .. tostring(kind) .. " item=" .. e.loot
                .. " ok=" .. tostring(it ~= nil) .. " zid=" .. zid)
        end
    end
end)

-- 바닐라는 시체 인벤토리에서 착용 아이템이 빠지면 ItemContainer.DoRemoveItem -> IsoDeadBody.checkClothing 으로
-- 착용 슬롯에서도 빼 다시 그린다. 루팅되는 건 바닐라 아이템이고 시체가 입은 건 장식이라 장식을 직접 뺀다.
-- ISTransferAction.transferItem 은 SP 에서만 돈다. MP 의 아이템 이동은 서버 자바 트랜잭션(Transaction.updateItem)이
-- 처리해 이 훅을 거치지 않으므로, 클라(PongDuMutantLootClient.lua)가 보고하면 아래 OnClientCommand 가 뺀다.
local function removeCosmetic(container, fullType)
    local items = container:getItems()
    for i = items:size() - 1, 0, -1 do
        local it = items:get(i)
        if it and it:getFullType() == fullType then
            container:DoRemoveItem(it)
            if isServer() then sendRemoveItemFromContainer(container, it) end
            return true
        end
    end
    return false
end

if ISTransferAction and ISTransferAction.transferItem then
    local origTransferItem = ISTransferAction.transferItem
    ISTransferAction.transferItem = function(self, character, item, srcContainer, destContainer, dropSquare)
        local result = origTransferItem(self, character, item, srcContainer, destContainer, dropSquare)
        local body = srcContainer and srcContainer:getParent()
        if item and body and instanceof(body, "IsoDeadBody") then
            local md = item:getModData()
            local cosmetic = md[LOOT_TAG]
            if type(cosmetic) == "string" then
                md[LOOT_TAG] = nil
                local removed = removeCosmetic(srcContainer, cosmetic)
                print(LOG .. "corpse item looted item=" .. tostring(item:getFullType())
                    .. " cosmeticRemoved=" .. tostring(removed)
                    .. " by=" .. tostring(character and character:getUsername()))
            end
        end
        return result
    end
    print(LOG .. "transfer hook installed")
else
    print(LOG .. "transfer hook skipped (ISTransferAction missing)")
end

-- ── MP: 클라가 알려 준 시체 아이템 루팅 ──────────────────────────────────────
-- 클라는 퐁듀 장식이 남은 시체에서 아이템을 옮기면 칸 좌표와 아이템 fullType 을 보낸다.
-- 그 칸 시체마다 해당 바닐라 아이템과 짝인 장식이 있는데 표식 달린 바닐라 아이템은 더 없으면 장식을 뺀다.
local LOOT_NET = "PongDuMutantLoot"

local function hasTagged(container, lootType, cosmetic)
    local items = container:getItems()
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if it and it:getFullType() == lootType and it:getModData()[LOOT_TAG] == cosmetic then return true end
    end
    return false
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= LOOT_NET or command ~= "LootTaken" then return end
    local who = player and player:getUsername() or "?"
    local x = tonumber(args and args["x"])
    local y = tonumber(args and args["y"])
    local zz = tonumber(args and args["z"])
    local lootType = args and args["type"]
    if not x or not y or not zz or type(lootType) ~= "string" then
        print(LOG .. "LootTaken ignored: bad args from=" .. who)
        return
    end
    if player and (math.abs(player:getX() - x) > 4 or math.abs(player:getY() - y) > 4) then
        print(LOG .. "LootTaken ignored: reporter too far from=" .. who)
        return
    end
    local cell = getCell()
    local sq = cell and cell:getGridSquare(x, y, zz)
    if not sq then
        print(LOG .. "LootTaken ignored: no square " .. x .. "," .. y .. "," .. zz .. " from=" .. who)
        return
    end
    local bodies = sq:getDeadBodys()
    local n, removed = 0, 0
    for i = 0, bodies:size() - 1 do
        local b = bodies:get(i)
        local c = b and b:getContainer()
        if c then
            n = n + 1
            for _, list in pairs(COSMETIC_LOOT) do
                for k = 1, #list do
                    local e = list[k]
                    if e.loot == lootType and c:containsType(e.cosmetic) and not hasTagged(c, e.loot, e.cosmetic) then
                        if removeCosmetic(c, e.cosmetic) then removed = removed + 1 end
                    end
                end
            end
        end
    end
    print(LOG .. "LootTaken item=" .. lootType .. " at " .. x .. "," .. y .. "," .. zz .. " bodies=" .. n
        .. " cosmeticRemoved=" .. removed .. " by=" .. who)
end)
