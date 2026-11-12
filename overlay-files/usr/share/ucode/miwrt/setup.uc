// MiWRT setup assistant: what the first-run wizard in the web interface shows, and the one step that
// applies all of it. Only a router set up from scratch gets the wizard (see uci-defaults 98-miwrt-setup).
'use strict';

import { readfile, writefile, unlink, access, popen, mkdir } from 'fs';
import { cursor } from 'uci';
import { connect } from 'ubus';
import * as hub from 'miwrt.hub';
import * as extras from 'miwrt.extras';
import timezones from 'luci.zoneinfo';

const ETC = '/etc/miwrt';
const RUN = '/tmp/miwrt';
const BACKUP = ETC + '/setup-backup.tar.gz';
const JOB = RUN + '/setup-job.json';
const AG_JOB = RUN + '/adguard-job.json';
const AG_PASS = RUN + '/adguard-pass';
// "Wi-Fi was set up on this router": the first-boot Wi-Fi defaults (BE7000, AC2100) leave it alone then
const WIFI_MARKS = { '/etc/init.d/be7000-wifi-defaults': '/etc/.be7000_secure_defaults',
	'/etc/init.d/miwrt-wifi-defaults': '/etc/.miwrt_wifi_defaults' };
const LANGS = [ 'auto', 'en', 'ru', 'zh_cn' ];
// AdGuard Home needs about 30 MB once installed (UBIFS compresses it to less); ask for room to spare
const ADGUARD_NEED_KB = hub.ADGUARD_NEED_KB;
const AG_TOOL = '/usr/libexec/miwrt-adguard';

function shq(s) {
	return `'${replace(s, "'", "'\\''")}'`;
}

function is_ipv4(s) {
	if (type(s) != 'string' || !match(s, /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/)) return false;
	for (let p in split(s, '.')) if (+p > 255) return false;
	return true;
}

function is_mask(s) {
	if (!is_ipv4(s)) return false;
	let n = 0;
	for (let p in split(s, '.')) n = n * 256 + +p;
	let inv = 0xffffffff - n;
	return n != 0 && ((inv & (inv + 1)) == 0);
}

function list_of(v) {
	return type(v) == 'array' ? v : (v != null ? [ v ] : []);
}

function overlay_free_kb() {
	let out = hub.run('df -k /overlay 2>/dev/null');
	let m = match(out, /\n\S+\s+[0-9]+\s+[0-9]+\s+([0-9]+)\s/);
	return m ? +m[1] : 0;
}

function root_password_set() {
	for (let l in split(readfile('/etc/shadow') ?? '', '\n')) {
		let f = split(l, ':');
		if (f[0] == 'root') return length(f[1] ?? '') > 0 && !match(f[1], /^[!*]/);
	}
	return false;
}

function zones() {
	return timezones ?? {};
}

/* Why AdGuard Home cannot be installed on this router, whatever mode the assistant is about to set:
   'unsupported' (no installer on this model), 'memory', 'storage'; null when it can. */
function adguard_blocker(ram_mb, free_kb) {
	if (!access(AG_TOOL)) return 'unsupported';
	if (ram_mb < 400) return 'memory';
	if (!access('/usr/bin/AdGuardHome') && free_kb < ADGUARD_NEED_KB) return 'storage';
	return null;
}

function ram_mb(conn) {
	return int((conn.call('system', 'info')?.memory?.total ?? 0) / 1048576);
}

function system_sid(c) {
	let sid = null;
	c.foreach('system', 'system', s => { sid = s['.name']; return false; });
	return sid;
}

// the networks the user's own devices use: access points on "lan", not the guest or IoT ones made here
function main_ifaces(c) {
	let out = [];
	c.foreach('wireless', 'wifi-iface', w => {
		if (w.mode != 'ap' || match(w['.name'], /^miwrt_(guest|iot)_/)) return;
		if (!('lan' in list_of(w.network))) return;
		push(out, w);
	});
	return out;
}

function band_of(c, w) {
	// an MLO network sits on several radios, all of them 5 GHz
	return c.get('wireless', list_of(w.device)[0], 'band');
}

function wan_base(dev) {
	return replace(dev ?? '', /\.[0-9]+$/, '');
}

