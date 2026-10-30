--- PongDuMutantId -- 특수좀비(뮤턴트) 정체성 = 전용 아웃핏 (B42)
---
--- [왜 아웃핏인가]
---   B42 는 좀비가 청크 밖으로 나가 가상화되면 modData 를 버린다
---   (ZombiePopulationManager.n_addZombie 인자에 modData 가 없음). 남는 건 위치·방향·
---   persistentOutfitID·상태 플래그·경로 목표뿐이다. 그래서 modData 표식은 청크를 한 번
---   나갔다 오면 사라지고, 옷 ID + 거리로 되살리던 예전 추적은 옷 ID 충돌(변형 번호 1~500)로
---   호드 좀비를 특좀으로 둔갑시켰다.
---   persistentOutfitID 의 아웃핏 번호는 가상화·서버 재시작(인구 세이브)·시체(IsoDeadBody 가
---   보관, reanimate 가 그대로 복사)·MP 패킷(ZombiePacket.outfitId)을 모두 통과한다.
---   -> media/clothing/clothing.xml 의 PongDuMutant_<슬롯> 아웃핏을 입은 좀비 = 그 종류의 특좀.
---
--- [슬롯 이름은 영구 고정]
---   아웃핏 번호는 저장되지 않고 기동마다 이름 정렬 순으로 다시 매겨진다
---   (PersistentOutfits.initOutfitList). 이름을 바꾸거나 추가·삭제하면 살아있는 월드의 좀비가
---   다른 아웃핏으로 밀린다. 종류 대응은 아래 SLOT_KIND 표로만 바꾼다. 아이템 구성은 자유.
---
--- [후원자 = 옷 ID 의 변형 번호]
---   persistentOutfitID = 성별비트(0x80000000) | 아웃핏번호<<16 | 모자비트(32768) | 변형번호(1~500).
---   변형 번호는 옷 무작위 시드일 뿐이라(고정 복장은 TINT 색만 바뀜) 후원자 번호로 쓴다.
---   서버가 글로벌 ModData DONOR_KEY 에 번호 -> 이름 표를 두고 클라에 전송한다.
---   변형 번호 1 은 "후원자 없음" 예약. 500 을 넘으면 가장 오래된 번호를 재사용한다.
---   Kahlua 에 비트 연산이 없고 % 는 0 쪽 절삭이라(KahluaThread OP_MOD) floor 로 직접 나눈다.

PongDuMutantId = PongDuMutantId or {}
local M = PongDuMutantId

M.OUTFIT_PREFIX = "PongDuMutant_"
M.SLOT_KIND = {
    ["01"] = "screamer",
    ["02"] = "brute",
    ["03"] = "roach",
    ["04"] = "tracer",
    ["05"] = "slammer",
    ["06"] = "sprinter",
    -- "07", "08" : 예비 (아웃핏은 정의돼 있음, 종류 미배정)
}
M.KIND_SLOT = {}
for slot, kind in pairs(M.SLOT_KIND) do M.KIND_SLOT[kind] = slot end

-- 성별 고정 (addZombiesInOutfit femaleChance, 0~100). 없으면 50.
M.FEMALE_CHANCE = {
    screamer = 100,   -- 전신화상 환자 (환자복 + 전신 붕대)
    slammer  = 0,     -- 근육 상체 + 청바지 (남성 몸 전용 외형)
}

M.DONOR_KEY  = "PongDuMutantDonors"
M.NO_DONOR   = 1
M.MAX_DONOR  = 500

local PREFIX_LEN = string.len(M.OUTFIT_PREFIX)

function M.log(msg)
    print("[PongDu][MutantId] " .. tostring(msg))
end

-- ── 종류 판별 ────────────────────────────────────────────────────────────────

--- 아웃핏 이름 -> 종류 (특좀 아웃핏이 아니면 nil)
function M.kindOfOutfitName(name)
    if type(name) ~= "string" then return nil end
    if string.sub(name, 1, PREFIX_LEN) ~= M.OUTFIT_PREFIX then return nil end
    return M.SLOT_KIND[string.sub(name, PREFIX_LEN + 1)]
end

--- persistentOutfitID -> 아웃핏 번호 (성별 비트 제거, 상위 16비트). 0/비숫자는 nil
function M.outfitIndexOf(pid)
    if type(pid) ~= "number" or pid == 0 then return nil end
    local p = pid
    if p < 0 then p = p + 4294967296 end                  -- 성별 비트가 켜진 음수 pid
    if p >= 2147483648 then p = p - 2147483648 end
    return math.floor(p / 65536)
