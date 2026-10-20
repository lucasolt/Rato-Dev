-- Live balance sheet: every live firearm with its default components, stats read through GBO's own math.
-- Getters mirror DESCRIPTION_HINTS_get.lua (locals there); keep them in step when the hints change.

local sheet_id = "idRatoWeaponSheet"
local csv_path = "AppData/RatoWeaponSheet.csv"
local samples = 64
local group_gap = 10
local cell_style = "PDAIMPContentTextSmall"
local char_w, cell_pad = 8, 3

local FullStats = {placeholder = true, Marksmanship = 100, Dexterity = 100, Agility = 100, Strength = 100}
local ClassOrder = {"AssaultRifle", "SubmachineGun", "MachineGun", "SniperRifle", "Rifle", "Shotgun", "Pistol", "Revolver"}
local ClassShort = {AssaultRifle = "Rifle", SubmachineGun = "SMG", MachineGun = "MG", SniperRifle = "SR", Rifle = "Rifle",
                    Shotgun = "SG", Pistol = "Pistol", Revolver = "Rev"}
local Stances = {"Standing", "Crouch", "Prone"}

local function WeaponClass(w)
    for _, c in ipairs(ClassOrder) do
        if IsKindOf(w, c) then return c end
    end
    return "Other"
end

-- HintChartShooter: a stand-in Unit the aperture and recoil chains accept
local function Shooter(weapon, owner, stance)
    local src = owner or FullStats
    local s = {placeholder = false, stance = stance}
    for _, k in ipairs{"Marksmanship", "Dexterity", "Agility", "Strength", "Wisdom", "Explosives"} do
        s[k] = src[k] or 100
    end
    s.GetActiveWeapons = function() return weapon end
    s.GetEquippedWeaponSlot = function() return false end
    s.GetEquippedWeapons = function() return {weapon} end
    s.IsMerc = function() return true end
    s.GetLevel = function() return 1 end
    s.GetStatusEffect = function(_, id) return owner and owner.GetStatusEffect and owner:GetStatusEffect(id) end
    s.HasStatusEffect = function(_, id) return owner and owner.HasStatusEffect and owner:HasStatusEffect(id) end
    return s
end

local State = {rows = false, sort = "Cls", desc = false, cls = false, merc = false, stance = 1, filter = "", no_scope = true, no_bipod = false,
               view = "overview", aim = 3, dist = 10}

local function Recoil(w, unit)
    local recoil = GetWepRecoil(w, unit, true) * GetCaliberStrRecoil(w, unit or FullStats)
    if unit then recoil = recoil * GetRecoilOther(w, unit, false) end
    return cRound(recoil * 100)
end

local function ModeRecoil(w, unit, delta_prop, bump)
    local net = MulDivRound(Recoil(w, unit), w[delta_prop] or 100, 100)
    if bump and w:HasComponent("recoil_bump") then
        net = cRound(net * const.Combat.Recoil.Components.RecoilBumpMul)
    end
    if unit and unit:HasStatusEffect("AutoWeapons") then
        net = cRound(net * const.Combat.Recoil.Perks.AutoWeaponsMul)
    end
    return net
end

local function HipSnap(w, aim, unit, shooter)
    local mul = cRound(GetWeaponHipfireOrSnapshotMul(w, false, false, true, aim) * 100)
    -- the unbraced bipod malus reads the shooter's stance, which the gun-alone call doesn't have
    if aim > 0 and Rat_BipodUnbraced(shooter, w) then
        mul = cRound(mul * const.Combat.Snapshot.Components.BipodUnbracedMul)
    end
    return unit and MulDivRound(mul, Rat_StepAttrMul(unit, nil, aim), 100) or mul
end

local function HandEyeScale(unit)
    local min, max = const.Combat.R_MinAimScaling, const.Combat.R_MaxAimScaling
    return Clamp(min + MulDivRound(max - min, rGetHandEyeCoordination(unit) - 10, 90), min, max)
end

local function PB(w, unit)
    local pb = GetPBbonus(w)
    if not unit then return pb end
    local scale = HandEyeScale(unit)
    if pb < 0 then scale = 150 - scale end
    return MulDivRound(pb, scale, 100)
end

-- aCTH aim per level, in hundredths
local function Aim(w, unit)
    local acc = MulDivRound(w.AimAccuracy * 100, GetApertureComponentAccMul(GetApertureAimComponentEffects(w, unit), 1), 100)
    return unit and MulDivRound(acc, Clamp(rGetHandEyeCoordination(unit), 10, 100), 100) or acc
end

local function StanceAP(w, unit)
    unit = unit or FullStats
    return MulDivRound(GetWeapon_StanceAP(unit, w, true), 1, const.Scale.AP) + MulDivRound(Get_AimCost(unit), 1, const.Scale.AP)
end

-- GetAPCost needs a spawned Unit; without one, the raw ShootAP
local function AttackAP(w, unit)
    local action = unit and CombatActions[w:GetBaseAttack(unit, true)]
    local ap = action and action:GetAPCost(unit, {weapon = w})
    if not ap or ap < 0 then ap = w.ShootAP or 0 end
    return MulDivRound(ap, 1, const.Scale.AP)
end

local function BurstModes(w)
    local burst = table.find(w.AvailableAttacks or empty_table, "BurstFire") and Rat_HasSelectiveBurst(w) and
                      not (IsKindOf(w, "AR15") and not w:HasComponent("Enable_BurstFire"))
    return burst and true or false, Rat_HasVariableAuto(w) and true or false
