-- PongDuWrecker: 레커(돌진 특수좀비) 공용 상수와 통신 경로 (B42).
--
-- [동작]
--   대상 플레이어가 TRIGGER_MIN~TRIGGER_MAX 칸 안이고 사이가 트여 있으면
--   예고(warn) -> 돌진(sprint) -> 회복(recovery) 순서로 진행한다.
--   돌진 중 닿은 플레이어는 넘어지고 피해를 입으며, 돌진은 멈추지 않고 계속된다(여러 명 관통).
--   돌진 중 벽·문·창문·울타리에 막히면 충돌(crash): 앞을 막은 문·창문·바리케이드를 부수고
--   휘는 울타리는 휘거나(첫 충돌) 무너뜨린다(이미 휜 것). 레커는 넘어진다.
--   평소에는 일반 좀비처럼 물고 할퀸다(원본 레커와 같음). 돌진 중에는 AI 가 고정돼 물지 못한다.
--   붙어 있어도 돌진한다(TRIGGER_MIN 0, 원본 레커와 같음).
--   돌진 거리 10칸은 소유 클라가 자기 쪽 위치로 잰다(서버 위치는 소유 클라 패킷이라 늦게 따라온다.
--   서버만 재면 실측 18~26칸을 가서야 멈췄다). 소유 클라가 Arrive 를 보내고 바로 회복으로 넘어간다.
--
-- [원본 레커(The Mutants, PZM_Wrecker_*)와의 관계]
--   클립은 원본 것을 그대로 쓰고(예고음은 퐁듀 자체 제작으로 교체, 아래 W.WARN_SOUND. anims_X/Zombie/Zombie_PZM_Wrecker_*.glb. 버전 폴더(42/)의
--   anims_X 는 common/media/anims_X 가 없으면 Zombie·Bob·Kate 같은 메시 폴더만 읽힌다(ModelManager.java:1838~1865),
--   sound/PongDuWrecker_ChargeWarn.ogg), 시간·거리·방향·파괴·취소 규칙도 원본 값을 따른다.
--   원본과 다른 점은 요청으로 바꾼 것뿐이다: 랜덤 외형(원본 남자 고정),
--   피해(원본 차량충돌 공식 -> 전체 체력 20 + 부위 부상), 체력 샌드박스, 돌진 거리 10칸 상한,
--   돌진 속도 1.5배, 맞은 플레이어 넘어짐 클립, 돌진 후 헛공격 방지(client/features/wrecker.lua resumeVanilla).
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

-- 발동 거리 (칸). 붙어 있어도 돌진한다 (원본 TRIGGER_MIN_DISTANCE = 0).
W.TRIGGER_MIN = 0
W.TRIGGER_MAX = 5

-- 돌진 수치 (하드코딩)
W.CHARGE_DISTANCE = 10    -- 한 번 돌진의 최대 거리 (칸). 원본은 검사 안 함. 소유 클라가 재서 Arrive 로 알린다
W.HIT_DAMAGE      = 20    -- 전체 체력(100) 기준으로 깎는 양
W.FRACTURE_CHANCE = 30    -- 부상 부위마다 골절 확률 (%), 나머지는 깊은 상처

-- 예고음: 퐁듀 자체 제작 중성적 울음(sound/PongDuWrecker_ChargeWarn.ogg, 모노 1.5초, 음량은 파일에 반영 -
-- 평균 약 -24 dB, 스크립트 volume 1.0). 원본 파일은 거의 최대 음량이라 다른 소리보다 약 25 dB 컸다.
-- 거리·범주 설정은 원본과 같다(scripts/t3_mutant_sounds.txt).
-- 재생도 원본과 같이 좀비 목소리 채널(getEmitter():playVocals)로 내고, 예고 동안 바닐라 좀비 울음은 끈다.
W.WARN_SOUND = "PongDuWrecker_ChargeWarn"

-- 소유 클라가 AI 이동을 멈출 때 빌리는 바닐라 상태. IsoZombie 가 이 이름을
-- GenericDefaultState(enter/execute/exit 없음)로 등록한다(IsoZombie.java:657).
W.HOLD_STATE = "attackvehicle-network"

-- 단계별로 이동 고정을 허용하는 애니메이션 상태 (이름은 normState 로 정규화한 것).
--   "hold"     : 고정한다
--   "suppress" : 돌진 중 부딪혀 bumped 에 들어가면 바로 끝내고 돌진을 잇는다
--   "crash"    : 돌진 중 낮은 울타리에 닿아 바닐라가 넘기(climbfence)를 걸면 그 울타리 충돌로 본다.
--                소유 클라가 Crash(climb) 를 보내고 서버가 울타리를 부순다. 부술 수 있든 없든 다른 충돌과
--                똑같이 넘어진다(사용자 지시: 모든 충돌에 같은 넘어짐). [원본과 다름: 원본은 넘어간다]
--                바닐라는 좀비 AI 가 Attack/StaggerBack/ClimbOverFence/ClimbThroughWindow 가 아니면
--                벽 충돌 때 넘기를 건다(IsoMovingObject.checkHitHoppable). 고정 상태(GenericDefaultState)는
--                여기 안 걸려 돌진 중에도 넘기가 시작된다.
--   (없음)     : 손을 뗀다. 바닐라 상태가 끝날 때까지 기다린다. 충돌 판정도 하지 않는다.
local HOLD_COMMON = { walktoward = "hold", lunge = "hold", idle = "hold", ["face-target"] = "hold", attack = "hold" }
W.HOLD_STATES = {
    warn     = HOLD_COMMON,
    sprint   = { walktoward = "hold", lunge = "hold", idle = "hold", ["face-target"] = "hold", attack = "hold",
                 thump = "hold", bumped = "suppress", climbfence = "crash" },
    recovery = { walktoward = "hold", lunge = "hold", idle = "hold", ["face-target"] = "hold", attack = "hold",
                 thump = "hold" },
}
-- 서버가 돌진(warn)을 시작해도 되는 상태 (원본 WreckerActions.StartAnimationStates: walktoward, lunge 만).
-- attack·idle 에서 시작하면 돌진이 끝날 때 애니메이션이 attack 에 남아 헛공격 모션이 나온다.
W.START_STATES = { walktoward = true, lunge = true }


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

-- 클라 -> 서버: 명중(Hit)·충돌(Crash)·10칸 도달(Arrive) 보고. args = { zid, seq, ... }
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
