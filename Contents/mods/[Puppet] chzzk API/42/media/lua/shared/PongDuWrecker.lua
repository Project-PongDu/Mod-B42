-- PongDuWrecker: 레커(돌진 특수좀비) 공용 상수와 통신 경로 (B42).
--
-- [동작]
--   대상 플레이어가 TRIGGER_MIN~TRIGGER_MAX 칸 안이고 사이가 트여 있으면
--   예고(warn) -> 돌진(sprint) -> 회복(recovery) 순서로 진행한다.
--   돌진 중 닿은 플레이어는 넘어지고 피해를 입으며, 돌진은 멈추지 않고 계속된다(여러 명 관통).
--   돌진 중 벽·문·창문·울타리에 막히면 충돌(crash): 앞을 막은 문·창문·바리케이드를 부수고
--   휘는 울타리는 휘거나(첫 충돌) 무너뜨린다(이미 휜 것). 레커는 넘어진다.
--   레커는 물지 않는다(setNoTeeth, AttackState.java:151 의 AttackCollisionCheck 가 피해를 건너뜀).
--   붙어 있어도 돌진한다(TRIGGER_MIN 0, 원본 레커와 같음).
--
-- [원본 레커(The Mutants, PZM_Wrecker_*)와의 관계]
--   클립·예고음은 원본 것을 그대로 쓰고(anims_X/Zombie/Zombie_PZM_Wrecker_*.glb. 버전 폴더(42/)의
--   anims_X 는 common/media/anims_X 가 없으면 Zombie·Bob·Kate 같은 메시 폴더만 읽힌다(ModelManager.java:1838~1865),
--   sound/PongDuWrecker_ChargeWarn.ogg), 시간·거리·방향·파괴·취소 규칙도 원본 값을 따른다.
--   원본과 다른 점은 요청으로 바꾼 것뿐이다: 랜덤 외형(원본 남자 고정), 물지 않음,
--   피해(원본 차량충돌 공식 -> 전체 체력 20 + 부위 부상), 체력 샌드박스, 돌진 거리 10칸 상한.
--
-- [바닐라 상태와의 공존] (원본 PZM_ActionStateAdapter 와 같은 방식)
--   이동 고정은 AI 상태만 무동작 상태로 바꾸고 애니메이션 상태(ActionContext)는 그대로 둔다.
--   그래서 고정해도 되는 애니메이션 상태에서만 고정하고(HOLD_STATES), 그 밖의 상태
--   (climbfence·climbwindow·hitreaction·staggerback 등)에서는 손을 떼 바닐라가 끝내게 둔다.
--   풀 때는 애니메이션 상태 이름에 맞는 바닐라 AI 상태로 되돌린다(어긋나면 그 자리에 굳는다).
--
-- [권위 분리]
--   * 단계 결정·피해·장애물 파괴는 서버(server/PongDuWreckerServer.lua). 좀비 표식
--     modData["PuppetMutant"] 가 서버 좀비에도 있고, 서버 좀비의 target 은 소유 클라 패킷으로
--     채워진다(NetworkZombieAI.java:238~245).
--   * 좀비 이동·자세는 소유 클라(client/features/wrecker.lua). 좀비 위치는 소유 클라가 시뮬레이션해
--     서버로 올린다. 돌진 이동은 돌진 클립의 루트모션으로 한다(doDeferredMovement 는 AI 상태와
--     무관하게 적용, IsoGameCharacter.java:1602).
--   * 애니메이션 변수는 네트워크로 안 간다(ZombiePacket 에 커스텀 변수 필드 없음). 서버가 단계를
--     방송하고 모든 클라가 자기 쪽 좀비 객체에 VAR_PHASE 를 세운다. AnimSets 노드는 좀비가 어느
--     상태(소유 클라의 walktoward/attack, 비소유 클라의 *-network 등)에 있든 덮어쓰도록 상태마다 깔려 있다.
--   * 명중 판정은 피격자 클라(자기 몸을 넘어뜨리는 건 그 클라 몫), 피해는 서버(BodyPart 서버 권위).
--
-- [SP] 서버·클라 Lua 가 한 VM 이고 sendServerCommand 가 동작하지 않으므로 핸들러를 직접 부른다.
--   SP 좀비 onlineID 는 전부 -1 이라 좀비 객체를 같이 넘긴다.

PongDuWrecker = PongDuWrecker or {}
local W = PongDuWrecker

W.NET  = "PongDuWrecker"
W.KIND = "wrecker"

