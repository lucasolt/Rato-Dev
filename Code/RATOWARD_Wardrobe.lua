-- Mix-and-match wardrobe: a per-merc AppearancePreset assembled from parts of existing presets, kept in the save.

-- [session_id] = {gender, base, prev, parts = {[slot] = part}}
-- part = {e = entity, c = color source preset, p = placement source preset} or baked {e, col, h, place}
GameVar("gv_RatoWardrobe", {})

local panel_id = "idRatoWardrobe"
local preset_group = "RatoWardrobe"
local storage_key = "rat_wardrobe_looks"
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
local color_fields = {}
for i = 1, 3 do
    table.iappend(color_fields, {"EditableColor" .. i, "EditableRoughness" .. i, "EditableMetallic" .. i})
end

local catalog

local function PresetGender(p)
    local body = p.Body and g_Classes[p.Body]
    if IsKindOf(body, "CharacterBodyMale") then return "Male" end
    if IsKindOf(body, "CharacterBodyFemale") then return "Female" end
end

local function ColorToRaw(cs)
    if not cs then return end
    local r = {ColorizationPalette = cs.ColorizationPalette}
    for _, f in ipairs(color_fields) do r[f] = cs[f] end
    return r
end

local function RawToColor(r)
    local cs = ColorizationPropSet:new({})
    for _, f in ipairs(color_fields) do
        if r[f] then cs:SetProperty(f, r[f]) end
    end
    cs.ColorizationPalette = r.ColorizationPalette
    return cs
end

local function HairOf(p)
    local h = {}
    for i, f in ipairs(hair_params) do h[i] = p[f] end
    return h
end

