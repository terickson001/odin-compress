package zlib

import "core:mem"
import rt "core:runtime"

import "../bits"

import "shared:profile"

read_block :: proc(data: []byte) -> Buffer
{
    when ODIN_DEBUG do profile.scoped_zone();
    z_buff := Buffer{};
    z_buff.data = &data[0];
    z_buff.data_end = mem.ptr_offset(z_buff.data, len(data));
    z_buff.cmf = _zread_u8(&z_buff);
    z_buff.extra_flags = _zread_u8(&z_buff);
    
    // z_buff.check_value = u16(_zread_sized(&z_buff, u16be));
    
    z_buff.bit_buffer = 0;
    z_buff.bits_remaining = 0;
    
    return z_buff;
}

decompress :: proc(using z_buff: ^Buffer)
{
    when ODIN_DEBUG do profile.scoped_zone();
    final := false;
    type: u32;
    out = make([dynamic]byte, 0, mem.ptr_sub(data_end, data));
    
    for !final
    {
        if bits_remaining < 3 do
            load_bits(z_buff);
        final = bool(read_bits(z_buff, 1));
        type  = read_bits(z_buff, 2);
        
        if type == 0
        {
            uncompressed(z_buff);
        }
        else
        {
            if type == 1 // Fixed Huffman
            {
                z_buff.huff_lit  = _build_huffman_code(default_huff_len[:]);
                z_buff.huff_dist = _build_huffman_code(default_huff_dist[:]);
            }
            else // Computed Huffman
            {
                compute_huffman(z_buff);
            }
            inflate(z_buff);
            destroy_huffman(z_buff.huff_lit);
            destroy_huffman(z_buff.huff_dist);
        }
    }
}


quick_append :: inline proc(arr: ^[dynamic]byte, val: byte)
{
    a := (^rt.Raw_Dynamic_Array)(arr);
    if a.len == a.cap do
        _ = reserve(arr, cap(arr)*2);
    a.len += 1;
    arr[a.len-1] = val;
}

inflate :: proc(using z_buff: ^Buffer)
{
    //     when ODIN_DEBUG do profile.scoped_zone();
    
    for
    {
        decoded_value := _decode_huffman(z_buff, huff_lit);
        if decoded_value == 256 do break;
        if decoded_value < 256
        {
            quick_append(&out, byte(decoded_value));
            continue;
        }
        
        if 256 < decoded_value && decoded_value < 286
        {
            base_index := decoded_value - 257;
            duplicate_length := u32(base_lengths[base_index]) + read_bits(z_buff, u32(length_extra_bits[base_index]));
            
            distance_index := _decode_huffman(z_buff, huff_dist);
            distance_length := base_dists[distance_index] + read_bits(z_buff, dist_extra_bits[distance_index]);
            assert(distance_length > 0);
            
            back_pointer_index := u32(len(out)) - distance_length;
            //             a := (^rt.Raw_Dynamic_Array)(&out);
            //             for a.len+int(duplicate_length) >= a.cap do
            //                 _ = reserve(&out, a.cap*2);
            //             mem.copy(&out[a.len-1], &out[back_pointer_index], int(duplicate_length));
            //             a.len += int(duplicate_length);
            for duplicate_length > 0
            {
                quick_append(&out, out[back_pointer_index]);
                back_pointer_index += 1;
                duplicate_length   -= 1;
            }
        }
    }
    
}

compute_huffman :: proc(using z_buff: ^Buffer)
{
    hlit  := u32(read_bits(z_buff, 5)) + 257;
    hdist := u32(read_bits(z_buff, 5)) + 1;
    hclen := u32(read_bits(z_buff, 4)) + 4;
    
    huff_clen_lens := [19]byte{};
    
    for i in 0..<(hclen) do
        huff_clen_lens[HUFFMAN_ALPHABET[i]] = byte(read_bits(z_buff, 3));
    
    huff_clen := _build_huffman_code(huff_clen_lens[:]);
    huff_lit_dist_lens := make([]byte, hlit+hdist);
    
    code_index := u32(0);
    for code_index < u32(len(huff_lit_dist_lens))
    {
        decoded_value := _decode_huffman(z_buff, huff_clen);
        if _zlib_err(decoded_value < 0 || decoded_value > 18, "Bad codelengths")
            do return;
        if decoded_value < 16
        {
            huff_lit_dist_lens[code_index] = byte(decoded_value);
            code_index += 1;
            continue;
        }
        
        repeat_count := u32(0);
        code_length_to_repeat := byte(0);
        
        switch decoded_value
        {
            case 16:
            repeat_count = read_bits(z_buff, 2) + 3;
            if _zlib_err(code_index == 0, "Bad codelengths") do return;
            code_length_to_repeat = huff_lit_dist_lens[code_index - 1];
            case 17:
            repeat_count = read_bits(z_buff, 3) + 3;
            case 18:
            repeat_count = read_bits(z_buff, 7) + 11;
        }
        
        if _zlib_err(hlit+hdist - code_index < repeat_count, "Bad codelengths")
            do return;
        
        mem.set(&huff_lit_dist_lens[code_index], code_length_to_repeat, int(repeat_count));
        code_index += repeat_count;
    }
    
    if _zlib_err(code_index != hlit+hdist, "Bad codelengths")
        do return;
    
    huff_lit  = _build_huffman_code(huff_lit_dist_lens[:hlit]);
    huff_dist = _build_huffman_code(huff_lit_dist_lens[hlit:]);
}

