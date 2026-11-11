'use strict';
'require view';
'require rpc';
'require uqr';

/*
 * MiWRT setup assistant: shown once, on a router set up from scratch (see miwrt/setup.uc).
 * One question per page, everything prefilled from the router's current settings, nothing changes on
 * the router until the last page. Text in English, Russian and Chinese; the page follows the language
 * picked on it, so it can be read before the web interface itself is switched.
 */

const APP_URL = 'https://apps.apple.com/app/id6819293819';
const KEEP = 'miwrt-setup-v1';
const ORDER = [ 'region', 'mode', 'wifi', 'guest', 'iot', 'protect', 'password', 'review' ];
const ART = { region: 'region', mode: 'mode', wifi: 'wifi', guest: 'guest', iot: 'iot', protect: 'protect', password: 'password', review: 'wifi', apply: 'wifi', done: 'app' };
const COUNTRIES = ('AD AE AF AG AI AL AM AO AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BW BY BZ ' +
	'CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR ' +
	'GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GT GU GW GY HK HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE ' +
	'KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT ' +
	'MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU ' +
	'RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA ' +
	'UG US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW').split(' ');

const callStatus = rpc.declare({ object: 'miwrt-setup', method: 'status' });
const callTest = rpc.declare({ object: 'miwrt-setup', method: 'adguard_test', params: [ 'url', 'username', 'password' ] });
const callApply = rpc.declare({ object: 'miwrt-setup', method: 'apply', params: [ 'config' ] });
const callSkip = rpc.declare({ object: 'miwrt-setup', method: 'skip' });

/* ------------------------------------------------------------------ */
/* Text                                                               */
/* ------------------------------------------------------------------ */

