'use strict';
'require view';
'require rpc';
'require ui';
'require poll';

var callStatus = rpc.declare({ object: 'be7000-storage', method: 'status' });
var callList = rpc.declare({ object: 'be7000-storage', method: 'list' });
var callUse = rpc.declare({ object: 'be7000-storage', method: 'use', params: ['device'] });
var callRevert = rpc.declare({ object: 'be7000-storage', method: 'revert' });
var callJob = rpc.declare({ object: 'be7000-storage', method: 'job' });
var callResetStatus = rpc.declare({ object: 'be7000-storage', method: 'reset_status' });
var callResetCancel = rpc.declare({ object: 'be7000-storage', method: 'reset_cancel' });
var callReboot = rpc.declare({ object: 'system', method: 'reboot', expect: { result: 0 } });

// "use" only starts the job; wait for it here, polling every 2 s.
function waitJob() {
	return new Promise(function(resolve) {
		var tick = function() {
			callJob().then(function(res) {
				if (res && res.done)
					resolve(res);
				else
					window.setTimeout(tick, 2000);
			}).catch(function() {
				window.setTimeout(tick, 2000);
			});
		};
		window.setTimeout(tick, 2000);
	});
}

function mb(kb) {
	// 0 is a real answer (a full overlay), only a missing value is unknown
	if (kb == null || isNaN(kb))
		return '—';
	return _('%.1f МБ').format(kb / 1024);
}

function gb(sizeMb) {
	if (!sizeMb)
		return '—';
	if (sizeMb >= 1024)
		return _('%.1f ГБ').format(sizeMb / 1024);
	return _('%d МБ').format(sizeMb);
}

