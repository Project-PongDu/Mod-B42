-- PongDuGrant: 후원 아이템 지급 공용 경로 (B42).
--
-- [왜 서버에서 넣는가]
--   B42 MP 에서 아이템은 서버 권위다. 클라가 자기 인벤에 AddItem 한 아이템은 인벤에 보이기만
--   하고 사용·버리기가 안 된다(2026-10-26 멀티 실측). ItemTransactionPacket.processServer 가
--   서버에 없는 아이템이라 isConsistent 에서 Reject 하기 때문이다.
--   그래서 실제 지급은 여기 한 곳에서 하고
--     - SP  : 클라 기능 파일이 직접 호출 (서버 왕복 없음)
--     - MP  : 클라가 sendClientCommand("PongDuGrant", ...) 로 요청 -> server/PongDuGrantServer.lua 가 호출
--   한다. 서버는 AddItem 뒤 sendAddItemToContainer 로 소유 클라에 내려보낸다
--   (LuaManager.sendAddItemToContainer: GameServer.server 일 때만 동작, SP 에선 no-op).
--
-- [이름·modData] AddInventoryItemToContainer 패킷은 CompressIdenticalItems.save -> InventoryItem.save
--   로 아이템을 통째로 직렬화한다. name(originalName 과 다를 때)과 modData 가 같이 가므로
--   setName / modData 는 반드시 sendAddItemToContainer "전에" 한다.
--   표시명 번역은 서버 Translator 언어를 따른다(Core 옵션 언어 -> 없으면 OS user.language).
--   바닐라 차 열쇠 이름(BaseVehicle.keyNamerVehicle)도 서버에서 같은 방식으로 붙는다.
--
-- [피드백] 보급음은 클라 로컬 사운드라 서버가 못 튼다. MP 는 서버가 받은 사람에게 "Delivered" 를
--   돌려보내고, 이 파일의 OnServerCommand 핸들러(클라에서만 발화)가 소리를 낸다.
--
-- 이 파일은 shared 라 모든 realm 에서 로드된다.

PongDuGrant = PongDuGrant or {}

PongDuGrant.NET_MODULE = "PongDuGrant"

local LOG    = "[PongDu][Grant] "
local MODULE = "t3chzzkDonation."

-- FoodSupply_Item 이 잘못 입력됐을 때만 쓰는 대체 아이템 (nil fallback 아님).
local INVALID_FOOD_TYPE = "Base.Crisps"

-- 클라 요청으로 지급할 수 있는 보급 아이템 (t3chzzkDonation 모듈 안의 type).
-- 서버는 클라가 보낸 itemId 를 그대로 믿지 않는다. 여기 없는 id 는 거부한다.
-- 혈청은 등급x스킬 조합이라 패턴으로 받는다(features/skillpotion.lua serum.roll 반환값).
local SUPPLY_IDS = {
    ["Zomboxivir"]        = true,   -- 백신
    ["weapon_box_melee"]  = true,   -- 랜덤무기 (근접 상자)
    ["weapon_box_ranged"] = true,   -- 랜덤무기 (원거리 상자)
    ["vehicle_drop_kit"]  = true,   -- 차량 보급 키트
    ["inv_save_ticket"]   = true,   -- 인벤세이브권
    ["medical_box"]       = true,   -- 의약품 보급상자 (서버 후원, 서버가 전원에게 직접 지급)
}

function PongDuGrant.isSupplyId(itemId)
    if type(itemId) ~= "string" then return false end
    if SUPPLY_IDS[itemId] then return true end
    return string.match(itemId, "^serum_%a+_%a+$") ~= nil
end

-- give(player, fullType, opts) -> InventoryItem | nil   [서버 / SP]
--   opts.prefix : 있으면 이름을 prefix .. <기본 표시명> 으로 바꾼다
--   opts.name   : 있으면 이름을 그대로 바꾼다 (prefix 보다 우선)
--   opts.donor  : modData.t3Donor 에 기록 (nil 이면 기록 안 함)
function PongDuGrant.give(player, fullType, opts)
    if not player then
        print(LOG .. "give aborted: player is nil (item=" .. tostring(fullType) .. ")")
        return nil
    end
    local inv = player:getInventory()
    local item = inv:AddItem(fullType)
    if not item then
        print(LOG .. "give FAILED: AddItem returned nil (item=" .. tostring(fullType)
            .. ", user=" .. tostring(player:getUsername()) .. ")")
        return nil
    end
    if opts then
        if opts.name then
            item:setName(opts.name)
        elseif opts.prefix then
            item:setName(opts.prefix .. item:getDisplayName())
        end
        if opts.donor ~= nil then item:getModData().t3Donor = opts.donor end
    end
    sendAddItemToContainer(inv, item)
    return item
end

-- supply(player, itemId, sender) -> InventoryItem | nil   [서버 / SP]
-- 보급 계열 공통: 지급 -> 후원자 각인("<후원자>'s <아이템명>"). B41 giveSupply 와 같은 이름 규칙.
function PongDuGrant.supply(player, itemId, sender)
    if not PongDuGrant.isSupplyId(itemId) then
        print(LOG .. "supply REJECTED: itemId not allowed (item=" .. tostring(itemId) .. ")")
        return nil
    end
    local fullType = MODULE .. itemId
    if not getScriptManager():FindItem(fullType) then
        print(LOG .. "supply FAILED: no item script (item=" .. fullType .. ")")
        return nil
    end
    local donor = sender or ""
    local item = PongDuGrant.give(player, fullType, { prefix = donor .. "'s ", donor = donor })
    if item then
        print(LOG .. "supply delivered item=" .. itemId .. " sender=" .. donor
            .. " user=" .. tostring(player:getUsername()) .. " itemID=" .. tostring(item:getID()))
    end
    return item