_decode_huffman_slow :: proc(using z_buff: ^Buffer, using huff: ^Huffman, loc := #caller_location) -> u32
{
    //     when ODIN_DEBUG do profile.scoped_zone();
    k := u32(bits.reverse(u16(bit_buffer), 16));
    s := u32(FAST_BITS+1);
    for ;;s+=1
    {
        if k < max_code[s] do
            break;
    }
    b := u16(k  >> (16-s)) - first_code[s] + first_symbol[s];
    bit_buffer >>= u32(s);
    bits_remaining -= u32(s);
    return u32(value[b]);
}

_decode_huffman :: inline proc(using z_buff: ^Buffer, using huff: ^Huffman, loc := #caller_location) -> u32
{
    if bits_remaining < 16 do
        load_bits(z_buff);
    b := fast_table[bit_buffer & FAST_MASK];
    if b != 0
    {
        s := b >> 9;
        bit_buffer >>= s;
        bits_remaining -= u32(s);
        return u32(b & 511);
    }
    return _decode_huffman_slow(z_buff, huff, loc);
}

quick_append_ptr :: inline proc(arr: ^[dynamic]byte, data: ^byte, n: int)
{
    a := (^rt.Raw_Dynamic_Array)(arr);
    if a.len+n >= a.cap
    {
        new_len := a.len;
        for a.len+n >= a.cap do new_len *= 2;
        _ = reserve(arr, new_len);
    }
    mem.copy(&arr[len(arr)-1], data, n);
    a.len += n;
}

uncompressed :: proc(using z_buff: ^Buffer)
{
    when ODIN_DEBUG do profile.scoped_zone();
    header := [4]byte{};
    if bits_remaining & 7 > 0 do
        read_bits(z_buff, bits_remaining & 7); // Discard
    
    for _, i in header do
        header[i] = u8(read_bits(z_buff, 8));
    assert(bits_remaining == 0);
    
    length  := u32(header[1]) * 256 + u32(header[0]);
    nlength := u32(header[3]) * 256 + u32(header[2]);
    if _zlib_err(nlength != (length ~ 0xffff), "Corrupt Zlib") ||
        _zlib_err(length > u32(mem.ptr_sub(data_end, data)), "Read past buffer")
        do return;
    
    quick_append_ptr(&out, data, int(length));
    data = mem.ptr_offset(data, int(length));
}

load_bits :: inline proc(using z_buff: ^Buffer, loc := #caller_location)
{
    for bits_remaining <= (size_of(bit_buffer)-1)*8
    {
        bit_buffer |= u64(_zread_u8(z_buff, loc)) << bits_remaining;
        bits_remaining += 8;
    }
    //     room := min(int(size_of(bit_buffer)*8 - bits_remaining), mem.ptr_sub(data_end, data)*8);
    //     for room > 8
    //     {
    //         if room == 64
    //         {
    //             bit_buffer = u64(_zread_sized(z_buff, u64));
    //             bits_remaining = 64;
    //             break;
    //         }
    //         else if room >= 32
    //         {
    //             bit_buffer = u64(_zread_sized(z_buff, u32)) << bits_remaining;
    //             bits_remaining += 32;
    //             room -= 32;
    //         }
    //         else if room >= 16
    //         {
    //             bit_buffer = u64(_zread_sized(z_buff, u16)) << bits_remaining;
    //             bits_remaining += 16;
    //             room -= 16;
    //         }
    //         else
    //         {
    //             bit_buffer = u64(_zread_u8(z_buff)) << bits_remaining;
    //             bits_remaining += 8;
    //             room -= 8;
    //         }
    //     }
}

read_bits :: proc(using z_buff: ^Buffer, size: u32) -> u32
{
    res := u32(0);
    
    if size > bits_remaining do
        load_bits(z_buff);
    
    for i in 0..<(size)
    {
        bit := u32(bit_buffer & (1 << i));
        res |= bit;
    }
    
    bit_buffer >>= size;
    bits_remaining -= size;
    
    return res;
}

