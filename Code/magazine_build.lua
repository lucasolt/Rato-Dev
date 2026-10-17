local magazineData = {
    -- {
    --     id = "B93RR_1",
    --     magsize = 20,
    --     mag_mod = "MagNormal",
    --     ancestor_id = "GlockMagazine",
    --     generate_extended = true
    -- }, {
    --     id = "USP_1",
    --     magsize = 12,
    --     mag_mod = "MagNormal",
    --     ancestor_id = "GlockMagazine",
    --     custom_icon = 'Mod/Dau6w/Images/usp_mag_def.png',
    --     generate_extended = true,
    --     extended_custom_icon = 'Mod/Dau6w/Images/usp_mag_ex.png'
    -- }, {
    --     id = "VikingMP446_1",
    --     magsize = 10,
    --     mag_mod = "MagNormal",
    --     ancestor_id = "GlockMagazine",
    --     generate_extended = true
    -- }, {
    --     id = "PKM_1",
    --     magsize = 100,
    --     mag_mod = "MagLarger",
    --     ancestor_id = "HKG3MagazineLarger",
    --     custom_icon = 'Mod/Dau6w/Images/pkm_mag_def.png'
    -- }, {id = "RPD_1", magsize = 100, mag_mod = "MagLarger", ancestor_id = "AK47MagazineMagLarger"},
    -- {id = "P90_2", magsize = 50, mag_mod = "MagNormal", ancestor_id = "MP5MagazineLarge"}, {
    --     id = "Gewehr43_1",
    --     magsize = 10,
    --     mag_mod = "MagNormal",
    --     ancestor_id = "SVDMagazine",
    --     generate_extended = true
    -- }, {
    --     id = "P08_1",
    --     magsize = 8,
    --     mag_mod = "MagNormal",
    --     ancestor_id = "GlockMagazine",
    --     generate_extended = true
    -- }, {
    --     id = "M1911_1",
    --     magsize = 7,
    --     mag_mod = "MagNormal",
    --     ancestor_id = "DesertEagleMagazine",
    --     generate_extended = true,
    --     extended_custom_icon = 'Mod/Dau6w/Images/M1911_Mag_ext.png'
    -- }, {id = "M76_1", magsize = 10, mag_mod = "MagNormal", ancestor_id = "MP5Magazine"},
    -- {id = "MAC11_1", magsize = 32, mag_mod = "MagNormal", ancestor_id = "MP40Magazine"}, {
    --     id = "MicroUZI_1",
    --     magsize = 20,
    --     mag_mod = "MagNormal",
    --     ancestor_id = "UZIMagazine",
    --     generate_extended = true,
    --     extended_custom_icon = 'Mod/Dau6w/Images/MicroUZI_Mag_ext.png'
    -- }, {
    --     id = "PP91_1",
    --     magsize = 20,
    --     mag_mod = "MagNormal",
    --     ancestor_id = "MP5Magazine",
    --     generate_extended = true
    -- }, {id = "VigM2_1", magsize = 32, mag_mod = "MagNormal", ancestor_id = "MP40Magazine"},
    -- {id = "Delisle_1", magsize = 7, mag_mod = "MagNormal", ancestor_id = "DesertEagleMagazine"}, {
    --     id = "SSG69_1",
    --     magsize = 5,
    --     mag_mod = "MagNormal",
    --     ancestor_id = "SVDMagazine",
    --     custom_icon = 'Mod/KKh3Yhf/Images/SSG69_Mag_def_icon.png',
    --     generate_extended = true
    -- }, -- { id = "HK23ECamo_1", magsize = 100, mag_mod = "MagLarger", ancestor_id = "HKG3MagazineLarger" },
    -- {
    --     id = "HK23E_1",
    --     magsize = 100,
    --     mag_mod = "MagLarger",
    --     ancestor_id = "HKG3MagazineLarger",
    --     shared_weapons_id_table = {"HK23ECamo_1"}
    -- }, {
    --     id = "SteyrScout_1",
    --     magsize = 5,
    --     mag_mod = "MagNormal",
    --     ancestor_id = "SVDMagazine",
    --     custom_icon = 'Mod/Dau6w/Images/Scout_mag_def.png'
    -- }, {
    --     id = "StenMK2_1",
    --     magsize = 32,
    --     mag_mod = "MagNormal",
    --     ancestor_id = "MP40Magazine",
    --     custom_icon = 'Mod/Dau6w/Images/Sten_mag_def.png'
    -- }, {id = "STG44R_1", magsize = 30, mag_mod = "MagNormal", ancestor_id = "AK47Magazine"}, {
    --     id = "UMP_1",
    --     magsize = 30,
    --     mag_mod = "MagNormal",
    --     ancestor_id = "MP40Magazine",
    --     custom_icon = 'Mod/Dau6w/Images/UMP_mag_def.png'
    -- },
    -- {id = "AR10std", magsize = 20, mag_mod = "MagNormal", ancestor_id = "FNFALMagazine"},
    ---- ext_comp: the extended component when its id has no "ext" in it
    {id = "A91_2", magsize = 30, mag_mod = "MagNormal", ancestor_id = "AK74Magazine", generate_extended = true},
    {
        id = "G11_1",
        magsize = 45,
        mag_mod = "MagNormal",
        ancestor_id = "AUGMagazine",
        generate_extended = true,
        drum = {comp = "G11_Mag_ext2_1", ancestor_id = "G36MagazineLarger"}
    },
    {
        id = "M24Sniper",
        magsize = 5,
        mag_mod = "MagNormal",
        ancestor_id = "M14Magazine",
        generate_extended = true,
        ext_comp = "MagLarge"
    }

}

