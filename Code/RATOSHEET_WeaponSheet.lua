-- Live balance sheet: every live firearm with its default components, stats read through GBO's own math.
-- Getters mirror DESCRIPTION_HINTS_get.lua (locals there); keep them in step when the hints change.

local sheet_id = "idRatoWeaponSheet"
local samples = 64
local group_gap = 8
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
               view = "overview", aim = 3, dist = 10, auto = 3, stance_ap = true, collapsed = {}}

local function RecoilComps()
    return IsACHTActive() and Rat_RecoilComponentsACTH() or const.Combat.Recoil.Components
end

local function Recoil(w, unit)
    local comps = RecoilComps()
    local recoil = GetWepRecoil(w, unit, true, comps) * GetCaliberStrRecoil(w, unit or FullStats)
    if unit then recoil = recoil * GetRecoilOther(w, unit, false, nil, comps) end
    return cRound(recoil * 100)
end

local function ModeRecoil(w, unit, delta_prop, bump)
    local net = MulDivRound(Recoil(w, unit), w[delta_prop] or 100, 100)
    if bump and w:HasComponent("recoil_bump") then
        net = cRound(net * (Rat_FactoryRecoilEffects(w).recoil_bump and const.Combat.Recoil.Components or RecoilComps()).RecoilBumpMul)
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

-- the attack each fire mode stands for; autofire at auto_n rounds, capped by the magazine
local function ModeAction(w, kind, auto_n)
    local burst, auto = BurstModes(w)
    if kind == "single" then
        return not w.AutoFireOnly and CombatActions.SingleShot, 1
    elseif kind == "burst" then
        local action = burst and CombatActions.BurstFire
        return action, action and w:GetAutofireShots(action)
    end
    local n = Min(auto_n or State.auto, w.MagazineSize or auto_n or State.auto)
    return auto and Rat_AutoFireView(n, Rat_AutoAttackId(w)), n
end

-- muzzle offset of the last round (3rd at most), arcmin; no cone, so it is the recoil walk alone
local function Drift(w, c, kind)
    local action, shots = ModeAction(w, kind, 3)
    shots = Min(3, shots or 0)
    local prof = action and shots > 1 and Rat_RecoilProfile(c.shooter, action, w, shots)
    if not prof then return end
    return Rat_EstimateBurst(prof, nil, nil, shots, samples).offset[shots]
end

-- GatherCritChanceModifications without its situational parts (Settled, head/torso scopes, Flanked)
local function CritChance(w, shooter, action_id, aim)
    local crit = w.CritChance + Rat_CritPerAimCrit(w, shooter, action_id, aim)
    if w:HasComponent("pso_dragunov_scope_critical") and aim > 1 then
        crit = crit + const.Combat.Critical.PSOScopeCritOnAimed
    end
    if w:HasComponent("first_aim_crit") and aim > 0 then
        crit = crit + const.Combat.Critical.FirstAimCrit
    end
    local flat = w.CritChance
    return Clamp(flat + MulDivRound(crit - flat, Rat_CritFireModeMul(action_id, w), 100), 0, 100)
end

local function CritDamage(w, unit)
    local bonus = const.Weapons.CriticalDamage + (w.CritDamage or 0)
    if unit and HasPerk(unit, "ColdHeart") then
        bonus = bonus + CharacterEffectDefs.ColdHeart:ResolveValue("crit_bonus")
    end
    return bonus
end

-- shooting stance entry in whole AP at the sheet's stance; GetWeapon_StanceAP reads the merc's real stance for the bipod deploy
local function StanceEntryAP(w, c)
    local u = c.ap_unit
    local raw = GetWeapon_StanceAP(u, w, true)
    if w:HasComponent("rotate_ap_bipod") then
        local bipod = const.Combat.BipodProneStanceAP * const.Scale.AP
        local want, has = c.shooter.stance == "Prone", u.stance == "Prone"
        if want and not has then raw = raw + bipod elseif has and not want then raw = raw - bipod end
    end
    return MulDivRound(raw, 1, const.Scale.AP)
end

-- one fire mode at the sheet's aim (or `aim`): {shots, sum of round CTH, crit %, expected damage, AP}, cached per row
local function Stats(w, c, kind, n, dist, aim)
    if kind == "auto" then n = Min(n, w.MagazineSize or n) end
    aim = Min(aim or State.aim, w.MaxAimActions or 3)
    local key = kind .. (kind == "auto" and n or "") .. "@" .. dist .. "a" .. aim
    c.stats = c.stats or {}
    if c.stats[key] ~= nil then return c.stats[key] or nil end
    c.stats[key] = false
    local action, shots = ModeAction(w, kind, n)
    if not action then return end
    local a = const.Combat.Aperture
    local sum = 0
    if kind == "single" then
        sum = ConeCTH(w, c.shooter, aim, dist)
    else
        local prof = Rat_RecoilProfile(c.shooter, action, w, shots)
        if not prof then return end
        local sigma = Sigma(w, c.shooter, action, aim)
        local follow = Rat_FollowUpConeMul(w, c.shooter, action, aim, false, nil, shots)
        local est = Rat_EstimateBurst(prof, Theta(dist), sigma, shots, samples, nil, nil, nil,
                                      follow and Max(1, MulDivRound(sigma, follow, 1000)))
        for i = 1, shots do
            sum = sum + Clamp(est.cth[i] or 0, a.MinCTH, a.MaxCTH)
        end
    end
    -- GetAPCost adds the aim levels; out of combat it prices the shooting stance at 0, so the Stance AP knob adds it
    local ap = c.ap_unit and action:GetAPCost(c.ap_unit, {weapon = w, aim = aim})
    ap = ap and ap > 0 and MulDivRound(ap, 1, const.Scale.AP) or nil
    -- GetAPCost adds the cycle only to an unbolted gun; the leverage view charges it on every single shot
    if ap and kind == "single" and c.cycle_ap then ap = ap + c.cycle_ap end
    local ap_free, ap_paid = ap, ap and aim > 0 and ap + StanceEntryAP(w, c) or ap
    if State.stance_ap then ap = ap_paid end
    local crit = CritChance(w, c.shooter, kind == "auto" and Rat_AutoAttackId(w) or action.id, aim)
    local per_hit = (w.Damage or 0) * 100 + MulDivRound((w.Damage or 0) * crit, CritDamage(w, c.unit), 100)
    local dmg100 = MulDivRound(sum, per_hit, 100)
    c.stats[key] = {shots = shots, sum = sum, crit = crit, dmg = MulDivRound(dmg100, 1, 100), dmg100 = dmg100, ap = ap,
                    ap_free = ap_free, ap_paid = ap_paid}
    return c.stats[key]
