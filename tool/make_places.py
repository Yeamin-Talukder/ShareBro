"""Builds assets/geo/places.tsv.gz and assets/geo/countries.tsv, the offline
place names used for search ("Kuakata") and to name places on the map.

Data: GeoNames (https://www.geonames.org, CC BY 4.0).
  - cities500: every town and city in the world with 500+ people.
  - FULL_DETAIL countries: every village, beach, hill, park, lake and landmark
    (Bangladesh by default, which is where places like Kuakata live).

Usage: python tool/make_places.py <folder with cities500.zip, countryInfo.txt
and one <CC>.zip per FULL_DETAIL country>

Each row: name, lat*1e4, lng*1e4, country code, population, kind (P town,
T beach/hill, L park/area, S spot, H water), then other spellings (|-joined).
"""
import gzip, pathlib, re, sys, zipfile

FULL_DETAIL = ['BD']
KINDS = set('PTLSH')
MAX_ALT = 3

src = pathlib.Path(sys.argv[1])
out = pathlib.Path(__file__).resolve().parent.parent / 'assets' / 'geo'
out.mkdir(parents=True, exist_ok=True)

latin = re.compile(r"^[A-Za-z0-9 '’.\-()&,À-ɏ]+$")


rows, seen = [], set()


def take(f, alts):
    gid = f[0]
    if gid in seen or f[6] not in KINDS:
        return
    seen.add(gid)
    # Shown in the plain spelling ("Kuakata", not "Kuākāta"); the original
    # stays as another spelling when it's Latin.
    name = (f[2] or f[1]).strip()
    spellings = []
    for a in [f[1]] + alts:
        a = a.strip()
        if a and a.lower() != name.lower() and latin.match(a) and a.lower() not in (x.lower() for x in spellings):
            spellings.append(a)
    rows.append('\t'.join([
        name.replace('\t', ' '),
        str(round(float(f[4]) * 1e4)), str(round(float(f[5]) * 1e4)),
        f[8], str(int(f[14] or 0)), f[6],
        '|'.join(spellings[: MAX_ALT + 1]),
    ]))


with zipfile.ZipFile(src / 'cities500.zip') as z:
    for line in z.read('cities500.txt').decode('utf-8').splitlines():
        take(line.split('\t'), [])
world = len(rows)
for cc in FULL_DETAIL:
    with zipfile.ZipFile(src / f'{cc}.zip') as z:
        for line in z.read(f'{cc}.txt').decode('utf-8').splitlines():
            f = line.split('\t')
            take(f, [a for a in f[3].split(',') if a][:12])

with gzip.open(out / 'places.tsv.gz', 'wt', encoding='utf-8', compresslevel=9) as g:
    g.write('\n'.join(rows))

countries = []
for line in (src / 'countryInfo.txt').read_text(encoding='utf-8').splitlines():
    if line.startswith('#') or not line.strip():
        continue
    f = line.split('\t')
    countries.append(f'{f[0]}\t{f[4]}')
(out / 'countries.tsv').write_text('\n'.join(countries), encoding='utf-8')

size = (out / 'places.tsv.gz').stat().st_size
print(f'{world} towns worldwide + {len(rows) - world} detailed ({",".join(FULL_DETAIL)}) = {len(rows)} places, '
      f'{size / 1e6:.1f} MB; {len(countries)} countries')