end

-- FoodSupply_Item 문자열을 실제 아이템 full type("Module.Type")으로 해석한다.
-- 서버 운영자가 직접 입력하는 문자열이라 오타·애드온 미적용이 생길 수 있다. 이건 "값이 nil" 이
-- 아니라 "값이 틀림" 문제라 sandbox default 가 막지 못한다. 못 찾으면 후원이 증발하지 않도록
-- 바닐라 감자칩으로 대체하고 WARN 을 남긴다. 모듈을 생략하면 FindItem 이 Base 로 본다.
local function resolveFoodType()
    local raw     = SandboxVars.PongDu.FoodSupply_Item
    local trimmed = raw:match("^%s*(.-)%s*$")
    if trimmed == "" then
        print(LOG .. "WARN FoodSupply_Item is empty -- using " .. INVALID_FOOD_TYPE)
        return INVALID_FOOD_TYPE
    end
    local script = getScriptManager():FindItem(trimmed)
    if not script then
        print(LOG .. "WARN FoodSupply_Item '" .. trimmed
            .. "' has no item script (typo or addon mod not loaded) -- using " .. INVALID_FOOD_TYPE)
        return INVALID_FOOD_TYPE
    end
    local fullType = script:getFullName()
    if fullType ~= trimmed then
        print(LOG .. "FoodSupply_Item '" .. trimmed .. "' resolved to " .. fullType)
    end
    return fullType
end

-- food(player, sender) -> delivered, itemType   [서버 / SP]
-- 아이템·개수는 요청 쪽이 아니라 이 realm 의 샌드박스에서 읽는다(MP 면 서버 값).
-- 표시명은 번역키 IGUI_donation_food_supply_item 이 있을 때만 덮어쓴다. 키가 없거나 값이
-- 공백뿐이면 setName 을 부르지 않는다(부르면 "<후원자>'s " 처럼 이름 없는 라벨이 박힌다).
function PongDuGrant.food(player, sender)
    local count    = SandboxVars.PongDu.FoodSupply_Count
    local itemType = resolveFoodType()
    local label    = getTextOrNull("IGUI_donation_food_supply_item")
    if label and label:match("^%s*$") then label = nil end
    if not label then
        print(LOG .. "translation key IGUI_donation_food_supply_item not found -- using default item name")
    end

    local donor = sender or ""
    local opts = { donor = donor }
    if label then opts.name = donor .. "'s " .. label end

    local delivered = 0
    for i = 1, count do
        if not PongDuGrant.give(player, itemType, opts) then
            print(LOG .. "food stopped at index=" .. i .. "/" .. tostring(count))
            break
        end
        delivered = delivered + 1
    end
    print(LOG .. "food delivered " .. delivered .. "/" .. tostring(count)
        .. " (item=" .. itemType .. ", sender=" .. donor
        .. ", user=" .. tostring(player and player:getUsername()) .. ")")
    return delivered, itemType
end

-- ── 클라 쪽 ─────────────────────────────────────────────────────────────────

-- 보급음. getSoundManager():PlaySound 는 클라 로컬 사운드라 좀비 어그로가 붙지 않는다.
-- PlaySound 의 maxGain 인자는 SoundManager.java 구현상 무시되므로 반환 핸들에 setVolume 을 건다.
function PongDuGrant.playSupplySound()
    local audio = getSoundManager():PlaySound("pongdu_supply", false, 1.0)
    if audio then audio:setVolume(0.5) end
end

-- request(command, args)  [클라, MP 전용]
function PongDuGrant.request(command, args)
    local player = getPlayer()
    if not player then
        print(LOG .. "request " .. tostring(command) .. " aborted: no local player")
        return
    end
    sendClientCommand(player, PongDuGrant.NET_MODULE, command, args or {})
    print(LOG .. "requested " .. tostring(command)
        .. " item=" .. tostring(args and args["item"])
        .. " sender=" .. tostring(args and args["sender"]))
end

-- 서버 결과 수신 (OnServerCommand 는 클라에서만 발화한다).
--   Delivered { kind, item, count, sender }  : 1개 이상 들어감 -> 보급음
--   Failed    { kind, item, reason, sender } : 하나도 못 넣음  -> 소리 없음 ("소리는 났는데 아이템은
--                                               없다"가 제일 추적하기 어렵다)
Events.OnServerCommand.Add(function(module, command, args)
    if module ~= PongDuGrant.NET_MODULE then return end
    if type(args) ~= "table" then
        print(LOG .. "server result ignored: bad payload command=" .. tostring(command))
        return
    end
    if command == "Delivered" then
        print(LOG .. "server delivered kind=" .. tostring(args["kind"])
            .. " item=" .. tostring(args["item"]) .. " count=" .. tostring(args["count"])
            .. " sender=" .. tostring(args["sender"]))
        PongDuGrant.playSupplySound()
    elseif command == "Failed" then
        print(LOG .. "server FAILED kind=" .. tostring(args["kind"])
            .. " item=" .. tostring(args["item"]) .. " reason=" .. tostring(args["reason"])
            .. " sender=" .. tostring(args["sender"]))
    end
end)