const STR = {
	en: {
		brand_sub: 'Setup',
		step_of: 'Step {0} of {1}',
		progress: 'Setup progress',
		done_sr: 'done',
		back: 'Back',
		next: 'Continue',
		skip: 'Skip setup',
		show: 'Show password',
		hide: 'Hide password',
		generate: 'Suggest one',
		change: 'Change',
		back_review: 'Back to review',
		optional: 'optional',
		on: 'On',
		off: 'Off',
		recommended: 'Recommended',
		your_router: 'your router',
		lang_label: 'Language',
		e_fix: 'Check the highlighted fields.',
		e_generic: 'Something went wrong: {0}',
		e_router_said: 'The router answered: {0}',

		s_region: 'Region',
		s_mode: 'Connection',
		s_wifi: 'Wi-Fi',
		s_guest: 'Guests',
		s_iot: 'Smart home',
		s_protect: 'Ad blocking',
		s_password: 'Password',
		s_review: 'Review',

		w_title: 'Let’s set up your router',
		w_lede: 'A few short steps and {0} is ready: internet, Wi-Fi, a guest network, smart-home devices, ad blocking and a password. It takes about three minutes, and nothing changes until the last step.',
		w_start: 'Start',
		w_imported: 'Your settings from the Xiaomi firmware were brought over and are filled in, so you can keep them.',
		w_list: 'What you will set up',
		w_skip_q: 'Skip the setup assistant?',
		w_skip_text: 'You can set everything up yourself in the web interface. The router has no password yet: set one under System, Administration straight away.',
		w_skip_yes: 'Skip',
		w_skip_no: 'Keep going',

		r_title: 'Where is the router?',
		r_lede: 'The country decides which Wi-Fi channels and power are allowed. The time zone keeps schedules and logs right.',
		r_lang: 'Language of the web interface',
		r_lang_auto: 'Same as the browser',
		r_country: 'Country',
		r_country_ph: 'Choose a country',
		r_zone: 'Time zone',
		r_zone_hint: 'This device is set to {0}.',
		e_country: 'Choose the country the router is in.',
		e_zone: 'Choose a time zone.',

		m_title: 'How does it connect?',
		m_lede: 'Choose what this router does in your home.',
		m_router: 'Main router',
		m_router_d: 'Connects to your modem, fibre box or the internet socket, and runs your home network.',
		m_ap: 'Access point',
		m_ap_d: 'You already have a router. This one adds Wi-Fi to its network over a cable.',
		m_ap_note: 'Plug a cable from your main router into this router’s WAN port. Guest and smart-home networks and ad blocking on this router need the main-router mode.',
		m_inet: 'Internet connection',
		m_dhcp: 'Automatic',
		m_dhcp_d: 'Most cable, fibre and modem connections (DHCP).',
		m_pppoe: 'PPPoE',
		m_pppoe_d: 'Your provider gave you a user name and password.',
		m_static: 'Fixed address',
		m_static_d: 'Your provider gave you an IP address to enter.',
		m_user: 'User name',
		m_pass: 'Password',
		m_vlan: 'VLAN ID',
		m_vlan_h: 'Only if your provider asks for one.',
		m_ip: 'IP address',
		m_mask: 'Subnet mask',
		m_gw: 'Gateway',
		m_dns: 'DNS servers',
		m_dns_h: 'Separate several with spaces. Leave empty to use the ones from the provider.',
		m_link_up: 'A cable is plugged into the internet (WAN) port.',
		m_link_down: 'Nothing is plugged into the internet (WAN) port yet.',
		m_ap_addr: 'Address of this router',
		m_ap_dhcp: 'From the main router',
		m_ap_dhcp_d: 'Simplest. You find the address later in the main router’s list of devices.',
		m_ap_static_d: 'You choose a free address in the main router’s network.',
		m_ap_gw: 'Main router’s address',
		m_ap_dns_h: 'Leave empty to use the main router.',
		e_user: 'Enter the user name your provider gave you.',
		e_vlan: 'A VLAN ID is a number from 1 to 4094.',
		e_ip: 'Enter an address such as 192.168.1.2.',
		e_mask: 'Enter a subnet mask such as 255.255.255.0.',
		e_dns: 'Each DNS server must be an IPv4 address.',
		e_chars: 'This contains characters that cannot be used.',

		f_title: 'Name your Wi-Fi',
		f_lede: 'Keep the name and password your devices already know, and they reconnect by themselves.',
		f_name: 'Wi-Fi name',
		f_name5: '5 GHz Wi-Fi name',
		f_pass: 'Wi-Fi password',
		f_pass_h: '8 to 63 characters. Longer is stronger.',
		f_split: 'Separate name for 5 GHz',
		f_split_d: 'Usually best off: with one name, devices pick the fastest band by themselves.',
		f_sec: 'Security',
		f_sae: 'WPA2/WPA3',
		f_sae_d: 'The strongest protection; older devices still join.',
		f_psk2: 'WPA2 only',
		f_psk2_d: 'For the few old devices that cannot join otherwise.',
		e_ssid_empty: 'Enter a Wi-Fi name.',
		e_ssid: 'A Wi-Fi name can be at most 32 bytes (letters outside A–Z take 2 or 3).',
		e_key: 'A Wi-Fi password needs 8 to 63 characters: Latin letters, digits and common symbols.',
		e_same5: 'Give the 5 GHz network a different name, or use one name for both.',
		e_unique: 'Each network needs a name of its own.',
		st_label: 'Strength: {0}',
		st_0: 'too short',
		st_1: 'weak',
		st_2: 'fair',
		st_3: 'strong',
		st_4: 'very strong',

		g_title: 'A Wi-Fi for guests',
		g_lede: 'Guests get the internet and nothing else: they cannot see your computers, phones or each other.',
		g_on: 'Guest network',
		g_on_d: 'From the app you can share it with a QR code and let it switch off by itself.',
		g_name: 'Guest Wi-Fi name',
		g_pass: 'Guest Wi-Fi password',

		i_title: 'A network for smart-home devices',
		i_lede: 'Plugs, cameras, bulbs and TVs on a network of their own. Your phone still controls them, but they cannot reach your computers.',
		i_on: 'Smart-home network',
		i_on_d: 'Uses WPA2, which every smart device can join.',
		i_name: 'Smart-home Wi-Fi name',
		i_pass: 'Smart-home Wi-Fi password',
		i_inet: 'Internet access',
		i_inet_d: 'Many devices need it for their app. Turn it off for devices that should only work at home.',
		i_5g: 'Also on 5 GHz',
		i_5g_d: 'Most smart devices only use 2.4 GHz, so this is off by default.',
		i_exists: 'This router already has a smart-home (IoT) network set up by hand. Change it under Network, Wireless.',

		p_title: 'Block ads and trackers',
		p_lede: 'AdGuard Home filters ads, trackers and harmful sites for every device in the house, without installing anything on them.',
		p_none: 'Not now',
		p_none_d: 'You can add it later from the app.',
		p_router: 'On this router',
		p_router_d: 'MiWRT installs AdGuard Home after setup (a download of about 30 MB) and looks after it.',
		p_router_after: 'Its own page will be http://{0}:3000, user admin, with the router password you choose in the next step.',
		p_net: 'On another device',
		p_net_d: 'You already run AdGuard Home, for example on a Raspberry Pi.',
		p_keep: 'Keep the current one',
		p_keep_d: 'AdGuard Home at {0}',
		p_why_mode: 'Needs the main-router mode.',
		p_why_storage: 'Needs {0} MB of free storage and {1} MB is free. Add storage (a USB drive or the spare slot), then install it from the app.',
		p_why_memory: 'This router does not have enough memory for it.',
		p_url: 'Address of AdGuard Home',
		p_user: 'User name',
		p_pass: 'Password',
		p_test: 'Test connection',
		p_testing: 'Checking…',
		p_ok: 'Connected to AdGuard Home {0}.',
		p_handout: 'Devices ask it directly',
		p_handout_d: 'The router tells each device to use it for DNS, so AdGuard Home sees every device by itself. Turn this off if your network already sends DNS there some other way.',
		e_ag_url: 'Enter the address, such as 192.168.1.2:3000.',
		e_ag_login: 'Enter the user name and password of AdGuard Home.',
		e_ag_fail: 'Could not connect: {0}',

		pw_title: 'Protect your router',
		pw_lede: 'This password lets you sign in here (user root) and pair the MiWRT app. Anyone who knows it can change everything.',
		pw_new: 'Router password',
		pw_again: 'Type it again',
		pw_h: 'At least 8 characters. A short sentence is easy to remember and hard to guess.',
		pw_ag: 'AdGuard Home on this router will use the same password, with user admin.',
		e_pw: 'The password needs at least 8 characters.',
		e_pw_long: 'The password can be at most 128 characters.',
		e_pw2: 'The passwords do not match.',
		e_pw_wifi: 'Use a different password from the Wi-Fi one, or anyone on your Wi-Fi could change the router.',

		v_title: 'Check and apply',
		v_lede: 'Nothing has changed yet. Applying takes about a minute.',
		v_warn: 'The network restarts. If this device uses Wi-Fi it disconnects for a moment; join “{0}” if it does not reconnect by itself.',
		v_apply: 'Apply settings',
		v_applying: 'Applying…',
		v_mode: 'Mode',
		v_set: 'Set',
		v_noinet: 'no internet',
		v_bands_all: '2.4 and 5 GHz',
		v_bands_24: '2.4 GHz',
		v_addr_auto: 'from the main router',

		a_title: 'Setting up your router',
		a_lede: 'Keep this page open. It moves on by itself.',
		a_save: 'Saving the settings',
		a_net: 'Restarting the network',
		a_addr: 'Getting an address from the main router',
		a_ag: 'Installing AdGuard Home',
		ag_internet: 'waiting for the internet',
		ag_download: 'downloading',
		ag_start: 'starting',
		ag_configure: 'taking over DNS',
		a_wait: 'Waiting for the router to answer…',
		a_join: 'Join the Wi-Fi',
		a_join_d: 'If this device was on Wi-Fi, connect it to “{0}”. A phone can join by scanning this code with its camera.',
		a_lost: 'The router has not answered for a while.',
		a_lost_router: 'Check that this device is on “{0}” or plugged in by cable, then open http://{1}.',
		a_lost_ap: 'This router now takes its address from your main router. Find “{0}” in the main router’s list of devices and open that address.',
		a_lost_ap_static: 'This router is now at http://{0}. Open that address from a device on the same network.',
		a_open: 'Open http://{0}',
		a_failed: 'Setup could not finish',
		a_fail_addr: 'No main router gave this router an address. Check that the cable from your main router is in the WAN port. The settings from before are back.',
		a_retry: 'Back to the settings',

		d_title: 'Your network is ready',
		d_lede: 'Everything is set. A few things worth doing next:',
		d_app: 'Get the MiWRT app',
		d_app_d: 'See every device, pause the internet for anyone, get alerts and manage ad blocking from your iPhone. The app finds the router by itself; pair it with the router password.',
		d_app_scan: 'Scan with the iPhone camera',
		d_app_btn: 'Open the App Store',
		d_wifi: 'Share your Wi-Fi',
		d_signin: 'Sign in here later',
		d_signin_d: 'Open http://{0} and sign in as root with your router password.',
		d_signin_ap: 'Find “{0}” in your main router’s list of devices, open that address and sign in as root with your router password.',
		d_ag_ok: 'AdGuard Home is running on the router. Its own page is at http://{0}:3000 (user admin, router password).',
		d_ag_fail: 'AdGuard Home was not installed. {0} You can install it later from the app.',
		agf_internet: 'The router could not reach the package feed.',
		agf_download: 'The download or the installation failed; check that there is free space.',
		agf_other: 'It did not start properly and was removed again; the router answers DNS itself.',
		d_more: 'Worth a look',
		d_more_upd: 'Firmware updates are checked once a day. Install them from the app or under System, Build.',
		d_more_pkgs: 'More features, such as VPN (AmneziaWG) and tools against censorship, install from System, Software.',
		d_open: 'Open the web interface'
	},

	ru: {
		brand_sub: 'Настройка',
		step_of: 'Шаг {0} из {1}',
		progress: 'Ход настройки',
		done_sr: 'выполнено',
		back: 'Назад',
		next: 'Далее',
		skip: 'Пропустить',
		show: 'Показать пароль',
		hide: 'Скрыть пароль',
		generate: 'Придумать',
		change: 'Изменить',
		back_review: 'К проверке',
		optional: 'необязательно',
		on: 'Вкл.',
		off: 'Выкл.',
		recommended: 'Рекомендуется',
		your_router: 'роутер',
		lang_label: 'Язык',
		e_fix: 'Проверьте отмеченные поля.',
		e_generic: 'Что-то пошло не так: {0}',
		e_router_said: 'Ответ роутера: {0}',

		s_region: 'Регион',
		s_mode: 'Подключение',
		s_wifi: 'Wi-Fi',
		s_guest: 'Гости',
		s_iot: 'Умный дом',
		s_protect: 'Блокировка рекламы',
		s_password: 'Пароль',
		s_review: 'Проверка',

		w_title: 'Давайте настроим роутер',
		w_lede: 'Несколько коротких шагов — и {0} готов: интернет, Wi-Fi, гостевая сеть, умные устройства, блокировка рекламы и пароль. Это займёт около трёх минут, а до последнего шага ничего не меняется.',
		w_start: 'Начать',
		w_imported: 'Настройки из прошивки Xiaomi перенесены и уже подставлены — их можно оставить.',
		w_list: 'Что будет настроено',
		w_skip_q: 'Пропустить мастер настройки?',
		w_skip_text: 'Всё можно настроить вручную в веб-интерфейсе. У роутера пока нет пароля — сразу задайте его в разделе «Система → Управление».',
		w_skip_yes: 'Пропустить',
		w_skip_no: 'Продолжить настройку',

		r_title: 'Где находится роутер?',
		r_lede: 'От страны зависят разрешённые каналы и мощность Wi-Fi. Часовой пояс нужен, чтобы расписания и журналы шли по верному времени.',
		r_lang: 'Язык веб-интерфейса',
		r_lang_auto: 'Как в браузере',
		r_country: 'Страна',
		r_country_ph: 'Выберите страну',
		r_zone: 'Часовой пояс',
		r_zone_hint: 'На этом устройстве установлен пояс {0}.',
		e_country: 'Выберите страну, где находится роутер.',
		e_zone: 'Выберите часовой пояс.',

		m_title: 'Как подключён роутер?',
		m_lede: 'Выберите, какую роль роутер выполняет дома.',
		m_router: 'Основной роутер',
		m_router_d: 'Подключается к модему, оптическому терминалу или кабелю провайдера и управляет домашней сетью.',
		m_ap: 'Точка доступа',
		m_ap_d: 'У вас уже есть роутер. Этот добавит Wi-Fi в его сеть по кабелю.',
		m_ap_note: 'Подключите кабель от основного роутера к порту WAN этого роутера. Гостевая сеть, сеть для умного дома и блокировка рекламы на роутере работают только в режиме основного роутера.',
		m_inet: 'Подключение к интернету',
		m_dhcp: 'Автоматически',
		m_dhcp_d: 'Большинство кабельных, оптических и модемных подключений (DHCP).',
		m_pppoe: 'PPPoE',
		m_pppoe_d: 'Провайдер выдал логин и пароль.',
		m_static: 'Статический адрес',
		m_static_d: 'Провайдер выдал IP-адрес для ручной настройки.',
		m_user: 'Логин',
		m_pass: 'Пароль',
		m_vlan: 'VLAN ID',
		m_vlan_h: 'Только если этого требует провайдер.',
		m_ip: 'IP-адрес',
		m_mask: 'Маска подсети',
		m_gw: 'Шлюз',
		m_dns: 'DNS-серверы',
		m_dns_h: 'Несколько — через пробел. Оставьте пустым, чтобы использовать серверы провайдера.',
		m_link_up: 'Кабель подключён к порту интернета (WAN).',
		m_link_down: 'К порту интернета (WAN) пока ничего не подключено.',
		m_ap_addr: 'Адрес этого роутера',
		m_ap_dhcp: 'От основного роутера',
		m_ap_dhcp_d: 'Проще всего. Адрес потом можно найти в списке устройств основного роутера.',
		m_ap_static_d: 'Вы задаёте свободный адрес в сети основного роутера.',
		m_ap_gw: 'Адрес основного роутера',
		m_ap_dns_h: 'Оставьте пустым, чтобы использовать основной роутер.',
		e_user: 'Введите логин, выданный провайдером.',
		e_vlan: 'VLAN ID — число от 1 до 4094.',
		e_ip: 'Введите адрес, например 192.168.1.2.',
		e_mask: 'Введите маску, например 255.255.255.0.',
		e_dns: 'Каждый DNS-сервер должен быть IPv4-адресом.',
		e_chars: 'Здесь есть недопустимые символы.',

		f_title: 'Настройте Wi-Fi',
		f_lede: 'Если оставить прежние имя и пароль, устройства подключатся сами.',
		f_name: 'Имя сети',
		f_name5: 'Имя сети 5 ГГц',
		f_pass: 'Пароль Wi-Fi',
		f_pass_h: 'От 8 до 63 символов. Чем длиннее, тем надёжнее.',
		f_split: 'Отдельное имя для 5 ГГц',
		f_split_d: 'Обычно лучше выключить: с одним именем устройства сами выбирают самый быстрый диапазон.',
		f_sec: 'Защита',
		f_sae: 'WPA2/WPA3',
		f_sae_d: 'Самая надёжная защита; старые устройства тоже подключатся.',
		f_psk2: 'Только WPA2',
		f_psk2_d: 'Для редких старых устройств, которые иначе не подключаются.',
		e_ssid_empty: 'Введите имя сети.',
		e_ssid: 'Имя сети — не больше 32 байт (буквы кроме латиницы занимают по 2–3 байта).',
		e_key: 'Пароль Wi-Fi — от 8 до 63 символов: латинские буквы, цифры и обычные знаки.',
		e_same5: 'Дайте сети 5 ГГц другое имя или используйте одно имя для обеих.',
		e_unique: 'У каждой сети должно быть своё имя.',
		st_label: 'Надёжность: {0}',
		st_0: 'слишком короткий',
		st_1: 'слабый',
		st_2: 'средний',
		st_3: 'надёжный',
		st_4: 'очень надёжный',

		g_title: 'Wi-Fi для гостей',
		g_lede: 'Гости получают только интернет: они не видят ваши компьютеры, телефоны и друг друга.',
		g_on: 'Гостевая сеть',
		g_on_d: 'В приложении ею можно поделиться по QR-коду и настроить автоотключение.',
		g_name: 'Имя гостевой сети',
		g_pass: 'Пароль гостевой сети',

		i_title: 'Сеть для умного дома',
		i_lede: 'Розетки, камеры, лампы и телевизоры — в отдельной сети. Телефон по-прежнему ими управляет, но до ваших компьютеров они не доберутся.',
		i_on: 'Сеть для умного дома',
		i_on_d: 'Использует WPA2 — к ней подключится любое умное устройство.',
		i_name: 'Имя сети умного дома',
		i_pass: 'Пароль сети умного дома',
		i_inet: 'Доступ в интернет',
		i_inet_d: 'Многим устройствам он нужен для их приложения. Выключите для устройств, которые должны работать только дома.',
		i_5g: 'Также на 5 ГГц',
		i_5g_d: 'Большинство умных устройств работают только на 2,4 ГГц, поэтому по умолчанию выключено.',
		i_exists: 'На роутере уже есть сеть IoT, настроенная вручную. Изменить её можно в разделе «Сеть → Беспроводная сеть».',

		p_title: 'Блокировка рекламы и трекеров',
		p_lede: 'AdGuard Home отсекает рекламу, трекеры и опасные сайты для всех устройств в доме — на сами устройства ничего ставить не нужно.',
		p_none: 'Не сейчас',
		p_none_d: 'Можно добавить позже в приложении.',
		p_router: 'На этом роутере',
		p_router_d: 'MiWRT установит AdGuard Home после настройки (загрузка около 30 МБ) и будет за ним следить.',
		p_router_after: 'Его страница будет по адресу http://{0}:3000, пользователь admin, пароль — тот, что вы зададите для роутера на следующем шаге.',
		p_net: 'На другом устройстве',
		p_net_d: 'AdGuard Home уже работает, например на Raspberry Pi.',
		p_keep: 'Оставить текущий',
		p_keep_d: 'AdGuard Home по адресу {0}',
		p_why_mode: 'Нужен режим основного роутера.',
		p_why_storage: 'Нужно {0} МБ свободного места, а свободно {1} МБ. Добавьте место (USB-накопитель или запасной раздел) и установите его из приложения.',
		p_why_memory: 'Этому роутеру не хватает памяти.',
		p_url: 'Адрес AdGuard Home',
		p_user: 'Имя пользователя',
		p_pass: 'Пароль',
		p_test: 'Проверить подключение',
		p_testing: 'Проверка…',
		p_ok: 'Подключено к AdGuard Home {0}.',
		p_handout: 'Устройства обращаются к нему напрямую',
		p_handout_d: 'Роутер сообщает каждому устройству использовать его как DNS, и AdGuard Home видит каждое устройство отдельно. Выключите, если сеть уже направляет DNS туда иначе.',
		e_ag_url: 'Введите адрес, например 192.168.1.2:3000.',
		e_ag_login: 'Введите имя пользователя и пароль AdGuard Home.',
		e_ag_fail: 'Не удалось подключиться: {0}',

		pw_title: 'Защитите роутер',
		pw_lede: 'С этим паролем вы входите сюда (пользователь root) и подключаете приложение MiWRT. Тот, кто его знает, может изменить всё.',
		pw_new: 'Пароль роутера',
		pw_again: 'Повторите пароль',
		pw_h: 'Не менее 8 символов. Короткую фразу легко запомнить и трудно подобрать.',
		pw_ag: 'AdGuard Home на этом роутере будет использовать тот же пароль, пользователь admin.',
		e_pw: 'Пароль должен содержать не менее 8 символов.',
		e_pw_long: 'Пароль может содержать не более 128 символов.',
		e_pw2: 'Пароли не совпадают.',
		e_pw_wifi: 'Пароль должен отличаться от пароля Wi-Fi, иначе любой в вашей сети Wi-Fi сможет изменить настройки роутера.',

		v_title: 'Проверьте и примените',
		v_lede: 'Пока ничего не изменено. Применение займёт около минуты.',
		v_warn: 'Сеть перезапустится. Если это устройство подключено по Wi-Fi, связь ненадолго пропадёт; подключитесь к «{0}», если оно не переподключится само.',
		v_apply: 'Применить',
		v_applying: 'Применение…',
		v_mode: 'Режим',
		v_set: 'Задан',
		v_noinet: 'без интернета',
		v_bands_all: '2,4 и 5 ГГц',
		v_bands_24: '2,4 ГГц',
		v_addr_auto: 'от основного роутера',

		a_title: 'Настраиваем роутер',
		a_lede: 'Не закрывайте страницу — она продолжит сама.',
		a_save: 'Сохранение настроек',
		a_net: 'Перезапуск сети',
		a_addr: 'Получение адреса от основного роутера',
		a_ag: 'Установка AdGuard Home',
		ag_internet: 'ожидание интернета',
		ag_download: 'загрузка',
		ag_start: 'запуск',
		ag_configure: 'переключение DNS',
		a_wait: 'Ждём ответа роутера…',
		a_join: 'Подключитесь к Wi-Fi',
		a_join_d: 'Если это устройство было подключено по Wi-Fi, подключите его к «{0}». Телефон подключится, если навести камеру на этот код.',
		a_lost: 'Роутер давно не отвечает.',
		a_lost_router: 'Убедитесь, что устройство подключено к «{0}» или по кабелю, и откройте http://{1}.',
		a_lost_ap: 'Теперь роутер получает адрес от основного роутера. Найдите «{0}» в списке устройств основного роутера и откройте этот адрес.',
		a_lost_ap_static: 'Теперь роутер доступен по адресу http://{0}. Откройте его с устройства в той же сети.',
		a_open: 'Открыть http://{0}',
		a_failed: 'Настройка не завершена',
		a_fail_addr: 'Основной роутер не выдал этому роутеру адрес. Проверьте, что кабель от основного роутера подключён к порту WAN. Прежние настройки восстановлены.',
		a_retry: 'Вернуться к настройкам',

		d_title: 'Сеть готова',
		d_lede: 'Всё настроено. Что стоит сделать дальше:',
		d_app: 'Установите приложение MiWRT',
		d_app_d: 'Все устройства, пауза интернета для любого из них, уведомления и блокировка рекламы — на iPhone. Приложение само найдёт роутер; для подключения нужен пароль роутера.',
		d_app_scan: 'Отсканируйте камерой iPhone',
		d_app_btn: 'Открыть App Store',
		d_wifi: 'Поделитесь Wi-Fi',
		d_signin: 'Вход в веб-интерфейс',
		d_signin_d: 'Откройте http://{0} и войдите как root с паролем роутера.',
		d_signin_ap: 'Найдите «{0}» в списке устройств основного роутера, откройте этот адрес и войдите как root с паролем роутера.',
		d_ag_ok: 'AdGuard Home работает на роутере. Его страница — http://{0}:3000 (пользователь admin, пароль роутера).',
		d_ag_fail: 'AdGuard Home не установлен. {0} Его можно установить позже из приложения.',
		agf_internet: 'Роутер не смог связаться с репозиторием пакетов.',
		agf_download: 'Не удалось загрузить или установить пакет; проверьте, есть ли свободное место.',
		agf_other: 'Он не запустился как надо и был удалён; DNS снова обслуживает сам роутер.',
		d_more: 'Что ещё посмотреть',
		d_more_upd: 'Обновления прошивки проверяются раз в день. Устанавливайте их из приложения или в разделе «Система → Сборка».',
		d_more_pkgs: 'Дополнительные возможности, например VPN (AmneziaWG) и средства обхода блокировок, устанавливаются в разделе «Система → Программное обеспечение».',
		d_open: 'Открыть веб-интерфейс'
	},

	zh_cn: {
		brand_sub: '设置',
		step_of: '第 {0} 步，共 {1} 步',
		progress: '设置进度',
		done_sr: '已完成',
		back: '返回',
		next: '继续',
		skip: '跳过设置',
		show: '显示密码',
		hide: '隐藏密码',
		generate: '随机生成',
		change: '修改',
		back_review: '返回确认页',
		optional: '可选',
		on: '开',
		off: '关',
		recommended: '推荐',
		your_router: '你的路由器',
		lang_label: '语言',
		e_fix: '请检查标出的字段。',
		e_generic: '出现错误：{0}',
		e_router_said: '路由器返回：{0}',

		s_region: '地区',
		s_mode: '连接',
		s_wifi: 'Wi-Fi',
		s_guest: '访客',
		s_iot: '智能家居',
		s_protect: '广告拦截',
		s_password: '密码',
		s_review: '确认',

		w_title: '开始设置路由器',
		w_lede: '只需几个简单步骤，{0}即可就绪：互联网、Wi-Fi、访客网络、智能设备、广告拦截和密码。大约需要三分钟，在最后一步之前不会做任何更改。',
		w_start: '开始',
		w_imported: '已导入小米原厂固件中的设置并预先填好，可以直接保留。',
		w_list: '将要设置的内容',
		w_skip_q: '跳过设置向导？',
		w_skip_text: '你可以在网页界面中自行完成所有设置。路由器目前还没有密码：请立即在“系统 → 管理权”中设置。',
		w_skip_yes: '跳过',
		w_skip_no: '继续设置',

		r_title: '路由器在哪里？',
		r_lede: '国家/地区决定允许使用的 Wi-Fi 信道和功率。时区用于确保计划任务和日志时间正确。',
		r_lang: '网页界面语言',
		r_lang_auto: '跟随浏览器',
		r_country: '国家/地区',
		r_country_ph: '请选择国家/地区',
		r_zone: '时区',
		r_zone_hint: '此设备的时区为 {0}。',
		e_country: '请选择路由器所在的国家/地区。',
		e_zone: '请选择时区。',

		m_title: '路由器如何连接？',
		m_lede: '选择这台路由器在家中的角色。',
		m_router: '主路由器',
		m_router_d: '连接光猫、调制解调器或入户网线，负责管理家庭网络。',
		m_ap: '接入点',
		m_ap_d: '你已有一台路由器。这台通过网线为现有网络提供 Wi-Fi。',
		m_ap_note: '用网线将主路由器连接到本路由器的 WAN 口。访客网络、智能家居网络和路由器上的广告拦截仅在主路由器模式下可用。',
		m_inet: '上网方式',
		m_dhcp: '自动获取',
		m_dhcp_d: '适用于大多数宽带、光纤和光猫连接（DHCP）。',
		m_pppoe: 'PPPoE 拨号',
		m_pppoe_d: '运营商提供了宽带账号和密码。',
		m_static: '静态地址',
		m_static_d: '运营商提供了需要手动填写的 IP 地址。',
		m_user: '宽带账号',
		m_pass: '密码',
		m_vlan: 'VLAN ID',
		m_vlan_h: '仅在运营商要求时填写。',
		m_ip: 'IP 地址',
		m_mask: '子网掩码',
		m_gw: '网关',
		m_dns: 'DNS 服务器',
		m_dns_h: '多个地址用空格分隔。留空则使用运营商提供的 DNS。',
		m_link_up: '互联网（WAN）端口已连接网线。',
		m_link_down: '互联网（WAN）端口尚未连接网线。',
		m_ap_addr: '本路由器的地址',
		m_ap_dhcp: '由主路由器分配',
		m_ap_dhcp_d: '最简单。之后可在主路由器的设备列表中找到地址。',
		m_ap_static_d: '在主路由器的网络中手动指定一个空闲地址。',
		m_ap_gw: '主路由器地址',
		m_ap_dns_h: '留空则使用主路由器。',
		e_user: '请输入运营商提供的宽带账号。',
		e_vlan: 'VLAN ID 必须是 1 到 4094 之间的数字。',
		e_ip: '请输入地址，例如 192.168.1.2。',
		e_mask: '请输入子网掩码，例如 255.255.255.0。',
		e_dns: '每个 DNS 服务器都必须是 IPv4 地址。',
		e_chars: '包含无法使用的字符。',

		f_title: '设置 Wi-Fi',
		f_lede: '沿用设备已知的名称和密码，设备会自动重新连接。',
		f_name: 'Wi-Fi 名称',
		f_name5: '5 GHz Wi-Fi 名称',
		f_pass: 'Wi-Fi 密码',
		f_pass_h: '8 到 63 个字符，越长越安全。',
		f_split: '5 GHz 使用单独名称',
		f_split_d: '通常建议关闭：使用同一名称时，设备会自动选择最快的频段。',
		f_sec: '加密方式',
		f_sae: 'WPA2/WPA3',
		f_sae_d: '最强的保护，旧设备也能连接。',
		f_psk2: '仅 WPA2',
		f_psk2_d: '仅用于少数无法以其他方式连接的旧设备。',
		e_ssid_empty: '请输入 Wi-Fi 名称。',
		e_ssid: 'Wi-Fi 名称最多 32 字节（每个中文字符占 3 字节）。',
		e_key: 'Wi-Fi 密码需为 8 到 63 个字符：英文字母、数字和常用符号。',
		e_same5: '请为 5 GHz 网络设置不同的名称，或两者使用同一名称。',
		e_unique: '每个网络都需要不同的名称。',
		st_label: '强度：{0}',
		st_0: '太短',
		st_1: '弱',
		st_2: '中等',
		st_3: '强',
		st_4: '很强',

		g_title: '访客 Wi-Fi',
		g_lede: '访客只能上网：无法访问你的电脑和手机，彼此之间也互不可见。',
		g_on: '访客网络',
		g_on_d: '可在应用中通过二维码分享，并设置自动关闭。',
		g_name: '访客 Wi-Fi 名称',
		g_pass: '访客 Wi-Fi 密码',

		i_title: '智能家居专用网络',
		i_lede: '插座、摄像头、灯泡和电视使用单独的网络。手机仍可控制它们，但它们无法访问你的电脑。',
		i_on: '智能家居网络',
		i_on_d: '使用所有智能设备都能连接的 WPA2。',
		i_name: '智能家居 Wi-Fi 名称',
		i_pass: '智能家居 Wi-Fi 密码',
		i_inet: '互联网访问',
		i_inet_d: '许多设备的应用需要联网。对只需在家中使用的设备可关闭。',
		i_5g: '同时使用 5 GHz',
		i_5g_d: '大多数智能设备只支持 2.4 GHz，因此默认关闭。',
		i_exists: '此路由器已有手动配置的 IoT 网络，可在“网络 → 无线”中修改。',

		p_title: '拦截广告和跟踪器',
		p_lede: 'AdGuard Home 为家中所有设备过滤广告、跟踪器和有害网站，无需在设备上安装任何软件。',
		p_none: '暂不启用',
		p_none_d: '之后可在应用中添加。',
		p_router: '在本路由器上',
		p_router_d: '设置完成后，MiWRT 会安装 AdGuard Home（约 30 MB 下载）并负责维护。',
		p_router_after: '其管理页面为 http://{0}:3000，用户名 admin，密码为下一步设置的路由器密码。',
		p_net: '在其他设备上',
		p_net_d: '你已在其他设备（例如树莓派）上运行 AdGuard Home。',
		p_keep: '保留当前设置',
		p_keep_d: '位于 {0} 的 AdGuard Home',
		p_why_mode: '需要主路由器模式。',
		p_why_storage: '需要 {0} MB 可用存储空间，当前仅剩 {1} MB。请增加存储（USB 存储设备或备用分区），然后在应用中安装。',
		p_why_memory: '此路由器内存不足。',
		p_url: 'AdGuard Home 地址',
		p_user: '用户名',
		p_pass: '密码',
		p_test: '测试连接',
		p_testing: '正在检查…',
		p_ok: '已连接到 AdGuard Home {0}。',
		p_handout: '设备直接使用它',
		p_handout_d: '路由器会让每台设备将它用作 DNS，使 AdGuard Home 能分别识别每台设备。如果网络已通过其他方式将 DNS 指向它，请关闭此项。',
		e_ag_url: '请输入地址，例如 192.168.1.2:3000。',
		e_ag_login: '请输入 AdGuard Home 的用户名和密码。',
		e_ag_fail: '无法连接：{0}',

		pw_title: '保护你的路由器',
		pw_lede: '此密码用于登录此处（用户名 root）以及配对 MiWRT 应用。知道它的人可以更改所有设置。',
		pw_new: '路由器密码',
		pw_again: '再次输入',
		pw_h: '至少 8 个字符。一句简短的话既好记又难猜。',
		pw_ag: '本路由器上的 AdGuard Home 将使用相同密码，用户名为 admin。',
		e_pw: '密码至少需要 8 个字符。',
		e_pw_long: '密码最多 128 个字符。',
		e_pw2: '两次输入的密码不一致。',
		e_pw_wifi: '请使用与 Wi-Fi 不同的密码，否则任何连接 Wi-Fi 的人都能更改路由器设置。',

		v_title: '确认并应用',
		v_lede: '目前尚未做任何更改。应用约需一分钟。',
		v_warn: '网络将重新启动。如果此设备使用 Wi-Fi，连接会短暂中断；若未自动重连，请连接“{0}”。',
		v_apply: '应用设置',
		v_applying: '正在应用…',
		v_mode: '模式',
		v_set: '已设置',
		v_noinet: '无互联网',
		v_bands_all: '2.4 和 5 GHz',
		v_bands_24: '2.4 GHz',
		v_addr_auto: '由主路由器分配',

		a_title: '正在设置路由器',
		a_lede: '请保持此页面打开，它会自动继续。',
		a_save: '正在保存设置',
		a_net: '正在重启网络',
		a_addr: '正在从主路由器获取地址',
		a_ag: '正在安装 AdGuard Home',
		ag_internet: '正在等待网络连接',
		ag_download: '正在下载',
		ag_start: '正在启动',
		ag_configure: '正在接管 DNS',
		a_wait: '正在等待路由器响应…',
		a_join: '连接 Wi-Fi',
		a_join_d: '如果此设备之前通过 Wi-Fi 连接，请连接到“{0}”。手机用相机扫描此二维码即可加入。',
		a_lost: '路由器已有一段时间没有响应。',
		a_lost_router: '请确认此设备已连接到“{0}”或已通过网线连接，然后打开 http://{1}。',
		a_lost_ap: '本路由器现在从主路由器获取地址。请在主路由器的设备列表中找到“{0}”，然后打开该地址。',
		a_lost_ap_static: '本路由器现在的地址是 http://{0}。请在同一网络中的设备上打开它。',
		a_open: '打开 http://{0}',
		a_failed: '设置未能完成',
		a_fail_addr: '主路由器没有给本路由器分配地址。请检查主路由器的网线是否插在 WAN 口。之前的设置已恢复。',
		a_retry: '返回设置',

		d_title: '网络已就绪',
		d_lede: '一切就绪。接下来值得做的几件事：',
		d_app: '获取 MiWRT 应用',
		d_app_d: '在 iPhone 上查看所有设备、为任何人暂停上网、接收提醒并管理广告拦截。应用会自动找到路由器，使用路由器密码完成配对。',
		d_app_scan: '用 iPhone 相机扫描',
		d_app_btn: '打开 App Store',
		d_wifi: '分享 Wi-Fi',
		d_signin: '以后登录此页面',
		d_signin_d: '打开 http://{0}，使用 root 和路由器密码登录。',
		d_signin_ap: '在主路由器的设备列表中找到“{0}”，打开该地址，使用 root 和路由器密码登录。',
		d_ag_ok: 'AdGuard Home 已在路由器上运行。其管理页面为 http://{0}:3000（用户名 admin，密码为路由器密码）。',
		d_ag_fail: 'AdGuard Home 未安装。{0} 之后可在应用中安装。',
		agf_internet: '路由器无法连接软件源。',
		agf_download: '下载或安装失败，请检查是否有足够的可用空间。',
		agf_other: '它未能正常启动，已被移除；DNS 仍由路由器自身提供。',
		d_more: '更多功能',
		d_more_upd: '每天自动检查一次固件更新，可在应用中或“系统 → 固件”中安装。',
		d_more_pkgs: '更多功能（如 VPN（AmneziaWG）和反审查工具）可在“系统 → 软件包”中安装。',
		d_open: '打开网页界面'
	}
};

