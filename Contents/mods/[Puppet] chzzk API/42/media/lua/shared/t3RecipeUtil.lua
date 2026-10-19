-- t3RecipeUtil: craftRecipe OnCreate 공용 헬퍼 (B42).
--
-- [B42 OnCreate 규약]
--   시그니처: OnCreate(craftRecipeData, character)
--     (CraftRecipeData.luaCallOnCreate:464 -> protectedCallVoid(fn, this, character))
--   실행 위치: ISHandcraftAction.performRecipe() 는 "not isClient()" 에서만 돈다.
--     싱글 = 로컬 프로세스, MP = 서버 (ISHandcraftAction:complete -> performRecipe).
--     B41 recipe OnCreate 는 MP 에서 "클라이언트" 에서 돌았으므로 정반대다.
--   그래서 OnCreate 안에서:
--     - 인벤토리에 넣은 아이템은 sendAddItemToContainer 로 소유 클라에 동기화해야 한다
--       (LuaManager:10342 - GameServer.server 일 때만 동작, 싱글에선 no-op)
--     - 대사(Say)/맵 마커 같은 화면 연출은 서버에서 직접 하면 안 되고 클라로 넘겨야 한다
--       (IsoGameCharacter.ProcessSay 는 ChatManager.showInfoMessage 를 부르는 클라 전용 경로)
--
-- 이 파일은 shared 라 모든 realm 에서 로드된다. OnServerCommand 핸들러는 클라에서만 발화한다.

t3RecipeUtil = t3RecipeUtil or {}

local LOG = "[PongDu][RecipeUtil] "
local NET_MODULE = "PongDuRecipe"

-- 소모된 입력 아이템의 modData 에 심어둔 후원자 이름을 찾는다.
-- getAllConsumedItems 는 mode:keep 이 아닌 입력 아이템 목록 (CraftRecipeData:1787).
-- OnCreate 는 processDestroyAndUsedItems 보다 먼저 호출되므로 아이템 객체가 아직 살아 있다.
function t3RecipeUtil.findDonor(craftRecipeData)
    if not craftRecipeData then return "" end
    local items = craftRecipeData:getAllConsumedItems()
    if not items then return "" end
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if it and it.getModData then
            local donor = it:getModData().t3Donor
            if donor and donor ~= "" then return donor end
        end
    end
    return ""
end

-- 인벤토리에 아이템을 넣고 소유 클라이언트에 동기화한다.
-- donor 가 있으면 이름 앞에 붙인다 (동기화 패킷보다 먼저 setName 해야 이름이 같이 간다).
-- 실패 시 nil.
function t3RecipeUtil.addItem(player, fullType, donor)
    local inv = player:getInventory()
    local item = inv:AddItem(fullType)
    if not item then
        print(LOG .. "AddItem failed: " .. tostring(fullType))
        return nil
    end
    if donor and donor ~= "" then
        item:setName(donor .. "'s " .. item:getDisplayName())
    end
    sendAddItemToContainer(inv, item)
    return item
end

-- 낱개 여러 개 (탄약 등). AddItems 가 돌려준 리스트를 한 번에 동기화한다.
function t3RecipeUtil.addItems(player, fullType, count)
    local inv = player:getInventory()
    local list = inv:AddItems(fullType, count)
    if list and list:size() > 0 then
        sendAddItemsToContainer(inv, list)
        return list:size()
    end
    print(LOG .. "AddItems failed: " .. tostring(fullType) .. " x" .. tostring(count))
    return 0
end

-- ── 화면 연출을 클라이언트로 ─────────────────────────────────────────────
-- kind:
--   "item" { fullType, donor }   -> "<donor>'s <아이템명>!" (아이템명은 클라 언어로 번역)
--   "text" { key, a1, a2 }       -> getText(key, a1, a2)
local function render(kind, args)
    if kind == "item" then
        local name = getItemNameFromFullType(args.fullType)
        if args.donor and args.donor ~= "" then
            name = args.donor .. "'s " .. name
        end
        return name .. "!"
    elseif kind == "text" then
        if args.a2 ~= nil then return getText(args.key, args.a1, args.a2) end
        if args.a1 ~= nil then return getText(args.key, args.a1) end
        return getText(args.key)
    end
    return nil
end

-- 싱글이면 바로 Say, 서버면 해당 플레이어 클라에 명령을 보낸다.
function t3RecipeUtil.say(player, kind, args)
    if not player then return end
    if isServer() then
        sendServerCommand(player, NET_MODULE, "Say", { kind = kind, args = args })
        return
    end
    local text = render(kind, args)
    if text then player:Say(text) end
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= NET_MODULE then return end
    if command ~= "Say" then return end
    local player = getPlayer()
    if not player or not args then return end
    local text = render(args.kind, args.args or {})
    if text then
        player:Say(text)
    else
        print(LOG .. "Say: unknown kind " .. tostring(args.kind))
    end
end)
