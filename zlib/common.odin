package zlib

import "core:fmt"
import "core:os"
import "core:time"
import "core:mem"

import "../bits"

import "shared:profile"

Buffer :: struct
{
    cmf: byte,
    extra_flags: byte,
    check_value: u16,
    
    data: ^byte,
    data_end: ^byte,
    
    bit_buffer: u64,
    bits_remaining: u32,
    
    huff_lit: ^Huffman,
    huff_dist: ^Huffman,
    out: [dynamic]byte,
}

FAST_BITS :: 12;
FAST_MASK :: ((1 << FAST_BITS) - 1);

Huffman :: struct
{
    fast_table: [1<<FAST_BITS]u16,
    first_code: [16]u16,
    max_code: [17]u32,
    first_symbol: [16]u16,
    size: [288]u8,
    value: [288]u16,
}

@private
@static HUFFMAN_ALPHABET :=
[?]u32{16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15};

@private
@static length_extra_bits := [?]u8{
    0, 0, 0, 0, 0, 0, 0, 0, //257 - 264
    1, 1, 1, 1, //265 - 268
    2, 2, 2, 2, //269 - 273
    3, 3, 3, 3, //274 - 276
    4, 4, 4, 4, //278 - 280
    5, 5, 5, 5, //281 - 284
    0,          //285
};

@private
@static base_lengths := [?]u32{
    3, 4, 5, 6, 7, 8, 9, 10, //257 - 264
    11, 13, 15, 17,          //265 - 268
    19, 23, 27, 31,          //269 - 273
    35, 43, 51, 59,          //274 - 276
    67, 83, 99, 115,         //278 - 280
    131, 163, 195, 227,      //281 - 284
    258                      //285
};

@private
@static base_dists := [?]u32{
    /*0*/  1,     2, 3, 4, //0-3
    /*1*/  5,     7,       //4-5
    /*2*/  9,     13,      //6-7
    /*3*/  17,    25,      //8-9
    /*4*/  33,    49,      //10-11
    /*5*/  65,    97,      //12-13
    /*6*/  129,   193,     //14-15
    /*7*/  257,   385,     //16-17
    /*8*/  513,   769,     //18-19
    /*9*/  1025,  1537,    //20-21
    /*10*/ 2049,  3073,    //22-23
    /*11*/ 4097,  6145,    //24-25
    /*12*/ 8193,  12289,   //26-27
    /*13*/ 16385, 24577,   //28-29
    0,     0        //30-31, error, shouldn't occur
};

@private
@static dist_extra_bits := [?]u32{
    /*0*/  0, 0, 0, 0, //0-3
    /*1*/  1, 1,       //4-5
    /*2*/  2, 2,       //6-7
    /*3*/  3, 3,       //8-9
    /*4*/  4, 4,       //10-11
    /*5*/  5, 5,       //12-13
    /*6*/  6, 6,       //14-15
    /*7*/  7, 7,       //16-17
    /*8*/  8, 8,       //18-19
    /*9*/  9, 9,       //20-21
    /*10*/ 10, 10,     //22-23
    /*11*/ 11, 11,     //24-25
    /*12*/ 12, 12,     //26-27
    /*13*/ 13, 13,     //28-29
    0,  0       //30-31 error, they shouldn't occur
};

@static default_huff_len := [?]byte
{
    0  ..<144 = 8,
    144..<256 = 9,
    256..<280 = 7,
    280..<288 = 8,
};

@static default_huff_dist := [?]byte
{
    0..<32 = 5,
};

@private
_zlib_err :: proc(test: bool, message: string, loc := #caller_location) -> bool
{
    if test {
        fmt.eprintf("%#v: ERROR: %s\n", loc, message);
        os.exit(1);
    }
    
    return test;
}

_zread_u8 :: inline proc(using z_buff: ^Buffer, loc := #caller_location) -> u8
{
    if data >= data_end 
    {
        return 0;
    }
    
    ret := data^;
    data = mem.ptr_offset(data, 1);
    return ret;
}

_zread_sized :: inline proc(using z_buff: ^Buffer, $T: typeid, loc := #caller_location) -> T
{
    if mem.ptr_offset(data, size_of(T)) > data_end 
    {
        return 0;
    }
    
    ret := (cast(^T)(data))^;
    data = mem.ptr_offset(data, size_of(T));
    return ret;
}

_build_huffman_code :: proc(lengths: []byte) -> ^Huffman
{
    huff := new(Huffman);
    
    using huff;
    max_length := _get_max_bit_length(lengths);
    counts     := make([]u32, 17);
    next_code: [16]i32;
    
    _get_bit_length_count(counts, lengths, max_length);
    _first_code_for_bitlen(huff, next_code[:], counts, max_length);
    
    for s, i in lengths
    {
        if s == 0 do continue;
        
        c := int(next_code[s]) - int(first_code[s]) + int(first_symbol[s]);
        fastv := u16((int(s) << 9) | int(i));
        size[c] = u8(s);
        value[c] = u16(i);
        if s <= FAST_BITS
        {
            j := bits.reverse(u16(next_code[s]), u16(s));
            for j < (1 << FAST_BITS)
            {
                fast_table[j] = fastv;
                j += 1 << s;
            }
        }
        next_code[s] += 1;
    }
    
    delete(counts);
    
    return huff;
}

destroy_huffman :: proc(huff: ^Huffman)
{
    free(huff);
}

@private
_get_max_bit_length :: proc(lengths: []byte) -> byte
{
    max_length := byte(0);
    for l in lengths 
    {
        max_length = max(max_length, l);
    }
    return max_length;
}

@private
_get_bit_length_count :: proc(counts: []u32, lengths: []byte, max_length: byte)
{
    for l in lengths 
    {
        counts[l] += 1;
    }
    counts[0] = 0;
    
    for i in 1..<(max_length)
    {
        if _zlib_err(counts[i] > (1 << i), "Bad Sizes")
        {
            return;
        }
    }
}

@private
_first_code_for_bitlen :: proc(using huff: ^Huffman, next_code: []i32, counts: []u32, max_length: byte)
{
    code := u32(0);
    k := u32(0);
    for bits in 1..<(u32(16))
    {
        next_code[bits] = i32(code);
        first_code[bits] = u16(code);
        first_symbol[bits] = u16(k);
        code = (code + counts[bits]);
        max_code[bits] = u32(code) << (16-bits);
        code <<= 1;
        k += counts[bits];
    }
    max_code[16] = 0x10000;
}
