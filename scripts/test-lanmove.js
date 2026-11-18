#!/usr/bin/env node
// Checks of overlay-files/www/luci-static/resources/preload/lanmove.js, the
// LuCI class that follows the router to a new LAN address.
//
//   node scripts/test-lanmove.js
//
// The class is loaded the way LuCI loads it (a function body that returns the
// class), with stand-ins for LuCI's ui.changes, rpc, the page address, the
// clock, timers and fetch. Nothing here talks to a router.

'use strict';

const fs = require('fs');
const path = require('path');

const SRC = fs.readFileSync(path.join(__dirname, '..',
	'overlay-files/www/luci-static/resources/preload/lanmove.js'), 'utf8');

String.prototype.format = function() {
	let i = 0;
	const a = arguments;
	return this.replace(/%[sd]/g, () => String(a[i++]));
};

let failed = 0;
function check(cond, what) {
	if (!cond) {
		failed++;
		console.log('FAIL: ' + what);
	}
}

const flush = () => new Promise(r => setImmediate(r));

// One loaded copy of the class with everything around it.
function world(opt) {
	opt = opt ?? {};

	const w = {
		now: 1000000,
		timers: [],
		seq: 0,
		calls: [],
		fetches: [],
		rpcCalls: [],
		navigated: null,
		dump: opt.dump ?? [ { interface: 'lan', 'ipv4-address': [ { address: '192.168.1.1', mask: 24 } ] } ],
		section: ('section' in opt) ? opt.section : { proto: 'static', ipaddr: '192.168.5.1', netmask: '255.255.255.0' },
		rpcMode: opt.rpcMode ?? 'ok',
		// what the next fetch does: { after: ms, ok: bool } or 'hang'
		fetchPlan: [],
		// the same per host, when the plan above is empty
		fetchByHost: {},
		fetchDefault: opt.fetchDefault ?? { after: 20, ok: true }
	};

	const location = {
		protocol: opt.protocol ?? 'http:',
		hostname: opt.hostname ?? '192.168.1.1',
		port: opt.port ?? '',
		pathname: opt.pathname ?? '/cgi-bin/luci/admin/network/network',
		search: opt.search ?? ''
	};

	Object.defineProperty(location, 'href', {
		get() { return 'unused'; },
		set(v) { w.navigated = v; }
	});

	w.window = {
		location,
		navigator: { onLine: opt.onLine ?? true },
		setTimeout(fn, ms, ...args) {
			const t = { id: ++w.seq, at: w.now + (ms || 0), fn, args };
			w.timers.push(t);
			return t.id;
		},
		clearTimeout(id) {
			w.timers = w.timers.filter(t => t.id !== id);
		},
		fetch(url, init) {
			const host = /^https?:\/\/([^/:]+)/.exec(url)?.[1];
			const plan = w.fetchPlan.length ? w.fetchPlan.shift() : (w.fetchByHost[host] ?? w.fetchDefault);
			const rec = { url, init, at: w.now, plan, aborted: false };
			w.fetches.push(rec);

			return new Promise((resolve, reject) => {
				if (init.signal)
					init.signal.addEventListener('abort', () => { rec.aborted = true; reject(new Error('aborted')); });

				if (plan === 'hang')
					return;

				w.window.setTimeout(() => plan.ok ? resolve({ type: 'opaque', status: 0 }) : reject(new TypeError('Failed to fetch')), plan.after);
			});
		}
	};

	w.DateStub = { now: () => w.now };

	// run timers up to "ms" from now, in order, letting promises settle
	w.advance = async function(ms) {
		const end = w.now + ms;

		await flush();

		for (;;) {
			const due = w.timers.filter(t => t.at <= end).sort((a, b) => a.at - b.at || a.id - b.id)[0];

			if (!due)
				break;

			w.timers = w.timers.filter(t => t !== due);
			w.now = Math.max(w.now, due.at);
			due.fn.apply(null, due.args);
			await flush();
		}

		w.now = end;
		await flush();
	};

	const changes = opt.noChanges ? undefined : {
		changes: ('pending' in opt) ? opt.pending : { network: [ [ 'set', 'lan', 'ipaddr', '192.168.5.1' ] ] },
		confirm_auth: { token: opt.token ?? 'abc123' },
		apply(checked) { w.calls.push([ 'apply', checked, this === changes ]); },
		confirm(checked, deadline, override) { w.calls.push([ 'confirm', checked, deadline, override, this === changes ]); },
		displayStatus(type, content) { w.calls.push([ 'status', type, content, this === changes ]); }
	};

	if (changes && opt.breakChanges)
		delete changes.confirm;

	w.changes = changes;
	w.stock = changes ? { apply: changes.apply, confirm: changes.confirm, displayStatus: changes.displayStatus } : null;

	const rpc = {
		declare(spec) {
			return function() {
				w.rpcCalls.push([ spec.object, spec.method, Array.from(arguments) ]);

				if (w.rpcMode == 'fail')
					return Promise.reject(new Error('rpc'));

				if (w.rpcMode == 'hang')
					return new Promise(() => {});

				if (w.rpcMode == 'throw')
					throw new Error('rpc');

				return Promise.resolve(spec.object == 'uci' ? w.section : w.dump);
			};
		}
	};

	const L = {
		isObject: v => v !== null && typeof(v) == 'object',
		bind: (fn, self, ...args) => fn.bind(self, ...args),
		url: (...parts) => '/cgi-bin/luci/' + parts.join('/'),
		env: { apply_holdoff: opt.holdoff ?? 4 }
	};

	// as LuCI's E(): the second argument is the attributes, or already the content
	const E = (tag, attrs, children) => {
		const plain = attrs !== null && typeof(attrs) == 'object' && !Array.isArray(attrs) && !('tag' in attrs);
		return plain ? { tag, attrs, children } : { tag, attrs: {}, children: attrs };
	};
	const baseclass = { extend(proto) { function C() { this.__init__(); } C.prototype = proto; return C; } };

	w.load = function() {
		const Cls = new Function('baseclass', 'ui', 'rpc', 'L', 'E', '_', 'window', 'Date', SRC)(
			baseclass, { changes }, rpc, L, E, s => s, w.window, w.DateStub);
		return new Cls();
	};

	w.inst = w.load();
	w.callsOf = name => w.calls.filter(c => c[0] == name);
	w.text = node => {
		if (node == null) return '';
		if (typeof(node) == 'string') return node;
		if (Array.isArray(node)) return node.map(w.text).join('');
		return w.text(node.children) + (node.attrs?.href ? ' [' + node.attrs.href + ']' : '');
	};

	return w;
}

