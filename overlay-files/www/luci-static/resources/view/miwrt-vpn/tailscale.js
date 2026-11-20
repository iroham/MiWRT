'use strict';
'require view';
'require ui';
'require dom';
'require poll';
'require miwrtvpn as mv';

// VPN, Tailscale: the router in the user's tailnet. On the BE7000 Tailscale is part of the firmware and
// only switched on or off; on the Redmi AC2100 it is installed when asked for and can be removed again.
// Backend: rpcd miwrt-vpn (tailscale.uc), the same code the MiWRT app uses.

return view.extend({
	load: function() {
		return L.resolveDefault(mv.callTsState(), {});
	},

	refresh: function() {
		var self = this;
		return L.resolveDefault(mv.callTsState(), {}).then(function(st) {
			self.st = st;
			dom.content(self.root, self.build());
		});
	},

	// the page is drawn again only when what it shows changes (an install step, a sign-in, a start), so
	// a half-typed key or setting is not lost; the device list is kept fresh on its own
	shape: function(st) {
		var j = st.job || {};
		return [ st.installed, st.enabled, st.backend, st.auth_url, j.state, j.step ].join('|');
	},

	tick: function() {
		var self = this;
		return L.resolveDefault(mv.callTsState(), null).then(function(n) {
			if (!n) return;
			var old = self.st || {};
			self.st = n;
			if (self.shape(n) != self.shape(old)) {
				dom.content(self.root, self.build());
				return;
			}
			var peers = document.getElementById('mv-peers');
			if (peers) dom.content(peers, self.peersInner(n));
		});
	},

	render: function(st) {
		this.st = st;
		this.root = E('div', {}, this.build());
		poll.add(L.bind(this.tick, this), 5);
		return E([], [
			mv.style(),
			E('h2', {}, _('Tailscale')),
			E('div', { 'class': 'cbi-map-descr' }, _('Роутер входит в вашу сеть Tailscale: к нему и к домашней сети можно подключаться из любого места, и он может стать выходом в интернет для ваших устройств. Те же настройки есть в приложении MiWRT.')),
			this.root
		]);
	},

	build: function() {
		var st = this.st || {};
		if (st.installed == null) return [ E('p', {}, _('Не удалось получить состояние Tailscale.')) ];
		if (!st.installed || (st.job && st.job.state == 'running' && st.job.step != 'remove'))
			return [ this.installCard(st) ];
		var out = [ this.statusCard(st) ];
		if (st.enabled && st.backend == 'Running') out.push(this.settingsCard(st), this.peersCard(st));
		if (st.enabled && st.backend == 'Running') out.push(this.signOutCard(st));
		if (st.removable) out.push(this.removeCard(st));
		return out;
	},

	installCard: function(st) {
		var self = this, job = st.job;
		var steps = [ [ 'download', _('Загрузка списка пакетов') ], [ 'install', _('Установка Tailscale') ] ];
		if (job && job.state == 'running')
			return mv.card('', [ E('h3', {}, _('Устанавливается Tailscale')), mv.jobView(job, steps), E('div', { 'class': 'mv-note' }, _('Обычно это занимает одну-две минуты.')) ]);
		var failed = job && job.state == 'failed' && job.age < 3600 ? E('div', { 'class': 'mv-err' }, job.error || _('Установка не удалась.')) : '';
		var removed = job && job.state == 'done' && job.step == 'removed' && job.age < 600 ? E('div', { 'class': 'mv-note' }, _('Tailscale удалён.')) : '';
		return mv.card('', [
			E('h3', {}, _('Tailscale не установлен')),
			E('div', { 'class': 'mv-text' }, _('На этом роутере Tailscale ставится только по желанию: он занимает место и оперативную память. Чтобы ему хватало памяти, вместе с ним включается сжатый файл подкачки в оперативной памяти (zram).')),
			E('div', { 'class': 'mv-note' }, _('Нужно не меньше 24 МБ свободного места. Удалить Tailscale можно здесь же, роутер вернётся к прежнему состоянию.')),
			removed, failed,
			st.blocker == 'storage' ? E('div', { 'class': 'mv-err' }, _('Не хватает свободного места. Освободите место в разделе Система, Программное обеспечение.')) : '',
			E('div', { 'class': 'mv-act' }, [
				st.blocker ? '' : mv.button(_('Установить Tailscale'), function() {
					return mv.act(mv.callTsInstall({})).then(L.bind(self.refresh, self));
				}, 'primary')
			])
		]);
	},

	statusCard: function(st) {
		var self = this;
		var on = E('input', { 'type': 'checkbox', 'checked': st.enabled ? '' : null });
		on.addEventListener('change', function() {
			on.disabled = true;
			mv.act(mv.callTsSet({ enabled: on.checked })).then(function() {
				// the service needs a few seconds to start or stop
				window.setTimeout(L.bind(self.refresh, self), 3000);
			});
		});
		var tone, title;
		if (!st.enabled) { tone = ''; title = _('Выключен'); }
		else if (st.backend == 'Running') { tone = 'good'; title = _('Подключён'); }
		else if (st.backend == 'NeedsLogin') { tone = 'warn'; title = _('Нужно войти'); }
		else if (st.backend == 'NeedsMachineAuth') { tone = 'warn'; title = _('Ждёт одобрения'); }
		else if (st.backend == 'Stopped') { tone = 'bad'; title = _('Остановлен'); }
		else { tone = 'warn'; title = _('Запускается…'); }

		var body = [
			E('div', { 'class': 'mv-row', 'style': 'justify-content:space-between' }, [
				mv.kicker(_('Состояние')),
				E('label', { 'class': 'mv-check' }, [ on, E('span', {}, _('Включён')) ])
			]),
			E('div', { 'class': 'mv-big' }, [ E('span', { 'class': 'mv-dot ' + tone }), title ])
		];

		if (st.enabled && st.backend == 'Running') {
			var stats = [];
			if ((st.addresses || []).length) stats.push(E('div', { 'class': 'mv-stat' }, [ E('b', {}, st.addresses[0]), E('span', {}, _('Адрес роутера в Tailscale')) ]));
			if (st.name) stats.push(E('div', { 'class': 'mv-stat' }, [ E('b', {}, st.name), E('span', {}, st.tailnet ? _('Имя в сети %s').format(st.tailnet) : _('Имя роутера')) ]));
			stats.push(E('div', { 'class': 'mv-stat' }, [ E('b', {}, _('%d из %d').format(st.peers_online || 0, (st.peers || []).length)), E('span', {}, _('Устройств в сети')) ]));
			body.push(E('div', { 'class': 'mv-stats' }, stats));
			(st.health || []).forEach(function(h) { body.push(E('div', { 'class': 'mv-note' }, h)); });
		}
		else if (st.enabled && st.backend == 'NeedsLogin') body.push(this.loginInner(st));
		else if (st.enabled && st.backend == 'NeedsMachineAuth')
			body.push(E('div', { 'class': 'mv-text' }, _('Роутер вошёл в сеть, но администратор сети должен одобрить его в панели Tailscale (Machines).')));
		else if (!st.enabled)
			body.push(E('div', { 'class': 'mv-note' }, st.in_image
				? _('Tailscale входит в прошивку этого роутера и выключен, пока он не нужен.')
				: _('Выключенный Tailscale не работает и не занимает оперативную память.')));

		if (st.version) body.push(E('div', { 'class': 'mv-note' }, _('Версия %s').format(st.version)));
		return E('div', { 'class': 'mv-card' + (st.enabled && st.backend == 'Running' ? ' on' : '') }, body);
	},

	loginInner: function(st) {
		var self = this;
		var key = E('input', { 'type': 'password', 'class': 'cbi-input-password', 'placeholder': 'tskey-auth-…', 'autocomplete': 'off' });
		var nodes = [ E('div', { 'class': 'mv-text' }, _('Войдите в свою учётную запись Tailscale, чтобы добавить роутер в сеть.')) ];
		if (st.auth_url)
			nodes.push(E('div', { 'class': 'mv-act' }, [
				E('a', { 'class': 'cbi-button cbi-button-action important', 'href': st.auth_url, 'target': '_blank', 'rel': 'noopener noreferrer' }, _('Войти в Tailscale')),
				E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': function() { mv.copy(st.auth_url); } }, _('Копировать ссылку'))
			]), E('div', { 'class': 'mv-note' }, _('Ссылку можно открыть на любом устройстве, например на телефоне. Страница обновится сама, когда роутер войдёт.')));
		else
			nodes.push(E('div', { 'class': 'mv-act' }, [ mv.button(_('Получить ссылку для входа'), function() {
				return mv.act(mv.callTsLogin({})).then(function() { window.setTimeout(L.bind(self.refresh, self), 4000); });
			}, 'primary') ]));
		nodes.push(
			E('div', { 'class': 'mv-group' }, _('Или ключом авторизации')),
			E('div', { 'class': 'mv-row' }, [ key, mv.button(_('Войти с ключом'), function() {
				if (!key.value.trim()) return;
				return mv.act(mv.callTsLogin({ auth_key: key.value.trim() })).then(function(ok) {
					key.value = '';
					if (ok) window.setTimeout(L.bind(self.refresh, self), 4000);
				});
			}) ]),
			E('div', { 'class': 'mv-note' }, _('Ключ создаётся в панели Tailscale: Settings, Keys. Роутер хранит его только до входа.'))
		);
		return E('div', { 'class': 'mv-field' }, nodes);
	},

	settingsCard: function(st) {
		var self = this, s = st.settings || {};
		var lan = E('input', { 'type': 'checkbox', 'checked': s.advertise_lan ? '' : null });
		var exitOffer = E('input', { 'type': 'checkbox', 'checked': s.advertise_exit ? '' : null });
		var accept = E('input', { 'type': 'checkbox', 'checked': s.accept_routes ? '' : null });
		var viaVpn = E('input', { 'type': 'checkbox', 'checked': s.via_vpn ? '' : null, 'disabled': st.vpn_available || s.via_vpn ? null : '' });
		var exits = (st.peers || []).filter(function(p) { return p.exit_node_option && (p.addresses || []).length; });
		var exitSel = E('select', { 'class': 'cbi-input-select' }, [ E('option', { 'value': '' }, _('Нет: роутер выходит в интернет сам')) ].concat(exits.map(function(p) {
			var v = p.addresses[0];
			return E('option', { 'value': v, 'selected': (s.exit_node == v || s.exit_node == p.name) ? '' : null }, p.name + (p.online ? '' : ' ' + _('(не в сети)')));
		})));
		if (s.exit_node && !exits.some(function(p) { return s.exit_node == p.addresses[0] || s.exit_node == p.name; }))
			exitSel.appendChild(E('option', { 'value': s.exit_node, 'selected': '' }, s.exit_node));

		return mv.card('', [
			E('h3', {}, _('Настройки')),
			mv.check(lan, _('Открыть домашнюю сеть устройствам Tailscale'), _('Роутер объявляет свою сеть (subnet router). Маршрут нужно один раз одобрить в панели Tailscale.')),
			mv.check(exitOffer, _('Предлагать роутер как выход в интернет'), _('Устройства Tailscale смогут выходить в интернет через этот дом (exit node). Тоже одобряется в панели Tailscale.')),
			mv.check(accept, _('Принимать маршруты других роутеров'), _('Включите, если в вашей сети есть другие subnet router и их сети нужны отсюда.')),
			mv.field(_('Выход в интернет для самого роутера'), exitSel, exits.length ? _('Трафик роутера пойдёт через выбранное устройство. Домашняя сеть остаётся доступной.') : _('В сети пока нет устройств, предлагающих себя как выход.')),
			mv.check(viaVpn, _('Подключаться к Tailscale через VPN (Xray)'), st.vpn_available
				? _('Если серверы Tailscale недоступны напрямую, роутер обращается к ним через VPN. Само соединение между устройствами остаётся прямым, когда это возможно.')
				: _('Доступно после установки Xray на странице VPN (Xray).')),
			E('div', { 'class': 'mv-act' }, [ mv.button(_('Сохранить'), function() {
				return mv.act(mv.callTsSet({ advertise_lan: lan.checked, advertise_exit: exitOffer.checked, accept_routes: accept.checked,
					exit_node: exitSel.value, via_vpn: viaVpn.checked })).then(function(ok) {
					if (ok) ui.addNotification(null, E('p', {}, _('Настройки сохранены.')), 'info');
					window.setTimeout(L.bind(self.refresh, self), 3000);
				});
			}, 'primary') ])
		]);
	},

	peersInner: function(st) {
		var peers = st.peers || [];
		if (!peers.length) return [ E('div', { 'class': 'mv-note' }, _('Других устройств в сети пока нет.')) ];
		return [ E('div', { 'class': 'mv-list' }, peers.map(function(p) {
			var tags = [];
			if (p.exit_node) tags.push(mv.badge(_('выход роутера'), ''));
			else if (p.exit_node_option) tags.push(mv.badge(_('может быть выходом'), 'soft'));
			return E('div', { 'class': 'mv-item' }, [
				E('span', { 'class': 'mv-dot' + (p.online ? ' good' : '') }),
				E('div', { 'class': 'mv-main' }, [ E('div', {}, p.name || '—'), E('div', {}, [ (p.addresses || [])[0] || '', p.os ? ' · ' + p.os : '' ].join('')) ]),
				E('div', { 'class': 'mv-row' }, tags)
			]);
		})) ];
	},

	peersCard: function(st) {
		return mv.card('', [ E('h3', {}, _('Устройства в сети')), E('div', { 'id': 'mv-peers' }, this.peersInner(st)) ]);
	},

	signOutCard: function(st) {
		var self = this;
		return mv.card('', [
			E('h4', {}, _('Учётная запись')),
			E('div', { 'class': 'mv-note' }, _('После выхода роутер пропадёт из сети Tailscale, пока вы не войдёте снова.')),
			E('div', { 'class': 'mv-act' }, [ mv.button(_('Выйти из Tailscale'), function() {
				if (!window.confirm(_('Выйти из Tailscale на этом роутере?'))) return;
				return mv.act(mv.callTsLogout({})).then(function() { window.setTimeout(L.bind(self.refresh, self), 3000); });
			}) ])
		]);
	},

	removeCard: function(st) {
		var self = this;
		return mv.card('', [
			E('h4', {}, _('Удаление')),
			E('div', { 'class': 'mv-note' }, _('Tailscale будет удалён вместе с тем, что ставилось для него, и место освободится. Поставить его снова можно здесь же.')),
			E('div', { 'class': 'mv-act' }, [ mv.button(_('Удалить Tailscale'), function() {
				if (!window.confirm(_('Удалить Tailscale с роутера?'))) return;
				return mv.act(mv.callTsRemove({})).then(function() { window.setTimeout(L.bind(self.refresh, self), 2000); });
			}, 'danger') ])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