end

local function ModeStats(w, c, kind)
    return Stats(w, c, kind, State.auto, State.dist)
end

local function Field(w, c, kind, key)
    local m = ModeStats(w, c, kind)
    return m and m[key]
end

-- damage per AP in hundredths, off the unrounded damage so small stat swings still register; `field` picks the AP
local function DAP(m, field)
    local ap = m and m[field or "ap"]
    return ap and MulDivRound(m.dmg100, 1, ap)
end

local function DmgPerAP(w, c, kind)
    return DAP(ModeStats(w, c, kind))
end

local AutoRounds = {3, 4, 5, 6, 8, 10, 15, 20}

-- best D/AP of the three fire-mode blocks (autofire at the Auto knob), at the sheet's distance: value, mode letter
local function BestDAP(w, c, field)
    local best, mode
    for _, m in ipairs{{"single", "S"}, {"burst", "B"}, {"auto", "A"}} do
        local v = DAP(ModeStats(w, c, m[1]), field)
        if v and (not best or v > best) then best, mode = v, m[2] end
    end
    return best, mode
end

local function Cents(v)
    return string.format("%d.%02d", v / 100, v % 100)
end

local function Hundredths(v)
    return string.format("%d.%d", v / 100, abs(v) % 100 / 10)
end

-- {key, label, data chars, tip, get(w, ctx), lower = smaller is better, fmt, text = not colored, prop = greyed at its Firearm default}
-- columns the Autofire view drops so it fits one screen
local NotAuto = {autofire = true}

