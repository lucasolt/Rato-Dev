function rebuild()
    rat_apply_changes()
    disable_unpatched_shop()
	redefine_Quick_reload_button()

	GBO_ApplyOptions()
    CUAEBuildWeaponTables()
	
    print("RATO Dev -- Rebuild complete")
end




-- rebuild on hot-reload only; registering the `and` expression handed Msg a boolean on first load
if not FirstLoad then rebuild() end	