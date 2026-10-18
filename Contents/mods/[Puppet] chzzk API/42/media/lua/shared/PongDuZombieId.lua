--- PongDuZombieId -- stable per-zombie identity for PongDu (B42)
---
--- Why this exists:
---   persistentOutfitID bit 16 (value 32768) is the "fallen hat" flag.
---   Engine reference -- zombie/PersistentOutfits.java:
---       public boolean isHatFallen(int outfitID) { return (outfitID & 32768) != 0; }
---       setFallenHat(): outfitID |= 32768  /  outfitID &= -32769
---   The engine flips that bit when a hat falls off, which would change the
---   zombie's id in the middle of its life and break every modData lookup
---   keyed on it. We mask the bit out so the id stays stable.
---
---   PersistentOutfits is NOT exposed to Lua in B42, so isHatFallen() cannot
---   be called directly and the mask is reproduced here.
---   java.lang.Long IS exposed (LuaManager.java:1695 setExposed(Long.class)),
---   so Long.toUnsignedString / Long.parseUnsignedLong are safe to call.
---
--- Ported from HitmanUtils.GetZombieID (B41) when the Hitman module was
--- dropped from the B42 build.

PongDuZombieId = PongDuZombieId or {}

local idcache = {}

local function toBits(num)
    local bits = string.split(string.reverse(Long.toUnsignedString(num, 2)), "")
    while #bits < 16 do bits[#bits + 1] = "0" end
    return bits
end

local function toDec(bits)
    return Long.parseUnsignedLong(string.reverse(table.concat(bits, "")), 2)
end

--- Stable id for a zombie, with the fallen-hat bit cleared.
--- Memoized: this runs per zombie in hot paths (OnZombieUpdate, sweeps).
function PongDuZombieId.Get(character)
    if not character then return nil end

    local dec = character:getPersistentOutfitID()
    local id = idcache[dec]
    if id then return id end

    local bits = toBits(dec)
    if bits[16] == "1" then
        bits[16] = "0"
        id = toDec(bits)
    else
        id = dec
    end

    idcache[dec] = id
    return id
end

--- String form, which is what modData keys use.
function PongDuZombieId.GetString(character)
    local id = PongDuZombieId.Get(character)
    if id == nil then return nil end
    return tostring(id)
end
