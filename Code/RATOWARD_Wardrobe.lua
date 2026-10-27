-- Mix-and-match wardrobe: a per-merc AppearancePreset assembled from parts of existing presets, kept in the save.

-- [session_id] = {gender, base, prev, parts = {[slot] = {e = entity, c = color source preset, p = placement source preset}}}
GameVar("gv_RatoWardrobe", {})

local panel_id = "idRatoWardrobe"
local preset_group = "RatoWardrobe"
local slots = {"Body", "Head", "Hair", "Hat", "Hat2", "Shirt", "Pants", "Armor", "Chest", "Hip"}
local required = {Body = true, Head = true}
local placement = {
    Hat = {"HatSpot", "HatAttachOffsetX", "HatAttachOffsetY", "HatAttachOffsetZ", "HatAttachOffsetAngle"},
    Hat2 = {"Hat2Spot", "Hat2AttachOffsetX", "Hat2AttachOffsetY", "Hat2AttachOffsetZ", "Hat2AttachOffsetAngle"},
    Hair = {"HairSpot"},
    Chest = {"ChestSpot"},
    Hip = {"HipSpot"},
}
local hair_params = {"HairParam1", "HairParam2", "HairParam3", "HairParam4"}

local catalog

local function PresetGender(p)
    local body = p.Body and g_Classes[p.Body]
    if IsKindOf(body, "CharacterBodyMale") then return "Male" end
    if IsKindOf(body, "CharacterBodyFemale") then return "Female" end
end

