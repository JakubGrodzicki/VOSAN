-- vosan_scroll.lua
-- Decyduje, ktora kwestie trzeba w tej klatce doprowadzic do widoku tabeli.
-- CELOWO nie ma tu zadnej matematyki pikseli - i to jest sedno tego modulu.
--
-- Historia (dwa nieudane podejscia, commity 4b504ff i befc03b): auto-przewijanie
-- liczylo cel samo, ze wzoru `top = (pozycja - 1) * wysokosc_wiersza`. Wysokosc
-- wiersza byla mierzona w petli rysowania jako odstep miedzy DWOMA PIERWSZYMI
-- wierszami zlozonymi w klatce:
--
--     local _, probe_y = reaper.ImGui_GetCursorScreenPos(ctx)
--     if probe_y1 == nil then probe_y1 = probe_y else probe_y2 = probe_y end
--
-- Te dwa wiersze nie sasiaduja ze soba. ImGui_ListClipper_Begin jest wolany bez
-- opcjonalnego argumentu items_height, wiec clipper w KAZDEJ klatce robi
-- przebieg pomiarowy: najpierw sklada wiersz 0 na gorze CALEJ zawartosci, potem
-- przestawia kursor i sklada dopiero faktycznie widoczny zakres na gorze WIDOKU.
-- Zmierzona roznica to wiec mniej wiecej biezacy ScrollY, a nie wysokosc
-- wiersza. Na samej gorze listy oba pomiary schodza sie w jednym punkcie
-- (roznica 0, wiec _row_h w ogole sie nie zapisywalo) - dlatego na krotkim
-- arkuszu wygladalo to poprawnie. Po przewinieciu w dol _row_h rosla do setek
-- pikseli, `top` wychodzil ogromny, cel przekraczal ScrollMaxY, ImGui przycinal
-- go po cichu do konca listy i tabela skakala na sam dol. Centrowanie (drugie
-- podejscie) nie moglo tego naprawic, bo blad siedzial w danych wejsciowych, a
-- nie we wzorze.
--
-- Dlatego teraz pozycje wyznacza samo ImGui: vosan_ui wymusza zlozenie wybranego
-- wiersza przez ImGui_ListClipper_IncludeItemByIndex i zaraz po nim wola
-- ImGui_SetScrollHereY. Ta funkcja liczy cel z prostokata wiersza, ktory ImGui
-- wlasnie ulozyl, sama uwzglednia zamrozony naglowek i sama przycina wynik do
-- prawdziwego zakresu przewijania. Zadna z wielkosci, ktore wczesniej psuly
-- wynik (wysokosc wiersza, wysokosc widoku, ScrollMaxY), nie jest tu potrzebna.
--
-- Temu modulowi zostaje wiec sama polityka: KIEDY przewijac. Ta czesc da sie
-- przetestowac bez ReaImGui (patrz tests/test_scroll.lua).

local M = {}

--- Pionowe zakotwiczenie wybranego wiersza w widoku, dla ImGui_SetScrollHereY:
--- 0.0 = gora, 0.5 = srodek, 1.0 = dol. 0.40 to lekko nad srodkiem - aktor
--- czyta w dol, wiec ponizej wybranej kwestii warto pokazac wiecej niz powyzej.
--- Przy koncach listy ImGui przycina przewijanie i wiersz naturalnie laduje
--- wyzej (poczatek) albo nizej (koniec) niz to zakotwiczenie.
M.CENTER_RATIO = 0.40

--- Zwraca `item_index, sel_id` - pozycje wybranej kwestii na liscie
--- state.filtered LICZONA OD ZERA (tak indeksuje ListClipper) oraz indeks
--- wiersza, ktorego ta pozycja dotyczy. Zwraca nil, gdy nie ma czego przewijac:
---   - nic nie jest wybrane,
---   - ten wybor zostal juz obsluzony (state._scroll_anchor),
---   - wybrana kwestia nie przechodzi przez aktualny filtr.
---
--- Przewijamy DOKLADNIE RAZ na zmiane wyboru. Bez tego warunku tabela
--- dociagalaby wybrany wiersz w kazdej klatce i realizator nie moglby przewinac
--- listy recznie - kazde przewiniecie zostaloby natychmiast cofniete.
---
--- W przypadku wyboru poza filtrem funkcja sama ustawia kotwice: nie ma czego
--- szukac, a bez tego przeszukiwalaby cala liste w kazdej klatce.
function M.pending_item(state)
  local sel = state.selected
  if sel == nil or sel == state._scroll_anchor then return nil end

  local filtered = state.filtered or {}
  for i = 1, #filtered do
    if filtered[i] == sel then
      return i - 1, sel
    end
  end

  state._scroll_anchor = sel
  return nil
end

--- Zapisuje, ze ten wybor zostal juz doprowadzony do widoku.
---
--- `sel_id` jest przekazywane z zewnatrz, a NIE czytane z state.selected,
--- bo miedzy decyzja a tym wywolaniem wybor moze sie zmienic w tej samej
--- klatce: klikniecie wiersza w tabeli ustawia state.selected od razu w petli
--- rysowania. Zapisanie wtedy nowego wyboru jako "obsluzonego" zjadloby
--- przewiniecie do wiersza, ktory realizator wlasnie kliknal.
function M.mark_done(state, sel_id)
  state._scroll_anchor = sel_id
end

--- Uniewaznia kotwice - nastepna klatka doprowadzi wybor do widoku na nowo.
--- Wolane z vosan_state.refresh_filter, czyli wszedzie tam, gdzie zmieniaja sie
--- pozycje wierszy (szukajka, wybor postaci, wczytanie pliku).
function M.invalidate(state)
  state._scroll_anchor = nil
end

return M