end

--- 아웃핏 번호 -> 종류 표. PersistentOutfits.initOutfitList 는 여성 아웃핏을 이름순으로
--- 먼저 번호 매기므로(0..F-1), getAllOutfits(true)(같은 이름순 정렬) 의 위치가 곧 번호다.
--- PongDuMutant_* 는 여성·남성 양쪽에 다 있어 남성 좀비도 같은 번호를 쓴다.
--- 목록이 아직 없으면 nil (다음 호출 때 다시 만든다).
M._indexKind = nil
local function indexKindTable()
    if M._indexKind then return M._indexKind end
    local ok, list = pcall(getAllOutfits, true)
    if not ok or not list or list:size() == 0 then return nil end
    local t, n = {}, 0
    for i = 0, list:size() - 1 do
        local kind = M.kindOfOutfitName(list:get(i))
        if kind then
            t[i] = kind
            n = n + 1
        end
    end
    M._indexKind = t
    M.log("outfit index table built mutants=" .. n .. " female=" .. list:size())
    return t
end

--- persistentOutfitID -> 종류 (특좀이 아니면 nil). 표를 못 만들면 false
function M.kindOfPid(pid)
    local idx = M.outfitIndexOf(pid)
    if not idx then return nil end
    local t = indexKindTable()
    if not t then return false end
    return t[idx]
end

--- IsoZombie / IsoDeadBody -> 종류.
--- 좀비는 persistentOutfitID 의 아웃핏 번호로 본다. getOutfitName(HumanVisual.outfit)은
--- 재사용된 좀비 객체에서 이전 좀비의 이름이 남는다: HumanVisual.clear 가 outfit 을 지우지 않고,
--- 클라는 모델이 붙을 때에야 옷을 입혀서(ModelManager.dressInRandomOutfit) 그 전 틱들은
--- 이전 좀비의 아웃핏 이름이 보인다. 옷 ID 는 첫 패킷으로 바로 들어와 이 문제가 없다.
--- (10/30 실측: 호드매니저로 연달아 부른 배치가 직전 배치의 아웃핏 이름으로 읽혀 약 580마리가
---  엉뚱한 특좀으로 초기화됨. Zed_Test·Survivalist02_Late 일반 좀비도 특좀으로 읽힘)
--- 시체는 옷 ID getter 가 없어(IsoDeadBody) 이름으로 본다. 아웃핏 목록을 아직 못 읽었을
--- 때만 이름으로 대신한다.
function M.kindOf(obj)
    if not obj then return nil end
    if instanceof(obj, "IsoZombie") then
        local kind = M.kindOfPid(obj:getPersistentOutfitID())
        if kind ~= false then return kind end
    end
    return M.kindOfOutfitName(obj:getOutfitName())
end

function M.outfitOf(kind)
    local slot = M.KIND_SLOT[kind]
    if not slot then return nil end
    return M.OUTFIT_PREFIX .. slot
end

-- ── 고정 외형 (머리·수염) ─────────────────────────────────────────────────────
-- 머리·수염은 옷 ID 변형 번호로 시드된 OutfitRNG 가 HairOutfitDefinitions 를 보고 고른다
-- (PersistentOutfits.dressInOutfit -> Outfit.RandomData -> HairOutfitDefinitions
--  .getRandomMaleHaircut / getRandomBeard). 변형 번호가 후원자 번호라 같은 후원자(또는 후원자 없음)의
-- 특좀은 머리·수염이 똑같이 나오므로, 종류별로 외형을 아예 고정한다.
-- "Bald" = 바닐라 hairStyles.xml 스타일(남녀 모두, 바닐라 femaleHaircut 에도 쓰임), 수염 "null" = 빈 이름 = BeardStyles 0번(수염 없음).
-- 키는 바닐라 정의와 같다: femaleHaircut / maleHaircut / beard (없는 키는 Java initStringChance 가 null 로 둔다).
-- 클라도 옷 ID 로 직접 입히므로 서버·클라가 같은 정의를 가져야 한다 -> shared 에서 등록.
-- 정의 표는 Lua 파일을 읽을 때마다 다시 읽힌다(LuaManager: HairOutfitDefinitions.dirty = true).
M.FIXED_HAIR = {
    slammer  = { maleHaircut = "Bald:100", beard = "null:100" },
    screamer = { femaleHaircut = "Bald:100" },
}

