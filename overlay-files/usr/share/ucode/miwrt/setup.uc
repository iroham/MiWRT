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
export const ADGUARD_NEED_KB = 32 * 1024;

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
		if (f[0] == 'root') return length(f[1] ?? '') > 0 && f[1] != '*' && f[1] != '!';
	}
	return false;
}

function zones() {
	return timezones ?? {};
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
	return c.get('wireless', w.device, 'band');
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
	let mem = conn.call('system', 'info')?.memory ?? {};
	let ram_mb = int((mem.total ?? 0) / 1048576);
	let why = null;
	if (access('/usr/bin/AdGuardHome')) why = null;
	else if (ram_mb && ram_mb < 400) why = 'memory';
	else if (free < ADGUARD_NEED_KB) why = 'storage';

	return {
		state: state(),
		model: board.model, hostname: board.hostname, release: board.release?.version,
		password_set: root_password_set(),
		lang: c.get('luci', 'main', 'lang') ?? 'auto',
		zonename: c.get('system', system_sid(c), 'zonename') ?? 'UTC',
		country: radios[0]?.country ?? '',
		imported: access('/etc/.be7000_stock_imported') == true,
		mode: lan.proto == 'dhcp' ? 'ap' : 'router',
		lan: { ipaddr: split(list_of(lan.ipaddr)[0] ?? '', '/')[0], netmask: lan.netmask ?? (match(list_of(lan.ipaddr)[0] ?? '', /\/24$/) ? '255.255.255.0' : null) },
		wan: { proto: wan.proto ?? 'dhcp', username: wan.username, password: wan.password, vlan: vlan ? +vlan[1] : null,
			ipaddr: wan.ipaddr, netmask: wan.netmask, gateway: wan.gateway, dns: list_of(wan.dns), device: base, link },
		wifi: { ssid: first.ssid ?? '', ssid5: five?.ssid ?? first.ssid ?? '', key: first.key ?? '',
			encryption: first.encryption ?? 'none', split: !same, bands: map(radios, r => r.band) },
		guest: extras.guest_status(),
		iot: extras.iot_status(),
		protection: ag ? { where: ag.where ?? 'network', url: ag.url, username: ag.username } : { where: 'none' },
		adguard: { installed: access('/usr/bin/AdGuardHome') == true, available: why == null, why, free_kb: free, need_kb: ADGUARD_NEED_KB, ram_mb },
		zones: sort(keys(zones()))
	};
};