return view.extend({
	load: function() {
		return Promise.all([
			callStatus().catch(function() { return {}; }),
			callList().catch(function() { return {}; }),
			callResetStatus().catch(function() { return {}; })
		]);
	},

	// The settings as an archive, the one System, Backup gives: asked for
	// before a reset is cancelled, while the settings in use are still the
	// only copy of what the router runs with.
	handleBackup: function(ev) {
		var form = E('form', {
			'method': 'post',
			'action': L.env.cgi_base + '/cgi-backup',
			'enctype': 'application/x-www-form-urlencoded'
		}, E('input', { 'type': 'hidden', 'name': 'sessionid', 'value': rpc.getSessionID() }));
		document.body.appendChild(form);
		form.submit();
		form.parentNode.removeChild(form);
	},

	handleReboot: function() {
		ui.showModal(_('Перезагрузка'), [
			E('p', {}, _('Роутер перезагрузится и попробует завершить сброс. Это займёт несколько минут.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Отмена')),
				' ',
				E('button', {
					'class': 'btn cbi-button-action',
					'click': function() {
						ui.showModal(_('Перезагрузка'), [E('p', { 'class': 'spinning' }, _('Роутер перезагружается'))]);
						callReboot().then(function() {
							ui.awaitReconnect();
						}).catch(function(err) {
							ui.hideModal();
							ui.addNotification(null, E('p', {}, String(err)), 'error');
						});
					}
				}, _('Перезагрузить'))
			])
		]);
	},

	handleResetCancel: function(rs) {
		var self = this;
		ui.showModal(_('Отменить сброс настроек'), [
			rs.inslot
				? E('p', {}, _('Сброс будет отменён. Роутер останется на встроенной памяти слота с теми настройками, которые у него сейчас. На диске ничего не меняется и не стирается.'))
				: E('p', {}, _('Сброс будет отменён, всё останется как было до него.')),
			rs.inslot
				? E('p', {}, _('Раздел данных роутер после этого сам использовать не будет. Чтобы получить больше места, перенесите /overlay на USB-диск на этой странице.'))
				: E('span'),
			E('p', {}, _('Сначала можно скачать резервную копию нынешних настроек.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Отмена')),
				' ',
				E('button', { 'class': 'btn cbi-button-action', 'click': function(ev) { self.handleBackup(ev); } }, _('Скачать резервную копию')),
				' ',
				E('button', {
					'class': 'btn cbi-button-negative',
					'click': function() {
						ui.showModal(_('Отменить сброс настроек'), [E('p', { 'class': 'spinning' }, _('Отменяю сброс'))]);
						callResetCancel().then(function(res) {
							ui.hideModal();
							if (res && res.ok)
								ui.addNotification(null, E('p', {}, _('Сброс отменён.')), 'info');
							else
								ui.addNotification(null, E('pre', {}, (res && res.error) || _('Не получилось')), 'error');
							self.reload();
						}).catch(function(err) {
							ui.hideModal();
							ui.addNotification(null, E('p', {}, String(err)), 'error');
						});
					}
				}, _('Отменить сброс'))
			])
		]);
	},

	// Why a factory reset has not finished, in words. The hook that carries
	// the reset out leaves one of a few reasons; what is plugged in right now
	// is looked up when the page loads.
	resetWhy: function(rs) {
		if (!rs.tried && !rs.inslot)
			return _('Сброс запланирован и выполнится при следующей загрузке роутера.');
		if (rs.present && rs.kind == 'disk' && (rs.why == 'absent' || !rs.why))
			return _('При прошлой загрузке диск не появился вовремя. Сейчас он подключён: перезагрузите роутер, и сброс завершится.');
		switch (rs.why) {
		case 'absent':
			if (rs.kind != 'disk')
				return _('Раздел, на котором лежал /overlay, не нашёлся при загрузке.');
			return rs.disks
				? _('Диска с той файловой системой, на которой был запрошен сброс, нет. Подключён другой диск, или этот диск с тех пор отформатирован. Такой диск роутер сам не очищает.')
				: _('Диск, на котором лежал /overlay, не появился за 15 секунд при загрузке. Подключите его и перезагрузите роутер.');
		case 'mount':
			return _('Файловая система нашлась, но не подключилась. Возможно, она повреждена.');
		case 'token':
			return _('Файловая система нашлась, но метки сброса на ней нет или она другая. Роутер ничего на ней не менял.');
		case 'write':
			return _('Не получилось записать на раздел с /overlay. Проверьте диск.');
		case 'internal':
			return _('Не получилось записать во встроенную память слота.');
		}
		return _('Роутер ещё не пробовал выполнить сброс или не записал причину. Перезагрузите его.');
	},

	resetSection: function(rs) {
		var self = this;
		var where = rs.device || '—';
		if (rs.uuid)
			where = '%s, UUID %s'.format(where, rs.uuid);
		if (rs.now && rs.now != rs.device)
			where = _('%s (сейчас это %s)').format(where, rs.now);

		var buttons = [
			E('button', { 'class': 'btn cbi-button-action', 'click': function() { self.handleReboot(); } }, _('Перезагрузить'))
		];
		if (rs.cancellable)
			buttons.push(' ', E('button', { 'class': 'btn cbi-button-negative', 'click': function() { self.handleResetCancel(rs); } }, _('Отменить сброс')));

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Сброс настроек не завершён')),
			E('p', { 'class': 'alert-message warning' }, this.resetWhy(rs)),
			E('p', {}, _('Сброс ждёт раздел: %s').format(where)),
			rs.inslot
				? E('p', {}, _('Пока сброс не завершён или не отменён, роутер работает со встроенной памяти слота, а перенос /overlay и переключение слотов отключены.'))
				: E('span'),
			rs.cancellable
				? E('span')
				: E('p', {}, _('Сброс встроенной памяти здесь отменить нельзя.')),
			E('div', { 'class': 'mw-button-row', 'style': 'margin-top:12px' }, buttons)
		]);
	},

	reload: function() {
		var self = this;
		return this.load().then(function(data) {
			var fresh = self.render(data);
			var node = document.getElementById('hf-storage');
			if (node && fresh)
				node.parentNode.replaceChild(fresh, node);
		});
	},

	handleUse: function(dev, label) {
		var self = this;
		ui.showModal(_('Перенести /overlay на %s').format(dev), [
			E('p', {}, _('Диск будет отформатирован, всё его содержимое пропадёт.')),
			E('p', {}, _('Текущие настройки и установленные пакеты переедут на него. Изменение вступит в силу после перезагрузки.')),
			E('p', { 'class': 'alert-message warning' }, label || dev),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Отмена')),
				' ',
				E('button', {
					'class': 'btn cbi-button-negative',
					'click': function() {
						ui.showModal(_('Переношу'), [E('p', { 'class': 'spinning' }, _('Форматирование и копирование, это может занять минуту'))]);
						callUse(dev).then(function(res) {
							return (res && res.started) ? waitJob() : res;
						}).then(function(res) {
							ui.hideModal();
							if (res && res.ok) {
								ui.addNotification(null, E('p', {}, _('Готово. Перезагрузите роутер, чтобы /overlay переехал.')), 'info');
								self.reload();
							}
							else {
								ui.addNotification(null, E('pre', {}, (res && res.output) || _('Не получилось')), 'error');
							}
						}).catch(function(err) {
							ui.hideModal();
							ui.addNotification(null, E('p', {}, String(err)), 'error');
						});
					}
				}, _('Форматировать и перенести'))
			])
		]);
	},

	handleRevert: function() {
		var self = this;
		ui.showModal(_('Вернуть /overlay на внутреннюю флешку'), [
			E('p', {}, _('Данные на диске останутся, но использоваться перестанут. Изменение вступит в силу после перезагрузки.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Отмена')),
				' ',
				E('button', {
					'class': 'btn cbi-button-action',
					'click': function() {
						callRevert().then(function(res) {
							ui.hideModal();
							if (res && res.ok) {
								ui.addNotification(null, E('p', {}, _('Готово. Перезагрузите роутер.')), 'info');
								self.reload();
							}
							else {
								ui.addNotification(null, E('pre', {}, (res && res.output) || _('Не получилось')), 'error');
							}
						});
					}
				}, _('Вернуть'))
			])
		]);
	},

	render: function(data) {
		var self = this;
		var status = (data[0] && data[0].data) || {};
		var disks = (data[1] && data[1].data) || [];
		var reset = data[2] || {};
		var waiting = reset.pending === true;

		var rows = [];
		if (!disks.length) {
			rows.push(E('p', {}, _('Накопители не найдены. Вставьте диск в порт USB и обновите страницу.')));
		}
		else {
			var table = E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('Устройство')),
					E('th', { 'class': 'th' }, _('Размер')),
					E('th', { 'class': 'th' }, _('Модель')),
					E('th', { 'class': 'th' }, '')
				])
			]);
			disks.forEach(function(d) {
				var action;
				if (d.mounted) {
					action = E('span', {}, _('используется'));
				}
				else if (waiting) {
					// the tool refuses while a reset waits, so do not offer it
					action = E('span', {}, '—');
				}
				else {
					action = E('button', {
						'class': 'btn cbi-button-action',
						'click': function() { self.handleUse(d.device, d.model); }
					}, _('Перенести сюда'));
				}
				table.appendChild(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, d.device),
					E('td', { 'class': 'td' }, gb(d.size_mb)),
					E('td', { 'class': 'td' }, d.model || '—'),
					E('td', { 'class': 'td' }, action)
				]));
			});
			rows.push(table);
		}

		var onExternal = status.extroot_enabled === '1';

		var kv = function(label, value) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'width': '33%' }, label),
				E('td', { 'class': 'td' }, value)
			]);
		};

		return E('div', { 'id': 'hf-storage', 'class': 'cbi-map' }, [
			E('h2', {}, _('Накопитель')),
			E('div', { 'class': 'cbi-map-descr' }, _('Всё, что роутер помнит между перезагрузками, лежит в /overlay. Это настройки, установленные пакеты и списки. Встроенного места немного, поэтому его можно перенести на USB-диск.')),

			waiting ? this.resetSection(reset) : E('span'),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Сейчас')),
				E('table', { 'class': 'table' }, [
					kv(_('Раздел'), status.device || '—'),
					kv(_('Всего'), mb(status.total_kb)),
					kv(_('Свободно'), mb(status.available_kb))
				]),
				(onExternal && !waiting) ? E('div', { 'class': 'mw-button-row', 'style': 'margin-top:12px' }, [
					E('button', {
						'class': 'btn cbi-button-reset',
						'click': function() { self.handleRevert(); }
					}, _('Вернуть на внутреннюю флешку'))
				]) : E('span')
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Доступные диски')),
				E('div', {}, rows)
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