function lan_bridge(c) {
	let sid = null;
	c.foreach('network', 'device', d => { if (d.name == 'br-lan') { sid = d['.name']; return false; } });
	return sid;
}

export function state() {
	return cursor().get('miwrt', 'setup', 'state') ?? 'done';
};

/* Everything the wizard fills its pages with, from the settings as they are now. On a router that took
   its settings from the factory firmware, that is the Wi-Fi and internet connection it had there. */
export function status() {
	let c = cursor(), conn = connect();
	let board = conn.call('system', 'board') ?? {};
	let wan = c.get_all('network', 'wan') ?? {};
	let lan = c.get_all('network', 'lan') ?? {};
	let wandev = wan.device ?? '';
	let vlan = match(wandev, /\.([0-9]+)$/);
	let link = null;
	let base = wan_base(wandev);
	if (base && !match(base, /^@/)) {
		let st = conn.call('network.device', 'status', { name: base });
		if (st) link = !!st.carrier;
	}

	let radios = [];
	c.foreach('wireless', 'wifi-device', r => { push(radios, { id: r['.name'], band: r.band, country: r.country }); });
	let ifaces = main_ifaces(c), first = ifaces[0] ?? {}, five = null;
	for (let w in ifaces) if (band_of(c, w) != '2g') { five = w; break; }
	let same = true;
	for (let w in ifaces) if (w.ssid != first.ssid) same = false;

	let ag = hub.load(ETC + '/adblock.json', null);
	let free = overlay_free_kb();
	let ram = ram_mb(conn);
	let why = adguard_blocker(ram, free);

	return {
		state: state(),
		model: board.model, hostname: board.hostname, release: board.release?.version,
		password_set: root_password_set(),
		lang: c.get('luci', 'main', 'lang') ?? 'auto',
		zonename: c.get('system', system_sid(c), 'zonename') ?? 'UTC',
		country: radios[0]?.country ?? '',
		imported: access('/etc/.be7000_stock_imported') == true,
		mode: hub.is_ap(c) ? 'ap' : 'router',
		lan: { ipaddr: split(list_of(lan.ipaddr)[0] ?? '', '/')[0], netmask: lan.netmask ?? (match(list_of(lan.ipaddr)[0] ?? '', /\/24$/) ? '255.255.255.0' : null) },
		wan: { proto: wan.proto ?? 'dhcp', username: wan.username, password: wan.password, vlan: vlan ? +vlan[1] : null,
			ipaddr: wan.ipaddr, netmask: wan.netmask, gateway: wan.gateway, dns: list_of(wan.dns), device: base, link },
		wifi: { ssid: first.ssid ?? '', ssid5: five?.ssid ?? first.ssid ?? '', key: first.key ?? '',
			encryption: first.encryption ?? 'none', split: !same, bands: map(radios, r => r.band) },
		guest: extras.guest_status(),
		iot: extras.iot_status(),
		protection: ag ? { where: ag.where ?? 'network', url: ag.url, username: ag.username } : { where: 'none' },
		adguard: { installed: access('/usr/bin/AdGuardHome') == true, available: why == null, why, free_kb: free, need_kb: ADGUARD_NEED_KB, ram_mb: ram },
		zones: sort(keys(zones()))
	};
};