end

local function Sigma(w, shooter, action, aim)
    local _, bipod = Presets.ChanceToHitModifier.Default.Bipod:CalcValue(shooter, nil, nil, nil, w)
    return Max(1, MulDivRound(Rat_GetAperture(w, shooter, action, aim), Rat_ConeMulForPoints(bipod or 0), 100))
end

local function Theta(tiles)
    return Rat_ThetaTarget(tiles * const.SlabSizeX, const.Combat.Aperture.Silhouette.Standing)
end

local function ConeCTH(w, shooter, aim, tiles)
    local a = const.Combat.Aperture
    return Clamp(Rat_RayleighCTH(Theta(tiles), Sigma(w, shooter, nil, aim)), a.MinCTH, a.MaxCTH)
end

-- the attack each fire mode stands for; autofire at 3 rounds
local function ModeAction(w, kind)
    local burst, auto = BurstModes(w)
    if kind == "single" then
        return not w.AutoFireOnly and CombatActions.SingleShot, 1
    elseif kind == "burst" then
        local action = burst and CombatActions.BurstFire
        return action, action and w:GetAutofireShots(action)
    end
    return auto and Rat_AutoFireView(3, Rat_AutoAttackId(w)), 3
end

-- muzzle offset of the last round (3rd at most), arcmin; no cone, so it is the recoil walk alone
local function Drift(w, c, kind)
    local action, shots = ModeAction(w, kind)
    shots = Min(3, shots or 0)
    local prof = action and shots > 1 and Rat_RecoilProfile(c.shooter, action, w, shots)
    if not prof then return end
    return Rat_EstimateBurst(prof, nil, nil, shots, samples).offset[shots]
end

-- one fire mode at the sheet's aim and distance: {shots, sum of round CTH, expected damage, AP}, cached per row
local function ModeStats(w, c, kind)
    if c[kind] ~= nil then return c[kind] or nil end
    c[kind] = false
    local action, shots = ModeAction(w, kind)
    if not action then return end
    local a = const.Combat.Aperture
    local aim = Min(State.aim, w.MaxAimActions or 3)
    local sum = 0
    if kind == "single" then
        sum = ConeCTH(w, c.shooter, aim, State.dist)
    else
        local prof = Rat_RecoilProfile(c.shooter, action, w, shots)
        if not prof then return end
        local est = Rat_EstimateBurst(prof, Theta(State.dist), Sigma(w, c.shooter, action, aim), shots, samples)
        for i = 1, shots do
            sum = sum + Clamp(est.cth[i] or 0, a.MinCTH, a.MaxCTH)
        end
    end
    -- with aim, GetAPCost already adds the shooting stance and the aim levels
    local ap = c.ap_unit and action:GetAPCost(c.ap_unit, {weapon = w, aim = aim})
    ap = ap and ap > 0 and MulDivRound(ap, 1, const.Scale.AP) or nil
    c[kind] = {shots = shots, sum = sum, dmg = MulDivRound(sum, w.Damage or 0, 100), ap = ap}
    return c[kind]
end

local function Field(w, c, kind, key)
    local m = ModeStats(w, c, kind)
    return m and m[key]
end

-- damage per AP in hundredths
local function DmgPerAP(w, c, kind)
    local m = ModeStats(w, c, kind)
    return m and m.ap and MulDivRound(m.dmg * 100, 1, m.ap)
end

local function Cents(v)
    return string.format("%d.%02d", v / 100, v % 100)
end

local function Hundredths(v)
    return string.format("%d.%d", v / 100, abs(v) % 100 / 10)
end