local Groups = {
    {"Gun", always = true, {
        {"Name", "Name", 7, "Display name; * = optic can't come off", function(w) return _InternalTranslate(w.DisplayName or "") end,
         text = true},
        {"Cls", "Class", 5, "Class", function(w) return ClassShort[WeaponClass(w)] or "?" end, text = true},
        {"Cal", "Caliber", 8, "Caliber", function(w) return w.Caliber or "" end, text = true},
    }},
    {"Damage", {
        {"Dmg", "Dmg", 4, "Damage, Basic ammo loaded", function(w) return w.Damage end, hide_in = NotAuto},
        {"Crit", "Crit", 4, "CritChance, Basic ammo loaded", function(w) return w.CritChance end, prop = "CritChance"},
        {"CPA", "C/Aim", 4, "Crit chance per aim level (Rat_WeaponCritPerAim x Hand-Eye)",
         function(w, c) return MulDivRound(Rat_WeaponCritPerAim(w), c.unit and rGetHandEyeCoordination(c.unit) or 100, 100) end,
         fmt = Hundredths, prop = "CritPerAim", hide_in = NotAuto},
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
        {"Wgt", "Wgt", 4, "weigth_held_mul: above RecoilHeldPivot, unsupported fire loses control (Strength relieves it)",
         function(w) return w.weigth_held_mul end, lower = true, prop = "weigth_held_mul"},
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
         function(w) return w:IsCumbersome() and R_VanillaAPToDisplay(1) end, lower = true, hide_in = NotAuto},
        {"RAP", "Rld", 4, "Reload AP", function(w) return MulDivRound(w.ReloadAP or 0, 1, const.Scale.AP) end, lower = true,
         hide_in = NotAuto},
        {"AimRec", "+Aim", 4, "After one single shot, every aim level of the next attack costs this much more AP "
            .. "(Rat_recoil stack 1, Rat_GetRecoilAimCost)", function(w, c)
            return cRound(Rat_GetRecoilAimCost(c.unit or c.shooter, CombatActions.SingleShot, w, 1))
        end, lower = true},
    }},
    {"Logistics", view = "overview", {
        {"Mag", "Mag", 4, "MagazineSize", function(w) return w.MagazineSize end},
        {"Noise", "Noise", 4, "Noise, Basic ammo loaded", function(w) return w.Noise end, lower = true},
        {"Rel", "Rel", 4, "Reliability", function(w) return w.Reliability end, prop = "Reliability"},
        {"Wt", "Kg", 4, "Weight, kg", function(w) return w.Weight end, lower = true, prop = "Weight",
         fmt = function(v) return string.format("%d.%d", v / 1000, v % 1000 / 100) end},
        {"Brl", "Brl", 4, "Effective barrel length, mm (components applied)",
         function(w) return (w.rat_barrel_len or 0) > 0 and Rat_EffectiveBarrelLength(w) end},
        {"Cost", "Cost", 5, "Cost", function(w) return w.Cost end, lower = true},
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
        {"SCrit", "Crit", 4, "Crit chance at the sheet's aim: CritChance + CritPerAim x aim x Hand-Eye, fire-mode mul on the aimed part (no Settled, no spot scopes)",
         function(w, c) return Field(w, c, "single", "crit") end},
        {"SDmg", "Dmg", 4, "Expected damage of one shot: hit chance x Damage x (1 + crit x crit damage); no armor",
         function(w, c) return Field(w, c, "single", "dmg") end},
        {"S1AP", "AP", 4, "AP: attack + shooting stance + aim levels (selected merc prices it)",
         function(w, c) return Field(w, c, "single", "ap") end, lower = true},
        {"SDAP", "D/AP", 5, "Expected damage per AP", function(w, c) return DmgPerAP(w, c, "single") end, fmt = Cents},
    }},
    {"Burst", view = "autofire", {
        {"BRds", "Rds", 3, "Rounds per burst", function(w, c) return Field(w, c, "burst", "shots") end, text = true},
        {"BHits", "Hits", 4, "Expected hits: sum of each round's hit chance (cone + recoil walk)",
         function(w, c) return Field(w, c, "burst", "sum") end, fmt = Hundredths},
        {"BCrit", "Crit", 4, "Crit chance at the sheet's aim: CritChance + CritPerAim x aim x Hand-Eye, fire-mode mul on the aimed part (no Settled, no spot scopes)",
         function(w, c) return Field(w, c, "burst", "crit") end},
        {"BDmg", "Dmg", 4, "Expected damage: hits x Damage x (1 + crit x crit damage); no armor",
         function(w, c) return Field(w, c, "burst", "dmg") end},
        {"BAP", "AP", 4, "AP: attack + shooting stance + aim levels (selected merc prices it)",
         function(w, c) return Field(w, c, "burst", "ap") end, lower = true},
        {"BDAP", "D/AP", 5, "Expected damage per AP", function(w, c) return DmgPerAP(w, c, "burst") end, fmt = Cents},
    }},
    {"Auto", view = "autofire", title = function() return "Auto (" .. State.auto .. " rds)" end, {
        {"ARds", "Rds", 3, "Rounds fired: the Auto knob, capped by the magazine", function(w, c) return Field(w, c, "auto", "shots") end,
         text = true},
        {"AHits", "Hits", 4, "Expected hits: sum of each round's hit chance (cone + recoil walk)",
         function(w, c) return Field(w, c, "auto", "sum") end, fmt = Hundredths},
        {"ACrit", "Crit", 4, "Crit chance at the sheet's aim: CritChance + CritPerAim x aim x Hand-Eye, fire-mode mul on the aimed part (no Settled, no spot scopes)",
         function(w, c) return Field(w, c, "auto", "crit") end},
        {"ADmg", "Dmg", 4, "Expected damage: hits x Damage x (1 + crit x crit damage); no armor",
         function(w, c) return Field(w, c, "auto", "dmg") end},
        {"AAP", "AP", 4, "AP: attack + shooting stance + aim levels (selected merc prices it)",
         function(w, c) return Field(w, c, "auto", "ap") end, lower = true},
        {"ADAP", "D/AP", 5, "Expected damage per AP", function(w, c) return DmgPerAP(w, c, "auto") end, fmt = Cents},
    }},
    {"Best", view = "autofire", {
        {"BestDAP", "Stnc", 5, "Best D/AP of the gun (single, burst or autofire at the Auto knob's rounds), paying the shooting stance on aimed attacks",
         function(w, c) return (BestDAP(w, c, "ap_paid")) end, fmt = Cents},
        {"BestMode", "M", 2, "Mode of the stance-paid best D/AP: S single, B burst, A autofire",
         function(w, c) return select(2, BestDAP(w, c, "ap_paid")) end, text = true},
        {"BestFree", "Free", 5, "Best D/AP with the shooting stance free (already in stance)",
         function(w, c) return (BestDAP(w, c, "ap_free")) end, fmt = Cents},
        {"BestFreeMode", "M", 2, "Mode of the stance-free best D/AP",
         function(w, c) return select(2, BestDAP(w, c, "ap_free")) end, text = true},
        {"AvS", "A/S", 4, "Autofire D/AP / single D/AP: above 1 the gun is better on auto",
         function(w, c)
             local auto = DmgPerAP(w, c, "auto")
             local single = DmgPerAP(w, c, "single")
             return auto and single and single > 0 and MulDivRound(auto, 100, single) or nil
         end, fmt = Cents},
    }},
}

-- curve views: D/AP by rounds at the Dist knob, and by distance at the Auto knob's rounds
local curve_w = 6
local by_rounds = {
    {"CRS", "Sgl", curve_w, "Single shot", function(w, c) return DAP(Stats(w, c, "single", 1, State.dist)) end, fmt = Cents},
    {"CRB", "Bst", curve_w, "Selective burst", function(w, c) return DAP(Stats(w, c, "burst", 1, State.dist)) end, fmt = Cents},
}
local auto_rounds = {}
for _, n in ipairs(AutoRounds) do
    auto_rounds[#auto_rounds + 1] = {"CR" .. n, tostring(n), curve_w, "Autofire, " .. n .. " rounds; blank past the magazine",
        function(w, c) return (w.MagazineSize or 0) >= n and DAP(Stats(w, c, "auto", n, State.dist)) or nil end, fmt = Cents}
