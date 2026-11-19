#!/bin/sh
# The setup assistant's choice of a Wi-Fi channel
# (overlay-files/usr/share/ucode/miwrt/channels.uc): which channels a radio
# may be offered, and which one is suggested after a scan.
#
# Only the parts that work from data given to them are checked here: the
# channel blocks, the reading of the kernel's regulatory database, the list
# of channels on offer and their order. Nothing is scanned and no radio is
# asked anything.
#
# It needs ucode with its fs, uci and ubus modules, so it runs on a router or
# in an OpenWrt root filesystem:
#
#   ssh root@<router> 'mkdir -p /tmp/t/miwrt'
#   scp -O overlay-files/usr/share/ucode/miwrt/channels.uc root@<router>:/tmp/t/miwrt/
#   scp -O scripts/test-channels.sh root@<router>:/tmp/t/
#   ssh root@<router> 'sh /tmp/t/test-channels.sh /tmp/t'
#
# The argument is the directory that holds miwrt/channels.uc; without one it
# is the copy in this repository, and failing that the router's own.

set -u

if ! command -v ucode >/dev/null 2>&1; then
	echo "channel tests: SKIPPED, no ucode on this machine (run it on a router, see the head of the script)"
	exit 0
fi

HERE=$(cd "$(dirname "$0")" && pwd)
LIB=${1:-}
[ -n "$LIB" ] || { [ -f "$HERE/../overlay-files/usr/share/ucode/miwrt/channels.uc" ] && LIB="$HERE/../overlay-files/usr/share/ucode"; }
[ -n "$LIB" ] || LIB=/usr/share/ucode
[ -f "$LIB/miwrt/channels.uc" ] || { echo "FAIL: no miwrt/channels.uc in $LIB" >&2; exit 1; }

T=$(mktemp /tmp/test-channels.XXXXXX) || exit 1
trap 'rm -f "$T"' EXIT INT TERM

cat > "$T" <<'EOF'
'use strict';
import * as ch from 'miwrt.channels';
import { readfile } from 'fs';

let failed = 0, done = 0;
function same(got, want, what) {
	done++;
	if (sprintf('%J', got) == sprintf('%J', want)) return;
	failed++;
	printf('FAIL: %s\n      got  %J\n      want %J\n', what, got, want);
}
let chans = l => map(l, c => c.channel);

// ---- widths and blocks ----
same(ch.width_of('VHT80'), 80, 'width of VHT80');
same(ch.width_of('EHT160'), 160, 'width of EHT160');
same(ch.width_of('HE20'), 20, 'width of HE20');
same(ch.width_of(null), null, 'width of nothing');
same(ch.block_of(44, 80), [ 36, 40, 44, 48 ], '80 MHz block of 44');
same(ch.block_of(36, 160), [ 36, 40, 44, 48, 52, 56, 60, 64 ], '160 MHz block of 36');
same(ch.block_of(157, 80), [ 149, 153, 157, 161 ], '80 MHz block of 157');
same(ch.block_of(165, 20), [ 165 ], '20 MHz block of 165');
same(ch.block_of(104, 40), [ 100, 104 ], '40 MHz block of 104');
same(ch.block_of(132, 160), null, 'no 160 MHz block holds 132');
same(ch.block_of(38, 80), null, '38 is not a 20 MHz channel');
same(ch.block_of('44', 80), null, 'a channel given as text');

// ---- the driver's list ----
function freqs(o) {
	let f = {};
	for (let c in [ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 ]) f['' + (2407 + 5 * c)] = { freq: 2407 + 5 * c, max_tx_power: 2000 };
	for (let c = 36; c <= 177; c += 4) {
		if ((c > 64 && c < 100) || (c > 144 && c < 149)) continue;
		if (c == 148) c = 149;
		f['' + (5000 + 5 * c)] = { freq: 5000 + 5 * c, max_tx_power: 2300, radar: c >= 52 && c <= 144 };
	}
	for (let c = 149; c <= 177; c += 4) f['' + (5000 + 5 * c)] = { freq: 5000 + 5 * c, max_tx_power: 2300 };
	for (let k, v in (o ?? {})) f[k] = v;
	return f;
}
let drv = (o) => ({ band: '5g', width: 80, current: 44, freqs: freqs(), mode: 'driver', rules: null, ...o });

