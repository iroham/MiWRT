// MiWRT: which Wi-Fi channel suits the place the router stands in. Used by the setup assistant
// (miwrt/setup.uc): the channels a radio may use in a given country, and their order after a scan of
// the networks around.
//
// A channel is only ever offered when something that knows has said it may be used:
//   - the country asked about is the one the radio runs with now: the driver's own channel list;
//   - another country, and the driver follows the kernel's regulatory database (mt76 on the
//     Redmi AC2100): that database, read from /lib/firmware/regulatory.db;
//   - another country, and the driver has rules of its own in its firmware (ath12k on the BE7000,
//     whose rules differ from the database): nothing is known until the country is set, so only the
//     block the radio is on now is offered.
// On 5 GHz a block that needs radar checks is not offered, and neither is one that reaches above
// channel 165, except the block the radio is on already.
// The width is never changed here.
'use strict';

import { readfile, writefile, rename, mkdir } from 'fs';
import { cursor } from 'uci';
import { connect } from 'ubus';

const RUN = '/tmp/miwrt';
const JOB = RUN + '/wifi-scan.json';
const REGDB = '/lib/firmware/regulatory.db';
// the channels Apple devices meet on for AirDrop, AirPlay and Handoff: with the network on one of
// them, a Mac or an iPhone does not have to leave the router's channel to listen there
const APPLE = [ 44, 149 ];

function mhz_of(band, ch) {
	return band == '2g' ? (ch == 14 ? 2484 : 2407 + 5 * ch) : 5000 + 5 * ch;
}

function absdiff(a, b) {
	return a > b ? a - b : b - a;
}

export function width_of(htmode) {
	let m = match(htmode ?? '', /^[A-Z]+([0-9]+)$/);
	return m ? +m[1] : null;
};

/* The channels that make up the block a 5 GHz channel belongs to at a width, lowest first. */
export function block_of(ch, width) {
	if (type(ch) != 'int' || !(width in [ 20, 40, 80, 160 ])) return null;
	let base = ch >= 149 ? 149 : ch >= 100 ? 100 : 36;
	let last = ch >= 149 ? 177 : ch >= 100 ? 144 : 64;
	if (ch < base || ch > last || (ch - base) % 4) return null;
	let n = int(width / 20), i = int((ch - base) / 4);
	let first = base + 4 * (i - i % n), out = [];
	for (let k = 0; k < n; k++) push(out, first + 4 * k);
	return out[n - 1] <= last ? out : null;
};

// ---------- the kernel's regulatory database ----------

function be16(s, o) { return ord(s, o) * 256 + ord(s, o + 1); }
function be32(s, o) { return be16(s, o) * 65536 + be16(s, o + 2); }

/* The rules of one country from wireless-regdb's binary file, version 20 (net/wireless/reg.c):
   "RGDB", the version, then { two letters, pointer } per country up to an empty entry. A pointer times
   four is where a collection starts: { length, number of rules, ... } and, from the next even byte,
   one pointer per rule. A rule:
   { length, flags, highest power in 1/100 dBm, start, end and widest channel in kHz, ... }.
   Returns null when the file cannot be read as that, [] for a country it does not list. */
export function rules_for(db, cc) {
	if (type(db) != 'string' || length(db) < 12 || substr(db, 0, 4) != 'RGDB' || be32(db, 4) != 20) return null;
	if (type(cc) != 'string' || length(cc) != 2) return [];
	for (let o = 8; o + 4 <= length(db); o += 4) {
		if (ord(db, o) == 0 && ord(db, o + 1) == 0) break;
		if (substr(db, o, 2) != cc) continue;
		let c = be16(db, o + 2) * 4;
		if (c + 4 > length(db)) return null;
		let n = ord(db, c + 1), base = c + ((ord(db, c) + 1) & ~1), out = [];
		for (let i = 0; i < n; i++) {
			if (base + 2 * i + 2 > length(db)) return null;
			let r = be16(db, base + 2 * i) * 4;
			if (r + 16 > length(db)) return null;
			let f = ord(db, r + 1);
			push(out, { start: be32(db, r + 4), end: be32(db, r + 8), bw: be32(db, r + 12), eirp: be16(db, r + 2),
				dfs: !!(f & 4), no_ir: !!(f & 8), auto_bw: !!(f & 16) });
		}
		return out;
	}
	return [];
};

/* The widest channel a rule allows, as the kernel works it out: a rule marked AUTO-BW counts the
   rules that touch it on either side as one range. */