end
Groups[#Groups + 1] = {"Rounds", view = "rounds", title = function() return "Single / burst @ " .. State.dist .. " tiles" end, by_rounds}
Groups[#Groups + 1] = {"AutoRounds", view = "rounds", title = function() return "Autofire D/AP by rounds @ " .. State.dist .. " tiles" end,
                       auto_rounds}

local CurveDistances = {5, 10, 15, 20, 30, 40}
for _, mode in ipairs{{"single", "S", "Single D/AP by distance"}, {"burst", "B", "Burst D/AP by distance"}, {"auto", "A", "Auto"}} do
    local kind, key, name = mode[1], mode[2], mode[3]
    local cols = {}
    for _, d in ipairs(CurveDistances) do
        cols[#cols + 1] = {"CD" .. key .. d, d .. "t", curve_w, kind .. " at " .. d .. " tiles",
            function(w, c) return DAP(Stats(w, c, kind, State.auto, d)) end, fmt = Cents}
    end
    Groups[#Groups + 1] = {name, view = "distance", cols,
        title = kind == "auto" and function() return "Auto D/AP by distance (" .. State.auto .. " rds)" end or nil}
end

-- turn budget view: highest aim one attack still affords after walking N tiles and shouldering, on the selected merc's full AP
local TurnMoves = {0, 2, 4, 6, 8}

local function TurnAim(w, c, kind, tiles)
    local u = c.ap_unit
    local action = u and ModeAction(w, kind, State.auto)
    if not action then return end
    local budget = MulDivRound(u:GetMaxActionPoints() - tiles * GetSpecialMoveAPCost("Walk"), 1, const.Scale.AP)
    for aim = w.MaxAimActions or 3, 0, -1 do
        local ap = action:GetAPCost(u, {weapon = w, aim = aim})
        if ap and ap >= 0 then
            -- hipfire needs no stance
            ap = MulDivRound(ap, 1, const.Scale.AP) + (aim > 0 and StanceEntryAP(w, c) or 0)
            if ap <= budget then return aim end
        end
    end
    return -1
end

local function AimLevel(v)
    return v < 0 and "x" or v == 0 and "hip" or tostring(v)
end

local turn_note = " Walk cost per tile from GetSpecialMoveAPCost; the stance is paid whenever aim > 0. x = can't fire, hip = hipfire only."
for _, mode in ipairs{{"single", "S", "Single"}, {"burst", "B", "Burst"}, {"auto", "A", "Auto"}} do
    local kind, key, name = mode[1], mode[2], mode[3]
    local cols = {}
    for _, t in ipairs(TurnMoves) do
        cols[#cols + 1] = {"T" .. key .. t, t .. "t", 4, name .. ": highest aim after walking " .. t .. " tiles." .. turn_note,
            function(w, c) return TurnAim(w, c, kind, t) end, fmt = AimLevel}
    end
    Groups[#Groups + 1] = {"Turn" .. name, view = "turn", cols, title = function()
        local u = SelectedObj
        local tail = kind == "auto" and " (" .. State.auto .. " rds)" or ""
        return name .. tail .. ": aim after walking" .. (IsKindOf(u, "Unit") and " (" .. MulDivRound(u:GetMaxActionPoints(), 1, const.Scale.AP) .. " AP)" or "")
    end}
end

-- stat leverage view: one stat swung 50 -> 90 off a 70 base (Marks 80); AP priced on the selected merc with its stats overridden
local LevBase = {Marksmanship = 80, Dexterity = 70, Agility = 70, Strength = 70, Wisdom = 70, Explosives = 70}
local LevProfiles = {
    base = {}, dex_lo = {Dexterity = 50}, dex_hi = {Dexterity = 90}, str_lo = {Strength = 50}, str_hi = {Strength = 90},
    agi_lo = {Agility = 50}, agi_hi = {Agility = 90}, weak = {Strength = 50, Dexterity = 90}, strong = {Strength = 90, Dexterity = 50},
}
local LevStatKeys = {"Marksmanship", "Dexterity", "Agility", "Strength"}

-- best D/AP over aim 0..max and every fire mode at the Dist knob: value, mode letter + aim
local function BestTurnDAP(w, c)
    local best, mode
    for aim = 0, w.MaxAimActions or 3 do
        for _, kind in ipairs{"single", "burst", "auto"} do
            local v = DAP(Stats(w, c, kind, State.auto, State.dist, aim))
            if v and (not best or v > best) then
                best, mode = v, (kind == "single" and "S" or kind == "burst" and "B" or "A") .. aim
            end
        end
    end
    return best, mode
end

local function Leverage(w, c)
    if c.lev ~= nil then return c.lev or nil end
    c.lev = false
    local u = c.ap_unit
    if not u then return end
    local saved = {}
    for _, k in ipairs(LevStatKeys) do saved[k] = u[k] end
    local out = {}
    local ok, err = pcall(function()
        for name, over in pairs(LevProfiles) do
            local stats = {}
            for k, v in pairs(LevBase) do stats[k] = over[k] or v end
            for _, k in ipairs(LevStatKeys) do u[k] = stats[k] end
            local pc = {ap_unit = u, shooter = Shooter(w, stats, c.shooter.stance),
                        cycle_ap = rat_canBolt(w) and MulDivRound(rat_get_manual_cyclingAP(u, w, true), 1, const.Scale.AP) or nil}
            out[name] = {BestTurnDAP(w, pc)}
        end
    end)
    for k, v in pairs(saved) do u[k] = v end
    if not ok then error(err) end
    c.lev = out
    return out
end

local function LevValue(w, c, name)
    local lev = Leverage(w, c)
    return lev and lev[name][1]
end

-- % D/AP gained from the low to the high profile
local function LevPct(w, c, lo, hi)
    local a, b = LevValue(w, c, lo), LevValue(w, c, hi)
    return a and b and a > 0 and MulDivRound(b - a, 100, a) or nil
end

local lev_note = " Best D/AP over aim 0-max and single/burst/auto (Auto knob rounds) at the Dist knob; bolt guns pay the cycle on every shot."
Groups[#Groups + 1] = {"Stat leverage", view = "stats", title = function() return "Stat leverage @ " .. State.dist .. " tiles" end, {
    {"LBase", "D/AP", 5, "Base shooter: Marks 80, Dex/Str/Agi 70." .. lev_note, function(w, c) return LevValue(w, c, "base") end, fmt = Cents},
    {"LMode", "Mode", 4, "Base shooter's best mode: S single, B burst, A auto, then the aim level",
     function(w, c) local lev = Leverage(w, c) return lev and lev.base[2] end, text = true},
    {"LDex", "Dex%", 5, "D/AP gained from Dex 50 to 90 (Hand-Eye aim and crit, Reflexes on the snapshot step, cycling AP)." .. lev_note,
     function(w, c) return LevPct(w, c, "dex_lo", "dex_hi") end},
    {"LStr", "Str%", 5, "D/AP gained from Str 50 to 90 (recoil gate, held weight, MG/autofire hipfire, stance AP)." .. lev_note,
     function(w, c) return LevPct(w, c, "str_lo", "str_hi") end},
    {"LAgi", "Agi%", 5, "D/AP gained from Agi 50 to 90 on stationary attacks: Reflexes only (see Mobile for moving fire). The bigger AP pool is the same for every gun and left out." .. lev_note,
     function(w, c) return LevPct(w, c, "agi_lo", "agi_hi") end},
    {"LLean", "Str-Dex", 7, "Str% minus Dex%: positive = a Strength gun, negative = a Dexterity gun",
     function(w, c)
         local s, d = LevPct(w, c, "str_lo", "str_hi"), LevPct(w, c, "dex_lo", "dex_hi")
         return s and d and s - d
     end},
}}
Groups[#Groups + 1] = {"Archetypes", view = "stats", {
    {"LWeak", "Weak", 5, "STR 50 / DEX 90 (Marks 80, Agi 70)." .. lev_note, function(w, c) return LevValue(w, c, "weak") end, fmt = Cents},
    {"LStrong", "Strong", 6, "STR 90 / DEX 50 (Marks 80, Agi 70)." .. lev_note, function(w, c) return LevValue(w, c, "strong") end, fmt = Cents},
    {"LWS", "W/S%", 5, "Weak D/AP as % of strong: above 100 the gun favours the dexterous merc",
     function(w, c)
         local a, b = LevValue(w, c, "weak"), LevValue(w, c, "strong")
         return a and b and b > 0 and MulDivRound(a, 100, b) or nil
     end},
}}

