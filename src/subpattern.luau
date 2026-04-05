--!strict
--!optimize 2

local subpattern = {}

-- Resolves (?&name) references by textual substitution wrapped in (?:...).
-- Keys are sorted for deterministic resolution order.
function subpattern.resolve(
    subpatterns: { [string]: string }?,
    patterns: { [string]: string }
): { [string]: string }
    local resolved_subs: { [string]: string } = {}
    local sub_order: { string } = {}

    if subpatterns then
        for name in subpatterns do
            table.insert(sub_order, name)
        end
        table.sort(sub_order)

        for _, name in sub_order do
            local value = subpatterns[name]
            for _, resolved_name in sub_order do
                if resolved_subs[resolved_name] then
                    value = string.gsub(value, "%(%?%&" .. resolved_name .. "%)", "(?:" .. resolved_subs[resolved_name] .. ")")
                end
            end
            resolved_subs[name] = value
        end
    end

    local result: { [string]: string } = {}
    for name, value in patterns do
        local resolved = value
        for _, sub_name in sub_order do
            resolved = string.gsub(resolved, "%(%?%&" .. sub_name .. "%)", "(?:" .. resolved_subs[sub_name] .. ")")
        end
        result[name] = resolved
    end

    return result
end

return subpattern
