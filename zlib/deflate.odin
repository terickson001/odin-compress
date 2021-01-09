package zlib

import "../bits"
import "core:mem"

compress :: proc(data: []byte, level: u32) -> []byte
{
    buffer := bits.String{};
    buffer.buffer = make([dynamic]byte);
    
    hashtable: map[u32]Ring_Buffer([]byte);
    
    bits.append(&buffer, u8(0x78));
    bits.append(&buffer, u8(0x5e));
    bits.append(&buffer, 1, 1);
    bits.append(&buffer, 1, 2);
    
    huff_lit := _build_huffman_code(default_huff_len[:]);
    huff_dist := _build_huffman_code(default_huff_dist[:]);
    
    i := u32(0);
    best_repeat: u32;
    jump_to: []byte;
    for i < u32(len(data)) - 3
    {
        best_repeat = 3;
        jump_to = nil;
        
        key := (^u32)(&data[i])^ & 0x00ff_ffff;
        matches := hashtable[key];
        if hashtable[key].buff == nil 
        {
            hashtable[key] = make_ring([]byte, level*2);
        }
        
        // Find best jump location
        for _, j in 0..<(hashtable[key].count)
        {
            match := hashtable[key].buff[j];
            if mem.ptr_sub(&data[i], &match[0]) < 32768
            {
                repeat := count_matching(match, data[i:]);
                if repeat >= best_repeat
                {
                    best_repeat = repeat;
                    jump_to = match;
                }
            }
        }
        
        // Push new match to ring buffer
        ring := hashtable[key];
        ring_push(&ring, data[i:]);
        hashtable[key] = ring;
        
        if jump_to != nil // If we found a match, encode it
        {
            distance := mem.ptr_sub(&data[i], &jump_to[0]);
            push_huffman_code(&buffer, best_repeat, u32(distance), huff_lit, huff_dist);
            i += best_repeat;
        }
        else // else, push the current byte
        {
            encode_huffman(&buffer, u32(data[i]), huff_lit);
            i += 1;
        }
    }
    
    // encode the remainder
    for i < u32(len(data))
    {
        encode_huffman(&buffer, u32(data[i]), huff_lit);
        i += 1;
    }
    
    // End of block
    encode_huffman(&buffer, 256, huff_lit);
    bits.next_byte(&buffer);
    
    for _, ring in hashtable
    {
        if ring.buff != nil
        {
            r := ring;
            delete_ring(&r);
        }
    }
    
    checksum := adler32(data[:]);
    bits.append(&buffer, u32(checksum));
    
    out := make([]byte, len(buffer.buffer));
    copy(out, buffer.buffer[:]);
    delete(buffer.buffer);
    
    return out;
}

@(private="file")
count_matching :: proc(data, datb: []byte) -> u32
{
    i := u32(0);
    for i < u32(min(len(data), len(datb))) && i < 257
    {
        if data[i] != datb[i] 
        {
            break;
        }
        i += 1;
    }
    return i;
}

@(private="file")
Ring_Buffer :: struct(Value: typeid)
{
    buff:  []Value,
    idx:   u32,
    count: u32,
}

@(private="file")
ring_push :: proc(using ring: ^Ring_Buffer($T), val: T)
{
    buff[idx] = val;
    idx += 1;
    
    if count < u32(len(buff)) 
    {
        count += 1;
    }
    if idx >= u32(len(buff)) 
    {
        idx = 0;
    }
}

@(private="file")
make_ring :: proc($Value: typeid, size: u32) -> (ring: Ring_Buffer(Value))
{
    ring.buff = make([]Value, size);
    return ring;
}

@(private="file")
delete_ring :: proc(using ring: ^Ring_Buffer($T))
{
    delete(buff);
    idx = 0;
    count = 0;
}

push_huffman_code :: proc(buffer: ^bits.String, length, dist: u32, huff_lit, huff_dist: ^Huffman)
{
    length_code, dist_code: u32;
    for length > base_lengths[length_code+1]-1 
    {
        length_code += 1;
    }
    for dist > base_dists[dist_code+1]-1 
    {
        dist_code += 1;
    }
    
    length_eb := u32(length_extra_bits[length_code]);
    dist_eb := u32(dist_extra_bits[dist_code]);
    
    encode_huffman(buffer, length_code+257, huff_lit);
    if length_eb > 0 
    {
        bits.append(buffer, length - base_lengths[length_code], length_eb);
    }
    
    encode_huffman(buffer, dist_code, huff_dist);
    if dist_eb > 0 
    {
        bits.append(buffer, dist - base_dists[dist_code], dist_eb);
    }
    
}

encode_huffman :: proc(buffer: ^bits.String, val: u32, using huff: ^Huffman)
{
    // bits.append_reverse(buffer, codes[val], u32(lengths[val]));
}

adler32 :: proc(data: []byte) -> u32
{
    A, B: u32;
    A = 1;
    
    for D in data
    {
        A = (A + u32(D)) % 65521;
        B = (B + A)      % 65521;
    }
    
    return (B << 16) + A;
}
