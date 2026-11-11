'use strict';
'require baseclass';
'require rpc';
'require ui';

// Icon paths from Tabler Icons (MIT licence, https://tabler.io/icons),
// drawn as 24x24 strokes.
const ICONS = {
	status: [ 'M3 12h4l3 8l4 -16l3 8h4' ],
	system: [ 'M10.325 4.317c.426 -1.756 2.924 -1.756 3.35 0a1.724 1.724 0 0 0 2.573 1.066c1.543 -.94 3.31 .826 2.37 2.37a1.724 1.724 0 0 0 1.065 2.572c1.756 .426 1.756 2.924 0 3.35a1.724 1.724 0 0 0 -1.066 2.573c.94 1.543 -.826 3.31 -2.37 2.37a1.724 1.724 0 0 0 -2.572 1.065c-.426 1.756 -2.924 1.756 -3.35 0a1.724 1.724 0 0 0 -2.573 -1.066c-1.543 .94 -3.31 -.826 -2.37 -2.37a1.724 1.724 0 0 0 -1.065 -2.572c-1.756 -.426 -1.756 -2.924 0 -3.35a1.724 1.724 0 0 0 1.066 -2.573c-.94 -1.543 .826 -3.31 2.37 -2.37c1 .608 2.296 .07 2.572 -1.065', 'M9 12a3 3 0 1 0 6 0a3 3 0 0 0 -6 0' ],
	services: [ 'M4 5a1 1 0 0 1 1 -1h4a1 1 0 0 1 1 1v4a1 1 0 0 1 -1 1h-4a1 1 0 0 1 -1 -1l0 -4', 'M4 15a1 1 0 0 1 1 -1h4a1 1 0 0 1 1 1v4a1 1 0 0 1 -1 1h-4a1 1 0 0 1 -1 -1l0 -4', 'M14 15a1 1 0 0 1 1 -1h4a1 1 0 0 1 1 1v4a1 1 0 0 1 -1 1h-4a1 1 0 0 1 -1 -1l0 -4', 'M14 7l6 0', 'M17 4l0 6' ],
	network: [ 'M3 12a9 9 0 1 0 18 0a9 9 0 0 0 -18 0', 'M3.6 9h16.8', 'M3.6 15h16.8', 'M11.5 3a17 17 0 0 0 0 18', 'M12.5 3a17 17 0 0 1 0 18' ],
	vpn: [ 'M12 3a12 12 0 0 0 8.5 3a12 12 0 0 1 -8.5 15a12 12 0 0 1 -8.5 -15a12 12 0 0 0 8.5 -3', 'M11 11a1 1 0 1 0 2 0a1 1 0 1 0 -2 0', 'M12 12l0 2.5' ],
	nas: [ 'M3 7a3 3 0 0 1 3 -3h12a3 3 0 0 1 3 3v2a3 3 0 0 1 -3 3h-12a3 3 0 0 1 -3 -3v-2', 'M3 15a3 3 0 0 1 3 -3h12a3 3 0 0 1 3 3v2a3 3 0 0 1 -3 3h-12a3 3 0 0 1 -3 -3l0 -2', 'M7 8l0 .01', 'M7 16l0 .01', 'M11 8h6', 'M11 16h6' ],
	statistics: [ 'M3 13a1 1 0 0 1 1 -1h4a1 1 0 0 1 1 1v6a1 1 0 0 1 -1 1h-4a1 1 0 0 1 -1 -1l0 -6', 'M15 9a1 1 0 0 1 1 -1h4a1 1 0 0 1 1 1v10a1 1 0 0 1 -1 1h-4a1 1 0 0 1 -1 -1l0 -10', 'M9 5a1 1 0 0 1 1 -1h4a1 1 0 0 1 1 1v14a1 1 0 0 1 -1 1h-4a1 1 0 0 1 -1 -1l0 -14', 'M4 20h14' ],
	docker: [ 'M12 3l8 4.5l0 9l-8 4.5l-8 -4.5l0 -9l8 -4.5', 'M12 12l8 -4.5', 'M12 12l0 9', 'M12 12l-8 -4.5' ],
	logout: [ 'M14 8v-2a2 2 0 0 0 -2 -2h-7a2 2 0 0 0 -2 2v12a2 2 0 0 0 2 2h7a2 2 0 0 0 2 -2v-2', 'M9 12h12l-3 -3', 'M18 15l3 -3' ],
	folder: [ 'M5 4h4l3 3h7a2 2 0 0 1 2 2v8a2 2 0 0 1 -2 2h-14a2 2 0 0 1 -2 -2v-11a2 2 0 0 1 2 -2' ],
	chevron: [ 'M9 6l6 6l-6 6' ],
	search: [ 'M3 10a7 7 0 1 0 14 0a7 7 0 1 0 -14 0', 'M21 21l-6 -6' ],
	auto: [ 'M3 5a1 1 0 0 1 1 -1h16a1 1 0 0 1 1 1v10a1 1 0 0 1 -1 1h-16a1 1 0 0 1 -1 -1v-10', 'M7 20h10', 'M9 16v4', 'M15 16v4' ],
	light: [ 'M8 12a4 4 0 1 0 8 0a4 4 0 1 0 -8 0', 'M3 12h1m8 -9v1m8 8h1m-9 8v1m-6.4 -15.4l.7 .7m12.1 -.7l-.7 .7m0 11.4l.7 .7m-12.1 -.7l-.7 .7' ],
	dark: [ 'M12 3c.132 0 .263 0 .393 0a7.5 7.5 0 0 0 7.92 12.446a9 9 0 1 1 -8.313 -12.454l0 .008' ],
	update: [ 'M20 11a8.1 8.1 0 0 0 -15.5 -2m-.5 -4v4h4', 'M4 13a8.1 8.1 0 0 0 15.5 2m.5 4v-4h-4' ],
	plug: [ 'M9.785 6l8.215 8.215l-2.054 2.054a5.81 5.81 0 1 1 -8.215 -8.215l2.054 -2.054', 'M4 20l3.5 -3.5', 'M15 4l-3.5 3.5', 'M20 9l-3.5 3.5' ]
};

