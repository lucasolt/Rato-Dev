function rebuild()
    rat_apply_changes()
    disable_unpatched_shop()
	redefine_Quick_reload_button()

	GBO_ApplyOptions()
    CUAEBuildWeaponTables()
	
    print("RATO Dev -- Rebuild complete")
end




OnMsg.DataLoaded = not FirstLoad and rebuild()	