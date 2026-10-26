--- PongDuClock -- 일시정지를 빼고 흐르는 실시간 시계 (ms)
---
--- 왜 필요한가:
---   getTimestampMs() 는 벽시계라 SP 일시정지(F2/Esc) 중에도 흐른다. OnTick 은 멈추므로
---   실시간 기준 타이머(화력지원 남은시간, 서버 job 만료, 헬기 경로 보간 등)는 정지 시간만큼
---   건너뛰어 재개 직후 끝나 버린다. 그렇다고 타이머마다 시각 필드를 밀어주면(zombierain 의
---   tick gap 방식) 필드가 많을수록 빠뜨리기 쉽다. 대신 시계 자체에서 정지 시간을 뺀다.
---
--- 동작 (SP 전용):
---   * OnTick 사이 간격이 PAUSE_GAP_MS 를 넘으면 정지로 보고, 넘은 만큼을 누적 정지 시간에 더한다.
---   * 틱이 PAUSE_GAP_MS 넘게 없는 동안(정지 중, 또는 재개 직후 이 핸들러가 돌기 전)에는
---     "마지막 틱 + PAUSE_GAP_MS" 시각에 멈춘 값을 돌려준다. 재개 시 누적값이 정확히 그만큼
---     늘어나므로 now() 는 끊김 없이 단조 증가한다 -- 핸들러 등록 순서와 무관하다.
---   * MP(클라·서버)는 게임이 멈추지 않으므로 getTimestampMs() 를 그대로 돌려준다. 클라 히칭을
---     정지로 오인해 서버와 시각이 어긋나는 일을 막기 위해서다.
---
--- SP 는 서버·클라 Lua 가 한 VM 이라 server.lua 와 클라 기능 파일이 같은 시계를 공유한다.
--- 이 시계로 만든 시각은 getTimestampMs() 값과 섞어 비교하지 말 것.

PongDuClock = PongDuClock or {}

local PAUSE_GAP_MS = 500

local _lastTick = nil   -- 마지막 OnTick 실시간
local _paused   = 0     -- 누적 정지 시간

local function isSP()
    return not isClient() and not isServer()
end

function PongDuClock.now()
    local real = getTimestampMs()
    if not isSP() then return real end
    if _lastTick and real - _lastTick > PAUSE_GAP_MS then
        return _lastTick + PAUSE_GAP_MS - _paused
    end
    return real - _paused
end

local function onTick()
    if not isSP() then return end
    local real = getTimestampMs()
    if _lastTick then
        local gap = real - _lastTick
        if gap > PAUSE_GAP_MS then
            _paused = _paused + (gap - PAUSE_GAP_MS)
            print(string.format("[PongDu][Clock] tick gap %dms (pause?) -> paused total %dms", gap, _paused))
        end
    end
    _lastTick = real
end

Events.OnTick.Add(onTick)