same(chans(ch.candidates(drv({}))), [ 36, 40, 44, 48, 149, 153, 157, 161 ], 'driver, 80 MHz: every block without radar');
same(chans(ch.candidates(drv({ current: 'auto' }))), [ 36, 40, 44, 48, 149, 153, 157, 161 ], 'driver, 80 MHz, channel chosen by the radio');
same(chans(ch.candidates(drv({ mode: 'home' }))), [ 36, 40, 44, 48 ], 'home: only the block the radio is on');
same(chans(ch.candidates(drv({ mode: 'home', current: 'auto' }))), [], 'home, no channel set: nothing to offer');
same(chans(ch.candidates(drv({ current: 100 }))), [ 36, 40, 44, 48, 149, 153, 157, 161 ], 'the radio is on a radar-only block: it is not offered');
same(chans(ch.candidates(drv({ freqs: freqs({ '5765': { freq: 5765, disabled: true } }) }))), [ 36, 40, 44, 48 ], 'one channel of a block switched off: the block goes');
same(chans(ch.candidates(drv({ freqs: freqs({ '5745': { freq: 5745, max_tx_power: 2300, no_80mhz: true } }) }))), [ 36, 40, 44, 48 ], 'a channel not allowed 80 MHz');
same(chans(ch.candidates(drv({ freqs: freqs({ '5745': { freq: 5745, no_ir: true } }) }))), [ 36, 40, 44, 48 ], 'a channel the router may not start on');
let quiet = freqs();
for (let c = 149; c <= 177; c += 4) quiet['' + (5000 + 5 * c)] = { freq: 5000 + 5 * c, max_tx_power: 1400 };
same(chans(ch.candidates(drv({ freqs: quiet }))), [ 36, 40, 44, 48 ], 'a block allowed far less power is left out');
same(chans(ch.candidates(drv({ freqs: quiet, current: 149 }))), [ 36, 40, 44, 48, 149, 153, 157, 161 ], 'except the one the radio is on');
let small = freqs();
for (let c = 165; c <= 177; c += 4) delete small['' + (5000 + 5 * c)];
same(chans(ch.candidates(drv({ freqs: small }))), [ 36, 40, 44, 48, 149, 153, 157, 161 ], 'channels the hardware does not have');
same(chans(ch.candidates(drv({ freqs: small, width: 160 }))), [ 36, 40, 44, 48 ], '160 MHz on 36 to 64: the channels without radar, because the radio is there');
same(chans(ch.candidates(drv({ freqs: small, width: 160, current: 'auto' }))), [], '160 MHz, not on that block: a block with radar is not offered');
same(chans(ch.candidates(drv({ width: 160, current: 'auto' }))), [], '160 MHz: the upper block reaches above 165');
same(chans(ch.candidates(drv({ width: 160, current: 153 }))), [ 149, 153, 157, 161, 165, 169, 173, 177 ], '160 MHz: unless the radio is on it');
same(chans(ch.candidates(drv({ width: 40, freqs: freqs({ '5745': { freq: 5745, max_tx_power: 2300, no_ht40_minus: true, no_ht40_plus: true } }) }))), [ 36, 40, 44, 48, 157, 161 ], '40 MHz: a channel allowed 20 MHz only takes its pair with it');
same(chans(ch.candidates(drv({ width: 20, freqs: freqs({ '5745': { freq: 5745, max_tx_power: 2300, no_ht40_minus: true, no_ht40_plus: true } }) }))), [ 36, 40, 44, 48, 149, 153, 157, 161, 165 ], '20 MHz: that channel is fine');
same(chans(ch.candidates(drv({ width: 40, freqs: freqs({ '5180': { freq: 5180, max_tx_power: 2300, no_ht40_minus: true } }) }))), [ 36, 40, 44, 48, 149, 153, 157, 161 ], '40 MHz: the lower channel of a pair is marked as not being the upper one, as drivers do');
same(chans(ch.candidates(drv({ width: 20 }))), [ 36, 40, 44, 48, 149, 153, 157, 161, 165 ], '20 MHz: up to 165');
same(chans(ch.candidates(drv({ width: 40 }))), [ 36, 40, 44, 48, 149, 153, 157, 161 ], '40 MHz: 165 would need 169');
same(chans(ch.candidates(drv({ current: 169 }))), [ 36, 40, 44, 48, 149, 153, 157, 161, 165, 169, 173, 177 ], 'above 165 only when the radio is there already');
same(chans(ch.candidates(drv({ width: 320 }))), [], 'a width this code does not know');
same(ch.candidates(drv({}))[2], { channel: 44, first: 36, last: 48, power: 23 }, 'what is said about a channel');