/* Checks an AdGuard Home address and login without saving anything. */
export function adguard_test(b) {
	let url = replace(trim(b?.url ?? ''), /\/+$/, '');
	if (!match(url, /^https?:\/\//)) url = 'http://' + url;
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
		if (b.guest?.on || b.iot?.on || b.protection?.where == 'router')
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
	if (!(p.where in [ 'none', 'router', 'network', 'keep' ])) return err('protection', 'Choose where ads are blocked.');

	if (type(b.password) != 'string' || length(b.password) < 8 || length(b.password) > 128 || match(b.password, /[[:cntrl:]]/))
		return err('password', 'The router password needs at least 8 characters.');
	return null;
}

function set_password(pw) {
	// the same way LuCI's own password page does it
	return system(`(echo ${shq(pw)}; sleep 1; echo ${shq(pw)}) | /bin/busybox passwd root >/dev/null 2>&1`) == 0;
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
	for (let i in [ 'wan', 'wan6' ]) { c.delete('network', i, 'disabled'); c.delete('network', i, 'auto'); }
	// a router that was an access point before: its WAN port goes back to the internet side
	let br = lan_bridge(c);
	if (br && base) c.set('network', br, 'ports', filter(list_of(c.get('network', br, 'ports')), p => p != base));
	for (let o in [ 'username', 'password', 'ipaddr', 'netmask', 'gateway', 'dns', 'service', 'ac' ]) c.delete('network', 'wan', o);
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
	if (c.get('network', 'lan', 'proto') != 'static') {
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
		set_or_delete(c, 'network', 'lan', 'dns', filter(list_of(a.dns), length));
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
		c.set('wireless', sid, 'encryption', f.security);
		c.set('wireless', sid, 'key', f.key);
		c.set('wireless', sid, 'disabled', '0');
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
	if (!is_ipv4(ip)) return;
	for (let sid in [ 'lan' ]) {
		if (c.get('dhcp', sid) != 'dhcp') continue;
		let opts = filter(list_of(c.get('dhcp', sid, 'dhcp_option')), o => !match(o, /^6,/));
		push(opts, '6,' + ip);
		c.set('dhcp', sid, 'dhcp_option', opts);
	}
	let dm = null;
	c.foreach('dhcp', 'dnsmasq', s => { dm = s['.name']; return false; });
	if (dm) {
		c.set('dhcp', dm, 'noresolv', '1');
		c.set('dhcp', dm, 'server', [ ip ]);
	}
}

function host_of(url) {
	let m = match(url ?? '', /^https?:\/\/([^:\/]+)/);
	return m ? m[1] : null;
}

/* LuCI keeps the menu, with the result of each entry's "depends", in /tmp/luci-indexcache.*.json until
   the menu files change; the setup entry depends on miwrt.setup.state, so the copy has to go. */
function drop_menu_cache() {
	system('rm -f /tmp/luci-indexcache*');
}

/* The wizard is done, or skipped: the web interface opens as usual from now on. */
export function finish() {
	let c = cursor();
	if (c.get('miwrt', 'setup') != 'setup') {
		if (!access('/etc/config/miwrt')) writefile('/etc/config/miwrt', '');
		c.load('miwrt');
		c.set('miwrt', 'setup', 'setup');
	}
	c.set('miwrt', 'setup', 'state', 'done');
	c.commit('miwrt');
	drop_menu_cache();
	return { ok: true };
};

const CONFIGS = [ 'network', 'wireless', 'dhcp', 'firewall', 'system', 'luci' ];

/* Applies the whole wizard in one go. Everything is checked before anything changes; the settings are
   saved to /etc/miwrt/setup-backup.tar.gz first. The network restarts a few seconds after the answer. */
export function apply(b) {
	let bad = validate(b);
	if (bad) return bad;

	let net_ag = null;
	if (b.protection.where == 'network') {
		let t = adguard_test(b.protection);
		if (t.error) return err('protection', t.error);
		net_ag = { provider: 'adguard', where: 'network', url: t.url, username: b.protection.username, password: b.protection.password };
	}

	mkdir(ETC); mkdir(RUN);
	if (system(`tar -czf ${BACKUP} -C / ${join(' ', map(CONFIGS, n => 'etc/config/' + n))} 2>/dev/null; chmod 600 ${BACKUP}`) != 0 && !access(BACKUP))
		return err(null, 'The router could not save a copy of its settings, so nothing was changed.');

	if (!set_password(b.password)) return err('password', 'The router did not accept the new password.');

	let c = cursor(), conn = connect();
	apply_region(c, b.region);
	let e = (b.mode == 'router') ? apply_router(c, b.wan) : apply_ap(c, b.ap);
	e = e ?? apply_wifi(c, b.wifi);
	if (b.mode == 'router') {
		e = e ?? apply_guest(c, conn, b.guest);
		e = e ?? apply_iot(c, conn, b.iot);
	}
	if (!e && net_ag && b.mode == 'router' && b.protection.handout !== false) apply_dns_handout(c, host_of(net_ag.url));
	if (!e) {
		for (let n in CONFIGS) c.save(n);
		if (system('fw4 check >/dev/null 2>&1') != 0) e = 'The router refused the new firewall settings.';
	}
	if (e) {
		for (let n in CONFIGS) c.revert(n);
		return err(null, e + ' Nothing else was changed (the new password stays).');
	}

	for (let n in CONFIGS) c.commit(n);

	if (net_ag) {
		hub.save_private(ETC + '/adblock.json', net_ag);
		unlink(RUN + '/protection.json');
	}
	if (b.mode == 'router' && b.guest?.on) {
		let s = hub.load(ETC + '/settings.json', {});
		s.guest_until = 0;
		hub.save(ETC + '/settings.json', s);
	}

	unlink(AG_JOB);
	let job = { state: 'running', step: 'network', mode: b.mode, ap_proto: b.ap?.proto, adguard: b.protection.where == 'router', time: time() };
	writefile(JOB, sprintf('%J', job));
	if (job.adguard) {
		writefile(AG_PASS, '');
		system([ 'chmod', '600', AG_PASS ]);
		writefile(AG_PASS, b.password);
	}
	finish();
	for (let init, mark in WIFI_MARKS) if (access(init)) writefile(mark, '');
	hub.add_alert('router', 'Router set up', 'With the setup assistant in the web interface.', 'info', null, true);

	system('(sleep 3; /usr/libexec/miwrt-setup-apply) >/dev/null 2>&1 </dev/null &');

	let lanip = b.mode == 'router' ? split(list_of(c.get('network', 'lan', 'ipaddr'))[0] ?? '', '/')[0] : (b.ap.proto == 'static' ? b.ap.ipaddr : null);
	return { ok: true, ssid: b.wifi.ssid, address: lanip, hostname: c.get('system', system_sid(c), 'hostname') };
};

/* What the restart after apply is doing, and the AdGuard Home install if one was asked for. */
export function job() {
	return { setup: hub.load(JOB, null), adguard: hub.load(AG_JOB, null) };
};