function rule_bw(rules, i) {
	let r = rules[i];
	if (!r.auto_bw) return r.bw;
	let start = r.start, end = r.end;
	for (let k = i - 1; k >= 0 && rules[k].end >= start; k--) start = rules[k].start;
	for (let k = i + 1; k < length(rules) && rules[k].start <= end; k++) end = rules[k].end;
	return end - start;
}

// ---------- which channels a radio may use ----------

/* One 20 MHz channel: null when it may not be used, else { radar, power (dBm), bw (widest, MHz) }.
   o.freqs is the driver's list, keyed by MHz; o.rules a country's rules when o.mode is 'regdb'. */
function chan_info(o, ch) {
	let mhz = mhz_of(o.band, ch), f = o.freqs?.['' + mhz];
	if (!f) return null;   // the hardware has no such channel
	if (o.mode == 'regdb') {
		for (let i = 0; i < length(o.rules); i++) {
			let r = o.rules[i];
			if (r.start > (mhz - 10) * 1000 || r.end < (mhz + 10) * 1000) continue;
			return r.no_ir ? null : { radar: r.dfs, power: r.eirp / 100, bw: rule_bw(o.rules, i) / 1000 };
		}
		return null;
	}
	if (f.disabled || f.no_ir) return null;
	// a channel that may be neither the lower nor the upper half of a pair is 20 MHz only
	let bw = (f.no_ht40_minus && f.no_ht40_plus) ? 20 : f.no_80mhz ? 40 : f.no_160mhz ? 80 : 160;
	return { radar: !!f.radar, power: (f.max_tx_power ?? 0) / 100, bw };
}

/* The channels to choose from: [ { channel, first, last, power } ], lowest first.
   o = { band: '2g'|'5g', width, current: 'auto' or a channel, freqs, mode: 'driver'|'regdb'|'home', rules } */
export function candidates(o) {
	let out = [];
	if (o.band == '2g') {
		// only 1, 6 and 11 do not overlap each other
		for (let ch in [ 1, 6, 11 ]) {
			let i = chan_info(o, ch);
			if (i) push(out, { channel: ch, first: ch, last: ch, power: i.power });
		}
		return out;
	}
	if (o.band != '5g' || !(o.width in [ 20, 40, 80, 160 ])) return out;
	let home = type(o.current) == 'int' ? block_of(o.current, o.width) : null;
	let blocks = [], seen = {};
	for (let ch = 36; ch <= 177; ch += 4) {
		if (ch > 64 && ch < 100) continue;
		if (ch > 144 && ch < 149) { ch = 145; continue; }
		let b = block_of(ch, o.width);
		if (!b || seen['' + b[0]]) continue;
		seen['' + b[0]] = true;
		let is_home = home != null && home[0] == b[0];
		if (o.mode == 'home' && !is_home) continue;
		// channels above 165 are new to Wi-Fi; many phones and laptops cannot use them and would not
		// even see a network that announces itself there
		if (b[length(b) - 1] > 165 && !is_home) continue;
		let ok = true, radar = false, power = 100, free = [];
		for (let c in b) {
			let i = chan_info(o, c);
			if (!i || i.bw < o.width) { ok = false; break; }
			if (i.radar) radar = true; else push(free, c);
			if (i.power < power) power = i.power;
		}
		// a block with radar channels in it has to wait before it may send, and may have to leave
		if (!ok || (radar && !is_home) || !length(free)) continue;
		push(blocks, { first: b[0], last: b[length(b) - 1], power, free, is_home });
	}
	// a block allowed far less power would be quiet, and reach nowhere
	let best = 0;
	for (let b in blocks) if (b.power > best) best = b.power;
	for (let b in blocks) {
		if (!b.is_home && b.power < best - 3) continue;
		for (let c in b.free) push(out, { channel: c, first: b.first, last: b.last, power: b.power });
	}
	return out;
};

// ---------- how busy each choice is ----------

/* The part of the band a network heard in a scan sends on, in MHz: [ low, high ]. */
export function occupied(band, n) {
	let f = n.mhz ?? mhz_of(band, n.channel);
	let ht = n.ht_operation, vht = n.vht_operation;
	if (band == '5g' && vht && vht.channel_width != 40 && vht.center_freq_1) {
		let c1 = mhz_of('5g', vht.center_freq_1), c2 = vht.center_freq_2 ? mhz_of('5g', vht.center_freq_2) : 0;
		if (vht.channel_width == 160) return [ c1 - 80, c1 + 80 ];
		// 160 MHz the way it is announced since 802.11ac-2016: the second number is its centre
		if (c2 && absdiff(vht.center_freq_2, vht.center_freq_1) == 8) return [ c2 - 80, c2 + 80 ];
		return [ c1 - 40, c1 + 40 ];
	}
	if (ht?.secondary_channel_offset == 'above') return [ f - 10, f + 30 ];
	if (ht?.secondary_channel_offset == 'below') return [ f - 30, f + 10 ];
	return [ f - 10, f + 10 ];
};

