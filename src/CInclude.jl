"""
# CInclude.jl

Include C language header files in Julia source code
(using [Clang.jl](https://github.com/JuliaInterop/Clang.jl)).

    julia> using CInclude
    julia> @cinclude "termios.h"

    [ Info: @cinclude "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/termios.h"
    ...

    julia> term = termios()
    julia> settings.c_lflag = ICANON
    julia> settings.c_cflag = CS8
    julia> cfsetspeed(Ref(settings), B38400)
    julia> tcsetattr(fd, TCSANOW, Ref(settings))
"""
module CInclude

export @cinclude


using ReadmeDocs
using Clang


function find_header(header)
    if !isfile(header)
        path = ["/usr/include"]
        if Sys.isapple()
            sdk = chomp(read(`xcrun --show-sdk-path`, String))
            push!(path, joinpath(sdk, "usr/include"))
        end
        for d in path
            h = joinpath(d, header)
            if isfile(h)
                return h
            end
        end
    end
    header
end


function wrap_header(header; lib="libc", include="", exclude="\0") 

    header = find_header(header)
    @info "@cinclude \"$header\""

    ctx = DefaultContext()
    ctx.libname = lib
    ctx.options["is_function_strictly_typed"] = false
    ctx.options["is_struct_mutable"] = true
    

    args = vcat((["-I", d] for d in find_std_headers())...)

    parse_headers!(ctx, [header], args=args)

    for unit in ctx.trans_units
        ctx.children = children(getcursor(unit))
        for (i, child) in enumerate(ctx.children)
            child_name = name(child)

            # choose which cursor to wrap
            if haskey(ctx.common_buffer, child_name) || # skip already wrapped
              !occursin(include, child_name)         || # skip not included
               occursin(exclude, child_name)            # skip excluded

                continue
            end

            ctx.children_index = i
            try
                wrap!(ctx, child)
            catch err
                if !startswith(child_name, "_")
                    @info "Can't wrap $child_name ($err)"
                end
            end
        end
    end

    template = [
        :(using CEnum),
        :(const Ctm = Base.Libc.TmStruct),
        :(const Ctime_t = UInt),
        :(const Cclock_t = UInt)]

    api = [template;
           dump_to_buffer(ctx.common_buffer);
           ctx.api_buffer]

    constructors = []

    for e in api
        if !(e isa Expr)
            continue
        end

        # Remove library name for built-in functions.
        # `ccall((:cfunc, libc), ...` => `ccall(:func, ...`)
        if e.head == :function
           args = e.args[2].args[1].args
           if args[2].args[2] == :libc
               args[2] = args[2].args[1]
           end
        end

        # Generate zero-value default constructors.
        if e.head == :struct
            T = e.args[2]
            push!(constructors, :(
                function $T()
                    $T(CInclude.czeros($T)...)
                end))
        end
    end

    [api; constructors]
end


czeros(T) =
    (hasmethod(zero, (t,)) ? zero(t) :
                t <: Tuple ? (czeros(t)...,) :
                            t(czeros(t)...)
     for t in fieldtypes(T))

README"## Interface"

README"""
    @cinclude "header.h"

Import symbols from C language `header.h` into the current module.

Note: C language headers may define a large number of symbols. To avoid
clashes with local names `@cinclude` can be used inside a sub-module. e.g.

    module SOCKET
        using CInclude
        @cinclude "sys/socket.h"
    end
    SOCKET.send(fd, buf, length(buf), SOCKET.MSG_OOB)
"""
macro cinclude(h)
    esc(quote
        for e in CInclude.wrap_header($h)
            if e isa String
                @info e
            else
                try
                    eval(e)
                catch err
                    @warn "$err in $e"
                end
            end
        end
    end)
end


end # module
