'use strict';
'require view';
'require ui';
'require dom';
'require poll';
'require miwrtvpn as mv';

// VPN, Router link: two MiWRT routers joined over Xray (VLESS with REALITY). The router abroad is the
// exit: the router in the other country uses its internet, and each side may let the other reach its
// home network. They meet at the router abroad (when it has a public address) or at a small server
// the user rents (relay). Backend: rpcd miwrt-vpn (tunnel.uc).

return view.extend({
	load: function() {
		return L.resolveDefault(mv.callLinkState(), {});
	},

	refresh: function() {
		var self = this;
		return L.resolveDefault(mv.callLinkState(), {}).then(function(st) {
			self.st = st;
			dom.content(self.root, self.build());
		});
	},

	render: function(st) {
		this.st = st;
		this.root = E('div', {}, this.build());
		var self = this;
		poll.add(function() {
			return L.resolveDefault(mv.callLinkState(), null).then(function(n) {
				if (!n || !n.link) return;
				self.st = n;
				var box = document.getElementById('mv-health');
				if (box) dom.content(box, self.health(n.link));
			});
		}, 10);
		return E([], [
			mv.style(),
			E('h2', {}, _('Связь роутеров')),
			E('div', { 'class': 'cbi-map-descr' }, _('Два роутера MiWRT соединяются между собой: роутер в другой стране отдаёт свой интернет, и при желании каждая сторона открывает другой свою домашнюю сеть. Соединение выглядит как обычное обращение к сайту по HTTPS.')),
			this.root
		]);
	},

	build: function() {
		var st = this.st || {};
		if (!st.engine)
			return [ mv.card('', [ E('h3', {}, _('Нужен Xray')), E('div', { 'class': 'mv-text' }, _('Связь роутеров работает на Xray. Установите его на странице VPN (Xray).')),
				E('div', { 'class': 'mv-act' }, [ E('a', { 'class': 'cbi-button cbi-button-action important', 'href': L.url('admin/vpn/miwrt-xray') }, _('Открыть VPN (Xray)')) ]) ]) ];
		if (!st.link) return [ E('div', { 'class': 'mv-cards' }, [ this.createCard(st), this.joinCard(st) ]) ];
		return st.link.role == 'exit' ? this.exitView(st) : this.insideView(st);
	},

	health: function(l) {
		var h = l.health;
		var nodes = [ mv.kicker(_('Состояние')) ];
		if (!h || h.ok == null) {
			nodes.push(E('div', { 'class': 'mv-big' }, [ E('span', { 'class': 'mv-dot' }), l.role == 'exit' ? _('Ждёт второй роутер') : _('Проверяется…') ]));
			if (l.role == 'exit' && !(l.peer_lans || []).length)
				nodes.push(E('div', { 'class': 'mv-note' }, _('Отсюда видно только, работает ли домашняя сеть другой стороны. Пока другая сторона её не открыла, состояние здесь не показывается; проверяйте на втором роутере.')));
			return nodes;
		}
		nodes.push(E('div', { 'class': 'mv-big' }, [ E('span', { 'class': 'mv-dot ' + (h.ok ? 'good' : 'bad') }), h.ok ? _('Связь есть') : _('Связи нет') ]));
		if (h.ok && h.exit_ip) nodes.push(E('div', { 'class': 'mv-text' }, _('Сайты видят адрес %s%s.').format(h.exit_ip, h.country ? ' (' + mv.country(h.country) + ')' : '')));
		if (h.ok && h.ms != null) nodes.push(E('div', { 'class': 'mv-note' }, _('Ответ за %d мс, проверено %s.').format(h.ms, mv.ago(h.time))));
		if (!h.ok) nodes.push(E('div', { 'class': 'mv-err' }, h.error || _('Другой роутер не отвечает.')));
		return nodes;
	},

	createCard: function(st) {
		var self = this;
		var meet = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'self', 'disabled': st.wan_public ? null : '' }, st.wan_public ? _('Этот роутер (%s)').format(st.wan_address) : _('Этот роутер (нет публичного адреса)')),
			E('option', { 'value': 'relay', 'selected': st.wan_public ? null : '' }, _('Арендованный сервер'))
		]);
		var host = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': st.wan_public ? st.wan_address : 'relay.example.net' });
		var hostNote = E('div', { 'class': 'mv-note' });
		var sync = function() {
			hostNote.textContent = meet.value == 'self'
				? _('Можно указать имя (DDNS) вместо адреса. Роутер откроет выбранный порт из интернета.')
				: _('Адрес сервера за границей. На нём должен работать Xray с настройками, которые роутер покажет после создания.');
		};
		meet.addEventListener('change', sync);
		sync();
		var port = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'value': '443', 'min': '1', 'max': '65535', 'style': 'width:110px' });
		var target = E('select', { 'class': 'cbi-input-select' }, (st.targets || []).map(function(t) { return E('option', { 'value': t }, t); }));
		var share = E('input', { 'type': 'checkbox' });
		var name = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': _('Роутер за границей') });
		return mv.card('', [
			E('h3', {}, _('Этот роутер за границей')),
			E('div', { 'class': 'mv-text' }, _('Он будет выходом в интернет для второго роутера. После создания роутер покажет код для второго роутера.')),
			mv.field(_('Место встречи'), meet),
			mv.field(_('Адрес'), host, hostNote),
			mv.field(_('Порт'), port),
			mv.field(_('Какой сайт изображать'), target, _('Соединение выглядит как обращение к этому сайту.')),
			mv.check(share, _('Открыть второму роутеру эту домашнюю сеть'), _('Устройства второго дома смогут обращаться к устройствам этого дома. Сам роутер и его настройки остаются закрыты.')),
			mv.field(_('Имя этого роутера'), name),
			E('div', { 'class': 'mv-act' }, [ mv.button(_('Создать связь'), function() {
				return mv.act(mv.callLink({ action: 'create', meet: meet.value, host: host.value, port: +port.value, target: target.value, share_lan: share.checked, name: name.value }))
					.then(L.bind(self.refresh, self));
			}, 'primary') ])
		]);
	},

	joinCard: function(st) {
		var self = this;
		var code = E('textarea', { 'placeholder': 'miwrt-link:…' });
		var share = E('input', { 'type': 'checkbox' });
		var name = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': _('Роутер дома') });
		return mv.card('', [
			E('h3', {}, _('Этот роутер подключается ко второму')),
			E('div', { 'class': 'mv-text' }, _('Он будет пользоваться интернетом второго роутера. Вставьте код, который показал тот роутер.')),
			mv.field(_('Код связи'), code),
			mv.check(share, _('Открыть второму роутеру эту домашнюю сеть'), _('Тогда роутер покажет ответный код: его нужно вставить на роутере за границей.')),
			mv.field(_('Имя этого роутера'), name),
			E('div', { 'class': 'mv-act' }, [ mv.button(_('Подключиться'), function() {
				return mv.act(mv.callLink({ action: 'join', code: code.value, share_lan: share.checked, name: name.value })).then(L.bind(self.refresh, self));
			}, 'primary') ])
		]);
	},

	shareCard: function(l) {
		var self = this;
		var cb = E('input', { 'type': 'checkbox', 'checked': l.share_lan ? '' : null });
		cb.addEventListener('change', function() {
			mv.act(mv.callLink({ action: 'set', share_lan: cb.checked })).then(L.bind(self.refresh, self));
		});
		return mv.card('', [
			E('h4', {}, _('Домашние сети')),
			mv.check(cb, _('Открыть второму роутеру эту домашнюю сеть'), (l.lans || []).length ? _('Сеть этого дома: %s').format(l.lans.join(', ')) : ''),
			(l.peer_lans || []).length ? E('div', { 'class': 'mv-text' }, _('Отсюда доступна сеть второго дома: %s').format(l.peer_lans.join(', '))) : ''
		]);
	},

	removeCard: function() {
		var self = this;
		return mv.card('', [
			E('div', { 'class': 'mv-note' }, _('После удаления второй роутер не сможет подключиться. Чтобы соединиться снова, нужна новая связь и новый код.')),
			E('div', { 'class': 'mv-act' }, [ mv.button(_('Удалить связь'), function() {
				if (!window.confirm(_('Удалить связь роутеров?'))) return;
				return mv.act(mv.callLink({ action: 'remove' })).then(L.bind(self.refresh, self));
			}, 'danger') ])
		]);
	},

	exitView: function(st) {
		var self = this, l = st.link;
		var answer = E('textarea', { 'placeholder': 'miwrt-link-answer:…' });
		var out = [
			E('div', { 'class': 'mv-card', 'id': 'mv-health' }, this.health(l)),
			mv.card('', [
				E('h3', {}, _('Код для второго роутера')),
				E('div', { 'class': 'mv-text' }, _('Вставьте этот код на втором роутере: Связь роутеров, «Этот роутер подключается ко второму». Код открывает доступ к вашему интернету, передавайте его только тому, кому доверяете.')),
				mv.codeBox(l.code),
				E('div', { 'class': 'mv-note' }, _('Место встречи: %s:%d.').format(l.address, l.port) + (l.meet == 'self' ? ' ' + _('Порт открыт из интернета правилом «MiWRT router link».') : ''))
			])
		];
		if (l.meet == 'relay') out.push(this.relayCard(l));
		if (!(l.peer_lans || []).length)
			out.push(mv.card('', [
				E('h4', {}, _('Ответный код')),
				E('div', { 'class': 'mv-text' }, _('Если второй роутер открыл свою домашнюю сеть, он показывает ответный код. Вставьте его сюда, чтобы устройства этого дома видели его сеть.')),
				answer,
				E('div', { 'class': 'mv-act' }, [ mv.button(_('Применить'), function() {
					return mv.act(mv.callLink({ action: 'answer', code: answer.value })).then(L.bind(self.refresh, self));
				}, 'primary') ])
			]));
		out.push(this.shareCard(l), this.removeCard());
		return out;
	},

	relayCard: function(l) {
		var box = E('div', {}, E('div', { 'class': 'mv-note' }, _('Загрузка…')));
		mv.callRelay().then(function(r) {
			if (!r || r.error) { dom.content(box, E('div', { 'class': 'mv-err' }, (r && r.error) || _('Не удалось получить настройки.'))); return; }
			var cfg = JSON.stringify(r.config, null, 2);
			var cmd = 'docker run -d --name miwrt-relay --restart unless-stopped -p ' + l.port + ':' + l.port +
				' -v "$PWD/config.json:/etc/xray/config.json:ro" ' + r.image + ' run -c /etc/xray/config.json';
			dom.content(box, [
				E('div', { 'class': 'mv-text' }, _('1. Сохраните эти настройки на сервере в файл config.json:')),
				mv.codeBox(cfg),
				E('div', { 'class': 'mv-text' }, _('2. Запустите Xray в Docker из той же папки:')),
				mv.codeBox(cmd),
				E('div', { 'class': 'mv-note' }, _('Порт %d на сервере должен быть открыт. В настройках есть ключи связи: храните файл так же бережно, как пароль.').format(l.port))
			]);
		});
		return mv.card('', [ E('h3', {}, _('Сервер для встречи')), box ]);
	},

	insideView: function(st) {
		var self = this, l = st.link;
		var inet = E('input', { 'type': 'checkbox', 'checked': l.internet ? '' : null });
		inet.addEventListener('change', function() {
			mv.act(mv.callLink({ action: 'set', internet: inet.checked })).then(L.bind(self.refresh, self));
		});
		var out = [
			E('div', { 'class': 'mv-card', 'id': 'mv-health' }, this.health(l)),
			mv.card('', [
				E('h3', {}, _('Интернет через %s').format(l.peer_name || _('второй роутер'))),
				mv.check(inet, _('Пользоваться интернетом второго роутера'), _('Тогда он появится среди серверов на странице VPN (Xray) как «%s». Выберите его там и включите VPN.').format(l.peer_name || '')),
				l.internet ? E('div', { 'class': 'mv-act' }, [ mv.button(_('Выбрать и включить VPN'), function() {
					return mv.act(mv.callSet({ server: 'link', enabled: true })).then(function(ok) {
						if (ok) ui.addNotification(null, E('p', {}, _('VPN включён через второй роутер.')), 'info');
					});
				}, 'primary') ]) : ''
			])
		];
		if (l.share_lan && l.answer)
			out.push(mv.card('', [
				E('h4', {}, _('Ответный код')),
				E('div', { 'class': 'mv-text' }, _('Вставьте его на роутере за границей, чтобы его устройства видели сеть этого дома.')),
				mv.codeBox(l.answer)
			]));
		out.push(this.shareCard(l), this.removeCard());
		return out;
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