function check_expandedmag()
    for _, entry in pairs(magazineData) do
        -- print(entry.id)
        local w = g_Classes[entry.id]

        -- print("weapon", w and true or false)
        local slots = w.ComponentSlots
        -- print("slots", slots and true or false)
        local comp
        for i, slot in ipairs(slots) do
            if slot.SlotType == "Magazine" then
                comp = slot
                break
            end
        end
        local ext_mag_id
        if comp then
            for i, v in ipairs(comp.AvailableComponents) do
                if string.find(v, "ext") then
                    ext_mag_id = v
                    break
                end
            end
        end

        print(entry.id, ext_mag_id)
    end
end

local function BuildMagazineItemRATRVE(id, magsize, mag_mod, ancestor_id, custom_icon,
                                       shared_weapons_id_table, generate_extended,
                                       extended_custom_icon, InventoryItem_table,
                                       WeaponComponentVisual_table, RevMagWeaponSetup_table,
                                       PosClass_table, ext_comp, drum)
    local w = g_Classes[id]

    local slots = w.ComponentSlots
    local comp
    for i, slot in ipairs(slots) do
        if slot.SlotType == "Magazine" then
            comp = slot
            break
        end
    end

    if not comp then
        return
    end

    local df_mag_id = comp.DefaultComponent

    local mag_comp = WeaponComponents[df_mag_id]

    local function get_entity_and_icon(component, custom_icon_override)
        local entity, icon
        local visual = component.Visuals[table.find(component.Visuals, "ApplyTo", id)]
        ---- ToG mag components often carry one generic visual (ApplyTo false) instead of one per gun
        visual = visual or component.Visuals[table.find(component.Visuals, "ApplyTo", false)]
        if visual then
            entity = visual.Entity
            icon = visual.Icon
        end

        if not icon or icon == "" then
            icon = component.Icon
        end

        if custom_icon_override then
            icon = custom_icon_override
        end

        return entity, icon
    end

    local entity, icon = get_entity_and_icon(mag_comp, custom_icon)

    local mag_class = IsKindOf(w, "Pistol") and "PistolMag" or
                          IsKindOfClasses(w, "AssaultRifle", 'SniperRifle') and "RifleMag" or
                          IsKindOf(w, "SubmachineGun") and "SmgMag" or "LargeMag"

    --- Tog defines B93 as smg
    mag_class = IsKindOf(w, "B93RR_1") and "PistolMag" or mag_class

    local ancestor = g_Classes[ancestor_id]

    local cal = FindPreset("Caliber", w.Caliber)
    cal = cal and (cal.Name[2] or _InternalTranslate(cal.Name)) or ""
    local wepname = w.DisplayName[2] or _InternalTranslate(w.DisplayName)

    ----- Helpers

    local function generate12DigitRandom()
        return math.random(100000, 999999) * 1000000 + math.random(100000, 999999)
    end

    local function generate_tabua(mag_item_id, mag_class, icon, displayName, displayNamePlural,
                                  description, add_hint, platform, magsize, cal, mag_mod, ancestor)
        return {
            Group = "Default",
            Id = mag_item_id,
            object_class = mag_class,
            ScrapParts = ancestor.ScrapParts,
            Repairable = ancestor.Repairable,
            Icon = icon,
            DisplayName = displayName,
            DisplayNamePlural = displayNamePlural,
            Description = description,
            AdditionalHint = add_hint,
            Cost = ancestor.Cost,
            CanAppearInShop = ancestor.CanAppearInShop,
            Tier = w.Tier,
            RestockWeight = ancestor.RestockWeight,
            CanBeConsumed = ancestor.CanBeConsumed,
            CategoryPair = ancestor.CategoryPair,
            Platform = platform,
            MagazineSize = magsize,
            Caliber = w.Caliber,
            Modification = mag_mod,
            Type = ancestor.Type,
            Weight = ancestor.Weight,
            ExtraAPCosts = ancestor.ExtraAPCosts,
            MagReloadCosts = ancestor.MagReloadCosts,
            MagUnloadCosts = ancestor.MagUnloadCosts,
            PocketL_amount = ancestor.PocketL_amount,
            PocketM_amount = ancestor.PocketM_amount,
            PocketML_amount = ancestor.PocketML_amount,
            PocketS_amount = ancestor.PocketS_amount,
            RifleMag_amount = ancestor.RifleMag_amount,
            PistolMag_amount = ancestor.PistolMag_amount,
            PistolHolster_amount = ancestor.PistolHolster_amount,
            KnifeSheath_amount = ancestor.KnifeSheath_amount,
            Carabiner_amount = ancestor.Carabiner_amount
        }
    end

    local function generate_visual_tabua(id, entity, icon)
        return {
            ApplyTo = id,
            Entity = entity or 'placeholder_7',
            Icon = icon,
            Slot = "Magazine",
            param_bindings = false
        }
    end

    local function print_code_for_itemsdotlua(tabua) -- n
        print("PlaceObj('ModItemInventoryItemCompositeDef', {")
        for key, value in pairs(tabua) do
            local formattedValue
            if type(value) == "string" and value:sub(1, 2) == "T(" then
                formattedValue = value
            elseif type(value) == "string" then
                formattedValue = string.format("'%s'", value)
            else
                formattedValue = tostring(value)
            end
            print(string.format("\t'%s', %s,", key, formattedValue))
        end
        print("}),")
    end

    local function generate_visual_code(tabua)
        local lines = {}
        table.insert(lines, "\tPlaceObj('WeaponComponentVisual',{")

        for key, value in pairs(tabua) do
            local formattedValue
            if type(value) == "string" then
                formattedValue = string.format('"%s"', value)
            elseif type(value) == "boolean" or type(value) == "number" then
                formattedValue = tostring(value)
            else
                formattedValue = tostring(value)
            end
            table.insert(lines, string.format("\t\t%s = %s,", key, formattedValue))
        end

        table.insert(lines, "\t}),")
        return table.concat(lines, "\n")
    end

    local function generate_setup_message(id, platform, mag_item_id, mag_mod_table)
        -- Format the modification table into a string
        local formattedMods = {}
        for _, mod in ipairs(mag_mod_table) do
            table.insert(formattedMods, string.format("'%s'", mod))
        end
        local mods_str = table.concat(formattedMods, ", ")

        -- Return the formatted setup message
        return string.format("REV_SetupWeapon(%s, '%s', '%s', '%s', { %s })", id, platform,
                             mag_item_id, mag_mod_table[1], mods_str)
    end

    local function generate_class_code(tabua)
        local lines = {}

        -- Undefine and DefineClass header
        table.insert(lines, string.format("UndefineClass('%s')", tabua.Id))
        table.insert(lines, string.format("DefineClass.%s = {", tabua.Id))

        -- Add __parents
        table.insert(lines, string.format("\t__parents = {\"%s\"},", tabua.object_class))

        table.insert(lines, '\t__generated_by_class = "ModItemInventoryItemCompositeDef",\n')

        -- Add properties
        for key, value in pairs(tabua) do
            local formattedValue
            if type(value) == "string" and value:sub(1, 2) == "T(" then
                formattedValue = value
            elseif type(value) == "string" then
                formattedValue = string.format('"%s"', value)
            elseif type(value) == "boolean" then
                formattedValue = tostring(value)
            else
                formattedValue = tostring(value)
            end

            table.insert(lines, string.format("\t%s = %s,", key, formattedValue))
        end

        -- Close the class definition
        table.insert(lines, "}")

        return table.concat(lines, "\n")
    end

    ----- 

    local displayName = "T(" .. generate12DigitRandom() .. "," .. "'" .. wepname .. " Magazine" ..
                            "'" .. ")"
    local displayNamePlural = "T(" .. generate12DigitRandom() .. "," .. "'" .. wepname ..
                                  " Magazines" .. "'" .. ")"
    local description =
        "T(" .. generate12DigitRandom() .. "," .. "'" .. wepname .. " Magazine for " .. cal ..
            " rounds" .. "'" .. ")"
    local add_hint = "T(" .. generate12DigitRandom() .. "," .. "'" .. cal .. "'" .. ")"

    local platform = id .. "_" .. w.Caliber

    local mag_item_id = id .. "_Magazine"

    ----- Main Mag Inventory Item
    local tabua = generate_tabua(mag_item_id, mag_class, icon, displayName, displayNamePlural,
                                 description, add_hint, platform, magsize, cal, mag_mod, ancestor)

    table.insert(PosClass_table, mag_item_id)
    ----- Optional Extended Magazine processing
    local displayName_ex, displayNamePlural_ex, description_ex, mag_item_id_ex, mag_comp_ext,
          ext_mag_id, ex_tabua, entity_ex, icon_ex, ex_mag_mod, ex_ancestor, ex_visual_tabua,
          ex_magsize

    if generate_extended then
        ext_mag_id = ext_comp
        for i, v in ipairs(ext_comp and empty_table or comp.AvailableComponents) do
            if string.find(v, "ext") then
                ext_mag_id = v
                break
            end
        end

        if ext_mag_id then
            mag_comp_ext = WeaponComponents[ext_mag_id]
        end

        ex_ancestor = g_Classes[ancestor_id .. "Large"] or ancestor

        if mag_comp_ext then
            entity_ex, icon_ex = get_entity_and_icon(mag_comp_ext, extended_custom_icon)

            local mul = 150
            for _, param in ipairs(mag_comp_ext.Parameters) do
                if param.Name == "MagazineSizeMultiplier" then
                    mul = param.Value
                    break
                end
            end

            ex_magsize = MulDivRound(magsize, mul, 100)
            ex_mag_mod = mag_mod == "MagLarge" and "MagLarger" or
                             (mag_mod == "MagSmall_GBOTOG" or mag_mod == "MagSmall_GBO" or mag_mod ==
                                 "MagSmall") and "MagNormal" or "MagLarge"

            displayName_ex = "T(" .. generate12DigitRandom() .. "," .. "'" .. wepname ..
                                 " Extended Magazine" .. "'" .. ")"
            displayNamePlural_ex = "T(" .. generate12DigitRandom() .. "," .. "'" .. wepname ..
                                       " Extended Magazines" .. "'" .. ")"
            description_ex = "T(" .. generate12DigitRandom() .. "," .. "'" .. wepname ..
                                 " Extended Magazine for " .. cal .. " rounds" .. "'" .. ")"
            mag_item_id_ex = id .. "_MagazineLarge"

            ex_tabua = generate_tabua(mag_item_id_ex, mag_class, icon_ex, displayName_ex,
                                      displayNamePlural_ex, description_ex, add_hint, platform,
                                      ex_magsize, cal, ex_mag_mod, ex_ancestor)
            ex_visual_tabua = generate_visual_tabua(id, entity_ex, icon_ex)
            table.insert(PosClass_table, mag_item_id_ex)
        end
    end

    local visual_tabua = generate_visual_tabua(id, entity, icon)

    if not WeaponComponentVisual_table[mag_mod] then
        WeaponComponentVisual_table[mag_mod] = {}
    end

    table.insert(WeaponComponentVisual_table[mag_mod], generate_visual_code(visual_tabua))

    -----
    table.insert(InventoryItem_table, generate_class_code(tabua))

    -- print_code_for_itemsdotlua(tabua)

    local possible_mods = {mag_mod}

    if generate_extended and ex_mag_mod and ext_mag_id then
        -- print_code_for_itemsdotlua(ex_tabua)
        table.insert(InventoryItem_table, generate_class_code(ex_tabua))

        -- Ensure the WeaponComponentVisual_table is set for the extended item ID
        WeaponComponentVisual_table[ex_mag_mod] = WeaponComponentVisual_table[ex_mag_mod] or {}
        table.insert(WeaponComponentVisual_table[ex_mag_mod], generate_visual_code(ex_visual_tabua))

        table.insert(possible_mods, ex_mag_mod)
    end

    ---- drum = {comp = component id, ancestor_id = class}: a third size, inserted as MagLarger
    local drum_comp = drum and WeaponComponents[drum.comp]
    if drum_comp then
        local drum_ancestor = g_Classes[drum.ancestor_id] or ancestor
        local entity_d, icon_d = get_entity_and_icon(drum_comp, drum.custom_icon)
        local mul = 300
        for _, param in ipairs(drum_comp.Parameters or empty_table) do
            if param.Name == "MagazineSizeMultiplier" then
                mul = param.Value
                break
            end
        end
        local drum_id = id .. "_MagazineLarger"
        local drum_tabua = generate_tabua(drum_id, "LargeMag", icon_d,
                                          "T(" .. generate12DigitRandom() .. ",'" .. wepname .. " Drum Magazine')",
                                          "T(" .. generate12DigitRandom() .. ",'" .. wepname .. " Drum Magazines')",
                                          "T(" .. generate12DigitRandom() .. ",'" .. wepname .. " Drum Magazine for " ..
                                              cal .. " rounds')", add_hint, platform,
                                          MulDivRound(magsize, mul, 100), cal, "MagLarger", drum_ancestor)
        table.insert(InventoryItem_table, generate_class_code(drum_tabua))
        table.insert(PosClass_table, drum_id)
        WeaponComponentVisual_table.MagLarger = WeaponComponentVisual_table.MagLarger or {}
        table.insert(WeaponComponentVisual_table.MagLarger,
                     generate_visual_code(generate_visual_tabua(id, entity_d, icon_d)))
        table.insert(possible_mods, "MagLarger")
    end

    -- Add REV_SetupWeapon message for the main item and extended mods if any
    local setup_message = generate_setup_message(id, platform, mag_item_id, possible_mods)
    table.insert(RevMagWeaponSetup_table, setup_message)

    if shared_weapons_id_table then
        for _, shared_id in ipairs(shared_weapons_id_table) do
            local setup_message = generate_setup_message(shared_id, platform, mag_item_id,
                                                         possible_mods)
            table.insert(RevMagWeaponSetup_table, setup_message)
        end
    end
