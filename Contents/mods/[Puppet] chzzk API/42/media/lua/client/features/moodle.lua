local _a = {moodleMap = {
    ["IGUI_moodle_Drunk"]     = {type = MoodleType.DRUNK},
    ["IGUI_moodle_Endurance"] = {type = MoodleType.ENDURANCE},
    ["IGUI_moodle_Food"]      = {type = "food"},
    ["IGUI_moodle_Panic"]     = {type = MoodleType.PANIC},
    ["IGUI_moodle_Stress"]    = {type = MoodleType.STRESS},
    ["IGUI_moodle_Tired"]     = {type = MoodleType.TIRED},
    ["IGUI_moodle_Unhappy"]   = {type = MoodleType.UNHAPPY},
}}
local _b = require("constants")
local _c = require("global")

-- 모든 버프/디버프의 증감폭은 "해당 스탯 전체 범위의 20%"로 통일한다.
local DELTA_PERCENT = 20

-- [B42] 스탯 조작은 shared/PongDuStats.lua 를 거친다.
--   - B41 개별 getter/setter(getDrunkenness/setPanic/BodyDamage:setUnhappynessLevel ...)가
--     B42에서 전부 사라지고 Stats:get/set/add(CharacterStat.X) 로 바뀌었다
--   - Stats:set 이 스탯 범위로 clamp 하므로(CharacterStat.clamp) B41의 shiftStat 직접 clamp 는 필요 없다
--   - MP 에선 서버 값이 정답이라 PongDuStats.apply 가 서버에 같은 연산을 보낸다
--   - B42 STRESS 는 순수 스트레스(체감 = STRESS + NICOTINE_WITHDRAWAL, Stats.java:128).
--     B41의 getStress()-getStressFromCigarettes() 역산(getPureStress)은 필요 없어졌다
-- 스탯별 스케일: Stress/Endurance/Fatigue = 0~1, Panic/Intoxication/Unhappiness = 0~100
local UNIT    = DELTA_PERCENT / 100          -- 0~1 스탯의 20%
local PERCENT = DELTA_PERCENT                -- 0~100 스탯의 20%

-- 디버프 (MoodleType -> ops)
local DEBUFF_OPS = {
    [MoodleType.DRUNK]     = { { op = "add", stat = "INTOXICATION", v =  PERCENT } },
    [MoodleType.ENDURANCE] = { { op = "add", stat = "ENDURANCE",    v = -UNIT } },
    [MoodleType.PANIC]     = { { op = "add", stat = "PANIC",        v =  PERCENT } },
    [MoodleType.STRESS]    = { { op = "add", stat = "STRESS",       v =  UNIT } },
    [MoodleType.TIRED]     = { { op = "add", stat = "FATIGUE",      v =  UNIT } },
    [MoodleType.UNHAPPY]   = { { op = "add", stat = "UNHAPPINESS",  v =  PERCENT } },
    food                   = { { op = "food", v = -DELTA_PERCENT } },
}

-- 버프. 스트레스는 담배 금단분(NICOTINE_WITHDRAWAL, 최대 0.51)부터 깎고 남는 양만
-- 순수 STRESS 에서 깎는다 (순수분부터 깎으면 금단분이 남아 체감이 거의 안 줄었다).
local BUFF_OPS = {
    [MoodleType.DRUNK]     = { { op = "add", stat = "INTOXICATION", v = -PERCENT } },
    [MoodleType.ENDURANCE] = { { op = "add", stat = "ENDURANCE",    v =  UNIT } },
    [MoodleType.PANIC]     = { { op = "add", stat = "PANIC",        v = -PERCENT } },
    [MoodleType.STRESS]    = { { op = "drain", stats = { "NICOTINE_WITHDRAWAL", "STRESS" }, v = UNIT } },
    [MoodleType.TIRED]     = { { op = "add", stat = "FATIGUE",      v = -UNIT } },
    [MoodleType.UNHAPPY]   = { { op = "add", stat = "UNHAPPINESS",  v = -PERCENT } },
    food                   = { { op = "food", v = DELTA_PERCENT } },
}

local BUFF_MAP = {
    ["IGUI_buff_moodle_Drunk"]     = {type = MoodleType.DRUNK},
    ["IGUI_buff_moodle_Endurance"] = {type = MoodleType.ENDURANCE},
    ["IGUI_buff_moodle_Food"]      = {type = "food"},
    ["IGUI_buff_moodle_Panic"]     = {type = MoodleType.PANIC},
    ["IGUI_buff_moodle_Stress"]    = {type = MoodleType.STRESS},
    ["IGUI_buff_moodle_Tired"]     = {type = MoodleType.TIRED},
    ["IGUI_buff_moodle_Unhappy"]   = {type = MoodleType.UNHAPPY},
}

-- 디버프 적용
function _a.a(a, b)
    if not a then return end
    _c.b("applyMoodleEffect FUNCTION START key=" .. tostring(b))
    local e = _a.moodleMap[b]
    local ops = e and DEBUFF_OPS[e.type]
    if ops then
        PongDuStats.apply(a, ops, "moodle_debuff:" .. tostring(b))
    else
        _c.b("applyMoodleEffect: no ops for key=" .. tostring(b))
    end
    _c.b("applyMoodleEffect FUNCTION END")
end

-- 버프 적용
function _a.b(a, b)
    if not a then return end
    _c.b("applyMoodleBuffEffect FUNCTION START key=" .. tostring(b))
    local e = BUFF_MAP[b]
    local ops = e and BUFF_OPS[e.type]
    if ops then
        PongDuStats.apply(a, ops, "moodle_buff:" .. tostring(b))
    else
        _c.b("applyMoodleBuffEffect: no ops for key=" .. tostring(b))
    end
    _c.b("applyMoodleBuffEffect FUNCTION END")
end
return _a
