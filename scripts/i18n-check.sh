#!/bin/sh
# Every string our LuCI pages pass to _() must have an English entry in
# i18n/be7000.en.po and a Chinese one in i18n/be7000.zh-cn.po, every entry
# there must still be used, and the committed .lmo files must be built from
# those .po files.
#   scripts/i18n-check.sh [path/to/po2lmo]
cd "$(dirname "$0")/.." || exit 1
PO=i18n/be7000.en.po
LMO=overlay-files/usr/lib/lua/luci/i18n/be7000.en.lmo
fail=0

python3 - "$PO" <<'PY' || fail=1
import re, sys, glob
po = open(sys.argv[1], encoding='utf-8').read()
have = set(bytes(m, 'utf-8').decode('unicode_escape').encode('latin-1').decode('utf-8')
           for m in re.findall(r'^msgid "(.*)"$', po, re.M)) - {''}
pats = ('overlay-files/www/**/*.js', 'awg-feed/*/htdocs/**/*.js', 'awg-proto-feed/*/htdocs/**/*.js',
        'luci-theme-miwrt/**/*.js', 'luci-theme-miwrt/**/*.ut',
        'overlay-files/usr/share/luci/menu.d/*.json', 'awg-feed/*/root/usr/share/luci/menu.d/*.json')
files = sorted(set(f for pat in pats for f in glob.glob(pat, recursive=True)))
used, missing = set(), []
for f in files:
    s = open(f, encoding='utf-8').read()
    if f.endswith('.json'):
        found = re.findall(r'"title":\s*"([^"]*)"', s)
    else:
        found = [m.group(2) for m in re.finditer(r"_\((['\"])((?:\\.|(?!\1).)*)\1", s)]
    for v in found:
        v = v.replace("\\'", "'").replace('\\"', '"')
        used.add(v)
        # LuCI's own files we only fork are not ours to translate
        if re.search('[А-Яа-яЁё]', v) and v not in have and not f.endswith('view/network/wireless.js'):
            missing.append((f, v))
for f, v in missing:
    print('missing: %s: %s' % (f, v))
unused = sorted(have - used)
for v in unused:
    print('not used anywhere: %s' % v)
sys.exit(1 if missing or unused else 0)
PY

# The Chinese catalogue must carry every msgid of the English one.
python3 - "$PO" i18n/be7000.zh-cn.po <<'PY' || fail=1
import re, sys
ids = lambda p: set(re.findall(r'^msgid "(.*)"$', open(p, encoding='utf-8').read(), re.M))
miss = ids(sys.argv[1]) - ids(sys.argv[2])
for m in sorted(miss):
    print('missing in zh-cn: %s' % m)
sys.exit(1 if miss else 0)
PY

if [ -n "${1:-}" ] && [ -x "$1" ]; then
	for l in en zh-cn; do
		tmp=$(mktemp)
		"$1" i18n/be7000.$l.po "$tmp" && cmp -s "$tmp" overlay-files/usr/lib/lua/luci/i18n/be7000.$l.lmo ||
			{ echo "be7000.$l.lmo is not built from be7000.$l.po"; fail=1; }
		rm -f "$tmp"
	done
fi

[ $fail = 0 ] && echo "i18n ok"
exit $fail
