-- ═══════════════════════════════════════════════════════════════════════════
--  PongDu Viewpoint 호환 -- 모델팩 시험 (임시 스파이크, 본구현 시 교체)
--
--  확인할 것:
--   1) 런타임 스프라이트(IsoSpriteManager:AddSprite + setName)에 Viewpoint 모델팩 bind 가
--      이름으로 걸리는가 (타일 시트(.tiles/.pack) 없이)
--   2) 모델팩 OBJ 텍스처의 알파(반투명)가 Viewpoint 에서 먹는가
--   3) OBJ 좌표축: 붉은 기둥(pongdu_vp_probe, +z 로 2.0)이 서 있으면 z 가 위
--
--  사용: 아이소 시점에서 땅을 우클릭 -> "[PongDu VP test]" 메뉴
--        -> 기둥 1개 / 가스 퍼프 S·M·L 3개를 그 칸 근처에 놓는다 (이 클라에만 존재, 서버 전송 없음)
--        -> Viewpoint 1인칭(O)으로 바라본다. 같은 메뉴의 Clear 로 전부 치운다.
--  2D 스프라이트는 완전 투명이라 아이소에서는 아무것도 안 보이는 것이 정상이다.
--  Viewpoint 가 없으면 등록만 실패 로그를 남기고 아무것도 하지 않는다.
-- ═══════════════════════════════════════════════════════════════════════════

local MOD_ID   = "t3chzzkDonationB42_ViewpointComp"
local MANIFEST = "media/modelpacks/pongdu_vp/pack.properties"

-- 스프라이트 이름 -> 투명 2D 텍스처 (AddSprite 는 텍스처 경로를 키로 쓰므로 이름마다 파일을 따로 둔다)
local SPRITES = {
    pongdu_vp_probe = "media/textures/PongDuVP/blank_probe.png",
    pongdu_vp_gas_s = "media/textures/PongDuVP/blank_gas_s.png",
    pongdu_vp_gas_m = "media/textures/PongDuVP/blank_gas_m.png",
    pongdu_vp_gas_l = "media/textures/PongDuVP/blank_gas_l.png",
}

local _registered = false
local _lastFail = nil
local _sprites = {}
local _placed = {}   -- { obj = IsoObject, sq = IsoGridSquare }

local function register(report)
    if _registered then return true end
    local api = Viewpoint and Viewpoint.ModelPacks
    if not api or not api.register then
        if report and _lastFail ~= "api" then
            _lastFail = "api"
            print("[PongDuVP] Viewpoint.ModelPacks not found (Viewpoint/ZombieBuddy off): 3D effects disabled")
        end
        return false
    end
    local ok, res = pcall(function() return api.register(MOD_ID, MANIFEST) end)
    if not ok or not res then
        if report and _lastFail ~= "reg" then
            _lastFail = "reg"
            print("[PongDuVP] Viewpoint.ModelPacks.register failed: " .. tostring(res))
        end
        return false
    end
    _registered = true
    print("[PongDuVP] model pack registered (" .. MANIFEST .. ") result=" .. tostring(res))
    return true
end

local function sprite(name)
    if _sprites[name] then return _sprites[name] end
    local tex = SPRITES[name]
    if not tex then return nil end
    local ok, spr = pcall(function()
        local s = IsoSpriteManager.instance:AddSprite(tex)
        s:setName(name)
        return s
    end)
    if not ok or not spr then
        print("[PongDuVP] sprite create FAILED name=" .. name .. " err=" .. tostring(spr))
        return nil
    end
    _sprites[name] = spr
    print("[PongDuVP] sprite created name=" .. tostring(spr:getName()) .. " tex=" .. tex)
    return spr
end

local function place(sq, name)
    local spr = sprite(name)
    if not sq or not spr then return false end
    local ok, err = pcall(function()
        local obj = IsoObject.new(getCell(), sq, spr)
        sq:AddTileObject(obj)
        _placed[#_placed + 1] = { obj = obj, sq = sq }
    end)
    print(string.format("[PongDuVP] place %s at %d,%d,%d ok=%s%s", name, sq:getX(), sq:getY(), sq:getZ(),
        tostring(ok), ok and "" or (" err=" .. tostring(err))))
    return ok
end

local function clearAll()
    local n = 0
    for i = #_placed, 1, -1 do
        local p = _placed[i]
        pcall(function() p.sq:RemoveTileObject(p.obj) end)
        n = n + 1
        _placed[i] = nil
    end
    print("[PongDuVP] cleared " .. n .. " test object(s)")
end

local function placeSet(sq)
    if not register(true) then return end
    local cell = getCell()
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    place(sq, "pongdu_vp_probe")
    place(cell:getGridSquare(x + 3, y, z), "pongdu_vp_gas_s")
    place(cell:getGridSquare(x + 6, y, z), "pongdu_vp_gas_m")
    place(cell:getGridSquare(x + 10, y, z), "pongdu_vp_gas_l")
    local vpMode = "none"
    if Viewpoint and Viewpoint.View and Viewpoint.View.next then
        local okN, nxt = pcall(Viewpoint.View.next)
        vpMode = okN and tostring(nxt) or "error"
    end
    print("[PongDuVP] test set placed near " .. x .. "," .. y .. "," .. z .. " (viewpoint next=" .. vpMode .. ")")
end

Events.OnFillWorldObjectContextMenu.Add(function(playerNum, context, worldobjects, test)
    if test then return end
    local sq = ISWorldObjectContextMenu.fetchVars and ISWorldObjectContextMenu.fetchVars.clickedSquare
    if not sq then return end
    local sub = ISContextMenu:getNew(context)
    sub:addOption("Place probe + gas puffs here", sq, placeSet)
    sub:addOption("Clear test objects (" .. #_placed .. ")", nil, clearAll)
    local opt = context:addOption("[PongDu VP test]", nil, nil)
    context:addSubMenu(opt, sub)
end)

register(false)
Events.OnGameBoot.Add(function() register(false) end)
Events.OnGameStart.Add(function() register(true) end)
