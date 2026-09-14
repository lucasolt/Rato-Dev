
function reapplyComps()
	for i, unit in ipairs(g_Units) do
		GBO_GeneralUnitItemUpdate(unit)
	end
end