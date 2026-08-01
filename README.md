# VOSAN — Voice Over Script Auto Namer

VOSAN jest skryptem do REAPERa. VOSAN nazywa nagrania dubbingu automatycznie.
VOSAN tworzy nazwane regiony na osi czasu podczas nagrywania.

Realizator wybiera jedną kwestię z listy. Realizator nagrywa aktora
normalnym transportem REAPERa. VOSAN wykrywa koniec nagrania. VOSAN
tworzy region wokół nagrania. VOSAN nadaje regionowi nazwę wybranej
kwestii.

Realizator eksportuje pliki ręcznie po sesji (Render, źródło Regions,
wildcard `@region_name`).

## Format pliku wejściowego

VOSAN przyjmuje pliki CSV i XLSX. Format kolumn jest następujący:

1. **Pierwsza kolumna** zawiera nazwę skryptu. VOSAN używa tej nazwy jako
   nazwy regionu.
2. **Ostatnia kolumna** zawiera tekst kwestii.
3. **Kolumny środkowe** są opcjonalne. Kolumny środkowe mogą zawierać
   dowolne informacje pomocnicze dla aktora (na przykład nazwę pliku
   źródłowego, flagę głównej postaci). VOSAN wyświetla te kolumny w
   tabeli i w panelu „Teraz nagrywasz”. VOSAN nie nadaje im żadnego
   specjalnego znaczenia.

Liczba kolumn środkowych jest dowolna. Plik może mieć 2 kolumny (tylko
nazwa skryptu i tekst) albo więcej. Przykład z czterema kolumnami:

| Nazwa skryptu       | Plik źródłowy   | MC  | Tekst                          |
|----------------------|-----------------|-----|----------------------------------|
| DIA_Straznik_01_01   | Straznik.json   | Nie | Stój! Kto tam idzie?            |
| DIA_Bohater_03_01    | Bohater.json    | Tak | Coś tu nie gra, muszę uważać.   |

Pierwszy wiersz może być nagłówkiem. Zaznacz checkbox „Pierwszy wiersz to
nagłówek” w oknie VOSAN, jeśli plik ma nagłówek. Nazwy kolumn z nagłówka
staną się etykietami w tabeli i w panelu „Teraz nagrywasz”.

## Instalacja

Wykonaj te kroki na każdym urządzeniu, na którym uruchamiasz VOSAN.

1. Skopiuj folder `VOSAN` do folderu `Scripts` w profilu REAPERa. Znajdź
   folder `Scripts` przez REAPER → Options → Show REAPER resource path
   in explorer/finder.
2. Zainstaluj wtyczkę ReaImGui. Otwórz Extensions → ReaPack → Browse
   packages. Wpisz `ReaImGui`. Zainstaluj pakiet „ReaImGui: ReaScript
   binding for Dear ImGui”. Zrestartuj REAPER.
   - Jeśli REAPER nie ma ReaPacka, zainstaluj go najpierw ze strony
     reapack.com.
3. Dodaj VOSAN do listy akcji REAPERa. Otwórz Actions → Show action
   list. Kliknij New action → Load ReaScript. Wskaż plik `VOSAN.lua`.
   Możesz przypisać skrót klawiszowy do tej akcji.
4. Wyłącz monit o zapisie plików po nagraniu. Otwórz Preferences →
   Audio → Recording. Odznacz „Prompt to save/delete/rename new files:
   on stop”.

   **Uwaga:** Ten krok jest obowiązkowy. Jeśli to ustawienie zostanie
   włączone, REAPER pokaże modalne okno po każdym zatrzymaniu nagrania.
   To okno blokuje cały REAPER, włącznie z VOSAN, aż realizator kliknie
   „Save All”. VOSAN nie utworzy regionu automatycznie, dopóki to okno
   jest otwarte.

VOSAN nie wymaga żadnych innych zależności. Parser CSV, parser XLSX i
wykrywanie nagrania działają na natywnym API REAPERa w czystym Lua.

## Użycie

1. Uruchom akcję VOSAN. Otworzy się okno VOSAN.
2. Kliknij „Wczytaj plik (CSV / XLSX)...”. Wskaż plik ze skryptem
   dubbingowym.
3. Kliknij wiersz z kwestią, którą aktor zaraz nagra. Wiersz podświetli
   się w tabeli. Treść kwestii pojawi się pogrubioną, większą czcionką w
   panelu „Teraz nagrywasz” na górze okna. Patrz tylko na ten panel
   podczas nagrywania.
4. Nagraj kwestię normalnym transportem REAPERa (spacja, R, albo
   przycisk Record). Zatrzymaj nagranie.
5. VOSAN wykryje koniec nagrania automatycznie. VOSAN utworzy region
   wokół nagrania. VOSAN nada regionowi nazwę wybranej kwestii.
