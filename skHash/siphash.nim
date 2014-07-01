
# Ported from: https://131002.net/siphash/ by Joshua "Skrylar" Cearley.
#
# This file (siphash.nim) is released in to the public domain (CC0
# License), the author releases all claims of copyright on it.

import
  unsigned

# Crypto-code is decidedly performance critical.
{.push checks: off.}

# Type definitions {{{1

type
  SipHash24Key* = array[0..15, uint8]
  RawData = ptr array[0..65535, uint8]

# }}}

# ROTL {{{1

# NB: Maybe we could spork this to a separate unit, since its used in a
# lot of cryptocode.

# NB: We should look in to compiler-specific optimizations, as some have
# special ways of doing a ROTL call.

template ROTL(x, b: uint64): uint64 =
  ( (x shl b) or ( x shr (uint64(64) - b) ) )

# }}}

# Integer Decoding {{{1
# NB: This code can probably be moved to a separate module because its
# also useful for non-crypto encoders as well.

template U32To8LE[T](p: var T; v: uint32; offset: int = 0) =
  p[0+offset] = uint8(v       )
  p[1+offset] = uint8(v shr 8 )
  p[2+offset] = uint8(v shr 16)
  p[3+offset] = uint8(v shr 24)

template U64To8LE[T](p: var T; v: uint64; offset: int = 0) =
  U32To8LE(p, uint32(v       ), 0)
  U32To8LE(p, uint32(v shr 32), 4)

template U8To64LE[T](p: T; offset: int = 0): uint64 =
  uint64(p[0+offset]) or
    (uint64(p[1+offset]) shl 8) or
    (uint64(p[2+offset]) shl 16) or
    (uint64(p[3+offset]) shl 24) or
    (uint64(p[4+offset]) shl 32) or
    (uint64(p[5+offset]) shl 40) or
    (uint64(p[6+offset]) shl 48) or
    (uint64(p[7+offset]) shl 56)

# }}}

# Siphash Implementation {{{1

template Sipround(v0, v1, v2, v3: var uint64) =
  v0 = v0 + v1; v1 = ROTL(v1, 13); v1 = v1 xor v0; v0 = ROTL(v0, 32)
  v2 = v2 + v3; v3 = ROTL(v3, 16); v3 = v3 xor v2
  v0 = v0 + v3; v3 = ROTL(v3, 21); v3 = v3 xor v0
  v2 = v2 + v1; v1 = ROTL(v1, 17); v1 = v1 xor v2; v2 = ROTL(v2, 32)

# SipHash-2-4
proc SipHash24*(input: pointer; length: int; k: SipHash24Key): uint64 =
  assert input != nil
  assert length >= 0

  # "somepseudorandomlygeneratedbytes"
  var v0 : uint64 = uint64(0x736F6D6570736575)
  var v1 : uint64 = uint64(0x646F72616E646F6D)
  var v2 : uint64 = uint64(0x6C7967656E657261)
  var v3 : uint64 = uint64(0x7465646279746573)
  var b  : uint64
  var k0 : uint64 = U8To64LE(k, 0)
  var k1 : uint64 = U8To64LE(k, 8)
  var m  : uint64

  let eof = ( length - ( length mod sizeof(uint64) ) )
  var left = cint(length and 7)
  var pos = 0

  let actualInput = cast[RawData](input)

  b = uint64(length) shl 56

  v3 = v3 xor k1
  v2 = v2 xor k0
  v1 = v1 xor k1
  v0 = v0 xor k0

  while pos < eof:
    m = U8To64LE(actualInput, pos)
    # Debug printing omitted.
    v3 = v3 xor m
    Sipround(v0, v1, v2, v3)
    Sipround(v0, v1, v2, v3)
    v0 = v0 xor m
    inc(pos, 8)

  # NB: I would prefer this be unrolled.
  while left > 0:
    let x = left - 1
    b = b or uint64( uint64(actualInput[pos+x]) shl uint64(x * 8) )
    dec(left)

  # Debug printing omitted.

  v3 = v3 xor b
  Sipround(v0, v1, v2, v3)
  Sipround(v0, v1, v2, v3)
  v0 = v0 xor b

  # Debug printing omitted.

  v2 = v2 xor 0xFF
  Sipround(v0, v1, v2, v3)
  Sipround(v0, v1, v2, v3)
  Sipround(v0, v1, v2, v3)
  Sipround(v0, v1, v2, v3)
  b = v0 xor v1 xor v2 xor v3

  return b

# }}}

# User Helpers {{{1

proc SipHash24*(input: pointer; length: int): uint64 =
  let key: SipHash24Key = [uint8(0), uint8(1), uint8(2), uint8(3),
    uint8(4), uint8(5), uint8(6), uint8(7), uint8(8), uint8(9), uint8(10),
    uint8(11), uint8(12), uint8(13), uint8(14), uint8(15)]
  return SipHash24(input, length, key)

