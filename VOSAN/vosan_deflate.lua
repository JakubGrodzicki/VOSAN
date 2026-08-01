-- vosan_deflate.lua
-- Samodzielna implementacja dekompresji DEFLATE (RFC 1951) w czystym Lua 5.4,
-- bez zadnych zewnetrznych bibliotek. Uzywana przez vosan_xlsx.lua do
-- rozpakowania wpisow ZIP (.xlsx to archiwum ZIP z wpisami skompresowanymi
-- metoda 8 = DEFLATE). Wymaga natywnych operatorow bitowych Lua 5.3+
-- (dostepnych w REAPER ReaScript Lua od wielu lat).

local M = {}

-- === Bit reader =============================================================
-- DEFLATE: bity pojedynczych wartosci sa pakowane od najmlodszego bitu (LSB)
-- kazdego bajtu; wartosci wielobitowe (poza kodami Huffmana) sa odczytywane
-- najpierw najmlodszy bit. Kody Huffmana sa budowane bit po bicie w kolejnosci
-- MSB->LSB kodu (patrz decode_symbol). To standardowy ukryty szczegol formatu
-- DEFLATE - zle zrozumiany psuje caly strumien w sposob trudny do zdiagnozowania.

local function br_new(data)
  return { data = data, len = #data, bytepos = 1, bitbuf = 0, bitcnt = 0 }
end

local function br_ensure(br, n)
  while br.bitcnt < n do
    local b = 0
    if br.bytepos <= br.len then
      b = string.byte(br.data, br.bytepos)
    end
    br.bytepos = br.bytepos + 1
    br.bitbuf = br.bitbuf | (b << br.bitcnt)
    br.bitcnt = br.bitcnt + 8
  end
end

local function getbits(br, n)
  if n == 0 then return 0 end
  br_ensure(br, n)
  local val = br.bitbuf & ((1 << n) - 1)
  br.bitbuf = br.bitbuf >> n
  br.bitcnt = br.bitcnt - n
  return val
end

local function getbit(br)
  return getbits(br, 1)
end

local function align_byte(br)
  local drop = br.bitcnt % 8
  br.bitbuf = br.bitbuf >> drop
  br.bitcnt = br.bitcnt - drop
end

-- === Huffman ================================================================
-- Kanoniczne drzewo Huffmana (RFC1951 3.2.2), zdekodowane jako mapa
-- {[dlugosc_kodu] = {[wartosc_kodu] = symbol}}. Dekodowanie idzie bit po bicie
-- (najwyzej 15 bitow), sprawdzajac po kazdym bicie czy zebrany kod jest
-- kompletny dla danej dlugosci - to prostsza (choc nie najszybsza mozliwa)
-- metoda, wystarczajaca do jednorazowego importu pliku.

local MAXBITS = 15

local function build_huffman(lengths)
  local bl_count = {}
  for b = 0, MAXBITS do bl_count[b] = 0 end
  for i = 1, #lengths do
    local l = lengths[i]
    if l > 0 then
      bl_count[l] = bl_count[l] + 1
    end
  end

  local next_code = {}
  local code = 0
  for bits = 1, MAXBITS do
    code = (code + bl_count[bits - 1]) << 1
    next_code[bits] = code
  end

  local codes_by_len = {}
  for i = 1, #lengths do
    local l = lengths[i]
    if l > 0 then
      local c = next_code[l]
      next_code[l] = c + 1
      codes_by_len[l] = codes_by_len[l] or {}
      codes_by_len[l][c] = i - 1
    end
  end
  return codes_by_len
end

local function decode_symbol(br, codes_by_len)
  local code = 0
  for len = 1, MAXBITS do
    code = (code << 1) | getbit(br)
    local tbl = codes_by_len[len]
    if tbl and tbl[code] ~= nil then
      return tbl[code]
    end
  end
  error("nieprawidlowy kod Huffmana - strumien DEFLATE jest uszkodzony")
end

-- Stale tabele dlugosci/odleglosci (RFC1951 3.2.5)
local LENGTH_BASE  = { 3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258 }
local LENGTH_EXTRA = { 0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0 }
local DIST_BASE  = { 1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577 }
local DIST_EXTRA = { 0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13 }

local CLC_ORDER = { 16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15 }

local FIXED_LIT_CODES, FIXED_DIST_CODES

local function build_fixed_tables()
  local lit_lengths = {}
  for i = 0, 143 do lit_lengths[i + 1] = 8 end
  for i = 144, 255 do lit_lengths[i + 1] = 9 end
  for i = 256, 279 do lit_lengths[i + 1] = 7 end
  for i = 280, 287 do lit_lengths[i + 1] = 8 end

  local dist_lengths = {}
  for i = 0, 29 do dist_lengths[i + 1] = 5 end

  FIXED_LIT_CODES = build_huffman(lit_lengths)
  FIXED_DIST_CODES = build_huffman(dist_lengths)
end

local function read_dynamic_tables(br)
  local hlit = getbits(br, 5) + 257
  local hdist = getbits(br, 5) + 1
  local hclen = getbits(br, 4) + 4

  local cl_lengths = {}
  for i = 1, 19 do cl_lengths[i] = 0 end
  for i = 1, hclen do
    cl_lengths[CLC_ORDER[i] + 1] = getbits(br, 3)
  end
  local cl_codes = build_huffman(cl_lengths)

  local lengths = {}
  local total = hlit + hdist
  local i = 1
  while i <= total do
    local sym = decode_symbol(br, cl_codes)
    if sym <= 15 then
      lengths[i] = sym
      i = i + 1
    elseif sym == 16 then
      local rep = getbits(br, 2) + 3
      local prev = lengths[i - 1] or 0
      for _ = 1, rep do lengths[i] = prev; i = i + 1 end
    elseif sym == 17 then
      local rep = getbits(br, 3) + 3
      for _ = 1, rep do lengths[i] = 0; i = i + 1 end
    elseif sym == 18 then
      local rep = getbits(br, 7) + 11
      for _ = 1, rep do lengths[i] = 0; i = i + 1 end
    else
      error("nieprawidlowy symbol dlugosci kodu w bloku DEFLATE")
    end
  end

  local lit_lengths = {}
  for k = 1, hlit do lit_lengths[k] = lengths[k] end
  local dist_lengths = {}
  for k = 1, hdist do dist_lengths[k] = lengths[hlit + k] end

  return build_huffman(lit_lengths), build_huffman(dist_lengths)
end

-- konwertuje tablice bajtow (liczby 0-255) na string, w kawalkach (unikamy
-- limitu argumentow string.char/table.unpack przy duzych plikach)
local function bytes_to_string(bytes)
  local CHUNK = 4096
  local chunks = {}
  local n = #bytes
  for i = 1, n, CHUNK do
    local j = math.min(i + CHUNK - 1, n)
    chunks[#chunks + 1] = string.char(table.unpack(bytes, i, j))
  end
  return table.concat(chunks)
end

--- Dekompresuje surowy strumien DEFLATE (bez naglowka zlib/gzip - dokladnie
--- to, co jest zapisane w danych wpisow ZIP metody 8). Zwraca string.
function M.inflate(data)
  if not FIXED_LIT_CODES then build_fixed_tables() end

  local br = br_new(data)
  local out = {}

  while true do
    local bfinal = getbits(br, 1)
    local btype = getbits(br, 2)

    if btype == 0 then
      align_byte(br)
      local len = getbits(br, 16)
      local _nlen = getbits(br, 16)
      for _ = 1, len do
        out[#out + 1] = getbits(br, 8)
      end
    elseif btype == 1 or btype == 2 then
      local lit_codes, dist_codes
      if btype == 1 then
        lit_codes, dist_codes = FIXED_LIT_CODES, FIXED_DIST_CODES
      else
        lit_codes, dist_codes = read_dynamic_tables(br)
      end

      while true do
        local sym = decode_symbol(br, lit_codes)
        if sym < 256 then
          out[#out + 1] = sym
        elseif sym == 256 then
          break
        else
          local li = sym - 257 + 1
          if li < 1 or li > 29 then
            error("nieprawidlowy symbol dlugosci: " .. tostring(sym))
          end
          local length = LENGTH_BASE[li] + getbits(br, LENGTH_EXTRA[li])
          local dsym = decode_symbol(br, dist_codes)
          local di = dsym + 1
          if di < 1 or di > 30 then
            error("nieprawidlowy symbol odleglosci: " .. tostring(dsym))
          end
          local distance = DIST_BASE[di] + getbits(br, DIST_EXTRA[di])
          local start = #out - distance + 1
          if start < 1 then
            error("nieprawidlowa odleglosc wsteczna w strumieniu DEFLATE")
          end
          for k = 0, length - 1 do
            out[#out + 1] = out[start + k]
          end
        end
      end
    else
      error("nieobslugiwany typ bloku DEFLATE (btype=3)")
    end

    if bfinal == 1 then break end
  end

  return bytes_to_string(out)
end

return M