const STRINGS = {
	en: {
		search: 'Search', placeholder: 'Go to a page or tab', empty: 'No page matches',
		auto: 'Auto', light: 'Light', dark: 'Dark', theme: 'Appearance', logout: 'Log out',
		open: 'open', move: 'move', close: 'close',
		newVersion: 'Update %s available',
		netifd: 'Restart network',
		netifdTitle: 'New network protocols need a restart',
		netifdText: 'These protocols were installed after the network started: %s. Interfaces that use them stay down until the network restarts.',
		netifdWarn: 'Wi-Fi and wired connections drop for 10 to 20 seconds. The page reloads by itself.',
		netifdLater: 'Later',
		netifdWait: 'Restarting the network...'
	},
	ru: {
		search: 'Поиск', placeholder: 'Перейти к странице или вкладке', empty: 'Нет подходящих страниц',
		auto: 'Авто', light: 'Светлая', dark: 'Тёмная', theme: 'Оформление', logout: 'Выйти',
		open: 'открыть', move: 'выбор', close: 'закрыть',
		newVersion: 'Доступно обновление %s',
		netifd: 'Перезапустить сеть',
		netifdTitle: 'Новым сетевым протоколам нужен перезапуск',
		netifdText: 'Эти протоколы установлены после запуска сети: %s. Интерфейсы с ними не поднимутся, пока сеть не перезапустится.',
		netifdWarn: 'Wi-Fi и проводная сеть пропадут на 10-20 секунд. Страница перезагрузится сама.',
		netifdLater: 'Позже',
		netifdWait: 'Сеть перезапускается...'
	},
	zh: {
		search: '搜索', placeholder: '跳转到页面或标签', empty: '没有匹配的页面',
		auto: '自动', light: '浅色', dark: '深色', theme: '外观', logout: '退出',
		open: '打开', move: '移动', close: '关闭',
		newVersion: '可更新到 %s',
		netifd: '重启网络',
		netifdTitle: '新的网络协议需要重启网络',
		netifdText: '以下协议在网络启动后才安装：%s。使用它们的接口要等网络重启后才能启动。',
		netifdWarn: 'Wi-Fi 和有线网络会断开 10 到 20 秒，页面会自动重新加载。',
		netifdLater: '稍后',
		netifdWait: '正在重启网络...'
	}
};