-- what the leverage reads: gun inputs, and the base shooter's cone split into the share aim closes and the held-weight share
local function LevShooter(w, c)
    c.lev_shooter = c.lev_shooter or Shooter(w, LevBase, c.shooter.stance)
    return c.lev_shooter
end

local function LevGaps(w, c)
    if c.lev_gaps ~= nil then return c.lev_gaps or nil end
    c.lev_gaps = false
    local sh = LevShooter(w, c)
    local _, _, parts = Rat_GetAperture(w, sh, nil, w.MaxAimActions or 3)
    if not parts or not parts.pre_aim then return end
    local gap = Max(0, parts.pre_aim - parts.floor)
    local base_mul, gun_mul = parts.base_mul * 100, Rat_HandlingBaseMul(w, sh)
    local gun = base_mul > gun_mul and Max(0, MulDivRound(parts.pre_aim, gun_mul, base_mul) - parts.floor) or gap
    c.lev_gaps = {gun = gun, held = gap - gun}
    return c.lev_gaps
end

local function LevHeldPen(w, c, str)
    return (Rat_HeldWeightPen(w, {Strength = str}, c.shooter.stance, const.Combat.Aperture.HandlingHeldSlope))
end

local function LevCycle(w, c)
    local u = c.ap_unit
    if not u or not rat_canBolt(w) then return end
    local saved = u.Dexterity
    local ap = {}
    for i, dex in ipairs{50, 90} do
        u.Dexterity = dex
        local ok, v = pcall(rat_get_manual_cyclingAP, u, w, true)
        ap[i] = ok and MulDivRound(v, 1, const.Scale.AP) or "?"
    end
    u.Dexterity = saved
    return ap[1] .. "/" .. ap[2]
end

Groups[#Groups + 1] = {"Dex drivers", view = "stats", {
    {"LvAim", "Aim", 4, "AimAccuracy per level before Hand-Eye, components applied: how hard each aim level closes the gap. Hand-Eye scales it",
     function(w) return Aim(w) end, fmt = function(v) return tostring(MulDivRound(v, 1, 100)) end},
    {"LvGap", "Gap", 4, "Cone the aim closes: sigma before aim minus the floor, held-weight share left out (base shooter, sheet stance). "
        .. "Dex leverage grows with it", function(w, c) local g = LevGaps(w, c) return g and g.gun end, lower = true},
    {"LvCPA", "C/Aim", 4, "Crit per aim level before Hand-Eye", function(w) return Rat_WeaponCritPerAim(w) end, fmt = Hundredths,
     prop = "CritPerAim"},
    {"LvSnap", "Snap%", 4, "Snapshot cone multiplier % before Reflexes (base shooter, sheet stance): Reflexes shrink the step",
     function(w, c) return HipSnap(w, 1, nil, LevShooter(w, c)) end, lower = true},
    {"LvCyc", "Cycle", 5, "Bolt cycling AP per shot at Dex 50 / 90", LevCycle, text = true},
}}
Groups[#Groups + 1] = {"Str drivers", view = "stats", {
    {"LvBP", "StrBP", 5, "Caliber Strength breakpoint: below it the recoil control falls off fast", function(w) return (Recoil_StrBreakpoint(w)) end},
    {"LvKick", "Kick", 4, "Single kick at Strength 100 (x100): the gun's own push", function(w) return Recoil(w) end, lower = true},
    {"LvWgt", "Wgt", 4, "weigth_held_mul (pivot A.HeldPivot)", function(w) return w.weigth_held_mul end,
     lower = true, prop = "weigth_held_mul"},
    {"LvHeld", "Held", 4, "Held-weight share of the base shooter's cone: closes at a fixed Hand-Eye, only Strength lifts it",
     function(w, c) local g = LevGaps(w, c) return g and g.held end, lower = true},
    {"LvH50", "Hld50", 5, "Held-weight cone malus % at Str 50, sheet stance", function(w, c) return LevHeldPen(w, c, 50) end, lower = true},
    {"LvH90", "Hld90", 5, "Held-weight cone malus % at Str 90, sheet stance", function(w, c) return LevHeldPen(w, c, 90) end, lower = true},
    {"LvCmb", "Cmb", 3, "Cumbersome: extra stance AP below Strength " .. const.Combat.CumbersomeStanceAP_StrThreshold,
     function(w) return w:IsCumbersome() and R_VanillaAPToDisplay(1) end, lower = true},
}}