-- {key, label, data chars, tip, get(w, ctx), lower = smaller is better, fmt, text = not colored, prop = greyed at its Firearm default}
local Groups = {
    {"Gun", {
        {"Id", "Id", 15, "Preset id", function(w) return w.class end, text = true},
        {"Name", "Name", 11, "Display name", function(w) return _InternalTranslate(w.DisplayName or "") end, text = true},
        {"Cls", "Class", 6, "Class", function(w) return ClassShort[WeaponClass(w)] or "?" end, text = true},
        {"Cal", "Caliber", 9, "Caliber", function(w) return w.Caliber or "" end, text = true},
        {"Src", "Src", 3, "V = vanilla, T = ToG patched", function(w) return w.is_tog_patched and "T" or "V" end, text = true},
    }},
    {"Damage", {
        {"Dmg", "Dmg", 4, "Damage, Basic ammo loaded", function(w) return w.Damage end},
        {"Crit", "Crit", 4, "CritChance, Basic ammo loaded", function(w) return w.CritChance end, prop = "CritChance"},
        {"CPA", "C/Aim", 4, "Crit chance per aim level (Rat_WeaponCritPerAim x Hand-Eye)",
         function(w, c) return MulDivRound(Rat_WeaponCritPerAim(w), c.unit and rGetHandEyeCoordination(c.unit) or 100, 100) end,
         fmt = Hundredths, prop = "CritPerAim"},
        {"Pen", "Pen", 4, "Penetration class, Basic ammo loaded", function(w) return Clamp(w.PenetrationClass, 1, #PenetrationClassIds) end},
    }},
    {"Accuracy", {
        {"Aim", "Aim", 5, "aCTH aim accuracy per level, components applied", function(w, c) return Aim(w, c.unit) end,
         fmt = function(v) return tostring(MulDivRound(v, 1, 100)) end},
        {"Hand", "Handl", 4, "Handling, effective points", function(w, c) return (Rat_HandlingEffectivePoints(w, c.unit)) end, prop = "Handling",
         shown = function() return IsACHTActive() end},
        {"AimH", "3Aim+H", 5, "(Aim x 3 + Handling) / 3: accuracy per aim level over 3 aim levels",
         function(w, c) return MulDivRound(Aim(w, c.unit) * 3 + Rat_HandlingEffectivePoints(w, c.unit) * 100, 1, 3) end,
         fmt = Hundredths, shown = function() return IsACHTActive() end},
        {"PB", "PB", 4, "Point blank bonus", function(w, c) return PB(w, c.unit) end,
         shown = function() return not IsACHTActive() end},
        {"Hip", "Hip%", 4, "Hipfire cone multiplier %", function(w, c) return HipSnap(w, 0, c.unit) end, lower = true},
        {"Snap", "Snap%", 4, "Snapshot cone multiplier %, unbraced bipod included (shooter not prone)",
         function(w, c) return HipSnap(w, 1, c.unit, c.shooter) end, lower = true},
        {"Rng", "Range", 4, "WeaponRange", function(w) return w.WeaponRange end, prop = "WeaponRange"},
    }},
    {"Kick (x100)", {
        {"Rec", "Single", 3, "Kick, the rollover's Recoil row: the gun's own push (aCTH KickMag), not the walk",
         function(w, c) return Recoil(w, c.unit) end, lower = true},
        {"BRec", "Burst", 4, "Selective burst kick",
         function(w, c) return (BurstModes(w)) and ModeRecoil(w, c.unit, "burst_recoil_delta", true) end, lower = true},
        {"ARec", "Auto", 4, "Autofire kick",
         function(w, c) return select(2, BurstModes(w)) and ModeRecoil(w, c.unit, "auto_recoil_delta") end, lower = true},
        {"RPM", "RPM", 5, "Rate of fire of burst and autofire: shortens the recovery between rounds (see Drift)", function(w)
            local burst, auto = BurstModes(w)
            return (burst or auto) and w.RPM
        end, prop = "RPM"},
    }},
    {"Drift", {
        {"BDrift", "Burst", 4, "Selective burst: how far the muzzle walked by the last round (3rd at most), arcmin. "
            .. "Kick, RPM, weight, Strength, stance and bipod; no cone", function(w, c) return Drift(w, c, "burst") end, lower = true},
        {"ADrift", "Auto", 4, "3-round autofire: how far the muzzle walked by the 3rd round, arcmin",
         function(w, c) return Drift(w, c, "auto") end, lower = true},
    }},
    {"AP", {
        {"AP", "Attk", 4, "Default attack AP (the selected merc prices it; else raw ShootAP)",
         function(w, c) return AttackAP(w, c.ap_unit) end, lower = true},
        {"SAP", "Stance", 4, "Shooting stance + one aim level AP, priced for the shooter (stat 100 clears Cumbersome)",
         function(w, c) return StanceAP(w, c.unit) end, lower = true},
        {"Cmb", "Cmb", 3, "Cumbersome: extra stance AP below Strength " .. const.Combat.CumbersomeStanceAP_StrThreshold,
         function(w) return w:IsCumbersome() and R_VanillaAPToDisplay(1) end, lower = true},
        {"RAP", "Rld", 4, "Reload AP", function(w) return MulDivRound(w.ReloadAP or 0, 1, const.Scale.AP) end, lower = true},
    }},
    {"Logistics", view = "overview", {
        {"Mag", "Mag", 4, "MagazineSize", function(w) return w.MagazineSize end},
        {"Noise", "Noise", 4, "Noise, Basic ammo loaded", function(w) return w.Noise end, lower = true},
        {"Rel", "Rel", 4, "Reliability", function(w) return w.Reliability end, prop = "Reliability"},
        {"Wt", "Kg", 4, "Weight, kg", function(w) return w.Weight end, lower = true, prop = "Weight",
         fmt = function(v) return string.format("%d.%d", v / 1000, v % 1000 / 100) end},
        {"Brl", "Brl", 4, "Effective barrel length, mm (components applied)",
         function(w) return (w.rat_barrel_len or 0) > 0 and Rat_EffectiveBarrelLength(w) end},
        {"Cost", "Cost", 6, "Cost", function(w) return w.Cost end, lower = true},
    }},
    {"Hit % (standing)", view = "overview", {
        {"H5", "Hip5", 4, "Hipfire (aim 0), 5 tiles", function(w, c) return ConeCTH(w, c.shooter, 0, 5) end},
        {"H10", "Hip10", 4, "Hipfire (aim 0), 10 tiles", function(w, c) return ConeCTH(w, c.shooter, 0, 10) end},
        {"A20", "Aim20", 4, "Full aim, 20 tiles (10 tiles saturates at MaxCTH)",
         function(w, c) return ConeCTH(w, c.shooter, w.MaxAimActions or 3, 20) end},
        {"A30", "Aim30", 4, "Full aim, 30 tiles", function(w, c) return ConeCTH(w, c.shooter, w.MaxAimActions or 3, 30) end},
        {"A40", "Aim40", 4, "Full aim, 40 tiles", function(w, c) return ConeCTH(w, c.shooter, w.MaxAimActions or 3, 40) end},
    }},
    {"Single", view = "autofire", {
        {"SDmg", "Dmg", 4, "Expected damage of one shot: hit chance x Damage (no crit, no armor)",
         function(w, c) return Field(w, c, "single", "dmg") end},
        {"S1AP", "AP", 4, "AP: attack + shooting stance + aim levels (selected merc prices it)",
         function(w, c) return Field(w, c, "single", "ap") end, lower = true},
        {"SDAP", "D/AP", 5, "Expected damage per AP", function(w, c) return DmgPerAP(w, c, "single") end, fmt = Cents},
    }},
    {"Burst", view = "autofire", {
        {"BRds", "Rds", 3, "Rounds per burst", function(w, c) return Field(w, c, "burst", "shots") end, text = true},
        {"BHits", "Hits", 4, "Expected hits: sum of each round's hit chance (cone + recoil walk)",
         function(w, c) return Field(w, c, "burst", "sum") end, fmt = Hundredths},
        {"BDmg", "Dmg", 4, "Expected damage: hits x Damage (no crit, no armor)",
         function(w, c) return Field(w, c, "burst", "dmg") end},
        {"BAP", "AP", 4, "AP: attack + shooting stance + aim levels (selected merc prices it)",
         function(w, c) return Field(w, c, "burst", "ap") end, lower = true},
        {"BDAP", "D/AP", 5, "Expected damage per AP", function(w, c) return DmgPerAP(w, c, "burst") end, fmt = Cents},
    }},
    {"Auto (3 rds)", view = "autofire", {
        {"AHits", "Hits", 4, "Expected hits: sum of each round's hit chance (cone + recoil walk)",
         function(w, c) return Field(w, c, "auto", "sum") end, fmt = Hundredths},
        {"ADmg", "Dmg", 4, "Expected damage: hits x Damage (no crit, no armor)",
         function(w, c) return Field(w, c, "auto", "dmg") end},
        {"AAP", "AP", 4, "AP: attack + shooting stance + aim levels (selected merc prices it)",
         function(w, c) return Field(w, c, "auto", "ap") end, lower = true},
        {"ADAP", "D/AP", 5, "Expected damage per AP", function(w, c) return DmgPerAP(w, c, "auto") end, fmt = Cents},
    }},
}

local Columns = {}
for gi, g in ipairs(Groups) do
    for _, col in ipairs(g[2]) do
        col.group = gi
        col.label = table.remove(col, 2)
        col.width = Max(#col.label, col[2]) * char_w + 2 * cell_pad
        Columns[#Columns + 1] = col
    end
end


-- hand-authored optics (SteyrS_Scope_1) carry no Scope trait, only the scope effects
local function IsScope(id)
    local def = id and WeaponComponents[id]
    if def and table.find(def.ModificationEffects or empty_table, "ScopeFloorReduction") then return true end
    local scopes = const.Combat.Aperture.ScopeTraits or empty_table
    for _, t in ipairs(id and id ~= "" and GBO_TraitsOf(id) or empty_table) do
        if scopes[t] and t ~= "Scope.Ironsight" then return true end
    end
end

local BipodEffects = {"bipod_penalty", "AccuracyBonusProne", "RecoilControlWhenProne"}

local function IsBipod(id)
    local effects = id and WeaponComponents[id] and WeaponComponents[id].ModificationEffects or empty_table
    for _, e in ipairs(BipodEffects) do
        if table.find(effects, e) then return true end
    end
end

-- part off: empty slot when allowed (or forced), else another option without it (`prefer` in the id first);
-- false when integral
local function StripPart(w, is_part, prefer, force)
    for _, slot in ipairs(w.ComponentSlots or empty_table) do
        local cur = w.components[slot.SlotType]
        if is_part(cur) then
            local pick = (slot.CanBeEmpty or force) and ""
            for _, id in ipairs(pick and empty_table or slot.AvailableComponents or empty_table) do
                if not is_part(id) and (not pick or prefer and id:find(prefer)) then pick = id end
            end
            if not pick then return false end
            w:SetWeaponComponent(slot.SlotType, pick)
        end
    end
    return true
end

local ApplyView

local function SelectedUnit()
    return IsKindOf(SelectedObj, "Unit") and SelectedObj or nil
end

local function ComputeRow(id, ctx)
    local w = PlaceInventoryItem(id)
    if not w then return end
    local kept_scope = ctx.no_scope and not StripPart(w, IsScope, "ron")
    if ctx.no_bipod then StripPart(w, IsBipod, nil, true) end
    local ammo = Rat_BasicAmmoClass(w)
    for _, mod in ipairs(ammo and ammo.Modifications or empty_table) do
        w:AddModifier("ammo", mod.target_prop, mod.mod_mul, mod.mod_add)
    end
    local c = {unit = ctx.unit, ap_unit = ctx.ap_unit, shooter = Shooter(w, ctx.unit, ctx.stance)}
    local row = {cls_order = table.find(ClassOrder, WeaponClass(w)) or 99, default = {}}
    for _, col in ipairs(Columns) do
        local ok, v = pcall(col[4], w, c)
        row[col[1]] = ok and v or nil
        if not ok then row.err = (row.err or "") .. col[1] .. " " end
        if col.prop and w[col.prop] == Firearm:GetDefaultPropertyValue(col.prop) then row.default[col[1]] = true end
    end
    if kept_scope then row.Id = row.Id .. "*" end
    DoneObject(w)
    return row
end

-- skins and variants of a gun already listed
local Duplicates = {Type56B_1 = true, Type56C_1 = true, Type56D_1 = true, HK23ECamo_1 = true, Papovka2SKS_1 = true}

local function Ids()
    local ids = {}
    ForEachPreset("InventoryItemCompositeDef", function(p)
        local cls = g_Classes[p.id]
        if Rat_IsLiveFirearm(cls) and not IsKindOfClasses(cls, "HeavyWeapon", "FlareGun") and not Duplicates[p.id] then
            ids[#ids + 1] = p.id
        end
    end)
    table.sort(ids)
    return ids
end

local function CellText(col, v)
    if v == nil or v == false then return "-" end
    if type(v) == "number" and col.fmt then return col.fmt(v) end
    return tostring(v)
end

local function Lerp(a, b, t)
    return a + MulDivRound(b - a, t, 1000)
end

local function ScaleColor(t)
    if t < 500 then
        t = t * 2
        return string.format("<color %d %d %d>", Lerp(215, 225, t), Lerp(95, 205, t), Lerp(85, 110, t))
    end
    t = (t - 500) * 2
    return string.format("<color %d %d %d>", Lerp(225, 120, t), Lerp(205, 215, t), Lerp(110, 120, t))
end

local function Compare(a, b)
    local key, desc = State.sort, State.desc
    local va, vb = a[key], b[key]
    if key == "Cls" then va, vb = a.cls_order, b.cls_order end
    if va == vb or type(va) ~= type(vb) then
        if va == vb or (va ~= nil) == (vb ~= nil) then return a.Id < b.Id end
        return va ~= nil
    end
    if desc then return va > vb end
    return va < vb
end

local function VisibleRows()
    local list = {}
    local filter = string.lower(State.filter or "")
    for _, r in ipairs(State.rows or empty_table) do
        local key = string.lower(r.Id .. " " .. (r.Name or "") .. " " .. (r.Cal or ""))
        if (not State.cls or r.Cls == State.cls) and (filter == "" or key:find(filter, 1, true)) then
            list[#list + 1] = r
        end
    end
    table.sort(list, Compare)
    return list
end

local function SetStatus(dlg, text)
    if dlg.idStatus then dlg.idStatus:SetText(text or "") end
end

local function row_default(r, col)
    return r.default and r.default[col[1]]
end

-- columns are one multi-line XText each, so the hovered row is found from the cursor's y
local function UpdateHover(dlg, pt)
    local hl, first, list_box = dlg.idHover, dlg.idCol1, dlg.idListBox
    local n = rawget(dlg, "rat_nrows") or 0
    rawset(dlg, "rat_last_pt", pt)
    local cb = first and first.content_box
    if not (hl and pt and cb and n > 0 and list_box.box:Point2DInside(pt)) then
        if hl then hl:SetVisible(false) end
        return
    end
    local line_h = cb:sizey() / n
    local idx = line_h > 0 and (pt:y() - cb:miny()) / line_h or -1
    if idx < 0 or idx >= n then
        hl:SetVisible(false)
        return
    end
    local area = dlg.idSheet.content_box
    hl:SetBox(area:minx(), cb:miny() + idx * line_h, area:sizex(), line_h)
    hl:SetVisible(true)
end

-- columns of the other CTH model are not built (aCTH: Handling; old CTH: PB)
local function Shown(col)
    return not col.shown or col.shown()
end

local function Render(dlg)
    local rows = VisibleRows()
    rawset(dlg, "rat_nrows", #rows)
    for i, col in ipairs(Columns) do
        if dlg["idCol" .. i] then
            local lo, hi
            if not col.text then
                for _, r in ipairs(rows) do
                    local v = r[col[1]]
                    if type(v) == "number" then lo, hi = Min(lo or v, v), Max(hi or v, v) end
                end
            end
            local lines = {}
            for k, r in ipairs(rows) do
                local v = r[col[1]]
                local s = CellText(col, v)
                if row_default(r, col) then
                    s = "<color 110 110 110>" .. s .. "</color>"
                elseif type(v) == "number" and lo and hi > lo then
                    local t = MulDivRound(v - lo, 1000, hi - lo)
                    s = ScaleColor(col.lower and 1000 - t or t) .. s .. "</color>"
                elseif k % 2 == 0 then
                    s = "<color 175 175 175>" .. s .. "</color>"
                end
                lines[k] = s
            end
            dlg["idCol" .. i]:SetText(table.concat(lines, "\n"))
            local head = dlg["idHead" .. i]
            head:SetTextColor(State.sort ~= col[1] and RGB(220, 220, 220) or State.desc and RGB(240, 190, 90) or RGB(120, 190, 240))
        end
    end
    SetStatus(dlg, string.format("%d/%d guns | %s %s | %s, %s%s", #rows, #(State.rows or empty_table),
        Columns[table.find(Columns, 1, State.sort)].label, State.desc and "desc" or "asc",
        State.merc and (SelectedUnit() and SelectedUnit().session_id or "no merc selected -> stat 100") or "stat 100",
        Stances[State.stance], SelectedUnit() and "" or " | select a merc to price AP"))
end

local recompute_delay = 700

local function StopThreads(dlg)
    for _, key in ipairs{"rat_delay", "rat_thread"} do
        local thread = rawget(dlg, key)
        if IsValidThread(thread) then DeleteThread(thread) end
        rawset(dlg, key, false)
    end
end

-- a run started from stale settings is dropped, not finished
local function Recompute(dlg)
    StopThreads(dlg)
    rawset(dlg, "rat_thread", CreateRealTimeThread(function()
        local unit = State.merc and SelectedUnit() or nil
        local ctx = {unit = unit, ap_unit = SelectedUnit(), stance = Stances[State.stance], no_scope = State.no_scope,
                     no_bipod = State.no_bipod}
        local ids, rows = Ids(), {}
        local t0 = RealTime()
        for i, id in ipairs(ids) do
            if dlg.window_state == "destroying" then return end
            rows[#rows + 1] = ComputeRow(id, ctx)
            if i % 4 == 0 then
                SetStatus(dlg, string.format("computing %d / %d ...", i, #ids))
                Sleep(1)
            end
        end
        State.rows = rows
        rawset(dlg, "rat_thread", false)
        Render(dlg)
        local errs = 0
        for _, r in ipairs(rows) do errs = errs + (r.err and 1 or 0) end
        if errs > 0 then
            SetStatus(dlg, dlg.idStatus:GetText() .. string.format("  |  %d rows with errors (see log)", errs))
            for _, r in ipairs(rows) do
                if r.err then print("RatoWeaponSheet", r.Id, "failed:", r.err) end
            end
        end
        print("RatoWeaponSheet computed", #rows, "guns in", RealTime() - t0, "ms")
    end))
end

-- knob presses wait for a pause, so cycling through options costs one run
local function RecomputeSoon(dlg)
    StopThreads(dlg)
    SetStatus(dlg, "waiting for more changes ...")
    rawset(dlg, "rat_delay", CreateRealTimeThread(function()
        Sleep(recompute_delay)
        rawset(dlg, "rat_delay", false)
        Recompute(dlg)
    end))
end

local function CsvCell(v)
    if v == nil or v == false then return "" end
    v = tostring(v)
    if v:find('[,"\n]') then v = '"' .. v:gsub('"', '""') .. '"' end
    return v
end

local function ExportCSV(dlg)
    local out = {}
    local head = {}
    local cols = {}
    for _, col in ipairs(Columns) do
        if Shown(col) then cols[#cols + 1] = col end
    end
    for i, col in ipairs(cols) do head[i] = col[1] end
    out[1] = table.concat(head, ",")
    for _, r in ipairs(VisibleRows()) do
        local cells = {}
        for i, col in ipairs(cols) do
            local v = r[col[1]]
            if type(v) == "number" and col.fmt then v = col.fmt(v) end
            cells[i] = CsvCell(v)
        end
        out[#out + 1] = table.concat(cells, ",")
    end
    local err = AsyncStringToFile(csv_path, table.concat(out, "\n"))
    SetStatus(dlg, err and ("export failed: " .. tostring(err)) or ("exported " .. (#out - 1) .. " rows to " .. csv_path))
end

local function Button(parent, text, on_press, props)
    local t = {
        Text = text,
        Translate = false,
        TextStyle = "SatelliteContextMenuText",
        Background = RGBA(60, 60, 60, 220),
        RolloverBackground = RGBA(120, 100, 50, 240),
        PressedBackground = RGBA(160, 130, 60, 255),
        Padding = box(8, 3, 8, 3),
        OnPress = on_press,
    }
    for k, v in pairs(props or empty_table) do t[k] = v end
    return XTextButton:new(t, parent)
end

local Distances = {5, 10, 15, 20, 30}

-- shows the view's groups; shading alternates over the visible ones only
ApplyView = function(dlg)
    local blocks = rawget(dlg, "rat_blocks")
    local n = 0
    for gi, g in ipairs(Groups) do
        local show = not g.view or g.view == State.view
        local shade = RGBA(0, 0, 0, 0)
        if show then
            n = n + 1
            if n % 2 == 0 then shade = RGBA(255, 255, 255, 12) end
        end
        for _, win in ipairs{blocks.head[gi], blocks.body[gi]} do
            win:SetVisible(show)
            win:SetBackground(shade)
        end
    end
end

local KnobIdle = RGBA(60, 60, 60, 220)
-- a knob off its usual setting gets its own color, so the active filters read at a glance
local KnobColors = {
    class = RGBA(150, 120, 40, 255),
    merc = RGBA(50, 90, 160, 255),
    stance = RGBA(110, 60, 140, 255),
    scope = RGBA(30, 115, 130, 255),
    bipod = RGBA(160, 75, 40, 255),
    view = RGBA(50, 125, 70, 255),
    aim = RGBA(130, 55, 80, 255),
    dist = RGBA(90, 100, 50, 255),
}

local function Knob(btn, text, active, color)
    btn:SetText(text)
    btn:SetBackground(active and color or KnobIdle)
    btn:SetTextColor(active and RGB(245, 245, 245) or TextStyles[btn.TextStyle].TextColor)
end

local function Build()
    local dlg = XWindow:new({
        Id = sheet_id,
        IdNode = true,
        Margins = box(16, 20, 16, 20),
        Padding = box(10, 8, 10, 8),
        Background = RGBA(12, 12, 12, 250),
        HandleMouse = true,
        ZOrder = 1000,
    }, terminal.desktop)
    dlg.OnShortcut = function(self, shortcut, ...)
        if shortcut == "Escape" or shortcut == "ButtonB" then self:Close() return "break" end
        return XWindow.OnShortcut(self, shortcut, ...)
    end

    local bar = XWindow:new({LayoutMethod = "HList", LayoutHSpacing = 6, Dock = "top"}, dlg)
    local title = XText:new({Translate = false, TextStyle = "SatelliteContextMenuText", VAlign = "center"}, bar)
    title:SetTextColor(RGB(230, 200, 120))
    title:SetText("WEAPON SHEET")
    local search = XEdit:new({
        Hint = "filter id / name / caliber",
        Translate = false,
        TextStyle = "SatelliteContextMenuText",
        MinWidth = 220,
        Background = RGBA(40, 40, 40, 255),
        FocusedBackground = RGBA(55, 55, 55, 255),
        Padding = box(4, 2, 4, 2),
        AutoSelectAll = true,
    }, bar)
    search:SetText(State.filter or "")
    search.OnTextChanged = function(self)
        State.filter = self:GetText()
        Render(dlg)
    end
    search.OnShortcut = function(self, shortcut, source, ...)
        if shortcut == "Escape" then self:SetFocus(false) return "break" end
        local r = XEdit.OnShortcut(self, shortcut, source, ...)
        return r or (#shortcut == 1 and "break") or nil
    end
    local cls_list = {false, "Rifle", "SMG", "MG", "SR", "SG", "Pistol", "Rev"}
    local cls_btn
    cls_btn = Button(bar, "Class: all", function()
        local i = (table.find(cls_list, State.cls) or 1) % #cls_list + 1
        State.cls = cls_list[i]
        Knob(cls_btn, "Class: " .. (State.cls or "all"), State.cls, KnobColors.class)
        Render(dlg)
    end)
    Knob(cls_btn, "Class: " .. (State.cls or "all"), State.cls, KnobColors.class)
    local merc_btn
    merc_btn = Button(bar, "", function()
        State.merc = not State.merc
        Knob(merc_btn, State.merc and "Shooter: selected merc" or "Shooter: stat 100", State.merc, KnobColors.merc)
        RecomputeSoon(dlg)
    end, {RolloverText = Untranslated("Stat 100 = the gun alone, like the rollover's grey bracket")})
    Knob(merc_btn, State.merc and "Shooter: selected merc" or "Shooter: stat 100", State.merc, KnobColors.merc)
    local stance_btn
    stance_btn = Button(bar, "", function()
        State.stance = State.stance % #Stances + 1
        Knob(stance_btn, "Stance: " .. Stances[State.stance], State.stance ~= 1, KnobColors.stance)
        RecomputeSoon(dlg)
    end, {RolloverText = Untranslated("Shooter stance for the CTH columns; the target is always standing")})
    Knob(stance_btn, "Stance: " .. Stances[State.stance], State.stance ~= 1, KnobColors.stance)
    local scope_btn
    scope_btn = Button(bar, "", function()
        State.no_scope = not State.no_scope
        Knob(scope_btn, State.no_scope and "Scopes: removed" or "Scopes: default", State.no_scope, KnobColors.scope)
        RecomputeSoon(dlg)
    end, {RolloverText = Untranslated("Removed: optics swapped for ironsights or an empty slot. Id* = optic can't come off")})
    Knob(scope_btn, State.no_scope and "Scopes: removed" or "Scopes: default", State.no_scope, KnobColors.scope)
    local bipod_btn
    bipod_btn = Button(bar, "", function()
        State.no_bipod = not State.no_bipod
        Knob(bipod_btn, State.no_bipod and "Bipods: removed" or "Bipods: default", State.no_bipod, KnobColors.bipod)
        RecomputeSoon(dlg)
    end, {RolloverText = Untranslated("Removed: every bipod slot emptied, fixed MG bipods included")})
    Knob(bipod_btn, State.no_bipod and "Bipods: removed" or "Bipods: default", State.no_bipod, KnobColors.bipod)
    Button(bar, "Recompute", function() Recompute(dlg) end)
    Button(bar, "Export CSV", function() ExportCSV(dlg) end,
        {RolloverText = Untranslated("Visible rows, current sort, to %AppData%/Jagged Alliance 3/RatoWeaponSheet.csv")})
    Button(bar, "Close", function() dlg:Close() end)

    local bar2 = XWindow:new({LayoutMethod = "HList", LayoutHSpacing = 6, Dock = "top", Margins = box(0, 6, 0, 0)}, dlg)
    local view_btn, aim_btn, dist_btn
    local function knob_texts()
        Knob(view_btn, State.view == "autofire" and "View: Autofire" or "View: Overview", State.view == "autofire",
             KnobColors.view)
        Knob(aim_btn, "Aim: " .. State.aim, State.aim ~= 3, KnobColors.aim)
        Knob(dist_btn, "Dist: " .. State.dist .. " tiles", State.dist ~= 10, KnobColors.dist)
    end
    view_btn = Button(bar2, "", function()
        State.view = State.view == "autofire" and "overview" or "autofire"
        knob_texts()
        ApplyView(dlg)
    end, {RolloverText = Untranslated("Overview: logistics and hit chance. Autofire: expected hits, damage and damage per AP")})
    aim_btn = Button(bar2, "", function()
        State.aim = (State.aim + 1) % 4
        knob_texts()
        RecomputeSoon(dlg)
    end, {RolloverText = Untranslated("Aim level of the Autofire view, capped by the gun's MaxAimActions")})
    dist_btn = Button(bar2, "", function()
        local i = table.find(Distances, State.dist) or 0
        State.dist = Distances[i % #Distances + 1]
        knob_texts()
        RecomputeSoon(dlg)
    end, {RolloverText = Untranslated("Target distance of the Autofire view; the target is always standing")})
    knob_texts()
    XText:new({Id = "idStatus", Translate = false, TextStyle = "SatelliteContextMenuText", VAlign = "center"}, bar2)
        :SetTextColor(RGB(200, 180, 120))

    local head = XWindow:new({LayoutMethod = "HList", LayoutHSpacing = group_gap, Dock = "top", Margins = box(0, 6, 0, 0),
                              Background = RGBA(30, 30, 30, 255)}, dlg)
    local list_box = XWindow:new({Id = "idListBox", Dock = "box", Clip = "self"}, dlg)
    XWindow:new({
        Id = "idHover",
        Dock = "ignore",
        Background = RGBA(230, 200, 120, 60),
        HandleMouse = false,
        Visible = false,
    }, list_box)
    XSleekScroll:new({Id = "idSheetScroll", Target = "idSheet", Dock = "right", Margins = box(4, 0, 0, 0), AutoHide = true}, list_box)
    local area = XScrollArea:new({
        Id = "idSheet",
        IdNode = false,
        VScroll = "idSheetScroll",
        LayoutMethod = "HList",
        LayoutHSpacing = group_gap,
        MouseWheelStep = 80,
    }, list_box)
    local head_groups, body_groups, head_blocks = {}, {}, {}
    rawset(dlg, "rat_blocks", {head = head_blocks, body = body_groups})
    for gi, g in ipairs(Groups) do
        local width = 0
        for _, col in ipairs(g[2]) do width = width + (Shown(col) and col.width or 0) end
        -- head and body blocks share one width so a long group label can't shift the columns under it
        local hg = XWindow:new({LayoutMethod = "VList", MinWidth = width, MaxWidth = width, FoldWhenHidden = true}, head)
        head_blocks[gi] = hg
        local label = XText:new({Translate = false, TextStyle = "SatelliteContextMenuText", HAlign = "center", Clip = "self", WordWrap = false}, hg)
        label:SetTextColor(RGB(230, 200, 120))
        label:SetText(g[1])
        XWindow:new({MinHeight = 1, MaxHeight = 1, Margins = box(4, 0, 4, 0), Background = RGBA(230, 200, 120, 90)}, hg)
        head_groups[gi] = XWindow:new({LayoutMethod = "HList"}, hg)
        body_groups[gi] = XWindow:new({LayoutMethod = "HList", MinWidth = width, MaxWidth = width, FoldWhenHidden = true}, area)
    end
    for i, col in ipairs(Columns) do
        if Shown(col) then
            local key = col[1]
            local btn = Button(head_groups[col.group], col.label, function()
                if State.sort == key then State.desc = not State.desc else State.sort, State.desc = key, not col.text end
                Render(dlg)
            end, {
                Id = "idHead" .. i,
                TextStyle = cell_style,
                MinWidth = col.width, MaxWidth = col.width,
                Padding = box(cell_pad, 2, cell_pad, 2),
                LayoutMethod = "Box",
                Background = RGBA(0, 0, 0, 0),
                RolloverText = Untranslated(col[3]),
            })
            btn.idLabel:SetHAlign(col.text and "left" or "right")
            XText:new({
                Id = "idCol" .. i,
                Translate = false,
                TextStyle = cell_style,
                MinWidth = col.width, MaxWidth = col.width,
                Padding = box(cell_pad, 0, cell_pad, 0),
                TextHAlign = col.text and "left" or "right",
                WordWrap = false,
                -- "self" would replace the list's clip rect, letting scrolled rows paint over the header
                Clip = "parent & self",
            }, body_groups[col.group]):SetTextColor(RGB(220, 220, 220))
        end
    end
    dlg.OnMousePos = function(self, pt)
        UpdateHover(self, pt)
    end
    dlg.OnMouseLeft = function(self, pt, child)
        UpdateHover(self, false)
        return XWindow.OnMouseLeft(self, pt, child)
    end
    area.DoScroll = function(self, x, y)
        local ret = XScrollArea.DoScroll(self, x, y)
        UpdateHover(dlg, rawget(dlg, "rat_last_pt"))
        return ret
    end
    ApplyView(dlg)
    dlg:Open()
    search:SetFocus()
    return dlg
end

function RatoWeaponSheet_Open()
    local old = terminal.desktop:ResolveId(sheet_id)
    if old then old:Close() return end
    local dlg = Build()
    if State.rows then Render(dlg) else Recompute(dlg) end
end

function OnMsg.Shortcuts(host)
    XAction:new({
        ActionId = "RatoWeaponSheet",
        ActionTranslate = false,
        ActionName = "Rato Weapon Sheet",
        ActionShortcut = "Ctrl-Shift-W",
        OnAction = function() RatoWeaponSheet_Open() end,
    }, host)
end
