using Test
using CInclude

@cinclude "sys/socket.h"

@test SOCK_RAW == 3
