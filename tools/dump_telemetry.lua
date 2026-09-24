-- Writes Rato Dev's in-memory telemetry to disk; runs in the DAP console env, where file I/O is allowed.
(function()
    local records = RATOTEL_Records or {}
    if #records == 0 then
        return "RATOTEL_Records empty"
    end
    AsyncCreatePath("AppData/RatoTelemetry")
    local err = AsyncStringToFile("AppData/RatoTelemetry/ai_telemetry.jsonl",
                                  table.concat(records, "\n") .. "\n")
    return err and ("write failed: " .. tostring(err)) or (#records .. " records written")
end)()
