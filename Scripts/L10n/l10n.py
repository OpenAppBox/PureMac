#!/usr/bin/env python3
"""Translation export/import for PureMac's three string catalogs.

  l10n.py export <out.tsv>             numbered source strings: a<n> app, k<n> engine, p<n> Info.plist
  l10n.py import <lang> <file.json>     writes translations from {"a12": "…", "k3": {"one": "…", "other": "…"}}
  l10n.py check <lang>                  completeness, format specifiers and plural categories

Ids are positions in the sorted keys of each catalog, so export and import must use the same
catalog contents. A value may be a plain string or, for a string with exactly one %lld, a dict of
CLDR plural categories; that becomes a plural variation for that language only.
"""
import json, re, sys, os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CATALOGS = {
    'a': 'PureMac/Resources/Localizable.xcstrings',
    'k': 'Packages/PureMacKit/Sources/PureMacKit/Resources/Localizable.xcstrings',
    'p': 'PureMac/Resources/InfoPlist.xcstrings',
}
# CLDR plural categories Apple uses for integers.
PLURALS = {
    'ar': ['zero', 'one', 'two', 'few', 'many', 'other'],
    'ru': ['one', 'few', 'many', 'other'], 'pl': ['one', 'few', 'many', 'other'],
    'fr': ['one', 'many', 'other'], 'pt-BR': ['one', 'many', 'other'], 'it': ['one', 'many', 'other'],
    'de': ['one', 'other'], 'nl': ['one', 'other'], 'sv': ['one', 'other'], 'nb': ['one', 'other'],
    'da': ['one', 'other'], 'fi': ['one', 'other'], 'tr': ['one', 'other'], 'en': ['one', 'other'],
    'ja': ['other'], 'ko': ['other'], 'zh-Hans': ['other'], 'zh-Hant': ['other'],
    'es': ['one', 'many', 'other'], 'hi': ['one', 'other'],
    'vi': ['other'], 'th': ['other'], 'id': ['other'],
}
SPEC = re.compile(r'%(?:(\d+)\$)?(lld|ld|d|@|f)')

def xcode_json(o, ind=0):
    """JSON the way Xcode writes .xcstrings (" : " separators, empty objects on two lines), so a
    catalog written here and one saved by Xcode differ only in what actually changed."""
    pad = '  ' * ind
    if isinstance(o, dict):
        if not o: return '{\n\n' + pad + '}'
        return '{\n' + ',\n'.join(pad + '  ' + json.dumps(k, ensure_ascii=False) + ' : ' + xcode_json(v, ind + 1) for k, v in o.items()) + '\n' + pad + '}'
    if isinstance(o, list):
        if not o: return '[\n\n' + pad + ']'
        return '[\n' + ',\n'.join(pad + '  ' + xcode_json(v, ind + 1) for v in o) + '\n' + pad + ']'
    return json.dumps(o, ensure_ascii=False)

def load(prefix):
    path = os.path.join(ROOT, CATALOGS[prefix])
    return path, json.load(open(path))

def keys(doc):
    return sorted(k for k in doc['strings'] if k.strip())

def specs(s):
    # Argument types in argument order: positional specifiers (%2$@) are placed
    # at their index, so a translation may reorder arguments only that way.
    found = SPEC.findall(s)
    if any(pos for pos, _ in found):
        return [t for _, t in sorted((int(pos or 0), t) for pos, t in found)]
    return [t for _, t in found]

def export(out):
    with open(out, 'w') as f:
        for prefix in CATALOGS:
            _, doc = load(prefix)
            for i, k in enumerate(keys(doc)):
                comment = doc['strings'][k].get('comment', '')
                f.write(f'{prefix}{i}\t{k}' + (f'\t# {comment}' if comment and prefix != 'p' else '') + '\n')
    print('exported to', out)

def values_of(loc):
    """Every text of one localization: the plain value or each plural form."""
    if not loc: return []
    if 'stringUnit' in loc: return [loc['stringUnit']['value']]
    plural = loc.get('variations', {}).get('plural', {})
    return [v['stringUnit']['value'] for v in plural.values()]

def do_import(lang, file):
    data = json.load(open(file))
    for prefix in CATALOGS:
        path, doc = load(prefix)
        ks = keys(doc)
        for id_, value in data.items():
            if not id_.startswith(prefix) or not id_[1:].isdigit(): continue
            key = ks[int(id_[1:])]
            entry = doc['strings'][key]
            locs = dict(entry.get('localizations', {}))
            if isinstance(value, dict):
                locs[lang] = {'variations': {'plural': {c: {'stringUnit': {'state': 'translated', 'value': value[c]}} for c in sorted(value)}}}
            else:
                locs[lang] = {'stringUnit': {'state': 'translated', 'value': value}}
            entry['localizations'] = {l: locs[l] for l in sorted(locs)}   # Xcode keeps languages sorted
        open(path, 'w').write(xcode_json(doc))
    print('imported', len(data), 'entries for', lang)

def check(lang):
    problems = 0
    for prefix in CATALOGS:
        _, doc = load(prefix)
        for i, k in enumerate(keys(doc)):
            loc = doc['strings'][k].get('localizations', {}).get(lang)
            texts = values_of(loc)
            if not texts:
                print(f'  MISSING {prefix}{i}: {k}'); problems += 1; continue
            for t in texts:
                if specs(t) != specs(k):
                    print(f'  SPECIFIERS {prefix}{i}: {k!r} -> {t!r}'); problems += 1
            plural = (loc or {}).get('variations', {}).get('plural')
            if plural is not None:
                if specs(k) != ['lld']:
                    print(f'  PLURAL ON NON-COUNT {prefix}{i}: {k!r}'); problems += 1
                want = set(PLURALS.get(lang, ['other']))
                if set(plural) != want:
                    print(f'  PLURAL CATEGORIES {prefix}{i}: {sorted(plural)} want {sorted(want)}'); problems += 1
    print(lang, 'OK' if problems == 0 else f'{problems} problem(s)')
    return problems

if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'export': export(sys.argv[2])
    elif cmd == 'import': do_import(sys.argv[2], sys.argv[3])
    elif cmd == 'check': sys.exit(1 if check(sys.argv[2]) else 0)
