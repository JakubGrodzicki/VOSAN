-- vosan_regions.lua
-- Tworzenie / zastepowanie / odpytywanie regionow projektu REAPER.
-- Retake tej samej kwestii zastepuje stary region o tej samej nazwie - w
-- projekcie zawsze istnieje tylko najnowsza wersja danej kwestii, co
-- jednoczesnie sluzy jako naturalny wskaznik postepu nagrywania.

local M = {}

--- Zbior nazw wszystkich regionow ({[nazwa]=true}) - do szybkiego sprawdzania
--- statusu "nagrane" bez powtarzania enumeracji dla kazdego wiersza.
--- Enumeruje wprost, bez budowania posredniej tablicy rekordow: ta funkcja
--- chodzi cyklicznie z petli rysowania, a w duzej sesji regionow sa setki.
function M.get_region_names_set()
  local set = {}
  local i = 0
  while true do
    local retval, isrgn, _, _, name = reaper.EnumProjectMarkers3(0, i)
    if retval == 0 then break end
    if isrgn then set[name] = true end
    i = i + 1
  end
  return set
end

--- Zwraca {markrgnindexnumber, name, start, stop} pierwszego regionu o podanej
--- nazwie, albo nil. Konczy enumeracje na trafieniu.
function M.find_region_by_name(name)
  local i = 0
  while true do
    local retval, isrgn, pos, rgnend, rname, markrgnindexnumber = reaper.EnumProjectMarkers3(0, i)
    if retval == 0 then break end
    if isrgn and rname == name then
      return {
        markrgnindexnumber = markrgnindexnumber,
        name = rname,
        start = pos,
        stop = rgnend,
      }
    end
    i = i + 1
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
