# CInclude.jl

Include C language header files in Julia source code (using [Clang.jl](https://github.com/JuliaInterop/Clang.jl)).

```
julia> using CInclude
julia> @cinclude "termios.h" quiet

[ Info: @cinclude "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/termios.h"
...

julia> term = termios()
julia> settings.c_lflag = ICANON
julia> settings.c_cflag = CS8
julia> cfsetspeed(Ref(settings), B38400)
julia> tcsetattr(fd, TCSANOW, Ref(settings))
```


## Interface

    @cinclude "header.h" [quiet] [exclude=r"^_"] [include=""] 

Import symbols from C language `header.h` into the current module.

Note: C language headers may define a large number of symbols. To avoid
clashes with local names `@cinclude` can be used inside a sub-module. e.g.

    module SOCKET
        using CInclude
        @cinclude "sys/socket.h"
    end
    SOCKET.send(fd, buf, length(buf), SOCKET.MSG_OOB)



