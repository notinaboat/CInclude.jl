using Test
using CInclude

@cinclude "sys/socket.h" quiet

@test SOCK_RAW == 3