function normal_url(u) {
	let url = replace(trim(u ?? ''), /\/+$/, '');
	return match(url, /^https?:\/\//) ? url : 'http://' + url;
}

function host_of(url) {
	let m = match(url ?? '', /^https?:\/\/([^:\/]+)/);
	return m ? m[1] : null;
}

/* Checks an AdGuard Home address and login without saving anything. */
export function adguard_test(b) {
	let url = normal_url(b?.url);
	if (!match(url, /^https?:\/\/[A-Za-z0-9.-]+(:[0-9]{1,5})?$/)) return { error: 'That address does not look right. Use something like 192.168.1.2:3000.' };
	if (type(b.username) != 'string' || !length(b.username) || type(b.password) != 'string') return { error: 'Enter the user name and password of AdGuard Home.' };
	let r = hub.ag_status({ provider: 'adguard', url, username: b.username, password: b.password });
	if (r.error) return { error: r.error };
	return { ok: true, url, version: r.version, protection_enabled: r.protection_enabled };
};

function err(field, text) {
	return { error: text, field };
}

function validate(b) {
	if (type(b) != 'object') return err(null, 'Nothing to apply.');
	let r = b.region ?? {};
	if (!(r.lang in LANGS)) return err('region', 'Choose a language.');
	if (!(r.zonename in zones())) return err('region', 'Choose a time zone.');
	if (!match(r.country ?? '', /^[A-Z]{2}$/)) return err('region', 'Choose the country the router is in.');

	if (!(b.mode in [ 'router', 'ap' ])) return err('mode', 'Choose how the router connects.');
	if (b.mode == 'router') {
		let w = b.wan ?? {};
		if (!(w.proto in [ 'dhcp', 'pppoe', 'static' ])) return err('mode', 'Choose the type of internet connection.');
		if (w.proto == 'pppoe') {
			if (type(w.username) != 'string' || !length(w.username) || length(w.username) > 128 || match(w.username, /[[:cntrl:]]/))
				return err('mode', 'Enter the user name your provider gave you.');
			if (w.password != null && (type(w.password) != 'string' || length(w.password) > 128 || match(w.password, /[[:cntrl:]]/)))
				return err('mode', 'The provider password contains characters that cannot be used.');
			if (w.vlan != null && w.vlan !== '' && (type(+w.vlan) != 'int' || +w.vlan < 1 || +w.vlan > 4094))
				return err('mode', 'A VLAN ID is a number from 1 to 4094.');
		}
		if (w.proto == 'static') {
			if (!is_ipv4(w.ipaddr)) return err('mode', 'Enter the address your provider gave you.');
			if (!is_mask(w.netmask)) return err('mode', 'Enter a subnet mask such as 255.255.255.0.');
			if (!is_ipv4(w.gateway)) return err('mode', 'Enter the gateway address.');
			for (let d in list_of(w.dns)) if (!is_ipv4(d)) return err('mode', 'A DNS server must be an IPv4 address.');
		}
	}
	else {
		let a = b.ap ?? {};
		if (!(a.proto in [ 'dhcp', 'static' ])) return err('mode', 'Choose how the router gets its address.');
		if (a.proto == 'static') {
			if (!is_ipv4(a.ipaddr)) return err('mode', 'Enter an address for the router.');
			if (!is_mask(a.netmask)) return err('mode', 'Enter a subnet mask such as 255.255.255.0.');
			if (!is_ipv4(a.gateway)) return err('mode', 'Enter the address of your main router.');
			for (let d in list_of(a.dns)) if (!is_ipv4(d)) return err('mode', 'A DNS server must be an IPv4 address.');
		}
		if (b.guest?.on || b.iot?.on || (type(b.protection) == 'object' && b.protection.where == 'router'))
			return err('mode', 'Guest and IoT networks and AdGuard Home on the router need the router mode.');
	}

	let f = b.wifi ?? {};
	if (!extras.valid_ssid(f.ssid)) return err('wifi', 'A Wi-Fi name needs 1 to 32 characters.');
	if (f.split && !extras.valid_ssid(f.ssid5)) return err('wifi', 'A Wi-Fi name needs 1 to 32 characters.');
	if (f.split && f.ssid5 == f.ssid) return err('wifi', 'Give the 5 GHz network a different name, or use one name for both.');
	if (!extras.valid_key(f.key)) return err('wifi', 'A Wi-Fi password needs 8 to 63 characters (letters, digits and common symbols).');
	if (!(f.security in [ 'sae-mixed', 'psk2' ])) return err('wifi', 'Choose the Wi-Fi security.');

	let names = [ f.ssid, f.split ? f.ssid5 : null ];
	for (let k in [ 'guest', 'iot' ]) {
		let n = b[k];
		if (!n?.on) continue;
		if (!extras.valid_ssid(n.ssid)) return err(k, 'A Wi-Fi name needs 1 to 32 characters.');
		if (!extras.valid_key(n.key)) return err(k, 'A Wi-Fi password needs 8 to 63 characters (letters, digits and common symbols).');
		if (n.ssid in names) return err(k, 'Each network needs a name of its own.');
		push(names, n.ssid);
	}

	let p = b.protection ?? { where: 'none' };
	if (type(p) != 'object' || !(p.where in [ 'none', 'router', 'network', 'keep' ])) return err('protection', 'Choose where ads are blocked.');
	if (p.where == 'router') {
		let why = adguard_blocker(ram_mb(connect()), overlay_free_kb());
		if (why) return err('protection', why == 'storage' ? 'There is not enough free storage on the router for AdGuard Home.' : 'AdGuard Home cannot be installed on this router.');
		// its own password, not the router's: it is kept where the app can use it, and typed into a page of its own
		if (type(p.password) != 'string' || length(p.password) < 8 || length(p.password) > 72 || match(p.password, /[[:cntrl:]]/))
			return err('protection', 'AdGuard Home needs a password of 8 to 72 characters.');
		if (p.password == b.password) return err('protection', 'Give AdGuard Home a password of its own, not the router\'s.');
	}
	if (p.where == 'network' && b.mode == 'router' && p.handout !== false && !is_ipv4(host_of(normal_url(p.url))))
		return err('protection', 'To make it the DNS server of your devices, enter the address of AdGuard Home as numbers, such as 192.168.1.2:3000.');

	if (type(b.password) != 'string' || length(b.password) < 8 || length(b.password) > 128 || match(b.password, /[[:cntrl:]]/))
		return err('password', 'The router password needs at least 8 characters.');
	return null;
}

function set_password(pw) {
	// the way LuCI's own password page does it, with printf: echo would take a password such as "-n" as an option
	return system(`(printf '%s\n' ${shq(pw)}; sleep 1; printf '%s\n' ${shq(pw)}) | /bin/busybox passwd root >/dev/null 2>&1`) == 0;
}

function apply_region(c, r) {
	c.set('luci', 'main', 'lang', r.lang);
	let sys = system_sid(c);
	if (sys) {
		c.set('system', sys, 'zonename', r.zonename);
		c.set('system', sys, 'timezone', zones()[r.zonename] ?? 'UTC');
	}
	c.foreach('wireless', 'wifi-device', d => { c.set('wireless', d['.name'], 'country', r.country); });
}

function set_or_delete(c, conf, sid, opt, val) {
	if (val == null || val === '' || (type(val) == 'array' && !length(val))) c.delete(conf, sid, opt);
	else c.set(conf, sid, opt, val);
}

function apply_router(c, w) {
	let base = wan_base(c.get('network', 'wan', 'device'));
	if (!base || match(base, /^@/)) return 'This router has no WAN port set up. Set the internet connection under Network, Interfaces.';
	let was_ap = hub.is_ap(c), was_pppoe = c.get('network', 'wan', 'proto') == 'pppoe';
	for (let i in [ 'wan', 'wan6' ]) { c.delete('network', i, 'disabled'); c.delete('network', i, 'auto'); }
	// a router that was an access point before: its WAN port goes back to the internet side
	let br = lan_bridge(c);
	if (br && base) set_or_delete(c, 'network', br, 'ports', filter(list_of(c.get('network', br, 'ports')), p => p != base));
	for (let o in [ 'username', 'password', 'ipaddr', 'netmask', 'gateway', 'dns', 'service', 'ac' ]) c.delete('network', 'wan', o);
	// what only a PPPoE line needed (the smaller packet size taken over from the factory firmware)
	if (was_pppoe && w.proto != 'pppoe') for (let o in [ 'mtu', 'ipv6' ]) c.delete('network', 'wan', o);
	c.set('network', 'wan', 'proto', w.proto);
	c.set('network', 'wan', 'device', (w.proto == 'pppoe' && w.vlan) ? `${base}.${+w.vlan}` : base);
	if (w.proto == 'pppoe') {
		c.set('network', 'wan', 'username', w.username);
		c.set('network', 'wan', 'password', w.password ?? '');
		c.set('network', 'wan', 'ipv6', 'auto');
	}
	if (w.proto == 'static') {
		c.set('network', 'wan', 'ipaddr', w.ipaddr);
		c.set('network', 'wan', 'netmask', w.netmask);
		c.set('network', 'wan', 'gateway', w.gateway);
		set_or_delete(c, 'network', 'wan', 'dns', filter(list_of(w.dns), length));
	}
	// a router that was an access point before: the main network gets its own address and DHCP back
	// (the IPv6 settings are left alone otherwise: OpenWrt's defaults hand out IPv6 on the LAN)
	if (was_ap) {
		for (let o in [ 'ipaddr', 'netmask', 'gateway', 'dns' ]) c.delete('network', 'lan', o);
		c.set('network', 'lan', 'proto', 'static');
		c.set('network', 'lan', 'ipaddr', '192.168.1.1');
		c.set('network', 'lan', 'netmask', '255.255.255.0');
		c.set('network', 'lan', 'ip6assign', '60');
	}
	if (c.get('dhcp', 'lan', 'ignore') == '1') {
		c.delete('dhcp', 'lan', 'ignore');
		c.set('dhcp', 'lan', 'dhcpv6', 'server');
		c.set('dhcp', 'lan', 'ra', 'server');
	}
	c.set('dhcp', 'lan', 'dhcpv4', 'server');
	return null;
}

/* Access point: the router joins the main router's network. The cable from the main router goes into
   the WAN port, which joins the LAN ports; this router hands out no addresses and routes nothing. */
function apply_ap(c, a) {
	let base = wan_base(c.get('network', 'wan', 'device'));
	let br = lan_bridge(c);
	if (!br) return 'This router has no LAN bridge to join the networks with.';
	if (base && !match(base, /^@/)) {
		let ports = list_of(c.get('network', br, 'ports'));
		if (!(base in ports)) push(ports, base);
		c.set('network', br, 'ports', ports);
	}
	for (let i in [ 'wan', 'wan6' ]) { c.set('network', i, 'disabled', '1'); c.set('network', i, 'auto', '0'); }
	for (let o in [ 'ipaddr', 'netmask', 'gateway', 'dns', 'ip6assign' ]) c.delete('network', 'lan', o);
	c.set('network', 'lan', 'proto', a.proto);
	if (a.proto == 'static') {
		c.set('network', 'lan', 'ipaddr', a.ipaddr);
		c.set('network', 'lan', 'netmask', a.netmask);
		c.set('network', 'lan', 'gateway', a.gateway);
		// without a DNS server of its own the router asks the main router, or it could not check the time or for updates
		let dns = filter(list_of(a.dns), length);
		c.set('network', 'lan', 'dns', length(dns) ? dns : [ a.gateway ]);
	}
	c.set('dhcp', 'lan', 'ignore', '1');
	c.set('dhcp', 'lan', 'dhcpv6', 'disabled');
	c.set('dhcp', 'lan', 'ra', 'disabled');
	return null;
}

function apply_wifi(c, f) {
	c.foreach('wireless', 'wifi-device', d => { c.set('wireless', d['.name'], 'disabled', '0'); });
	let ifaces = main_ifaces(c);
	if (!length(ifaces)) return 'This router has no Wi-Fi network to set up.';
	for (let w in ifaces) {
		let sid = w['.name'];
		c.set('wireless', sid, 'ssid', (f.split && band_of(c, w) != '2g') ? f.ssid5 : f.ssid);
		// a Wi-Fi 7 MLO network keeps its own security mode, which it has to have (be7000-5g-split)
		if (w.mlo != '1') c.set('wireless', sid, 'encryption', f.security);
		c.set('wireless', sid, 'key', f.key);
		// the networks MLO stands in for stay parked
		if (w.be7000_mlo_off != '1') c.set('wireless', sid, 'disabled', '0');
	}
	return null;
}

function apply_guest(c, conn, g) {
	let st = extras.guest_status();
	if (!g?.on && !st.exists) return null;
	if (!st.exists) {
		let e = extras.guest_create(c, conn, g.ssid, g.key);
		if (e) return e;
	}
	c.foreach('wireless', 'wifi-iface', w => {
		if (w.network != 'guest' || !match(w['.name'], /^miwrt_guest_/)) return;
		if (g?.on) { c.set('wireless', w['.name'], 'ssid', g.ssid); c.set('wireless', w['.name'], 'key', g.key); }
		c.set('wireless', w['.name'], 'disabled', g?.on ? '0' : '1');
	});
	return null;
}

function apply_iot(c, conn, n) {
	let st = extras.iot_status();
	if (!n?.on) {
		if (st.ours) c.foreach('wireless', 'wifi-iface', w => { if (match(w['.name'], /^miwrt_iot_/)) c.set('wireless', w['.name'], 'disabled', '1'); });
		return null;
	}
	if (!st.exists) return extras.iot_create(c, conn, { ssid: n.ssid, key: n.key, internet: n.internet !== false, all_bands: !!n.all_bands });
	if (!st.ours) return 'This router already has an IoT network of its own. Change it under Network, Wireless.';
	c.foreach('wireless', 'wifi-iface', w => {
		if (!match(w['.name'], /^miwrt_iot_/)) return;
		c.set('wireless', w['.name'], 'ssid', n.ssid);
		c.set('wireless', w['.name'], 'key', n.key);
		c.set('wireless', w['.name'], 'disabled', '0');
	});
	if (n.internet === false) c.delete('firewall', 'miwrt_iot_wan');
	else if (c.get('firewall', 'miwrt_iot_wan') != 'forwarding') {
		c.set('firewall', 'miwrt_iot_wan', 'forwarding');
		c.set('firewall', 'miwrt_iot_wan', 'src', 'iot');
		c.set('firewall', 'miwrt_iot_wan', 'dest', 'wan');
	}
	return null;
}

/* AdGuard Home elsewhere on the network: devices on the main network get it as their DNS server, so it
   sees each of them; the router (and with it the guest and IoT networks) asks it too. */
function apply_dns_handout(c, ip) {
	if (!is_ipv4(ip)) return null;
	let done = { added: [], server: ip };
	for (let sid in [ 'lan' ]) {
		if (c.get('dhcp', sid) != 'dhcp') continue;
		let opts = filter(list_of(c.get('dhcp', sid, 'dhcp_option')), o => !match(o, /^6,/));
		push(opts, '6,' + ip);
		c.set('dhcp', sid, 'dhcp_option', opts);
		push(done.added, { net: sid, option: '6,' + ip });
	}
	let dm = null;
	c.foreach('dhcp', 'dnsmasq', s => { dm = s['.name']; return false; });
	if (dm) {
		done.old_noresolv = c.get('dhcp', dm, 'noresolv');
		done.old_server = list_of(c.get('dhcp', dm, 'server'));
		c.set('dhcp', dm, 'noresolv', '1');
		c.set('dhcp', dm, 'server', [ ip ]);
	}
	return done;   // what "unlink" in the app puts back (hub.uc)
}

/* LuCI keeps the menu in /tmp/luci-indexcache.*.json until the menu files change. The page is in the
   menu at all times now (it sends a router that is set up to the overview itself), but a copy made by
   an earlier build may still say otherwise. */
function drop_menu_cache() {
	system('rm -f /tmp/luci-indexcache*');
}

/* The wizard is done, or skipped: the web interface opens as usual from now on. "verify" is set for a
   router that becomes an access point: until it has an address from the main router, a restart (a power
   cut, say) goes on checking, and puts the old settings back if none comes (miwrt-setup-apply resume). */
export function finish(verify) {
	let c = cursor();
	if (c.get('miwrt', 'setup') != 'setup') {
		if (!access('/etc/config/miwrt')) writefile('/etc/config/miwrt', '');
		c.load('miwrt');
		c.set('miwrt', 'setup', 'setup');
	}
	c.set('miwrt', 'setup', 'state', 'done');
	if (verify === true) c.set('miwrt', 'setup', 'verify', '1');
	else c.delete('miwrt', 'setup', 'verify');
	c.delete('miwrt', 'setup', 'retry');
	c.commit('miwrt');
	drop_menu_cache();
	return { ok: true };
};

const CONFIGS = [ 'network', 'wireless', 'dhcp', 'firewall', 'system', 'luci' ];

/* Applies the whole wizard in one go. Everything is checked before anything changes, and the settings
   are saved to /etc/miwrt/setup-backup.tar.gz first. The network restarts a few seconds after the answer. */
export function apply(b) {
	// the assistant is for a router that has not been set up; afterwards the same call would lock out its owner
	if (state() != 'pending') return err(null, 'This router is already set up. Change its settings in the web interface.');
	let running = hub.load(JOB, null);
	if (running?.state == 'running' && time() - (running.time ?? 0) < 180)
		return err(null, 'The router is already applying your settings. Give it a minute.');

	let bad = validate(b);
	if (bad) return bad;
	let prot = b.protection ?? { where: 'none' };

	let net_ag = null;
	if (prot.where == 'network') {
		let t = adguard_test(prot);
		if (t.error) return err('protection', t.error);
		net_ag = { provider: 'adguard', where: 'network', url: t.url, username: prot.username, password: prot.password };
	}

	mkdir(ETC); mkdir(RUN);
	if (system(`tar -czf ${BACKUP} -C / ${join(' ', map(CONFIGS, n => 'etc/config/' + n))} 2>/dev/null && chmod 600 ${BACKUP}`) != 0) {
		unlink(BACKUP);
		return err(null, 'The router could not save a copy of its settings, so nothing was changed.');
	}

	let c = cursor(), conn = connect();
	apply_region(c, b.region);
	let e = (b.mode == 'router') ? apply_router(c, b.wan) : apply_ap(c, b.ap);
	e = e ?? apply_wifi(c, b.wifi);
	if (b.mode == 'router') {
		e = e ?? apply_guest(c, conn, b.guest);
		e = e ?? apply_iot(c, conn, b.iot);
	}
	let handout = null;
	if (!e && net_ag && b.mode == 'router' && prot.handout !== false) handout = apply_dns_handout(c, host_of(net_ag.url));
	if (!e) {
		for (let n in CONFIGS) c.save(n);
		if (system('fw4 check >/dev/null 2>&1') != 0) e = 'The router refused the new firewall settings.';
	}
	// the password last of the things that can fail: nothing is kept unless everything is
	if (!e && !set_password(b.password)) e = 'The router did not accept the new password.';
	if (e) {
		for (let n in CONFIGS) c.revert(n);
		return err(null, e + ' Nothing was changed.');
	}

	for (let n in CONFIGS) c.commit(n);

	if (net_ag) {
		hub.save_private(ETC + '/adblock.json', net_ag);
		unlink(RUN + '/protection.json');
		if (handout) hub.save(hub.AG_HANDOUT, handout);
	}
	if (b.mode == 'router' && b.guest?.on) {
		let s = hub.load(ETC + '/settings.json', {});
		s.guest_until = 0;
		hub.save(ETC + '/settings.json', s);
	}

	unlink(AG_JOB);
	let job = { state: 'running', step: 'network', mode: b.mode, ap_proto: b.ap?.proto, adguard: prot.where == 'router', time: time() };
	writefile(JOB, sprintf('%J', job));
	if (job.adguard) {
		writefile(AG_PASS, '');
		system([ 'chmod', '600', AG_PASS ]);
		writefile(AG_PASS, prot.password);
	}
	finish(b.mode == 'ap');
	for (let init, mark in WIFI_MARKS) if (access(init)) writefile(mark, '');

	// from here the router has to restart its network, whatever else happens
	system('(sleep 3; /usr/libexec/miwrt-setup-apply) >/dev/null 2>&1 </dev/null &');
	try { hub.add_alert('router', 'Router set up', 'With the setup assistant in the web interface.', 'info', null, true); }
	catch (x) { warn(`miwrt-setup: ${x}\n`); }

	let lanip = b.mode == 'router' ? split(list_of(c.get('network', 'lan', 'ipaddr'))[0] ?? '', '/')[0] : (b.ap.proto == 'static' ? b.ap.ipaddr : null);
	return { ok: true, ssid: b.wifi.ssid, address: lanip, hostname: c.get('system', system_sid(c), 'hostname') };
};

/* What the restart after apply is doing, and the AdGuard Home install if one was asked for. */
export function job() {
	return { setup: hub.load(JOB, null), adguard: hub.load(AG_JOB, null) };
};
