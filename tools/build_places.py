#!/usr/bin/env python3
"""Builds RawDrop/Places/places.tsv from a GeoNames dump.

RawDrop names the place a photo was taken without asking a server: it ships
every town over 15,000 people and looks up the nearest one on the phone.

    curl -O https://download.geonames.org/export/dump/cities15000.zip
    curl -O https://download.geonames.org/export/dump/admin1CodesASCII.txt
    curl -O https://download.geonames.org/export/dump/countryInfo.txt
    unzip cities15000.zip
    python3 tools/build_places.py <dir with those files> RawDrop/Places/places.tsv

Output is one file, three kinds of line, tab separated:

    C  <country code>  <country name>
    A  <country.admin1>  <admin1 name>
    P  <name>  <lat>  <lon>  <population>  <country.admin1>

GeoNames data is CC BY 4.0 (https://www.geonames.org). The About sheet credits it.
"""

import csv
import os
import sys


def main(src: str, out: str) -> None:
    countries = {}
    with open(os.path.join(src, "countryInfo.txt"), encoding="utf-8") as f:
        for line in f:
            if line.startswith("#"):
                continue
            cols = line.rstrip("\n").split("\t")
            if len(cols) > 4:
                countries[cols[0]] = cols[4]

    admin1 = {}
    with open(os.path.join(src, "admin1CodesASCII.txt"), encoding="utf-8") as f:
        for line in f:
            cols = line.rstrip("\n").split("\t")
            if len(cols) > 1:
                admin1[cols[0]] = cols[1]

    places = []
    used_admin = set()
    used_country = set()
    with open(os.path.join(src, "cities15000.txt"), encoding="utf-8") as f:
        for cols in csv.reader(f, delimiter="\t", quoting=csv.QUOTE_NONE):
            name, lat, lon, feature, cc, a1, pop = cols[1], cols[4], cols[5], cols[7], cols[8], cols[10], cols[14]
            # Historical and abandoned places have no business naming a photo.
            if feature in ("PPLH", "PPLQ", "PPLW"):
                continue
            key = f"{cc}.{a1}"
            places.append((name, f"{float(lat):.3f}", f"{float(lon):.3f}", pop or "0", key))
            used_country.add(cc)
            if key in admin1:
                used_admin.add(key)

    with open(out, "w", encoding="utf-8", newline="\n") as f:
        for cc in sorted(used_country):
            if cc in countries:
                f.write(f"C\t{cc}\t{countries[cc]}\n")
        for key in sorted(used_admin):
            f.write(f"A\t{key}\t{admin1[key]}\n")
        for p in places:
            f.write("P\t" + "\t".join(p) + "\n")

    print(f"{len(places)} places, {len(used_admin)} regions, {len(used_country)} countries -> {out}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