const LANG_NAMES = { en: 'English', ru: 'Русский', zh_cn: '简体中文' };
const LANG_TAGS = { en: 'en', ru: 'ru', zh_cn: 'zh-CN' };

let lang = 'en';

function t(key, ...args) {
	const s = STR[lang]?.[key] ?? STR.en[key] ?? key;
	return s.replace(/\{(\d)\}/g, (m, i) => String(args[+i] ?? ''));
}

/* ------------------------------------------------------------------ */
/* Small helpers                                                      */
/* ------------------------------------------------------------------ */

/* Tabler Icons (MIT), the same family the theme's menu uses */
const ICONS = {
	check: '<path d="M5 12l5 5l10 -10"/>',
	left: '<path d="M5 12l14 0"/><path d="M5 12l6 6"/><path d="M5 12l6 -6"/>',
	right: '<path d="M5 12l14 0"/><path d="M13 18l6 -6"/><path d="M13 6l6 6"/>',
	eye: '<path d="M10 12a2 2 0 1 0 4 0a2 2 0 0 0 -4 0"/><path d="M21 12c-2.4 4 -5.4 6 -9 6c-3.6 0 -6.6 -2 -9 -6c2.4 -4 5.4 -6 9 -6c3.6 0 6.6 2 9 6"/>',
	eyeoff: '<path d="M10.585 10.587a2 2 0 0 0 2.829 2.828"/><path d="M16.681 16.673a8.717 8.717 0 0 1 -4.681 1.327c-3.6 0 -6.6 -2 -9 -6c1.272 -2.12 2.712 -3.678 4.32 -4.674m2.86 -1.146a9.055 9.055 0 0 1 1.82 -.18c3.6 0 6.6 2 9 6c-.666 1.11 -1.379 2.067 -2.138 2.87"/><path d="M3 3l18 18"/>',
	refresh: '<path d="M20 11a8.1 8.1 0 0 0 -15.5 -2m-.5 -4v4h4"/><path d="M4 13a8.1 8.1 0 0 0 15.5 2m.5 4v-4h-4"/>',
	alert: '<path d="M12 9v4"/><path d="M10.363 3.591l-8.106 13.534a1.914 1.914 0 0 0 1.636 2.871h16.214a1.914 1.914 0 0 0 1.636 -2.87l-8.106 -13.536a1.914 1.914 0 0 0 -3.274 0z"/><path d="M12 16h.01"/>',
	info: '<path d="M3 12a9 9 0 1 0 18 0a9 9 0 0 0 -18 0"/><path d="M12 9h.01"/><path d="M11 12h1v4h1"/>',
	world: '<path d="M3 12a9 9 0 1 0 18 0a9 9 0 0 0 -18 0"/><path d="M3.6 9h16.8"/><path d="M3.6 15h16.8"/><path d="M11.5 3a17 17 0 0 0 0 18"/><path d="M12.5 3a17 17 0 0 1 0 18"/>',
	x: '<path d="M18 6l-12 12"/><path d="M6 6l12 12"/>',
	link: '<path d="M9 15l6 -6"/><path d="M11 6l.463 -.536a5 5 0 0 1 7.071 7.072l-.534 .464"/><path d="M13 18l-.397 .534a5.068 5.068 0 0 1 -7.127 0a4.972 4.972 0 0 1 0 -7.071l.524 -.463"/>',
	plug: '<path d="M9.785 6l8.215 8.215l-2.054 2.054a5.81 5.81 0 1 1 -8.215 -8.215l2.054 -2.054z"/><path d="M4 20l3.5 -3.5"/><path d="M15 4l-3.5 3.5"/><path d="M20 9l-3.5 3.5"/>'
};

