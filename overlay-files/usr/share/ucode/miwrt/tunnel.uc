// MiWRT tunnel: the Xray VPN client and the link between two MiWRT routers, shared by the app's API
// (/usr/share/miwrt/api.uc), the web interface (rpcd object miwrt-vpn) and /usr/sbin/miwrt-tunnel,
// which the service /etc/init.d/miwrt-tunnel runs.
//
// The settings are /etc/miwrt/tunnel.json (private: server links hold passwords). From them the
// router writes one Xray configuration, /tmp/miwrt/tunnel/config.json, and one nftables table,
// inet miwrt_tunnel. Devices chosen for the VPN reach Xray through transparent proxying (TPROXY):
// their packets keep their real destination, are marked and delivered to Xray's dokodemo-door
// inbound by a local route in table 157. The router's own traffic never passes through the tunnel.
'use strict';

import { readfile, writefile, unlink, access, mkdir, stat, open, lsdir } from 'fs';
import { connect } from 'ubus';
import { cursor } from 'uci';
import * as hub from 'miwrt.hub';

const ETC = '/etc/miwrt';
const RUN = '/tmp/miwrt';
export const CONF = ETC + '/tunnel.json';
export const DIR = RUN + '/tunnel';
export const XCONF = DIR + '/config.json';
const JOB = RUN + '/tunnel-job.json';
const TESTS = RUN + '/tunnel-tests.json';
const HEALTH = RUN + '/tunnel-health.json';
const RATE = RUN + '/tunnel-rate.json';
const SUBS_JOB = RUN + '/tunnel-subs';           // exists while subscriptions are being fetched
const CHECKING = RUN + '/tunnel-checking';       // exists while a check started from the web page runs
const APPLIED = RUN + '/tunnel-applied';         // touched by every change that restarts the service
export const XRAY = '/usr/bin/xray';
export const TOOL = '/usr/sbin/miwrt-tunnel';
const INIT = '/etc/init.d/miwrt-tunnel';

export const MARK = '0x4d57';
// marks what the link opens on behalf of the other router: that may never reach this router itself
const LINK_MARK = 0x4d58;
export const TABLE = '157';
export const TP_PORT = 12370;           // transparent proxy inbound
export const SOCKS_PORT = 10808;        // local SOCKS for the router itself (only 127.0.0.1)
export const HTTP_PORT = 10809;         // local HTTP proxy, e.g. for Tailscale's control traffic
const API_PORT = 10813;                 // Xray's statistics API (only 127.0.0.1)
const LINK_SOCKS = 10812;               // checks the router link
export const LINK_LOCAL_PORT = 24443;   // the link's own server when this router is the meeting point

const MAX_SERVERS = 300;
const MAX_SUBS = 10;
// the router abroad checks the link with a request for this name; the inside router answers it itself
const LINK_PING = 'check.miwrt.invalid';

// Never sent through the tunnel and never reachable from the other end of a router link.
export const PRIVATE_V4 = [ '0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16', '172.16.0.0/12',
	'192.0.0.0/24', '192.168.0.0/16', '198.18.0.0/15', '224.0.0.0/4', '240.0.0.0/4' ];
const PRIVATE_V6 = [ '::/128', '::1/128', 'fc00::/7', 'fe80::/10', 'ff00::/8' ];

// Sites of a country that stay outside the tunnel when the country is set: banks and public
// services there often refuse foreign addresses, and domestic traffic is cheaper.
export const COUNTRIES = {
	ir: [ 'domain:ir' ],
	cn: [ 'domain:cn' ],
	ru: [ 'domain:ru', 'domain:su', 'domain:xn--p1ai' ]
};

// REALITY borrows the handshake of a real site. These answer TLS 1.3 with X25519 and HTTP/2.
export const REALITY_TARGETS = [ 'www.microsoft.com', 'www.apple.com', 'dl.google.com', 'www.amazon.com', 'www.cloudflare.com' ];

// ---------- small helpers ----------

function rand_hex(n) {
	let f = open('/dev/urandom', 'r');
	let b = f.read(n);
	f.close();
	return hexenc(b);
}

/* Is the file missing or older than secs seconds? */
function older(path, secs) {
	let st = stat(path);
	return !st || time() - st.mtime >= secs;
}

export function uuid() {
	let h = rand_hex(16);
	// version 4, variant 1
	let v = substr(h, 0, 12) + '4' + substr(h, 13, 3) + sprintf('%x', (hex(substr(h, 16, 1)) & 3) | 8) + substr(h, 17, 15);
	return `${substr(v, 0, 8)}-${substr(v, 8, 4)}-${substr(v, 12, 4)}-${substr(v, 16, 4)}-${substr(v, 20, 12)}`;
}