-- 애니메이션 단계 변수 (AnimSets/zombie/*/PongDuWrecker_*.xml 의 STRING 조건)
W.VAR_PHASE = "PongDuWreckerPhase"
-- 예고 클립 재생 위치 (0~1). 예고 노드가 m_TrackTimeToVariable 로 읽는다 (원본 ActionProgress)
W.VAR_PROGRESS = "PongDuWreckerProgress"
-- 맞은 플레이어 변수. 켜져 있으면 넘어짐 노드(AnimSets/player/bumped/PongDuSlammerFall.xml)가
-- 바닐라 밀려 넘어짐 대신 '전력질주 울타리 넘기 실패' 클립(Bob_ValultOver_SprintFail)을 튼다.
W.VAR_PLAYER_FALL = "PongDuSlammerFall"

W.PH = {
    NONE     = "none",
    WARN     = "warn",
    SPRINT   = "sprint",
    RECOVERY = "recovery",
    CRASH    = "crash",
}

-- 단계 길이 (ms). 원본 틱 값(60틱 = 1초)을 그대로 옮겼다.
W.WARN_MS        = 1500    -- 원본 90틱 (예고 클립 1.5초)
W.SPRINT_MAX_MS  = 4000    -- 원본 240틱
W.RECOVERY_MS    = 833     -- 원본 50틱 (회복 클립 0.833초)
W.CRASH_MS       = 17      -- 원본 1틱. 바로 바닐라 넉다운에 넘긴다
W.COOLDOWN_MS    = 10000   -- 원본 600틱. 돌진(sprint) 시작부터 다음 돌진 가능까지
W.CANCEL_RETRY_MS = 1000   -- 원본 60틱. 돌진이 중간에 취소되면 이만큼 뒤 다시 시도

-- 발동 거리 (칸). 물지 않으므로 붙어 있어도 돌진한다 (원본 TRIGGER_MIN_DISTANCE = 0).
W.TRIGGER_MIN = 0
W.TRIGGER_MAX = 5

-- 돌진 수치 (하드코딩)
W.CHARGE_DISTANCE = 10    -- 한 번 돌진의 최대 거리 (칸). 원본은 클립이 이 거리에 맞춰져 있고 검사는 안 한다
W.HIT_DAMAGE      = 20    -- 전체 체력(100) 기준으로 깎는 양
W.FRACTURE_CHANCE = 30    -- 부상 부위마다 골절 확률 (%), 나머지는 깊은 상처

-- 예고음 (원본 PZTheMutants_Wrecker_ChargeWarn 과 같은 파일·설정, scripts/t3_mutant_sounds.txt)
W.WARN_SOUND = "PongDuWrecker_ChargeWarn"

-- 소유 클라가 AI 이동을 멈출 때 빌리는 바닐라 상태. IsoZombie 가 이 이름을
-- GenericDefaultState(enter/execute/exit 없음)로 등록한다(IsoZombie.java:657).
W.HOLD_STATE = "attackvehicle-network"

-- 단계별로 이동 고정을 허용하는 애니메이션 상태 (이름은 normState 로 정규화한 것).
--   "hold"     : 고정한다
--   "suppress" : 돌진 중 부딪혀 bumped 에 들어가면 바로 끝내고 돌진을 잇는다
--   (없음)     : 손을 뗀다. 바닐라 상태가 끝날 때까지 기다린다. 충돌 판정도 하지 않는다.
local HOLD_COMMON = { walktoward = "hold", lunge = "hold", idle = "hold", ["face-target"] = "hold", attack = "hold" }
W.HOLD_STATES = {
    warn     = HOLD_COMMON,
    sprint   = { walktoward = "hold", lunge = "hold", idle = "hold", ["face-target"] = "hold", attack = "hold",
                 thump = "hold", bumped = "suppress" },
    recovery = { walktoward = "hold", lunge = "hold", idle = "hold", ["face-target"] = "hold", attack = "hold",
                 thump = "hold" },
}
-- 서버가 돌진(warn)을 시작해도 되는 상태
W.START_STATES = HOLD_COMMON


W.clientHandler = nil   -- function(args, zombie)                  : client/features/wrecker.lua
W.serverHandler = nil   -- function(command, player, args, zombie) : server/PongDuWreckerServer.lua

function W.log(msg)
    print("[PongDu][Wrecker] " .. msg)
end

function W.isWrecker(zombie)
    return zombie ~= nil and zombie:getModData()["PuppetMutant"] == W.KIND
end

-- 애니메이션 상태 이름 정규화: 소문자, 경로 앞부분 제거, "-network" 꼬리 제거.
function W.normState(name)
    if type(name) ~= "string" or name == "" then return nil end
    local n = string.lower(name)
    n = string.gsub(n, "\\", "/")
    n = string.match(n, "([^/]+)$")
    if not n or n == "" then return nil end
    n = string.gsub(n, "%-network$", "")
    return n
end

-- 좀비의 현재 애니메이션 상태 (정규화).
--   MP 서버: 소유 클라가 올려 보낸 realState (NetworkZombieAI.java:180, 256)
--   그 외  : 자기 ActionContext 상태
function W.stateOf(zombie)
    if not zombie then return nil end
    if isServer() then
        local rs = W.normState(zombie:getRealState())
        if rs then return rs end
    end
    return W.normState(zombie:getCurrentActionContextStateName())
end

-- 서버 -> 모든 클라: 단계 통지. args = { zid, ph, seq, dx, dy }
function W.sendPhase(args, zombie)
    if isServer() then
        sendServerCommand(W.NET, "Phase", args)
    elseif W.clientHandler then
        W.clientHandler(args, zombie)
    end
end

-- 클라 -> 서버: 명중(Hit)·충돌(Crash) 보고. args = { zid, seq }
-- 서버 -> 모든 클라: 이 플레이어가 맞아 넘어진다 (다른 클라에서도 같은 넘어짐 클립이 나오게). args = { pid }
function W.sendFall(args)
    if isServer() then
        sendServerCommand(W.NET, "Fall", args)
    end
end

function W.sendClaim(player, command, args, zombie)
    if isClient() then
        sendClientCommand(player, W.NET, command, args)
    elseif W.serverHandler then
        W.serverHandler(command, player, args, zombie)
    end
end

return W