function icon(name, cls) {
	const s = document.createElement('span');
	s.className = 'mws-ic' + (cls ? ' ' + cls : '');
	s.setAttribute('aria-hidden', 'true');
	s.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' + ICONS[name] + '</svg>';
	return s;
}

/* createElement with properties where they matter (value, checked, disabled) and plain attributes
   otherwise; false and null leave an attribute out */
function h(tag, attrs, kids) {
	const el = document.createElement(tag);
	for (const k in (attrs || {})) {
		const v = attrs[k];
		if (v == null || v === false) continue;
		if (k.slice(0, 2) == 'on' && typeof v == 'function') el.addEventListener(k.slice(2), v);
		else if (k == 'class') el.className = v;
		else if (k == 'value') el.value = v;
		else if (k == 'checked' || k == 'selected') el[k] = true;
		else el.setAttribute(k, v === true ? '' : v);
	}
	const add = c => {
		if (c == null || c === false) return;
		if (Array.isArray(c)) c.forEach(add);
		else el.appendChild(typeof c == 'object' ? c : document.createTextNode(String(c)));
	};
	add(kids);
	return el;
}

const bytes = s => new TextEncoder().encode(s ?? '').length;
const CTRL = /[\x00-\x1f\x7f]/;

function isIp(s) {
	const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(s ?? '');
	return !!m && m.slice(1).every(p => +p <= 255);
}

function isMask(s) {
	if (!isIp(s)) return false;
	const n = s.split('.').reduce((a, p) => a * 256 + +p, 0);
	const inv = 0xffffffff - n;
	return n != 0 && (inv & (inv + 1)) === 0;
}

const dnsList = s => String(s ?? '').split(/[\s,]+/).filter(Boolean);

/* 12 letters and digits without look-alikes, in groups of four: easy to read out and to type on a phone */
function randomKey() {
	const abc = 'abcdefghjkmnpqrstuvwxyz23456789', out = [];
	while (out.length < 12) {
		const b = crypto.getRandomValues(new Uint8Array(16));
		for (const x of b) if (x < 248 && out.length < 12) out.push(abc[x % 31]);
	}
	return out.slice(0, 4).join('') + '-' + out.slice(4, 8).join('') + '-' + out.slice(8).join('');
}

function strength(pw) {
	if ((pw ?? '').length < 8) return 0;
	let pool = 0;
	if (/[a-z]/.test(pw)) pool += 26;
	if (/[A-Z]/.test(pw)) pool += 26;
	if (/[0-9]/.test(pw)) pool += 10;
	if (/[^A-Za-z0-9]/.test(pw)) pool += 33;
	let bits = pw.length * Math.log2(Math.max(pool, 2));
	// a well-known word or run inside costs a guesser little
	if (/pass|qwer|asdf|1234|admin|love|welcome|letmein|wifi|router|abc|111|000/i.test(pw)) bits -= 22;
	if (/^(.)\1+$/.test(pw)) bits = 10;
	return bits < 40 ? 1 : bits < 55 ? 2 : bits < 75 ? 3 : 4;
}