proc SipHash24*(input: string): uint64 {.inline.} =
  var data: string = input
  shallowCopy(data, input)
  return SipHash24(addr(data[0]), data.len)

proc SipHash24*(input: string; key: SipHash24Key): uint64 {.inline.} =
  var data: string = input
  shallowCopy(data, input)
  return SipHash24(addr(data[0]), data.len, key)

template DefHash(typ: typedesc): stmt =
  proc SipHash24*(input: typ): uint64 =
    var data: typ
    shallowCopy(data, input)
    return SipHash24(addr(data), sizeof(typ))
  proc SipHash24*(input: typ; key: SipHash24Key): uint64 =
    var data: typ
    shallowCopy(data, input)
    return SipHash24(addr(data), sizeof(typ), key)

DefHash(int)
DefHash(int8)
DefHash(int16)
DefHash(int32)
DefHash(int64)
DefHash(uint)
DefHash(uint8)
DefHash(uint16)
DefHash(uint32)
DefHash(uint64)

# }}}

# Test vectors {{{1

when isMainModule:
  type
    TestVector = array[0..7, int]

  import unittest

  let ExpectedResults: array[0..63, TestVector] = [
    [ 0x31, 0x0E, 0x0E, 0xDD, 0x47, 0xDB, 0x6F, 0x72 ],
    [ 0xFD, 0x67, 0xDC, 0x93, 0xC5, 0x39, 0xF8, 0x74 ],
    [ 0x5A, 0x4F, 0xA9, 0xD9, 0x09, 0x80, 0x6C, 0x0D ],
    [ 0x2D, 0x7E, 0xFB, 0xD7, 0x96, 0x66, 0x67, 0x85 ],
    [ 0xB7, 0x87, 0x71, 0x27, 0xE0, 0x94, 0x27, 0xCF ],
    [ 0x8D, 0xA6, 0x99, 0xCD, 0x64, 0x55, 0x76, 0x18 ],
    [ 0xCE, 0xE3, 0xFE, 0x58, 0x6E, 0x46, 0xC9, 0xCB ],
    [ 0x37, 0xD1, 0x01, 0x8B, 0xF5, 0x00, 0x02, 0xAB ],
    [ 0x62, 0x24, 0x93, 0x9A, 0x79, 0xF5, 0xF5, 0x93 ],
    [ 0xB0, 0xE4, 0xA9, 0x0B, 0xDF, 0x82, 0x00, 0x9E ],
    [ 0xF3, 0xB9, 0xDD, 0x94, 0xC5, 0xBB, 0x5D, 0x7A ],
    [ 0xA7, 0xAD, 0x6B, 0x22, 0x46, 0x2F, 0xB3, 0xF4 ],
    [ 0xFB, 0xE5, 0x0E, 0x86, 0xBC, 0x8F, 0x1E, 0x75 ],
    [ 0x90, 0x3D, 0x84, 0xC0, 0x27, 0x56, 0xEA, 0x14 ],
    [ 0xEE, 0xF2, 0x7A, 0x8E, 0x90, 0xCA, 0x23, 0xF7 ],
    [ 0xE5, 0x45, 0xBE, 0x49, 0x61, 0xCA, 0x29, 0xA1 ],
    [ 0xDB, 0x9B, 0xC2, 0x57, 0x7F, 0xCC, 0x2A, 0x3F ],
    [ 0x94, 0x47, 0xBE, 0x2C, 0xF5, 0xE9, 0x9A, 0x69 ],
    [ 0x9C, 0xD3, 0x8D, 0x96, 0xF0, 0xB3, 0xC1, 0x4B ],
    [ 0xBD, 0x61, 0x79, 0xA7, 0x1D, 0xC9, 0x6D, 0xBB ],
    [ 0x98, 0xEE, 0xA2, 0x1A, 0xF2, 0x5C, 0xD6, 0xBE ],
    [ 0xC7, 0x67, 0x3B, 0x2E, 0xB0, 0xCB, 0xF2, 0xD0 ],
    [ 0x88, 0x3E, 0xA3, 0xE3, 0x95, 0x67, 0x53, 0x93 ],
    [ 0xC8, 0xCE, 0x5C, 0xCD, 0x8C, 0x03, 0x0C, 0xA8 ],
    [ 0x94, 0xAF, 0x49, 0xF6, 0xC6, 0x50, 0xAD, 0xB8 ],
    [ 0xEA, 0xB8, 0x85, 0x8A, 0xDE, 0x92, 0xE1, 0xBC ],
    [ 0xF3, 0x15, 0xBB, 0x5B, 0xB8, 0x35, 0xD8, 0x17 ],
    [ 0xAD, 0xCF, 0x6B, 0x07, 0x63, 0x61, 0x2E, 0x2F ],
    [ 0xA5, 0xC9, 0x1D, 0xA7, 0xAC, 0xAA, 0x4D, 0xDE ],
    [ 0x71, 0x65, 0x95, 0x87, 0x66, 0x50, 0xA2, 0xA6 ],
    [ 0x28, 0xEF, 0x49, 0x5C, 0x53, 0xA3, 0x87, 0xAD ],
    [ 0x42, 0xC3, 0x41, 0xD8, 0xFA, 0x92, 0xD8, 0x32 ],
    [ 0xCE, 0x7C, 0xF2, 0x72, 0x2F, 0x51, 0x27, 0x71 ],
    [ 0xE3, 0x78, 0x59, 0xF9, 0x46, 0x23, 0xF3, 0xA7 ],
    [ 0x38, 0x12, 0x05, 0xBB, 0x1A, 0xB0, 0xE0, 0x12 ],
    [ 0xAE, 0x97, 0xA1, 0x0F, 0xD4, 0x34, 0xE0, 0x15 ],
    [ 0xB4, 0xA3, 0x15, 0x08, 0xBE, 0xFF, 0x4D, 0x31 ],
    [ 0x81, 0x39, 0x62, 0x29, 0xF0, 0x90, 0x79, 0x02 ],
    [ 0x4D, 0x0C, 0xF4, 0x9E, 0xE5, 0xD4, 0xDC, 0xCA ],
    [ 0x5C, 0x73, 0x33, 0x6A, 0x76, 0xD8, 0xBF, 0x9A ],
    [ 0xD0, 0xA7, 0x04, 0x53, 0x6B, 0xA9, 0x3E, 0x0E ],
    [ 0x92, 0x59, 0x58, 0xFC, 0xD6, 0x42, 0x0C, 0xAD ],
    [ 0xA9, 0x15, 0xC2, 0x9B, 0xC8, 0x06, 0x73, 0x18 ],
    [ 0x95, 0x2B, 0x79, 0xF3, 0xBC, 0x0A, 0xA6, 0xD4 ],
    [ 0xF2, 0x1D, 0xF2, 0xE4, 0x1D, 0x45, 0x35, 0xF9 ],
    [ 0x87, 0x57, 0x75, 0x19, 0x04, 0x8F, 0x53, 0xA9 ],
    [ 0x10, 0xA5, 0x6C, 0xF5, 0xDF, 0xCD, 0x9A, 0xDB ],
    [ 0xEB, 0x75, 0x09, 0x5C, 0xCD, 0x98, 0x6C, 0xD0 ],
    [ 0x51, 0xA9, 0xCB, 0x9E, 0xCB, 0xA3, 0x12, 0xE6 ],
    [ 0x96, 0xAF, 0xAD, 0xFC, 0x2C, 0xE6, 0x66, 0xC7 ],
    [ 0x72, 0xFE, 0x52, 0x97, 0x5A, 0x43, 0x64, 0xEE ],
    [ 0x5A, 0x16, 0x45, 0xB2, 0x76, 0xD5, 0x92, 0xA1 ],
    [ 0xB2, 0x74, 0xCB, 0x8E, 0xBF, 0x87, 0x87, 0x0A ],
    [ 0x6F, 0x9B, 0xB4, 0x20, 0x3D, 0xE7, 0xB3, 0x81 ],
    [ 0xEA, 0xEC, 0xB2, 0xA3, 0x0B, 0x22, 0xA8, 0x7F ],
    [ 0x99, 0x24, 0xA4, 0x3C, 0xC1, 0x31, 0x57, 0x24 ],
    [ 0xBD, 0x83, 0x8D, 0x3A, 0xAF, 0xBF, 0x8D, 0xB7 ],
    [ 0x0B, 0x1A, 0x2A, 0x32, 0x65, 0xD5, 0x1A, 0xEA ],
    [ 0x13, 0x50, 0x79, 0xA3, 0x23, 0x1C, 0xE6, 0x60 ],
    [ 0x93, 0x2B, 0x28, 0x46, 0xE4, 0xD7, 0x06, 0x66 ],
    [ 0xE1, 0x91, 0x5F, 0x5C, 0xB1, 0xEC, 0xA4, 0x6C ],
    [ 0xF3, 0x25, 0x96, 0x5C, 0xA1, 0x6D, 0x62, 0x9F ],
    [ 0x57, 0x5F, 0xF2, 0x8E, 0x60, 0x38, 0x1B, 0xE5 ],
    [ 0x72, 0x45, 0x06, 0xEB, 0x4C, 0x32, 0x8A, 0x95 ]
  ]

  test "siphash vectors":
    var k: SipHash24Key
    var input: array[0..64, uint8]
    var output: array[0..7, uint8]

    # initialize K
    for i in 0..15:
      k[i] = uint8(i)

    # do the things
    for i in 0..63:
      input[i] = uint8(i)
      let hash = SipHash24(pointer(addr(input[0])), i, k)
      let expected = U8To64LE(ExpectedResults[i])
      check hash == expected

# }}}

{.pop.}