let two = (o) => ({ band: '2g', width: 20, current: 'auto', freqs: freqs(), mode: 'driver', rules: null, ...o });
same(chans(ch.candidates(two({}))), [ 1, 6, 11 ], '2.4 GHz: 1, 6 and 11');
same(chans(ch.candidates(two({ freqs: freqs({ '2462': { freq: 2462, disabled: true } }) }))), [ 1, 6 ], '2.4 GHz with 11 switched off');
same(chans(ch.candidates(two({ freqs: null }))), [], 'no list from the driver');

// ---- a country's rules from the regulatory database ----
let rules = [
	{ start: 2400000, end: 2483500, bw: 40000, eirp: 2000, dfs: false, no_ir: false, auto_bw: false },
	{ start: 5150000, end: 5250000, bw: 80000, eirp: 2300, dfs: false, no_ir: false, auto_bw: true },
	{ start: 5250000, end: 5350000, bw: 80000, eirp: 2000, dfs: true, no_ir: false, auto_bw: true },
	{ start: 5470000, end: 5725000, bw: 160000, eirp: 2600, dfs: true, no_ir: false, auto_bw: false },
	{ start: 5725000, end: 5875000, bw: 80000, eirp: 1398, dfs: false, no_ir: false, auto_bw: false }
];
let reg = (o) => ({ band: '5g', width: 80, current: 44, freqs: freqs(), mode: 'regdb', rules, ...o });
same(chans(ch.candidates(reg({}))), [ 36, 40, 44, 48 ], 'database: the weak upper block is left out, radar blocks too');
same(chans(ch.candidates(reg({ current: 157 }))), [ 36, 40, 44, 48, 149, 153, 157, 161 ], 'database: the weak block stays when the radio is on it');
same(chans(ch.candidates(reg({ width: 160, current: 36 }))), [ 36, 40, 44, 48 ], 'database: two rules that touch make one 160 MHz range');
let loud = map(rules, r => ({ ...r }));
loud[4].eirp = 2300;
same(chans(ch.candidates(reg({ rules: loud }))), [ 36, 40, 44, 48, 149, 153, 157, 161 ], 'database: an upper block with full power, and one the rules end inside');
let closed = map(rules, r => ({ ...r }));
closed[1].no_ir = true;
same(chans(ch.candidates(reg({ rules: closed }))), [ 149, 153, 157, 161 ], 'database: a range the router may not start on');
same(chans(ch.candidates(two({ mode: 'regdb', rules }))), [ 1, 6, 11 ], 'database: 2.4 GHz');
same(chans(ch.candidates(two({ mode: 'regdb', rules: [ { ...rules[0], end: 2472000 } ] }))), [ 1, 6, 11 ], 'database: 2.4 GHz that ends at the edge of channel 11');
same(chans(ch.candidates(two({ mode: 'regdb', rules: [ { ...rules[0], end: 2470000 } ] }))), [ 1, 6 ], 'database: 2.4 GHz that ends inside channel 11');

