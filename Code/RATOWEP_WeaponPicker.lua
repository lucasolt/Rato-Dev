-- Debug weapon picker inside ModifyWeaponDlg: spawn any Firearm preset, edit it for free, give or drop it.

local panel_id = "idRatoWeaponPicker"
local SetPickerOpen

local function OwnerId(owner)
    return type(owner) == "string" and owner or owner and owner.session_id
end

local function OwnerUnit(id)
    return id and (gv_SatelliteView and gv_UnitData[id] or g_Units[id] or gv_UnitData[id])
end

local function FirearmEntries()
    local list = {}
    ForEachPreset("InventoryItemCompositeDef", function(p)
        local cls = g_Classes[p.id]
        if cls and IsKindOf(cls, "Firearm") and p.group ~= "Debug" then
            local name = _InternalTranslate(cls.DisplayName or "")
            list[#list + 1] = {
                id = p.id,
                name = name,
                group = p.group or "",
                live = (cls.is_vanilla_firearm or cls.is_tog_patched) and true or false,
                key = string.lower(p.id .. " " .. name .. " " .. (p.group or "")),
            }
        end
    end)
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

-- Spawned weapons sit in no inventory, so the vanilla NetSyncEvent apply can't find them: edit in place.
local function SpawnedApply(self, modSlot)
    local ctx = self.context
    local comp = self.weaponClone.components[modSlot]
    local weapon = ctx.weapon
    CreateMapRealTimeThread(function()
        local old = weapon.components[modSlot]
        weapon:SetWeaponComponent(modSlot, comp)
        weapon:UpdateVisualObj()
        self.weaponClone:SetWeaponComponent(modSlot, comp)
        ObjModified(weapon)
        local unit = OwnerUnit(ctx.rat_holder)
        if unit and not gv_SatelliteView and IsValid(unit) then
            unit:FlushCombatCache()
            unit:RecalcUIActions(true)
        end
        Msg("WeaponModifiedSuccess", weapon, unit, true, unit, modSlot, old)
    end)
end

local function PatchDialog(dlg)
    if rawget(dlg, "rat_picker_patched") then return end
    rawset(dlg, "rat_picker_patched", true)
    dlg.GetChangesCost = function(self, ...)
        local costs, any, afford, per = ModifyWeaponDlg.GetChangesCost(self, ...)
        if self.context and self.context.rat_spawned then return costs, any, true, {} end
        return costs, any, afford, per
    end
    dlg.ApplyChangesSlot = function(self, modSlot, ...)
        if self.context and self.context.rat_spawned then return SpawnedApply(self, modSlot) end
        return ModifyWeaponDlg.ApplyChangesSlot(self, modSlot, ...)
    end
end

local function SetStatus(panel, text)
    if panel.idStatus then panel.idStatus:SetText(text or "") end
end