function overlap(a, lo, hi) {
	let x = (a[1] < hi ? a[1] : hi) - (a[0] > lo ? a[0] : lo);
	return x > 0 ? x : 0;
}

/* A network heard loudly takes the channel whenever it sends; a faint one only part of the time. */
function weight(signal) {
	return signal >= -60 ? 1 : signal >= -70 ? 0.8 : signal >= -80 ? 0.5 : signal >= -88 ? 0.25 : 0.1;
}

/* Puts the choices in order for the networks heard in a scan. Each channel gets
     score: the sum over the networks around of loudness times how much of the channel they cover
            (all of it when they sit on the 20 MHz the router would announce itself on, half their
            share of the whole width otherwise);
     networks, strongest: how many overlap it at all, and the loudest of them.
   The lowest score wins. Among those close to it: on 5 GHz a channel Apple devices meet on, then the
   channel the radio is on already, then the lower score, then the lowest channel. A 5 GHz block is one choice, whichever of
   its channels the router announces itself on, so the answer names one channel per block
   ({ candidates }) and the one to take ({ suggested }). */
export function rank(band, width, cands, current, scan) {
	let w = band == '2g' ? 20 : width, all = [];
	for (let c in cands) {
		let p = mhz_of(band, c.channel), lo = mhz_of(band, c.first) - 10, hi = mhz_of(band, c.last) + 10;
		if (band == '2g') { lo = p - 10; hi = p + 10; }
		let score = 0.0, nets = 0, strongest = null;
		for (let n in (scan ?? [])) {
			if (type(n.signal) != 'int' && type(n.signal) != 'double') continue;
			let occ = occupied(band, n);
			let whole = overlap(occ, lo, hi);
			if (whole <= 0) continue;
			let prim = overlap(occ, p - 10, p + 10) / 20.0, share = 0.5 * whole / w;
			score += weight(n.signal) * (prim > share ? prim : share);
			nets++;
			if (strongest == null || n.signal > strongest) strongest = n.signal;
		}
		push(all, { channel: c.channel, first: c.first, last: c.last, score: int(score * 100 + 0.5) / 100.0, networks: nets, strongest });
	}
	let pref = c => (band == '5g' && (c.channel in APPLE) ? 4 : 0) + (c.channel === current ? 2 : 0);
	let best_of = list => {
		let low = list[0].score;
		for (let c in list) if (c.score < low) low = c.score;
		let margin = low * 0.15 > 0.3 ? low * 0.15 : 0.3;
		return sort(filter(list, c => c.score <= low + margin),
			(a, b) => (pref(b) - pref(a)) || (a.score < b.score ? -1 : a.score > b.score ? 1 : 0) || (a.channel - b.channel))[0];
	};
	let groups = {}, order = [];
	for (let c in all) {
		let k = '' + c.first;
		if (!groups[k]) { groups[k] = []; push(order, k); }
		push(groups[k], c);
	}
	let out = map(order, k => best_of(groups[k]));
	return { candidates: out, suggested: length(out) ? best_of(out).channel : null };
};

/* The networks heard, per channel they announce themselves on: [ { channel, networks, strongest } ]. */
function heard(scan) {
	let per = {};
	for (let n in (scan ?? [])) {
		if (!n.channel) continue;
		let k = '' + n.channel;
		per[k] = per[k] ?? { channel: n.channel, networks: 0, strongest: -120 };
		per[k].networks++;
		if ((n.signal ?? -120) > per[k].strongest) per[k].strongest = n.signal;
	}
	return sort(values(per), (a, b) => a.channel - b.channel);
}

// ---------- the radios of this router ----------

function nl80211() {
	try { return require('nl80211'); }
	catch (e) { return null; }
}

function dump(nl, cmd, args) {
	let r = nl.request(nl.const[cmd], nl.const.NLM_F_DUMP, args ?? {});
	return type(r) == 'array' ? r : (r ? [ r ] : []);
}

/* Every 2.4 and 5 GHz radio with the channels it may use in a country:
   [ { id, band, width, current, ifname, mode, candidates } ]. ifname is null for a radio that is not
   up (it cannot scan). A 5 GHz radio split in two for Wi-Fi 7 multi-link (be7000-5g-split) has its
   channels set by that tool and is left out. Nothing is scanned here. */
