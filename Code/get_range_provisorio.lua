function FirearmBase:GetAccuracy(distance, unit, action)
	local r = GetRangeAccuracy(self, distance, unit, action)
	print("range acc:", r)
	return r
end