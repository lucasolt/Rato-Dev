-- Live balance sheet: every live firearm with its default components, stats read through GBO's own math.
-- Getters mirror DESCRIPTION_HINTS_get.lua (locals there); keep them in step when the hints change.

local sheet_id = "idRatoWeaponSheet"
local csv_path = "AppData/RatoWeaponSheet.csv"
local samples = 64

local FullStats = {placeholder = true, Marksmanship = 100, Dexterity = 100, Agility = 100, Strength = 100}
local ClassOrder = {"AssaultRifle", "SubmachineGun", "MachineGun", "SniperRifle", "Rifle", "Shotgun", "Pistol", "Revolver"}
local ClassShort = {AssaultRifle = "AR", SubmachineGun = "SMG", MachineGun = "MG", SniperRifle = "SR", Rifle = "Rifle",
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

local function HipSnap(w, aim, unit)
    local mul = cRound(GetWeaponHipfireOrSnapshotMul(w, false, false, true, aim) * 100)
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
    unit = unit or {placeholder = true, Marksmanship = 0, Dexterity = 0, Agility = 0, Strength = 0}
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

-- mean CTH of every round of the string at full aim (capped at 3), cone + recoil walk
local function StringCTH(w, shooter, action, shots, tiles)
    local prof = action and Rat_RecoilProfile(shooter, action, w, shots)
    if not prof then return end
    local aim = Min(3, w.MaxAimActions or 3)
    local est = Rat_EstimateBurst(prof, Theta(tiles), Sigma(w, shooter, action, aim), shots, samples)
    local a, sum = const.Combat.Aperture, 0
    for i = 1, shots do
        sum = sum + Clamp(est.cth[i] or 0, a.MinCTH, a.MaxCTH)
    end
    return MulDivRound(sum, 1, shots)
end

local function Hundredths(v)
    return string.format("%d.%d", v / 100, abs(v) % 100 / 10)
end

-- {key, width, tip, get(w, ctx), lower = smaller is better, fmt, text = not colored}
local Columns = {
    {"Id", 150, "Preset id", function(w) return w.class end, text = true},
    {"Name", 150, "Display name", function(w) return _InternalTranslate(w.DisplayName or "") end, text = true},
    {"Cls", 60, "Class", function(w) return ClassShort[WeaponClass(w)] or "?" end, text = true},
    {"Cal", 90, "Caliber", function(w) return w.Caliber or "" end, text = true},
    {"Src", 34, "V = vanilla, T = ToG patched", function(w) return w.is_tog_patched and "T" or "V" end, text = true},
    {"Dmg", 40, "Damage, Basic ammo loaded", function(w) return w.Damage end},
    {"Crit", 44, "CritChance", function(w) return w.CritChance end},
    {"CPA", 40, "Crit per aim (Rat_WeaponCritPerAim x Hand-Eye)",
     function(w, c) return MulDivRound(Rat_WeaponCritPerAim(w), c.unit and rGetHandEyeCoordination(c.unit) or 100, 100) end,
     fmt = Hundredths},
    {"Aim", 50, "aCTH aim accuracy per level, components applied", function(w, c) return Aim(w, c.unit) end, fmt = Hundredths},
    {"Hand", 48, "Handling, effective points", function(w, c) return (Rat_HandlingEffectivePoints(w, c.unit)) end},
    {"PB", 36, "Point blank bonus", function(w, c) return PB(w, c.unit) end},
    {"Hip", 40, "Hipfire cone mul %", function(w, c) return HipSnap(w, 0, c.unit) end, lower = true},
    {"Snap", 42, "Snapshot cone mul %", function(w, c) return HipSnap(w, 1, c.unit) end, lower = true},
    {"Rng", 38, "WeaponRange", function(w) return w.WeaponRange end},
    {"Rec", 40, "Recoil (x100), the rollover's Recoil row", function(w, c) return Recoil(w, c.unit) end, lower = true},
    {"BRec", 44, "Selective burst recoil (x100)",
     function(w, c) return (BurstModes(w)) and ModeRecoil(w, c.unit, "burst_recoil_delta", true) end, lower = true},
    {"ARec", 44, "Autofire recoil (x100)",
     function(w, c) return select(2, BurstModes(w)) and ModeRecoil(w, c.unit, "auto_recoil_delta") end, lower = true},
    {"RPM", 50, "RPM (variable autofire)", function(w) return Rat_HasVariableAuto(w) and w.RPM end},
    {"AP", 34, "Default attack AP (selected merc prices it; else raw ShootAP)", function(w, c) return AttackAP(w, c.ap_unit) end, lower = true},
    {"SAP", 36, "Stance + aim AP", function(w, c) return StanceAP(w, c.unit) end, lower = true},
    {"RAP", 36, "ReloadAP", function(w) return MulDivRound(w.ReloadAP or 0, 1, const.Scale.AP) end, lower = true},
    {"Mag", 36, "MagazineSize", function(w) return w.MagazineSize end},
    {"Noise", 54, "Noise, Basic ammo loaded", function(w) return w.Noise end, lower = true},
    {"Rel", 40, "Reliability", function(w) return w.Reliability end},
    {"Pen", 34, "Penetration class shown", function(w) return Rat_DisplayPenetrationClass(w) end},
    {"Wt", 40, "Weight, kg", function(w) return w.Weight end, lower = true,
     fmt = function(v) return string.format("%d.%d", v / 1000, v % 1000 / 100) end},
    {"Cost", 62, "Cost", function(w) return w.Cost end, lower = true},
    {"H5", 36, "CTH % hipfire (aim 0), 5 tiles, standing target", function(w, c) return ConeCTH(w, c.shooter, 0, 5) end},
    {"H10", 38, "CTH % hipfire, 10 tiles", function(w, c) return ConeCTH(w, c.shooter, 0, 10) end},
    {"A20", 38, "CTH % full aim, 20 tiles", function(w, c) return ConeCTH(w, c.shooter, w.MaxAimActions or 3, 20) end},
    {"A30", 38, "CTH % full aim, 30 tiles", function(w, c) return ConeCTH(w, c.shooter, w.MaxAimActions or 3, 30) end},
    {"A40", 38, "CTH % full aim, 40 tiles (10 tiles saturates at MaxCTH)",
     function(w, c) return ConeCTH(w, c.shooter, w.MaxAimActions or 3, 40) end},
    {"B10", 38, "Selective burst, aim 3: mean CTH of each round, 10 tiles", function(w, c)
        if not (BurstModes(w)) then return end
        local action = CombatActions.BurstFire
        return StringCTH(w, c.shooter, action, w:GetAutofireShots(action), 10)
    end},
    {"F10", 38, "Autofire 3 rounds, aim 3: mean CTH of each round, 10 tiles", function(w, c)
        if not select(2, BurstModes(w)) then return end
        return StringCTH(w, c.shooter, Rat_AutoFireView(3, Rat_AutoAttackId(w)), 3, 10)
    end},
}

local State = {rows = false, sort = "Cls", desc = false, cls = false, merc = false, stance = 1, filter = ""}

local function SelectedUnit()
    return IsKindOf(SelectedObj, "Unit") and SelectedObj or nil
end

local function ComputeRow(id, ctx)
    local w = PlaceInventoryItem(id)
    if not w then return end
    local ammo = Rat_BasicAmmoClass(w)
    for _, mod in ipairs(ammo and ammo.Modifications or empty_table) do
        w:AddModifier("ammo", mod.target_prop, mod.mod_mul, mod.mod_add)
    end
    local c = {unit = ctx.unit, ap_unit = ctx.ap_unit, shooter = Shooter(w, ctx.unit, ctx.stance)}
    local row = {cls_order = table.find(ClassOrder, WeaponClass(w)) or 99}
    for _, col in ipairs(Columns) do
        local ok, v = pcall(col[4], w, c)
        row[col[1]] = ok and v or nil
        if not ok then row.err = (row.err or "") .. col[1] .. " " end
    end
    DoneObject(w)
    return row
end

local function Ids()
    local ids = {}
    ForEachPreset("InventoryItemCompositeDef", function(p)
        local cls = g_Classes[p.id]
        if Rat_IsLiveFirearm(cls) and not IsKindOf(cls, "HeavyWeapon") then ids[#ids + 1] = p.id end
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

local function Render(dlg)
    local rows = VisibleRows()
    for i, col in ipairs(Columns) do
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
            if type(v) == "number" and lo and hi > lo then
                local t = MulDivRound(v - lo, 1000, hi - lo)
                s = ScaleColor(col.lower and 1000 - t or t) .. s .. "</color>"
            elseif k % 2 == 0 then
                s = "<color 175 175 175>" .. s .. "</color>"
            end
            lines[k] = s
        end
        dlg["idCol" .. i]:SetText(table.concat(lines, "\n"))
        local head = dlg["idHead" .. i]
        head:SetText(col[1] .. (State.sort == col[1] and (State.desc and " v" or " ^") or ""))
    end
    SetStatus(dlg, string.format("%d / %d guns  |  shooter: %s, %s", #rows, #(State.rows or empty_table),
        State.merc and (SelectedUnit() and SelectedUnit().session_id or "no merc selected -> stat 100") or "stat 100, gun alone",
        Stances[State.stance]))
end

local function Recompute(dlg)
    if rawget(dlg, "rat_thread") then return end
    rawset(dlg, "rat_thread", CreateRealTimeThread(function()
        local unit = State.merc and SelectedUnit() or nil
        local ctx = {unit = unit, ap_unit = SelectedUnit(), stance = Stances[State.stance]}
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

local function CsvCell(v)
    if v == nil or v == false then return "" end
    v = tostring(v)
    if v:find('[,"\n]') then v = '"' .. v:gsub('"', '""') .. '"' end
    return v
end

local function ExportCSV(dlg)
    local out = {}
    local head = {}
    for i, col in ipairs(Columns) do head[i] = col[1] end
    out[1] = table.concat(head, ",")
    for _, r in ipairs(VisibleRows()) do
        local cells = {}
        for i, col in ipairs(Columns) do
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

local function Build()
    local dlg = XWindow:new({
        Id = sheet_id,
        IdNode = true,
        Margins = box(30, 30, 30, 30),
        Padding = box(10, 8, 10, 8),
        LayoutMethod = "VList",
        LayoutVSpacing = 6,
        Background = RGBA(12, 12, 12, 235),
        HandleMouse = true,
        ZOrder = 1000,
    }, terminal.desktop)
    dlg.OnShortcut = function(self, shortcut, ...)
        if shortcut == "Escape" or shortcut == "ButtonB" then self:Close() return "break" end
        return XWindow.OnShortcut(self, shortcut, ...)
    end

    local bar = XWindow:new({LayoutMethod = "HList", LayoutHSpacing = 6}, dlg)
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
    local cls_list = {false, "AR", "SMG", "MG", "SR", "Rifle", "SG", "Pistol", "Rev"}
    local cls_btn
    cls_btn = Button(bar, "Class: all", function()
        local i = (table.find(cls_list, State.cls) or 1) % #cls_list + 1
        State.cls = cls_list[i]
        cls_btn:SetText("Class: " .. (State.cls or "all"))
        Render(dlg)
    end)
    cls_btn:SetText("Class: " .. (State.cls or "all"))
    local merc_btn
    merc_btn = Button(bar, "", function()
        State.merc = not State.merc
        merc_btn:SetText(State.merc and "Shooter: selected merc" or "Shooter: stat 100")
        Recompute(dlg)
    end, {RolloverText = Untranslated("Stat 100 = the gun alone, like the rollover's grey bracket")})
    merc_btn:SetText(State.merc and "Shooter: selected merc" or "Shooter: stat 100")
    local stance_btn
    stance_btn = Button(bar, "", function()
        State.stance = State.stance % #Stances + 1
        stance_btn:SetText("Stance: " .. Stances[State.stance])
        Recompute(dlg)
    end, {RolloverText = Untranslated("Shooter stance for the CTH columns; the target is always standing")})
    stance_btn:SetText("Stance: " .. Stances[State.stance])
    Button(bar, "Recompute", function() Recompute(dlg) end)
    Button(bar, "Export CSV", function() ExportCSV(dlg) end,
        {RolloverText = Untranslated("Visible rows, current sort, to %AppData%/Jagged Alliance 3/RatoWeaponSheet.csv")})
    Button(bar, "Close", function() dlg:Close() end)
    XText:new({Id = "idStatus", Translate = false, TextStyle = "SatelliteContextMenuText", VAlign = "center"}, bar)
        :SetTextColor(RGB(200, 180, 120))

    local head = XWindow:new({LayoutMethod = "HList", Background = RGBA(35, 35, 35, 255)}, dlg)
    local list_box = XWindow:new({}, dlg)
    XSleekScroll:new({Id = "idSheetScroll", Target = "idSheet", Dock = "right", Margins = box(4, 0, 0, 0), AutoHide = true}, list_box)
    local area = XScrollArea:new({
        Id = "idSheet",
        IdNode = false,
        VScroll = "idSheetScroll",
        LayoutMethod = "HList",
        MouseWheelStep = 80,
    }, list_box)
    for i, col in ipairs(Columns) do
        local key = col[1]
        Button(head, key, function()
            if State.sort == key then State.desc = not State.desc else State.sort, State.desc = key, not col.text end
            Render(dlg)
        end, {
            Id = "idHead" .. i,
            MinWidth = col[2], MaxWidth = col[2],
            Padding = box(3, 2, 3, 2),
            Background = RGBA(0, 0, 0, 0),
            RolloverText = Untranslated(col[3]),
        })
        XText:new({
            Id = "idCol" .. i,
            Translate = false,
            TextStyle = "SatelliteContextMenuText",
            MinWidth = col[2], MaxWidth = col[2],
            Padding = box(3, 0, 3, 0),
            WordWrap = false,
            Clip = "self",
        }, area)
    end
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
