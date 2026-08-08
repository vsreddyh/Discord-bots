#!/usr/bin/env python3
"""Given a saved MediaWiki wikitext JSON file (from action=parse&prop=wikitext),
print infobox parameter lines matching a regex filter.

Usage:
    python3 parse_wikitext_fields.py page.json 'health|armor|durab|difficulty|faction'
"""
import json
import re
import sys

if len(sys.argv) < 3:
    sys.exit("usage: parse_wikitext_fields.py <page.json> '<filter_regex>'")

path, pattern = sys.argv[1], sys.argv[2]
d = json.load(open(path))
# Guard: search API shape differs from parse API shape.
if "parse" in d and "wikitext" in d["parse"]:
    text = d["parse"]["wikitext"]["*"]
else:
    sys.exit("file does not contain parse.wikitext (run action=parse&prop=wikitext)")

rx = re.compile(pattern, re.IGNORECASE)
for line in text.splitlines():
    if "=" in line and rx.search(line):
        print(line.strip()[:160])