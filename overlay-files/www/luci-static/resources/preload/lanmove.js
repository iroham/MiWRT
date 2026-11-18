'use strict';
'require baseclass';
'require ui';
'require rpc';

/*
 * Follow the router to its new address.
 *
 * LuCI applies a change with a safety net: the router takes the new settings
 * and waits for the browser to confirm that it still gets through; without
 * that it puts the old settings back. The confirmation is sent to the address
 * the page was opened at. When the change is that very address (Network,
 * Interfaces, LAN, IPv4 address), nothing answers there any more, so a change
 * that is perfectly fine was rolled back unless you typed the new address
 * into the browser yourself within the time allowed.
 *
 * This class, loaded on every LuCI page, adds the missing half. Before the
 * apply it reads the pending settings: is the address in the browser's
 * address bar an address of a router interface, and does that interface have
 * another one afterwards? If so, once the router has had time to switch, it
 * sends the confirmation to the new address and then opens the same page
 * there. The page says what is happening and offers the new address as a
 * link all the while.
 *
 * Over HTTPS with the router's own (self-signed) certificate the browser lets
 * no request through to the new address before you have accepted the
 * certificate for it. An address that keeps refusing at once is a router that
 * is there, so the page is opened and the browser asks about the certificate;
 * the login page that follows sends the confirmation (LuCI itself does that
 * on any page while a rollback is pending). "Keeps" is ten seconds: a cable's
 * link drops for a few seconds while the router re-reads its network
 * settings, and every request fails at once during that, too.
 *
 * Nothing changes when the address stays, when the page was opened by name or
 * over IPv6, or when anything here fails: LuCI then works as it always did.
 */

const callInterfaceDump = rpc.declare({
	object: 'network.interface',
	method: 'dump',
	expect: { interface: [] }
});

const callUciGet = rpc.declare({
	object: 'uci',
	method: 'get',
	params: [ 'config', 'section' ],
	expect: { values: {} }
});

/* how long the settings may be looked up before the apply starts anyway */
const LOOKUP_LIMIT = 3000;
/* pause between two tries at the new address */
const PROBE_EVERY = 2000;
/* a try that has no answer after this long is given up */
const PROBE_LIMIT = 4000;
/* a refusal quicker than this comes from a host that is there */
const REFUSED_FAST = 1000;
/* quick refusals and nothing else for this long, and the page is opened for
 * the certificate */
const REFUSED_FOR = 10000;

const state = {
	/* the address the interface gets, between the lookup and the apply */
	target: null,
	/* the move in progress */
	move: null
};

/* A dotted IPv4 address in its plain form, or null. */
function ipv4(s) {
	const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(String(s ?? '').trim());

	if (!m)
		return null;

	const parts = [];

	for (let i = 1; i <= 4; i++) {
		const n = +m[i];

		if (n > 255)
			return null;

		parts.push(n);
	}

	return parts.join('.');
}

/* The IPv4 addresses a pending "ipaddr" value names: one address, one
 * address with a prefix, or a list of them. */
function addressesOf(value) {
	const list = [];

	for (const v of [].concat(value ?? [])) {
		const a = ipv4(String(v).split('/')[0]);

		if (a != null && list.indexOf(a) < 0)
			list.push(a);
	}

	return list;
}

/* Which address will the router have in place of the one this page was
 * opened at? Answers null when it keeps it, or when that cannot be told. */
function lookup(here) {
	return callInterfaceDump().then(ifaces => {
		const names = [];

		for (const iface of (Array.isArray(ifaces) ? ifaces : [])) {
			const addrs = Array.isArray(iface?.['ipv4-address']) ? iface['ipv4-address'] : [];

			if (typeof(iface?.interface) == 'string' && addrs.some(a => ipv4(a?.address) == here))
				names.push(iface.interface);
		}

		/* not an address of this router (a forwarded port, a tunnel), or
		 * not clear which interface it belongs to */
		if (names.length != 1)
			return null;

		return callUciGet('network', names[0]).then(section => {
			if (!L.isObject(section) || section.proto != 'static' || section.disabled == '1')
				return null;

			const next = addressesOf(section.ipaddr);

			if (!next.length || next.indexOf(here) > -1)
				return null;

			return next[0];
		});
	});
}

function noteFor(move) {
	if (move.note)
		return move.note;

	const lines = [
		E('p', {}, _('Адрес роутера меняется на %s. Как только роутер ответит по новому адресу, настройки будут подтверждены и страница откроется там сама.').format(move.target)),
		E('p', {}, [
			_('Если страница не открылась, откройте новый адрес сами:'), ' ',
			E('a', { 'href': move.dest }, move.base)
		]),
		E('p', {}, _('Устройству, с которого вы настраиваете роутер, может понадобиться подключиться заново (переткнуть кабель или выйти из Wi-Fi и войти снова), чтобы получить адрес в новой сети. Если новый адрес не открыть за отведённое время, роутер вернёт прежние настройки.'))
	];

	if (move.https)
		lines.push(E('p', {}, _('Браузер спросит про сертификат: для нового адреса его нужно принять ещё раз.')));

	move.note = E('div', { 'style': 'margin-top:1em' }, lines);

	return move.note;
}

