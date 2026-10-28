-- PongDuWrecker: 레커(돌진 특수좀비) 공용 상수와 통신 경로 (B42).
--
-- [동작]
--   대상 플레이어가 TRIGGER_MIN~TRIGGER_MAX 칸 안이고 사이가 트여 있으면
--   예고(warn) -> 돌진(sprint) -> 회복(recovery) 순서로 진행한다.
--   돌진 중 닿은 플레이어는 넘어지고 피해를 입으며, 돌진은 멈추지 않고 계속된다(여러 명 관통).
--   돌진 중 벽·문·창문에 막히면 충돌(crash): 앞을 막은 문·창문·바리케이드를 부수고 레커가 넘어진다.
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

W.PH = {
    NONE     = "none",
    WARN     = "warn",
    SPRINT   = "sprint",
    RECOVERY = "recovery",
    CRASH    = "crash",
}

-- 단계 길이 (ms). 돌진 최대 거리는 샌드박스 Wrecker_ChargeDistance.
W.WARN_MS       = 1500
W.SPRINT_MAX_MS = 4000
W.RECOVERY_MS   = 1000
W.CRASH_MS      = 300
W.COOLDOWN_MS   = 10000   -- 돌진 시작부터 다음 돌진 가능까지

-- 발동 거리 (칸). 너무 붙어 있으면 돌진 대신 바닐라 공격에 맡긴다.
W.TRIGGER_MIN = 1.5
W.TRIGGER_MAX = 5

-- 피격 판정 반경 (칸, 피격자 클라)
W.HIT_RADIUS = 0.9

-- 소유 클라가 AI 이동을 멈출 때 빌리는 바닐라 상태. IsoZombie 가 이 이름을
-- GenericDefaultState(enter/execute/exit 없음)로 등록한다(IsoZombie.java:657).
W.HOLD_STATE = "attackvehicle-network"

-- 예고음 (바닐라 스프린터 포효). 전용 사운드를 만들면 이 이름만 바꾼다.
W.WARN_SOUND_MALE   = "MaleZombieSprinterVoiceA"
W.WARN_SOUND_FEMALE = "FemaleZombieSprinterVoiceA"

W.clientHandler = nil   -- function(args, zombie)                  : client/features/wrecker.lua
W.serverHandler = nil   -- function(command, player, args, zombie) : server/PongDuWreckerServer.lua

function W.log(msg)
    print("[PongDu][Wrecker] " .. msg)
end

function W.isWrecker(zombie)
    return zombie ~= nil and zombie:getModData()["PuppetMutant"] == W.KIND
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
function W.sendClaim(player, command, args, zombie)
    if isClient() then
        sendClientCommand(player, W.NET, command, args)
    elseif W.serverHandler then
        W.serverHandler(command, player, args, zombie)
    end
end

return W
