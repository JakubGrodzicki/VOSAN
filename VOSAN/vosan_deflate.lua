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

local function align_byte(br)
  local drop = br.bitcnt % 8
  br.bitbuf = br.bitbuf >> drop
  br.bitcnt = br.bitcnt - drop
end

-- === Huffman ================================================================
-- Kanoniczne drzewo Huffmana (RFC1951 3.2.2) trzymane jako dwie plaskie
-- tablice, metoda z referencyjnego dekodera "puff" ze zrodel zlib:
--   counts[l] = ile kodow ma dlugosc l,
--   symbols   = symbole uporzadkowane wg (dlugosc kodu, wartosc kodu).
-- Dekodowanie idzie bit po bicie (najwyzej 15 bitow), ale odczyt bitow jest
-- wpisany wprost w petle i operuje na zmiennych lokalnych. Poprzednia wersja
-- wolala na kazdy bit trzy funkcje (getbit -> getbits -> br_ensure) i szukala
-- w tablicy haszowanej; przy imporcie liczonym w milionach bitow to dominowalo
-- caly czas dekompresji.

local MAXBITS = 15

local function build_huffman(lengths)
  local counts = {}
  for l = 0, MAXBITS do counts[l] = 0 end
  for i = 1, #lengths do
    local l = lengths[i]
    counts[l] = counts[l] + 1
  end
  counts[0] = 0 -- symbole o dlugosci kodu 0 nie wystepuja w strumieniu

  local offsets = {}
  offsets[1] = 0
  for l = 1, MAXBITS - 1 do
    offsets[l + 1] = offsets[l] + counts[l]
  end

  local symbols = {}
  for i = 1, #lengths do
    local l = lengths[i]
    if l > 0 then
      symbols[offsets[l] + 1] = i - 1
      offsets[l] = offsets[l] + 1
    end
  end

  return { counts = counts, symbols = symbols }
end

local function decode_symbol(br, huff)
  local counts, symbols = huff.counts, huff.symbols
  local data, len = br.data, br.len
  local bitbuf, bitcnt, bytepos = br.bitbuf, br.bitcnt, br.bytepos
  -- code: kod zebrany do tej pory, first: najmniejszy kod danej dlugosci,
  -- index: ile symbolow maja kody krotsze niz biezaca dlugosc.
  local code, first, index = 0, 0, 0

  for l = 1, MAXBITS do
    if bitcnt == 0 then
      local b = 0
      if bytepos <= len then b = string.byte(data, bytepos) end
      bytepos = bytepos + 1
      bitbuf, bitcnt = b, 8
    end
    code = code | (bitbuf & 1)
    bitbuf = bitbuf >> 1
    bitcnt = bitcnt - 1

    local count = counts[l]
    if code - count < first then
      local sym = symbols[index + (code - first) + 1]
      if sym == nil then
        error("nieprawidlowy kod Huffmana - strumien DEFLATE jest uszkodzony")
      end
      br.bitbuf, br.bitcnt, br.bytepos = bitbuf, bitcnt, bytepos
      return sym
    end
    index = index + count
    first = (first + count) << 1
    code = code << 1
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
local function bytes_to_string(bytes, n)
  local CHUNK = 4096
  local chunks = {}
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
  -- Jawny licznik dlugosci wyjscia. Poprzednia wersja wolala #out raz na kazdy
  -- bajt wyniku (i drugi raz w petli kopiowania dopasowan wstecznych).
  local outn = 0

  while true do
    local bfinal = getbits(br, 1)
    local btype = getbits(br, 2)

    if btype == 0 then
      align_byte(br)
      local len = getbits(br, 16)
      local _nlen = getbits(br, 16)
      for _ = 1, len do
        outn = outn + 1
        out[outn] = getbits(br, 8)
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
          outn = outn + 1
          out[outn] = sym
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
          local start = outn - distance + 1
          if start < 1 then
            error("nieprawidlowa odleglosc wsteczna w strumieniu DEFLATE")
          end
          -- kopiowanie musi isc po kolei: przy distance < length czytamy bajty,
          -- ktore wlasnie dopisalismy w tej samej petli
          for k = start, start + length - 1 do
            outn = outn + 1
            out[outn] = out[k]
          end
        end
      end
    else
      error("nieobslugiwany typ bloku DEFLATE (btype=3)")
    end

    if bfinal == 1 then break end
  end

  return bytes_to_string(out, outn)
end

return M