local function ColorKey(p, slot)
    local cs = p[slot .. "Color"]
    if not cs then return end
    local k = {}
    for i = 1, 3 do
        k[#k + 1] = tostring(cs["EditableColor" .. i])
        k[#k + 1] = tostring(cs["EditableMetallic" .. i])
        k[#k + 1] = tostring(cs["EditableRoughness" .. i])
    end
    if slot == "Hair" then
        for _, f in ipairs(hair_params) do k[#k + 1] = tostring(p[f]) end
    end
    return table.concat(k, ",")
end

local function BuildCatalog()
    local ids = table.keys(AppearancePresets, true)
    local cat = {}
    for _, id in ipairs(ids) do
        local p = AppearancePresets[id]
        local gender = p.group ~= preset_group and PresetGender(p)
        if gender then
            local g = cat[gender] or {bases = {}, parts = {}, src = {}, colors = {}, color_idx = {}}
            cat[gender] = g
            g.bases[#g.bases + 1] = id
            for _, slot in ipairs(slots) do
                local e = p[slot]
                if e and e ~= "" and IsValidEntity(e) then
                    g.src[slot] = g.src[slot] or {}
                    if not g.src[slot][e] then
                        g.src[slot][e] = id
                        g.parts[slot] = g.parts[slot] or {}
                        table.insert(g.parts[slot], e)
                    end
                    local key = ColorKey(p, slot)
                    g.color_idx[slot] = g.color_idx[slot] or {}
                    if key and not g.color_idx[slot][key] then
                        g.colors[slot] = g.colors[slot] or {}
                        table.insert(g.colors[slot], id)
                        g.color_idx[slot][key] = #g.colors[slot]
                    end
                end
            end
        end
    end
    for _, g in pairs(cat) do
        for _, list in pairs(g.parts) do table.sort(list) end
    end
    return cat
end

local function Catalog(gender)
    catalog = catalog or BuildCatalog()
    return catalog[gender]
end

local function PresetId(id)
    return "RatoWardrobe_" .. id
end

local function BuildPreset(id, spec)
    local pid = PresetId(id)
    local t = {id = pid, group = preset_group}
    for _, slot in ipairs(slots) do
        local s = spec.parts[slot]
        local e = s and s.e or ""
        t[slot] = e
        if e ~= "" then
            local cp = AppearancePresets[s.c] or AppearancePresets[s.p]
            t[slot .. "Color"] = cp and cp[slot .. "Color"] or nil
            local sp = AppearancePresets[s.p]
            for _, f in ipairs(placement[slot] or empty_table) do t[f] = sp and sp[f] or nil end
            if slot == "Hair" and cp then
                for _, f in ipairs(hair_params) do t[f] = cp[f] end
            end
        end
    end
    local old = AppearancePresets[pid]
    if old then old:delete() end
    AppearancePreset:new(t):Register()
    return pid
end

local function SpecFromPreset(preset_id)
    local p = AppearancePresets[preset_id]
    local gender = p and PresetGender(p)
    if not gender then return end
    local parts = {}
    for _, slot in ipairs(slots) do
        local e = p[slot]
        if e and e ~= "" then parts[slot] = {e = e, c = preset_id, p = preset_id} end
    end
    return {gender = gender, base = preset_id, parts = parts}
end

local function ApplyToUnit(id)
    local unit = g_Units[id]
    if not IsValid(unit) or unit:IsDead() then return end
    local anim, phase = unit:GetStateText(), unit:GetAnimPhase()
    unit:ApplyAppearance(unit:ChooseAppearance(), true)
    unit:SetStateText(anim, const.eKeepComponentTargets)
    unit:SetAnimPhase(1, phase)
    unit:UpdateOutfit()
end

local function Commit(id)
    local ud = gv_UnitData[id]
    local spec = gv_RatoWardrobe and gv_RatoWardrobe[id]
    if not ud then return end
    if spec then
        ud.ForcedAppearance = BuildPreset(id, spec)
    end
    ApplyToUnit(id)
end

function RatoWardrobe_Revert(id)
    local spec = gv_RatoWardrobe and gv_RatoWardrobe[id]
    if not spec then return end
    gv_RatoWardrobe[id] = nil
    local ud = gv_UnitData[id]
    if ud then ud.ForcedAppearance = spec.prev or false end
    local p = AppearancePresets[PresetId(id)]
    ApplyToUnit(id)
    if p then p:delete() end
end

local function CurrentAppearance(id)
    local unit = g_Units[id]
    if IsValid(unit) and AppearancePresets[unit.Appearance] then return unit.Appearance end
    local ud = gv_UnitData[id]
    local forced = ud and ud.ForcedAppearance
    if forced and AppearancePresets[forced] then return forced end
    return ChooseUnitAppearance(id, IsValid(unit) and unit.handle or nil)
end

-- Runs before EnterSector spawns the units; ForcedAppearance is not saved with UnitData, so set it again.
function OnMsg.PreLoadSessionData()
    for id, spec in pairs(gv_RatoWardrobe or empty_table) do
        local ud = gv_UnitData[id]
        if ud then ud.ForcedAppearance = BuildPreset(id, spec) end
    end
end

function OnMsg.ModsReloaded()
    catalog = nil
end

-- UI

local function GetSpec(id)
    gv_RatoWardrobe = gv_RatoWardrobe or {}
    local spec = gv_RatoWardrobe[id]
    if spec then return spec end
    spec = SpecFromPreset(CurrentAppearance(id))
    if not spec then return end
    local ud = gv_UnitData[id]
    spec.prev = ud and ud.ForcedAppearance or false
    gv_RatoWardrobe[id] = spec
    return spec
end

local function Cycle(list, cur, step)
    local n = #list
    if n == 0 then return end
    if step == "rnd" then return list[AsyncRand(n) + 1] end
    local i = table.find(list, cur) or 0
    return list[(i - 1 + step) % n + 1]
end

local function SetPart(spec, slot, e)
    if not e or e == "" then
        spec.parts[slot] = nil
        return
    end
    local g = Catalog(spec.gender)
    local src = g.src[slot] and g.src[slot][e]
    local old = spec.parts[slot]
    spec.parts[slot] = {e = e, p = src, c = old and old.c or src}
end

local function ColorIndex(spec, slot)
    local s = spec.parts[slot]
    local cp = s and AppearancePresets[s.c]
    local key = cp and ColorKey(cp, slot)
    local idx = Catalog(spec.gender).color_idx[slot]
    return key and idx and idx[key]
end

local function StepColor(spec, slot, step)
    local s = spec.parts[slot]
    local list = Catalog(spec.gender).colors[slot]
    if not (s and list and #list > 0) then return end
    local n = #list
    local i = step == "rnd" and AsyncRand(n) + 1 or ((ColorIndex(spec, slot) or 1) - 1 + step) % n + 1
    s.c = list[i]
end

local function Randomize(spec)
    local g = Catalog(spec.gender)
    for _, slot in ipairs(slots) do
        local list = g.parts[slot] or empty_table
        -- Optional slots are left empty half the time, or every merc ends up wearing two hats.
        if #list > 0 and (required[slot] or AsyncRand(2) == 0) then
            SetPart(spec, slot, list[AsyncRand(#list) + 1])
            StepColor(spec, slot, "rnd")
        else
            spec.parts[slot] = nil
        end
    end
end

local function HiredMercs()
    local list = {}
    for id, ud in pairs(gv_UnitData) do
        if ud.HireStatus == "Hired" then list[#list + 1] = id end
    end
    table.sort(list, function(a, b)
        local ia, ib = IsImpUnit(gv_UnitData[a]), IsImpUnit(gv_UnitData[b])
        if ia ~= ib then return ia end
        return a < b
    end)
    return list
end

local function MakeButton(parent, text, on_press, props)
    local t = {
        Text = text,
        Translate = false,
        TextStyle = "SatelliteContextMenuText",
        Background = RGBA(60, 60, 60, 220),
        RolloverBackground = RGBA(120, 100, 50, 240),
        PressedBackground = RGBA(160, 130, 60, 255),
        Padding = box(6, 2, 6, 2),
        VAlign = "center",
        OnPress = on_press,
    }
    for k, v in pairs(props or empty_table) do t[k] = v end
    return XTextButton:new(t, parent)
end

local function MakeText(parent, props)
    local t = {Translate = false, TextStyle = "SatelliteContextMenuText", VAlign = "center"}
    for k, v in pairs(props or empty_table) do t[k] = v end
    return XText:new(t, parent)
end

local Refresh

local function Change(panel, fn)
    local id = rawget(panel, "rat_unit")
    local spec = id and GetSpec(id)
    if not spec then return end
    fn(spec)
    Commit(id)
    Refresh(panel)
end

local function BuildSlotRow(panel, body, slot)
    local row = XWindow:new({LayoutMethod = "HList", LayoutHSpacing = 4}, body)
    MakeText(row, {MinWidth = 60, MaxWidth = 60}):SetText(slot)
    local function part_step(step)
        return function()
            Change(panel, function(spec)
                local list = Catalog(spec.gender).parts[slot] or empty_table
                SetPart(spec, slot, Cycle(list, spec.parts[slot] and spec.parts[slot].e, step))
            end)
        end
    end
    MakeButton(row, "<", part_step(-1))
    MakeButton(row, ">", part_step(1))
    MakeButton(row, "?", part_step("rnd"))
    if not required[slot] then
        MakeButton(row, "x", function() Change(panel, function(spec) spec.parts[slot] = nil end) end)
    end
    local function color_step(step)
        return function() Change(panel, function(spec) StepColor(spec, slot, step) end) end
    end
    MakeButton(row, "col <", color_step(-1))
    MakeButton(row, ">", color_step(1))
    MakeButton(row, "?", color_step("rnd"))
    rawget(panel, "rat_labels")[slot] = MakeText(row, {MinWidth = 330})
end

Refresh = function(panel)
    local id = rawget(panel, "rat_unit")
    local spec = id and GetSpec(id)
    local ud = id and gv_UnitData[id]
    panel.idMerc:SetText(id and string.format("%s%s", id, ud and IsImpUnit(ud) and "  (IMP)" or "") or "no hired merc")
    if not spec then
        panel.idBase:SetText("")
        for _, label in pairs(rawget(panel, "rat_labels")) do label:SetText("") end
        return
    end
    local g = Catalog(spec.gender)
    panel.idBase:SetText(string.format("%s  (%d/%d)  %s", spec.base or "-",
        table.find(g.bases, spec.base) or 0, #g.bases, spec.gender))
    for slot, label in pairs(rawget(panel, "rat_labels")) do
        local s = spec.parts[slot]
        local parts = g.parts[slot] or empty_table
        local colors = g.colors[slot] or empty_table
        if s then
            label:SetText(string.format("%s (%d/%d)  col %d/%d", s.e, table.find(parts, s.e) or 0, #parts,
                ColorIndex(spec, slot) or 0, #colors))
        else
            label:SetText(string.format("-  (%d options)", #parts))
        end
    end
    panel.idStatus:SetText(IsValid(g_Units[id]) and "" or "not on the map: the look applies when the merc spawns")
end

local function SelectMerc(panel, step)
    local list = HiredMercs()
    rawset(panel, "rat_unit", Cycle(list, rawget(panel, "rat_unit"), step) or false)
    Refresh(panel)
end

local function Build(unit_id)
    local panel = XWindow:new({
        Id = panel_id,
        IdNode = true,
        HAlign = "left",
        VAlign = "top",
        Margins = box(130, 80, 0, 0),
        Padding = box(10, 8, 10, 8),
        LayoutMethod = "VList",
        LayoutVSpacing = 4,
        Background = RGBA(15, 15, 15, 225),
        HandleMouse = true,
        ZOrder = 1000,
    }, terminal.desktop)
    panel.OnShortcut = function(self, shortcut, ...)
        if shortcut == "Escape" or shortcut == "ButtonB" then self:Close() return "break" end
        return XWindow.OnShortcut(self, shortcut, ...)
    end
    rawset(panel, "rat_labels", {})
    rawset(panel, "rat_unit", unit_id or false)

    local header = XWindow:new({LayoutMethod = "HList", LayoutHSpacing = 4}, panel)
    local title = MakeText(header)
    title:SetTextColor(RGB(230, 200, 120))
    title:SetText("WARDROBE")
    MakeButton(header, "<", function() SelectMerc(panel, -1) end)
    MakeButton(header, ">", function() SelectMerc(panel, 1) end)
    MakeText(header, {Id = "idMerc", MinWidth = 240})
    MakeButton(header, "close", function() panel:Close() end)

    local base_row = XWindow:new({LayoutMethod = "HList", LayoutHSpacing = 4}, panel)
    MakeText(base_row, {MinWidth = 60, MaxWidth = 60}):SetText("Outfit")
    local function base_step(step)
        return function()
            Change(panel, function(spec)
                local new = SpecFromPreset(Cycle(Catalog(spec.gender).bases, spec.base, step))
                if new then
                    spec.base, spec.parts = new.base, new.parts
                end
            end)
        end
    end
    MakeButton(base_row, "<", base_step(-1))
    MakeButton(base_row, ">", base_step(1))
    MakeButton(base_row, "?", base_step("rnd"))
    MakeText(base_row, {Id = "idBase"})

    for _, slot in ipairs(slots) do
        BuildSlotRow(panel, panel, slot)
    end

    local actions = XWindow:new({LayoutMethod = "HList", LayoutHSpacing = 6, Margins = box(0, 4, 0, 0)}, panel)
    MakeButton(actions, "Random look", function() Change(panel, Randomize) end)
    MakeButton(actions, "Revert to original", function()
        local id = rawget(panel, "rat_unit")
        if id then RatoWardrobe_Revert(id) end
        Refresh(panel)
    end)
    MakeText(panel, {Id = "idStatus"}):SetTextColor(RGB(200, 180, 120))

    panel:Open()
    if not unit_id then SelectMerc(panel, 1) else Refresh(panel) end
    return panel
end

function RatoWardrobe_Open(unit_id)
    local old = terminal.desktop:ResolveId(panel_id)
    if old then old:Close() return end
    local sel = IsKindOf(SelectedObj, "Unit") and SelectedObj.session_id
    unit_id = unit_id or (sel and gv_UnitData[sel] and gv_UnitData[sel].HireStatus == "Hired" and sel)
    return Build(unit_id)
end

function OnMsg.Shortcuts(host)
    XAction:new({
        ActionId = "RatoWardrobe",
        ActionTranslate = false,
        ActionName = "Rato Wardrobe",
        ActionShortcut = "Ctrl-Alt-W",
        OnAction = function() RatoWardrobe_Open() end,
    }, host)
end