6. VOSAN zaznaczy kolejną kwestię z listy automatycznie, jeśli checkbox
   „Auto-przejście do następnej kwestii po nagraniu” jest zaznaczony
   (domyślne ustawienie). Nagrywaj kolejną kwestię bez klikania w oknie
   VOSAN.

### Retake (powtórka nagrania)

Zaznacz tę samą kwestię ponownie. Nagraj ją jeszcze raz. VOSAN usunie
stary region o tej nazwie. VOSAN utworzy nowy region w to miejsce. W
projekcie istnieje zawsze tylko jedna, najnowsza wersja każdej kwestii.

Zielony wiersz w tabeli oznacza kwestię z istniejącym regionem
(nagraną). Kolor pomarańczowy oznacza aktualnie wybraną kwestię.

### Kwestie głównego bohatera (MC) i pozostałych postaci

Niektóre arkusze zawierają kwestie dwóch postaci naraz: głównego
bohatera (MC) i drugiej postaci, której arkusz dotyczy. Powodem jest
zachowanie kontekstu rozmowy. Realizator nagrywa jedną postać na raz z
tego samego arkusza.

VOSAN rozpoznaje ten przypadek automatycznie. Warunek: plik ma kolumnę o
nazwie „MC” z wartościami „Tak” albo „Nie”. Jeśli ten warunek jest
spełniony, w oknie VOSAN pojawi się dodatkowy checkbox „Czy nagrywamy
głównego bohatera (MC)?”.

- Checkbox odznaczony (domyślne ustawienie): VOSAN pomija kwestie MC
  przy auto-przejściu. VOSAN zatrzymuje się tylko na kwestiach z
  wartością „Nie” w kolumnie MC.
- Checkbox zaznaczony: VOSAN pomija kwestie pozostałych postaci przy
  auto-przejściu. VOSAN zatrzymuje się tylko na kwestiach z wartością
  „Tak” w kolumnie MC.

Tabela pokazuje wszystkie kwestie przez cały czas, także te, które nie
należą do aktualnie nagrywanej postaci. Powodem jest zachowanie
kontekstu rozmowy dla aktora. Kolor wiersza pokazuje status kwestii:

1. Pomarańczowy: aktualnie wybrana kwestia.
2. Zielony: kwestia ma już nagrany region.
3. Niebieski: kwestia należy do aktualnie nagrywanej postaci (zgodnie z
   checkboxem) i czeka na nagranie.
4. Szary: kwestia należy do drugiej postaci w arkuszu. Ta kwestia służy
   tylko jako kontekst rozmowy.

Realizator może kliknąć dowolny wiersz ręcznie, także szary. Checkbox
wpływa tylko na auto-przejście i na kolory w tabeli.

### Brak wybranej kwestii

VOSAN nie gubi żadnego nagrania. Jeśli nagranie zakończy się bez
wybranej kwestii, VOSAN utworzy region z tymczasową nazwą
`NIEPRZYPISANE_<data>_<godzina>`. VOSAN pokaże czerwone ostrzeżenie w
oknie. Zmień nazwę tego regionu ręcznie w REAPERze.

### Eksport

1. Otwórz File → Render...
2. Ustaw źródło (Source) na „Regions”.
3. Wpisz wildcard `@region_name` w polu nazwy pliku.
4. Kliknij Render.

## Pliki testowe

Folder `samples/` zawiera przykładowe pliki `sample_kwestie.csv` i
`sample_kwestie.xlsx`. Oba pliki mają identyczną zawartość: 10 wierszy
testowych, w tym jeden celowy duplikat nazwy skryptu. Użyj tych plików
do szybkiego sprawdzenia importu po instalacji.

## Ograniczenia

- VOSAN wykrywa standardowy tryb nagrywania: pusta ścieżka, nowy item na
  uzbrojonej ścieżce. VOSAN nie obsługuje trybu „tape” (nagrywanie w
  istniejący item jako nowy take).
- Import dużych plików XLSX może potrwać kilka do kilkunastu sekund.
  Powodem jest dekompresja DEFLATE w czystym Lua, bez zewnętrznych
  bibliotek. Użyj formatu CSV dla plików z wieloma tysiącami wierszy —
  import CSV jest szybszy.
- Wyszukiwanie w polu filtra ignoruje wielkość liter tylko dla znaków
  ASCII. Polskie znaki diakrytyczne (ą, ć, ę, ó, ...) rozróżniają
  wielkość liter. Powodem jest ograniczenie standardowej biblioteki Lua.
- Region powstaje z dokładnym zakresem nagranego itemu. VOSAN nie dodaje
  paddingu ani ciszy przed i po nagraniu.