function icon(name) {
	const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
	svg.setAttribute('viewBox', '0 0 24 24');
	svg.setAttribute('aria-hidden', 'true');
	(ICONS[name] || ICONS.folder).forEach((d) => {
		const p = document.createElementNS('http://www.w3.org/2000/svg', 'path');
		p.setAttribute('d', d);
		svg.appendChild(p);
	});
	return svg;
}

function load(key, fallback) {
	try { const v = localStorage.getItem(key); return v != null ? v : fallback; } catch (e) { return fallback; }
}

function save(key, val) {
	try { localStorage.setItem(key, val); } catch (e) {}
}

return baseclass.extend({
	__init__() {
		const lang = (document.documentElement.getAttribute('lang') || 'en').toLowerCase();
		this.t = STRINGS[lang.indexOf('ru') === 0 ? 'ru' : lang.indexOf('zh') === 0 ? 'zh' : 'en'];
		this.pages = [];

		this.bindShell();
		ui.menu.load().then((tree) => this.render(tree));
	},

	setDrawer(open) {
		const btn = document.querySelector('#mw-menu-btn');
		document.body.classList.toggle('mw-drawer-open', open);
		if (btn)
			btn.setAttribute('aria-expanded', open ? 'true' : 'false');
		if (open) {
			const first = document.querySelector('#mw-side a, #mw-side button:not([hidden])');
			if (first)
				first.focus();
		}
	},

	bindShell() {
		const btn = document.querySelector('#mw-menu-btn');
		const scrim = document.querySelector('#mw-scrim');

		if (btn)
			btn.addEventListener('click', () => this.setDrawer(!document.body.classList.contains('mw-drawer-open')));

		if (scrim)
			scrim.addEventListener('click', () => this.setDrawer(false));

		document.addEventListener('keydown', (ev) => {
			const el = ev.target;
			const typing = el && (/^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName) || el.isContentEditable);

			if ((ev.key === 'k' || ev.key === 'K') && (ev.metaKey || ev.ctrlKey)) {
				ev.preventDefault();
				this.openPalette();
			}
			else if (ev.key === '/' && !typing && !document.body.classList.contains('modal-overlay-active')) {
				ev.preventDefault();
				this.openPalette();
			}
			else if (ev.key === 'Escape' && document.body.classList.contains('mw-drawer-open')) {
				this.setDrawer(false);
				if (btn)
					btn.focus();
			}
		});

		const isMac = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);
		const search = document.querySelector('#mw-search');

		if (search) {
			search.querySelector('.mw-search-label').textContent = this.t.search;
			search.querySelector('kbd').textContent = isMac ? '⌘K' : 'Ctrl K';
			search.addEventListener('click', () => this.openPalette());
			search.hidden = false;
		}

		this.renderThemeSwitch();
		this.checkUpdate();
		this.checkNetifd();
	},

	addNotice(node) {
		const end = document.querySelector('#mw-top-end');
		if (end)
			end.insertBefore(node, end.firstChild);
	},

	// be7000-update checks for a newer build once a day. Its last answer is
	// one local call away; the tab keeps it for ten minutes. Builds without
	// be7000-update reject the call and nothing shows.
	checkUpdate() {
		const KEY = 'mw-update-notice';
		let cached = null;

		try { cached = JSON.parse(sessionStorage.getItem(KEY)); } catch (e) {}

		const show = (version) => {
			if (!version || document.querySelector('.mw-notice-update'))
				return;

			const label = this.t.newVersion.replace('%s', version);
			this.addNotice(E('a', {
				'class': 'mw-notice mw-notice-update',
				'href': L.url('admin/system/be7000-update'),
				'title': label
			}, [ icon('update'), E('span', {}, [ label ]) ]));
		};

		if (cached && Date.now() - cached.at < 600000)
			return show(cached.version);

		rpc.declare({ object: 'be7000-update', method: 'status' })().then((res) => {
			const latest = res && res.latest;
			const version = latest && (latest.available === 1 || latest.available === true) ? latest.latest : '';

			try { sessionStorage.setItem(KEY, JSON.stringify({ at: Date.now(), version: version })); } catch (e) {}

			show(version);
		}).catch(() => {});
	},

	// netifd reads its protocol handlers once, at start. When a package adds
	// one later (gre, xl2tpd, 6in4...) be7000-netifd notes it, and interfaces
	// of that protocol stay down until the network restarts. This offers the
	// restart. On builds without be7000-netifd the call fails quietly.
	checkNetifd() {
		rpc.declare({ object: 'be7000-netifd', method: 'status' })().then((res) => {
			const pending = (res && Array.isArray(res.pending)) ? res.pending : [];

			if (!pending.length || document.querySelector('.mw-notice-netifd'))
				return;

			const btn = E('button', {
				'type': 'button',
				'class': 'mw-notice mw-notice-netifd',
				'title': this.t.netifdTitle
			}, [ icon('plug'), E('span', {}, [ this.t.netifd ]) ]);

			btn.addEventListener('click', () => {
				ui.showModal(this.t.netifdTitle, [
					E('p', {}, [ this.t.netifdText.replace('%s', pending.join(', ')) ]),
					E('p', {}, [ this.t.netifdWarn ]),
					E('div', { 'class': 'right' }, [
						E('button', { 'class': 'btn', 'click': ui.hideModal }, [ this.t.netifdLater ]),
						' ',
						E('button', {
							'class': 'btn cbi-button-action',
							'click': () => {
								ui.showModal(this.t.netifdTitle, [ E('p', { 'class': 'spinning' }, [ this.t.netifdWait ]) ]);
								rpc.declare({ object: 'be7000-netifd', method: 'restart' })().catch(() => {});
								window.setTimeout(() => { location.reload(); }, 20000);
							}
						}, [ this.t.netifd ])
					])
				]);
			});

			this.addNotice(btn);
		}).catch(() => {});
	},

	renderThemeSwitch() {
		const foot = document.querySelector('#mw-side-foot');
		if (!foot)
			return;

		let current = load('miwrt-theme', 'auto');
		const group = E('div', { 'class': 'mw-theme', 'role': 'radiogroup', 'aria-label': this.t.theme });
		const opts = [];

		const select = (mode, focus) => {
			current = mode;
			window.miwrtSetTheme(mode);
			opts.forEach((o) => {
				const on = (o.getAttribute('data-mode') === mode);
				o.setAttribute('aria-checked', on ? 'true' : 'false');
				o.tabIndex = on ? 0 : -1;
				if (on && focus)
					o.focus();
			});
		};

		[ 'auto', 'light', 'dark' ].forEach((mode, i, all) => {
			const b = E('button', {
				'type': 'button',
				'class': 'mw-theme-opt',
				'role': 'radio',
				'aria-checked': mode === current ? 'true' : 'false',
				'tabindex': mode === current ? '0' : '-1',
				'title': this.t[mode],
				'data-mode': mode
			}, [ icon(mode), E('span', {}, [ this.t[mode] ]) ]);

			b.addEventListener('click', () => select(mode));
			b.addEventListener('keydown', (ev) => {
				const step = (ev.key === 'ArrowRight' || ev.key === 'ArrowDown') ? 1 : (ev.key === 'ArrowLeft' || ev.key === 'ArrowUp') ? -1 : 0;
				if (step) {
					ev.preventDefault();
					select(all[(i + step + all.length) % all.length], true);
				}
			});

			opts.push(b);
			group.appendChild(b);
		});

		foot.appendChild(group);
	},

	render(tree) {
		this.renderModeMenu(tree);

		const path = L.env.dispatchpath || [];
		let node = tree;
		let url = '';

		if (path.length >= 3) {
			for (let i = 0; i < 3 && node; i++) {
				node = node.children[path[i]];
				url = url + (url ? '/' : '') + path[i];
			}

			if (node)
				this.renderTabMenu(node, url);
		}

		this.renderCrumbs(tree);
	},

	renderModeMenu(tree) {
		const ul = document.querySelector('#modemenu');
		const children = ui.menu.getChildren(tree);
		const req = L.env.requestpath || [];

		children.forEach((child, index) => {
			const isActive = req.length ? child.name === req[0] : index === 0;

			ul.appendChild(E('li', { 'class': isActive ? 'active' : '' }, [
				E('a', { 'href': L.url(child.name) }, [ _(child.title) ])
			]));

			if (isActive)
				this.renderMainMenu(child, child.name);
		});

		if (ul.children.length > 1)
			ul.style.display = '';
	},

	renderMainMenu(tree, url) {
		const nav = document.querySelector('#topmenu');
		const foot = document.querySelector('#mw-side-foot');
		const path = L.env.dispatchpath || [];
		let openState = {};

		try { openState = JSON.parse(load('miwrt-nav-open', '{}')) || {}; } catch (e) {}

		ui.menu.getChildren(tree).forEach((cat) => {
			const pages = ui.menu.getChildren(cat);
			const catActive = (path[1] === cat.name);

			if (cat.name === 'logout') {
				if (foot)
					foot.appendChild(E('a', { 'class': 'mw-logout', 'href': L.url(url, cat.name) }, [
						icon('logout'), E('span', {}, [ this.t.logout ])
					]));
				return;
			}

			if (!pages.length) {
				const attrs = { 'class': 'mw-nav-single' + (catActive ? ' active' : ''), 'href': L.url(url, cat.name) };
				if (catActive)
					attrs['aria-current'] = 'page';

				nav.appendChild(E('a', attrs, [ icon(cat.name), E('span', {}, [ _(cat.title) ]) ]));
				this.pages.push({ title: _(cat.title), group: '', url: L.url(url, cat.name) });
				return;
			}

			const isOpen = catActive || openState[cat.name] === true;
			const subId = 'mw-nav-' + cat.name.replace(/[^a-z0-9_-]/gi, '');
			const sub = E('ul', { 'class': 'mw-nav-sub', 'id': subId });
			const group = E('div', { 'class': 'mw-nav-group' + (catActive ? ' active' : '') + (isOpen ? ' open' : '') });

			const head = E('button', {
				'type': 'button',
				'class': 'mw-nav-head',
				'aria-expanded': isOpen ? 'true' : 'false',
				'aria-controls': subId
			}, [
				icon(cat.name),
				E('span', { 'class': 'mw-nav-title' }, [ _(cat.title) ]),
				E('span', { 'class': 'mw-nav-chev' }, [ icon('chevron') ])
			]);

			head.addEventListener('click', () => {
				const open = !group.classList.contains('open');
				group.classList.toggle('open', open);
				head.setAttribute('aria-expanded', open ? 'true' : 'false');
				openState[cat.name] = open;
				save('miwrt-nav-open', JSON.stringify(openState));
			});

			pages.forEach((page) => {
				const active = catActive && path[2] === page.name;
				const href = L.url(url, cat.name, page.name);
				const attrs = { 'href': href };

				if (active) {
					attrs['class'] = 'active';
					attrs['aria-current'] = 'page';
				}

				sub.appendChild(E('li', {}, [ E('a', attrs, [ _(page.title) ]) ]));
				this.pages.push({ title: _(page.title), group: _(cat.title), url: href });

				ui.menu.getChildren(page).forEach((tab) => {
					this.pages.push({
						title: _(tab.title),
						group: _(cat.title) + ' / ' + _(page.title),
						url: L.url(url, cat.name, page.name, tab.name)
					});
				});
			});

			group.appendChild(head);
			group.appendChild(sub);
			nav.appendChild(group);
		});

		const active = nav.querySelector('.mw-nav-sub a.active');
		if (active && active.scrollIntoView)
			active.scrollIntoView({ block: 'nearest' });
	},

	renderTabMenu(tree, url, level) {
		const container = document.querySelector('#tabmenu');
		const ul = E('ul', { 'class': 'tabs' });
		const children = ui.menu.getChildren(tree);
		let activeNode = null;

		children.forEach((child) => {
			const isActive = (L.env.dispatchpath[3 + (level || 0)] == child.name);
			const attrs = { 'href': L.url(url, child.name) };

			if (isActive)
				attrs['aria-current'] = 'page';

			ul.appendChild(E('li', { 'class': 'tabmenu-item-%s %s'.format(child.name, isActive ? 'active' : '') }, [
				E('a', attrs, [ _(child.title) ])
			]));

			if (isActive)
				activeNode = child;
		});

		if (ul.children.length == 0)
			return E([]);

		container.appendChild(ul);
		container.style.display = '';

		const act = ul.querySelector('li.active');
		if (act)
			requestAnimationFrame(() => { ul.scrollLeft = act.offsetLeft - 16; });

		if (activeNode)
			this.renderTabMenu(activeNode, url + '/' + activeNode.name, (level || 0) + 1);

		return ul;
	},

	renderCrumbs(tree) {
		const crumbs = document.querySelector('#mw-crumbs');
		const path = L.env.dispatchpath || [];
		const items = [];
		let node = tree;
		let url = '';

		if (!crumbs)
			return;

		for (let i = 0; i < path.length && node && node.children; i++) {
			node = node.children[path[i]];
			url = url + (url ? '/' : '') + path[i];

			if (i === 0 || !node || !node.title)
				continue;

			items.push({ title: _(node.title), url: L.url(url) });
		}

		const ol = E('ol', {});

		items.forEach((item, i) => {
			const last = (i === items.length - 1);
			ol.appendChild(E('li', {}, [
				last ? E('span', { 'aria-current': 'page' }, [ item.title ]) : E('a', { 'href': item.url }, [ item.title ])
			]));
		});

		crumbs.appendChild(ol);
	},

	openPalette() {
		if (this.palette) {
			this.lastFocus = document.activeElement;
			this.palette.classList.add('open');
			this.paletteInput.value = '';
			this.filterPalette('');
			this.paletteInput.focus();
			return;
		}

		this.lastFocus = document.activeElement;

		const input = E('input', {
			'type': 'search',
			'class': 'mw-pal-input',
			'placeholder': this.t.placeholder,
			'autocomplete': 'off',
			'spellcheck': 'false',
			'role': 'combobox',
			'aria-expanded': 'true',
			'aria-controls': 'mw-pal-list',
			'aria-label': this.t.search
		});

		const list = E('ul', { 'class': 'mw-pal-list', 'id': 'mw-pal-list', 'role': 'listbox' });
		const box = E('div', { 'class': 'mw-pal-box', 'role': 'dialog', 'aria-modal': 'true', 'aria-label': this.t.search }, [
			E('div', { 'class': 'mw-pal-search' }, [ icon('search'), input, E('kbd', {}, [ 'Esc' ]) ]),
			list,
			E('div', { 'class': 'mw-pal-hint' }, [
				E('span', {}, [ E('kbd', {}, [ '↑' ]), E('kbd', {}, [ '↓' ]), ' ', this.t.move ]),
				E('span', {}, [ E('kbd', {}, [ '↵' ]), ' ', this.t.open ]),
				E('span', {}, [ E('kbd', {}, [ 'Esc' ]), ' ', this.t.close ])
			])
		]);

		const overlay = E('div', { 'class': 'mw-pal open' }, [ box ]);

		overlay.addEventListener('mousedown', (ev) => {
			if (ev.target === overlay)
				this.closePalette();
		});

		input.addEventListener('input', () => this.filterPalette(input.value));
		input.addEventListener('keydown', (ev) => {
			if (ev.key === 'ArrowDown' || ev.key === 'ArrowUp') {
				ev.preventDefault();
				this.movePalette(ev.key === 'ArrowDown' ? 1 : -1);
			}
			else if (ev.key === 'Enter') {
				ev.preventDefault();
				const sel = list.querySelector('li.active a');
				if (sel)
					window.location.href = sel.getAttribute('href');
			}
			else if (ev.key === 'Escape') {
				ev.preventDefault();
				ev.stopPropagation();
				this.closePalette();
			}
			else if (ev.key === 'Tab') {
				ev.preventDefault();
			}
		});

		document.body.appendChild(overlay);

		this.palette = overlay;
		this.paletteInput = input;
		this.paletteList = list;

		this.filterPalette('');
		input.focus();
	},

	closePalette() {
		if (!this.palette)
			return;

		this.palette.classList.remove('open');
		if (this.lastFocus && this.lastFocus.focus)
			this.lastFocus.focus();
	},

	filterPalette(query) {
		const list = this.paletteList;
		const q = String(query || '').trim().toLowerCase();
		const words = q.split(/\s+/).filter(Boolean);

		const scored = this.pages.map((p) => {
			const title = p.title.toLowerCase();
			const hay = (p.group + ' ' + p.title).toLowerCase();
			let score;

			if (!words.length)
				return { p, score: 1 };

			if (!words.every((w) => hay.indexOf(w) >= 0))
				return { p, score: 0 };

			score = title.indexOf(q) === 0 ? 100 : title.indexOf(q) >= 0 ? 60 : 20;
			return { p, score: score - p.group.length / 100 };
		}).filter((s) => s.score > 0);

		if (words.length)
			scored.sort((a, b) => b.score - a.score);

		list.innerHTML = '';

		scored.slice(0, 60).forEach((s, i) => {
			const li = E('li', {
				'class': i === 0 ? 'active' : '',
				'role': 'option',
				'id': 'mw-pal-opt-' + i,
				'aria-selected': i === 0 ? 'true' : 'false'
			}, [
				E('a', { 'href': s.p.url, 'tabindex': '-1' }, [
					E('span', { 'class': 'mw-pal-title' }, [ s.p.title ]),
					s.p.group ? E('span', { 'class': 'mw-pal-group' }, [ s.p.group ]) : ''
				])
			]);

			li.addEventListener('mousemove', () => this.markPalette(li));
			list.appendChild(li);
		});

		if (!scored.length)
			list.appendChild(E('li', { 'class': 'mw-pal-empty' }, [ this.t.empty ]));

		const first = list.querySelector('li[role="option"]');
		this.paletteInput.setAttribute('aria-activedescendant', first ? first.id : '');
	},

	markPalette(li) {
		this.paletteList.querySelectorAll('li.active').forEach((a) => {
			a.classList.remove('active');
			a.setAttribute('aria-selected', 'false');
		});
		li.classList.add('active');
		li.setAttribute('aria-selected', 'true');
		this.paletteInput.setAttribute('aria-activedescendant', li.id);
	},

	movePalette(dir) {
		const items = Array.from(this.paletteList.querySelectorAll('li[role="option"]'));
		if (!items.length)
			return;

		let idx = items.findIndex((li) => li.classList.contains('active'));
		idx = (idx + dir + items.length) % items.length;
		this.markPalette(items[idx]);
		items[idx].scrollIntoView({ block: 'nearest' });
	}
});
