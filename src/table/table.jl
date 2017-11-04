import IndexedTables: NextTable, table, colnames, reindex,
                      excludecols, showtable
import Dagger: domainchunks, chunks

# re-export the essentials
export distribute, chunks, compute, free!

const IndexTuple = Union{Tuple, NamedTuple}

"""
    IndexSpace(interval, boundingrect, nrows)

Metadata about an chunk.

- `interval`: An `Interval` object with the first and the last index tuples.
- `boundingrect`: An `Interval` object with the lowest and the highest indices as tuples.
- `nrows`: A `Nullable{Int}` of number of rows in the NDSparse, if knowable.
"""
struct IndexSpace{T<:IndexTuple}
    interval::Interval{T}
    boundingrect::Interval{T}
    nrows::Nullable{Int}
end

"""
A distributed table
"""
struct DNextTable{T,K}
    # primary key columns
    pkey::Vector{Int}
    # extent of values in the pkeys
    domains::Vector{IndexSpace{K}}
    chunks::Vector
end

function Dagger.domain(t::NextTable)
    ks = pkeys(t)
    T = eltype(ks)

    if isempty(t)
        return EmptySpace{T}()
    end

    wrap = T<:NamedTuple ? T : tuple

    interval = Interval(wrap(first(ks)...), wrap(last(ks)...))
    cs = astuple(columns(ks))
    extr = map(extrema, cs[2:end]) # we use first and last value of first column
    boundingrect = Interval(wrap(first(cs[1]), map(first, extr)...),
                            wrap(last(cs[1]), map(last, extr)...))
    return t.pkey => IndexSpace{T}(interval, boundingrect, Nullable{Int}(length(t)))
end

function table(::Val{:distributed}, tup::Tup; chunks=nothing, kwargs...)
    if chunks === nothing
        # this means the vectors are distributed.
        # pick the first distributed vector and distribute
        # all others similarly
        idx = findfirst(x->isa(x, ArrayOp), tup)
        if idx == 0
            error("Don't know how to distribute. specify `chunks`")
        end
        darr = tup[idx]
        ds = domainchunks(darr)
        darrays = map(x->distribute(x, ds), tup)
    else
        darrays = map(x->distribute(x, chunks), tup)
    end

    if isempty(darrays)
        error("Table must be constructed with at least one column")
    end

    nchunks = length(darrays[1].chunks)
    cs = Array{Any}(nchunks)
    names = isa(tup, NamedTuple) ? fieldnames(tup) : nothing
    f = delayed((cs...) -> table(cs...; names=names, kwargs...))
    for i = 1:nchunks
        cs[i] = f(map(x->x.chunks[i], darrays)...)
    end
    fromchunks(cs)
end

Base.eltype(dt::DNextTable{T}) where {T} = T
colnames{T}(t::DNextTable{T}) = fieldnames(T)

function trylength(t)::Nullable{Int}
    len = 0
    for l in map(x->x.nrows, t.domains)
        if !isnull(l)
            len = len + get(l)
        else
            return nothing
        end
    end
    return len
end

function Base.length(t::DNextTable)
    l = trylength(t)
    if isnull(l)
        error("The length of the DNDSparse is not yet known since some of its parts are not yet computed. Call `compute` to compute them, and then call `length` on the result of `compute`.")
    else
        get(l)
    end
end

"""
    fromchunks(cs)

Construct a distributed object from chunks. Calls `fromchunks(T, cs)`
where T is the type of the data in the first chunk. Computes any thunks.
"""
function fromchunks(cs::AbstractArray, args...; kwargs...)
    if any(x->isa(x, Thunk), cs)
        vec_thunk = delayed((refs...) -> [refs...]; meta=true)(cs...)
        cs = compute(get_context(), vec_thunk) # returns a vector of Chunk objects
    end
    T = chunktype(first(cs))
    fromchunks(T, cs, args...; kwargs...)
end

function fromchunks(::Type{<:NextTable}, chunks::AbstractArray,
                    domains::AbstractArray = last.(domain.(chunks)),
                    pkey=first(domain(first(chunks)));
                    K = promote_eltypes(eltype.(domains)),
                    T = promote_eltypes(eltype.(chunktype.(chunks))))

    nzidxs = find(x->!isempty(x), domains)
    domains = domains[nzidxs]

    DNextTable{T, K}(pkey, domains, chunks[nzidxs])
end

function promote_eltypes(ts::AbstractArray)
    reduce(_promote_type, ts)
end

"""
    distribute(t::Table, chunks)

Distribute a table in `chunks` pieces. Equivalent to `table(t, chunks=chunks)`.
"""
distribute(t::NextTable, chunks) = table(t, chunks=chunks, copy=false)

compute(t::DNextTable; kwargs...) = compute(get_context(), t; kwargs...)

function compute(ctx, t::DNextTable)
    if any(Dagger.istask, t.chunks)
        fromchunks(NextTable, cs)
    else
        map(Dagger.unrelease, t.chunks) # don't let this be freed
        foreach(Dagger.persist!, t.chunks)
        t
    end
end

collect(t::DNextTable) = collect(get_context(), t)

function collect(ctx::Context, dt::DNextTable{T}) where T
    cs = dt.chunks
    if length(cs) > 0
        collect(ctx, treereduce(delayed(_merge), cs))
    else
        error("Empty table")
    end
end

# merging two tables

function _merge(f, l::NextTable, r::NextTable)
    if isempty(l.pkey) && isempty(r.pkey)
        return table(vcat(rows(l), rows(r)))
    end
    a = IndexedTables._convert(NDSparse, l)
    b = IndexedTables._convert(NDSparse, r)
    if isempty(a)
        b
    elseif isempty(b)
        a
    elseif last(a.index) < first(b.index)
        # can vcat
        NDSparse(vcat(a.index, b.index), vcat(a.data, b.data),
              presorted=true, copy=false)
    elseif last(b.index) < first(a.index)
        _merge(b, a)
    else
        f(a, b) # Keep equal index elements
    end |> x -> IndexedTables._convert(NextTable, x)
end

_merge(f, x::NextTable) = x
function _merge(f, x::NextTable, y::NextTable, ys::NextTable...)
    treereduce((a,b)->_merge(f, a, b), [x,y,ys...])
end

_merge(x::NextTable, y::NextTable...) = _merge((a,b) -> merge(a, b, agg=nothing), x, y...)

function Base.show(io::IO, big::DNextTable)
    h, w = displaysize(io)
    showrows = h - 5 # This will trigger an ellipsis when there's
                     # more to see than the screen fits
    t = first(Iterators.partition(big, showrows))
    len = trylength(big)
    vals = isnull(len) ? "" : " with $(get(len)) rows"
    header = "Distributed Table$vals in $(length(big.chunks)) chunks:"
    cstyle = Dict([i=>:bold for i in t.pkey])
    showtable(io, t; header=header, ellipsis=:end, cstyle=cstyle)
end