local function RawKey(col, h)
    if not col then return end
    local k = {}
    for _, f in ipairs(color_fields) do k[#k + 1] = tostring(col[f]) end
    for i = 1, #hair_params do k[#k + 1] = tostring(h and h[i]) end
    return table.concat(k, ",")
end

local function ColorKey(p, slot)
    return RawKey(ColorToRaw(p[slot .. "Color"]), slot == "Hair" and HairOf(p) or nil)
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

local function PartColor(s, slot)
    if s.col then return s.col, s.h end
    local cp = AppearancePresets[s.c] or AppearancePresets[s.p]
    if not cp then return end
    return ColorToRaw(cp[slot .. "Color"]), slot == "Hair" and HairOf(cp) or nil
end

local function PartPlace(s, slot)
    if s.place then return s.place end
    local sp = AppearancePresets[s.p]
    local r = {}
    for _, f in ipairs(placement[slot] or empty_table) do r[f] = sp and sp[f] end
    return r
end

local function PresetProps(id, group, parts)
    local t = {id = id, group = group}
    for _, slot in ipairs(slots) do
        local s = parts[slot]
        t[slot] = s and s.e or ""
        if s then
            local col, h = PartColor(s, slot)
            t[slot .. "Color"] = col and RawToColor(col) or nil
            for f, v in pairs(PartPlace(s, slot)) do t[f] = v end
            if slot == "Hair" and h then
                for i, f in ipairs(hair_params) do t[f] = h[i] end
            end
        end
    end
    return t
end

local function BuildPreset(id, spec)
    local pid = PresetId(id)
    local old = AppearancePresets[pid]
    if old then old:delete() end
    AppearancePreset:new(PresetProps(pid, preset_group, spec.parts)):Register()
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

-- Looks: plain-value copies of a spec, independent of the presets they were picked from.

local function Bake(spec, name)
    local parts = {}
    for slot, s in pairs(spec.parts) do
        local col, h = PartColor(s, slot)
        parts[slot] = {e = s.e, col = col, h = h, place = placement[slot] and PartPlace(s, slot) or nil}
    end
    return {name = name, gender = spec.gender, parts = parts}
end

-- Turns a PlaceObj props list (pairs, map or both) into a map.
local function PropsMap(props)
    local m = {}
    for k, v in pairs(props or empty_table) do
        if type(k) ~= "number" then m[k] = v end
    end
    for i = 1, #(props or empty_table) - 1, 2 do m[props[i]] = props[i + 1] end
    return m
end

local function LookFromPresetProps(m)
    local gender = PresetGender(m)
    if not gender then return end
    local parts = {}
    for _, slot in ipairs(slots) do
        local e = m[slot]
        if e and e ~= "" then
            local cw = m[slot .. "Color"]
            local place = {}
            for _, f in ipairs(placement[slot] or empty_table) do place[f] = m[f] end
            parts[slot] = {
                e = e,
                col = type(cw) == "table" and PropsMap(cw.props) or nil,
                h = slot == "Hair" and HairOf(m) or nil,
                place = placement[slot] and place or nil,
            }
        end
    end
    return {name = m.id or "pasted", gender = gender, parts = parts}
end

-- Accepts a copied look or a ModItemAppearancePreset / AppearancePreset block (e.g. from another mod's items.lua).
local function ParseLook(text)
    text = (text or ""):gsub("^[%s,]+", ""):gsub("[%s,]+$", "")
    local env = {
        RGBA = RGBA, RGB = RGB, point = point,
        T = function(...) return "" end,
        PlaceObj = function(class, props) return {class = class, props = props} end,
    }
    local err, v = LuaCodeToTuple(text, env)
    if err or type(v) ~= "table" then return nil, "clipboard holds no look" end
    if v.parts then return v end
    if v.class == "ModItemAppearancePreset" or v.class == "AppearancePreset" then
        local look = LookFromPresetProps(PropsMap(v.props))
        if look then return look end
    end
    return nil, "clipboard holds no look"
end

local function SpecFromLook(spec, look)
    if look.gender ~= spec.gender then
        return string.format("look is %s, merc is %s", tostring(look.gender), spec.gender)
    end
    local parts, dropped = {}, 0
    for slot, s in pairs(look.parts or empty_table) do
        if table.find(slots, slot) and IsValidEntity(s.e) then
            parts[slot] = table.copy(s, "deep")
        else
            dropped = dropped + 1
        end
    end
    if not (parts.Body and parts.Head) then return "look has no valid body or head" end
    spec.base, spec.parts = false, parts
    return dropped > 0 and string.format("applied, %d missing parts skipped", dropped) or "applied " .. tostring(look.name)
end

local function Library()
    CurrentModStorageTable[storage_key] = CurrentModStorageTable[storage_key] or {}
    return CurrentModStorageTable[storage_key]
end

local function WriteLibrary()
    local err = WriteModPersistentStorageTable()
    return err and ("storage error: " .. tostring(err))
end

-- UI

-- Only a change stores the spec, so viewing a merc leaves the save untouched.
local function GetSpec(id, store)
    gv_RatoWardrobe = gv_RatoWardrobe or {}
    local spec = gv_RatoWardrobe[id]
    if spec then return spec end
    spec = SpecFromPreset(CurrentAppearance(id))
    if not (spec and store) then return spec end
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
    spec.parts[slot] = {e = e, p = src, c = old and old.c or src, col = old and old.col, h = old and old.h}
end

local function ColorIndex(spec, slot)
    local s = spec.parts[slot]
    local key = s and RawKey(PartColor(s, slot))
    local idx = Catalog(spec.gender).color_idx[slot]
    return key and idx and idx[key]
end

local function StepColor(spec, slot, step)
    local s = spec.parts[slot]
    local list = Catalog(spec.gender).colors[slot]
    if not (s and list and #list > 0) then return end
    local n = #list
    local i = step == "rnd" and AsyncRand(n) + 1 or ((ColorIndex(spec, slot) or 1) - 1 + step) % n + 1
    s.c, s.col, s.h = list[i], nil, nil
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

local function SetStatus(panel, text)
    panel.idStatus:SetText(text or "")
end

local Refresh

local function Change(panel, fn)
    local id = rawget(panel, "rat_unit")
    local spec = id and GetSpec(id, "store")
    if not spec then return end
    local msg = fn(spec)
    Commit(id)
    Refresh(panel)
    if msg then SetStatus(panel, msg) end
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

local function LookName(panel, spec)
    local typed = panel.idName:GetText()
    if typed and typed ~= "" then return typed end
    local id = rawget(panel, "rat_unit")
    return string.format("%s %d", tostring(id), #Library() + 1)
end

local function RefreshLibrary(panel)
    local lib = Library()
    local i = Clamp(rawget(panel, "rat_lib_idx") or 1, 1, Max(#lib, 1))
    rawset(panel, "rat_lib_idx", i)
    local look = lib[i]
    panel.idLib:SetText(look and string.format("%s  [%s]  (%d/%d)", tostring(look.name), tostring(look.gender), i, #lib)
        or "no saved looks")
end

Refresh = function(panel)
    local id = rawget(panel, "rat_unit")
    local spec = id and GetSpec(id)
    local ud = id and gv_UnitData[id]
    panel.idMerc:SetText(id and string.format("%s%s", id, ud and IsImpUnit(ud) and "  (IMP)" or "") or "no hired merc")
    RefreshLibrary(panel)
    if not spec then
        panel.idBase:SetText("")
        for _, label in pairs(rawget(panel, "rat_labels")) do label:SetText("") end
        return
    end
    local g = Catalog(spec.gender)
    panel.idBase:SetText(string.format("%s  (%d/%d)  %s", spec.base or "custom",
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
    SetStatus(panel, IsValid(g_Units[id]) and "" or "not on the map: the look applies when the merc spawns")
end

local function SelectMerc(panel, step)
    local list = HiredMercs()
    rawset(panel, "rat_unit", Cycle(list, rawget(panel, "rat_unit"), step) or false)
    Refresh(panel)
end

local function BuildLookRows(panel)
    local lib_row = XWindow:new({LayoutMethod = "HList", LayoutHSpacing = 4, Margins = box(0, 4, 0, 0)}, panel)
    MakeText(lib_row, {MinWidth = 60, MaxWidth = 60}):SetText("Saved")
    local function lib_step(step)
        return function()
            local n = #Library()
            if n == 0 then return end
            rawset(panel, "rat_lib_idx", ((rawget(panel, "rat_lib_idx") or 1) - 1 + step) % n + 1)
            RefreshLibrary(panel)
        end
    end
    MakeButton(lib_row, "<", lib_step(-1))
    MakeButton(lib_row, ">", lib_step(1))
    MakeButton(lib_row, "wear", function()
        local look = Library()[rawget(panel, "rat_lib_idx") or 1]
        if look then Change(panel, function(spec) return SpecFromLook(spec, look) end) end
    end)
    MakeButton(lib_row, "forget", function()
        local lib, i = Library(), rawget(panel, "rat_lib_idx") or 1
        local look = table.remove(lib, i)
        if not look then return end
        local err = WriteLibrary()
        RefreshLibrary(panel)
        SetStatus(panel, err or ("removed " .. tostring(look.name)))
    end)
    MakeText(lib_row, {Id = "idLib"})

    local io_row = XWindow:new({LayoutMethod = "HList", LayoutHSpacing = 4}, panel)
    local name = XEdit:new({
        Id = "idName",
        Hint = "look name",
        Translate = false,
        TextStyle = "SatelliteContextMenuText",
        Background = RGBA(40, 40, 40, 255),
        FocusedBackground = RGBA(55, 55, 55, 255),
        Padding = box(4, 2, 4, 2),
        MinWidth = 160,
        MaxWidth = 160,
    }, io_row)
    -- Keep typed letters away from the game's single-key shortcuts.
    name.OnShortcut = function(self, shortcut, source, ...)
        if shortcut == "Escape" then self:SetFocus(false) return "break" end
        local r = XEdit.OnShortcut(self, shortcut, source, ...)
        return r or (#shortcut == 1 and "break") or nil
    end
    local function current_look()
        local id = rawget(panel, "rat_unit")
        local spec = id and GetSpec(id)
        return spec and Bake(spec, LookName(panel, spec))
    end
    MakeButton(io_row, "Save look", function()
        local look = current_look()
        if not look then return end
        local lib = Library()
        lib[#lib + 1] = look
        local err = WriteLibrary()
        if err then table.remove(lib) end
        rawset(panel, "rat_lib_idx", #lib)
        RefreshLibrary(panel)
        SetStatus(panel, err or ("saved " .. look.name .. " (all saves and campaigns)"))
    end)
    MakeButton(io_row, "Copy", function()
        local look = current_look()
        if not look then return end
        -- A -1 limit makes CopyToClipboard do nothing; GetFromClipboard needs it to read past 1024 chars.
        CopyToClipboard(TableToLuaCode(look))
        SetStatus(panel, "look copied to the clipboard")
    end)
    MakeButton(io_row, "Paste", function()
        local look, err = ParseLook(GetFromClipboard(-1))
        if not look then return SetStatus(panel, err) end
        Change(panel, function(spec) return SpecFromLook(spec, look) end)
    end)
    MakeButton(io_row, "Copy as preset", function()
        local look = current_look()
        if not look then return end
        local pid = look.name:gsub("[^%w_]", "_")
        local code = ValueToLuaCode(AppearancePreset:new(PresetProps(pid, "IMP", look.parts)))
        CopyToClipboard((code:gsub("^PlaceObj%('AppearancePreset'", "PlaceObj('ModItemAppearancePreset'")))
        SetStatus(panel, "ModItemAppearancePreset " .. pid .. " copied, for a mod's items.lua")
    end)
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
    BuildLookRows(panel)
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