-- mobile attacks: one aim-1 round of Mobile Shot (pistols) or Run and Gun (SMGs), standing, at the Dist knob; recoil left out
local function MobileAction(w)
    local list = w.AvailableAttacks or empty_table
    return table.find(list, "MobileShot") and CombatActions.MobileShot or table.find(list, "RunAndGun") and CombatActions.RunAndGun or nil
end

local function MobileDmg(w, c, name)
    c.mob = c.mob or {}
    if c.mob[name] ~= nil then return c.mob[name] or nil end
    c.mob[name] = false
    local action = MobileAction(w)
    if not action then return end
    local stats = {}
    for k, v in pairs(LevBase) do stats[k] = LevProfiles[name][k] or v end
    local sh = Shooter(w, stats, "Standing")
    local a = const.Combat.Aperture
    local cth = Clamp(Rat_RayleighCTH(Theta(State.dist), Max(1, Rat_GetAperture(w, sh, action, 1))), a.MinCTH, a.MaxCTH)
    local crit = CritChance(w, sh, action.id, 1)
    c.mob[name] = MulDivRound(cth, (w.Damage or 0) * 100 + MulDivRound((w.Damage or 0) * crit, CritDamage(w), 100), 100)
    return c.mob[name]
end

local function MobilePct(w, c, lo, hi)
    local a, b = MobileDmg(w, c, lo), MobileDmg(w, c, hi)
    return a and b and a > 0 and MulDivRound(b - a, 100, a) or nil
end

local function MobileStep(w, c)
    local action = MobileAction(w)
    if not action then return end
    local _, _, parts = Rat_GetAperture(w, Shooter(w, LevBase, "Standing"), action, 1)
    return parts and parts.step
end

-- display move AP of the mobile attack at Agi 50 / 90, priced on the selected merc
local function MobileMoveAP(w, c)
    local u, action = c.ap_unit, MobileAction(w)
    if not u or not action then return end
    local saved = u.Agility
    local ap = {}
    for i, agi in ipairs{50, 90} do
        u.Agility = agi
        local ok, v = pcall(rat_getMobileshot_moveAP, action, u, w)
        ap[i] = ok and R_VanillaAPToDisplay(v) or "?"
    end
    u.Agility = saved
    return ap[1] .. "/" .. ap[2]
end

local mob_note = " One aim-1 round of the mobile attack (Mobile Shot, else Run and Gun), standing, at the Dist knob; no recoil, no movement AP."
Groups[#Groups + 1] = {"Mobile leverage", view = "stats", title = function() return "Mobile @ " .. State.dist .. " tiles" end, {
    {"MAct", "Act", 3, "MS = Mobile Shot, RG = Run and Gun",
     function(w) local a = MobileAction(w) return a and (a.id == "MobileShot" and "MS" or "RG") end, text = true},
    {"MDmg", "Dmg", 5, "Base shooter's expected damage per mobile round." .. mob_note, function(w, c) return MobileDmg(w, c, "base") end, fmt = Cents},
    {"MAgi", "Agi%", 5, "Mobile damage gained from Agi 50 to 90: the moving-Agility multiplier plus Reflexes." .. mob_note,
     function(w, c) return MobilePct(w, c, "agi_lo", "agi_hi") end},
    {"MDex", "Dex%", 5, "Mobile damage gained from Dex 50 to 90: Hand-Eye on the halved aim level plus Reflexes." .. mob_note,
     function(w, c) return MobilePct(w, c, "dex_lo", "dex_hi") end},
}}
Groups[#Groups + 1] = {"Agi drivers", view = "stats", {
    {"AgStep", "Step%", 5, "Snapshot step of the mobile attack at Agi 70 (base shooter). The moving-Agility multiplier on it "
        .. "(MobileAgiPer10 per 10 points off 70) is the same for every gun", MobileStep, lower = true},
    {"AgMv", "MvAP", 7, "Move AP of the mobile attack at Agi 50 / 90 (selected merc's perks and weapon stance)", MobileMoveAP, text = true},
}}

local Columns = {}
for gi, g in ipairs(Groups) do
    State.collapsed[gi] = g.collapsed
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
    -- Id isn't a column; rows keep it for sort ties, the filter and the error log
    local row = {Id = id, cls_order = table.find(ClassOrder, WeaponClass(w)) or 99, default = {}}
    for _, col in ipairs(Columns) do
        local gview = Groups[col.group].view
        if gview and gview ~= ctx.view then goto continue end
        local ok, v = pcall(col[4], w, c)
        row[col[1]] = ok and v or nil
        if not ok then row.err = (row.err or "") .. col[1] .. " " end
        if col.prop and w[col.prop] == Firearm:GetDefaultPropertyValue(col.prop) then row.default[col[1]] = true end
        ::continue::
    end
    if kept_scope then row.Name = row.Name .. "*" end
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

