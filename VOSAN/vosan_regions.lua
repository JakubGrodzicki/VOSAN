-- vosan_regions.lua
-- Tworzenie / zastepowanie / odpytywanie regionow projektu REAPER.
-- Retake tej samej kwestii zastepuje stary region o tej samej nazwie - w
-- projekcie zawsze istnieje tylko najnowsza wersja danej kwestii, co
-- jednoczesnie sluzy jako naturalny wskaznik postepu nagrywania.

local M = {}

--- Zwraca tablice wszystkich regionow projektu: {markrgnindexnumber, name, start, stop}.
function M.get_all_regions()
  local regions = {}
  local i = 0
  while true do
    local retval, isrgn, pos, rgnend, name, markrgnindexnumber = reaper.EnumProjectMarkers3(0, i)
    if retval == 0 then break end
    if isrgn then
      regions[#regions + 1] = {
        markrgnindexnumber = markrgnindexnumber,
        name = name,
        start = pos,
        stop = rgnend,
      }
    end
    i = i + 1
  end
  return regions
end

--- Zbior nazw wszystkich regionow ({[nazwa]=true}) - do szybkiego sprawdzania
--- statusu "nagrane" bez powtarzania enumeracji dla kazdego wiersza.
function M.get_region_names_set()
  local set = {}
  for _, r in ipairs(M.get_all_regions()) do
    set[r.name] = true
  end
  return set
end

function M.find_region_by_name(name)
  for _, r in ipairs(M.get_all_regions()) do
    if r.name == name then return r end
  end
  return nil
end

--- Tworzy nowy region [start_pos, end_pos] o podanej nazwie. Jesli istnieje
--- juz region o tej samej nazwie, zostaje najpierw usuniety (retake).
--- Zwraca indeks nowo utworzonego regionu.
function M.create_or_replace_region(name, start_pos, end_pos)
  reaper.Undo_BeginBlock()

  local existing = M.find_region_by_name(name)
  if existing then
    reaper.DeleteProjectMarker(0, existing.markrgnindexnumber, true)
  end

  local idx = reaper.AddProjectMarker2(0, true, start_pos, end_pos, name, -1, 0)

  reaper.Undo_EndBlock("VOSAN: region '" .. name .. "'", -1)
  return idx
end

return M
