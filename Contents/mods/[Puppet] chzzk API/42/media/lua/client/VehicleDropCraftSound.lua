-- 차량 드랍 키트(craftRecipe PongDuOpenVehicleDropKit) 개봉 진행 중 연출 3가지를 처리한다.
-- 전부 같은 레시피를 대상으로 같은 ISHandcraftAction을 후킹하므로 파일 하나로 묶음.
--
-- [B42] B41 recipe 는 ISCraftAction 으로 돌았지만 B42 craftRecipe 는 ISHandcraftAction
-- (shared/Entity/TimedActions/ISHandcraftAction.lua) 으로 돈다. ISCraftAction 은 B42에도
-- 남아 있지만 구 recipe 전용이라 후킹해도 우리 레시피엔 안 걸린다.
-- 사운드 핸들 필드도 craftSound -> sound 로 바뀌었다 (start():143, stop():160).
-- RadioTalk 는 레시피 Sound 필드가 아니라 timedAction 스크립트의 sound 로 재생된다
-- (t3chzzkDonation.PongDuRadioCall, soundTime 기본값 ACTION_START = start()에서 재생).
--
--   1) start():  개봉 시작 시 레시피 Sound(RadioTalk) 볼륨을 절반으로 낮춤
--   2) update(): 진행 중 머리 위 대사를 "차량보급 호출 중." -> ".." -> "..." 순으로 반복 표시,
--                진행률(jobDelta)이 50%를 넘는 순간 vehicle_call_signal 사운드를 1회 재생
--   3) stop(): 액션이 "취소"된 경우에만 재생 중이던 vehicle_call_signal을 즉시 정지.
--              정상 완료(perform) 시에는 정지하지 않고 소리가 끝까지 재생되도록 둔다.
--              (바닐라 self.sound(RadioTalk) 정리는 바닐라가 알아서 함 — 유지)
--
-- [사운드 볼륨] timedAction sound 는 ISHandcraftAction:start()에서
-- self.sound = character:playSound(...)로 재생되어 완료/취소 시 정지된다.
-- 스크립트에 볼륨 필드가 없어 조절 수단이 없으므로 시작 시점에 여기서 낮춘다.
--
-- [대사] Kahlua stdlib에는 string.rep이 없어(PZ-Library StringLib 확인, 미구현 함수는
-- "tried to call nil"로 즉시 죽음) 점 개수별 문자열을 테이블로 미리 준비해 인덱싱한다.
--
-- character:Say(text)는 ChatManager.showInfoMessage로 채팅 로그에 "새 줄"을 추가하는
-- 함수라(IsoGameCharacter.ProcessSay 디컴파일 확인), 호출할 때마다 머리 위에 이전
-- 줄들이 최근 몇 개까지 겹쳐 쌓이며 표시된다(요청한 "한 줄 교체"가 아니라 로그 누적).
-- 대신 character:setHaloNote(text, r, g, b, dispTime)를 쓴다. 이건 캐릭터가 들고
-- 있는 단일 TextDrawObject(haloNote)의 문자열을 매번 덮어쓰는 방식이라(ReadString()
-- 호출, 새 줄 추가 아님) 항상 한 줄만 표시되고 내용만 교체된다. ISSearchManager.lua의
-- 채집 결과 표시(searchManager:setHaloNote)와 동일한 표준 패턴.
-- dispTime 단위는 초가 아니라 내부 틱 카운트(바닐라 기본값 haloDispTime=128)라
-- DOT_INTERVAL_TICKS(40)보다 충분히 큰 값을 매 갱신마다 다시 넣어줘야 끊기지 않는다.
--
-- [호출 사운드 취소 처리] 취소 경로(stop)에서만 끊는다. 바닐라 ISHandcraftAction은
-- self.sound를 stop에서 끊지만, 우리 사운드는 "완료 시 끝까지 재생"이
-- 요구사항이므로 perform은 후킹하지 않는다.
-- character:stopOrTriggerSound(handle)은 IsoGameCharacter가 getEmitter()로 위임하는
-- 표준 정지 API (바닐라 self.sound 정지와 동일 메서드).
--
-- [재생 시점] 고정 틱(예: 250) 대신 진행률 self:getJobDelta() >= 0.5 를 쓴다.
-- jobDelta는 ISBaseTimedAction:getJobDelta() -> self.action:getJobDelta()로
-- 0.0~1.0 진행률을 돌려주므로, 레시피 Time 값이 나중에 바뀌어도
-- "절반 지점"이라는 의미가 그대로 유지된다.

-- [레시피 판별] B42 CraftRecipe:getName()은 스크립트 ID 그대로다. 번역명은 별도 필드
-- (translationName, getTranslationName())라 로케일과 무관하게 비교할 수 있다
-- (CraftRecipe.java:362~363). B41 Recipe:getName()이 번역명을 돌려줘 getOriginalname()을
-- 쓰던 우회는 더 이상 필요 없다.
local TARGET_RECIPE_NAME = "PongDuOpenVehicleDropKit"

local function isTargetRecipe(craftRecipe)
    return craftRecipe ~= nil and craftRecipe:getName() == TARGET_RECIPE_NAME
end
local TARGET_VOLUME = 0.5
local DOT_INTERVAL_TICKS = 40 -- 점 개수가 바뀌는 간격(틱). Time 값이 바뀌면 체감 순환 속도도 바뀜.
local DOT_PATTERNS = { ".", "..", "..." }
local DOT_HALO_COLOR = { 255, 255, 255 } -- r, g, b

