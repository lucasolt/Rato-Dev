-- ReloadLua re-runs Zulib's files and regenerates classes, but zz_ZCore_Setup only runs on ModsReloaded (Mod.lua:1957).
function OnMsg.AutorunEnd()
    local zulib = table.find_value(ModsLoaded, "id", "Tc3ajdY")
    -- items not loaded yet = boot; Zulib's own ModsReloaded handler covers it
    if not zulib or not zulib:ItemsLoaded() then
        return
    end
    CreateRealTimeThread(function()
        -- a full mod reload also passes through ReloadLua, then fires ModsReloaded itself
        if WaitMsg("ModsReloaded", 5000) then
            return
        end
        zz_ZCore_Setup()
        zz_ChangeMouseOver()
        print("RatoDev: re-applied Zulib caliber setup after ReloadLua")
    end)
end