export function radios(country) {
	let c = cursor(), conn = connect(), nl = nl80211(), out = [];
	if (!nl) return out;
	let up = conn.call('network.wireless', 'status') ?? {};
	let phy_of = {}, own_rules = {}, freqs_of = {};
	for (let i in dump(nl, 'NL80211_CMD_GET_INTERFACE')) if (i.ifname) phy_of[i.ifname] = i.wiphy;
	// a driver with its own rules has an entry of its own here
	for (let r in dump(nl, 'NL80211_CMD_GET_REG')) if (r.wiphy != null) own_rules['' + r.wiphy] = true;
	for (let p in dump(nl, 'NL80211_CMD_GET_WIPHY', { split_wiphy_dump: true })) {
		let fr = freqs_of['' + p.wiphy] ?? {};
		for (let b in (p.wiphy_bands ?? [])) for (let f in (b?.freqs ?? [])) if (f?.freq) fr['' + f.freq] = f;
		freqs_of['' + p.wiphy] = fr;
	}
	let db = null;
	c.foreach('wireless', 'wifi-device', r => {
		if (!(r.band in [ '2g', '5g' ]) || r.radio != null) return;
		let id = r['.name'], ifname = null;
		for (let i in (up[id]?.interfaces ?? [])) if (i.ifname && phy_of[i.ifname] != null && !ifname) ifname = i.ifname;
		let cur = match(r.channel ?? '', /^[0-9]+$/) ? +r.channel : 'auto';
		let o = { band: r.band, width: width_of(r.htmode), current: cur, freqs: null, mode: 'home', rules: null };
		if (ifname) {
			let phy = '' + phy_of[ifname];
			o.freqs = freqs_of[phy];
			if (r.country == country) o.mode = 'driver';
			else if (!own_rules[phy]) {
				db = db ?? readfile(REGDB);
				o.rules = rules_for(db, country);
				if (length(o.rules)) o.mode = 'regdb';
			}
		}
		push(out, { id, band: r.band, width: o.width, current: cur, ifname, mode: o.mode, candidates: ifname ? candidates(o) : [] });
	});
	return sort(out, (a, b) => a.band < b.band ? -1 : a.band > b.band ? 1 : 0);
};

/* Whether a radio may be set to a channel in a country (asked again when the assistant applies). */
export function allowed(list, id, ch) {
	for (let r in list)
		if (r.id == id) return type(ch) == 'int' && length(filter(r.candidates, x => x.channel == ch)) == 1;
	return false;
};

// ---------- the scan ----------

function put(o) {
	mkdir(RUN);
	writefile(JOB + '.tmp', sprintf('%J', o));
	rename(JOB + '.tmp', JOB);
}

/* Marks a scan as started before its process is: whoever asks next must not be shown the last one. */
export function begin(country, id) {
	put({ state: 'running', id, country, time: time() });
};

export function job() {
	let s = readfile(JOB);
	try { return s ? json(s) : null; }
	catch (e) { return null; }
};

/* Listens on every radio for the networks around and writes what it found, and the channel it would
   take, to /tmp/miwrt/wifi-scan.json. Takes 5 to 15 seconds; devices on Wi-Fi pause for a second or
   two while their band is listened on. Not for rpcd itself to call: the scan is answered by rpcd.
   Only counts per channel are kept, no names or addresses of anyone's network. */
export function run(country, id) {
	let started = time();
	try {
		begin(country, id);
		let conn = connect(), out = [];
		for (let r in radios(country)) {
			let e = { id: r.id, band: r.band, width: r.width, current: r.current, mode: r.mode, scanned: false,
				neighbours: 0, heard: [], candidates: [], suggested: null };
			if (r.ifname) {
				let res = conn.call('iwinfo', 'scan', { device: r.ifname })?.results;
				// another scan may be running on the radio (its own channel choice at start, say)
				if (res == null) { system('sleep 2'); res = conn.call('iwinfo', 'scan', { device: r.ifname })?.results; }
				if (res != null) {
					let ranked = rank(r.band, r.width, r.candidates, r.current, res);
					e.scanned = true;
					e.neighbours = length(res);
					e.heard = heard(res);
					e.candidates = ranked.candidates;
					e.suggested = ranked.suggested;
				}
			}
			push(out, e);
		}
		put({ state: 'done', id, country, time: time(), took: time() - started, radios: out });
	}
	catch (x) {
		warn(`miwrt-channels: ${x}\n`);
		put({ state: 'failed', id, country, time: time(), error: 'The scan did not finish.' });
	}
};