return baseclass.extend({
	__init__() {
		try {
			this.install();
		}
		catch (e) {
			/* LuCI stays as it is */
		}
	},

	install() {
		const changes = ui.changes;

		if (!L.isObject(changes) || changes.lanmove ||
		    typeof(changes.apply) != 'function' ||
		    typeof(changes.confirm) != 'function' ||
		    typeof(changes.displayStatus) != 'function')
			return;

		const self = this;
		const stock = {
			apply: changes.apply,
			confirm: changes.confirm,
			displayStatus: changes.displayStatus
		};

		this.changes = changes;
		this.stock = stock;
		changes.lanmove = true;

		/* before the apply: where is the router afterwards? */
		changes.apply = function(checked) {
			const args = arguments;
			const go = () => stock.apply.apply(this, args);

			state.target = null;
			state.move = null;

			const here = self.pageAddress();

			/* opened by name or over IPv6, or no network setting waits */
			if (here == null || (L.isObject(this.changes) && !Array.isArray(this.changes.network)))
				return go();

			try {
				stock.displayStatus.call(this, 'notice spinning',
					E('p', _('Starting configuration apply…')));
			}
			catch (e) { }

			let found;

			try {
				found = Promise.resolve(lookup(here));
			}
			catch (e) {
				found = Promise.resolve(null);
			}

			const limit = new Promise(resolve => window.setTimeout(resolve, LOOKUP_LIMIT, null));

			return Promise.race([ found, limit ]).catch(() => null).then(target => {
				state.target = ipv4(target);
			}).then(go);
		};

		/* after the apply request: LuCI starts confirming at the old
		 * address, this adds the new one. With a token from the page
		 * (override_token) the page already is where the router is. */
		changes.confirm = function(checked, deadline, override_token) {
			try {
				if (state.target != null && !override_token)
					self.follow(checked, deadline, checked ? this.confirm_auth?.token : null);
			}
			catch (e) { }

			state.target = null;

			return stock.confirm.apply(this, arguments);
		};

		/* while the move is on, every status LuCI shows carries the note */
		changes.displayStatus = function(type, content) {
			try {
				const move = state.move;

				if (move && !move.done && type && content && Date.now() < move.deadline)
					content = [].concat(content, noteFor(move));
			}
			catch (e) { }

			return stock.displayStatus.call(this, type, content);
		};
	},

	/* the address in the address bar, when it is a plain IPv4 address */
	pageAddress() {
		return ipv4(window.location.hostname);
	},

	/* for the checks in scripts/test-lanmove.js */
	lookup(here) {
		return lookup(here);
	},

	setTarget(target) {
		state.target = ipv4(target);
	},

	currentMove() {
		return state.move;
	},

	follow(checked, deadline, token) {
		const loc = window.location;
		const target = state.target;
		const base = `${loc.protocol}//${target}${loc.port ? ':' + loc.port : ''}`;

		const move = state.move = {
			target,
			base,
			dest: base + loc.pathname + (loc.search ?? ''),
			confirm: base + L.url('admin/uci/confirm'),
			https: loc.protocol == 'https:',
			token: (typeof(token) == 'string') ? token : null,
			deadline,
			refusedSince: null,
			done: false,
			note: null
		};

		/* the same pause LuCI takes before its first try */
		window.setTimeout(L.bind(this.probe, this, move), (+L.env.apply_holdoff || 4) * 1000);
	},

	/* One try at the new address. The request is the confirmation itself;
	 * its answer cannot be read from here (another origin), and need not
	 * be: any answer means the router is there, and should it not have
	 * taken the confirmation, the page opened there sends it again. */
	probe(move) {
		if (move.done || state.move !== move)
			return;

		/* time is up: LuCI's own rollback notice takes over */
		if (Date.now() >= move.deadline) {
			move.done = true;
			return;
		}

		const started = Date.now();
		const ctl = (typeof(AbortController) == 'function') ? new AbortController() : null;
		let gaveup = false;

		const timer = window.setTimeout(() => {
			gaveup = true;

			if (ctl)
				ctl.abort();
		}, PROBE_LIMIT);

		const again = () => {
			window.setTimeout(L.bind(this.probe, this, move),
				Math.max(PROBE_EVERY - (Date.now() - started), 250));
		};

		let request;

		try {
			request = window.fetch(move.confirm, {
				method: 'POST',
				mode: 'no-cors',
				credentials: 'omit',
				cache: 'no-store',
				headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
				body: move.token ? 'token=' + encodeURIComponent(move.token) : '',
				signal: ctl ? ctl.signal : undefined
			});
		}
		catch (e) {
			request = Promise.reject(e);
		}

		Promise.resolve(request).then(() => {
			window.clearTimeout(timer);
			this.open(move);
		}, () => {
			window.clearTimeout(timer);

			const quick = !gaveup && (Date.now() - started) < REFUSED_FAST;

			/* HTTPS and a quick refusal: a router that is there, with a
			 * certificate this browser has not accepted for this address */
			if (!(move.https && quick && window.navigator.onLine !== false))
				move.refusedSince = null;
			else if (move.refusedSince == null)
				move.refusedSince = started;

			if (move.refusedSince != null && Date.now() - move.refusedSince >= REFUSED_FOR)
				this.open(move);
			else
				again();
		});
	},

	open(move) {
		if (move.done || state.move !== move)
			return;

		move.done = true;

		try {
			this.stock.displayStatus.call(this.changes, 'notice spinning',
				E('p', _('Роутер отвечает по адресу %s, открываю страницу там…').format(move.target)));
		}
		catch (e) { }

		window.setTimeout(() => { window.location.href = move.dest; }, 500);
	}
});
