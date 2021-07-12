"""
# CInclude.jl

Include C language header files in Julia source code
(using [Clang.jl](https://github.com/JuliaInterop/Clang.jl)).

    julia> using CInclude
    julia> @cinclude "termios.h" quiet

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

function system_include_path()
    path = ["/usr/include"]
    if Sys.isapple()
        sdk = chomp(read(`xcrun --show-sdk-path`, String))
        push!(path, joinpath(sdk, "usr/include"))
    elseif Sys.islinux()
        try
            x = eachline(`sh -c "gcc -xc -E -v /dev/null 2>&1"`)
            line, state = iterate(x)
            while line != nothing &&
                  line != "#include <...> search starts here:"
                line, state = iterate(x, state)
            end
            line, state = iterate(x, state)
            while line != nothing &&
                  line != "End of search list."
                push!(path, strip(line))
                line, state = iterate(x, state)
            end
        catch err
            @warn err
        end
    end
    path
end


function find_header(header)
    if !isfile(header)
        for d in system_include_path()
            h = joinpath(d, header)
            if isfile(h)
                return h
            end
        end
    end
    header
end

function macro_values(header, names)
    mktempdir() do d
        cfile = joinpath(d, "tmp.cpp")
        delim = "aARf6F3fWe6"
        write(cfile, """
            #include <iostream>
            #include <string>
            #include <iomanip>
            #include <typeinfo>
            #include "$header"

            #define T(x) typeid(x).name()[0]
            #define isstr(x) (T(x) == 'A')
            #define ischr(x) (T(x) == 'c')
            #define isint8(x) (T(x) == 'h'|| T(x) == 'a')
            #define dump(n,x) std::cout << "const " << n << " = " << x
            #define jlquote(x) std::quoted((const char*)(int)x)
            #define jlchar(x) std::string("Char(") +                         \\
                              std::to_string((int)(x)) + ")"

            #define wrap(x) ({                                               \\
                std::cout << "$delim";                                       \\
                     if(isstr(x))  dump(#x, jlquote(x));                     \\
                else if(ischr(x))  dump(#x,  jlchar(x));                     \\
                else if(isint8(x)) dump(#x,     int(x));                     \\
                else               dump(#x,        (x));                     \\
            })

            int main() {
                $(join(["wrap($n);" for n in names], "\n"))
            }
            """)
        binfile = joinpath(d, "tmp.bin")
        try
            run(`g++ -o $binfile $cfile`)
            output = read(`$binfile`, String)
            map(Meta.parse, split(output, delim; keepempty=false))
        catch err
            @error err
            return []
        end
    end
end


function wrap_header(header; lib="libc", include="", exclude=r"^!")

    header = find_header(header)
    @info "@cinclude \"$header\""

    ctx = DefaultContext()
    ctx.libname = lib
    ctx.options["is_function_strictly_typed"] = false
    ctx.options["is_struct_mutable"] = true

    cargs::Vector{String} = vcat((["-I", d] for d in system_include_path())...)
    @info cargs

    parse_headers!(ctx, [header], args=cargs)

    macro_names = []

    for unit in ctx.trans_units
        ctx.children = children(getcursor(unit))
        for (i, child) in enumerate(ctx.children)
            ctx.force_name = ""
            ctx.children_index = i
            child_name = name(child)

            # choose which cursor to wrap
            if haskey(ctx.common_buffer, child_name) || # skip already wrapped
               (exclude != "" && occursin(exclude, child_name) &&
               (include == "" || !occursin(include, child_name)) &&
               !(child isa Clang.CLEnumDecl))

                continue
            end

            if child isa Clang.CLEnumDecl && child_name == ""
                ctx.anonymous_counter += 1
                ctx.force_name = "ANONYMOUS_ENUM_$(ctx.anonymous_counter)"
            end

            if child isa Clang.CLMacroDefinition
                if startswith(child_name, "_")
                    continue
                end
                tokens = try tokenize(child) catch end
                if tokens != nothing &&
                   tokens.size > 1 &&
                   tokens[2].text != "(" &&
                   (tokens.size < 3 || tokens[3].text != ".")
                    push!(macro_names, child_name)
                    continue
                end
            end

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
           ctx.api_buffer;
           macro_values(header, macro_names)]

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

function symbol_name(e::Expr)
    if e.head in (:using, :const, :function)
        return e.args[1].args[1]
    elseif e.head == :struct
        return e.args[2]
    elseif e.head == :macrocall
        return e.args[3].args[1]
    else
        dump(e)
    end
    return nothing
end

czeros(T) =
    (hasmethod(zero, (t,)) ? zero(t) :
                t <: Tuple ? (czeros(t)...,) :
                            t(czeros(t)...)
     for t in fieldtypes(T))

README"## Interface"

README"""
    @cinclude "header.h" [quiet] [exclude=""] [include=""]

Import symbols from C language `header.h` into the current module.

Note: C language headers may define a large number of symbols. To avoid
clashes with local names `@cinclude` can be used inside a sub-module. e.g.

    module SOCKET
        using CInclude
        @cinclude "sys/socket.h"
    end
    SOCKET.send(fd, buf, length(buf), SOCKET.MSG_OOB)
"""
macro cinclude(h, options...)
    if :quiet in options
        options=filter(x->x!=:quiet, options)
        logger=:NullLogger
    else
        logger=:current_logger
    end
    esc(quote
        Base.CoreLogging.with_logger(Base.CoreLogging.$logger()) do
            for e in CInclude.wrap_header($h; $(options...))
                if e isa String
                    @info e
                else
                    #if e.head != :function
                        n = CInclude.symbol_name(e)
                        if n in names(@__MODULE__; all=true)
                            @info ":$n already defined in $(@__MODULE__)"
                            continue
                        end
                    #end
                    try
                        eval(e)
                    catch err
                        @warn "$err in $e"
                    end
                end
            end
        end
    end)
end


end # module
