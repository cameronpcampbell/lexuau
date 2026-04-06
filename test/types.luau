type function union_from_components(input: { type })
    local input_len = #input
    return if input_len == 0 then nil elseif input_len == 1 then input[1] else types.unionof(table.unpack(input))
end

type function intersection_from_components(input: { type })
    local input_len = #input
    return if input_len == 0 then nil elseif input_len == 1 then input[1] else types.intersectionof(table.unpack(input))
end

type function handle_negation<T>(input: type, callback: (input: type) -> T)
    local input_tag = input.tag

    if input_tag == "negation" then
        local input_inner = input:inner()
        return types.negationof(callback(input_inner))

    else
        return callback(input)
    end
end

type function table_value_swap_remove(input: { [any]: any }, idx: number)
    -- Last item, we can just remove from the end of the input table.
    if idx == #input then
        table.remove(input, idx)

    else
        -- Swap remove optimisation.
        input[idx] = table.remove(input)
    end
end

export type function NonNullable(input: type)
    return handle_negation(input, function(input)
        local input_tag = input.tag

        if input_tag == "union" or input_tag == "intersection" then
            local components = input:components()

            for idx, component in components do
                if component == types.singleton(nil) then
                    table_value_swap_remove(components, idx)
                end
            end

            return
                if input.tag == "union" then union_from_components(components) or types.never
                else intersection_from_components(components) or types.never
        end

        return if input == types.singleton(nil) then types.never else input
    end)
end

return nil