local function registerFixedHair()
    local defs = HairOutfitDefinitions and HairOutfitDefinitions.haircutOutfitDefinition
    if type(defs) ~= "table" then
        M.log("WARNING HairOutfitDefinitions.haircutOutfitDefinition missing, fixed hair not registered")
        return
    end
    for kind, def in pairs(M.FIXED_HAIR) do
        local outfit = M.outfitOf(kind)
        local found = false
        for i = 1, #defs do
            if defs[i] and defs[i].outfit == outfit then found = true end
        end
        if outfit and not found then
            table.insert(defs, { outfit = outfit, femaleHaircut = def.femaleHaircut,
                maleHaircut = def.maleHaircut, beard = def.beard })
            M.log("fixed hair registered outfit=" .. outfit .. " femaleHaircut=" .. tostring(def.femaleHaircut)
                .. " maleHaircut=" .. tostring(def.maleHaircut)
                .. " beard=" .. tostring(def.beard))
        end
    end
end
registerFixedHair()

-- 종류별 고정 피부 텍스처 (media/textures/Body/<이름>.png). 무작위 좀비 피부(M_ZedBody0N_levelL,
-- 옷 ID 변형 번호 시드) 대신 HumanVisual:setSkinTextureName 으로 덮어쓴다 (getSkinTexture 가 이 이름을 먼저 쓴다).
-- 옷 ID 로 다시 입히면 HumanVisual.clear 가 이름을 지우므로, 클라(mutantspawn 렌더용)와 서버(시체·저장용)가
-- 각자 다시 넣는다. 이름은 HumanVisual 직렬화·copyFrom 으로 시체에 따라간다.
M.FIXED_SKIN = {
    slammer = "PongDu_SlammerGrey_M",
}

--- 고정 피부가 있는 종류면 넣는다. 반환: 바뀌었으면 true
function M.applyFixedSkin(zombie, kind)
    local name = M.FIXED_SKIN[kind]
    if not name or not zombie then return false end
    local hv = zombie:getHumanVisual()
    if not hv then return false end
    if hv:getSkinTexture() == name then return false end
    hv:setSkinTextureName(name)
    return true
end

function M.femaleChance(kind)
    return M.FEMALE_CHANCE[kind] or 50
end

-- ── 변형 번호(후원자 번호) 산술 ──────────────────────────────────────────────
local function lowBits(pid)
    return pid - math.floor(pid / 65536) * 65536          -- 0~65535 (음수 pid 포함)
end

function M.variantOf(pid)
    if type(pid) ~= "number" then return nil end
    local low = lowBits(pid)
    if low >= 32768 then low = low - 32768 end            -- 모자 탈락 비트 제거
    return low
end

function M.withVariant(pid, variant)
    local low = lowBits(pid)
    local hat = (low >= 32768) and 32768 or 0
    return pid - low + hat + variant
end

-- ── 후원자 표 ────────────────────────────────────────────────────────────────
M._donors = nil   -- MP 클라가 서버에서 받은 사본

local function donorTable()
    if isClient() then return M._donors end
    return ModData.getOrCreate(M.DONOR_KEY)
end

--- 좀비의 후원자 이름 (없으면 nil)
function M.senderOf(zombie)
    if not zombie then return nil end
    local v = M.variantOf(zombie:getPersistentOutfitID())
    if not v or v == M.NO_DONOR then return nil end
    local t = donorTable()
    if not t then return nil end
    local name = t[tostring(v)]
    if type(name) ~= "string" or name == "" then return nil end
    return name
end

--- [서버/SP] 후원자 이름 -> 번호. 처음 보는 이름이면 다음 번호를 배정하고 표를 전송한다.
function M.donorIndexFor(sender)
    if type(sender) ~= "string" or sender == "" then return M.NO_DONOR end
    local t = ModData.getOrCreate(M.DONOR_KEY)
    for i = 2, M.MAX_DONOR do
        if t[tostring(i)] == sender then return i end
    end
    local nxt = tonumber(t["_next"]) or 2
    if nxt < 2 or nxt > M.MAX_DONOR then nxt = 2 end
    local old = t[tostring(nxt)]
    t[tostring(nxt)] = sender
    t["_next"] = (nxt >= M.MAX_DONOR) and 2 or (nxt + 1)
    if old then
        M.log("donor slot " .. nxt .. " reused (was " .. tostring(old) .. ")")
    end
    M.log("donor " .. tostring(sender) .. " -> slot " .. nxt)
    if isServer() then ModData.transmit(M.DONOR_KEY) end
    return nxt
