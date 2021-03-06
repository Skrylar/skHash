
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
    ## A key which may be supplied to a Siphash24 implementation. Keys
    ## don't *necesserily* need to be anything special, however a key is
    ## used as a form of salting and unique keys will preclude the
    ## usability of generic rainbow tables.

  Siphash24Impl* = object
    ## An implementation of Siphash24. Fully self-contained.
    v0, v1, v2, v3, b, k0, k1, m: uint64
    total: uint64
    overflow:     array[0..8, int8]
    overflowPos:  int

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

# NB: This stuff should probably check the local system encoding to make
# sure it does everything correctly.

# template U32To8LE[T](p: var T; v: uint32; offset: int = 0) =
#   p[0+offset] = uint8(v       )
#   p[1+offset] = uint8(v shr 8 )
#   p[2+offset] = uint8(v shr 16)
#   p[3+offset] = uint8(v shr 24)

# template U64To8LE[T](p: var T; v: uint64; offset: int = 0) =
#   U32To8LE(p, uint32(v       ), 0)
#   U32To8LE(p, uint32(v shr 32), 4)

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

proc Reset*(self: var Siphash24Impl;
            k: SipHash24Key): bool {.noSideEffect.} =
  ## Resets a previously initialized siphash24 implementation, so that
  ## it can be used with a different set of data.

  # Note that `length` is the length of data which is being hashed; you
  # must know this in advance, or space muffins will be upset.
  self.total       = 0
  self.overflowPos = 0
  # FIXME set some flag that indicates we are ready for data
  # Set up important stuff
  # "somepseudorandomlygeneratedbytes"
  self.v0 = uint64(0x736F6D6570736575)
  self.v1 = uint64(0x646F72616E646F6D)
  self.v2 = uint64(0x6C7967656E657261)
  self.v3 = uint64(0x7465646279746573)
  self.k0 = U8To64LE(k, 0)
  self.k1 = U8To64LE(k, 8)
  self.total  = 0
  # Salt the potatos
  self.v3 = self.v3 xor self.k1
  self.v2 = self.v2 xor self.k0
  self.v1 = self.v1 xor self.k1
  self.v0 = self.v0 xor self.k0
  return true

proc Init*(self: var Siphash24Impl;
               k: SipHash24Key): bool {.inline.} =
  ## Initializes a siphash24 implementation.
  return Reset(self, k)

proc Feed*(self: var Siphash24Impl;
           data: openarray[int8];
           start, length: int): bool {.noSideEffect.} =
  ## Supplies binary data to a siphash24 implementation, using the
  ## provided `data` array and `start`/`length` information.

  # FIXME check state flags
  result = true

  var pos, epos: int
  pos  = start
  epos = pos + length

  template DoRound(self:    var Siphash24Impl;
                   input:   openarray[int8];
                   offset:  int) =
    let m = U8To64LE(input, offset)
    # Debug printing omitted.
    self.v3 = self.v3 xor m
    Sipround(self.v0, self.v1, self.v2, self.v3)
    Sipround(self.v0, self.v1, self.v2, self.v3)
    self.v0 = self.v0 xor m
    self.total = self.total + 8.uint64

  if self.overflowPos > 0:
    # FIXME test and make sure this works; it should fill up the
    # previous overflow and then process it
    # Finish stuffing the overflow
    while (self.overflowPos < 8) and (pos < epos):
      self.overflow[self.overflowPos] = data[pos]
      inc self.overflowPos
      inc pos
    # Process overflow buffer
    DoRound(self, self.Overflow, 0)
    self.overflowPos = 0

  while (epos - pos) > 7:
    DoRound(self, data, pos)
    inc pos, 8

  if (epos - pos) > 0:
    while pos < epos:
      self.overflow[self.overflowPos] = data[pos]
      inc self.overflowPos
      inc self.total
      inc pos

  # if self.left > 0.uint64:
  #   let x = self.left - 1
  # self.eof   = ( length - ( length mod sizeof(uint64).uint64 ) )
  # self.left = uint64(length and 7)
  #   self.b = uint64(self.total) shl 56
  #   self.b = self.b or uint64( input shl uint64(x * 8) )
  #   self.left = self.left - 1
  # else:
  #   return false

proc Finalize*(self: var Siphash24Impl): uint64 {.noSideEffect.} =
  ## Indicates that there is no more data to be hashed; performs any
  ## final calculations and returns the 64-bit result of the siphash24
  ## implementation on all previously supplied data.

  # FIXME check state flags
  self.b = uint64(self.total) shl 56
  if self.overflowPos > 0:
    for i in 0..(self.overflowPos-1):
      let input = self.overflow[i]
      self.b = self.b or ( uint64( input ) shl (i * 8).uint64 )
  # TODO chuck overflow buffer in here
  self.v3 = self.v3 xor self.b
  Sipround(self.v0, self.v1, self.v2, self.v3)
  Sipround(self.v0, self.v1, self.v2, self.v3)
  self.v0 = self.v0 xor self.b
  self.v2 = self.v2 xor 0xFF
  Sipround(self.v0, self.v1, self.v2, self.v3)
  Sipround(self.v0, self.v1, self.v2, self.v3)
  Sipround(self.v0, self.v1, self.v2, self.v3)
  Sipround(self.v0, self.v1, self.v2, self.v3)
  self.b = self.v0 xor self.v1 xor self.v2 xor self.v3
  # FIXME set a flag that we are done, so people don't accidentally use
  # an invalid hasher
  return self.b

# }}}

# Utility Functions {{{1

proc SipHash24*(input: openarray[int8];
                pos, length: int;
                key: SipHash24Key): uint64 =
  ## A one-stop convenience function which will calculate a 64-bit hash
  ## from the supplied input bytes and siphash24 key.
  var impl: Siphash24Impl
  doAssert(impl.Init(key) == true)
  doAssert(impl.Feed(input, pos, length) == true)
  return impl.Finalize()

# }}} Utility Functions

# Test vectors {{{1

when isMainModule:
  type
    TestVector = array[0..7, int]

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

  echo "testing siphash vectors"
  var k: SipHash24Key
  var input: array[0..64, int8]

  # initialize K
  for i in 0..15:
    k[i] = uint8(i)

  # do the things
  for i in 0..63:
    input[i] = cast[int8](uint8(i))
    let hash = SipHash24(input, 0, i, k)
    let expected = U8To64LE(ExpectedResults[i])
    doAssert(hash == expected)

# }}}

{.pop.}

