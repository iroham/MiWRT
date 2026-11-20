'use strict';
'require view';
'require ui';
'require dom';
'require poll';
'require miwrtvpn as mv';

// VPN, VPN (Xray): the router's VPN client. Servers come from share links or subscriptions; the chosen
// devices (or all) reach the internet through the chosen server. Backend: rpcd miwrt-vpn, which runs
// /usr/share/ucode/miwrt/tunnel.uc, the same code the MiWRT app uses.

var PROTO = { vless: 'VLESS', vmess: 'VMess', trojan: 'Trojan', shadowsocks: 'Shadowsocks', hysteria2: 'Hysteria2', link: _('Роутер-партнёр') };

return view.extend({
	load: function() {
		return Promise.all([ L.resolveDefault(mv.callState(false), {}), L.resolveDefault(mv.callHints(), {}) ]);
	},

	refresh: function() {
		var self = this;
		return Promise.all([ L.resolveDefault(mv.callState(false), {}), L.resolveDefault(mv.callHints(), {}) ]).then(function(r) {
			self.st = r[0]; self.hints = r[1];
			dom.content(self.root, self.build());
		});
	},

	// an install, a removal, a test, a check or a subscription download changes what the page shows:
	// it is drawn again when one ends. Otherwise only the status box and the job box follow the
	// router, so nothing being typed is lost.
	jobBusy: function(st) {
		return !!((st.engine && st.engine.job && st.engine.job.state == 'running') || (st.tests && st.tests.running)
			|| st.subs_updating || (st.status && st.status.checking));
	},

	tick: function() {
		var self = this, was = this.jobBusy(this.st || {});
		return L.resolveDefault(mv.callState(false), null).then(function(n) {
			if (!n || !n.engine) return;
			var installedBefore = !!(self.st && self.st.engine && self.st.engine.installed);
			self.st = n;
			if ((was && !self.jobBusy(n)) || installedBefore != !!n.engine.installed) return self.refresh();
			var box = document.getElementById('mv-status');
			if (box && n.engine && n.engine.installed) {
				box.className = 'mv-card' + (n.status.state == 'connected' ? ' on' : '');
				dom.content(box, self.statusInner(n));
			}
			var jb = document.getElementById('mv-job');
			if (jb && n.engine && n.engine.job) dom.content(jb, self.installCard(n));
		});
	},

	render: function(data) {
		this.st = data[0]; this.hints = data[1];
		this.root = E('div', {}, this.build());
		poll.add(L.bind(this.tick, this), 5);
		return E([], [
			mv.style(),
			E('h2', {}, _('VPN (Xray)')),
			E('div', { 'class': 'cbi-map-descr' }, _('Роутер подключается к VPN-серверу на Xray и пропускает через него трафик выбранных устройств. Серверы добавляются ссылками vless://, vmess://, trojan://, ss://, hysteria2:// или подпиской. Те же настройки есть в приложении MiWRT.')),
			this.root
		]);
	},

	build: function() {
		var st = this.st || {};
		if (!st.engine) return [ E('p', {}, _('Не удалось получить состояние VPN.')) ];
		if (!st.engine.installed || (st.engine.job && st.engine.job.state == 'running'))
			return [ E('div', { 'id': 'mv-job' }, this.installCard(st)) ];
		return [
			E('div', { 'class': 'mv-card' + (st.status.state == 'connected' ? ' on' : ''), 'id': 'mv-status' }, this.statusInner(st)),
			this.serversCard(st),
			this.whoCard(st),
			this.subsCard(st),
			this.removeCard(st)
		];
	},

	installCard: function(st) {
		var e = st.engine, job = e.job;
		var steps = [ [ 'download', _('Загрузка списка пакетов') ], [ 'install', _('Установка Xray') ], [ 'check', _('Проверка') ] ];
		if (job && job.state == 'running' && job.step == 'remove')
			return mv.card('', [ E('h3', {}, _('Удаляется Xray')), E('div', { 'class': 'mv-note' }, _('VPN и связь роутеров выключаются. Это занимает несколько секунд.')) ]);
		if (job && job.state == 'running')
			return mv.card('', [ E('h3', {}, _('Устанавливается Xray')), mv.jobView(job, steps), E('div', { 'class': 'mv-note' }, _('Обычно это занимает меньше минуты.')) ]);
		var failed = job && job.state == 'failed' && job.step != 'remove' && job.age < 3600 ? E('div', { 'class': 'mv-err' }, mv.T(job.error || _('Установка не удалась.'))) : '';
		return mv.card('', [
			E('h3', {}, _('Xray не установлен')),
			E('div', { 'class': 'mv-text' }, _('Xray работает с протоколами VLESS (в том числе REALITY), VMess, Trojan, Shadowsocks и Hysteria2. Программа ставится из пакетов MiWRT и обновляется без обновления прошивки.')),
			E('div', { 'class': 'mv-note' }, e.package == 'miwrt-xray-xz'
				? _('Займёт около 8 МБ памяти настроек: программа хранится сжатой и распаковывается в оперативную память при запуске.')
				: _('Займёт около 14 МБ флеш-памяти.')),
			failed,
			e.blocker == 'storage' ? E('div', { 'class': 'mv-err' }, _('Не хватает свободного места. Освободите место в разделе Система, Программное обеспечение.')) : '',
			E('div', { 'class': 'mv-act' }, [
				e.blocker ? '' : mv.button(_('Установить Xray'), L.bind(function() {
					return mv.act(mv.callInstall({})).then(L.bind(this.refresh, this));
				}, this), 'primary')
			]),
			E('div', { 'class': 'mv-note' }, _('Если роутер не может скачать пакет, его можно загрузить вручную в разделе Система, Программное обеспечение.'))
		]);
	},

	statusInner: function(st) {
		var s = st.status || {}, h = s.health || {}, server = null;
		(st.servers || []).forEach(function(x) { if (x.id == st.server) server = x; });
		var tone = { connected: 'good', starting: 'warn', failing: 'bad' }[s.state] || '';
		var title = { connected: _('Подключено'), starting: _('Подключение…'), failing: _('Не работает'), off: _('Выключено'), 'no-engine': _('Xray не установлен') }[s.state] || s.state;
		var stats = [];
		if (s.state == 'connected' && h.exit_ip)
			stats.push(E('div', { 'class': 'mv-stat' }, [ E('b', {}, mv.T(h.exit_ip)), E('span', {}, mv.T(mv.country(h.country) ? _('Адрес для сайтов, %s').format(mv.country(h.country)) : _('Адрес для сайтов'))) ]));
		if (s.state == 'connected' && h.ms != null)
			stats.push(E('div', { 'class': 'mv-stat' }, [ E('b', {}, mv.T(_('%d мс').format(h.ms))), E('span', {}, _('Ответ через VPN')) ]));
		if (s.rate)
			stats.push(E('div', { 'class': 'mv-stat' }, [ E('b', {}, mv.T('↓ ' + mv.rate(s.rate.down_bps) + '  ↑ ' + mv.rate(s.rate.up_bps))), E('span', {}, _('Скорость сейчас')) ]));
		var self = this;
		return [
			mv.kicker(_('Состояние')),
			E('div', { 'class': 'mv-big' }, [ E('span', { 'class': 'mv-dot ' + tone }), String(title || '') ]),
			E('div', { 'class': 'mv-text' }, mv.T(server ? _('Сервер: %s').format(server.name) : _('Сервер не выбран.'))),
			s.state == 'failing' ? E('div', { 'class': 'mv-err' }, _('Сервер не отвечает. У устройств, которые идут через VPN, нет интернета, пока сервер не ответит или VPN не выключат.')) : '',
			stats.length ? E('div', { 'class': 'mv-stats' }, stats) : '',
			E('div', { 'class': 'mv-act' }, [
				st.enabled
					? mv.button(_('Выключить VPN'), function() { return mv.act(mv.callSet({ enabled: false })).then(L.bind(self.refresh, self)); })
					: mv.button(_('Включить VPN'), function() { return mv.act(mv.callSet({ enabled: true })).then(L.bind(self.refresh, self)); }, 'primary'),
				!st.enabled ? ''
					: s.checking ? E('button', { 'class': 'cbi-button cbi-button-neutral', 'disabled': '' }, _('Проверка…'))
					: mv.button(_('Проверить сейчас'), function() {
						// the check runs on the router; the page is drawn again when it ends
						return L.resolveDefault(mv.callState(true), null).then(L.bind(self.refresh, self));
					})
			])
		];
	},

	serversCard: function(st) {
		var self = this, groups = {}, order = [];
		var subName = {};
		(st.subscriptions || []).forEach(function(s) { subName[s.id] = s.name; });
		(st.servers || []).forEach(function(s) {
			var g = s.source == 'link' ? _('Роутер-партнёр') : s.source == 'manual' ? _('Добавлены вручную') : _('Подписка: %s').format(subName[s.source] || s.source);
			if (!groups[g]) { groups[g] = []; order.push(g); }
			groups[g].push(s);
		});
		var rows = [];
		order.forEach(function(g) {
			rows.push(E('div', { 'class': 'mv-group' }, mv.T(g)));
			rows.push(E('div', { 'class': 'mv-list' }, groups[g].map(function(s) { return self.serverRow(st, s); })));
		});
		var ta = E('textarea', { 'placeholder': 'vless://…\nhysteria2://…' });
		return mv.card('', [
			E('h3', {}, [ _('Серверы'), st.tests && st.tests.running ? mv.badge(_('идёт проверка'), 'soft') : '' ]),
			rows.length ? E('div', {}, rows) : E('div', { 'class': 'mv-note' }, _('Серверов пока нет. Вставьте ссылки ниже или добавьте подписку.')),
			rows.length ? E('div', { 'class': 'mv-act' }, [ mv.button(_('Проверить все'), function() {
				return mv.act(mv.callTest({})).then(function() { setTimeout(L.bind(self.refresh, self), 1500); });
			}) ]) : '',
			mv.field(_('Добавить серверы'), ta, _('Одна ссылка на строку. Можно вставить и содержимое подписки в base64.')),
			E('div', { 'class': 'mv-act' }, [ mv.button(_('Добавить'), function() {
				return mv.act(mv.callServers({ action: 'add', text: ta.value })).then(function(r) {
					if (!r) return;
					var msg = _('Добавлено серверов: %d.').format(r.added || 0);
					if (r.skipped) msg += ' ' + _('Уже были в списке: %d.').format(r.skipped);
					if (r.errors && r.errors.length) msg += ' ' + _('Не приняты: %d (%s)').format(r.errors.length, r.errors[0]);
					ui.addNotification(null, E('p', {}, mv.T(msg)), r.errors && r.errors.length ? 'warning' : 'info');
					return self.refresh();
				});
			}, 'primary') ])
		]);
	},

	serverRow: function(st, s) {
		var self = this, sel = s.id == st.server;
		var lat = s.test_error ? mv.badge(_('нет ответа'), 'bad') : (s.latency_ms != null ? mv.badge(_('%d мс').format(s.latency_ms), s.latency_ms <= 150 ? 'good' : s.latency_ms <= 400 ? 'warn' : 'bad') : '');
		var detail = [ PROTO[s.protocol] || s.protocol, s.transport && s.transport != 'raw' ? s.transport : null, s.security && s.security != 'none' ? s.security : null, s.address ? s.address + ':' + s.port : null ]
			.filter(function(x) { return x; }).join(' · ');
		var acts = [];
		if (!sel) acts.push(E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': ui.createHandlerFn(this, function() {
			return mv.act(mv.callSet({ server: s.id })).then(L.bind(self.refresh, self));
		}) }, _('Выбрать')));
		if (s.source == 'manual') {
			acts.push(E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': ui.createHandlerFn(this, function() {
				var name = window.prompt(_('Новое имя сервера'), s.name);
				if (name == null) return;
				return mv.act(mv.callServers({ action: 'rename', id: s.id, name: name })).then(L.bind(self.refresh, self));
			}) }, _('Переименовать')));
			acts.push(E('button', { 'class': 'cbi-button cbi-button-negative', 'click': ui.createHandlerFn(this, function() {
				if (!window.confirm(_('Удалить сервер «%s»?').format(s.name))) return;
				return mv.act(mv.callServers({ action: 'delete', id: s.id })).then(L.bind(self.refresh, self));
			}) }, _('Удалить')));
		}
		return E('div', { 'class': 'mv-item' + (sel ? ' sel' : '') }, [
			E('span', { 'class': 'mv-dot' + (sel ? ' good' : '') }),
			E('div', { 'class': 'mv-main' }, [ E('div', {}, mv.T(s.name)), E('div', {}, mv.T(detail)) ]),
			lat,
			sel ? mv.badge(_('выбран')) : '',
			E('div', { 'class': 'mv-act' }, acts)
		]);
	},

	whoCard: function(st) {
		var self = this, hints = this.hints || {};
		var who = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'all', 'selected': st.who == 'all' ? '' : null }, _('Все устройства домашней сети')),
			E('option', { 'value': 'selected', 'selected': st.who == 'selected' ? '' : null }, _('Только выбранные устройства')),
			E('option', { 'value': 'except', 'selected': st.who == 'except' ? '' : null }, _('Все, кроме выбранных'))
		]);
		var chosen = {};
		(st.devices || []).forEach(function(m) { chosen[m.toLowerCase()] = true; });
		var macs = Object.keys(hints).map(function(m) { return m.toLowerCase(); });
		(st.devices || []).forEach(function(m) { if (macs.indexOf(m) < 0) macs.push(m); });
		var label = function(m) {
			var h = hints[m.toUpperCase()] || hints[m] || {};
			var ip = (h.ipaddrs || h.ipv4 || [])[0];
			return (h.name || m) + (ip ? ' (' + ip + ')' : '');
		};
		macs.sort(function(a, b) { return label(a).localeCompare(label(b)); });
		var boxes = macs.map(function(m) {
			var cb = E('input', { 'type': 'checkbox', 'value': m, 'checked': chosen[m] ? '' : null });
			return mv.check(cb, label(m));
		});
		var devs = E('div', { 'class': 'mv-devs', 'style': st.who == 'all' ? 'display:none' : '' }, boxes);
		who.addEventListener('change', function() { devs.style.display = who.value == 'all' ? 'none' : ''; });
		var country = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': '', 'selected': !st.country ? '' : null }, _('Нет: всё через VPN')),
			E('option', { 'value': 'ir', 'selected': st.country == 'ir' ? '' : null }, _('Иран (.ir)')),
			E('option', { 'value': 'cn', 'selected': st.country == 'cn' ? '' : null }, _('Китай (.cn)')),
			E('option', { 'value': 'ru', 'selected': st.country == 'ru' ? '' : null }, _('Россия (.ru, .su, .рф)'))
		]);
		var dns = E('input', { 'type': 'checkbox', 'checked': st.dns ? '' : null });
		return mv.card('', [
			E('h3', {}, _('Кто идёт через VPN')),
			mv.field(_('Устройства'), who, _('Гостевая сеть и сеть умного дома через VPN не идут. У устройств, которые идут через VPN, выключается IPv6, чтобы ничего не шло в обход.')),
			devs,
			mv.field(_('Сайты страны напрямую'), country, _('Сайты в зоне страны открываются без VPN: банки и госуслуги часто не пускают зарубежные адреса.')),
			mv.check(dns, _('Запросы имён через VPN'), _('Адреса сайтов узнаются через VPN-сервер. Блокировщик рекламы на роутере эти запросы не видит.')),
			E('div', { 'class': 'mv-act' }, [ mv.button(_('Сохранить'), function() {
				var devices = boxes.map(function(l) { return l.querySelector('input'); }).filter(function(i) { return i.checked; }).map(function(i) { return i.value; });
				return mv.act(mv.callSet({ who: who.value, devices: devices, country: country.value, dns: dns.checked })).then(function(ok) {
					if (ok) ui.addNotification(null, E('p', {}, _('Сохранено.')), 'info');
					return self.refresh();
				});
			}, 'primary') ])
		]);
	},

	subsCard: function(st) {
		var self = this;
		var url = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': 'https://…', 'style': 'width:100%' });
		var busy = !!st.subs_updating;
		var rows = (st.subscriptions || []).map(function(s) {
			var line = s.error ? s.error
				: (!s.updated && busy) ? _('Загружается…')
				: _('Обновлена %s, серверов: %d').format(mv.ago(s.updated), s.count || 0);
			return E('div', { 'class': 'mv-item' }, [
				E('div', { 'class': 'mv-main' }, [ E('div', {}, mv.T(s.name || s.host || _('Подписка'))), E('div', {}, mv.T(line)) ]),
				s.error ? mv.badge(_('ошибка'), 'bad') : '',
				E('div', { 'class': 'mv-act' }, [
					E('button', { 'class': 'cbi-button cbi-button-negative', 'click': ui.createHandlerFn(self, function() {
						if (!window.confirm(_('Удалить подписку «%s» и её серверы?').format(s.name || s.host || ''))) return;
						return mv.act(mv.callSubs({ action: 'delete', id: s.id })).then(L.bind(self.refresh, self));
					}) }, _('Удалить'))
				])
			]);
		});
		return mv.card('', [
			E('h3', {}, _('Подписки')),
			rows.length ? E('div', { 'class': 'mv-list' }, rows) : E('div', { 'class': 'mv-note' }, _('Подписка — адрес, по которому провайдер VPN отдаёт список серверов. Роутер обновляет подписки раз в сутки.')),
			rows.length ? E('div', { 'class': 'mv-act' }, [ busy
				? E('button', { 'class': 'cbi-button cbi-button-neutral', 'disabled': '' }, _('Загружается…'))
				: mv.button(_('Обновить все'), function() {
					return mv.act(mv.callSubs({ action: 'update' })).then(L.bind(self.refresh, self));
				}) ]) : '',
			mv.field(_('Добавить подписку'), url),
			E('div', { 'class': 'mv-act' }, [ mv.button(_('Добавить'), function() {
				return mv.act(mv.callSubs({ action: 'add', url: url.value })).then(L.bind(self.refresh, self));
			}, 'primary') ])
		]);
	},

	removeCard: function(st) {
		var self = this;
		return mv.card('', [
			E('h4', {}, mv.T(_('Xray %s').format(st.engine.version || ''))),
			st.engine.job && st.engine.job.state == 'failed' && st.engine.job.step == 'remove' && st.engine.job.age < 3600
				? E('div', { 'class': 'mv-err' }, mv.T(st.engine.job.error || _('Удаление не удалось.'))) : '',
			E('div', { 'class': 'mv-note' }, _('Удаление Xray выключает VPN и связь роутеров. Серверы и подписки сохраняются.')),
			E('div', { 'class': 'mv-act' }, [ mv.button(_('Удалить Xray'), function() {
				if (!window.confirm(_('Удалить Xray с роутера? VPN и связь роутеров выключатся.'))) return;
				return mv.act(mv.callRemove({})).then(L.bind(self.refresh, self));
			}, 'danger') ])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