end

--- [서버/SP] 방금 소환한 특좀의 변형 번호를 후원자 번호로 바꿔 다시 입힌다.
--- addZombiesInOutfit 과 같은 Lua 호출 안에서 해야 첫 ZombiePacket 에 새 옷 ID 가 실린다
--- (클라는 처음 받은 outfitId 로만 옷을 입힌다, NetworkZombieSimulator.parseZombie).
function M.applyDonor(zed, sender)
    local idx = M.donorIndexFor(sender)
    local pid = zed:getPersistentOutfitID()
    if not pid or pid == 0 then
        M.log("applyDonor: zombie has no outfit id, donor not stored")
        return idx
    end
    local newPid = M.withVariant(pid, idx)
    if newPid ~= pid then
        zed:dressInPersistentOutfitID(newPid)
    end
    return idx
end

--- [서버/SP] 특좀 1마리 소환. 반환: IsoZombie 또는 nil
function M.spawn(x, y, z, kind, sender)
    local outfit = M.outfitOf(kind)
    if not outfit then
        M.log("spawn: unknown kind " .. tostring(kind))
        return nil
    end
    local zeds = addZombiesInOutfit(x, y, z, 1, outfit, M.femaleChance(kind))
    if not zeds or zeds:size() == 0 then return nil end
    return zeds:get(0)
end

-- ── MP 클라: 후원자 표 수신 ──────────────────────────────────────────────────
if isClient() then
    Events.OnReceiveGlobalModData.Add(function(name, data)
        if name ~= M.DONOR_KEY then return end
        if type(data) == "table" then
            M._donors = data
            local n = 0
            for k, _ in pairs(data) do
                if k ~= "_next" then n = n + 1 end
            end
            M.log("donor table received entries=" .. n)
        end
    end)
    Events.OnGameStart.Add(function()
        ModData.request(M.DONOR_KEY)
    end)
end

-- ── [서버/SP] 기동 검사 ──────────────────────────────────────────────────────

local function outfitSet(female)
    local set, n = {}, 0
    local ok, list = pcall(getAllOutfits, female)
    if not ok or not list then return nil, 0 end
    for i = 0, list:size() - 1 do
        set[list:get(i)] = true
        n = n + 1
    end
    return set, n
end

