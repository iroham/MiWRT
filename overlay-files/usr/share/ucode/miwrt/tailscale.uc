// MiWRT: Tailscale on the router, for the app's API and the web interface.
// The BE7000 carries the MiWRT build of Tailscale in its image, switched off; the Redmi AC2100 has
// no room in memory to spare, so there it is installed only when asked for (with compressed swap)
// and can be removed again. /usr/sbin/miwrt-tailscale does the slow work in the background.
'use strict';

import { readfile, writefile, unlink, access, mkdir } from 'fs';
import { cursor } from 'uci';
import * as hub from 'miwrt.hub';

const RUN = '/tmp/miwrt';
const JOB = RUN + '/tailscale-job.json';
const BIN = '/usr/sbin/tailscale';
const INIT = '/etc/init.d/tailscale';
export const TOOL = '/usr/sbin/miwrt-tailscale';
// what the installer added, so that removing takes exactly that away again
export const ADDED = '/etc/miwrt/tailscale-added';

function q(s) {
	return "'" + replace(`${s}`, /'/g, "'\\''") + "'";
}

export function installed() {
	return access(BIN) == true && access(INIT) == true;
}

/* In the image (cannot be removed, only switched off) or added later. */
export function in_image() {
	return access('/rom/usr/sbin/tailscaled') == true;
}

function free_kb() {
	let m = match(hub.run('df -k /overlay 2>/dev/null'), /\n\S+\s+[0-9]+\s+[0-9]+\s+([0-9]+)\s/);
	return m ? +m[1] : 0;
}

export function blocker() {
	if (installed()) return null;
	return free_kb() < 24 * 1024 ? 'storage' : null;
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

export function job_step(state, step, error) {
	mkdir(RUN);
	hub.save(JOB, { state, step, error, time: time() });
}

function job_running() {
	return job()?.state == 'running';
}

function opt(c, name, fallback) {
	return c.get('tailscale', 'settings', name) ?? fallback;
}

export function enabled() {
	return opt(cursor(), 'enabled', '0') == '1';
}

/* tailscale status --json, or null when the service is not running. */
function ts_status() {
	if (!installed()) return null;
	let out = hub.run(`${BIN} status --json 2>/dev/null`);
	try { let s = json(out); return type(s) == 'object' ? s : null; } catch (e) { return null; }
}

export function state() {
	let c = cursor(), st = enabled() ? ts_status() : null;
	let peers = [], online = 0;
	for (let k, p in (st?.Peer ?? {})) {
		if (p.Online) online++;
		push(peers, { name: p.HostName ?? p.DNSName, os: p.OS, online: !!p.Online, exit_node_option: !!p.ExitNodeOption, exit_node: !!p.ExitNode,
			addresses: p.TailscaleIPs ?? [], id: p.ID });
	}
	peers = sort(peers, (a, b) => (b.online - a.online) || (a.name < b.name ? -1 : 1));
	return {
		installed: installed(), in_image: in_image(), removable: installed() && !in_image(), blocker: blocker(), job: job(),
		enabled: enabled(),
		backend: st?.BackendState,           // NoState, NeedsLogin, NeedsMachineAuth, Starting, Running, Stopped
		auth_url: (st?.BackendState == 'NeedsLogin' && length(st?.AuthURL ?? '')) ? st.AuthURL : null,
		name: st?.Self?.HostName, tailnet: st?.CurrentTailnet?.Name, addresses: st?.Self?.TailscaleIPs ?? [],
		online: st?.Self?.Online, health: st?.Health ?? [],
		peers: slice(peers, 0, 100), peers_online: online,
		version: st?.Version ? split(st.Version, '-')[0] : null,
		settings: {
			via_vpn: opt(c, 'via_vpn', '0') == '1', advertise_lan: opt(c, 'advertise_lan', '0') == '1',
			advertise_exit: opt(c, 'advertise_exit', '0') == '1', accept_routes: opt(c, 'accept_routes', '0') == '1',
			exit_node: opt(c, 'exit_node', '')
		},
		vpn_available: access('/etc/miwrt/tunnel.json') == true
	};
}

export function install() {
	if (installed()) return 'Tailscale is already installed.';
	if (blocker() == 'storage') return 'There is not enough free storage for Tailscale.';
	return hub.locked(() => {
		if (job_running()) return null;
		job_step('running', 'download');
		system(`(${TOOL} install) >/dev/null 2>&1 </dev/null &`);
		return null;
	});
}

export function remove() {
	if (!installed()) return 'Tailscale is not installed.';
	if (in_image()) return 'Tailscale is part of this router\'s firmware. Switch it off instead.';
	return hub.locked(() => {
		if (job_running()) return 'Tailscale is still being installed. Try again in a minute.';
		job_step('running', 'remove');
		system(`(${TOOL} remove) >/dev/null 2>&1 </dev/null &`);
		return null;
	});
}

/* The "tailscale set" arguments for the saved settings. */
export function set_args(c) {
	c = c ?? cursor();
	let lan = [];
	if (opt(c, 'advertise_lan', '0') == '1') {
		let st = hub.run('ubus call network.interface.lan status 2>/dev/null');
		try {
			for (let a in (json(st)['ipv4-address'] ?? [])) {
				let p = split(a.address, '.'), bits = +a.mask;
				if (length(p) != 4 || bits < 8 || bits > 30) continue;
				let n = ((+p[0]) << 24 | (+p[1]) << 16 | (+p[2]) << 8 | +p[3]) & ((0xffffffff << (32 - bits)) & 0xffffffff);
				push(lan, sprintf('%d.%d.%d.%d/%d', (n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255, bits));
			}
		} catch (e) {}
	}
	let exitn = opt(c, 'exit_node', '');
	if (!match(exitn, /^[A-Za-z0-9.:-]*$/)) exitn = '';
	let args = [ '--accept-dns=false', `--advertise-routes=${join(',', lan)}`,
		`--advertise-exit-node=${opt(c, 'advertise_exit', '0') == '1'}`, `--accept-routes=${opt(c, 'accept_routes', '0') == '1'}`,
		`--exit-node=${exitn}` ];
	// the home network stays reachable while the router's traffic leaves through another exit node
	if (length(exitn)) push(args, '--exit-node-allow-lan-access=true');
	return args;
}

/* The firewall zone for tailscale0: the tailnet may reach the router and the home network, and use
   the router's internet when it offers itself as an exit node. */
export function firewall(on, c) {
	c = c ?? cursor();
	let changed = false;
	let set = (conf, sec, typ, vals) => {
		if (c.get(conf, sec) != typ) { c.set(conf, sec, typ); changed = true; }
		for (let k, v in vals) if (c.get(conf, sec, k) != v) { c.set(conf, sec, k, v); changed = true; }
	};
	let del = (conf, sec) => { if (c.get(conf, sec)) { c.delete(conf, sec); changed = true; } };
	if (on) {
		set('network', 'tailscale', 'interface', { proto: 'none', device: 'tailscale0' });
		set('firewall', 'miwrt_ts_zone', 'zone', { name: 'tailscale', input: 'ACCEPT', output: 'ACCEPT', forward: 'REJECT', network: [ 'tailscale' ], mtu_fix: '1' });
		set('firewall', 'miwrt_ts_lan', 'forwarding', { src: 'tailscale', dest: 'lan' });
		set('firewall', 'miwrt_lan_ts', 'forwarding', { src: 'lan', dest: 'tailscale' });
		if (opt(c, 'advertise_exit', '0') == '1') set('firewall', 'miwrt_ts_wan', 'forwarding', { src: 'tailscale', dest: 'wan' });
		else del('firewall', 'miwrt_ts_wan');
	} else {
		for (let s in [ 'miwrt_ts_zone', 'miwrt_ts_lan', 'miwrt_lan_ts', 'miwrt_ts_wan' ]) del('firewall', s);
		del('network', 'tailscale');
	}
	if (changed) {
		c.commit('network');
		c.commit('firewall');
		system('(/etc/init.d/network reload; /etc/init.d/firewall reload) >/dev/null 2>&1 </dev/null &');
	}
}

/* on/off, via_vpn, advertise_lan, advertise_exit, accept_routes, exit_node. */
export function set(b) {
	if (!installed()) return 'Install Tailscale first.';
	let c = cursor();
	if ('exit_node' in b && !(b.exit_node == '' || match(b.exit_node ?? '', /^[A-Za-z0-9.:-]{1,100}$/))) return 'That exit node is not valid.';
	let restart = false;
	for (let k in [ 'via_vpn', 'advertise_lan', 'advertise_exit', 'accept_routes' ])
		if (k in b) { let v = b[k] ? '1' : '0'; if (opt(c, k, '0') != v) { c.set('tailscale', 'settings', k, v); if (k == 'via_vpn') restart = true; } }
	if ('exit_node' in b) c.set('tailscale', 'settings', 'exit_node', b.exit_node);
	let was = enabled();
	if ('enabled' in b) c.set('tailscale', 'settings', 'enabled', b.enabled ? '1' : '0');
	c.commit('tailscale');
	let now = opt(c, 'enabled', '0') == '1';
	firewall(now, c);
	if (now && !was) {
		system(`(${INIT} enable; ${INIT} start) >/dev/null 2>&1 </dev/null &`);
		hub.locked(() => hub.add_alert('router', 'Tailscale switched on', '', 'info'));
	} else if (!now && was) {
		system(`(${INIT} stop; ${INIT} disable) >/dev/null 2>&1 </dev/null &`);
		hub.locked(() => hub.add_alert('router', 'Tailscale switched off', '', 'info'));
	} else if (now && restart) {
		system(`(${INIT} restart; sleep 3; ${TOOL} apply) >/dev/null 2>&1 </dev/null &`);
	} else if (now) {
		system(`(${TOOL} apply) >/dev/null 2>&1 </dev/null &`);
	}
	return null;
}

/* Signs in: with an auth key (tskey-auth-…) at once, otherwise Tailscale gives a sign-in address that
   GET shows as auth_url within a few seconds. */
export function login(b) {
	if (!installed() || !enabled()) return 'Switch Tailscale on first.';
	let key = trim(b?.auth_key ?? '');
	if (length(key) && !match(key, /^tskey-[A-Za-z0-9_-]{10,200}$/)) return 'That does not look like a Tailscale auth key (tskey-…).';
	let f = '';
	if (length(key)) {
		mkdir(RUN);
		f = RUN + '/ts-key';
		writefile(f, '');
		system([ 'chmod', '600', f ]);
		writefile(f, key);
	}
	system(`(${TOOL} login ${f}) >/dev/null 2>&1 </dev/null &`);
	return null;
}

export function logout() {
	if (!installed() || !enabled()) return 'Tailscale is not running.';
	system(`(${BIN} logout) >/dev/null 2>&1 </dev/null &`);
	return null;
}
