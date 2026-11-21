'use strict';
'require baseclass';
'require rpc';
'require ui';

// Shared parts of the VPN pages (views miwrt-vpn/xray, link, tailscale): the calls to the rpcd object
// miwrt-vpn, the look (the same cards as the other MiWRT pages, in the theme's colours) and small helpers.
//
// Text from the router (server and subscription names, peer names, error messages) is never given to
// E() as a bare string: LuCI's dom.append sets a bare string as innerHTML. Wrapped in an array it
// becomes a text node. The helpers below wrap whatever they are given; the views wrap the rest (T()).

function T(v) {
	return [ v == null ? '' : String(v) ];
}

function declare(method, params) {
	// reject: a call that fails in rpcd (a ubus status instead of an answer) rejects, so act() and
	// L.resolveDefault() see it as a failure instead of taking the status number for a reply
	return rpc.declare({ object: 'miwrt-vpn', method: method, params: params || [], reject: true });
}

var CSS = `
.mv-cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:12px;margin:12px 0 18px}
.mv-card{padding:16px 18px;border-radius:14px;border:1px solid var(--mw-line,rgba(128,128,128,.3));background:var(--mw-surface-2,rgba(128,128,128,.05));display:flex;flex-direction:column;gap:10px;margin:0 0 14px}
.mv-card.on{border-color:var(--mw-accent,#4b3bff);box-shadow:0 0 0 3px var(--mw-ring,rgba(75,59,255,.18))}
.mv-card h3,.mv-card h4{margin:0;display:flex;flex-wrap:wrap;align-items:center;gap:8px}
.mv-card h3{font-size:17px}.mv-card h4{font-size:15px}
.mv-kicker{font:600 11px/1.2 ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.08em;text-transform:uppercase;color:var(--mw-text-3,#888)}
.mv-big{font-size:22px;font-weight:700;display:flex;align-items:center;gap:10px}
.mv-dot{width:10px;height:10px;border-radius:50%;background:var(--mw-text-3,#999);flex:none}
.mv-dot.good{background:#2fb36b;box-shadow:0 0 0 4px rgba(47,179,107,.18)}
.mv-dot.warn{background:#e0a100}.mv-dot.bad{background:#e5484d}
.mv-badge{font-size:11px;font-weight:600;padding:1px 8px;border-radius:999px;background:var(--mw-accent,#4b3bff);color:var(--mw-on-accent,#fff);white-space:nowrap}
.mv-badge.soft{background:var(--mw-surface-3,rgba(128,128,128,.18));color:var(--mw-text,inherit)}
.mv-badge.good{background:rgba(47,179,107,.16);color:#1f8a50}.mv-badge.warn{background:rgba(224,161,0,.16);color:#9a6f00}.mv-badge.bad{background:rgba(229,72,77,.14);color:#c62f35}
.mv-text{font-size:13px;line-height:1.5}
.mv-note{font-size:12px;line-height:1.45;color:var(--mw-text-3,#888)}
.mv-err{font-size:13px;color:#c62f35}
.mv-row{display:flex;flex-wrap:wrap;align-items:center;gap:8px}
.mv-act{display:flex;flex-wrap:wrap;gap:8px;align-items:center}
.mv-stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:10px}
.mv-stat{padding:10px 12px;border-radius:10px;background:var(--mw-surface-3,rgba(128,128,128,.08))}
.mv-stat b{display:block;font-size:16px}.mv-stat span{font-size:11.5px;color:var(--mw-text-3,#888)}
.mv-list{display:flex;flex-direction:column;border-radius:10px;overflow:hidden;border:1px solid var(--mw-line,rgba(128,128,128,.25))}
.mv-item{display:flex;align-items:center;gap:10px;padding:9px 12px;border-top:1px solid var(--mw-line,rgba(128,128,128,.18))}
.mv-item:first-child{border-top:0}
.mv-item.sel{background:var(--mw-ring,rgba(75,59,255,.08))}
.mv-item .mv-main{flex:1;min-width:0}
.mv-item .mv-main div:first-child{font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.mv-item .mv-main div+div{font-size:11.5px;color:var(--mw-text-3,#888)}
.mv-group{font-size:12px;font-weight:600;color:var(--mw-text-3,#888);margin:10px 0 4px}
.mv-steps{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:6px}
.mv-steps li{display:flex;align-items:center;gap:8px;font-size:13px}
.mv-code{font:12px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace;padding:10px 12px;border-radius:10px;background:var(--mw-surface-3,rgba(128,128,128,.1));word-break:break-all;white-space:pre-wrap;max-height:220px;overflow:auto}
.mv-card textarea{width:100%;min-height:90px;font:12px ui-monospace,SFMono-Regular,Menlo,monospace;box-sizing:border-box}
.mv-card input[type=text],.mv-card input[type=password],.mv-card select{max-width:100%}
.mv-field{display:flex;flex-direction:column;gap:4px}
.mv-field label{font-size:12.5px;font-weight:600}
.mv-check{display:flex;align-items:flex-start;gap:8px;font-size:13px}
.mv-check input{margin-top:3px}
.mv-devs{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:4px 12px;max-height:260px;overflow:auto;padding:4px 0}
@media (max-width:600px){.mv-cards{grid-template-columns:1fr}.mv-big{font-size:19px}}
`;