--- 구역 정의(ZombiesZoneDefinition) 정리.
--- 구역 정의가 없는 아웃핏 이름을 가리키면 엔진이 전체 아웃핏 중 무작위로 고른다
--- (ZombiesZoneDefinition.applyDefinition / getRandomOutfit -> OutfitManager.GetRandomOutfit).
--- 그 후보에 PongDuMutant_* 도 들어 있어 월드 좀비가 특좀이 될 수 있다. 바닐라에도
--- 그런 항목이 있다(B42.21: 성별 지정 없는 남성 전용 GuitarGuy·Hunter·스트리퍼, 없는 이름
--- StripperWhite, 여성판이 없는 Clubgoer gender=female). 폴백이 일어나지 않게 고친다:
---   성별 미지정인데 한쪽 성별에만 있는 이름 -> 그 성별로 지정
---   지정 성별에 없거나 어느 쪽에도 없는 이름 -> 항목 제거
--- Java 는 이 Lua 표를 첫 사용 때 읽는다(ZombiesZoneDefinition.dirty 초기 true).
function M.sanitizeZoneDefs()
    if M._zoneSanitized then return true end
    local zzd = ZombiesZoneDefinition
    if type(zzd) ~= "table" then
        M.log("zone defs: ZombiesZoneDefinition table missing, skipped")
        return false
    end
    local fem, nf = outfitSet(true)
    local mal, nm = outfitSet(false)
    if not fem or not mal or nf == 0 or nm == 0 then
        M.log("zone defs: outfit list not ready (female=" .. tostring(nf) .. " male=" .. tostring(nm) .. "), skipped")
        return false
    end
    local fixes, removes = {}, {}
    for zoneName, zone in pairs(zzd) do
        if type(zone) == "table" then
            for key, e in pairs(zone) do
                if type(e) == "table" and type(e.name) == "string" then
                    local g = type(e.gender) == "string" and string.lower(e.gender) or ""
                    local inF, inM = fem[e.name] == true, mal[e.name] == true
                    if g == "male" then
                        if not inM then removes[#removes + 1] = { zone, key, zoneName, e.name, "no male outfit" } end
                    elseif g == "female" then
                        if not inF then removes[#removes + 1] = { zone, key, zoneName, e.name, "no female outfit" } end
                    elseif not inF and not inM then
                        removes[#removes + 1] = { zone, key, zoneName, e.name, "no outfit" }
                    elseif not inF then
                        fixes[#fixes + 1] = { e, "male", zoneName }
                    elseif not inM then
                        fixes[#fixes + 1] = { e, "female", zoneName }
                    end
                end
            end
        end
    end
    for i = 1, #fixes do
        local f = fixes[i]
        f[1].gender = f[2]
        M.log("zone defs: " .. tostring(f[3]) .. "." .. tostring(f[1].name) .. " gender -> " .. f[2])
    end
    for i = 1, #removes do
        local r = removes[i]
        r[1][r[2]] = nil
        M.log("zone defs: removed " .. tostring(r[3]) .. "." .. tostring(r[4]) .. " (" .. r[5] .. ")")
    end
    M.log("zone defs sanitized: genderFixed=" .. #fixes .. " removed=" .. #removes
        .. " outfits female=" .. nf .. " male=" .. nm)
    M._zoneSanitized = true
    return true
end

--- 아웃핏 목록 지문. 월드를 만든 뒤 아웃핏 목록(모드 추가·삭제, 게임 업데이트)이 바뀌면
--- 번호가 밀려 저장된 좀비 일부가 다른 아웃핏(특좀 포함)으로 바뀐다. 감지만 하고 크게 기록한다.
local function hashNames(list, h)
    for i = 0, list:size() - 1 do
        local s = list:get(i)
        for j = 1, string.len(s) do
            h = h * 31 + string.byte(s, j)
            h = h - math.floor(h / 2147483647) * 2147483647
        end
        h = h * 31 + 124
        h = h - math.floor(h / 2147483647) * 2147483647
    end
    return h
end

function M.checkOutfitFingerprint()
    local okF, fl = pcall(getAllOutfits, true)
    local okM, ml = pcall(getAllOutfits, false)
    if not okF or not okM or not fl or not ml or fl:size() == 0 or ml:size() == 0 then
        M.log("outfit fingerprint: outfit list not ready, skipped")
        return
    end
    local h = hashNames(ml, hashNames(fl, 7))
    local fp = tostring(fl:size()) .. "/" .. tostring(ml:size()) .. "/" .. tostring(h)
    local t = ModData.getOrCreate("PongDuOutfitPrint")
    local prev = t["fp"]
    if prev == nil then
        t["fp"] = fp
        M.log("outfit fingerprint stored " .. fp)
    elseif prev ~= fp then
        M.log("WARNING outfit list changed since this world was created (was " .. tostring(prev)
            .. " now " .. fp .. "). Outfit indices shifted: saved zombies may wear other outfits and"
            .. " ordinary zombies may have become PongDu mutants. Keep the mod list and game version"
            .. " fixed for the season, or reset the world.")
    else
        M.log("outfit fingerprint ok " .. fp)
    end
end

--- 이전 추적 방식이 남긴 글로벌 ModData 정리 (1회성, 남아 있을 때만)
function M.removeLegacyKeys()
    local keys = { "PuppetMutants", "PongDuMutantLost", "PongDuMutantLive" }
    for i = 1, #keys do
        if ModData.exists(keys[i]) then
            ModData.remove(keys[i])
            M.log("removed legacy global moddata " .. keys[i])
        end
    end
end

-- getAllOutfits 는 ModelManager.create() 를 부른다(이미 만들어졌으면 no-op, 전용 서버는 그래픽 생략).
-- OnGameBoot(SP 메인 메뉴)에서는 부르지 않고 월드 초기화 때 한 번에 한다.
if not isClient() then
    Events.OnInitGlobalModData.Add(function()
        M.sanitizeZoneDefs()
        M.removeLegacyKeys()
        M.checkOutfitFingerprint()
        ModData.getOrCreate(M.DONOR_KEY)
    end)
end