async function lookupIs(opt, want, what) {
	const w = world(opt);
	let got;

	try { got = await w.inst.lookup(opt.here ?? '192.168.1.1'); }
	catch (e) { got = 'threw'; }

	check(got === want, `lookup, ${what}: got ${JSON.stringify(got)}, expected ${JSON.stringify(want)}`);
}

async function main() {
	// --- which address the router gets -------------------------------------
	await lookupIs({}, '192.168.5.1', 'a new address');
	await lookupIs({ section: { proto: 'static', ipaddr: '192.168.5.1/24' } }, '192.168.5.1', 'address with a prefix');
	await lookupIs({ section: { proto: 'static', ipaddr: [ '192.168.5.1/24', '10.0.0.1/8' ] } }, '192.168.5.1', 'a list of addresses');
	await lookupIs({ section: { proto: 'static', ipaddr: [ '10.0.0.1/8', '192.168.1.1/24' ] } }, null, 'the address stays in the list');
	await lookupIs({ section: { proto: 'static', ipaddr: '192.168.1.1', netmask: '255.255.0.0' } }, null, 'only the netmask changes');
	await lookupIs({ section: { proto: 'static', ipaddr: '192.168.001.001' } }, null, 'the same address written differently');
	await lookupIs({ section: { proto: 'dhcp' } }, null, 'the interface goes to DHCP');
	await lookupIs({ section: { proto: 'dhcp', ipaddr: '192.168.5.1' } }, null, 'the interface goes to DHCP and an old address option is left');
	await lookupIs({ section: { proto: 'static', ipaddr: '192.168.5.1', disabled: '1' } }, null, 'the interface is switched off');
	await lookupIs({ section: { proto: 'static' } }, null, 'no address set');
	await lookupIs({ section: { proto: 'static', ipaddr: 'abc' } }, null, 'not an address');
	await lookupIs({ section: { proto: 'static', ipaddr: '999.1.1.1' } }, null, 'an impossible address');
	await lookupIs({ section: { proto: 'static', ipaddr: 'fd00::1/64' } }, null, 'an IPv6 address');
	await lookupIs({ section: null }, null, 'no such section');
	await lookupIs({ here: '203.0.113.7' }, null, 'the page address is not the router\'s');
	await lookupIs({ dump: [
		{ interface: 'lan', 'ipv4-address': [ { address: '192.168.1.1' } ] },
		{ interface: 'lan2', 'ipv4-address': [ { address: '192.168.1.1' } ] } ] }, null, 'two interfaces with the address');
	await lookupIs({ dump: [
		{ interface: 'wan', 'ipv4-address': [ { address: '100.64.0.2' } ] },
		{ interface: 'loopback', 'ipv4-address': [ { address: '127.0.0.1' } ] },
		{ interface: 'guest' },
		{ interface: 'lan', 'ipv4-address': [ { address: '192.168.1.1' } ] } ] }, '192.168.5.1', 'among other interfaces');
	await lookupIs({ dump: 'nonsense' }, null, 'a strange answer');

	{
		const w = world({});
		await w.inst.lookup('192.168.1.1');
		const g = w.rpcCalls.find(c => c[0] == 'uci');
		check(g && g[1] == 'get' && g[2][0] == 'network' && g[2][1] == 'lan', 'lookup reads the pending settings of the interface that has the address');
	}

	// --- apply ----------------------------------------------------------------
	{
		// opened by name: LuCI as it is, at once
		const w = world({ hostname: 'router.lan' });
		w.changes.apply(true);
		check(w.callsOf('apply').length == 1 && w.callsOf('apply')[0][1] === true && w.callsOf('apply')[0][2], 'apply by name goes straight to LuCI');
		check(w.rpcCalls.length == 0, 'apply by name asks the router nothing');
		w.changes.confirm(true, w.now + 90000);
		await w.advance(30000);
		check(w.fetches.length == 0 && w.navigated == null, 'apply by name follows nowhere');
	}
	{
		const w = world({ hostname: '[fd00::1]' });
		w.changes.apply(true);
		check(w.callsOf('apply').length == 1 && w.rpcCalls.length == 0, 'apply over IPv6 goes straight to LuCI');
	}
	{
		// nothing waits for the network settings
		const w = world({ pending: { firewall: [ [ 'set', 'x', 'y', 'z' ] ] } });
		w.changes.apply(true);
		check(w.callsOf('apply').length == 1 && w.rpcCalls.length == 0, 'apply without network changes goes straight to LuCI');
	}
	{
		const w = world({});
		w.changes.apply(true);
		check(w.callsOf('apply').length == 0, 'apply waits for the lookup');
		await w.advance(0);
		const a = w.callsOf('apply');
		check(a.length == 1 && a[0][1] === true && a[0][2], 'apply reaches LuCI with its argument and its object');
		check(w.rpcCalls.length == 2, 'apply looked the address up');
		w.changes.confirm(true, w.now + 90000);
		check(w.inst.currentMove()?.target == '192.168.5.1', 'the move knows the new address');
		check(w.callsOf('confirm').length == 1 && w.callsOf('confirm')[0][4], 'confirm reaches LuCI');
	}
	{
		// the list of pending changes is not known (apply from a page that just loaded): look anyway
		const w = world({ pending: undefined });
		w.changes.apply(true);
		await w.advance(0);
		check(w.rpcCalls.length == 2 && w.callsOf('apply').length == 1, 'apply with an unknown change list looks the address up');
	}
	for (const mode of [ 'fail', 'throw' ]) {
		const w = world({ rpcMode: mode });
		w.changes.apply(true);
		await w.advance(0);
		check(w.callsOf('apply').length == 1, `apply goes on when the lookup fails (${mode})`);
		w.changes.confirm(true, w.now + 90000);
		check(w.inst.currentMove() == null, `no move after a failed lookup (${mode})`);
	}
	{
		const w = world({ rpcMode: 'hang' });
		w.changes.apply(false);
		await w.advance(2900);
		check(w.callsOf('apply').length == 0, 'apply still waits for a slow lookup at 2.9 s');
		await w.advance(200);
		check(w.callsOf('apply').length == 1 && w.callsOf('apply')[0][1] === false, 'apply starts without the lookup after 3 s');
	}
	{
		// the address stays: nothing follows
		const w = world({ section: { proto: 'static', ipaddr: '192.168.1.1' } });
		w.changes.apply(true);
		await w.advance(0);
		w.changes.confirm(true, w.now + 90000);
		await w.advance(30000);
		check(w.inst.currentMove() == null && w.fetches.length == 0 && w.navigated == null, 'nothing follows when the address stays');
	}

	// --- confirm at the new address, then open it -----------------------------
	async function started(opt) {
		const w = world(opt);
		w.changes.apply(opt?.checked ?? true);
		await w.advance(0);
		w.deadline = w.now + 90000;
		w.changes.confirm(opt?.checked ?? true, w.deadline);
		return w;
	}

	{
		const w = await started({});
		await w.advance(3900);
		check(w.fetches.length == 0, 'no try at the new address before the router had its 4 seconds');
		await w.advance(200);
		check(w.fetches.length == 1, 'first try after 4 seconds');
		const f = w.fetches[0];
		check(f.url == 'http://192.168.5.1/cgi-bin/luci/admin/uci/confirm', 'the confirmation goes to the new address: ' + f.url);
		check(f.init.method == 'POST' && f.init.mode == 'no-cors' && f.init.credentials == 'omit', 'the confirmation is a plain cross-origin POST without cookies');
		check(f.init.headers['Content-Type'] == 'application/x-www-form-urlencoded' && f.init.body == 'token=abc123', 'the confirmation carries the token: ' + f.init.body);
		await w.advance(100);
		check(w.navigated == null, 'the page does not jump the instant the router answers');
		const last = w.callsOf('status').pop();
		check(last && /192\.168\.5\.1/.test(w.text(last[2])), 'the page says that the router answers at the new address');
		await w.advance(600);
		check(w.navigated == 'http://192.168.5.1/cgi-bin/luci/admin/network/network', 'the same page opens at the new address: ' + w.navigated);
		await w.advance(30000);
		check(w.fetches.length == 1, 'no more tries after the page was opened');
	}
	{
		const w = await started({ port: '8080', search: '?x=1', pathname: '/cgi-bin/luci/admin/network/network/lan' });
		await w.advance(5000);
		check(w.fetches[0]?.url == 'http://192.168.5.1:8080/cgi-bin/luci/admin/uci/confirm', 'the port is kept for the confirmation');
		check(w.navigated == 'http://192.168.5.1:8080/cgi-bin/luci/admin/network/network/lan?x=1', 'port, path and query are kept: ' + w.navigated);
	}
	{
		const w = await started({ token: 'a b&c=d/é' });
		await w.advance(4100);
		check(w.fetches[0]?.init.body == 'token=a%20b%26c%3Dd%2F%C3%A9', 'the token is encoded: ' + w.fetches[0]?.init.body);
	}
	{
		// apply without the safety net: nothing to confirm, the page still follows
		const w = await started({ checked: false });
		await w.advance(5000);
		check(w.fetches.length == 1 && w.fetches[0].init.body === '', 'an unchecked apply sends no token');
		check(w.navigated != null, 'an unchecked apply still opens the new address');
	}
	{
		// a token handed over by the page: LuCI is already at the right address
		const w = world({});
		w.inst.setTarget('192.168.5.1');
		w.changes.confirm(true, w.now + 90000, 'from-the-page');
		await w.advance(30000);
		const c = w.callsOf('confirm');
		check(c.length == 1 && c[0][3] == 'from-the-page', 'confirm with a token from the page reaches LuCI unchanged');
		check(w.fetches.length == 0 && w.inst.currentMove() == null, 'confirm with a token from the page follows nowhere');
		w.changes.confirm(true, w.now + 90000);
		check(w.inst.currentMove() == null, 'an address from an earlier lookup is not kept for the next confirm');
	}
	{
		// HTTP, the new address does not answer: keep trying, never jump
		const w = await started({ fetchDefault: { after: 3000, ok: false } });
		await w.advance(60000);
		check(w.fetches.length >= 15, 'tries go on while the address does not answer: ' + w.fetches.length);
		check(w.navigated == null, 'the page stays while the address does not answer');
		check(w.fetches.every((f, i) => i == 0 || f.at - w.fetches[i - 1].at >= 2000), 'tries are at least 2 seconds apart');
		await w.advance(40000);
		const n = w.fetches.length;
		check(w.inst.currentMove().done, 'the tries end when the time is up');
		await w.advance(20000);
		check(w.fetches.length == n && w.navigated == null, 'nothing more happens after the time is up');
	}
	{
		// HTTP and quick refusals (nothing listens there): never jump
		const w = await started({ fetchDefault: { after: 5, ok: false } });
		await w.advance(60000);
		check(w.navigated == null && w.fetches.length > 10, 'over HTTP quick refusals do not open the page');
	}
	{
		// answers on the fourth try
		const w = await started({});
		w.fetchPlan = [ { after: 3000, ok: false }, { after: 3000, ok: false }, { after: 3000, ok: false }, { after: 30, ok: true } ];
		await w.advance(20000);
		check(w.fetches.length == 4 && w.navigated != null, 'the page opens once the address answers');
	}
	{
		// a try that gets no answer at all is given up after 4 seconds
		const w = await started({ fetchDefault: 'hang' });
		await w.advance(4100);
		check(w.fetches.length == 1 && !w.fetches[0].aborted, 'the try is still running');
		await w.advance(3950);
		check(w.fetches[0].aborted, 'a try without an answer is given up');
		check(w.fetches.length == 1, 'the next try does not start in the same instant');
		await w.advance(300);
		check(w.fetches.length == 2, 'the next try follows a given-up one');
		await w.advance(30000);
		check(w.navigated == null, 'given-up tries do not open the page');
	}
	{
		// HTTPS: the router is there, the browser refuses its certificate
		const w = await started({ protocol: 'https:', fetchDefault: { after: 40, ok: false } });
		await w.advance(4100);
		check(w.fetches[0]?.url == 'https://192.168.5.1/cgi-bin/luci/admin/uci/confirm', 'HTTPS stays HTTPS');
		// a cable's link is down for a few seconds while the router re-reads
		// its network settings: every request fails at once then, too
		await w.advance(9500);
		check(w.fetches.length == 5 && w.navigated == null, 'quick refusals for less than ten seconds are not enough: ' + w.fetches.length);
		await w.advance(1100);
		check(w.fetches.length == 6, 'six tries were made: ' + w.fetches.length);
		check(w.navigated == 'https://192.168.5.1/cgi-bin/luci/admin/network/network', 'after ten seconds of quick refusals the page is opened for the certificate: ' + w.navigated);
	}
	{
		// HTTPS: quick refusals interrupted by a slow one start the wait again
		// (tries at 4.0 and 6.0 s, a slow one from 8.0 to 10.5 s, quick ones
		// from 10.75 s on)
		const w = await started({ protocol: 'https:', fetchDefault: { after: 40, ok: false } });
		w.fetchPlan = [ { after: 40, ok: false }, { after: 40, ok: false }, { after: 2500, ok: false } ];
		await w.advance(15000);
		check(w.fetches.length == 6 && w.navigated == null, 'a slow failure between quick ones starts the ten seconds again: ' + w.fetches.length);
		await w.advance(5500);
		check(w.navigated == null, 'and they run from the first quick refusal after it');
		await w.advance(1000);
		check(w.navigated != null, 'ten seconds of quick refusals after that open the page');
	}
	{
		// HTTPS: the address does not answer (slow failures): never jump
		const w = await started({ protocol: 'https:', fetchDefault: { after: 3000, ok: false } });
		await w.advance(100000);
		check(w.navigated == null, 'over HTTPS slow failures do not open the page');
	}
	{
		// HTTPS: the device itself is off the network
		const w = await started({ protocol: 'https:', onLine: false, fetchDefault: { after: 5, ok: false } });
		await w.advance(60000);
		check(w.navigated == null, 'quick failures while the device is offline do not open the page');
	}
	{
		// HTTPS with a certificate the browser accepts: confirmed like HTTP
		const w = await started({ protocol: 'https:' });
		await w.advance(5000);
		check(w.fetches.length == 1 && w.navigated == 'https://192.168.5.1/cgi-bin/luci/admin/network/network', 'HTTPS with an accepted certificate confirms and opens');
	}
	{
		// a second apply takes over from the first
		const w = await started({ fetchDefault: { after: 3000, ok: false } });
		await w.advance(9000);
		const first = w.inst.currentMove();
		w.section = { proto: 'static', ipaddr: '192.168.7.1' };
		w.fetchByHost = { '192.168.7.1': { after: 20, ok: true } };
		w.changes.apply(true);
		await w.advance(0);
		w.changes.confirm(true, w.now + 90000);
		const second = w.inst.currentMove();
		check(second !== first && second.target == '192.168.7.1', 'a new apply starts a new move');
		const since = w.now;
		await w.advance(30000);
		check(w.fetches.filter(f => f.at > since && /192\.168\.5\.1/.test(f.url)).length == 0, 'the earlier move stops trying');
		check(w.navigated == 'http://192.168.7.1/cgi-bin/luci/admin/network/network', 'the page opens at the address of the latest apply: ' + w.navigated);
	}
	{
		// an apply that keeps the address ends a move that was on
		const w = await started({ fetchDefault: { after: 3000, ok: false } });
		await w.advance(9000);
		w.section = { proto: 'static', ipaddr: '192.168.1.1' };
		w.changes.apply(true);
		await w.advance(0);
		w.changes.confirm(true, w.now + 90000);
		check(w.inst.currentMove() == null, 'an apply that keeps the address leaves no move');
		const since = w.now;
		const c = { tag: 'p', children: 'x' };
		w.calls.length = 0;
		w.changes.displayStatus('notice spinning', c);
		check(w.callsOf('status')[0][2] === c, 'and no note');
		await w.advance(30000);
		check(w.fetches.filter(f => f.at > since).length == 0 && w.navigated == null, 'and no more tries');
	}

	// --- what the page shows --------------------------------------------------
	{
		const w = await started({ fetchDefault: { after: 3000, ok: false } });
		w.calls.length = 0;
		w.changes.displayStatus('notice spinning', { tag: 'p', children: 'Applying…' });
		w.changes.displayStatus('notice spinning', { tag: 'p', children: 'Applying…' });
		const s = w.callsOf('status');
		check(s.length == 2 && s[0][3], 'status reaches LuCI');
		check(Array.isArray(s[0][2]) && s[0][2].length == 2 && s[0][2][0].children == 'Applying…', 'the note is added after LuCI\'s own text');
		const note = w.text(s[0][2][1]);
		check(/192\.168\.5\.1/.test(note) && /\[http:\/\/192\.168\.5\.1\/cgi-bin\/luci\/admin\/network\/network\]/.test(note), 'the note names the new address and links to it: ' + note);
		check(s[0][2][1] === s[1][2][1], 'the note is the same element every time (a click on its link survives the redraw)');
		check(!/сертификат/.test(note), 'no word about a certificate over HTTP');

		w.changes.displayStatus('notice');
		check(w.callsOf('status')[2][2] === undefined, 'a status without text stays without text');
		w.changes.displayStatus(false);
		check(w.callsOf('status')[3][1] === false && w.callsOf('status')[3][2] === undefined, 'closing the status is passed on as it is');
		w.changes.displayStatus('warning', [ 'a', 'b' ]);
		check(w.callsOf('status')[4][2].length == 3, 'a list of elements gets the note as one more');

		// the time is up and the next try has not noticed yet: LuCI's notice is already its own
		const keep = w.now;
		w.now = w.deadline + 1;
		w.calls.length = 0;
		w.changes.displayStatus('warning spinning', { tag: 'p', children: 'Failed to confirm…' });
		check(!Array.isArray(w.callsOf('status')[0][2]), 'the note ends with the time allowed, not with the next try');
		w.now = keep;

		await w.advance(95000);
		w.calls.length = 0;
		w.changes.displayStatus('warning spinning', { tag: 'p', children: 'Failed to confirm…' });
		check(!Array.isArray(w.callsOf('status')[0][2]), 'after the time is up LuCI\'s rollback notice is shown as it is');
	}
	{
		const w = await started({ protocol: 'https:', fetchDefault: { after: 3000, ok: false } });
		w.calls.length = 0;
		w.changes.displayStatus('notice spinning', { tag: 'p', children: 'x' });
		check(/сертификат/.test(w.text(w.callsOf('status')[0][2][1])), 'over HTTPS the note mentions the certificate');
	}
	{
		// no move: every status as LuCI wrote it
		const w = world({});
		const c = { tag: 'p', children: 'x' };
		w.changes.displayStatus('notice', c);
		check(w.callsOf('status')[0][2] === c, 'without a move the status is untouched');
	}

	// --- being a good guest ---------------------------------------------------
	{
		const w = world({});
		const a = w.changes.apply, c = w.changes.confirm, d = w.changes.displayStatus;
		check(a !== w.stock.apply && c !== w.stock.confirm && d !== w.stock.displayStatus, 'the three functions are wrapped');
		w.load();
		check(w.changes.apply === a && w.changes.confirm === c && w.changes.displayStatus === d, 'loading the class twice wraps once');
	}
	{
		let threw = false;
		try { world({ noChanges: true }); } catch (e) { threw = true; }
		check(!threw, 'a LuCI without ui.changes is left alone');
	}
	{
		let threw = false, w;
		try { w = world({ breakChanges: true }); } catch (e) { threw = true; }
		check(!threw && w.changes.apply === w.stock.apply && w.changes.displayStatus === w.stock.displayStatus, 'an unexpected ui.changes is left alone');
	}

	if (failed) {
		console.log(`lanmove tests: ${failed} FAILED`);
		process.exit(1);
	}

	console.log('lanmove tests: OK');
}

main().catch(e => { console.log('FAIL: the test itself broke: ' + (e && e.stack || e)); process.exit(1); });
