# What a snapshot of the catalog would cost: the catalog as one persistent map, `Base.PersistentDict`,
# where each change makes a new version that shares everything else with the old one, against the
# vector of mutable rows of today. 1 000 000 rows, each a struct the size of a catalog row.
#
# julia --threads=auto work/item-table/persistent.jl

# The fields of a catalog row (`Catalogs.Node`), without the computation and the vectors of inputs
# and readers, which a change of state shares with the old row.
struct Entry
    state::Int8
    running::Bool
    changes::UInt32
    waiting::Int32
    blocked::Int32
    priority::Int
    inherited::Int
    requested::Int
    holds::Int32
    revision::UInt64
end
mutable struct MutableEntry
    state::Int8
    running::Bool
    changes::UInt32
    waiting::Int32
    blocked::Int32
    priority::Int
    inherited::Int
    requested::Int
    holds::Int32
    revision::UInt64
end
entry(i) = Entry(1, false, 0, 0, 0, 0, 0, 0, 0, UInt64(i))

# The root that readers load: one atomic reference to the current version.
mutable struct Root
    @atomic map::Base.PersistentDict{Int,Entry}
end

const N = 1_000_000
mib(bytes) = round(bytes / 2^20; digits=1)

function build(n)
    map = Base.PersistentDict{Int,Entry}()
    for i in 1:n
        map = Base.PersistentDict(map, i => entry(i))
    end
    return map
end

# One change of state of one row, as a worker makes it: a new entry, a new version, published.
function change!(root, rows)
    for i in rows
        map = @atomic root.map
        old = map[i]
        @atomic root.map = Base.PersistentDict(map, i => Entry(old.state + Int8(1), old.running, old.changes + 1,
            old.waiting, old.blocked, old.priority, old.inherited, old.requested, old.holds, old.revision))
    end
end
function change!(vector::Vector{MutableEntry}, rows)
    for i in rows
        vector[i].state += Int8(1)
        vector[i].changes += 1
    end
end

function readall(map, rows)
    total = UInt64(0)
    for i in rows
        total += map[i].revision
    end
    return total
end

build(1000); change!(Root(build(1000)), 1:1000); readall(build(1000), 1:1000)
vector = [MutableEntry(1, false, 0, 0, 0, 0, 0, 0, 0, UInt64(i)) for i in 1:N]
change!(vector, 1:1000); readall(vector, 1:1000)

built = @timed build(N)
root = Root(built.value)
rows = rand(1:N, 1_000_000)
GC.gc()
persistent_change = @timed change!(root, rows)
vector_change = @timed change!(vector, rows)
persistent_read = @timed readall(root.map, rows)
vector_read = @timed readall(vector, rows)
GC.gc()

println("RESULT 1 000 000 rows")
println("RESULT memory: persistent map=$(mib(Base.summarysize(root.map))) MiB  vector of mutable rows=$(mib(Base.summarysize(vector))) MiB")
println("RESULT build:  persistent map=$(round(built.time; digits=2)) s")
for (name, persistent, mutable) in (("change", persistent_change, vector_change), ("read", persistent_read, vector_read))
    println("RESULT $name, per row: persistent map=$(round(1e9persistent.time / length(rows); digits=0)) ns, ",
        "$(round(Int, persistent.bytes / length(rows))) bytes allocated  vector=$(round(1e9mutable.time / length(rows); digits=0)) ns, ",
        "$(round(Int, mutable.bytes / length(rows))) bytes allocated")
end
println("RESULT GC time during the changes of the persistent map: $(round(persistent_change.gctime; digits=2)) s of $(round(persistent_change.time; digits=2)) s")