return baseclass.extend({
	callState: declare('state', [ 'check' ]),
	callSet: declare('set', [ 'data' ]),
	callInstall: declare('install', [ 'data' ]),
	callRemove: declare('remove', [ 'data' ]),
	callServers: declare('servers', [ 'data' ]),
	callSubs: declare('subscriptions', [ 'data' ]),
	callTest: declare('test', [ 'data' ]),
	callLinkState: declare('link_state'),
	callLink: declare('link', [ 'data' ]),
	callRelay: declare('relay'),
	callTsState: declare('ts_state'),
	callTsSet: declare('ts_set', [ 'data' ]),
	callTsInstall: declare('ts_install', [ 'data' ]),
	callTsRemove: declare('ts_remove', [ 'data' ]),
	callTsLogin: declare('ts_login', [ 'data' ]),
	callTsLogout: declare('ts_logout', [ 'data' ]),
	callHints: rpc.declare({ object: 'luci-rpc', method: 'getHostHints', expect: { '': {} } }),

	T: T,

	style: function() {
		return E('style', {}, CSS);
	},

	card: function(cls, children) {
		return E('div', { 'class': 'mv-card' + (cls ? ' ' + cls : '') }, children);
	},

	badge: function(text, tone) {
		return E('span', { 'class': 'mv-badge' + (tone ? ' ' + tone : '') }, T(text));
	},

	kicker: function(text) {
		return E('div', { 'class': 'mv-kicker' }, T(text));
	},

	button: function(label, fn, kind) {
		var cls = kind == 'primary' ? 'cbi-button cbi-button-action important'
			: kind == 'danger' ? 'cbi-button cbi-button-negative' : 'cbi-button cbi-button-neutral';
		return E('button', { 'class': cls, 'click': ui.createHandlerFn(this, fn) }, T(label));
	},

	/* Runs a call; on { error } shows it and resolves false, otherwise true. */
	act: function(promise) {
		return Promise.resolve(promise).then(function(r) {
			if (r && r.error) {
				ui.addNotification(null, E('p', {}, T(r.error)), 'danger');
				return false;
			}
			return r || true;
		}).catch(function(e) {
			ui.addNotification(null, E('p', {}, T(e.message || String(e))), 'danger');
			return false;
		});
	},

	rate: function(bps) {
		bps = +bps || 0;
		if (bps >= 1e9) return _('%.1f Гбит/с').format(bps / 1e9);
		if (bps >= 1e6) return _('%.1f Мбит/с').format(bps / 1e6);
		if (bps >= 1e3) return _('%d кбит/с').format(Math.round(bps / 1e3));
		return _('%d бит/с').format(bps);
	},

	ago: function(t) {
		if (!t) return _('ещё не обновлялась');
		var s = Math.max(0, Math.round(Date.now() / 1000 - t));
		if (s < 90) return _('только что');
		if (s < 5400) return _('%d мин назад').format(Math.round(s / 60));
		if (s < 129600) return _('%d ч назад').format(Math.round(s / 3600));
		return _('%d дн назад').format(Math.round(s / 86400));
	},

	/* An install or removal in progress: the steps with the current one marked. */
	jobView: function(job, steps) {
		var at = -1;
		steps.forEach(function(s, i) { if (s[0] == job.step) at = i; });
		return E('ul', { 'class': 'mv-steps' }, steps.map(function(s, i) {
			var mark = i < at || job.state == 'done' ? '✓' : (i == at ? '…' : '○');
			return E('li', {}, [ E('span', { 'style': 'width:16px;text-align:center;font-weight:700' }, T(mark)), s[1] ]);
		}));
	},

	copy: function(text) {
		var done = function() { ui.addNotification(null, E('p', {}, T(_('Скопировано.'))), 'info'); };
		var fail = function() { ui.addNotification(null, E('p', {}, T(_('Не удалось скопировать: выделите текст и скопируйте его вручную.'))), 'warning'); };
		if (navigator.clipboard && window.isSecureContext)
			return navigator.clipboard.writeText(text).then(done, fail);
		var ta = E('textarea', { 'style': 'position:fixed;opacity:0' });
		ta.value = text;
		document.body.appendChild(ta);
		ta.select();
		var ok = false;
		try { ok = document.execCommand('copy'); } catch (e) {}
		document.body.removeChild(ta);
		ok ? done() : fail();
	},

	codeBox: function(text) {
		var self = this;
		return E('div', { 'class': 'mv-field' }, [
			E('div', { 'class': 'mv-code' }, T(text)),
			E('div', { 'class': 'mv-act' }, [ E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': function() { self.copy(text); } }, _('Копировать')) ])
		]);
	},

	// note: a text, or an element of its own (one whose text changes, e.g. with a choice above it)
	field: function(label, input, note) {
		return E('div', { 'class': 'mv-field' }, [ E('label', {}, T(label)), input,
			note ? (note instanceof Node ? note : E('div', { 'class': 'mv-note' }, T(note))) : '' ]);
	},

	check: function(input, label, note) {
		return E('label', { 'class': 'mv-check' }, [ input, E('span', {}, [ String(label), note ? E('div', { 'class': 'mv-note' }, T(note)) : '' ]) ]);
	},

	country: function(cc) {
		var names = { NL: _('Нидерланды'), DE: _('Германия'), FI: _('Финляндия'), FR: _('Франция'), GB: _('Великобритания'), US: _('США'),
			SE: _('Швеция'), TR: _('Турция'), AE: _('ОАЭ'), RU: _('Россия'), IR: _('Иран'), CN: _('Китай'), JP: _('Япония'), SG: _('Сингапур') };
		return cc ? (names[cc] || cc) : '';
	}
});
