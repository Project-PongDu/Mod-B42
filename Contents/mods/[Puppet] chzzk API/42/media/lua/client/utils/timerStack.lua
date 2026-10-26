require("ISUI/ISPanel")

-- 봄바드/화력지원(헬기·드론)/좀비레인 등 화면 하단-중앙에 뜨는 카운트다운
-- 패널들을, 도네 큐박스 호버 툴팁과 겹치지 않게 쌓아주는 공용 매니저.
--
-- 규칙:
--   1) 바닥선 = 큐박스 툴팁 상단에서 3px 위. 큐박스가 비어있으면(패널 없음)
--      화면 하단 기준 폴백값 사용.
--   2) 먼저 register()된 패널일수록 바닥선에 가깝게(맨 아래) 깔린다.
--   3) 중간 패널이 끝나서 unregister()되면, 그 위에 있던 패널들이 순서를
--      당겨받아 한 칸씩 내려온다(빈 자리 없이 재정렬).
--   4) 같은 group 으로 register()된 패널들은 한 줄에 가로로 나란히 놓인다
--      (화력지원 저격·헬기·드론처럼 동시에 여럿 뜰 수 있는 것). 줄 위치는 그 그룹의
--      첫 패널이 들어온 순서를 따르고, 줄 안에서는 등록 순서대로 왼쪽부터 놓은 뒤
--      줄 전체를 화면 가운데에 맞춘다. 그룹 패널 폭은 GROUP_W 로 줄인다.
local _a = {}

local ROW_GAP      = 6    -- 슬롯 간 여백. 슬롯 높이는 패널마다 getHeight()로 잰다
                           -- (timerText 카운터는 2줄이라 randomteleport 1줄 패널보다 높다).
local TOOLTIP_GAP  = 3    -- 큐박스 툴팁과의 최소 간격
local COL_GAP      = 24   -- 같은 줄(그룹) 안 패널 사이 가로 여백
local GROUP_W      = 240  -- 그룹 패널 폭. 기능명(Large)·"남은시간 MM:SS"(Medium)가 들어가는 폭
local FALLBACK_PAD = 210  -- DonationReceiver 미로드 등 극단적 상황에서만 쓰이는 안전망.
                           -- 큐박스 기본 앵커(핫바 바로 위) 위치를 대략 근사한 값.

local stack = {}   -- 순서대로: stack[1] = 가장 먼저 register()된 패널(=최하단)
                   -- 항목: { panel = ISPanel, group = 문자열|nil }

local function baseY()
    local ok, receiver = pcall(require, "DonationReceiver")
    local top = ok and receiver and receiver.getTooltipTopY and receiver.getTooltipTopY()
    if top then
        return top - TOOLTIP_GAP
    end
    -- 큐박스가 비어있거나 아직 로드되지 않음 -> 화면 하단 기준 폴백.
    return getCore():getScreenHeight() - FALLBACK_PAD
end

-- stack 을 줄 단위로 묶는다. 그룹 없는 패널은 혼자 한 줄, 그룹 패널은 그 그룹의
-- 첫 패널 자리에 한 줄로 모인다.
local function buildRows()
    local rows, rowOf = {}, {}
    for _, entry in ipairs(stack) do
        local g = entry.group
        if g and rowOf[g] then
            local row = rowOf[g]
            row[#row + 1] = entry.panel
        else
            local row = { entry.panel }
            row.group = g
            rows[#rows + 1] = row
            if g then rowOf[g] = row end
        end
    end
    return rows
end

local function relayout()
    local y  = baseY()
    local sw = getCore():getScreenWidth()
    for _, row in ipairs(buildRows()) do
        local h = 0
        for i = 1, #row do
            local ph = row[i]:getHeight()
            if ph > h then h = ph end
        end
        y = y - h - ROW_GAP
        if not row.group then
            row[1]:setY(y)
        else
            local total = 0
            for i = 1, #row do total = total + row[i]:getWidth() end
            total = total + COL_GAP * (#row - 1)
            local x = (sw - total) / 2
            for i = 1, #row do
                row[i]:setX(x)
                row[i]:setY(y)
                x = x + row[i]:getWidth() + COL_GAP
            end
        end
    end
end

-- panel: ISPanel 인스턴스. 호출 순서대로 최하단부터 쌓인다.
-- group: 생략하면 한 줄을 혼자 쓴다. 주면 같은 group 패널끼리 한 줄에 가로로 놓인다.
function _a.register(panel, group)
    if group then
        -- 폰트 크기 옵션이 크면 "남은시간 MM:SS" 가 GROUP_W 를 넘어 옆 패널과 겹치므로 실측해서 넓힌다
        local w = GROUP_W
        local tw = getTextManager():MeasureStringX(UIFont.Medium,
            getText("IGUI_donation_timer_remain") .. " 00:00") + 40
        if tw > w then w = tw end
        panel:setWidth(w)
    end
    table.insert(stack, { panel = panel, group = group })
    relayout()
end

-- 타이머가 끝나 패널을 없앨 때 removeFromUIManager() 전에 반드시 호출할 것.
-- (그래야 위에 쌓여있던 패널들이 빈 자리를 채우며 내려온다)
function _a.unregister(panel)
    for i = #stack, 1, -1 do
        if stack[i].panel == panel then
            table.remove(stack, i)
            break
        end
    end
    relayout()
end

Events.OnResolutionChange.Add(relayout)

return _a
