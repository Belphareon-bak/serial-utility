# Oprava filtru technických tagů

Větev `docs/revize-2026-09-23`.

## Co bylo špatně

`Remove-Tags` testovala každý token názvu proti jedinému seznamu technických tagů.
V tom seznamu byla i slova, která jsou zároveň součástí skutečných názvů: `max`,
`ray`, `blu`, `dual`, `complete`, `extended`, `limited`, `sub`, `multi`, `web`, `rip`.

Ověřeno spuštěním **původního** skriptu pod PowerShellem:

| Vstup | Původní výsledek |
|---|---|
| `Mad Max Fury Road 2015 1080p BluRay x264.mkv` | `Mad Fury Road (2015).mkv` |
| `Max 2015 BRRip.mkv` | **`2015 (2015).mkv`** |
| `Ray 2004 1080p BluRay x264 CZ.mkv` | **`2004 (2004).mkv`** |
| `Blu 2019 1080p.mkv` | **`2019 (2019).mkv`** |
| `The Limited 2019 WEB-DL.mkv` | `The (2019).mkv` |
| `Sub Zero 2005 DVDRip.mkv` | `Zero (2005).mkv` |

U tří z nich z názvu zbyl jen letopočet. Přejmenování je přitom výchozí chování
a `-Apply` soubor přejmenuje natrvalo.

## Jak je to opravené

Seznam je rozdělený na dva.

**`$TagPatternStrict`** — tagy, které nejsou zároveň běžnými slovy (`1080p`, `x265`,
`hevc`, `webrip`, `bdremux`, `hdtv`, `atmos`…). Sem patří i jazykové a dabingové
značky `cz`, `sk`, `en`, `dab`, `tit`, `forced`, `titulky` — v české knihovně to
nejsou názvy. Vyhazují se z celé délky názvu.

**`$TagPatternLoose`** — tagy, které jsou zároveň běžná slova (`max`, `ray`, `blu`,
`web`, `rip`, `opus`, `dual`, `complete`, `extended`, `limited`, `multi`, `sub`,
`hd`, `sd`, `dl`, `dv`, `nf`, `ws`, `proper`, `internal`, `uncut`, `unrated`).
Vyhazují se **jen z části za rokem nebo za `SxxEyy`**, kde už název být nemůže.
Před rokem zůstávají — lepší jeden zbytečný tag v názvu než utržený název.

`Remove-Tags` a `Get-CleanSegment` mají nově přepínač `-Trailing`, který druhou
skupinu zapíná. Používá se na text za `SxxEyy` a za rokem.

**Pojistka:** když text obsahoval písmena a po vyhození tagů nezbylo žádné,
vrátí se nezměněný. V koncové části (`-Trailing`) pojistka neplatí — tam je prázdný
výsledek správná odpověď, protože za `SxxEyy` bývá jen technický balast.

## Druhá oprava: rok se nebere z rozlišení

`Orel Eddie _ Eddie the Eagle (2016) Kom CZ 1920x800p.avi` dostal rok **1920**,
protože regulární výraz bral poslední čtyřčíslí a `1920x800p` mu vyhovovalo.
Doplněn zápor `(?![xX]\d)`.

## Ověření

Skript byl spuštěn pod PowerShellem 7.6.6 na Linuxu (funkce se načtou přes
`-LoadOnly`, samotné parsování názvů je čistá práce s řetězci).

**Porovnání staré a nové verze na 580 skutečných názvech** z `DATA II/Videa`,
`Serialy` a `Top Gear`:

| | |
|---|---|
| Názvů celkem | 580 |
| Změněný výsledek | **2** |
| Beze změny | 578 |

Obě změny jsou opravy:

- `The.Martian.Extended.Cut.2015…` → bylo `The Martian Cut (2015)`, nyní `The Martian Extended Cut (2015)`
- `Orel Eddie … 1920x800p.avi` → bylo `… 2016 Kom (1920)`, nyní `Orel Eddie Eddie the Eagle (2016)`

### Mezikrok, který se neosvědčil

První verze opravy dávala do dvojznačné skupiny i `cz`, `sk`, `dab` a pojistku
uplatňovala všude. Na skutečných datech to udělalo **33 změn, z nichž většina byla
zhoršení** — `Californication.S05E05.HDTV.XviD.CZ-dabing` skončilo jako
`Californication - S05E05 - HDTV XviD CZ-dabing` místo `Californication - S05E05`,
protože pojistka vrátila původní text tam, kde bylo prázdno správně. Proto ten
dvojí ústupek výše.

## Co zůstává otevřené

Ostatní nálezy z `REVIZE-2026-09-23.md`: ověření přesunu přes svazky jen podle
velikosti, `Get-UniqueTarget` po 99 pokusech, výběr podle největšího souboru
u „stejný díl, jiná data".
