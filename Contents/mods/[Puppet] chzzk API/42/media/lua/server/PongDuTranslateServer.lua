-- PongDuTranslateServer: 전용 서버에서 모드 번역을 다시 읽는다.
--
-- [B42 엔진 동작 - 소스 확인 42.21]
-- 전용 서버는 Translator.loadFiles() 를 GameServer 초기화에서 단 한 번 부르는데
-- (GameServer.java:604) 이때는 아직 모드가 로드되기 전이다(loadMods 는 :1419).
-- loadFiles 는 ZomboidFileSystem.getModIDs() 에 있는 모드의 Translate 만 읽으므로
-- 서버에는 모드 번역이 하나도 없다. 그 뒤 ScriptManager.Load(:1450) 가 아이템
-- DisplayName 을 Translator.getItemNameFromFullType 으로 정하면서 스크립트의
-- 영어 DisplayName 으로 굳는다(Item.java:3536).
-- 결과:
--   * 서버에서 만들고 setName 한 아이템("<후원자>'s <이름>")이 영어로 박힌다.
--     setName 한 이름은 그대로 클라로 전송된다(InventoryItem.save: name != originalName).
--   * 서버 getText("IGUI_donation_...") 가 번역 대신 키 문자열을 돌려준다.
-- 바닐라 아이템은 바닐라 번역이 먼저 로드돼 있어 서버 언어로 정상 표시된다.
--
-- 대응: 모드 로드가 끝난 뒤 발화하는 OnGameBoot(GameServer.java:1499) 에서
-- Translator.loadFiles() 를 다시 부르고, 이 모드 모듈 아이템의 스크립트
-- DisplayName 을 번역값으로 갱신한다. 이름 언어는 서버 Translator 언어다
-- (Core 옵션 언어 -> 없으면 JVM user.language). 바닐라 차 열쇠 이름과 같은 규칙.
--
-- SP·MP 클라는 모드 로드 후 번역을 다시 읽으므로 해당 없음 -> 전용 서버만.

if not isServer() then return end

local LOG = "[PongDu][Translate] "
local MODULE = "t3chzzkDonation"
local PROBE = MODULE .. ".medical_box"

local function refreshItemNames()
    local items = getScriptManager():getAllItems()
    local updated, total = 0, 0
    for i = 0, items:size() - 1 do
        local scriptItem = items:get(i)
        if scriptItem and scriptItem:getModuleName() == MODULE then
            total = total + 1
            local name = getItemNameFromFullType(scriptItem:getFullName())
            if name and name ~= scriptItem:getDisplayName() then
                scriptItem:setDisplayName(name)
                updated = updated + 1
            end
        end
    end
    return updated, total
end

Events.OnGameBoot.Add(function()
    local before = getItemNameFromFullType(PROBE)
    local ok, err = pcall(function() Translator.loadFiles() end)
    if not ok then
        print(LOG .. "ERROR Translator.loadFiles failed: " .. tostring(err))
        return
    end
    local updated, total = refreshItemNames()
    local lang = Translator.getLanguage()
    print(LOG .. "server translations reloaded with mods: language="
        .. tostring(lang and lang:name())
        .. " itemsUpdated=" .. tostring(updated) .. "/" .. tostring(total)
        .. " probeKeyFound=" .. tostring(getTextOrNull("IGUI_donation_zombie_owner") ~= nil)
        .. " probeChanged=" .. tostring(before ~= getItemNameFromFullType(PROBE)))
end)