// a database with one country, built the way the file is laid out
let b16 = n => chr((n >> 8) & 255, n & 255), b32 = n => b16((n >> 16) & 65535) + b16(n & 65535);
let rule = (flags, eirp, start, end, bw) => chr(16, flags) + b16(eirp) + b32(start) + b32(end) + b32(bw);
let db = 'RGDB' + b32(20) + 'ZZ' + b16(4) + chr(0, 0, 0, 0)       // header, one country at byte 16, the end mark
	+ chr(3, 2, 0, 0) + b16(6) + b16(10)                         // its collection (three bytes long, as in the real file): two rules, at bytes 24 and 40
	+ rule(0, 2000, 2400000, 2483500, 40000)
	+ rule(4 | 16, 2300, 5250000, 5350000, 80000);
same(ch.rules_for(db, 'ZZ'), [
	{ start: 2400000, end: 2483500, bw: 40000, eirp: 2000, dfs: false, no_ir: false, auto_bw: false },
	{ start: 5250000, end: 5350000, bw: 80000, eirp: 2300, dfs: true, no_ir: false, auto_bw: true }
], 'a country read from the database');
same(ch.rules_for(db, 'QQ'), [], 'a country the database does not list');
same(ch.rules_for(db, null), [], 'no country');
same(ch.rules_for('RGDB' + b32(19) + substr(db, 8), 'ZZ'), null, 'a database of another version');
same(ch.rules_for('nonsense', 'ZZ'), null, 'not a database');
same(ch.rules_for(null, 'ZZ'), null, 'no file');
same(ch.rules_for(substr(db, 0, 30), 'ZZ'), null, 'a database cut short');
let real = readfile('/lib/firmware/regulatory.db');
if (real) {
	let us = ch.rules_for(real, 'US');
	same(type(us) == 'array' && length(filter(us, r => r.start <= 2402000 && r.end >= 2422000)) == 1, true, 'this machine\'s database: the US rule for channel 1');
}

// ---- how much of the band a network takes ----
same(ch.occupied('2g', { channel: 1, mhz: 2412 }), [ 2402, 2422 ], '2.4 GHz, 20 MHz');
same(ch.occupied('2g', { channel: 1, ht_operation: { secondary_channel_offset: 'above' } }), [ 2402, 2442 ], '2.4 GHz, 40 MHz upwards');
same(ch.occupied('2g', { channel: 11, ht_operation: { secondary_channel_offset: 'below' } }), [ 2432, 2472 ], '2.4 GHz, 40 MHz downwards');
same(ch.occupied('5g', { channel: 149 }), [ 5735, 5755 ], '5 GHz, 20 MHz');
same(ch.occupied('5g', { channel: 36, vht_operation: { channel_width: 80, center_freq_1: 42 } }), [ 5170, 5250 ], '5 GHz, 80 MHz');
same(ch.occupied('5g', { channel: 36, vht_operation: { channel_width: 80, center_freq_1: 42, center_freq_2: 50 } }), [ 5170, 5330 ], '5 GHz, 160 MHz as announced today');
same(ch.occupied('5g', { channel: 36, vht_operation: { channel_width: 160, center_freq_1: 50 } }), [ 5170, 5330 ], '5 GHz, 160 MHz as announced before');
same(ch.occupied('5g', { channel: 36, ht_operation: { secondary_channel_offset: 'above' }, vht_operation: { channel_width: 40, center_freq_1: 0 } }), [ 5170, 5210 ], '5 GHz, 40 MHz');

