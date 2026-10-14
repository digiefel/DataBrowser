struct Item
    x::Float64
end
value(i::Item) = i.x
process(x) = value(Item(x)) + 1
