-- PongDuBody: 플레이어 몸 상태(BodyPart) 조작 공용 경로 (B42).
--
-- [왜 shared 인가]
--   B42 MP 에서 BodyPart(상처/감염/부위 체력)는 서버 값이 정답이다.
--   * syncBodyPart(part, mask) 는 서버에서만 동작한다 (LuaManager.java syncBodyPart:
--     "if (GameServer.server && ...)" ). 클라가 직접 바꾼 상처는 서버 값에 덮여 몇 초 안에 사라진다
--     (2026-10-26 멀티 4B #3 에서 확인).
--   * 바닐라 디버그 건강 패널도 MP 에서는 서버 명령(server/ClientCommands.lua)으로 상처를 만들고
--     syncBodyPart(bodyPart, 0xFFFFFFFFFFF) 로 내려보낸다. 퐁듀도 같은 방식을 쓴다.
--   그래서 실제 조작 코드는 여기 한 곳에 두고
--     - SP  : 클라 기능 파일이 직접 호출 (서버 왕복 없음)
--     - MP  : 클라가 sendClientCommand("PongDuBody", ...) 로 요청 -> server/PongDuBodyServer.lua 가 호출
--   한다. isServer() 일 때만 손댄 부위를 syncBodyPart 로 소유 클라에 내려보낸다.
--
-- 반환값은 sendServerCommand 로 그대로 보낼 수 있는 plain table 이다
-- (부위는 인덱스, 문구는 번역 키. 표시 문자열 조립은 클라가 한다).

PongDuBody = PongDuBody or {}

local LOG_INJURY = "[PongDu][RandomInjury] "
local LOG_HEAL   = "[PongDu][InstantHeal] "

PongDuBody.NET_MODULE = "PongDuBody"

-- BodyPartSyncPacket 의 BD_* 비트 전체 (바닐라 ClientCommands.lua 와 같은 값).
local SYNC_ALL = 0xFFFFFFFFFFF

function PongDuBody.syncPart(part)
    if isServer() and part then
        syncBodyPart(part, SYNC_ALL)
    end
end

-- ── 랜덤 부상 (random_injury) ────────────────────────────────────────────────
--
-- 머리/목 제외 이유: Neck 은 생성자에서 DamageScaler 가 5배로 잡혀 있고
-- (BodyPart.java:78-80), Head 는 상시 노출 부위라 방어구로 막을 수단이 사실상
-- 없다. 둘 다 후원 한 번에 즉사에 가까운 결과가 나올 수 있어 밸런스상 뺀다.
--
-- 구현 근거 (B41 41.78.20 BodyPart.java 확인, B42 동일):
--   * setScratched(true, forceNoInfection) / setCut(true, forceNoInfection)
--     -- forceNoInfection=false 일 때만 좀비 감염 확률이 붙는다. 기본은 감염 없음(true).
--   * SetBitten(true) 1인자 버전만 biteTime / setInfectedWound / 출혈을 제대로 채운다.
--     감염을 뺄 때는 호출 직후 SetInfected/SetFakeInfected 를 false 로 되돌린다.
--   * generateDeepShardWound() 는 깊은 상처 + 유리 파편을 같이 만든다.
--   * setBurned() / setHaveBullet(true, 0) / setFractureTime(30~50, AddRandomDamage 와 동일 범위).
--     바닐라 골절을 끈 서버(SandboxVars.BoneFracture=false)에서는 골절을 후보에서 뺀다.
PongDuBody.INJURY_TYPES = {
    {
        id = "scratch", option = "Injury_Scratch", key = "IGUI_donation_injury_scratch",
        apply = function(part, allowInfection) part:setScratched(true, not allowInfection) end,
    },
    {
        id = "cut", option = "Injury_Cut", key = "IGUI_donation_injury_cut",
        apply = function(part, allowInfection) part:setCut(true, not allowInfection) end,
    },
    {
        id = "deep_wound", option = "Injury_DeepWound", key = "IGUI_donation_injury_deep_wound",
        apply = function(part) part:generateDeepWound() end,
    },
    {
        id = "glass", option = "Injury_Glass", key = "IGUI_donation_injury_glass",
        apply = function(part) part:generateDeepShardWound() end,
    },
    {
        id = "bite", option = "Injury_Bite", key = "IGUI_donation_injury_bite",
        apply = function(part, allowInfection)
            part:SetBitten(true)
            if not allowInfection then
                part:SetInfected(false)
                part:SetFakeInfected(false)
            end
        end,
    },
    {
        id = "burn", option = "Injury_Burn", key = "IGUI_donation_injury_burn",
        apply = function(part) part:setBurned() end,
    },
    {
        id = "bullet", option = "Injury_Bullet", key = "IGUI_donation_injury_bullet",
        apply = function(part) part:setHaveBullet(true, 0) end,
    },
    {
        id = "fracture", option = "Injury_Fracture", key = "IGUI_donation_injury_fracture",
        vanillaGate = function() return SandboxVars.BoneFracture end,
        apply = function(part) part:setFractureTime(ZombRand(30, 51)) end,
    },
}

-- 머리/목을 뺀 부위 인덱스 목록. 인덱스를 하드코딩하지 않고 매번 BodyPartType 에서 만든다.
local function buildPartPool()
    local pool = {}
    local headIdx = BodyPartType.ToIndex(BodyPartType.Head)
    local neckIdx = BodyPartType.ToIndex(BodyPartType.Neck)
    local maxIdx  = BodyPartType.ToIndex(BodyPartType.MAX)
    for i = 0, maxIdx - 1 do
        if i ~= headIdx and i ~= neckIdx then
            pool[#pool + 1] = i
        end
    end
    return pool
end

-- 샌드박스에서 켜져 있고 바닐라 게이트도 통과한 부상 종류만 모은다.
local function buildTypePool()
    local sv = SandboxVars.PongDu
    local pool = {}
    for i = 1, #PongDuBody.INJURY_TYPES do
        local t = PongDuBody.INJURY_TYPES[i]
        if sv[t.option] and (t.vanillaGate == nil or t.vanillaGate()) then
            pool[#pool + 1] = t
        end
    end
    return pool
end

-- 반환: { applied, count, part (마지막 부위 인덱스), key (마지막 부상 번역 키), skipped }
function PongDuBody.randomInjury(player, sender)
    local result = { applied = 0, count = 0 }
    if not player then
        print(LOG_INJURY .. "injury aborted: player is nil")
        return result
    end
    local bodyDamage = player:getBodyDamage()
    if not bodyDamage then
        print(LOG_INJURY .. "injury aborted: bodyDamage is nil")
        return result
    end

    local sv = SandboxVars.PongDu
    local count          = sv.Injury_Count
    local allowInfection = sv.Injury_Infection
    result.count = count

    local typePool = buildTypePool()
    if #typePool == 0 then
        print(LOG_INJURY .. "injury SKIPPED: every injury type is disabled in sandbox"
            .. " (sender=" .. tostring(sender) .. ")")
        result.skipped = true
        return result
    end

    -- 같은 부위에 몰리지 않도록 뽑은 부위는 풀에서 빼고, 풀이 마르면 다시 채운다.
    local partPool = buildPartPool()

    for _ = 1, count do
        if #partPool == 0 then partPool = buildPartPool() end

        local pick    = ZombRand(1, #partPool + 1)
        local partIdx = partPool[pick]
        table.remove(partPool, pick)

        local partType = BodyPartType.FromIndex(partIdx)
        local part     = bodyDamage:getBodyPart(partType)
        if not part then
            print(LOG_INJURY .. "getBodyPart returned nil (index=" .. tostring(partIdx) .. ")")
        else
            local injury = typePool[ZombRand(1, #typePool + 1)]
            injury.apply(part, allowInfection)
            PongDuBody.syncPart(part)
            result.applied = result.applied + 1
            result.part = partIdx
            result.key  = injury.key
            print(LOG_INJURY .. "applied injury=" .. injury.id
                .. " part=" .. BodyPartType.ToString(partType)
                .. " allowInfection=" .. tostring(allowInfection)
                .. " server=" .. tostring(isServer()))
        end
    end

    print(LOG_INJURY .. "done applied=" .. tostring(result.applied) .. "/" .. tostring(count)
        .. " typePool=" .. tostring(#typePool)
        .. " sender=" .. tostring(sender)
        .. " player=" .. tostring(player:getUsername()))
    return result
end

-- ── 즉시 치유 (instant_heal) ─────────────────────────────────────────────────
--
-- 전신 부위의 물리적 부상과 부위 체력을 원상복구한다. 좀비 감염은 기본적으로 남기고,
-- 샌드박스 Heal_CureBiteInfection 을 켰을 때만 백신과 같은 절차로 완전 치료한다.
--
-- 구현 근거 (B41 41.78.20 BodyPart.java / BodyDamage.java 확인, B42 동일):
--   * BodyPart:RestoreToFullHealth() 는 그 부위의 모든 부상 필드와 Health 를 한 번에 초기화한다.
--     다만 IsInfected / IsFakeInfected 까지 지우므로, 감염을 남길 때는 호출 전 값을 되돌린다.
--   * 뻐근함(stiffness)은 RestoreToFullHealth() 대상이 아니다. 부위 값만 0으로 만들면
--     Fitness 누적치가 남아 되돌아오므로 Fitness:removeStiffnessValue() 도 같이 부른다 (바닐라와 동일).
--   * 전체 체력(OverallBodyHealth)은 부위 체력에서 매 틱 재계산되므로 직접 쓰지 않는다.
--   * B42: InfectionLevel/FakeInfectionLevel 은 Stats 로 옮겨졌다 (ZOMBIE_INFECTION / ZOMBIE_FEVER).
--     PongDuStats.applyLocal 은 서버에서 부르면 syncPlayerStats 까지 한다.
--
-- 반환: { healed, stiffness, keptInfected, cureInfection }
function PongDuBody.instantHeal(player, sender)
    local result = { healed = 0, stiffness = 0, keptInfected = 0 }
    if not player then
        print(LOG_HEAL .. "heal aborted: player is nil")
        return result
    end
    local bodyDamage = player:getBodyDamage()
    if not bodyDamage then
        print(LOG_HEAL .. "heal aborted: bodyDamage is nil")
        return result
    end

    local cureInfection = SandboxVars.PongDu.Heal_CureBiteInfection
    result.cureInfection = cureInfection
    local fitness = player:getFitness()

    local parts = bodyDamage:getBodyParts()
    for i = 0, parts:size() - 1 do
        local part = parts:get(i)

        local wasInfected = part:IsInfected()
        local wasFake     = part:IsFakeInfected()
        local hadInjury   = part:HasInjury() or part:getHealth() < 100

        part:RestoreToFullHealth()

        if not cureInfection then
            if wasInfected then
                part:SetInfected(true)
                result.keptInfected = result.keptInfected + 1
            end
            if wasFake then
                part:SetFakeInfected(true)
            end
        end

        if part:getStiffness() > 0 then
            part:setStiffness(0)
            if fitness then
                fitness:removeStiffnessValue(BodyPartType.ToString(part:getType()))
            end
            result.stiffness = result.stiffness + 1
        end

        if hadInjury then
            result.healed = result.healed + 1
        end

        PongDuBody.syncPart(part)
    end

    if cureInfection then
        -- shared/PongDuVaccine.lua 의 Zomboxivir 처리와 같은 절차.
        bodyDamage:setInfected(false)
        bodyDamage:setIsFakeInfected(false)
        PongDuStats.applyLocal(player, {
            { op = "set", stat = "ZOMBIE_INFECTION", v = 0 },
            { op = "set", stat = "ZOMBIE_FEVER",     v = 0 },
        }, "instant_heal")
        bodyDamage:setInfectionTime(-1)
        bodyDamage:setInfectionMortalityDuration(-1)
    end

    print(LOG_HEAL .. "healed parts=" .. tostring(result.healed)
        .. " stiffnessCleared=" .. tostring(result.stiffness)
        .. " cureInfection=" .. tostring(cureInfection)
        .. " infectedPartsKept=" .. tostring(result.keptInfected)
        .. " server=" .. tostring(isServer())
        .. " sender=" .. tostring(sender)
        .. " player=" .. tostring(player:getUsername()))
    return result
end

-- ── 폭격 부상 (missile 폭발) ─────────────────────────────────────────────────
--
-- 머리 화상 + 통증, 머리 제외 15부위 중 긁힘 4 / 깊은 상처 1 / 베임 1 (감염 없음).
-- 실외에 있는 플레이어만. 넘어지는 연출(setBumpType 등)은 로컬 플레이어 애니메이션이라
-- 클라(features/bombard.lua)가 따로 한다.
--   SP : 클라가 직접 호출
--   MP : 서버 Kaboom 처리(server/server.lua)가 반경 안 접속자 전원에게 호출 -> 부위마다 syncBodyPart
-- 반환: 적용했으면 true
local BLAST_PARTS = {
    "Foot_L", "Foot_R",
    "ForeArm_L", "ForeArm_R",
    "Groin",
    "Hand_L", "Hand_R",
    "LowerLeg_L", "LowerLeg_R",
    "Torso_Lower", "Torso_Upper",
    "UpperArm_L", "UpperArm_R",
    "UpperLeg_L", "UpperLeg_R",
}

function PongDuBody.blastInjury(player)
    if not SandboxVars.PongDu.Bombard_Injure then return false end
    if not player or not player:isOutside() then return false end
    local bd = player:getBodyDamage()
    if not bd then return false end

    local function pickParts(n)
        local out, seen = {}, {}
        while #out < n do
            local name = BLAST_PARTS[ZombRand(1, #BLAST_PARTS + 1)]
            if not seen[name] then
                seen[name] = true
                out[#out + 1] = name
            end
        end
        return out
    end

    local touched = {}
    local head = bd:getBodyPart(BodyPartType.Head)
    head:setBurned()
    head:setAdditionalPain(100)
    touched[#touched + 1] = head
    for _, name in ipairs(pickParts(4)) do
        local part = bd:getBodyPart(BodyPartType[name])
        part:setScratched(true, true)
        touched[#touched + 1] = part
    end
    for _, name in ipairs(pickParts(1)) do
        local part = bd:getBodyPart(BodyPartType[name])
        part:generateDeepWound()
        touched[#touched + 1] = part
    end
    for _, name in ipairs(pickParts(1)) do
        local part = bd:getBodyPart(BodyPartType[name])
        part:setCut(true, true)
        touched[#touched + 1] = part
    end
    for _, part in ipairs(touched) do
        PongDuBody.syncPart(part)
    end

    print("[PongDu][BlastInjury] applied parts=" .. #touched
        .. " server=" .. tostring(isServer())
        .. " player=" .. tostring(player:getUsername()))
    return true
end

return PongDuBody