-- [대사 글꼴] setHaloNote 는 글꼴이 UIFont.Small 로 고정이고(IsoGameCharacter haloNote
-- 생성부) 태그로도 못 바꾼다(TextDrawObject.allowFonts 기본 false). 화면에서 너무 작아서
-- 특수좀비 이름표(features/mutantspawn.lua renderTags)와 같은 방식으로 직접 그린다:
-- 우리 TextDrawObject 하나를 UIFont.Medium 으로 매 틱 배치드로우. 객체가 하나라 항상 한 줄만 보인다.
local CALL_TEXT_FONT = UIFont.Medium
local CALL_TEXT_TTL = 5          -- update() 가 멈춘 뒤 이 틱 수만큼 남았다가 사라진다
local CALL_TEXT_HEAD_OFFSET = 150 -- 발 기준 화면 위쪽 오프셋(px, 줌 1 기준)
local _callText, _callChar, _callTtl, _callTdo = nil, nil, 0, nil

local function renderCallText()
    if _callTtl <= 0 or not _callChar or not _callText then return end
    _callTtl = _callTtl - 1
    local c = _callChar
    local sx = IsoUtils.XToScreen(c:getX(), c:getY(), c:getZ(), 0) - IsoCamera.getOffX() - c:getOffsetX()
    local sy = IsoUtils.YToScreen(c:getX(), c:getY(), c:getZ(), 0) - IsoCamera.getOffY() - c:getOffsetY()
        - CALL_TEXT_HEAD_OFFSET
    local zoom = getCore():getZoom(0)
    sx, sy = sx / zoom, sy / zoom
    _callTdo = _callTdo or TextDrawObject.new()
    _callTdo:setDefaultColors(DOT_HALO_COLOR[1] / 255, DOT_HALO_COLOR[2] / 255, DOT_HALO_COLOR[3] / 255, 1)
    _callTdo:setOutlineColors(0, 0, 0, 1)
    _callTdo:ReadString(CALL_TEXT_FONT, _callText, -1)
    _callTdo:AddBatchedDraw(sx, sy - _callTdo:getHeight(), true)
end
Events.OnTick.Add(renderCallText)

local CALL_SOUND_NAME = "vehicle_call_signal" -- t3_rewards_sounds.txt 등록명
local CALL_SOUND_PROGRESS = 0.5 -- 진행률이 이 값을 넘는 순간 1회 재생
local CALL_SOUND_VOLUME = 0.5 -- 재생 볼륨 절반

local original_start = ISHandcraftAction.start
function ISHandcraftAction:start()
    original_start(self)

    if isTargetRecipe(self.craftRecipe) and self.sound then
        local emitter = self.character:getEmitter()
        if emitter then
            emitter:setVolume(self.sound, TARGET_VOLUME)
            print("[VehicleDropCraftSound] RadioTalk volume lowered to " .. TARGET_VOLUME)
        else
            print("[VehicleDropCraftSound] Failed to get emitter, skipping volume adjustment")
        end
    end
end

local original_update = ISHandcraftAction.update
function ISHandcraftAction:update()
    original_update(self)

    if isTargetRecipe(self.craftRecipe) then
        self.t3CallTick = (self.t3CallTick or 0) + 1

        -- 점 개수 순환 대사 (3,1,2,3,1,2...)
        local dotIndex = (math.floor(self.t3CallTick / DOT_INTERVAL_TICKS) + 2) % 3 + 1
        if dotIndex ~= self.t3LastDotIndex then
            self.t3LastDotIndex = dotIndex
            _callText = getText("IGUI_donation_vehicle_drop_calling") .. DOT_PATTERNS[dotIndex]
        end
        -- update()가 매 틱 도는 동안 TTL을 채워 두고, 액션이 끝나면 몇 틱 뒤 자연히 사라진다
        _callChar = self.character
        _callTtl = CALL_TEXT_TTL

        -- 진행률 50% 도달 시 호출 사운드 1회 재생
        if not self.t3CallSoundPlayed and self:getJobDelta() >= CALL_SOUND_PROGRESS then
            self.t3CallSoundPlayed = true
            local emitter = self.character:getEmitter()
            if emitter then
                self.t3CallSoundHandle = emitter:playSound(CALL_SOUND_NAME)
                if self.t3CallSoundHandle and self.t3CallSoundHandle ~= 0 then
                    emitter:setVolume(self.t3CallSoundHandle, CALL_SOUND_VOLUME)
                end
                -- handle이 0/nil이면 GameSounds.getSound()가 null -> 사운드 미등록/빌드 미반영 신호
                print("[VehicleDropCraftSound] " .. CALL_SOUND_NAME .. " playback attempt (jobDelta "
                    .. tostring(self:getJobDelta()) .. ", handle=" .. tostring(self.t3CallSoundHandle) .. ")")
                if not self.t3CallSoundHandle or self.t3CallSoundHandle == 0 then
                    print("[VehicleDropCraftSound] Warning: handle is 0/nil -> sound registration likely failed")
                end
            end
        end
    end
end

-- 재생 중인 호출 사운드를 즉시 정지 (취소 경로 전용)
local function stopCallSound(self)
    if self.t3CallSoundHandle and self.character:getEmitter():isPlaying(self.t3CallSoundHandle) then
        self.character:stopOrTriggerSound(self.t3CallSoundHandle)
        print("[VehicleDropCraftSound] " .. CALL_SOUND_NAME .. " stopped mid-play")
    end
end

local original_stop = ISHandcraftAction.stop
function ISHandcraftAction:stop()
    if isTargetRecipe(self.craftRecipe) then
        stopCallSound(self)
    end
    original_stop(self)
end

-- perform(정상 완료)은 후킹하지 않는다: 완료 시 vehicle_call_signal은 끝까지 재생.
