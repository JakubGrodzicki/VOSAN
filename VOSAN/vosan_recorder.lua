-- vosan_recorder.lua
-- Watcher stanu nagrywania. Wywolywany co klatke z glownej petli reaper.defer.
-- Nie steruje transportem - realizator nagrywa normalnym transportem Reapera
-- (spacja/R/przycisk Record); ten modul tylko wykrywa koniec nagrywania
-- (GetPlayState, bit &4) i ustala DOKLADNY zakres nowo powstalego itemu,
-- przez porownanie z migawka itemow na uzbrojonych sciezkach sprzed nagrania.
--
-- Migawka jest odswiezana w kazdej klatce, w ktorej nagrywanie NIE trwa (wiec
-- zawsze mamy gotowa, aktualna migawke sprzed startu, bez wyscigu czasowego).
-- Po zatrzymaniu nagrywania REAPER dolacza nowy item do sciezki z niewielkim
-- opoznieniem (nie w tej samej klatce co zmiana stanu transportu), dlatego
-- sprawdzamy co klatke przez okno czasowe zamiast tylko raz.
--
-- WAZNE: jesli w Preferences > Audio > Recording jest wlaczone "Prompt to
-- save/delete/rename new files: on stop", REAPER po kazdym zatrzymaniu
-- nagrywania pokazuje modalne okno blokujace WSZYSTKO (wlacznie z ta petla)
-- az do recznego kliknieca "Save All" - wtedy zaden automat, w tym VOSAN,
-- nie zadziala. To ustawienie musi byc wylaczone (patrz README).

local M = {}

local was_recording = false
local last_known_snapshot = {}
local pending_deadline = nil -- nil = nie czekamy; liczba = reaper.time_precise() deadline
-- Gorny limit PROB wykrycia nowego itemu po zatrzymaniu nagrywania - NIE jest
-- to stale opoznienie doliczane do kazdego ujecia (sprawdzanie konczy sie
-- natychmiast, gdy item zostanie znaleziony - w praktyce ~0.01s). To tylko
-- zabezpieczenie na wypadek, gdy nic nowego nie powstalo (np. sciezka byla
-- tylko uzbrojona bez faktycznego nagrania) - po tym czasie skrypt cicho
-- rezygnuje, bez blokowania interfejsu.
local PENDING_TIMEOUT = 1.5

local function get_armed_tracks()
  local tracks = {}
  local count = reaper.CountTracks(0)
  for i = 0, count - 1 do
    local tr = reaper.GetTrack(0, i)
    if reaper.GetMediaTrackInfo_Value(tr, "I_RECARM") == 1 then
      tracks[#tracks + 1] = tr
    end
  end
  return tracks
end

local function snapshot_armed_items(armed_tracks)
  local snap = {}
  for _, tr in ipairs(armed_tracks) do
    local cnt = reaper.CountTrackMediaItems(tr)
    for i = 0, cnt - 1 do
      local item = reaper.GetTrackMediaItem(tr, i)
      local ok, guid = reaper.GetSetMediaItemInfo_String(item, "GUID", "", false)
      if ok then snap[guid] = true end
    end
  end
  return snap
end

local function find_new_items(armed_tracks, old_snapshot)
  local new_items = {}
  for _, tr in ipairs(armed_tracks) do
    local cnt = reaper.CountTrackMediaItems(tr)
    for i = 0, cnt - 1 do
      local item = reaper.GetTrackMediaItem(tr, i)
      local ok, guid = reaper.GetSetMediaItemInfo_String(item, "GUID", "", false)
      if ok and not old_snapshot[guid] then
        new_items[#new_items + 1] = item
      end
    end
  end
  return new_items
end

local function bounds_of(items)
  local start_pos, end_pos = nil, nil
  for _, item in ipairs(items) do
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local item_end = pos + len
    if not start_pos or pos < start_pos then start_pos = pos end
    if not end_pos or item_end > end_pos then end_pos = item_end end
  end
  return start_pos, end_pos
end

--- Wywolywana co klatke. `on_recording_finished(start_pos, end_pos)` jest
--- wolane wylacznie gdy nagrywanie sie zakonczylo i powstal co najmniej
--- jeden nowy item na uzbrojonej sciezce.
function M.poll(on_recording_finished)
  local playstate = reaper.GetPlayState()
  local is_recording = (playstate & 4) == 4

  if (not is_recording) and was_recording then
    pending_deadline = reaper.time_precise() + PENDING_TIMEOUT
  end

  if pending_deadline then
    local armed_tracks = get_armed_tracks()
    local new_items = find_new_items(armed_tracks, last_known_snapshot)

    if #new_items > 0 then
      local start_pos, end_pos = bounds_of(new_items)
      on_recording_finished(start_pos, end_pos)
      pending_deadline = nil
      last_known_snapshot = snapshot_armed_items(get_armed_tracks())
    elseif reaper.time_precise() > pending_deadline then
      pending_deadline = nil
      last_known_snapshot = snapshot_armed_items(get_armed_tracks())
    end
  elseif not is_recording then
    last_known_snapshot = snapshot_armed_items(get_armed_tracks())
  end

  was_recording = is_recording
end

return M
