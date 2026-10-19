-- t3MedicalBox: medical_box donation feature (server-tier).
--
-- The donation itself grants one box to EVERY connected player (see
-- server/PongDuMedBoxServer.lua + client/features/medicalbox.lua). This file
-- only handles what happens when a box is opened: grant every enabled
-- item (4 syringes + Zomboxivir vaccine) from t3_rewards_items.txt at once
-- (no random pick anymore).
--
-- The grant happens per box, wherever the craftRecipe OnCreate runs: the
-- local process in SP, the SERVER in MP (B42 ISHandcraftAction.performRecipe
-- only runs when not isClient(); see shared/t3RecipeUtil.lua). The sandbox options
-- (PongDu.MedBox_Allow_*, read at open time, never cached) decide which
-- items are included; toggling one off in-session takes effect on the
-- next box opened.
--
-- Global table (no module return) so the craftRecipe OnCreate can resolve
-- "t3MedicalBox.OpenBox" (craftRecipe PongDuOpenMedicalBox in
-- t3_rewards_items.txt). Same pattern as t3RandomWeapon / t3VehicleDrop.

t3MedicalBox = t3MedicalBox or {}

local LOG = "[PongDu][MedicalBox] "

local MODULE = "t3chzzkDonation."

-- item: script item name (module prefix added at grant time)
-- option: sandbox option suffix under SandboxVars.PongDu (boolean toggle)
--
-- Zomboxivir is the same item the standalone "vaccine" donation grants
-- (rewardManager.lua giveSupply("Zomboxivir", ...)); here it's just another
-- pool entry, gated by its own MedBox_Allow_Vaccine toggle independent of
-- the standalone vaccine donation.
t3MedicalBox.ITEMS = {
    { item = "Syringe_Adrenaline",  option = "MedBox_Allow_Adrenaline"  },
    { item = "Syringe_Doxycycline", option = "MedBox_Allow_Doxycycline" },
    { item = "Syringe_Morphine",    option = "MedBox_Allow_Morphine"    },
    { item = "Syringe_Emergency",   option = "MedBox_Allow_Emergency"   },
    { item = "Zomboxivir",          option = "MedBox_Allow_Vaccine"     },
}

-- Every medbox item enabled in the sandbox options. Read here (use time), not
-- at file load, so mid-session changes take effect immediately. Returns a
-- list of bare item names (empty when all five are off).
function t3MedicalBox.rollAll()
    local pool = {}
    for _, entry in ipairs(t3MedicalBox.ITEMS) do
        if SandboxVars.PongDu[entry.option] then
            table.insert(pool, entry.item)
        end
    end

    if #pool == 0 then
        print(LOG .. "open aborted: every medbox item is disabled in sandbox options")
    end

    return pool
end

-- craftRecipe OnCreate handler ---------------------------------------------
-- B42 signature: (craftRecipeData, character). Grants every currently-enabled
-- medbox item (syringes + vaccine) at once, synced to the owning client.
function t3MedicalBox.OpenBox(craftRecipeData, player)
    if not player then
        print(LOG .. "OpenBox aborted: player is nil")
        return
    end

    local pool = t3MedicalBox.rollAll()
    if #pool == 0 then return end

    local donor = t3RecipeUtil.findDonor(craftRecipeData)
    local grantedTypes = {}

    for _, itemType in ipairs(pool) do
        if t3RecipeUtil.addItem(player, MODULE .. itemType, donor) then
            table.insert(grantedTypes, itemType)
        else
            print(LOG .. "ERROR: AddItem failed for " .. MODULE .. itemType)
        end
    end

    print(LOG .. "box opened: items=" .. table.concat(grantedTypes, ",") .. ", donor=" .. tostring(donor)
        .. ", server=" .. tostring(isServer()))
end