function q(s) {
	return "'" + replace(`${s}`, /'/g, "'\\''") + "'";
}

function urldec(s) {
	return replace(s ?? '', /%([0-9A-Fa-f]{2})/g, (m, h) => chr(hex(h)));
}

function urlenc(s) {
	return replace(`${s ?? ''}`, /[^A-Za-z0-9._~-]/g, (c) => sprintf('%%%02X', ord(c)));
}

// standard or URL-safe base64, with or without padding
function b64any(s) {
	s = replace(trim(s ?? ''), /[\r\n\t ]/g, '');
	if (!length(s) || match(s, /[^A-Za-z0-9+\/=_-]/)) return null;
	s = replace(replace(s, /-/g, '+'), /_/g, '/');
	s = replace(s, /=+$/, '');
	while (length(s) % 4) s += '=';
	return b64dec(s);
}

function b64url(s) {
	return replace(replace(replace(b64enc(s), /\+/g, '-'), /\//g, '_'), /=+$/, '');
}

function clean_name(s, fallback) {
	// ucode hands a pattern to the C library as text: no \x00 in it, and \s or \d mean nothing inside [ ]
	s = trim(replace(s ?? '', /[[:cntrl:]]/g, ' '));
	if (length(s) > 64) s = substr(s, 0, 64);
	return length(s) ? s : fallback;
}

function host_ok(h) {
	return type(h) == 'string' && length(h) <= 253 &&
		(match(h, /^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$/) != null || match(h, /^[0-9a-fA-F:.]+$/) != null && index(h, ':') >= 0);
}

function port_ok(p) {
	let n = +p;
	return type(n) == 'int' && n >= 1 && n <= 65535;
}

function ip2int(a) {
	let m = match(a ?? '', /^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$/);
	if (!m) return null;
	for (let i = 1; i <= 4; i++) if (+m[i] > 255) return null;
	return ((+m[1]) << 24 | (+m[2]) << 16 | (+m[3]) << 8 | (+m[4])) & 0xffffffff;
}

function int2ip(n) {
	return sprintf('%d.%d.%d.%d', (n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255);
}

export function cidr_ok(c) {
	let m = match(c ?? '', /^([0-9.]+)\/([0-9]+)$/);
	return m && ip2int(m[1]) != null && +m[2] >= 8 && +m[2] <= 32;
}

function cidr_net(c) {
	let m = match(c, /^([0-9.]+)\/([0-9]+)$/);
	let bits = +m[2], mask = bits ? (0xffffffff << (32 - bits)) & 0xffffffff : 0;
	return { net: ip2int(m[1]) & mask, mask };
}

function cidrs_overlap(a, b) {
	let x = cidr_net(a), y = cidr_net(b), mask = x.mask & y.mask;
	return (x.net & mask) == (y.net & mask);
}

/* The router's own networks that a router link may share: the home network (lan), as CIDRs. */
export function lan_cidrs() {
	let out = [];
	let st = connect().call('network.interface.lan', 'status') ?? {};
	for (let a in (st['ipv4-address'] ?? [])) {
		let n = ip2int(a.address), bits = +a.mask;
		if (n == null || bits < 8 || bits > 30) continue;
		let mask = (0xffffffff << (32 - bits)) & 0xffffffff;
		push(out, `${int2ip(n & mask)}/${bits}`);
	}
	return out;
}

function lan_device() {
	return connect().call('network.interface.lan', 'status')?.l3_device ?? 'br-lan';
}

function lan_ips() {
	let out = [];
	for (let a in (connect().call('network.interface.lan', 'status')?.['ipv4-address'] ?? [])) push(out, a.address);
	return out;
}

// ---------- settings ----------

function defaults() {
	return { enabled: false, server: null, servers: [], subscriptions: [], who: 'all', devices: [], country: '', dns: true, link: null };
}

export function conf() {
	let c = hub.load(CONF, null);
	if (type(c) != 'object') c = {};
	let d = defaults();
	for (let k, v in d) if (!(k in c) || type(c[k]) != type(v) && v != null) c[k] = v;
	if (type(c.servers) != 'array') c.servers = [];
	if (type(c.subscriptions) != 'array') c.subscriptions = [];
	if (type(c.devices) != 'array') c.devices = [];
	return c;
}

export function store(c) {
	mkdir(ETC);
	hub.save_private(CONF, c);
}

// ---------- share links ----------

function parse_query(s) {
	let out = {};
	for (let kv in split(s ?? '', '&')) {
		if (!length(kv)) continue;
		let i = index(kv, '=');
		let k = i < 0 ? kv : substr(kv, 0, i), v = i < 0 ? '' : substr(kv, i + 1);
		out[lc(urldec(k))] = urldec(v);
	}
	return out;
}

/* scheme://userinfo@host:port/path?query#fragment, where userinfo may hold any character except '@'
   that comes after it (base64 holds '/', '+' and '='). */
function split_url(s) {
	let m = match(s, /^([A-Za-z0-9+.-]+):\/\/(.*)$/s);
	if (!m) return null;
	let rest = m[2], frag = '';
	let h = index(rest, '#');
	if (h >= 0) { frag = substr(rest, h + 1); rest = substr(rest, 0, h); }
	let query = '';
	let qi = index(rest, '?');
	if (qi >= 0) { query = substr(rest, qi + 1); rest = substr(rest, 0, qi); }
	let user = null;
	let at = rindex(rest, '@');
	if (at >= 0) { user = substr(rest, 0, at); rest = substr(rest, at + 1); }
	let path = '';
	let sl = index(rest, '/');
	if (sl >= 0) { path = substr(rest, sl); rest = substr(rest, 0, sl); }
	let host = rest, port = null;
	let v6 = match(rest, /^\[([0-9A-Fa-f:.]+)\](:([0-9]+))?$/);
	if (v6) { host = v6[1]; port = v6[3]; }
	else {
		let hp = match(rest, /^([^:]+)(:([0-9]+))?$/);
		if (!hp) return null;
		host = hp[1]; port = hp[3];
	}
	return { scheme: lc(m[1]), user, host: lc(host), port: port != null ? +port : null, path, query: parse_query(query), name: urldec(frag) };
}

// the transport and security parts shared by vless, trojan and the vmess JSON
function stream_from(s, p) {
	let net = lc(p.type ?? p.net ?? 'tcp');
	if (net == 'tcp') net = 'raw';
	if (net == 'splithttp') net = 'xhttp';
	if (!(net in { raw: 1, ws: 1, grpc: 1, xhttp: 1, httpupgrade: 1 }))
		return `The transport "${net}" is not supported. Use TCP, WebSocket, gRPC, XHTTP or HTTPUpgrade.`;
	s.net = net;
	s.path = p.path ?? null;
	s.host_header = p.host ?? null;
	if (net == 'grpc') { s.path = p.servicename ?? p.path ?? ''; s.mode = (p.mode == 'multi') ? 'multi' : 'gun'; }
	if (net == 'xhttp') {
		s.mode = p.mode ?? 'auto';
		if (p.extra) { try { let e = json(p.extra); if (type(e) == 'object') s.extra = e; } catch (e) {} }
	}
	if (net == 'raw' && lc(p.headertype ?? '') == 'http') s.header = 'http';
	let sec = lc(p.security ?? 'none');
	if (sec == '') sec = 'none';
	if (!(sec in { none: 1, tls: 1, reality: 1 })) return `The security "${sec}" is not supported.`;
	s.security = sec;
	s.sni = p.sni ?? p.peer ?? null;
	s.fp = p.fp ?? null;
	s.alpn = p.alpn ?? null;
	if (sec == 'reality') {
		s.pbk = p.pbk ?? p.password ?? null;
		s.sid = p.sid ?? '';
		s.spx = p.spx ?? null;
		if (!s.pbk || !match(s.pbk, /^[A-Za-z0-9_-]{43}$/)) return 'This REALITY link has no valid public key (pbk).';
		if (!match(s.sid, /^[0-9a-fA-F]{0,16}$/)) return 'This REALITY link has an invalid short ID (sid).';
	}
	if (sec == 'tls') {
		s.pcs = p.pcs ?? null;
		s.vcn = p.vcn ?? null;
		if ((p.insecure == '1' || p.allowinsecure == '1') && !s.pcs)
			return 'This server skips certificate checks (insecure). Xray no longer allows that; ask for a link with the certificate fingerprint (pcs).';
	}
	return null;
}

/* One share link into a server record, or a string saying why not. */
export function parse_link(link) {
	link = trim(link ?? '');
	if (length(link) > 4096) return 'The link is too long.';
	let s = { proto: null, link };

	if (match(link, /^vmess:\/\//i)) {
		let raw = b64any(substr(link, 8));
		let v;
		try { v = json(raw); } catch (e) { v = null; }
		if (type(v) != 'object') return 'This VMess link cannot be read.';
		s.proto = 'vmess';
		s.host = lc(`${v.add ?? ''}`);
		s.port = +v.port;
		s.uuid = `${v.id ?? ''}`;
		s.alter_id = +(v.aid ?? 0);
		s.cipher = v.scy ?? 'auto';
		s.name = clean_name(v.ps, null);
		let p = { type: v.net, path: v.path, host: v.host, security: v.tls, sni: v.sni, fp: v.fp, alpn: v.alpn, pbk: v.pbk, sid: v.sid, spx: v.spx };
		if ((v.net ?? 'tcp') == 'tcp' && v.type == 'http') p.headertype = 'http';
		if (v.net == 'grpc') { p.servicename = v.path; p.mode = v.type == 'multi' ? 'multi' : 'gun'; }
		if (v.net == 'xhttp' || v.net == 'splithttp') p.mode = v.type;
		let err = stream_from(s, p);
		if (err) return err;
	}
	else if (match(link, /^ss:\/\//i)) {
		let u = split_url(link);
		s.proto = 'shadowsocks';
		if (u && u.user != null) {
			let ui = urldec(u.user), dec = b64any(u.user);
			let pair = (dec && index(dec, ':') > 0) ? dec : ui;
			let i = index(pair, ':');
			if (i <= 0) return 'This Shadowsocks link cannot be read.';
			s.method = lc(substr(pair, 0, i)); s.password = substr(pair, i + 1);
			s.host = u.host; s.port = u.port; s.name = clean_name(u.name, null);
			if (u.query.plugin) return 'Shadowsocks plugins are not supported.';
		} else {
			// the old form: ss://base64(method:password@host:port)#name
			let h = index(link, '#');
			let body = b64any(h < 0 ? substr(link, 5) : substr(link, 5, h - 5));
			let m = match(body ?? '', /^([^:]+):(.*)@([^@:]+|\[[0-9a-fA-F:]+\]):([0-9]+)$/s);
			if (!m) return 'This Shadowsocks link cannot be read.';
			s.method = lc(m[1]); s.password = m[2]; s.host = lc(replace(m[3], /^\[|\]$/g, '')); s.port = +m[4];
			s.name = clean_name(h < 0 ? '' : urldec(substr(link, h + 1)), null);
		}
		if (!match(s.method, /^(aes-(128|256)-gcm|chacha20-(ietf-)?poly1305|xchacha20-(ietf-)?poly1305|2022-blake3-(aes-128-gcm|aes-256-gcm|chacha20-poly1305)|none|plain)$/))
			return `The Shadowsocks cipher "${s.method}" is not supported.`;
		s.net = 'raw'; s.security = 'none';
	}
	else if (match(link, /^(hysteria2|hy2):\/\//i)) {
		let u = split_url(link);
		if (!u) return 'This Hysteria2 link cannot be read.';
		s.proto = 'hysteria2';
		s.password = urldec(u.user ?? '');
		s.host = u.host; s.port = u.port ?? 443; s.name = clean_name(u.name, null);
		s.sni = u.query.sni ?? null;
		s.pcs = u.query.pcs ?? u.query.pinsha256 ?? null;
		if (u.query.insecure == '1' && !s.pcs)
			return 'This server skips certificate checks (insecure). Xray no longer allows that; ask for a link with the certificate fingerprint.';
		if (u.query.obfs && u.query.obfs != 'salamander') return `The Hysteria2 obfuscation "${u.query.obfs}" is not supported.`;
		if (u.query.obfs) s.obfs = u.query['obfs-password'] ?? '';
		if (u.query.mport) return 'Port hopping (mport) is not supported.';
		s.net = 'hysteria'; s.security = 'tls';
	}
	else if (match(link, /^(vless|trojan):\/\//i)) {
		let u = split_url(link);
		if (!u || u.user == null) return 'This link cannot be read.';
		s.proto = u.scheme;
		s.host = u.host; s.port = u.port ?? 443; s.name = clean_name(u.name, null);
		if (s.proto == 'vless') {
			s.uuid = urldec(u.user);
			s.flow = u.query.flow ?? null;
			s.encryption = u.query.encryption ?? 'none';
		} else {
			s.password = urldec(u.user);
			if (!('security' in u.query)) u.query.security = 'tls';
		}
		let err = stream_from(s, u.query);
		if (err) return err;
	}
	else if (match(link, /^miwrt-link:/)) {
		return 'This is a router link code. Add it under Router link, not as a VPN server.';
	}
	else return 'This is not a link the router knows. It takes vless://, vmess://, trojan://, ss:// and hysteria2:// links.';

	if (!host_ok(s.host)) return 'The server address in this link is not valid.';
	if (!port_ok(s.port)) return 'The port in this link is not valid.';
	if (s.proto in { vless: 1, vmess: 1 } && !match(s.uuid ?? '', /^[A-Za-z0-9_-]{1,64}$/)) return 'The user ID in this link is not valid.';
	if (s.proto in { trojan: 1, shadowsocks: 1, hysteria2: 1 } && !length(s.password ?? '')) return 'This link has no password.';
	if (s.flow && !match(s.flow, /^xtls-rprx-vision(-udp443)?$/)) return `The flow "${s.flow}" is not supported.`;
	if (!s.name) s.name = `${s.host}:${s.port}`;
	return s;
}

/* Many links at once: one per line, or a subscription's base64 text. Returns { servers, errors }. */
export function parse_many(text) {
	text = trim(text ?? '');
	if (!match(text, /:\/\//)) {
		let dec = b64any(text);
		if (dec && match(dec, /:\/\//)) text = dec;
	}
	let servers = [], errors = [];
	for (let line in split(text, /\r?\n/)) {
		line = trim(line);
		if (!length(line) || substr(line, 0, 1) == '#') continue;
		let r = parse_link(line);
		if (type(r) == 'string') push(errors, r);
		else push(servers, r);
	}
	return { servers, errors };
}

// ---------- Xray configuration ----------

function strip_null(o) {
	if (type(o) == 'object') {
		let out = {};
		for (let k, v in o) if (v != null) out[k] = strip_null(v);
		return out;
	}
	if (type(o) == 'array') return map(o, strip_null);
	return o;
}

function stream_settings(s) {
	let st = { network: s.net, security: s.security };
	if (s.security == 'tls')
		st.tlsSettings = { serverName: s.sni ?? (s.host_header ?? null), fingerprint: s.fp ?? 'chrome',
			alpn: s.alpn ? split(s.alpn, ',') : (s.net == 'hysteria' ? [ 'h3' ] : null),
			pinnedPeerCertSha256: s.pcs, verifyPeerCertByName: s.vcn };
	if (s.security == 'reality')
		st.realitySettings = { serverName: s.sni, fingerprint: s.fp ?? 'chrome', password: s.pbk, shortId: s.sid ?? '', spiderX: s.spx };
	if (s.net == 'raw' && s.header == 'http')
		st.rawSettings = { header: { type: 'http', request: { path: [ s.path ?? '/' ], headers: s.host_header ? { Host: split(s.host_header, ',') } : null } } };
	if (s.net == 'ws') st.wsSettings = { path: s.path ?? '/', host: s.host_header };
	if (s.net == 'httpupgrade') st.httpupgradeSettings = { path: s.path ?? '/', host: s.host_header };
	if (s.net == 'grpc') st.grpcSettings = { serviceName: s.path ?? '', multiMode: s.mode == 'multi' };
	if (s.net == 'xhttp') st.xhttpSettings = { path: s.path ?? '/', host: s.host_header, mode: s.mode ?? 'auto', extra: s.extra };
	if (s.net == 'hysteria') {
		st.hysteriaSettings = { version: 2, auth: s.password };
		if (s.obfs != null) st.finalmask = { udp: [ { type: 'salamander', settings: { password: s.obfs } } ] };
	}
	return st;
}

export function outbound(s, tag) {
	let o = { tag, protocol: s.proto, streamSettings: stream_settings(s) };
	if (s.proto == 'vless')
		o.settings = { address: s.host, port: s.port, id: s.uuid, flow: s.flow, encryption: s.encryption ?? 'none', reverse: s.reverse ? { tag: s.reverse } : null };
	else if (s.proto == 'vmess')
		o.settings = { vnext: [ { address: s.host, port: s.port, users: [ { id: s.uuid, alterId: s.alter_id ?? 0, security: s.cipher ?? 'auto' } ] } ] };
	else if (s.proto == 'trojan')
		o.settings = { servers: [ { address: s.host, port: s.port, password: s.password } ] };
	else if (s.proto == 'shadowsocks')
		o.settings = { servers: [ { address: s.host, port: s.port, method: s.method, password: s.password } ] };
	else if (s.proto == 'hysteria2') {
		o.protocol = 'hysteria';
		o.settings = { version: 2, address: s.host, port: s.port };
	}
	return strip_null(o);
}

/* What the link outbound and the link server use (both ends of a router link). */
function link_server(l) {
	return { proto: 'vless', host: l.host, port: l.port, uuid: null, flow: 'xtls-rprx-vision', encryption: 'none',
		net: 'raw', security: 'reality', sni: l.sni, fp: 'chrome', pbk: l.pbk, sid: l.sid };
}

/* Traffic that arrives from the other router may leave here only to the internet (when this router
   is the exit) and to this router's own networks (when they are shared), never to the router itself
   or any other private address. First match wins. */
function link_exit_rules(l) {
	let rules = [];
	if (l.share_lan && length(l.lans ?? [])) {
		let mine = filter(lan_ips(), a => a);
		if (length(mine)) push(rules, { action: 'block', ip: map(mine, a => a + '/32') });
		push(rules, { action: 'allow', ip: l.lans });
	}
	push(rules, { action: 'block', ip: [ ...PRIVATE_V4, ...PRIVATE_V6 ] });
	push(rules, { action: l.role == 'exit' ? 'allow' : 'block' });
	return rules;
}

function find_server(c, id) {
	for (let s in c.servers) if (s.id == id) return s;
	return null;
}

/* Can the VPN use the linked router as its server? */
function link_usable(c) {
	return c.link?.role == 'inside' && c.link.internet !== false;
}

/* Is the VPN on and pointed at something that exists? Returns the outbound tag of the server or null. */
function vpn_target(c) {
	if (!c.enabled) return null;
	if (c.server == 'link') return link_usable(c) ? 'link-use' : null;
	return find_server(c, c.server) ? 'proxy' : null;
}

/* The whole Xray configuration for the settings c, or a string saying what is wrong. */
export function xray_config(c) {
	let target = vpn_target(c), l = c.link;
	let inbounds = [], outbounds = [], rules = [];

	push(inbounds, { tag: 'tp', port: TP_PORT, protocol: 'dokodemo-door',
		settings: { network: 'tcp,udp', followRedirect: true },
		streamSettings: { sockopt: { tproxy: 'tproxy' } },
		sniffing: { enabled: true, destOverride: [ 'http', 'tls', 'quic' ], routeOnly: true } });
	push(inbounds, { tag: 'local', listen: '127.0.0.1', port: SOCKS_PORT, protocol: 'socks', settings: { udp: true },
		sniffing: { enabled: true, destOverride: [ 'http', 'tls' ], routeOnly: true } });
	push(inbounds, { tag: 'local-http', listen: '127.0.0.1', port: HTTP_PORT, protocol: 'http' });
	push(inbounds, { tag: 'api', listen: '127.0.0.1', port: API_PORT, protocol: 'dokodemo-door', settings: { address: '127.0.0.1' } });

	// the first outbound takes everything no rule names
	if (target == 'proxy') {
		let s = find_server(c, c.server);
		push(outbounds, outbound(s, 'proxy'));
	}
	push(outbounds, { tag: 'direct', protocol: 'freedom', streamSettings: { sockopt: { domainStrategy: 'UseIPv4' } } });
	push(outbounds, { tag: 'block', protocol: 'blackhole' });
	push(outbounds, { tag: 'dns-out', protocol: 'dns' });

	push(rules, { type: 'field', inboundTag: [ 'api' ], outboundTag: 'api' });

	if (l) {
		let ls = link_server(l.peer ?? {});
		if (l.role == 'exit' && l.meet == 'self') {
			let srv = { tag: 'link-in', port: LINK_LOCAL_PORT, protocol: 'vless',
				settings: { decryption: 'none', clients: [
					{ id: l.ids.in_use, flow: 'xtls-rprx-vision', email: 'in-use' },
					{ id: l.ids.in_rev, flow: 'xtls-rprx-vision', email: 'in-rev', reverse: { tag: 'link-peer' } } ] },
				streamSettings: { network: 'raw', security: 'reality',
					realitySettings: { target: `${l.self.target}:443`, serverNames: [ l.self.target ], privateKey: l.self.priv, shortIds: [ l.self.sid ] } },
				sniffing: { enabled: true, destOverride: [ 'http', 'tls', 'quic' ], routeOnly: true } };
			push(inbounds, srv);
			push(rules, { type: 'field', inboundTag: [ 'link-in' ], user: [ 'in-use' ], outboundTag: 'link-out' });
		} else {
			// both ends dial the meeting point: one connection that offers this router's side ...
			let me = (l.role == 'exit') ? { rev: l.ids.exit_rev, use: l.ids.exit_use } : { rev: l.ids.in_rev, use: l.ids.in_use };
			if (l.role == 'exit' || l.share_lan) {
				let o = outbound({ ...ls, uuid: me.rev, reverse: 'link-from-peer' }, 'link-portal');
				push(outbounds, o);
				if (l.role == 'inside') {
					// answered here (HTTP 403 from a blackhole), so the router abroad can tell the link works
					push(outbounds, { tag: 'link-ping', protocol: 'blackhole', settings: { response: { type: 'http' } } });
					push(rules, { type: 'field', inboundTag: [ 'link-from-peer' ], domain: [ 'full:' + LINK_PING ], outboundTag: 'link-ping' });
				}
				push(rules, { type: 'field', inboundTag: [ 'link-from-peer' ], outboundTag: 'link-out' });
			}
			// ... and one that uses the other side
			push(outbounds, outbound({ ...ls, uuid: me.use }, 'link-use'));
		}
		if (l.role == 'exit' && l.meet == 'self') {
			// the inside router's offer arrives as the reverse "link-peer" (see the inbound)
			if (length(l.peer_lans ?? [])) push(rules, { type: 'field', ip: l.peer_lans, outboundTag: 'link-peer' });
		} else if (length(l.peer_lans ?? []))
			push(rules, { type: 'field', ip: l.peer_lans, outboundTag: 'link-use' });
		push(outbounds, { tag: 'link-out', protocol: 'freedom', settings: { finalRules: link_exit_rules(l) }, streamSettings: { sockopt: { domainStrategy: 'UseIPv4', mark: LINK_MARK } } });
		push(inbounds, { tag: 'link-check', listen: '127.0.0.1', port: LINK_SOCKS, protocol: 'socks', settings: { udp: false } });
		if (l.role == 'inside') push(rules, { type: 'field', inboundTag: [ 'link-check' ], outboundTag: 'link-use' });
		else if (l.meet != 'self') push(rules, { type: 'field', inboundTag: [ 'link-check' ], outboundTag: 'link-use' });
		else push(rules, { type: 'field', inboundTag: [ 'link-check' ], outboundTag: 'link-peer' });
	}

	if (target) {
		if (c.dns) push(rules, { type: 'field', inboundTag: [ 'tp' ], port: '53', outboundTag: 'dns-out' });
		push(rules, { type: 'field', inboundTag: [ 'dns-q' ], outboundTag: target });
		push(rules, { type: 'field', ip: PRIVATE_V4, outboundTag: 'direct' });
		if (COUNTRIES[c.country]) push(rules, { type: 'field', inboundTag: [ 'tp', 'local' ], domain: COUNTRIES[c.country], outboundTag: 'direct' });
		push(rules, { type: 'field', inboundTag: [ 'tp', 'local', 'local-http' ], outboundTag: target });
	} else {
		// nothing to tunnel: the local proxies go straight out, transparent traffic is only the link's
		push(rules, { type: 'field', inboundTag: [ 'tp', 'local', 'local-http' ], outboundTag: 'direct' });
	}

	let dns = null;
	if (target) {
		dns = { tag: 'dns-q', queryStrategy: 'UseIPv4',
			servers: [ 'https://1.1.1.1/dns-query', 'https://8.8.8.8/dns-query' ] };
		if (COUNTRIES[c.country]) unshift(dns.servers, { address: 'localhost', domains: COUNTRIES[c.country], skipFallback: true });
		// names in the home network (router.lan, a printer) only this router knows
		unshift(dns.servers, { address: 'localhost', domains: [ 'domain:lan', 'domain:local', 'domain:home.arpa' ], skipFallback: true });
	}

	return strip_null({
		log: { loglevel: 'warning' },
		api: { tag: 'api', services: [ 'StatsService' ] },
		stats: {},
		policy: { system: { statsOutboundUplink: true, statsOutboundDownlink: true } },
		dns,
		inbounds, outbounds,
		routing: { domainStrategy: 'AsIs', rules }
	});
}

/* Should the service run at all? */
export function wanted(c) {
	return !!(vpn_target(c) || c.link);
}

// ---------- nftables and the local route ----------

function nft_set(name, typ, elems) {
	if (!length(elems)) return `\tset ${name} { type ${typ}; flags interval; }\n`;
	return `\tset ${name} { type ${typ}; flags interval; elements = { ${join(', ', elems)} } }\n`;
}

/* Devices paused from the app (a pause, a schedule, a new device waiting for approval). The app
   service keeps them in /etc/miwrt/blocked.list for the firewall's forward chain. */
function paused_macs() {
	return filter(map(split(readfile(ETC + '/blocked.list') ?? '', '\n'), m => lc(trim(m))), m => hub.is_mac(m));
}

function mac_set(name, macs) {
	return `\tset ${name} { type ether_addr; ${length(macs) ? 'elements = { ' + join(', ', macs) + ' }' : ''} }\n`;
}

/* The rules for the settings c (text for nft -f). */
export function nft_rules(c) {
	let target = vpn_target(c), l = c.link, dev = lan_device();
	let peer = (l && length(l.peer_lans ?? [])) ? l.peer_lans : [];
	let macs = filter(c.devices ?? [], m => hub.is_mac(m));
	let t = 'table inet miwrt_tunnel {\n';
	t += nft_set('private4', 'ipv4_addr', PRIVATE_V4);
	t += nft_set('peer4', 'ipv4_addr', peer);
	t += nft_set('routerips', 'ipv4_addr', lan_ips());
	t += mac_set('macs', macs);
	t += mac_set('paused', paused_macs());
	t += '\tchain pre {\n\t\ttype filter hook prerouting priority mangle; policy accept;\n';
	t += `\t\tiifname != "${dev}" return\n`;
	// the transparent proxy takes redirected traffic only, never a connection made to it directly
	t += `\t\tmeta l4proto { tcp, udp } th dport ${TP_PORT} fib daddr type local drop\n`;
	// a paused device goes on to the firewall's forward chain, which rejects it; through Xray its
	// traffic would never pass that chain
	t += '\t\tether saddr @paused return\n';
	t += `\t\tmeta l4proto { tcp, udp } ip daddr @peer4 meta mark set ${MARK} tproxy ip to :${TP_PORT} accept\n`;
	if (target) {
		if (c.who == 'selected') t += '\t\tether saddr != @macs return\n';
		if (c.who == 'except') t += '\t\tether saddr @macs return\n';
		if (c.dns) {
			t += `\t\tip daddr @routerips meta l4proto { tcp, udp } th dport 53 meta mark set ${MARK} tproxy ip to :${TP_PORT} accept\n`;
			// a lookup over IPv6 (the router's own IPv6 address answers too) would pass beside the
			// tunnel: dropped, so the device asks over IPv4
			t += '\t\tmeta nfproto ipv6 meta l4proto { tcp, udp } th dport 53 drop\n';
		}
		t += '\t\tip daddr @private4 return\n';
		t += `\t\tmeta nfproto ipv4 meta l4proto { tcp, udp } meta mark set ${MARK} tproxy ip to :${TP_PORT} accept\n`;
		// IPv6 would pass beside the tunnel
		t += `\t\tmeta nfproto ipv6 ip6 daddr != { ${join(', ', PRIVATE_V6)} } drop\n`;
	}
	t += '\t}\n';
	if (l) {
		// what the other router opens through the link never reaches this router itself, at any of its
		// addresses, the public one included (Xray marks those connections: see link-out)
		t += '\tchain out {\n\t\ttype filter hook output priority filter; policy accept;\n';
		t += `\t\tmeta mark ${sprintf('0x%x', LINK_MARK)} fib daddr type local reject\n`;
		t += '\t}\n';
	}
	t += '}\n';
	return t;
}

export function nft_apply(c) {
	mkdir(DIR);
	// a name of its own: the service and a network change can write at the same moment
	let f = DIR + `/rules.${rand_hex(4)}.nft`;
	writefile(f, 'table inet miwrt_tunnel\ndelete table inet miwrt_tunnel\n' + nft_rules(c));
	let out = hub.run(`nft -f ${f} 2>&1; echo "__RC:$?"`);
	unlink(f);
	let m = match(out, /__RC:([0-9]+)\s*$/);
	if (!m || m[1] != '0') return trim(replace(out, /__RC:[0-9]+\s*$/, ''));
	return null;
}

/* After the paused devices change: the rules are written again when they are in place. */
export function paused_changed() {
	if (system('nft list table inet miwrt_tunnel >/dev/null 2>&1') != 0) return;
	let err = nft_apply(conf());
	if (err) warn(`miwrt-tunnel: firewall rules: ${err}\n`);
}

export function nft_clear() {
	system('nft delete table inet miwrt_tunnel >/dev/null 2>&1');
}

export function route_on() {
	system(`ip rule show | grep -q "fwmark ${MARK} lookup ${TABLE}" || ip rule add fwmark ${MARK} lookup ${TABLE} priority ${TABLE}`);
	system(`ip route replace local 0.0.0.0/0 dev lo table ${TABLE}`);
}

export function route_off() {
	system(`while ip rule del fwmark ${MARK} lookup ${TABLE} 2>/dev/null; do :; done; ip route flush table ${TABLE} 2>/dev/null`);
}

// ---------- the engine (the Xray package) ----------

function model() {
	return match(readfile('/etc/miwrt-release') ?? '', /(^|\n)MODEL=([^\n]*)/)?.[2] ?? 'Xiaomi BE7000';
}

/* The package for this router: the BE7000 keeps Xray compressed on flash and unpacks it into memory. */
export function engine_package() {
	return match(model(), /AC2100/) ? 'miwrt-xray' : 'miwrt-xray-xz';
}

function free_kb() {
	let m = match(hub.run('df -k /overlay 2>/dev/null'), /\n\S+\s+[0-9]+\s+[0-9]+\s+([0-9]+)\s/);
	return m ? +m[1] : 0;
}

export function engine_installed() {
	return access(XRAY) == true;
}

/* Is the VPN installed and switched on (whether or not it works right now)? */
export function vpn_on() {
	return engine_installed() && !!vpn_target(conf());
}

/* null when it can be installed, else 'storage'. */
export function engine_blocker() {
	if (engine_installed()) return null;
	return free_kb() < (engine_package() == 'miwrt-xray' ? 16 : 9) * 1024 ? 'storage' : null;
}

export function engine_version() {
	if (!engine_installed()) return null;
	let st = stat(XRAY), key = `${st?.mtime}:${st?.size}:${stat('/usr/share/miwrt-xray/xray.sha256')?.mtime}`;
	let kept = hub.load(DIR + '/engine.json', null);
	if (kept?.key == key) return kept.version;
	let v = match(hub.run(`${XRAY} version 2>/dev/null | head -n 1`), /^Xray ([0-9][^ ]*)/)?.[1];
	if (v) { mkdir(DIR); hub.save(DIR + '/engine.json', { key, version: v }); }
	return v;
}

export function job() {
	let j = hub.load(JOB, null);
	if (type(j) != 'object') return null;
	j.age = max(0, time() - (j.time ?? 0));
	if (j.state == 'running' && j.age >= 900) {
		j.state = 'failed';
		j.error = 'The router stopped before it finished. Try again.';
	}
	return j;
}

function job_running() {
	return job()?.state == 'running';
}

export function job_step(state, step, error) {
	mkdir(RUN);
	hub.save(JOB, { state, step, error, time: time() });
}

export function engine_install() {
	if (engine_installed()) return 'Xray is already installed.';
	if (engine_blocker() == 'storage') return 'There is not enough free storage for Xray. Free some space under System, Software, then try again.';
	return hub.locked(() => {
		if (job_running()) return null;
		job_step('running', 'download');
		system(`(${TOOL} engine-install) >/dev/null 2>&1 </dev/null &`);
		return null;
	});
}

export function engine_remove() {
	if (!engine_installed()) return 'Xray is not installed.';
	return hub.locked(() => {
		if (job_running()) return 'Xray is still being installed. Try again in a minute.';
		job_step('running', 'remove');
		system(`(${TOOL} engine-remove) >/dev/null 2>&1 </dev/null &`);
		return null;
	});
}

// ---------- applying ----------

/* Writes the Xray configuration for c. Returns an error text or null. */
export function write_config(c) {
	mkdir(DIR);
	system([ 'chmod', '700', DIR ]);
	let cfg = xray_config(c);
	if (type(cfg) == 'string') return cfg;
	// a name of its own: two changes in quick succession must not write into one file
	let tmp = DIR + `/config.${rand_hex(4)}.json`;
	writefile(tmp, '');
	system([ 'chmod', '600', tmp ]);
	writefile(tmp, sprintf('%J', cfg));
	if (engine_installed()) {
		let out = hub.run(`${XRAY} run -test -c ${tmp} 2>&1; echo "__RC:$?"`);
		if (!match(out, /__RC:0\s*$/)) {
			unlink(tmp);
			let why = match(out, /(Failed to[^\n]*|[^\n]*error[^\n]*)/i)?.[1] ?? 'Xray did not accept the settings.';
			return `Xray did not accept the settings: ${trim(why)}`;
		}
	}
	system([ 'mv', '-f', tmp, XCONF ]);
	return null;
}

/* Puts the settings into effect: the service starts, restarts or stops. In the background, so a
   request from the app or the web page returns at once. */
export function apply() {
	unlink(HEALTH);
	unlink(RATE);
	mkdir(RUN);
	writefile(APPLIED, '');
	// Tailscale set to reach its servers through the VPN follows the VPN coming or going
	system(`(${INIT} enabled || ${INIT} enable; ${INIT} restart; [ -x /usr/sbin/miwrt-tailscale ] && /usr/sbin/miwrt-tailscale follow) >/dev/null 2>&1 </dev/null &`);
}

// ---------- state for the app and the web page ----------

function public_server(s, tests) {
	let t = tests?.results?.[s.id];
	return { id: s.id, name: s.name, protocol: s.proto, transport: s.net, security: s.security, address: s.host, port: s.port,
		source: s.source ?? 'manual', latency_ms: t?.ms, test_error: t?.error };
}

function service_running() {
	let r = connect().call('service', 'list', { name: 'miwrt-tunnel' }) ?? {};
	for (let name, inst in (r['miwrt-tunnel']?.instances ?? {})) if (inst.running) return true;
	return false;
}

/* Up and down bytes per second through the tunnel, from Xray's own counters. */
function rates(target) {
	if (!target || !service_running()) return null;
	let prev = hub.load(RATE, null), now = time();
	// each query starts the Xray program once more: not more often than every 10 seconds
	if (prev && now - prev.t < 10) return prev.rate;
	let out = hub.run(`${XRAY} api statsquery --server=127.0.0.1:${API_PORT} -pattern 'outbound>>>${target}>>>' 2>/dev/null`);
	let up = 0, down = 0;
	try {
		for (let s in (json(out)?.stat ?? [])) {
			if (match(s.name, /uplink$/)) up = +(s.value ?? 0);
			if (match(s.name, /downlink$/)) down = +(s.value ?? 0);
		}
	} catch (e) { return prev?.rate; }
	let rate = null;
	if (prev && now > prev.t && up >= prev.up && down >= prev.down)
		rate = { up_bps: int((up - prev.up) * 8 / (now - prev.t)), down_bps: int((down - prev.down) * 8 / (now - prev.t)) };
	hub.save(RATE, { t: now, up, down, rate });
	return { ...(rate ?? { up_bps: 0, down_bps: 0 }), up_bytes: up, down_bytes: down };
}

/* Through the tunnel to Cloudflare: which address and country the sites see. */
export function check(port) {
	let out = hub.run(`curl -s -m 12 -x socks5h://127.0.0.1:${port ?? SOCKS_PORT} -w '\\n__T:%{time_total}' https://www.cloudflare.com/cdn-cgi/trace 2>&1`);
	let ip = match(out, /(^|\n)ip=([^\n]+)/)?.[2], loc = match(out, /(^|\n)loc=([A-Z]{2})/)?.[2];
	let t = match(out, /__T:([0-9.]+)/)?.[1];
	if (!ip) return { ok: false, time: time(), error: 'No answer through the tunnel.' };
	return { ok: true, time: time(), exit_ip: ip, country: loc, ms: int(+t * 1000) };
}

export function health(fresh) {
	let h = hub.load(HEALTH, null);
	if (!fresh && h && time() - h.time < 120) return h;
	if (!service_running()) return null;
	h = check(SOCKS_PORT);
	hub.save(HEALTH, h);
	return h;
}

/* A check in the background (for the web page: the router's web service may not wait 12 seconds). */
export function check_bg() {
	if (!vpn_target(conf()) || !service_running() || !older(CHECKING, 20)) return;
	mkdir(RUN);
	writefile(CHECKING, '');
	system(`(${TOOL} check) >/dev/null 2>&1 </dev/null &`);
}

/* For miwrt-tunnel check. */
export function check_now() {
	health(true);
	unlink(CHECKING);
}

function subs_running() {
	return !older(SUBS_JOB, 600);
}

function uptime() {
	return +(split(readfile('/proc/uptime') ?? '0', ' ')[0]);
}

export function state(fresh) {
	let c = conf(), target = vpn_target(c), tests = hub.load(TESTS, null), running = service_running();
	let st = 'off';
	if (target) {
		// a check takes up to 12 seconds, so only an explicit request waits for one; otherwise the
		// 30 s pass keeps the answer fresh
		let h = running ? (fresh ? health(true) : hub.load(HEALTH, null)) : null;
		// still not running a minute after the last change (two minutes after a boot): it does not start
		let stuck = !running && older(APPLIED, 60) && uptime() > 120;
		st = !engine_installed() ? 'no-engine' : stuck ? 'failing' : !running ? 'starting' : (h == null ? 'starting' : (h.ok ? 'connected' : 'failing'));
	}
	let servers = map(c.servers, s => public_server(s, tests));
	if (link_usable(c))
		unshift(servers, { id: 'link', name: c.link.peer_name ?? 'Linked router', protocol: 'link', address: c.link.peer?.host, port: c.link.peer?.port, source: 'link' });
	return {
		engine: { installed: engine_installed(), version: engine_version(), package: engine_package(), blocker: engine_blocker(), job: job() },
		enabled: !!c.enabled, server: c.server, who: c.who, devices: c.devices, country: c.country, dns: !!c.dns,
		countries: keys(COUNTRIES),
		status: { state: st, running, health: target ? hub.load(HEALTH, null) : null, rate: rates(target), checking: !older(CHECKING, 20) },
		servers,
		subscriptions: map(c.subscriptions, s => ({ id: s.id, name: s.name, host: match(s.url, /^https?:\/\/([^\/:?#]+)/)?.[1], updated: s.updated, count: s.count, error: s.error })),
		// a test whose program died (out of memory) does not count as running for ever
		tests: tests ? { running: !!tests.running && time() - (tests.time ?? 0) < 180, time: tests.time } : null,
		subs_updating: subs_running(),
		link: !!c.link,
		// for the web page's device list: only devices in the home network, not the router itself
		lans: lan_cidrs(), router_ips: lan_ips()
	};
}

// ---------- changes ----------

export function set(b) {
	return hub.locked(() => {
		let c = conf();
		if ('who' in b) {
			if (!(b.who in { all: 1, selected: 1, except: 1 })) return 'Choose all devices, chosen devices, or all but chosen devices.';
			c.who = b.who;
		}
		if ('devices' in b) {
			if (type(b.devices) != 'array' || length(b.devices) > 256) return 'The device list is not valid.';
			let d = [];
			for (let m in b.devices) { m = lc(`${m}`); if (!hub.is_mac(m)) return 'The device list is not valid.'; if (index(d, m) < 0) push(d, m); }
			c.devices = d;
		}
		if ('country' in b) {
			if (b.country != '' && !COUNTRIES[b.country]) return 'That country is not known.';
			c.country = b.country;
		}
		if ('dns' in b) c.dns = !!b.dns;
		if ('server' in b) {
			if (b.server == 'link' ? !link_usable(c) : !find_server(c, b.server)) return 'That server is not in the list.';
			c.server = b.server;
		}
		if ('enabled' in b) {
			if (b.enabled && !engine_installed()) return 'Install Xray first.';
			if (b.enabled && !(c.server == 'link' ? link_usable(c) : find_server(c, c.server))) return 'Choose a server first.';
			c.enabled = !!b.enabled;
		}
		if (c.enabled && c.who == 'selected' && !length(c.devices)) return 'Choose at least one device, or let all devices use the VPN.';
		let err = engine_installed() && wanted(c) ? write_config(c) : null;
		if (err) return err;
		let was = conf();
		store(c);
		if (b.enabled != null && !!b.enabled != !!was.enabled)
			hub.add_alert('internet', c.enabled ? 'VPN switched on' : 'VPN switched off', c.enabled ? `Through ${find_server(c, c.server)?.name ?? 'the linked router'}.` : '', 'info');
		apply();
		return null;
	});
}

function new_id(c) {
	for (let i = 0; i < 10; i++) {
		let id = rand_hex(4);
		if (!find_server(c, id) && id != 'link') return id;
	}
	return rand_hex(8);
}

function same_server(a, b) {
	return a.proto == b.proto && a.host == b.host && a.port == b.port && (a.uuid ?? a.password) == (b.uuid ?? b.password) && a.net == b.net;
}

export function servers_action(b) {
	return hub.locked(() => {
		let c = conf(), restart = false;
		if (b.action == 'add') {
			let r = parse_many(b.text);
			if (!length(r.servers)) return length(r.errors) ? r.errors[0] : 'Paste one or more server links.';
			let added = 0;
			for (let s in r.servers) {
				if (length(filter(c.servers, x => same_server(x, s)))) continue;
				if (length(c.servers) >= MAX_SERVERS) break;
				s.id = new_id(c); s.source = 'manual';
				push(c.servers, s);
				added++;
			}
			if (!c.server && length(c.servers)) c.server = c.servers[0].id;
			store(c);
			return { added, skipped: length(r.servers) - added, errors: r.errors };
		}
		let s = find_server(c, b.id);
		if (!s) return 'That server is not in the list.';
		if (b.action == 'rename') {
			s.name = clean_name(b.name, s.name);
		} else if (b.action == 'delete') {
			if (s.source != 'manual') return 'This server comes from a subscription. Remove the subscription instead.';
			c.servers = filter(c.servers, x => x.id != s.id);
			if (c.server == s.id) { c.server = length(c.servers) ? c.servers[0].id : null; if (!c.server) c.enabled = false; restart = true; }
		} else return 'Unknown action.';
		store(c);
		if (restart) apply();
		return null;
	});
}

function fetch_text(url, via_tunnel) {
	mkdir(DIR);
	let f = DIR + `/fetch.${rand_hex(4)}.tmp`;
	let proxy = via_tunnel ? `-x socks5h://127.0.0.1:${SOCKS_PORT}` : '';
	let rc = system(`curl -s -f -L -m 25 --max-filesize 1048576 -A MiWRT ${proxy} -o ${f} ${q(url)} >/dev/null 2>&1`);
	let text = rc == 0 ? readfile(f) : null;
	unlink(f);
	return text;
}

/* Fetches one subscription and puts its servers in place of the old ones. Returns an error text or null. */
function sub_refresh(c, sub) {
	let text = fetch_text(sub.url, false);
	if (text == null && service_running() && vpn_target(c)) text = fetch_text(sub.url, true);
	if (text == null) { sub.error = 'The router could not download this subscription.'; return sub.error; }
	let r = parse_many(text);
	if (!length(r.servers)) { sub.error = 'The subscription has no server the router can use.'; return sub.error; }
	let old = filter(c.servers, s => s.source == sub.id);
	let keep = filter(c.servers, s => s.source != sub.id);
	let fresh = [];
	for (let s in slice(r.servers, 0, max(0, MAX_SERVERS - length(keep)))) {
		// a server that stays keeps its id, so a chosen one stays chosen
		let was = filter(old, o => same_server(o, s))[0];
		s.id = was?.id ?? new_id({ servers: [ ...keep, ...fresh, ...old ] });
		s.source = sub.id;
		push(fresh, s);
	}
	c.servers = [ ...keep, ...fresh ];
	sub.updated = time(); sub.count = length(fresh); sub.error = null;
	if (c.server && !find_server(c, c.server) && c.server != 'link') { c.server = length(fresh) ? fresh[0].id : null; if (!c.server) c.enabled = false; }
	return null;
}

function subs_start(id) {
	mkdir(RUN);
	writefile(SUBS_JOB, '');
	system(`(${TOOL} subs-update ${id ? q(id) : ''}) >/dev/null 2>&1 </dev/null &`);
}

/* Fetches the subscriptions again (all, or the one with the given id) and puts their servers in
   place. For miwrt-tunnel subs-update. Returns an error text or null. */
export function subs_update_now(id) {
	let c = conf(), errs = [], done = {};
	for (let sub in c.subscriptions) if (!id || sub.id == id) {
		let e = sub_refresh(c, sub);
		if (e) push(errs, `${sub.name ?? sub.id}: ${e}`);
		done[sub.id] = sub;
	}
	return hub.locked(() => {
		let now = conf(), was = conf();
		// the downloads ran outside the lock: only the subscriptions fetched here change, and one
		// deleted meanwhile stays deleted (another download may have finished in between)
		let alive = {};
		for (let sub in now.subscriptions) alive[sub.id] = true;
		now.servers = [ ...filter(now.servers, s => !done[s.source ?? '']), ...filter(c.servers, s => done[s.source ?? ''] && alive[s.source]) ];
		for (let i, sub in now.subscriptions) if (done[sub.id]) now.subscriptions[i] = done[sub.id];
		if (now.server && now.server != 'link' && !find_server(now, now.server)) {
			now.server = length(now.servers) ? now.servers[0].id : null;
			if (!now.server) now.enabled = false;
		}
		if (!now.server && length(now.servers)) now.server = now.servers[0].id;
		store(now);
		// the VPN restarts only when the server it uses changed or went away
		let changed = now.server != was.server || sprintf('%J', find_server(now, now.server)) != sprintf('%J', find_server(was, was.server));
		if ((was.enabled && !now.enabled) || (now.enabled && changed)) apply();
		return length(errs) ? join('\n', errs) : null;
	});
}

/* add (in the background with b.background: the download can take half a minute, longer than the
   web page waits), update (always in the background), delete. */
export function subs_action(b) {
	if (b.action == 'add') {
		let url = trim(b.url ?? '');
		if (!match(url, /^https?:\/\/[^[:space:]'"]+$/) || length(url) > 1024) return 'Enter the subscription address (https://…).';
		let c = conf();
		if (length(c.subscriptions) >= MAX_SUBS) return 'The router keeps up to 10 subscriptions.';
		if (length(filter(c.subscriptions, s => s.url == url))) return 'This subscription is already in the list.';
		let sub = { id: 'sub-' + rand_hex(3), name: clean_name(b.name, match(url, /^https?:\/\/([^\/:?#]+)/)?.[1]), url, updated: null, count: 0 };
		if (b.background) {
			return hub.locked(() => {
				let now = conf();
				if (length(now.subscriptions) >= MAX_SUBS) return 'The router keeps up to 10 subscriptions.';
				push(now.subscriptions, sub);
				store(now);
				subs_start(sub.id);
				return null;
			});
		}
		// the download runs outside the lock: it can take half a minute
		let err = sub_refresh(c, sub);
		if (err) return err;
		return hub.locked(() => {
			let now = conf();
			if (length(now.subscriptions) >= MAX_SUBS) return 'The router keeps up to 10 subscriptions.';
			now.servers = [ ...filter(now.servers, s => s.source != sub.id), ...filter(c.servers, s => s.source == sub.id) ];
			push(now.subscriptions, sub);
			if (!now.server && length(now.servers)) now.server = now.servers[0].id;
			store(now);
			return null;
		});
	}
	if (b.action == 'update') {
		let c = conf();
		if (b.id && !length(filter(c.subscriptions, s => s.id == b.id))) return 'That subscription is not in the list.';
		if (!length(c.subscriptions)) return 'There is no subscription to update.';
		if (!subs_running()) subs_start(b.id);
		return null;
	}
	if (b.action == 'delete') {
		return hub.locked(() => {
			let c = conf(), restart = false;
			if (!length(filter(c.subscriptions, s => s.id == b.id))) return 'That subscription is not in the list.';
			c.subscriptions = filter(c.subscriptions, s => s.id != b.id);
			c.servers = filter(c.servers, s => s.source != b.id);
			if (c.server && c.server != 'link' && !find_server(c, c.server)) {
				c.server = length(c.servers) ? c.servers[0].id : null;
				if (!c.server) c.enabled = false;
				restart = true;
			}
			store(c);
			// after the settings are stored: the restart reads them
			if (restart) apply();
			return null;
		});
	}
	return 'Unknown action.';
}

/* For miwrt-tunnel subs-update: marks the attempt, fetches, says it is done. */
export function subs_update_job(id) {
	mkdir(RUN);
	writefile(SUBS_JOB, '');
	hub.locked(() => {
		let now = conf();
		for (let s in now.subscriptions) if (!id || s.id == id) s.tried = time();
		store(now);
	});
	let err = subs_update_now(id);
	unlink(SUBS_JOB);
	return err;
}

/* Daily refresh of subscriptions, from the 30 s pass. */
export function subs_due() {
	let c = conf();
	for (let s in c.subscriptions) if (time() - (s.updated ?? 0) > 86400 && time() - (s.tried ?? 0) > 3600) return true;
	return false;
}

/* Starts a test of the servers (all, or the ids in b.ids) in the background. */
export function test(b) {
	if (!engine_installed()) return 'Install Xray first.';
	let t = hub.load(TESTS, null);
	if (t?.running && time() - (t.time ?? 0) < 120) return null;
	let ids = (type(b?.ids) == 'array') ? filter(b.ids, i => type(i) == 'string' && match(i, /^[0-9a-f]{1,16}$/)) : null;
	hub.save(TESTS, { running: true, time: time(), results: t?.results ?? {} });
	system(`(${TOOL} test ${ids ? q(join(',', ids)) : ''}) >/dev/null 2>&1 </dev/null &`);
	return null;
}

/* For miwrt-tunnel test: one Xray with a SOCKS port per server, then one request through each. */
export function run_tests(ids) {
	let c = conf();
	let list = filter(c.servers, s => !ids || index(ids, s.id) >= 0);
	let mem = connect().call('system', 'info')?.memory?.total ?? 0;
	list = slice(list, 0, mem < 200 * 1048576 ? 12 : 40);
	let t = hub.load(TESTS, null) ?? {};
	let results = t.results ?? {};
	if (length(list)) {
		let cfg = { log: { loglevel: 'none' }, inbounds: [], outbounds: [], routing: { rules: [] } };
		for (let i, s in list) {
			push(cfg.inbounds, { tag: `t${i}`, listen: '127.0.0.1', port: 20100 + i, protocol: 'socks' });
			push(cfg.outbounds, outbound(s, `o${i}`));
			push(cfg.routing.rules, { type: 'field', inboundTag: [ `t${i}` ], outboundTag: `o${i}` });
		}
		mkdir(DIR);
		let f = DIR + '/test.json';
		writefile(f, '');
		system([ 'chmod', '600', f ]);
		writefile(f, sprintf('%J', cfg));
		let env = mem < 200 * 1048576 ? 'GOMEMLIMIT=40MiB GOGC=50 ' : '';
		let pid = trim(hub.run(`${env}${XRAY} run -c ${f} >/dev/null 2>&1 </dev/null & echo $!`));
		// ready when the last test port listens (the BE7000 first unpacks Xray), at most 15 seconds; only a
		// listening socket counts (local port, no remote end, state 0A), not an old connection to that port
		let last = sprintf(':%04X 00000000:0000 0A ', 20100 + length(list) - 1);
		// (BusyBox's sleep on both routers takes whole seconds only)
		for (let i = 0; i < 15; i++) {
			if (index(readfile('/proc/net/tcp') ?? '', last) >= 0) break;
			system('sleep 1');
		}
		let cmd = '';
		for (let i, s in list)
			cmd += `(curl -s -o /dev/null -m 10 -x socks5h://127.0.0.1:${20100 + i} -w '${i} %{http_code} %{time_total}\\n' https://www.gstatic.com/generate_204 || echo '${i} 000 0') &\n`;
		let out = hub.run(cmd + 'wait');
		if (match(pid, /^[0-9]+$/)) system(`kill ${pid} 2>/dev/null`);
		unlink(f);
		for (let line in split(out, '\n')) {
			let m = match(line, /^([0-9]+) ([0-9]+) ([0-9.]+)/);
			if (!m || !list[+m[1]]) continue;
			let id = list[+m[1]].id;
			results[id] = (m[2] == '204') ? { ms: int(+m[3] * 1000), time: time() } : { error: 'No answer', time: time() };
		}
	}
	hub.save(TESTS, { running: false, time: time(), results });
}

// ---------- the link between two routers ----------

/* x25519 keys from Xray: { priv, pub }. */
function reality_keys() {
	let out = hub.run(`${XRAY} x25519 2>/dev/null`);
	let priv = match(out, /PrivateKey:\s*([A-Za-z0-9_-]{43})/)?.[1];
	let pub = match(out, /(Password|PublicKey)[^:]*:\s*([A-Za-z0-9_-]{43})/)?.[2];
	return (priv && pub) ? { priv, pub } : null;
}

function wan_ipv4() {
	let st = connect().call('network.interface.wan', 'status') ?? {};
	return (st['ipv4-address'] ?? [])[0]?.address;
}

function public_v4(a) {
	let n = ip2int(a);
	if (n == null) return false;
	for (let c in PRIVATE_V4) { let x = cidr_net(c); if ((n & x.mask) == x.net) return false; }
	return true;
}

/* The code the other router takes: where to meet and the two IDs it uses, plus this side's networks
   when they are shared. */
function link_code(l) {
	let p = l.peer;
	return 'miwrt-link:' + b64url(sprintf('%J', { v: 1, h: p.host, p: p.port, sni: p.sni, pbk: p.pbk, sid: p.sid,
		r: l.ids.in_rev, u: l.ids.in_use, n: l.name, lans: l.share_lan ? l.lans : [] }));
}

/* The answer code the inside router shows: its own networks, for the exit to reach them. */
function answer_code(l) {
	return 'miwrt-link-answer:' + b64url(sprintf('%J', { v: 1, n: l.name, lans: l.share_lan ? l.lans : [] }));
}

function decode_code(code, prefix) {
	code = replace(trim(code ?? ''), /\s+/g, '');
	if (substr(code, 0, length(prefix)) != prefix) return null;
	try { let o = json(b64any(substr(code, length(prefix)))); return type(o) == 'object' ? o : null; } catch (e) { return null; }
}

function check_overlap(mine, theirs) {
	for (let a in mine) for (let b in theirs) if (cidrs_overlap(a, b))
		return `Both homes use the network ${a}. Change the address range of one router (Network, Interfaces, lan) to share the networks.`;
	return null;
}

/* The relay server's configuration (exit, meeting point "relay"): Xray on any server abroad. */
export function relay_config(l) {
	l = l ?? conf().link;
	if (l?.role != 'exit' || l.meet != 'relay') return null;
	let ids = l.ids;
	return {
		log: { loglevel: 'warning' },
		inbounds: [ { tag: 'meet', port: l.peer.port, protocol: 'vless',
			settings: { decryption: 'none', clients: [
				{ id: ids.exit_rev, flow: 'xtls-rprx-vision', email: 'exit-rev', reverse: { tag: 'to-exit' } },
				{ id: ids.exit_use, flow: 'xtls-rprx-vision', email: 'exit-use' },
				{ id: ids.in_rev, flow: 'xtls-rprx-vision', email: 'in-rev', reverse: { tag: 'to-inside' } },
				{ id: ids.in_use, flow: 'xtls-rprx-vision', email: 'in-use' } ] },
			streamSettings: { network: 'raw', security: 'reality',
				realitySettings: { target: `${l.relay.target}:443`, serverNames: [ l.relay.target ], privateKey: l.relay.priv, shortIds: [ l.peer.sid ] } } } ],
		outbounds: [ { tag: 'block', protocol: 'blackhole' } ],
		routing: { rules: [
			{ type: 'field', user: [ 'in-use' ], outboundTag: 'to-exit' },
			{ type: 'field', user: [ 'exit-use' ], outboundTag: 'to-inside' },
			{ type: 'field', inboundTag: [ 'meet' ], outboundTag: 'block' } ] }
	};
}

function public_link(l) {
	if (!l) return null;
	let out = { role: l.role, meet: l.meet, name: l.name, peer_name: l.peer_name, share_lan: !!l.share_lan, lans: l.lans,
		peer_lans: l.peer_lans ?? [], address: l.peer?.host, port: l.peer?.port, internet: l.internet !== false,
		created: l.created, health: hub.load(RUN + '/link-health.json', null) };
	if (l.role == 'exit') out.code = link_code(l);
	if (l.role == 'inside') out.answer = answer_code(l);
	if (l.role == 'exit' && l.meet == 'relay') out.relay_target = l.relay.target;
	return out;
}

export function link_state() {
	let c = conf(), l = c.link;
	let wan = wan_ipv4();
	return { engine: engine_installed(), link: public_link(l), lans: lan_cidrs(), wan_public: public_v4(wan), wan_address: public_v4(wan) ? wan : null,
		targets: REALITY_TARGETS };
}

/* The port forward from the internet to the link's own server (only when this router is the
   meeting point). null port removes it. */
function link_firewall(port) {
	let cur = cursor();
	if (port == null) {
		cur.delete('firewall', 'miwrt_link');
		cur.commit('firewall');
		system('(/etc/init.d/firewall reload) >/dev/null 2>&1 </dev/null &');
		return null;
	}
	let clash = null;
	cur.foreach('firewall', 'redirect', r => {
		if (r['.name'] != 'miwrt_link' && r.src == 'wan' && `${r.src_dport}` == `${port}`) clash = r.name ?? 'another port forward';
	});
	if (clash) return `Port ${port} is already forwarded (${clash}). Choose another port.`;
	cur.set('firewall', 'miwrt_link', 'redirect');
	cur.set('firewall', 'miwrt_link', 'name', 'MiWRT router link');
	cur.set('firewall', 'miwrt_link', 'src', 'wan');
	cur.set('firewall', 'miwrt_link', 'proto', 'tcp');
	cur.set('firewall', 'miwrt_link', 'src_dport', `${port}`);
	cur.set('firewall', 'miwrt_link', 'dest_port', `${LINK_LOCAL_PORT}`);
	cur.set('firewall', 'miwrt_link', 'target', 'DNAT');
	cur.commit('firewall');
	system('(/etc/init.d/firewall reload) >/dev/null 2>&1 </dev/null &');
	return null;
}

/* create (this router is the exit), join (with the exit's code), answer (the inside's answer at the
   exit), set (share the home network or not; use for internet), remove. */
export function link_action(b) {
	// a link can always be removed, also after Xray was
	if (!engine_installed() && b.action != 'remove') return 'Install Xray first: the router link runs on it.';
	return hub.locked(() => {
		let c = conf(), l = c.link;
		if (b.action == 'create') {
			if (l) return 'This router already has a link. Remove it first.';
			let meet = b.meet == 'self' ? 'self' : 'relay';
			let port = +(b.port ?? 443);
			if (!port_ok(port)) return 'Choose a port between 1 and 65535.';
			let target = b.target ?? REALITY_TARGETS[0];
			if (index(REALITY_TARGETS, target) < 0) return 'Choose one of the listed sites.';
			let host = lc(trim(b.host ?? ''));
			if (meet == 'self' && !length(host)) {
				let w = wan_ipv4();
				if (!public_v4(w)) return 'This router has no public internet address, so the other router cannot reach it. Use a server you rent as the meeting point.';
				host = w;
			}
			if (!host_ok(host)) return meet == 'self' ? 'Enter this router\'s public address or its name.' : 'Enter the address of the server you rent.';
			let k = reality_keys();
			if (!k) return 'Xray could not make the keys.';
			let lans = lan_cidrs();
			l = { role: 'exit', meet, name: clean_name(b.name, 'Router abroad'), peer_name: null, share_lan: !!b.share_lan, lans,
				peer_lans: [], created: time(),
				ids: { exit_rev: uuid(), exit_use: uuid(), in_rev: uuid(), in_use: uuid() },
				peer: { host, port, sni: target, pbk: k.pub, sid: rand_hex(4) } };
			if (meet == 'self') l.self = { priv: k.priv, target, sid: l.peer.sid };
			else l.relay = { priv: k.priv, target };
			c.link = l;
			let err = write_config(c);
			if (err) return err;
			if (meet == 'self') {
				let ferr = link_firewall(port);
				if (ferr) return ferr;
			}
			store(c);
			hub.add_alert('internet', 'Router link created', 'Give the link code to the other router.', 'info');
			apply();
			return null;
		}
		if (b.action == 'join') {
			let o = decode_code(b.code, 'miwrt-link:');
			if (!o || o.v != 1 || !host_ok(o.h) || !port_ok(o.p) || !match(o.pbk ?? '', /^[A-Za-z0-9_-]{43}$/) || !match(o.r ?? '', /^[0-9a-f-]{36}$/) || !match(o.u ?? '', /^[0-9a-f-]{36}$/))
				return 'This is not a valid router link code.';
			let peer_lans = filter(type(o.lans) == 'array' ? o.lans : [], cidr_ok);
			if (l) {
				// the same link's code again (the router abroad shares its network now, or moved): taken over
				if (l.role != 'inside' || l.ids?.in_rev != o.r || l.ids?.in_use != o.u) return 'This router already has a link. Remove it first.';
				if (length(peer_lans) && l.share_lan) { let e = check_overlap(lan_cidrs(), peer_lans); if (e) return e; }
				l.peer = { host: o.h, port: +o.p, sni: o.sni, pbk: o.pbk, sid: o.sid ?? '' };
				l.peer_name = clean_name(o.n, l.peer_name ?? 'Router abroad');
				l.peer_lans = check_overlap(lan_cidrs(), peer_lans) ? [] : peer_lans;
				let err = write_config(c);
				if (err) return err;
				store(c);
				apply();
				return null;
			}
			let lans = lan_cidrs();
			if (length(peer_lans) && b.share_lan) { let e = check_overlap(lans, peer_lans); if (e) return e; }
			l = { role: 'inside', meet: null, name: clean_name(b.name, 'Router at home'), peer_name: clean_name(o.n, 'Router abroad'),
				share_lan: !!b.share_lan, lans, peer_lans, created: time(), internet: true,
				ids: { in_rev: o.r, in_use: o.u }, peer: { host: o.h, port: +o.p, sni: o.sni, pbk: o.pbk, sid: o.sid ?? '' } };
			if (length(peer_lans) && check_overlap(lans, peer_lans)) l.peer_lans = [];
			c.link = l;
			let err = write_config(c);
			if (err) return err;
			store(c);
			hub.add_alert('internet', 'Router link joined', `Linked with ${l.peer_name}.`, 'info');
			apply();
			return null;
		}
		if (!l) return 'This router has no link.';
		if (b.action == 'answer') {
			if (l.role != 'exit') return 'Only the router abroad takes an answer code.';
			let o = decode_code(b.code, 'miwrt-link-answer:');
			if (!o || o.v != 1) return 'This is not a valid answer code.';
			let peer_lans = filter(type(o.lans) == 'array' ? o.lans : [], cidr_ok);
			let e = check_overlap(lan_cidrs(), peer_lans);
			if (e) return e;
			l.peer_lans = peer_lans;
			l.peer_name = clean_name(o.n, l.peer_name ?? 'Router at home');
		} else if (b.action == 'set') {
			if ('share_lan' in b) {
				l.share_lan = !!b.share_lan;
				l.lans = lan_cidrs();
				if (l.share_lan && l.role == 'inside') { let e = check_overlap(l.lans, l.peer_lans ?? []); if (e) return e; }
			}
			if ('internet' in b && l.role == 'inside') {
				l.internet = !!b.internet;
				if (!l.internet && c.server == 'link') { c.enabled = false; c.server = length(c.servers) ? c.servers[0].id : null; }
			}
			if ('name' in b) l.name = clean_name(b.name, l.name);
		} else if (b.action == 'remove') {
			if (l.role == 'exit' && l.meet == 'self') link_firewall(null);
			c.link = null;
			if (c.server == 'link') { c.enabled = false; c.server = length(c.servers) ? c.servers[0].id : null; }
			if (engine_installed() && wanted(c)) { let err = write_config(c); if (err) return err; }
			store(c);
			unlink(RUN + '/link-health.json');
			hub.add_alert('internet', 'Router link removed', '', 'info');
			apply();
			return null;
		} else return 'Unknown action.';
		let err = write_config(c);
		if (err) return err;
		store(c);
		apply();
		return null;
	});
}

/* Is the other router reachable through the link? From the 30 s pass, every two minutes. */
export function link_check() {
	let c = conf();
	if (!c.link || !service_running()) return null;
	let h = hub.load(RUN + '/link-health.json', null);
	if (h && time() - h.time < 120) return h;
	let r;
	if (c.link.role == 'inside') r = check(LINK_SOCKS);
	else if (length(c.link.peer_lans ?? [])) {
		// the inside router answers this name itself when its side is up (see link-ping)
		let out = hub.run(`curl -s -m 10 -o /dev/null -w '%{http_code} %{time_total}' -x socks5h://127.0.0.1:${LINK_SOCKS} http://${LINK_PING}/ 2>/dev/null`);
		let m = match(out, /^([0-9]{3}) ([0-9.]+)/);
		r = (m && m[1] != '000') ? { ok: true, time: time(), ms: int(+m[2] * 1000) } : { ok: false, time: time(), error: 'The other router does not answer.' };
	}
	else r = { ok: null, time: time() };
	let was = h?.ok;
	hub.save(RUN + '/link-health.json', r);
	if (was != null && r.ok != null && was != r.ok)
		hub.locked(() => hub.add_alert('internet', r.ok ? 'Router link is back' : 'Router link is down', r.ok ? '' : 'The other router cannot be reached through the link.', r.ok ? 'info' : 'warning'));
	return r;
}

/* From the 30 s pass: when a check is due, it runs in the background (it can take a few seconds). */
export function tick() {
	if (!access(CONF)) return;
	let c = conf();
	let due = subs_due();
	if (service_running()) {
		if (vpn_target(c)) {
			let h = hub.load(HEALTH, null);
			if (!h || time() - h.time >= (h.ok === false ? 30 : 120)) due = true;
		}
		if (c.link && older(RUN + '/link-health.json', 120)) due = true;
	}
	if (due && older(RUN + '/tunnel-tick', 25)) {
		writefile(RUN + '/tunnel-tick', '');
		system(`(${TOOL} watch) >/dev/null 2>&1 </dev/null &`);
	}
}

/* miwrt-tunnel watch: checks the tunnel and the link and says when one stops or starts working. */
export function watch() {
	let c = conf();
	if (vpn_target(c) && service_running()) {
		let prev = hub.load(HEALTH, null), h = health(prev && prev.ok === false && time() - prev.time >= 30);
		if (prev && h && prev.ok != h.ok && h.time != prev.time)
			hub.locked(() => hub.add_alert('internet', h.ok ? 'VPN works again' : 'VPN is not working', h.ok ? `Sites see ${h.exit_ip}.` : 'The VPN server does not answer. Devices that use the VPN have no internet until it answers or the VPN is switched off.', h.ok ? 'info' : 'warning'));
	}
	link_check();
	if (subs_due() && !subs_running()) subs_start(null);
}