local CurveViews = {rounds = true, distance = true, stats = true, turn = true}

-- curve views hide the always-on groups but Gun
local function GroupShown(gi)
    local g = Groups[gi]
    if g.hide_in and g.hide_in[State.view] then return false end
    return g.view == State.view or not g.view and (not CurveViews[State.view] or g.always)
end

local function ColShown(col)
    return Shown(col) and not (col.hide_in and col.hide_in[State.view])
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

local function StopThreads(dlg)
    local thread = rawget(dlg, "rat_thread")
    if IsValidThread(thread) then DeleteThread(thread) end
    rawset(dlg, "rat_thread", false)
end

-- a run started from stale settings is dropped, not finished
local function SetPending(dlg, pending)
    rawset(dlg, "rat_pending", pending)
    local btn = dlg.idApply
    if not btn then return end
    btn:SetText(pending and "Apply changes" or "Recompute")
    btn:SetBackground(pending and RGBA(190, 60, 40, 255) or RGBA(60, 60, 60, 220))
    btn:SetTextColor(pending and RGB(255, 255, 255) or TextStyles[btn.TextStyle].TextColor)
end

local function Recompute(dlg)
    StopThreads(dlg)
    SetPending(dlg, false)
    rawset(dlg, "rat_thread", CreateRealTimeThread(function()
        local unit = State.merc and SelectedUnit() or nil
        local ctx = {unit = unit, ap_unit = SelectedUnit(), stance = Stances[State.stance], no_scope = State.no_scope, view = State.view,
                     no_bipod = State.no_bipod}
        local ids, rows = Ids(), {}
        local t0 = RealTime()
        for i, id in ipairs(ids) do
            if dlg.window_state == "destroying" then return end
            rows[#rows + 1] = ComputeRow(id, ctx)
            if i % (ctx.view == "stats" and 1 or 4) == 0 then
                SetStatus(dlg, string.format("computing %d / %d ...", i, #ids))
                Sleep(1)
            end
        end
        State.rows, State.rows_view = rows, ctx.view
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

-- knobs only flag the rows stale; the Apply button recomputes, so cycling options costs nothing
local function MarkPending(dlg)
    SetPending(dlg, true)
    SetStatus(dlg, "changes pending: press Apply changes")
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
        if ColShown(col) and GroupShown(col.group) then cols[#cols + 1] = col end
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
    -- mods can't write files (AsyncStringToFile is in ModEnvBlacklist)
    CopyToClipboard(table.concat(out, "\n"))
    SetStatus(dlg, "copied " .. (#out - 1) .. " rows to the clipboard as CSV")
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
local Views = {"overview", "autofire", "rounds", "distance", "stats", "turn"}
local ViewNames = {overview = "Overview", autofire = "Autofire", rounds = "D/AP by rounds", distance = "D/AP by distance",
                   stats = "Stat leverage", turn = "Turn budget"}
local collapsed_w = 5 * char_w + 2 * cell_pad

-- shows the view's groups and folds collapsed ones to a stub; shading alternates over the visible ones only
ApplyView = function(dlg)
    local blocks = rawget(dlg, "rat_blocks")
    local n = 0
    for gi, g in ipairs(Groups) do
        local show = GroupShown(gi)
        local shade = RGBA(0, 0, 0, 0)
        if show then
            n = n + 1
            if n % 2 == 0 then shade = RGBA(255, 255, 255, 12) end
        end
        local folded = State.collapsed[gi]
        local width = 0
        for i, col in ipairs(Columns) do
            if col.group == gi and Shown(col) then
                local vis = ColShown(col) and not folded
                dlg["idHead" .. i]:SetVisible(vis)
                dlg["idCol" .. i]:SetVisible(vis)
                width = width + (vis and col.width or 0)
            end
        end
        if folded then width = collapsed_w end
        for _, win in ipairs{blocks.head[gi], blocks.body[gi]} do
            win:SetVisible(show)
            win:SetBackground(shade)
            win:SetMinWidth(width)
            win:SetMaxWidth(width)
        end
        blocks.cols[gi]:SetVisible(not folded)
        blocks.label[gi]:SetText(folded and g[1]:sub(1, 3) .. "+" or g.title and g.title() or g[1])
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
    auto = RGBA(140, 90, 40, 255),
    stance_ap = RGBA(40, 110, 110, 255),
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
        MarkPending(dlg)
    end, {RolloverText = Untranslated("Stat 100 = the gun alone, like the rollover's grey bracket")})
    Knob(merc_btn, State.merc and "Shooter: selected merc" or "Shooter: stat 100", State.merc, KnobColors.merc)
    local stance_btn
    stance_btn = Button(bar, "", function()
        State.stance = State.stance % #Stances + 1
        Knob(stance_btn, "Stance: " .. Stances[State.stance], State.stance ~= 1, KnobColors.stance)
        MarkPending(dlg)
    end, {RolloverText = Untranslated("Shooter stance for the CTH columns; the target is always standing")})
    Knob(stance_btn, "Stance: " .. Stances[State.stance], State.stance ~= 1, KnobColors.stance)
    local scope_btn
    scope_btn = Button(bar, "", function()
        State.no_scope = not State.no_scope
        Knob(scope_btn, State.no_scope and "Scopes: removed" or "Scopes: default", State.no_scope, KnobColors.scope)
        MarkPending(dlg)
    end, {RolloverText = Untranslated("Removed: optics swapped for ironsights or an empty slot. Name* = optic can't come off")})
    Knob(scope_btn, State.no_scope and "Scopes: removed" or "Scopes: default", State.no_scope, KnobColors.scope)
    local bipod_btn
    bipod_btn = Button(bar, "", function()
        State.no_bipod = not State.no_bipod
        Knob(bipod_btn, State.no_bipod and "Bipods: removed" or "Bipods: default", State.no_bipod, KnobColors.bipod)
        MarkPending(dlg)
    end, {RolloverText = Untranslated("Removed: every bipod slot emptied, fixed MG bipods included")})
    Knob(bipod_btn, State.no_bipod and "Bipods: removed" or "Bipods: default", State.no_bipod, KnobColors.bipod)
    Button(bar, "Recompute", function() Recompute(dlg) end, {Id = "idApply"})
    Button(bar, "Copy CSV", function() ExportCSV(dlg) end,
        {RolloverText = Untranslated("Visible rows and columns, current sort, to the clipboard as CSV")})
    Button(bar, "Close", function() dlg:Close() end)

    local bar2 = XWindow:new({LayoutMethod = "HList", LayoutHSpacing = 6, Dock = "top", Margins = box(0, 6, 0, 0)}, dlg)
    local view_btn, aim_btn, dist_btn, auto_btn, stance_ap_btn
    local function knob_texts()
        Knob(auto_btn, "Auto: " .. State.auto .. " rds", State.auto ~= 3, KnobColors.auto)
        Knob(stance_ap_btn, State.stance_ap and "Stance AP: paid" or "Stance AP: free", not State.stance_ap, KnobColors.stance_ap)
        Knob(view_btn, "View: " .. ViewNames[State.view], State.view ~= "overview",
             KnobColors.view)
        Knob(aim_btn, "Aim: " .. State.aim, State.aim ~= 3, KnobColors.aim)
        Knob(dist_btn, "Dist: " .. State.dist .. " tiles", State.dist ~= 10, KnobColors.dist)
    end
    view_btn = Button(bar2, "", function()
        State.view = Views[(table.find(Views, State.view) or 0) % #Views + 1]
        knob_texts()
        ApplyView(dlg)
        if State.rows and State.rows_view ~= State.view then MarkPending(dlg) end
    end, {RolloverText = Untranslated("Overview: logistics and hit chance. Autofire: expected hits, damage and damage per AP. D/AP by rounds (at Dist) and by distance (at Auto rounds). Stat leverage: how much Dex, Str and Agi move each gun (needs a selected merc)")})
    aim_btn = Button(bar2, "", function()
        State.aim = (State.aim + 1) % 4
        knob_texts()
        MarkPending(dlg)
    end, {RolloverText = Untranslated("Aim level of the Autofire view, capped by the gun's MaxAimActions")})
    dist_btn = Button(bar2, "", function()
        local i = table.find(Distances, State.dist) or 0
        State.dist = Distances[i % #Distances + 1]
        knob_texts()
        ApplyView(dlg)
        MarkPending(dlg)
    end, {RolloverText = Untranslated("Target distance of the Autofire view and of D/AP by rounds; the target is always standing")})
    auto_btn = Button(bar2, "", function()
        local i = table.find(AutoRounds, State.auto) or 0
        State.auto = AutoRounds[i % #AutoRounds + 1]
        knob_texts()
        ApplyView(dlg)
        MarkPending(dlg)
    end, {RolloverText = Untranslated("Rounds of the Autofire view's Auto block and of D/AP by distance, capped by each gun's magazine")})
    stance_ap_btn = Button(bar2, "", function()
        State.stance_ap = not State.stance_ap
        knob_texts()
        MarkPending(dlg)
    end, {RolloverText = Untranslated("Paid: every aimed attack's AP includes entering the shooting stance (out of combat the game prices it at 0). "
        .. "Free: already in stance, as for a follow-up attack")})
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
    local head_groups, body_groups, head_blocks, labels = {}, {}, {}, {}
    rawset(dlg, "rat_blocks", {head = head_blocks, body = body_groups, cols = head_groups, label = labels})
    for gi, g in ipairs(Groups) do
        local width = 0
        for _, col in ipairs(g[2]) do width = width + (Shown(col) and col.width or 0) end
        -- head and body blocks share one width so a long group label can't shift the columns under it
        local hg = XWindow:new({LayoutMethod = "VList", MinWidth = width, MaxWidth = width, FoldWhenHidden = true}, head)
        head_blocks[gi] = hg
        local label = XText:new({Translate = false, TextStyle = "SatelliteContextMenuText", HAlign = "center", Clip = "self", WordWrap = false,
                                 HandleMouse = gi > 1, RolloverText = gi > 1 and Untranslated(g[1] .. ": click to collapse / expand") or nil}, hg)
        labels[gi] = label
        label:SetTextColor(RGB(230, 200, 120))
        label:SetText(g[1])
        if gi > 1 then
            label.OnMouseButtonDown = function(self, pt, button)
                if button ~= "L" then return end
                State.collapsed[gi] = not State.collapsed[gi] or nil
                ApplyView(dlg)
                return "break"
            end
        end
        XWindow:new({MinHeight = 1, MaxHeight = 1, Margins = box(4, 0, 4, 0), Background = RGBA(230, 200, 120, 90)}, hg)
        head_groups[gi] = XWindow:new({LayoutMethod = "HList", FoldWhenHidden = true}, hg)
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
                FoldWhenHidden = true,
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
                FoldWhenHidden = true,
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
