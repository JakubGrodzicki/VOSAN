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

--- Przygotowuje Region Render Matrix (tylko na sciezce Master) dla podanych regionow.
--- Parametr `regionindex` funkcji SetRegionRenderMatrix to markrgnindexnumber
--- z EnumProjectMarkers3 (numer regionu), a NIE indeks enumeracji - dokumentacja
--- tego nie precyzuje, ale potwierdzil to test w REAPERze 7.79: okno renderu
--- pokazalo dokladnie te regiony, ktore trafily do macierzy.
--- @param region_names_to_render table zbior nazw regionow, ktore maja byc wlaczone ({[nazwa]=true})
function M.prepare_render_matrix(region_names_to_render)
  local master_track = reaper.GetMasterTrack(0)
  
  local i = 0
  while true do
    local retval, isrgn, pos, rgnend, rname, markrgnindexnumber = reaper.EnumProjectMarkers3(0, i)
    if retval == 0 then break end
    if isrgn then
      if region_names_to_render[rname] then
        reaper.SetRegionRenderMatrix(0, markrgnindexnumber, master_track, 1)
      else
        reaper.SetRegionRenderMatrix(0, markrgnindexnumber, master_track, -1)
      end
    end
    i = i + 1
  end
end

--- true, jesli REAPER ma API zaznaczania regionow (pole B_UISEL). Zestaw
--- GetRegionOrMarker/SetRegionOrMarkerInfo_Value doszedl w REAPER 7.62; w
--- starszych wersjach regiony da sie zaznaczyc TYLKO recznie, wiec render
--- "Bounds: Selected regions" jest z poziomu skryptu nieosiagalny i trzeba
--- uzyc Region Render Matrix (patrz prepare_render_matrix).
function M.has_region_selection_api()
  return reaper.APIExists('GetNumRegionsOrMarkers')
    and reaper.APIExists('GetRegionOrMarker')
    and reaper.APIExists('GetRegionOrMarkerInfo_Value')
    and reaper.APIExists('SetRegionOrMarkerInfo_Value')
    and reaper.APIExists('GetSetRegionOrMarkerInfo_String')
end

--- Zaznacza regiony o nazwach z `names` ({[nazwa]=true}) i ODZNACZA wszystkie
--- pozostale. Daje dokladnie ten sam efekt, co reczne klikniecie regionow w
--- Region Managerze, czyli buduje zbior uzywany przez render z opcja
--- "Bounds: Selected regions".
--- Wymaga API z REAPER 7.62+ (patrz has_region_selection_api).
--- Zwraca liczbe zaznaczonych regionow.
function M.select_regions_by_name(names)
  local total = reaper.GetNumRegionsOrMarkers(0)
  local selected = 0
  for i = 0, total - 1 do
    local rm = reaper.GetRegionOrMarker(0, i, "")
    if rm and reaper.GetRegionOrMarkerInfo_Value(0, rm, "B_ISREGION") ~= 0 then
      local _, rname = reaper.GetSetRegionOrMarkerInfo_String(0, rm, "P_NAME", "", false)
      local want = names[rname] and 1 or 0
      reaper.SetRegionOrMarkerInfo_Value(0, rm, "B_UISEL", want)
      selected = selected + want
    end
  end
  return selected
end

return M