local function SpawnWeapon(dlg, panel, id)
    local item = PlaceInventoryItem(id)
    if not item then return SetStatus(panel, "failed to spawn " .. id) end
    local owner = OwnerId(dlg.context and dlg.context.owner)
    for _, e in ipairs(owner and empty_table or dlg.allWeapons) do
        owner = owner or OwnerId(e.owner)
    end
    owner = owner or OwnerId(SelectedObj)
    local spawned = rawget(dlg, "rat_spawned_items") or {}
    rawset(dlg, "rat_spawned_items", spawned)
    spawned[#spawned + 1] = item
    local ctx = {weapon = item, slot = false, owner = owner, rat_spawned = true}
    dlg.allWeapons[#dlg.allWeapons + 1] = ctx
    dlg:SetWeapon(#dlg.allWeapons)
    SetStatus(panel, "spawned " .. id)
    SetPickerOpen(panel, false)
end

local function ReleaseSpawned(dlg, item)
    table.remove_value(rawget(dlg, "rat_spawned_items") or empty_table, item)
end

local function GiveOrDrop(dlg, panel, drop)
    local ctx = dlg.context
    if not (ctx and ctx.rat_spawned) then return SetStatus(panel, "not a spawned weapon") end
    if ctx.rat_holder then return SetStatus(panel, "already handed out") end
    local item = ctx.weapon
    local unit = OwnerUnit(OwnerId(ctx.owner)) or SelectedObj
    if not unit then return SetStatus(panel, "no merc to receive it") end
    if not drop and unit:CanAddItem("Inventory", item) then
        unit:AddItem("Inventory", item)
        ctx.rat_holder = unit.session_id
        ReleaseSpawned(dlg, item)
        ObjModified(unit)
        return SetStatus(panel, "given to " .. unit.session_id)
    end
    if gv_SatelliteView or not IsKindOf(unit, "Unit") or not IsValid(unit) then
        AddToSectorInventory(dlg.sector, {item})
        ctx.rat_holder = "stash"
        ReleaseSpawned(dlg, item)
        return SetStatus(panel, "put in " .. tostring(dlg.sector) .. " stash")
    end
    local container = GetDropContainer(unit, false, item)
    if not (container and container:AddItem("Inventory", item)) then
        return SetStatus(panel, "drop failed")
    end
    ctx.rat_holder = "ground"
    ReleaseSpawned(dlg, item)
    SetStatus(panel, "dropped at " .. unit.session_id .. "'s feet")
end

local function MakeButton(parent, text, on_press, props)
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

local function FillList(panel)
    local area = panel.idList
    area:DeleteChildren()
    local filter = string.lower(panel.idSearch:GetText() or "")
    local live_only = rawget(panel, "rat_live_only")
    local shown = 0
    for _, e in ipairs(rawget(panel, "rat_entries")) do
        if (not live_only or e.live) and (filter == "" or e.key:find(filter, 1, true)) then
            shown = shown + 1
            local label = string.format("%s%s  %s", e.live and "" or "~", e.id, e.name)
            local btn = XTextButton:new({
                Text = label,
                Translate = false,
                TextStyle = "SatelliteContextMenuText",
                HAlign = "stretch",
                Background = RGBA(0, 0, 0, 0),
                RolloverBackground = RGBA(120, 100, 50, 200),
                PressedBackground = RGBA(160, 130, 60, 255),
                Padding = box(4, 1, 4, 1),
                RolloverText = Untranslated(e.group),
                OnPress = function() SpawnWeapon(panel.rat_dlg, panel, e.id) end,
            }, area)
            btn:Open()
        end
    end
    panel.idCount:SetText(string.format("%d weapons", shown))
    area:ScrollTo(0, 0)
end

SetPickerOpen = function(panel, open)
    panel.idBody:SetVisible(open)
    panel.idToggle:SetText(open and "hide" or "pick weapon")
    if open then panel.idSearch:SetFocus() end
end

local function BuildPanel(dlg)
    if dlg:ResolveId(panel_id) then return end
    PatchDialog(dlg)

    local panel = XWindow:new({
        Id = panel_id,
        IdNode = true,
        HAlign = "right",
        VAlign = "top",
        Margins = box(0, 60, 40, 0),
        MinWidth = 420,
        MaxWidth = 420,
        MaxHeight = 640,
        Padding = box(10, 8, 10, 8),
        LayoutMethod = "VList",
        LayoutVSpacing = 6,
        Background = RGBA(15, 15, 15, 215),
        HandleMouse = true,
        ZOrder = 100,
    }, dlg)
    rawset(panel, "rat_dlg", dlg)
    rawset(panel, "rat_entries", FirearmEntries())
    rawset(panel, "rat_live_only", true)

    local header = XWindow:new({}, panel)
    local title = XText:new({
        Translate = false,
        TextStyle = "SatelliteContextMenuText",
        VAlign = "center",
    }, header)
    title:SetTextColor(RGB(230, 200, 120))
    title:SetText("DEBUG WEAPON PICKER")
    MakeButton(header, "hide", function() SetPickerOpen(panel, not panel.idBody:GetVisible()) end,
        {Id = "idToggle", Dock = "right"})
    local body = XWindow:new({
        Id = "idBody",
        LayoutMethod = "VList",
        LayoutVSpacing = 6,
        FoldWhenHidden = true,
    }, panel)

    local search = XEdit:new({
        Id = "idSearch",
        Hint = "search id / name / group",
        Translate = false,
        TextStyle = "SatelliteContextMenuText",
        Background = RGBA(40, 40, 40, 255),
        FocusedBackground = RGBA(55, 55, 55, 255),
        Padding = box(4, 2, 4, 2),
        AutoSelectAll = true,
    }, body)
    search.OnTextChanged = function() FillList(panel) end
    -- The dialog's P/N/R shortcuts would fire while typing.
    search.OnShortcut = function(self, shortcut, source, ...)
        if shortcut == "Escape" then self:SetFocus(false) return "break" end
        local r = XEdit.OnShortcut(self, shortcut, source, ...)
        return r or (#shortcut == 1 and "break") or nil
    end

    local row = XWindow:new({LayoutMethod = "HList", LayoutHSpacing = 6}, body)
    local live_btn
    live_btn = MakeButton(row, "Live set only: ON", function()
        local on = not rawget(panel, "rat_live_only")
        rawset(panel, "rat_live_only", on)
        live_btn:SetText(on and "Live set only: ON" or "Live set only: OFF")
        FillList(panel)
    end)
    XText:new({
        Id = "idCount",
        Translate = false,
        TextStyle = "SatelliteContextMenuText",
        VAlign = "center",
    }, row)

    local list_box = XWindow:new({MaxHeight = 430}, body)
    XSleekScroll:new({
        Id = "idListScroll",
        Target = "idList",
        Dock = "right",
        Margins = box(4, 0, 0, 0),
        AutoHide = true,
    }, list_box)
    XScrollArea:new({
        Id = "idList",
        IdNode = false,
        VScroll = "idListScroll",
        LayoutMethod = "VList",
        MouseWheelStep = 60,
    }, list_box)
    local actions = XWindow:new({LayoutMethod = "HList", LayoutHSpacing = 6}, panel)
    MakeButton(actions, "Give to merc", function() GiveOrDrop(dlg, panel, false) end)
    MakeButton(actions, "Drop (ground/stash)", function() GiveOrDrop(dlg, panel, true) end)

    XText:new({
        Id = "idStatus",
        Translate = false,
        TextStyle = "SatelliteContextMenuText",
    }, panel):SetTextColor(RGB(200, 180, 120))

    panel:Open()
    FillList(panel)
end

-- Spawned weapons nobody received die with the dialog.
local function WatchDialog(dlg)
    while dlg.window_state ~= "destroying" and dlg.window_state ~= "destroyed" do
        Sleep(250)
    end
    for _, item in ipairs(rawget(dlg, "rat_spawned_items") or empty_table) do
        DoneObject(item)
    end
end

function RatoWeaponPicker_Attach()
    CreateRealTimeThread(function()
        local dlg
        for _ = 1, 100 do
            local cab = GetDialog("ModifyWeaponDlg")
            dlg = cab and rawget(cab, "idModifyDialog")
            if dlg and dlg.allWeapons and dlg.weaponClone then break end
            dlg = nil
            Sleep(50)
        end
        if not dlg then return end
        BuildPanel(dlg)
        WatchDialog(dlg)
    end)
end

function OnMsg.ModifyWeaponDialogOpened()
    if Platform.developer then RatoWeaponPicker_Attach() end
end