end

function rat_buildmags()
    local InventoryItem_table = {}
    local RevMagWeaponSetup_table = {}
    local WeaponComponentVisual_table = {}
    local PosClass_table = {}

    for i, v in pairs(magazineData) do
        BuildMagazineItemRATRVE(v.id, v.magsize, v.mag_mod, v.ancestor_id, v.custom_icon,
                                v.shared_weapons_id_table, v.generate_extended,
                                v.extended_custom_icon, InventoryItem_table,
                                WeaponComponentVisual_table, RevMagWeaponSetup_table, PosClass_table,
                                v.ext_comp, v.drum)
    end

    -- Print the REV_SetupWeapon messages
    print("function OnMsg.RevisedMagPropsAddedToFirearms()")
    for _, setup_msg in ipairs(RevMagWeaponSetup_table) do
        print("		", setup_msg)
    end
    print("end")

    ------ Mag inventory Items
    print("function GBOTOG_RevMag_CreateMagazine()")
    print("if not IsMod_loaded('URkxyfE') then return end")
    for _, v in ipairs(InventoryItem_table) do
        print("		", v)
    end
    print("end")

    -- Print the WeaponComponentVisual_table
    print("local map = {")
    for key, visuals in pairs(WeaponComponentVisual_table) do
        print(string.format('["%s"] = {', key))
        for _, visual_code in ipairs(visuals) do
            print("	", visual_code)
        end
        print('},')
    end
    print("}")
    print([[function GBOTOG_RevMag_WeaponComponentVisualPatch()
		RatTOG_RevMag_ApplyMap(map)
	end]])

    print("function GBOTOG_RevMag_AddClassesToInventoryItemDefs()")
    print("local classes = {")
    for _, id in ipairs(PosClass_table) do
        print("'" .. id .. "',")
    end
    print("}")
    print("end")

end

