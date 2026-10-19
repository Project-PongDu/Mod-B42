-- PongDuStats: 플레이어 스탯 조작 공용 경로 (B42).
--
-- [B41 -> B42 에서 바뀐 것]
--   1) API: Stats 의 개별 getter/setter(getFatigue/setPanic/...)와 BodyDamage 의
--      setInfectionLevel/setFoodSicknessLevel/setPoisonLevel/getUnhappynessLevel 이 전부 없어지고
--      Stats:get/set/add(CharacterStat.X) 하나로 합쳐졌다 (Stats.java:74~87).
--      set 은 스탯 범위로 자동 clamp 한다 (CharacterStat.clamp) -> 직접 clamp 할 필요 없음.
--      B41 이름 -> B42 CharacterStat:
--        Drunkenness -> INTOXICATION (0~100)      Unhappyness(BodyDamage) -> UNHAPPINESS (0~100)
--        StressFromCigarettes -> NICOTINE_WITHDRAWAL (0~0.51)
--        InfectionLevel -> ZOMBIE_INFECTION        FakeInfectionLevel -> ZOMBIE_FEVER
--        FoodSicknessLevel -> FOOD_SICKNESS        PoisonLevel -> POISON         Pain -> PAIN
--      STRESS 는 이제 "순수" 스트레스다. 체감값은 STRESS + NICOTINE_WITHDRAWAL (Stats.java:128).
--   2) 권위: MP 에서 플레이어 스탯은 서버 값이 정답이고, 서버가 SyncPlayerStats 로 소유
--      클라에 내려준다 (LuaManager.syncPlayerStats:9966). 클라가 직접 바꾼 값은 다음 동기화에
--      덮인다. 클라 -> 서버 반영(sendPlayerStat:9973)은 CanModifyBodyStats 권한(어드민)이 있어야 한다.
--
-- 그래서:
--   PongDuStats.apply(player, ops)      : 후원 효과처럼 클라에서 시작하는 변경.
--       싱글 = 바로 적용 / MP 클라 = 즉시 화면 반영용으로 로컬 적용 + 서버에 같은 ops 전송
--       / 서버 = 적용 + syncPlayerStats.
--   PongDuStats.applyLocal(player, ops) : 서버와 클라에서 각각 따로 도는 코드용
--       (OnEat 처럼 엔진이 양쪽에서 부르는 경로). 네트워크 전송 없이 적용, 서버면 sync.
--
-- ops 는 plain table 배열 (sendClientCommand 로 그대로 보낼 수 있어야 한다):
--   { op = "set",   stat = "PAIN",  v = 0 }
--   { op = "add",   stat = "PANIC", v = 15 }
--   { op = "drain", stats = { "NICOTINE_WITHDRAWAL", "STRESS" }, v = 0.2 }
--       앞 스탯부터 0 이 될 때까지 깎고 남은 양을 다음 스탯에서 깎는다.
--   { op = "food",  v = 20 }
--       배고픔(HUNGER, 0~1)과 포만감(BodyDamage.HealthFromFoodTimer, 0~11000)을 -100~100 한 축으로
--       보고 v(%)만큼 이동. 양수 = 포만 방향.
--
-- [보안] 서버는 보낸 본인에게만, 아래 ALLOWED 스탯만 적용한다. 후원 이벤트 자체가 클라에서
-- 시작하는 구조(런처 -> 클라 파일)라 서버가 "정당한 후원 효과인지"는 검증할 수 없다.

PongDuStats = PongDuStats or {}

local LOG = "[PongDu][Stats] "
local NET_MODULE = "PongDuStats"

local ALLOWED = {
    ENDURANCE = true, FATIGUE = true, PANIC = true, STRESS = true,
    NICOTINE_WITHDRAWAL = true, INTOXICATION = true, UNHAPPINESS = true,
    HUNGER = true, PAIN = true, POISON = true, FOOD_SICKNESS = true,
    ZOMBIE_INFECTION = true, ZOMBIE_FEVER = true,
}

-- BodyDamage.HealthFromFoodTimer 의 게임 내 상한 (B41 BodyDamage.java:572-573 과 동일 값).
local FOOD_FULLNESS_BASIS = 11000

local function statOf(name)
    if not ALLOWED[name] then return nil end
    return CharacterStat[name]
end

