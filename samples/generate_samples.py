"""
Generuje pliki testowe sample_kwestie.csv i sample_kwestie.xlsx z identyczna
zawartoscia (naglowek + 10 wierszy, w tym jeden CELOWY duplikat nazwy
skryptu do testu ostrzezenia o duplikatach). Uzywa wylacznie biblioteki
standardowej Pythona (csv, zipfile) - brak zewnetrznych zaleznosci.

Uruchom: python generate_samples.py
"""
import csv
import os
import zipfile

OUT_DIR = os.path.dirname(os.path.abspath(__file__))
CSV_PATH = os.path.join(OUT_DIR, "sample_kwestie.csv")
XLSX_PATH = os.path.join(OUT_DIR, "sample_kwestie.xlsx")

ROWS = [
    ("Nazwa skryptu", "Plik zrodlowy", "MC", "Tekst"),
    ("DIA_Straznik_01_01", "Straznik.json", "Nie", "Stój! Kto tam idzie?"),
    ("DIA_Straznik_01_02", "Straznik.json", "Nie", 'Do broni, mamy intruza w "skarbcu"!'),
    ("DIA_Kupiec_02_01", "Kupiec.json", "Nie", "Witaj, podróżniku, masz szczęście, właśnie dostałem nowy towar."),
    ("DIA_Kupiec_02_02", "Kupiec.json", "Nie", "Ta klinga, ta zbroja, ten eliksir - wszystko na sprzedaż."),
    ("DIA_Bohater_03_01", "Bohater.json", "Tak", "Coś tu nie gra, muszę być ostrożny."),
    ("DIA_Krolowa_04_01", "Krolowa.json", "Nie", "Sprowadźcie mi głowę zdrajcy, natychmiast!"),
    ("DIA_Narrator_05_01", "Narrator.json", "Nie", "Dawno, dawno temu, w krainie pełnej magii i niebezpieczeństw..."),
    ("DIA_Straznik_01_01", "Straznik.json", "Nie", "To jest CELOWY duplikat nazwy skryptu DIA_Straznik_01_01 - test ostrzezenia o duplikatach."),
    ("DIA_Napis_06_01", "Napis.json", "Nie", "Zamknięte; wróć jutro."),
    ("DIA_Straznik_01_03", "Straznik.json", "Nie", "Ruszaj dalej, nic tu po Tobie."),
]

# --- CSV (srednik, jak domyslny polski Excel) - moduł csv sam poprawnie
# escapuje cudzyslowy i srednik wewnatrz pol.
with open(CSV_PATH, "w", newline="", encoding="utf-8-sig") as f:
    writer = csv.writer(f, delimiter=";", quoting=csv.QUOTE_MINIMAL)
    for row in ROWS:
        writer.writerow(row)
print("Zapisano:", CSV_PATH)

# --- XLSX (minimalny, poprawny plik OOXML zbudowany recznie) --------------

CONTENT_TYPES = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
</Types>"""

RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>"""

WORKBOOK = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets><sheet name="Kwestie" sheetId="1" r:id="rId1"/></sheets>
</workbook>"""

WORKBOOK_RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
</Relationships>"""


def esc(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
             .replace('"', "&quot;").replace("'", "&apos;"))


shared = []
shared_index = {}


def sidx(s):
    if s not in shared_index:
        shared_index[s] = len(shared)
        shared.append(s)
    return shared_index[s]


def col_letter(n):
    """1 -> A, 2 -> B, ..., 27 -> AA (wystarczajace dla malej liczby kolumn tutaj)."""
    letters = ""
    while n > 0:
        n, rem = divmod(n - 1, 26)
        letters = chr(65 + rem) + letters
    return letters


# Wliczamy WIERSZ NAGLOWKA (ROWS[0]) do arkusza xlsx tak samo jak w CSV -
# domyslnie wlaczony w VOSAN checkbox "Pierwszy wiersz to naglowek" musi
# miec co pominac w OBU formatach, inaczej w xlsx zjada pierwszy realny wiersz.
cells_xml = []
for r, row in enumerate(ROWS, start=1):
    cells = []
    for c, value in enumerate(row, start=1):
        i = sidx(value)
        cells.append(f'<c r="{col_letter(c)}{r}" t="s"><v>{i}</v></c>')
    cells_xml.append(f'<row r="{r}">' + "".join(cells) + "</row>")

SHEET1 = ("""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<sheetData>""" + "".join(cells_xml) + "</sheetData></worksheet>")

SHARED_STRINGS = ("""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="%d" uniqueCount="%d">"""
                   % (len(shared), len(shared))
                   + "".join(f"<si><t>{esc(s)}</t></si>" for s in shared)
                   + "</sst>")

with zipfile.ZipFile(XLSX_PATH, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("[Content_Types].xml", CONTENT_TYPES)
    z.writestr("_rels/.rels", RELS)
    z.writestr("xl/workbook.xml", WORKBOOK)
    z.writestr("xl/_rels/workbook.xml.rels", WORKBOOK_RELS)
    z.writestr("xl/worksheets/sheet1.xml", SHEET1)
    z.writestr("xl/sharedStrings.xml", SHARED_STRINGS)
print("Zapisano:", XLSX_PATH)