function wifiQrText(ssid, key) {
	const esc = s => String(s).replace(/([\\;,:"])/g, '\\$1');
	return 'WIFI:T:WPA;S:' + esc(ssid) + ';P:' + esc(key) + ';;';
}

function qr(text, label) {
	const box = h('div', { class: 'mws-qr', role: 'img', 'aria-label': label });
	try {
		box.innerHTML = uqr.renderSVG(text, { pixelSize: 4, whiteColor: '#ffffff', blackColor: '#16161d', ecc: 'M' });
		// the library sets a pixel size but no viewBox; with one the code scales to its box
		const svg = box.querySelector('svg');
		svg.setAttribute('viewBox', '0 0 ' + svg.getAttribute('width') + ' ' + svg.getAttribute('height'));
		svg.removeAttribute('width');
		svg.removeAttribute('height');
		svg.setAttribute('shape-rendering', 'crispEdges');
	}
	catch (e) {
		box.hidden = true;
	}
	return box;
}

/* ------------------------------------------------------------------ */
/* State                                                              */
/* ------------------------------------------------------------------ */

let st = null;      // what the router reported
let cfg = null;     // the answers
const ui = {
	root: null, screen: 'welcome', furthest: -1, errors: {}, banner: null, busy: false, fromReview: false,
	focusTitle: false, reveal: { 'f-key': true, 'f-g-key': true, 'f-i-key': true }, test: { state: null, sig: null, text: null }, result: null,
	job: null, started: 0, contact: 0, timer: null, enter: true
};

function browserLang() {
	const l = String((navigator.languages && navigator.languages[0]) || navigator.language || 'en').toLowerCase();
	return l.startsWith('ru') ? 'ru' : l.startsWith('zh') ? 'zh_cn' : 'en';
}

function uiLang() {
	const l = cfg.region.lang;
	return (l == 'auto' || !STR[l]) ? browserLang() : l;
}

function browserCountry() {
	for (const l of (navigator.languages || [ navigator.language ])) {
		const m = /^[a-z]{2,3}[-_](?:[A-Za-z]{4}[-_])?([A-Za-z]{2})\b/.exec(l || '');
		if (m && COUNTRIES.includes(m[1].toUpperCase())) return m[1].toUpperCase();
	}
	return null;
}

function browserZone() {
	try { return Intl.DateTimeFormat().resolvedOptions().timeZone || null; }
	catch (e) { return null; }
}

function hasBand(b) {
	return (st.wifi.bands || []).some(x => x == b);
}

function defaults() {
	const zones = st.zones || [];
	const bz = browserZone();
	const zone = (st.zonename && st.zonename != 'UTC' && zones.includes(st.zonename)) ? st.zonename
		: (bz && zones.includes(bz)) ? bz : (zones.includes('UTC') ? 'UTC' : (zones[0] || 'UTC'));
	const sc = /^[A-Z]{2}$/.test(st.country || '') && COUNTRIES.includes(st.country) ? st.country : null;
	const w = st.wan || {};
	const f = st.wifi || {};
	const base = (f.ssid || 'MiWRT').trim();
	const cut = (s, suffix) => {
		let b = s;
		while (bytes(b + suffix) > 32 && b.length) b = b.slice(0, -1);
		return b + suffix;
	};
	const g = st.guest || {}, io = st.iot || {}, p = st.protection || { where: 'none' };
	return {
		region: { lang: [ 'auto', 'en', 'ru', 'zh_cn' ].includes(st.lang) ? st.lang : 'auto', zonename: zone, country: browserCountry() || sc || '' },
		mode: st.mode == 'ap' ? 'ap' : 'router',
		wan: {
			proto: [ 'dhcp', 'pppoe', 'static' ].includes(w.proto) ? w.proto : 'dhcp',
			username: w.username || '', password: w.password || '', vlan: w.vlan ? String(w.vlan) : '',
			ipaddr: w.ipaddr || '', netmask: w.netmask || '255.255.255.0', gateway: w.gateway || '', dns: (w.dns || []).join(' ')
		},
		ap: { proto: 'dhcp', ipaddr: '', netmask: '255.255.255.0', gateway: '', dns: '' },
		wifi: {
			ssid: f.ssid || '', ssid5: f.ssid5 || f.ssid || '', key: f.key || '',
			security: /^psk2/.test(f.encryption || '') ? 'psk2' : 'sae-mixed',
			split: !!f.split && hasBand('5g')
		},
		guest: { on: !!g.enabled, ssid: g.ssid || cut(base, ' Guest'), key: g.key || randomKey() },
		iot: { on: !!io.ours, ssid: io.ssid || cut(base, ' IoT'), key: io.key || randomKey(), internet: io.ours ? io.internet !== false : true, all_bands: false },
		protection: { where: p.where == 'none' ? 'none' : 'keep', url: p.where == 'network' ? (p.url || '') : '', username: p.where == 'network' ? (p.username || '') : 'admin', password: '', handout: true },
		password: '', password2: ''
	};
}

/* answers survive a reload of the page (but no passwords for the router, PPPoE or AdGuard Home) */
function save() {
	try {
		const c = JSON.parse(JSON.stringify(cfg));
		c.password = c.password2 = '';
		c.wan.password = '';
		c.protection.password = '';
		sessionStorage.setItem(KEEP, JSON.stringify({ cfg: c, screen: ui.screen, furthest: ui.furthest }));
	}
	catch (e) {}
}

function restore() {
	try {
		const k = JSON.parse(sessionStorage.getItem(KEEP) || 'null');
		if (!k || !k.cfg) return;
		for (const s in cfg)
			if (k.cfg[s] != null && typeof cfg[s] == 'object') Object.assign(cfg[s], k.cfg[s]);
			else if (k.cfg[s] != null) cfg[s] = k.cfg[s];
		cfg.wan.password = st.wan?.password || '';
		if (ORDER.includes(k.screen)) ui.screen = k.screen;
		ui.furthest = Math.max(-1, Math.min(+k.furthest || -1, ORDER.length - 1));
	}
	catch (e) {}
}

function forget() {
	try { sessionStorage.removeItem(KEEP); }
	catch (e) {}
}

function steps() {
	return cfg.mode == 'ap' ? ORDER.filter(s => s != 'guest' && s != 'iot') : ORDER;
}

const routerAddr = () => st.lan?.ipaddr || location.hostname;

/* ------------------------------------------------------------------ */
/* Validation, per step                                               */
/* ------------------------------------------------------------------ */

function vSsid(s) {
	if (!s) return t('e_ssid_empty');
	if (bytes(s) > 32) return t('e_ssid');
	if (CTRL.test(s)) return t('e_chars');
	return null;
}

function vKey(k) {
	return /^[\x20-\x7e]{8,63}$/.test(k ?? '') ? null : t('e_key');
}

function vStatic(e, o, gwField) {
	if (!isIp(o.ipaddr)) e['f-ip'] = t('e_ip');
	if (!isMask(o.netmask)) e['f-mask'] = t('e_mask');
	if (!isIp(o.gateway)) e[gwField] = t('e_ip');
	if (!dnsList(o.dns).every(isIp)) e['f-dns'] = t('e_dns');
}

function agAvailable() {
	if (cfg.mode == 'ap') return 'mode';
	if (st.adguard?.available) return null;
	return st.adguard?.why || 'storage';
}

const VALIDATE = {
	region() {
		const e = {};
		if (!COUNTRIES.includes(cfg.region.country)) e['f-country'] = t('e_country');
		if (!(st.zones || []).includes(cfg.region.zonename)) e['f-zone'] = t('e_zone');
		return e;
	},
	mode() {
		const e = {};
		if (cfg.mode == 'router') {
			const w = cfg.wan;
			if (w.proto == 'pppoe') {
				if (!w.username || bytes(w.username) > 128 || CTRL.test(w.username)) e['f-user'] = t('e_user');
				if (bytes(w.password) > 128 || CTRL.test(w.password)) e['f-ppass'] = t('e_chars');
				if (w.vlan !== '' && !(/^\d+$/.test(w.vlan) && +w.vlan >= 1 && +w.vlan <= 4094)) e['f-vlan'] = t('e_vlan');
			}
			if (w.proto == 'static') vStatic(e, w, 'f-gw');
		}
		else if (cfg.ap.proto == 'static') vStatic(e, cfg.ap, 'f-gw');
		return e;
	},
	wifi() {
		const e = {}, f = cfg.wifi;
		const a = vSsid(f.ssid);
		if (a) e['f-ssid'] = a;
		if (f.split) {
			const b = vSsid(f.ssid5);
			if (b) e['f-ssid5'] = b;
			else if (f.ssid5 == f.ssid) e['f-ssid5'] = t('e_same5');
		}
		const k = vKey(f.key);
		if (k) e['f-key'] = k;
		return e;
	},
	guest() {
		const e = {}, g = cfg.guest;
		if (!g.on || cfg.mode == 'ap') return e;
		const a = vSsid(g.ssid);
		if (a) e['f-g-ssid'] = a;
		else if (mainNames().includes(g.ssid)) e['f-g-ssid'] = t('e_unique');
		const k = vKey(g.key);
		if (k) e['f-g-key'] = k;
		return e;
	},
	iot() {
		const e = {}, n = cfg.iot;
		if (!n.on || cfg.mode == 'ap' || iotForeign()) return e;
		const a = vSsid(n.ssid);
		if (a) e['f-i-ssid'] = a;
		else if (mainNames().concat(guestOn() ? [ cfg.guest.ssid ] : []).includes(n.ssid)) e['f-i-ssid'] = t('e_unique');
		const k = vKey(n.key);
		if (k) e['f-i-key'] = k;
		return e;
	},
	protect() {
		const e = {}, p = cfg.protection;
		if (p.where == 'network') {
			if (!/^(https?:\/\/)?[A-Za-z0-9.-]+(:\d{1,5})?\/?$/.test(p.url.trim())) e['f-ag-url'] = t('e_ag_url');
			if (!p.username) e['f-ag-user'] = t('e_ag_login');
			if (!p.password) e['f-ag-pass'] = t('e_ag_login');
		}
		return e;
	},
	password() {
		const e = {};
		const pw = cfg.password;
		if (pw.length < 8) e['f-pw'] = t('e_pw');
		else if (pw.length > 128) e['f-pw'] = t('e_pw_long');
		else if (CTRL.test(pw)) e['f-pw'] = t('e_chars');
		else if (pw == cfg.wifi.key || (guestOn() && pw == cfg.guest.key) || (iotOn() && pw == cfg.iot.key)) e['f-pw'] = t('e_pw_wifi');
		if (!e['f-pw'] && cfg.password2 != pw) e['f-pw2'] = t('e_pw2');
		return e;
	},
	review() {
		return {};
	}
};

const mainNames = () => [ cfg.wifi.ssid ].concat(cfg.wifi.split ? [ cfg.wifi.ssid5 ] : []);
const guestOn = () => cfg.mode == 'router' && cfg.guest.on;
const iotForeign = () => !!(st.iot?.exists && !st.iot?.ours);
const iotOn = () => cfg.mode == 'router' && cfg.iot.on && !iotForeign();

/* ------------------------------------------------------------------ */
/* Building blocks                                                    */
/* ------------------------------------------------------------------ */

function errorFor(id) {
	const m = ui.errors[id];
	return m ? h('p', { class: 'mws-err', id: id + '-err' }, [ icon('alert'), h('span', {}, m) ]) : null;
}

function clearError(id, el) {
	if (!ui.errors[id]) return;
	delete ui.errors[id];
	el.removeAttribute('aria-invalid');
	const box = el.closest('.mws-field');
	box?.classList.remove('is-invalid');
	document.getElementById(id + '-err')?.remove();
	const ref = [ id + '-hint' ].filter(x => document.getElementById(x)).join(' ');
	if (ref) el.setAttribute('aria-describedby', ref); else el.removeAttribute('aria-describedby');
}

/* one labelled input: o = { id, label, value, set, hint, type, secret, reveal, auto, mode, ph, max, extra, meter, optional } */
function field(o) {
	const err = ui.errors[o.id];
	const secret = !!o.secret;
	const shown = secret ? !!ui.reveal[o.id] : true;
	const desc = [ o.hint ? o.id + '-hint' : null, o.meter ? o.id + '-meter' : null, err ? o.id + '-err' : null ].filter(Boolean).join(' ');
	const input = h('input', {
		id: o.id, name: o.id, type: secret && !shown ? 'password' : (o.type || 'text'), value: o.value ?? '',
		class: secret ? 'is-mono' : null,
		autocomplete: o.auto || 'off', inputmode: o.mode, placeholder: o.ph, maxlength: o.max,
		spellcheck: 'false', autocapitalize: 'off', autocorrect: 'off',
		'aria-invalid': err ? 'true' : null, 'aria-describedby': desc || null, required: o.optional ? null : true,
		oninput: ev => {
			o.set(ev.target.value);
			clearError(o.id, ev.target);
			if (o.meter) updateMeter(o.id, ev.target.value);
			if (o.onchange) o.onchange();
			save();
		}
	});
	const tools = [];
	if (secret)
		tools.push(h('button', {
			type: 'button', class: 'mws-tool', 'aria-label': shown ? t('hide') : t('show'), title: shown ? t('hide') : t('show'),
			'aria-pressed': shown ? 'true' : 'false', 'aria-controls': o.id,
			onclick: () => { ui.reveal[o.id] = !shown; render(o.id); }
		}, icon(shown ? 'eyeoff' : 'eye')));
	const gen = o.generate ? h('button', {
		type: 'button', class: 'mws-link is-small', onclick: () => {
			o.set(randomKey());
			ui.reveal[o.id] = true;
			delete ui.errors[o.id];
			save();
			render(o.id);
		}
	}, [ icon('refresh'), h('span', {}, t('generate')) ]) : null;
	return h('div', { class: 'mws-field' + (err ? ' is-invalid' : '') + (o.cls ? ' ' + o.cls : '') }, [
		h('div', { class: 'mws-label-row' }, [
			h('label', { for: o.id }, [ o.label, o.optional ? h('span', { class: 'mws-opt' }, ' · ' + t('optional')) : null ]),
			gen
		]),
		h('div', { class: 'mws-input' + (tools.length ? ' has-tools' : '') }, [ input, tools.length ? h('div', { class: 'mws-tools' }, tools) : null ]),
		o.meter ? meter(o.id, o.value) : null,
		o.hint ? h('p', { class: 'mws-hint', id: o.id + '-hint' }, o.hint) : null,
		errorFor(o.id)
	]);
}

function meter(id, value) {
	const s = strength(value);
	return h('div', { class: 'mws-meter', id: id + '-meter', 'data-s': String(s), 'aria-live': 'polite' }, [
		h('div', { class: 'mws-meter-bar', 'aria-hidden': 'true' }, [ h('i'), h('i'), h('i'), h('i') ]),
		h('span', {}, value ? t('st_label', t('st_' + s)) : '')
	]);
}

function updateMeter(id, value) {
	const m = document.getElementById(id + '-meter');
	if (!m) return;
	const s = strength(value);
	m.setAttribute('data-s', String(s));
	m.querySelector('span').textContent = value ? t('st_label', t('st_' + s)) : '';
}

function select(o) {
	const err = ui.errors[o.id];
	const sel = h('select', {
		id: o.id, name: o.id, 'aria-invalid': err ? 'true' : null,
		'aria-describedby': [ o.hint ? o.id + '-hint' : null, err ? o.id + '-err' : null ].filter(Boolean).join(' ') || null,
		onchange: ev => { o.set(ev.target.value); clearError(o.id, ev.target); save(); if (o.rerender) render(o.id); }
	}, o.options);
	sel.value = o.value ?? '';
	return h('div', { class: 'mws-field' + (err ? ' is-invalid' : '') }, [
		h('label', { for: o.id }, o.label),
		h('div', { class: 'mws-input mws-select' }, sel),
		o.hint ? h('p', { class: 'mws-hint', id: o.id + '-hint' }, o.hint) : null,
		errorFor(o.id)
	]);
}

/* radio cards: items = [{ value, title, desc, badge, disabled, why, icon }] */
function choices(name, legend, value, items, set, compact) {
	return h('fieldset', { class: 'mws-choices' + (compact ? ' is-compact' : '') }, [
		h('legend', { class: compact ? 'mws-legend' : 'mws-sr' }, legend),
		h('div', { class: 'mws-choice-list' + (items.length == 2 && !compact ? ' is-pair' : '') }, items.map(it => {
			const id = name + '-' + it.value;
			const on = value == it.value;
			return h('label', { class: 'mws-choice' + (on ? ' is-on' : '') + (it.disabled ? ' is-disabled' : ''), for: id }, [
				h('input', {
					type: 'radio', id, name, value: it.value, checked: on, disabled: it.disabled,
					'aria-describedby': it.desc || it.why ? id + '-d' : null,
					onchange: () => { set(it.value); save(); render(id); }
				}),
				h('span', { class: 'mws-choice-dot', 'aria-hidden': 'true' }),
				h('span', { class: 'mws-choice-body' }, [
					h('span', { class: 'mws-choice-title' }, [ it.title, it.badge ? h('span', { class: 'mws-badge' }, it.badge) : null ]),
					(it.desc || it.why) ? h('span', { class: 'mws-choice-desc', id: id + '-d' }, [
						it.desc || null, it.why ? h('span', { class: 'mws-choice-why' }, [ icon('info'), h('span', {}, it.why) ]) : null
					]) : null
				])
			]);
		}))
	]);
}

function toggle(id, label, desc, checked, set, disabled) {
	return h('div', { class: 'mws-switch' + (disabled ? ' is-disabled' : '') }, [
		h('div', { class: 'mws-switch-text' }, [
			h('label', { for: id, class: 'mws-switch-label' }, label),
			desc ? h('p', { class: 'mws-hint', id: id + '-d' }, desc) : null
		]),
		h('input', {
			type: 'checkbox', role: 'switch', id, class: 'mws-switch-input', checked, disabled,
			'aria-describedby': desc ? id + '-d' : null,
			onchange: ev => { set(ev.target.checked); save(); render(id); }
		})
	]);
}

function note(kind, kids) {
	return h('div', { class: 'mws-note is-' + kind }, [ icon(kind == 'warn' ? 'alert' : kind == 'ok' ? 'check' : 'info'), h('div', {}, kids) ]);
}

/* ------------------------------------------------------------------ */
/* Steps                                                              */
/* ------------------------------------------------------------------ */

const STEP = {
	region() {
		const names = (() => {
			try { return new Intl.DisplayNames([ LANG_TAGS[lang] ], { type: 'region' }); }
			catch (e) { return null; }
		})();
		const cn = c => { try { return names?.of(c) || c; } catch (e) { return c; } };
		const countries = COUNTRIES.map(c => [ c, cn(c) ]).sort((a, b) => a[1].localeCompare(b[1], LANG_TAGS[lang]));
		const zones = st.zones || [];
		const groups = {};
		for (const z of zones) {
			const i = z.indexOf('/');
			const g = i > 0 ? z.slice(0, i) : '';
			(groups[g] = groups[g] || []).push(z);
		}
		const zoneOpts = [];
		for (const z of (groups[''] || [])) zoneOpts.push(h('option', { value: z }, z.replace(/_/g, ' ')));
		for (const g of Object.keys(groups).filter(Boolean).sort())
			zoneOpts.push(h('optgroup', { label: g }, groups[g].map(z => h('option', { value: z }, z.slice(g.length + 1).replace(/_/g, ' ').replace(/\//g, ' / ')))));
		const bz = browserZone();
		return [
			select({
				id: 'f-lang', label: t('r_lang'), value: cfg.region.lang, rerender: true,
				set: v => { cfg.region.lang = v; },
				options: [ h('option', { value: 'auto' }, t('r_lang_auto') + ' (' + LANG_NAMES[browserLang()] + ')') ]
					.concat([ 'en', 'ru', 'zh_cn' ].map(l => h('option', { value: l, lang: LANG_TAGS[l] }, LANG_NAMES[l])))
			}),
			select({
				id: 'f-country', label: t('r_country'), value: cfg.region.country, set: v => { cfg.region.country = v; },
				options: [ h('option', { value: '', disabled: true }, t('r_country_ph')) ].concat(countries.map(([ c, n ]) => h('option', { value: c }, n)))
			}),
			select({
				id: 'f-zone', label: t('r_zone'), value: cfg.region.zonename, set: v => { cfg.region.zonename = v; },
				hint: bz && zones.includes(bz) && bz != cfg.region.zonename ? t('r_zone_hint', bz.replace(/_/g, ' ')) : null,
				options: zoneOpts
			})
		];
	},

	mode() {
		const out = [
			choices('mode', t('m_title'), cfg.mode, [
				{ value: 'router', title: t('m_router'), desc: t('m_router_d'), badge: t('recommended') },
				{ value: 'ap', title: t('m_ap'), desc: t('m_ap_d') }
			], v => {
				cfg.mode = v;
				if (v == 'ap' && cfg.protection.where == 'router') cfg.protection.where = 'none';
			})
		];
		if (cfg.mode == 'router') {
			const w = cfg.wan;
			if (st.wan?.link === true) out.push(note('ok', t('m_link_up')));
			else if (st.wan?.link === false) out.push(note('warn', t('m_link_down')));
			out.push(choices('proto', t('m_inet'), w.proto, [
				{ value: 'dhcp', title: t('m_dhcp'), desc: t('m_dhcp_d') },
				{ value: 'pppoe', title: t('m_pppoe'), desc: t('m_pppoe_d') },
				{ value: 'static', title: t('m_static'), desc: t('m_static_d') }
			], v => { w.proto = v; ui.errors = {}; }, true));
			if (w.proto == 'pppoe')
				out.push(h('div', { class: 'mws-group' }, [
					field({ id: 'f-user', label: t('m_user'), value: w.username, set: v => { w.username = v; }, auto: 'off', max: 128 }),
					field({ id: 'f-ppass', label: t('m_pass'), value: w.password, set: v => { w.password = v; }, secret: true, auto: 'off', max: 128, optional: true }),
					field({ id: 'f-vlan', label: t('m_vlan'), value: w.vlan, set: v => { w.vlan = v.trim(); }, mode: 'numeric', max: 4, hint: t('m_vlan_h'), optional: true, cls: 'is-short' })
				]));
			if (w.proto == 'static') out.push(staticFields(w, t('m_gw'), t('m_dns_h')));
		}
		else {
			const a = cfg.ap;
			out.push(note('info', t('m_ap_note')));
			out.push(choices('approto', t('m_ap_addr'), a.proto, [
				{ value: 'dhcp', title: t('m_ap_dhcp'), desc: t('m_ap_dhcp_d') },
				{ value: 'static', title: t('m_static'), desc: t('m_ap_static_d') }
			], v => { a.proto = v; ui.errors = {}; }, true));
			if (a.proto == 'static') out.push(staticFields(a, t('m_ap_gw'), t('m_ap_dns_h')));
		}
		return out;
	},

	wifi() {
		const f = cfg.wifi;
		return [
			field({ id: 'f-ssid', label: f.split ? t('f_name') + ' (2.4 GHz)' : t('f_name'), value: f.ssid, set: v => { f.ssid = v; }, auto: 'off' }),
			hasBand('5g') && hasBand('2g') ? toggle('f-split', t('f_split'), t('f_split_d'), f.split, v => {
				f.split = v;
				if (v && (!f.ssid5 || f.ssid5 == f.ssid)) {
					let b = f.ssid;
					while (bytes(b + '-5G') > 32 && b.length) b = b.slice(0, -1);
					f.ssid5 = b + '-5G';
				}
			}) : null,
			f.split ? field({ id: 'f-ssid5', label: t('f_name5'), value: f.ssid5, set: v => { f.ssid5 = v; }, auto: 'off' }) : null,
			field({ id: 'f-key', label: t('f_pass'), value: f.key, set: v => { f.key = v; }, secret: true, generate: true, meter: true, hint: t('f_pass_h'), max: 63 }),
			choices('sec', t('f_sec'), f.security, [
				{ value: 'sae-mixed', title: t('f_sae'), desc: t('f_sae_d'), badge: t('recommended') },
				{ value: 'psk2', title: t('f_psk2'), desc: t('f_psk2_d') }
			], v => { f.security = v; }, true)
		];
	},

	guest() {
		const g = cfg.guest;
		return [
			toggle('f-g-on', t('g_on'), t('g_on_d'), g.on, v => { g.on = v; }),
			g.on ? h('div', { class: 'mws-group' }, [
				field({ id: 'f-g-ssid', label: t('g_name'), value: g.ssid, set: v => { g.ssid = v; } }),
				field({ id: 'f-g-key', label: t('g_pass'), value: g.key, set: v => { g.key = v; }, secret: true, generate: true, meter: true, max: 63 })
			]) : null
		];
	},

	iot() {
		const n = cfg.iot;
		if (iotForeign()) return [ note('info', t('i_exists')) ];
		return [
			toggle('f-i-on', t('i_on'), t('i_on_d'), n.on, v => { n.on = v; }),
			n.on ? h('div', { class: 'mws-group' }, [
				field({ id: 'f-i-ssid', label: t('i_name'), value: n.ssid, set: v => { n.ssid = v; } }),
				field({ id: 'f-i-key', label: t('i_pass'), value: n.key, set: v => { n.key = v; }, secret: true, generate: true, meter: true, max: 63 }),
				toggle('f-i-inet', t('i_inet'), t('i_inet_d'), n.internet, v => { n.internet = v; }),
				hasBand('5g') ? toggle('f-i-5g', t('i_5g'), t('i_5g_d'), n.all_bands, v => { n.all_bands = v; }) : null
			]) : null
		];
	},

	protect() {
		const p = cfg.protection;
		const why = agAvailable();
		const mb = kb => Math.floor((kb || 0) / 1024);
		const reason = why == 'mode' ? t('p_why_mode') : why == 'memory' ? t('p_why_memory')
			: why ? t('p_why_storage', mb(st.adguard?.need_kb), mb(st.adguard?.free_kb)) : null;
		const items = [];
		const had = st.protection?.where && st.protection.where != 'none';
		if (had) items.push({ value: 'keep', title: t('p_keep'), desc: t('p_keep_d', st.protection.url || '') });
		if (st.protection?.where != 'router') {
			items.push({ value: 'router', title: t('p_router'), desc: t('p_router_d'), badge: why ? null : t('recommended'), disabled: !!why, why: reason });
			items.push({ value: 'network', title: t('p_net'), desc: t('p_net_d') });
		}
		if (!had) items.push({ value: 'none', title: t('p_none'), desc: t('p_none_d') });
		const out = [ choices('ag', t('p_title'), p.where, items, v => { p.where = v; ui.errors = {}; }) ];
		if (p.where == 'router') out.push(note('info', t('p_router_after', routerAddr())));
		if (p.where == 'network') {
			const sig = p.url.trim() + '\n' + p.username + '\n' + p.password;
			const tested = ui.test.sig == sig ? ui.test : { state: null };
			out.push(h('div', { class: 'mws-group' }, [
				field({ id: 'f-ag-url', label: t('p_url'), value: p.url, set: v => { p.url = v; }, ph: '192.168.1.2:3000', mode: 'url' }),
				h('div', { class: 'mws-row' }, [
					field({ id: 'f-ag-user', label: t('p_user'), value: p.username, set: v => { p.username = v; }, auto: 'off' }),
					field({ id: 'f-ag-pass', label: t('p_pass'), value: p.password, set: v => { p.password = v; }, secret: true, auto: 'off' })
				]),
				h('div', { class: 'mws-test' }, [
					h('button', { type: 'button', class: 'mws-btn is-quiet', disabled: tested.state == 'busy', onclick: () => testAdguard() },
						tested.state == 'busy' ? [ h('span', { class: 'mws-spin', 'aria-hidden': 'true' }), t('p_testing') ] : [ icon('link'), t('p_test') ]),
					h('div', { 'aria-live': 'polite', class: 'mws-test-out' },
						tested.state == 'ok' ? note('ok', tested.text) : tested.state == 'fail' ? note('warn', tested.text) : null)
				]),
				cfg.mode == 'router' ? toggle('f-ag-handout', t('p_handout'), t('p_handout_d'), p.handout, v => { p.handout = v; }) : null
			]));
		}
		return out;
	},

	password() {
		return [
			field({ id: 'f-pw', label: t('pw_new'), value: cfg.password, set: v => { cfg.password = v; }, secret: true, auto: 'new-password', meter: true, hint: t('pw_h'), max: 128 }),
			field({ id: 'f-pw2', label: t('pw_again'), value: cfg.password2, set: v => { cfg.password2 = v; }, secret: true, auto: 'new-password', max: 128 }),
			cfg.mode == 'router' && cfg.protection.where == 'router' ? note('info', t('pw_ag')) : null
		];
	},

	review() {
		const f = cfg.wifi, rows = [];
		const zone = cfg.region.zonename.replace(/_/g, ' ');
		let country = cfg.region.country;
		try { country = new Intl.DisplayNames([ LANG_TAGS[lang] ], { type: 'region' }).of(country) || country; } catch (e) {}
		const dots = s => '•'.repeat(Math.min(12, (s || '').length));
		const langName = cfg.region.lang == 'auto' ? t('r_lang_auto') : LANG_NAMES[cfg.region.lang];
		rows.push([ 'region', t('s_region'), [ [ t('lang_label'), langName ], [ t('r_country'), country ], [ t('r_zone'), zone ] ] ]);
		let conn;
		if (cfg.mode == 'router') {
			const w = cfg.wan;
			const how = w.proto == 'dhcp' ? t('m_dhcp') : w.proto == 'pppoe' ? 'PPPoE · ' + w.username + (w.vlan ? ' · VLAN ' + w.vlan : '') : w.ipaddr + ' · ' + w.gateway;
			conn = [ [ t('v_mode'), t('m_router') ], [ t('m_inet'), how ] ];
		}
		else
			conn = [ [ t('v_mode'), t('m_ap') ], [ t('m_ap_addr'), cfg.ap.proto == 'dhcp' ? t('v_addr_auto') : cfg.ap.ipaddr ] ];
		rows.push([ 'mode', t('s_mode'), conn ]);
		const nets = f.split ? [ [ t('f_name') + ' (2.4 GHz)', f.ssid ], [ t('f_name5'), f.ssid5 ] ] : [ [ t('f_name'), f.ssid ] ];
		rows.push([ 'wifi', t('s_wifi'), nets.concat([ [ t('f_pass'), f.key, true ], [ t('f_sec'), f.security == 'psk2' ? t('f_psk2') : t('f_sae') ] ]) ]);
		if (cfg.mode == 'router') {
			rows.push([ 'guest', t('s_guest'), [ [ t('g_on'), guestOn() ? cfg.guest.ssid : t('off') ] ].concat(guestOn() ? [ [ t('g_pass'), cfg.guest.key, true ] ] : []) ]);
			if (!iotForeign())
				rows.push([ 'iot', t('s_iot'), [ [ t('i_on'), iotOn()
					? cfg.iot.ssid + ' · ' + (cfg.iot.all_bands ? t('v_bands_all') : t('v_bands_24')) + (cfg.iot.internet ? '' : ' · ' + t('v_noinet'))
					: t('off') ] ].concat(iotOn() ? [ [ t('i_pass'), cfg.iot.key, true ] ] : []) ]);
		}
		const p = cfg.protection;
		const ag = p.where == 'router' ? t('p_router') : p.where == 'network' ? t('p_net') + ' · ' + p.url.trim()
			: p.where == 'keep' ? t('p_keep_d', st.protection?.url || '') : t('p_none');
		rows.push([ 'protect', t('s_protect'), [ [ 'AdGuard Home', ag ] ] ]);
		rows.push([ 'password', t('s_password'), [ [ t('pw_new'), t('v_set') ] ] ]);

		return [
			h('div', { class: 'mws-review' }, rows.map(([ step, title, items ]) => h('section', { class: 'mws-review-sec', 'aria-labelledby': 'rv-' + step }, [
				h('header', {}, [
					h('h2', { id: 'rv-' + step }, title),
					h('button', { type: 'button', class: 'mws-link', 'aria-label': t('change') + ': ' + title, onclick: () => go(step, true) }, t('change'))
				]),
				h('dl', {}, items.map(([ k, v, secret ]) => [
					h('dt', {}, k),
					h('dd', { class: secret ? 'mws-secret' : null }, secret ? revealable('rv-k-' + k, v, dots(v)) : v)
				]))
			]))),
			note('warn', t('v_warn', f.ssid))
		];
	}
};

function staticFields(o, gwLabel, dnsHint) {
	return h('div', { class: 'mws-group' }, [
		h('div', { class: 'mws-row' }, [
			field({ id: 'f-ip', label: t('m_ip'), value: o.ipaddr, set: v => { o.ipaddr = v.trim(); }, mode: 'decimal', ph: '192.168.1.2' }),
			field({ id: 'f-mask', label: t('m_mask'), value: o.netmask, set: v => { o.netmask = v.trim(); }, mode: 'decimal', ph: '255.255.255.0' })
		]),
		field({ id: 'f-gw', label: gwLabel, value: o.gateway, set: v => { o.gateway = v.trim(); }, mode: 'decimal', ph: '192.168.1.1' }),
		field({ id: 'f-dns', label: t('m_dns'), value: o.dns, set: v => { o.dns = v; }, hint: dnsHint, optional: true, ph: '9.9.9.9 1.1.1.1' })
	]);
}

function revealable(id, value, masked) {
	const shown = !!ui.reveal[id];
	return [
		h('span', { class: 'mws-mono' }, shown ? value : masked),
		h('button', {
			type: 'button', class: 'mws-tool is-inline', 'aria-label': shown ? t('hide') : t('show'), title: shown ? t('hide') : t('show'),
			'aria-pressed': shown ? 'true' : 'false', onclick: () => { ui.reveal[id] = !shown; render(); }
		}, icon(shown ? 'eyeoff' : 'eye'))
	];
}

/* ------------------------------------------------------------------ */
/* Actions                                                            */
/* ------------------------------------------------------------------ */

function go(screen, fromReview) {
	ui.fromReview = !!fromReview;
	ui.screen = screen;
	ui.errors = {};
	ui.banner = null;
	ui.focusTitle = true;
	ui.enter = true;
	const i = ORDER.indexOf(screen);
	if (i > ui.furthest) ui.furthest = i;
	save();
	render();
}

function showErrors(e) {
	ui.errors = e;
	ui.banner = t('e_fix');
	render();
	const first = Object.keys(e)[0];
	const el = first && document.getElementById(first);
	if (el) {
		el.focus({ preventScroll: true });
		(el.closest('.mws-field') || el).scrollIntoView({ block: 'center', behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' });
	}
}

async function next() {
	const s = ui.screen;
	if (s == 'welcome') return go(steps()[0]);
	if (s == 'review') return apply();
	const e = VALIDATE[s]();
	if (Object.keys(e).length) return showErrors(e);
	if (s == 'protect' && cfg.protection.where == 'network') {
		if (!(await testAdguard())) return;
	}
	if (ui.fromReview) return go('review');
	const list = steps();
	go(list[list.indexOf(s) + 1] || 'review');
}

function back() {
	if (ui.fromReview) return go('review');
	const list = steps();
	const i = list.indexOf(ui.screen);
	go(i > 0 ? list[i - 1] : 'welcome');
}

async function testAdguard() {
	const p = cfg.protection;
	const e = VALIDATE.protect();
	if (Object.keys(e).length) { showErrors(e); return false; }
	const sig = p.url.trim() + '\n' + p.username + '\n' + p.password;
	if (ui.test.sig == sig && ui.test.state == 'ok') return true;
	ui.test = { state: 'busy', sig, text: null };
	render();
	let r;
	try { r = await callTest(p.url.trim(), p.username, p.password); }
	catch (err) { r = { error: err.message }; }
	if (ui.test.sig != sig) return false;
	if (r && typeof r == 'object' && r.ok) {
		ui.test = { state: 'ok', sig, text: t('p_ok', r.version || '') };
		render();
		return true;
	}
	ui.test = { state: 'fail', sig, text: t('e_ag_fail', (r && r.error) || String(r)) };
	render();
	document.querySelector('.mws-test-out')?.scrollIntoView({ block: 'nearest' });
	return false;
}

function buildConfig() {
	const r = cfg.mode == 'router';
	const w = cfg.wan, a = cfg.ap, f = cfg.wifi, p = cfg.protection;
	return {
		region: { lang: cfg.region.lang, zonename: cfg.region.zonename, country: cfg.region.country },
		mode: cfg.mode,
		wan: r ? {
			proto: w.proto,
			username: w.proto == 'pppoe' ? w.username : null,
			password: w.proto == 'pppoe' ? w.password : null,
			vlan: w.proto == 'pppoe' && w.vlan ? +w.vlan : null,
			ipaddr: w.proto == 'static' ? w.ipaddr : null,
			netmask: w.proto == 'static' ? w.netmask : null,
			gateway: w.proto == 'static' ? w.gateway : null,
			dns: w.proto == 'static' ? dnsList(w.dns) : []
		} : null,
		ap: r ? null : {
			proto: a.proto,
			ipaddr: a.proto == 'static' ? a.ipaddr : null,
			netmask: a.proto == 'static' ? a.netmask : null,
			gateway: a.proto == 'static' ? a.gateway : null,
			dns: a.proto == 'static' ? dnsList(a.dns) : []
		},
		wifi: { ssid: f.ssid, ssid5: f.split ? f.ssid5 : null, key: f.key, security: f.security, split: !!f.split },
		guest: guestOn() ? { on: true, ssid: cfg.guest.ssid, key: cfg.guest.key } : { on: false },
		iot: iotOn() ? { on: true, ssid: cfg.iot.ssid, key: cfg.iot.key, internet: !!cfg.iot.internet, all_bands: !!cfg.iot.all_bands } : { on: false },
		protection: p.where == 'network'
			? { where: 'network', url: p.url.trim(), username: p.username, password: p.password, handout: r ? !!p.handout : false }
			: { where: (p.where == 'router' && !r) ? 'none' : p.where },
		password: cfg.password
	};
}

const FIELD_STEP = { region: 'region', mode: 'mode', wifi: 'wifi', guest: 'guest', iot: 'iot', protection: 'protect', password: 'password' };

async function apply() {
	if (ui.busy) return;
	// every page once more, in case something changed on an earlier page after a later one was checked
	for (const s of steps()) {
		const e = VALIDATE[s]();
		if (Object.keys(e).length) {
			go(s, true);
			return showErrors(e);
		}
	}
	ui.busy = true;
	ui.banner = null;
	render();
	let r;
	try { r = await callApply(buildConfig()); }
	catch (err) { r = { error: err.message }; }
	ui.busy = false;
	if (!r || typeof r != 'object' || !r.ok) {
		const msg = (r && typeof r == 'object' && r.error) ? t('e_router_said', r.error) : t('e_generic', String(r));
		const step = r && FIELD_STEP[r.field];
		if (step && steps().includes(step)) {
			go(step, true);
			ui.banner = msg;
			if (step == 'protect') ui.test = { state: 'fail', sig: null, text: msg };
		}
		else ui.banner = msg;
		render();
		return;
	}
	forget();
	ui.result = r;
	ui.screen = 'apply';
	ui.started = ui.contact = Date.now();
	ui.job = null;
	ui.focusTitle = true;
	ui.enter = true;
	render();
	ui.timer = setTimeout(poll, 4000);
}

/* the job is read with a short timeout of its own: while the network restarts, requests just fail */
function fetchJob() {
	const ctl = new AbortController();
	const tm = setTimeout(() => ctl.abort(), 5000);
	return fetch(L.url('admin/ubus'), {
		method: 'POST', credentials: 'same-origin', cache: 'no-store', signal: ctl.signal,
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({ jsonrpc: '2.0', id: Date.now(), method: 'call', params: [ L.env.sessionid, 'miwrt-setup', 'job', {} ] })
	}).then(res => res.json()).then(m => {
		if (Array.isArray(m?.result) && m.result[0] === 0 && m.result[1]) return m.result[1];
		throw new Error('no answer');
	}).finally(() => clearTimeout(tm));
}

async function poll() {
	try {
		ui.job = await fetchJob();
		ui.contact = Date.now();
	}
	catch (e) {}
	const s = ui.job?.setup;
	if (s?.state == 'failed') {
		ui.screen = 'failed';
		ui.focusTitle = true;
		ui.enter = true;
		render();
		return;
	}
	if (s?.state == 'done' && s.step == 'done') {
		ui.screen = 'done';
		ui.focusTitle = true;
		ui.enter = true;
		render();
		return;
	}
	render();
	ui.timer = setTimeout(poll, 2000);
}

function skip() {
	const dlg = h('dialog', { class: 'mws-dialog', 'aria-labelledby': 'mws-dlg-t', 'aria-describedby': 'mws-dlg-d' }, [
		h('h2', { id: 'mws-dlg-t' }, t('w_skip_q')),
		h('p', { id: 'mws-dlg-d' }, t('w_skip_text')),
		h('div', { class: 'mws-dialog-actions' }, [
			h('button', { type: 'button', class: 'mws-btn is-quiet', onclick: () => dlg.close() }, t('w_skip_no')),
			h('button', {
				type: 'button', class: 'mws-btn is-danger', onclick: async ev => {
					ev.target.disabled = true;
					try { await callSkip(); } catch (e) {}
					forget();
					location.href = L.url('admin/status/overview');
				}
			}, t('w_skip_yes'))
		])
	]);
	dlg.addEventListener('close', () => dlg.remove());
	ui.root.appendChild(dlg);
	dlg.showModal();
}

/* ------------------------------------------------------------------ */
/* Screens                                                            */
/* ------------------------------------------------------------------ */

function art(name, cls) {
	return h('img', { class: cls, src: L.resource('miwrt-setup/' + name + '.webp'), alt: '', width: 320, height: 320, decoding: 'async' });
}

function topbar() {
	const working = [ 'apply', 'done', 'failed' ].includes(ui.screen);
	// the language this page is in; the choice also becomes the web interface language (Region step)
	const langSel = h('select', {
		id: 'mws-lang', 'aria-label': t('lang_label'),
		onchange: ev => { cfg.region.lang = ev.target.value == browserLang() && cfg.region.lang == 'auto' ? 'auto' : ev.target.value; save(); render('mws-lang'); }
	}, [ 'en', 'ru', 'zh_cn' ].map(l => h('option', { value: l, lang: LANG_TAGS[l] }, LANG_NAMES[l])));
	langSel.value = lang;
	return h('header', { class: 'mws-top' }, [
		h('div', { class: 'mws-brand' }, [
			h('img', { src: L.env.resource.replace(/\/resources\/?$/, '/miwrt/logo.svg'), alt: '', width: 28, height: 28, onerror: ev => { ev.target.hidden = true; } }),
			h('strong', {}, 'MiWRT'),
			h('span', {}, t('brand_sub'))
		]),
		h('div', { class: 'mws-top-end' }, [
			working ? null : h('label', { class: 'mws-lang' }, [ icon('world'), langSel ]),
			working ? null : h('button', { type: 'button', class: 'mws-link', onclick: skip }, t('skip'))
		])
	]);
}

function stepper(list, i) {
	return h('ol', { class: 'mws-steps', 'aria-label': t('progress') }, list.map((s, n) => {
		const done = n < i, cur = n == i;
		const reach = ORDER.indexOf(s) <= ui.furthest && !cur && ui.screen != 'welcome';
		const label = [ h('span', { class: 'mws-step-mark', 'aria-hidden': 'true' }, done ? icon('check') : String(n + 1)), h('span', { class: 'mws-step-label' }, t('s_' + s)),
			done ? h('span', { class: 'mws-sr' }, ' (' + t('done_sr') + ')') : null ];
		return h('li', { class: 'mws-step' + (done ? ' is-done' : '') + (cur ? ' is-current' : ''), 'aria-current': cur ? 'step' : null },
			reach ? h('button', { type: 'button', class: 'mws-step-btn', onclick: () => go(s, ui.screen == 'review' || ui.fromReview) }, label) : h('span', {}, label));
	}));
}

function welcome() {
	const model = st.model || t('your_router');
	const items = [ 'region', 'mode', 'wifi', 'guest', 'iot', 'protect', 'password' ];
	const hero = /AC2100/i.test(st.model || '') ? 'login-ac2100.webp' : 'login-be7000.webp';
	return h('div', { class: 'mws-shell is-welcome' }, [
		h('div', { class: 'mws-hero', style: 'background-image:url("' + L.env.resource.replace(/\/resources\/?$/, '/miwrt/') + hero + '")', 'aria-hidden': 'true' }),
		h('main', { class: 'mws-main' }, h('form', { class: 'mws-card' + (ui.enter ? ' is-enter' : ''), novalidate: true, onsubmit: ev => { ev.preventDefault(); next(); } }, [
			h('p', { class: 'mws-eyebrow' }, model),
			h('h1', { id: 'mws-title', tabindex: '-1' }, t('w_title')),
			h('p', { class: 'mws-lede' }, t('w_lede', model)),
			st.imported ? note('ok', t('w_imported')) : null,
			h('h2', { class: 'mws-sub' }, t('w_list')),
			h('ul', { class: 'mws-tiles' }, items.map(s => h('li', {}, [ art(ART[s]), h('span', {}, t('s_' + s)) ]))),
			h('div', { class: 'mws-actions is-welcome' }, [
				h('span'),
				h('button', { type: 'submit', class: 'mws-btn is-primary is-large' }, [ t('w_start'), icon('right') ])
			])
		]))
	]);
}

function stepScreen() {
	const list = steps();
	const i = list.indexOf(ui.screen);
	const s = ui.screen;
	const heads = {
		region: [ 'r_title', 'r_lede' ], mode: [ 'm_title', 'm_lede' ], wifi: [ 'f_title', 'f_lede' ], guest: [ 'g_title', 'g_lede' ],
		iot: [ 'i_title', 'i_lede' ], protect: [ 'p_title', 'p_lede' ], password: [ 'pw_title', 'pw_lede' ], review: [ 'v_title', 'v_lede' ]
	}[s];
	const last = s == 'review';
	return h('div', { class: 'mws-shell' }, [
		h('aside', { class: 'mws-rail' }, [
			h('div', { class: 'mws-rail-art' }, art(ART[s])),
			stepper(list, i)
		]),
		h('main', { class: 'mws-main' }, [
			h('div', {
				class: 'mws-progress', role: 'progressbar', 'aria-label': t('progress'),
				'aria-valuemin': '1', 'aria-valuemax': String(list.length), 'aria-valuenow': String(i + 1),
				'aria-valuetext': t('step_of', i + 1, list.length) + ': ' + t('s_' + s)
			}, list.map((x, n) => h('i', { class: n < i ? 'is-done' : n == i ? 'is-current' : null }))),
			h('form', { class: 'mws-card' + (ui.enter ? ' is-enter' : ''), novalidate: true, onsubmit: ev => { ev.preventDefault(); next(); } }, [
				h('div', { class: 'mws-head' }, [
					h('div', {}, [
						h('p', { class: 'mws-eyebrow' }, t('step_of', i + 1, list.length) + ' · ' + t('s_' + s)),
						h('h1', { id: 'mws-title', tabindex: '-1' }, t(heads[0])),
						h('p', { class: 'mws-lede' }, t(heads[1]))
					]),
					art(ART[s], 'mws-head-art')
				]),
				h('div', { class: 'mws-banner-slot', 'aria-live': 'assertive' }, ui.banner ? note('warn', ui.banner) : null),
				h('div', { class: 'mws-fields' }, STEP[s]()),
				h('div', { class: 'mws-actions' }, [
					ui.fromReview ? h('span') : h('button', { type: 'button', class: 'mws-btn is-quiet', onclick: back, disabled: ui.busy }, [ icon('left'), t('back') ]),
					h('button', { type: 'submit', class: 'mws-btn is-primary', disabled: ui.busy, 'aria-busy': ui.busy ? 'true' : null },
						ui.busy ? [ h('span', { class: 'mws-spin', 'aria-hidden': 'true' }), t('v_applying') ]
							: last ? [ t('v_apply'), icon('check') ] : [ ui.fromReview ? t('back_review') : t('next'), icon('right') ])
				])
			])
		])
	]);
}

function applyRows() {
	const s = ui.job?.setup, ag = ui.job?.adguard;
	const order = { network: 1, address: 2, restore: 2, adguard: 3, done: 4 };
	const cur = s ? (order[s.step] ?? 1) : 1;
	const rows = [ { label: t('a_save'), n: 0 }, { label: t('a_net'), n: 1 } ];
	if (cfg.mode == 'ap') rows.push({ label: t('a_addr'), n: 2 });
	if (ui.job?.setup?.adguard ?? (cfg.mode == 'router' && cfg.protection.where == 'router')) {
		const sub = (cur == 3 && ag?.state == 'running' && ag.step) ? t('ag_' + ag.step) : null;
		rows.push({ label: t('a_ag'), n: 3, sub: sub && sub != 'ag_' + ag.step ? sub : null, warn: ag?.state == 'failed' });
	}
	return h('ol', { class: 'mws-run' }, rows.map(r => {
		const state = r.warn ? 'warn' : r.n < cur ? 'done' : r.n == cur ? 'run' : 'wait';
		return h('li', { class: 'is-' + state }, [
			h('span', { class: 'mws-run-mark', 'aria-hidden': 'true' }, state == 'done' ? icon('check') : state == 'warn' ? icon('alert') : state == 'run' ? h('span', { class: 'mws-spin' }) : null),
			h('span', {}, [ r.label, r.sub ? h('small', {}, ' · ' + r.sub) : null ]),
			h('span', { class: 'mws-sr' }, state == 'done' ? ' (' + t('done_sr') + ')' : '')
		]);
	}));
}

function joinCard(title, text) {
	const f = cfg.wifi;
	return h('section', { class: 'mws-panel mws-join' }, [
		qr(wifiQrText(f.ssid, f.key), title + ': ' + f.ssid),
		h('div', {}, [
			h('h2', {}, title),
			text ? h('p', {}, text) : null,
			h('dl', { class: 'mws-kv' }, [ h('dt', {}, t('f_name')), h('dd', {}, f.ssid), h('dt', {}, t('f_pass')), h('dd', { class: 'mws-mono' }, f.key) ])
		])
	]);
}

function applyScreen() {
	const silent = Date.now() - ui.contact;
	const ap = cfg.mode == 'ap';
	let help = null;
	if (ap && silent > 20000)
		help = note('info', cfg.ap.proto == 'static'
			? [ t('a_lost_ap_static', cfg.ap.ipaddr), ' ', h('a', { href: 'http://' + cfg.ap.ipaddr + '/' }, t('a_open', cfg.ap.ipaddr)) ]
			: t('a_lost_ap', ui.result?.hostname || st.hostname || 'MiWRT'));
	else if (silent > 120000)
		help = note('warn', [ h('strong', {}, t('a_lost')), ' ', t('a_lost_router', cfg.wifi.ssid, ui.result?.address || routerAddr()) ]);
	else if (silent > 8000)
		help = h('p', { class: 'mws-wait' }, t('a_wait'));
	return h('div', { class: 'mws-shell is-single' }, h('main', { class: 'mws-main' }, h('div', { class: 'mws-card' + (ui.enter ? ' is-enter' : '') }, [
		h('h1', { id: 'mws-title', tabindex: '-1' }, t('a_title')),
		h('p', { class: 'mws-lede' }, t('a_lede')),
		h('div', { 'aria-live': 'polite' }, [ applyRows(), help ]),
		joinCard(t('a_join'), t('a_join_d', cfg.wifi.ssid))
	])));
}

function failedScreen() {
	const s = ui.job?.setup || {};
	const text = s.step == 'address' ? t('a_fail_addr') : (s.error || '');
	return h('div', { class: 'mws-shell is-single' }, h('main', { class: 'mws-main' }, h('div', { class: 'mws-card' + (ui.enter ? ' is-enter' : '') }, [
		h('h1', { id: 'mws-title', tabindex: '-1' }, t('a_failed')),
		note('warn', text),
		h('div', { class: 'mws-actions' }, [
			h('span'),
			h('button', { type: 'button', class: 'mws-btn is-primary', onclick: () => { cfg.password = cfg.password2 = ''; go('mode'); } }, [ t('a_retry'), icon('right') ])
		])
	])));
}

function doneScreen() {
	const ag = ui.job?.adguard;
	const addr = ui.result?.address;
	const signin = addr ? t('d_signin_d', addr) : t('d_signin_ap', ui.result?.hostname || st.hostname || 'MiWRT');
	const agNote = !ui.job?.setup?.adguard ? null
		: ag?.state == 'done' ? note('ok', t('d_ag_ok', addr || routerAddr()))
		: note('warn', t('d_ag_fail', t(ag?.step == 'internet' ? 'agf_internet' : ag?.step == 'download' ? 'agf_download' : 'agf_other')));
	return h('div', { class: 'mws-shell is-single' }, h('main', { class: 'mws-main' }, h('div', { class: 'mws-card is-done' + (ui.enter ? ' is-enter' : '') }, [
		h('div', { class: 'mws-done-mark', 'aria-hidden': 'true' }, icon('check')),
		h('h1', { id: 'mws-title', tabindex: '-1' }, t('d_title')),
		h('p', { class: 'mws-lede' }, t('d_lede')),
		agNote,
		h('section', { class: 'mws-panel mws-app' }, [
			h('div', { class: 'mws-app-qr' }, [ qr(APP_URL, t('d_app')), h('p', {}, t('d_app_scan')) ]),
			h('div', {}, [
				art('app', 'mws-app-art'),
				h('h2', {}, t('d_app')),
				h('p', {}, t('d_app_d')),
				h('a', { class: 'mws-btn is-quiet', href: APP_URL, target: '_blank', rel: 'noopener noreferrer' }, t('d_app_btn'))
			])
		]),
		joinCard(t('d_wifi'), ''),
		h('section', { class: 'mws-panel' }, [
			h('h2', {}, t('d_signin')),
			h('p', {}, signin),
			h('h2', { class: 'mws-sub' }, t('d_more')),
			h('ul', { class: 'mws-list' }, [ h('li', {}, t('d_more_upd')), h('li', {}, t('d_more_pkgs')) ])
		]),
		h('div', { class: 'mws-actions is-end' }, [
			h('span'),
			h('a', { class: 'mws-btn is-primary', href: L.url('admin/status/overview') }, [ t('d_open'), icon('right') ])
		])
	])));
}

/* ------------------------------------------------------------------ */
/* Render                                                             */
/* ------------------------------------------------------------------ */

function render(focusId) {
	lang = uiLang();
	const root = ui.root;
	const active = focusId || document.activeElement?.id;
	const sel = (document.activeElement && 'selectionStart' in document.activeElement && document.activeElement.type != 'radio' && document.activeElement.type != 'checkbox')
		? [ document.activeElement.selectionStart, document.activeElement.selectionEnd ] : null;
	const scroll = root.scrollTop;
	root.setAttribute('lang', LANG_TAGS[lang]);
	root.setAttribute('data-screen', ui.screen);
	const body = ui.screen == 'welcome' ? welcome() : ui.screen == 'apply' ? applyScreen() : ui.screen == 'done' ? doneScreen()
		: ui.screen == 'failed' ? failedScreen() : stepScreen();
	root.replaceChildren(topbar(), body);
	ui.enter = false;
	if (ui.focusTitle) {
		ui.focusTitle = false;
		root.scrollTop = 0;
		document.getElementById('mws-title')?.focus({ preventScroll: true });
	}
	else {
		root.scrollTop = scroll;
		const el = active && document.getElementById(active);
		if (el) {
			el.focus({ preventScroll: true });
			if (sel && el.setSelectionRange) {
				try { el.setSelectionRange(sel[0], sel[1]); }
				catch (e) {}
			}
		}
	}
}

return view.extend({
	load() {
		const css = new Promise(resolve => {
			const link = document.createElement('link');
			link.rel = 'stylesheet';
			link.href = L.resource('miwrt-setup/wizard.css');
			link.onload = link.onerror = () => resolve();
			document.head.appendChild(link);
		});
		return Promise.all([ callStatus(), css ]);
	},

	render([ status ]) {
		st = (status && typeof status == 'object') ? status : {};
		st.wan = st.wan || {};
		st.wifi = st.wifi || {};
		cfg = defaults();
		if (st.state == 'pending') restore();
		else forget();
		lang = uiLang();
		for (const a of new Set(Object.values(ART))) new Image().src = L.resource('miwrt-setup/' + a + '.webp');
		document.documentElement.classList.add('mws-lock');
		ui.root = h('div', { class: 'mws', id: 'mws' });
		ui.focusTitle = true;
		render();
		return ui.root;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
