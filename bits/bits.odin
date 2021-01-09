package bits

import "core:intrinsics"
import "core:fmt"
import "core:os"
import "core:builtin"

String :: struct
{
    buffer: [dynamic]byte,
    bytei: u32,
    biti:  u32,
}

slice :: proc(val: $T, shift, size: u32) -> T where intrinsics.type_is_integer(T)
{
    assert(size_of(T)*8 > shift && size_of(T)*8 >= size);
    size_mask := T((1 << size) - 1);
    return T((val >> shift) & size_mask);
}

append_bits :: proc(using str: ^String, val: $T, bitn: u32, loc := #caller_location) where intrinsics.type_is_integer(T)
{
    to_write := bitn;
    for to_write > 0
    {
        size := min(8-biti, to_write);
        if biti > 0 
        {
            buffer[bytei] |= byte(slice(val, bitn-to_write, size) << biti);
        }
        else 
        {
            builtin.append(&buffer, byte(slice(val, bitn-to_write, size)));
        }
        
        biti += size;
        if biti > 7
        {
            bytei += 1;
            biti = 0;
        }
        
        to_write -= size;
    }
    assert(to_write == 0);
}

append_bytes :: proc(using str: ^String, val: $T, loc := #caller_location) where intrinsics.type_is_integer(T)
{
    for i in 0..<size_of(T) 
    {
        append_bits(str, byte(val >> (u32(size_of(T)-i-1)*8)), 8, loc);
    }
}

append_slice :: proc(using str: ^String, bytes: []byte, loc := #caller_location)
{
    for b in bytes 
    {
        append_bits(str, b, 8, loc);
    }
}

append :: proc{append_bits, append_bytes, append_slice};

append_byte :: proc(using str: ^String, val: byte)
{
    next_byte(str);
    builtin.append(&buffer, val);
}

next_byte :: proc(using str: ^String)
{
    if biti > 0 
    {
        append(str, 0, 8-biti);
    }
}

slice_reverse :: proc(val: $T, offset, size: u32) -> T where intrinsics.type_is_integer(T)
{
    res := T(0);
    
    sshift := offset + size-1;
    dshift := u32(0);
    for sshift >= offset
    {
        res |= (val >> sshift & 1) << dshift;
        if sshift == 0 do break;
        sshift -= 1;
        dshift += 1;
    }
    
    return res;
}

append_reverse :: proc(using str: ^String, val: $T, bitn: u32, loc := #caller_location) where intrinsics.type_is_integer(T)
{
    reversed := slice_reverse(val, 0, bitn);
    append(str, reversed, bitn, loc);
}

reverse :: inline proc(val: u16, bits: u16) -> u16
{
    n := val;
    n = ((n & 0xAAAA) >>  1) | ((n & 0x5555) << 1);
    n = ((n & 0xCCCC) >>  2) | ((n & 0x3333) << 2);
    n = ((n & 0xF0F0) >>  4) | ((n & 0x0F0F) << 4);
    n = ((n & 0xFF00) >>  8) | ((n & 0x00FF) << 8);
    return n >> (16-bits);
}