// ---- the order after a scan ----
let c2 = ch.candidates(two({})), c5 = ch.candidates(drv({ freqs: small }));
let net = (channel, signal, more) => ({ channel, signal, ...(more ?? {}) });
let r = ch.rank('2g', 20, c2, 'auto', [ net(1, -40), net(1, -55), net(6, -70), net(6, -82), net(11, -85) ]);
same(r.suggested, 11, '2.4 GHz: the channel with the least on it');
same(map(r.candidates, c => [ c.channel, c.networks, c.strongest ]), [ [ 1, 2, -40 ], [ 6, 2, -70 ], [ 11, 1, -85 ] ], '2.4 GHz: what is said about each channel');
same(ch.rank('2g', 20, c2, 'auto', []).suggested, 1, '2.4 GHz, nobody around: the lowest');
same(ch.rank('2g', 20, c2, 6, []).suggested, 6, '2.4 GHz, nobody around: the channel the radio is on');
same(ch.rank('2g', 20, c2, 6, [ net(6, -86) ]).suggested, 6, '2.4 GHz: a faint neighbour is no reason to move');
same(ch.rank('2g', 20, c2, 6, [ net(6, -50), net(6, -60) ]).suggested, 1, '2.4 GHz: two loud ones are');
same(ch.rank('2g', 20, c2, 'auto', [ net(3, -50) ]).suggested, 11, '2.4 GHz: a network between 1 and 6 counts against both');
same(ch.rank('2g', 20, c2, 6, [ net(3, -50) ]).suggested, 6, '2.4 GHz: but a small overlap does not move the radio');
same(ch.rank('2g', 20, c2, 'auto', [ net(1, null), net(1, -50) ]).candidates[0].networks, 1, 'an entry without a signal is not counted');
same(ch.rank('2g', 20, [], 'auto', [ net(1, -50) ]), { candidates: [], suggested: null }, 'nothing to choose from');

r = ch.rank('5g', 80, c5, 36, []);
same(chans(r.candidates), [ 44, 149 ], '5 GHz: one choice per block, the channel Apple devices meet on');
same(r.suggested, 44, '5 GHz, nobody around: 44');
same(ch.rank('5g', 80, c5, 149, []).suggested, 149, '5 GHz, nobody around, radio on 149: it stays');
let wide = { vht_operation: { channel_width: 80, center_freq_1: 42 } };
r = ch.rank('5g', 80, c5, 44, [ net(36, -50, wide), net(40, -60, wide) ]);
same(r.suggested, 149, '5 GHz: two loud networks on the lower block');
same([ r.candidates[0].networks, r.candidates[0].strongest, r.candidates[1].networks ], [ 2, -50, 0 ], '5 GHz: what is said about each block');
same(ch.rank('5g', 80, c5, 44, [ net(36, -87, wide) ]).suggested, 44, '5 GHz: a faint neighbour is no reason to move');
r = ch.rank('5g', 80, c5, 36, [ net(44, -45), net(44, -50), net(149, -45, { vht_operation: { channel_width: 80, center_freq_1: 155 } }), net(149, -50), net(149, -55) ]);
same(chans(r.candidates), [ 36, 153 ], '5 GHz: inside a block, away from the 20 MHz others announce themselves on');
same(r.suggested, 36, '5 GHz: the block with less on it');

same(ch.allowed([ { id: 'radio0', candidates: c2 } ], 'radio0', 6), true, 'a channel that was offered');
same(ch.allowed([ { id: 'radio0', candidates: c2 } ], 'radio0', 3), false, 'a channel that was not');
same(ch.allowed([ { id: 'radio0', candidates: c2 } ], 'radio0', '6'), false, 'a channel given as text');
same(ch.allowed([ { id: 'radio0', candidates: c2 } ], 'radio1', 6), false, 'a radio that is not there');

printf('channel tests: %d checks, %d failed\n', done, failed);
exit(failed ? 1 : 0);
EOF

ucode -L "$LIB" "$T"