-- 바뀐 스탯을 SyncPlayerStats 비트마스크로. 같은 스탯이 여러 번 나와도 한 번만 더한다
-- (Kahlua 엔 비트 연산이 없어 OR 대신 중복 제거 + 합).
local function buildMask(touched)
    local getMask = SyncPlayerStatsPacket and SyncPlayerStatsPacket.getBitMaskForStat
    if not getMask then
        print(LOG .. "SyncPlayerStatsPacket.getBitMaskForStat unavailable, sync skipped")
        return 0
    end
    local mask = 0
    for name, _ in pairs(touched) do
        mask = mask + getMask(CharacterStat[name])
    end
    return mask
end

local function applyFood(player, percent, touched)
    local stats = player:getStats()
    local bodyDamage = player:getBodyDamage()

    local hungerPct = stats:get(CharacterStat.HUNGER) * 100
    local fullPct = bodyDamage:getHealthFromFoodTimer() / FOOD_FULLNESS_BASIS * 100
    if fullPct < 0 then fullPct = 0 end
    if fullPct > 100 then fullPct = 100 end

    local net = fullPct - hungerPct + percent
    if net > 100 then net = 100 end
    if net < -100 then net = -100 end

    if net >= 0 then
        stats:set(CharacterStat.HUNGER, 0)
        bodyDamage:setHealthFromFoodTimer((net / 100) * FOOD_FULLNESS_BASIS)
    else
        stats:set(CharacterStat.HUNGER, (-net) / 100)
        bodyDamage:setHealthFromFoodTimer(0)
    end
    touched.HUNGER = true
    print(LOG .. "food percent=" .. tostring(percent) .. " hungerPct=" .. tostring(hungerPct)
        .. " fullPct=" .. tostring(fullPct) .. " net=" .. tostring(net))
end

local function applyOps(player, ops, tag)
    local stats = player:getStats()
    local touched = {}
    for _, o in ipairs(ops) do
        if o.op == "set" or o.op == "add" then
            local st = statOf(o.stat)
            if st then
                local before = stats:get(st)
                if o.op == "set" then stats:set(st, o.v) else stats:add(st, o.v) end
                touched[o.stat] = true
                print(LOG .. tostring(tag) .. " " .. o.op .. " " .. o.stat .. " " .. tostring(before)
                    .. " -> " .. tostring(stats:get(st)))
            else
                print(LOG .. "rejected stat " .. tostring(o.stat))
            end
        elseif o.op == "drain" then
            local left = o.v or 0
            for _, name in ipairs(o.stats or {}) do
                local st = statOf(name)
                if st and left > 0 then
                    local before = stats:get(st)
                    local take = math.min(before, left)
                    stats:set(st, before - take)
                    left = left - take
                    touched[name] = true
                    print(LOG .. tostring(tag) .. " drain " .. name .. " " .. tostring(before)
                        .. " -> " .. tostring(stats:get(st)))
                end
            end
        elseif o.op == "food" then
            applyFood(player, o.v or 0, touched)
        else
            print(LOG .. "unknown op " .. tostring(o.op))
        end
    end
    return touched
end

local function syncIfServer(player, touched)
    if not isServer() then return end
    local mask = buildMask(touched)
    if mask ~= 0 then syncPlayerStats(player, mask) end
end

-- 네트워크 없이 이 프로세스에서만 적용 (서버면 소유 클라에 sync).
function PongDuStats.applyLocal(player, ops, tag)
    if not player or not ops then return end
    syncIfServer(player, applyOps(player, ops, tag))
end

-- 클라에서 시작하는 변경. MP 클라면 서버에도 보낸다.
function PongDuStats.apply(player, ops, tag)
    if not player or not ops then return end
    applyOps(player, ops, tag)
    if isClient() then
        sendClientCommand(player, NET_MODULE, "Apply", { ops = ops, tag = tag })
    end
end

-- 읽기 헬퍼 (B41 getter 대체)
function PongDuStats.get(player, name)
    return player:getStats():get(CharacterStat[name])
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= NET_MODULE or command ~= "Apply" then return end
    if not player or not args or type(args.ops) ~= "table" then
        print(LOG .. "Apply: bad payload")
        return
    end
    PongDuStats.applyLocal(player, args.ops, "remote:" .. tostring(args.tag))
end)
