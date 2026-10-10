'use strict';
'require view';
'require rpc';
'require poll';
'require ui';
'require dom';

var callStatus = rpc.declare({
	object: 'poe',
	method: 'status',
	expect: { }
});

var callSet = rpc.declare({
	object: 'poe',
	method: 'set',
	params: [ 'port', 'enabled' ],
	expect: { }
});

function fmtPower(mw) {
	if (mw == null)
		return '-';

	return (mw / 1000).toFixed(2) + ' W';
}

function fmtEnergy(mj) {
	if (mj == null)
		return '-';

	var wh = mj / 3600000;

	if (wh >= 1000)
		return (wh / 1000).toFixed(2) + ' MWh';
	if (wh >= 1)
		return wh.toFixed(2) + ' kWh';

	return Math.round(mj) + ' mJ';
}

function fmtBool(v) {
	if (v == null)
		return '-';

	return v ? _('yes') : _('no');
}

function portFlags(p) {
	var f = [];

	if (p.denied)
		f.push(_('power denied'));
	if (p.overload)
		f.push(_('overload'));
	if (p.underload)
		f.push(_('underload'));

	return f.length ? f.join(', ') : '-';
}

function faultBadges(faults) {
	var out = [];
	var names = {
		failed_fet:  _('PSE FET failure'),
		failed_temp: _('over temperature'),
		uvlo_main:   _('main rail undervoltage'),
		uvlo_vcc:    _('VCC undervoltage')
	};

	for (var k in names) {
		if (faults[k])
			out.push(names[k]);
	}

	if (!out.length)
		return E('span', { 'class': 'label success' }, [ _('all clear') ]);

	return E('span', { 'class': 'label danger' }, [ out.join('; ') ]);
}

function renderSummary(st) {
	var rows = [
		E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left' }, [ _('Power budget') ]),
			E('td', { 'class': 'td left' }, [ fmtPower(st.budget_mw) ])
		]),
		E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left' }, [ _('Total draw') ]),
			E('td', { 'class': 'td left' }, [ fmtPower(st.total_power_mw) ])
		]),
		E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left' }, [ _('Faults') ]),
			E('td', { 'class': 'td left' }, [ faultBadges(st.faults || {}) ])
		])
	];

	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, _('Controller')),
		E('table', { 'class': 'table cbi-section-table' }, rows)
	]);
}

function renderPorts(st, onToggle) {
	var rows = [
		E('tr', { 'class': 'tr cbi-section-table-titles' }, [
			E('th', { 'class': 'th' }, [ _('Port') ]),
			E('th', { 'class': 'th' }, [ _('Power') ]),
			E('th', { 'class': 'th' }, [ _('Device') ]),
			E('th', { 'class': 'th' }, [ _('Class') ]),
			E('th', { 'class': 'th' }, [ _('Mode') ]),
			E('th', { 'class': 'th' }, [ _('Power draw') ]),
			E('th', { 'class': 'th' }, [ _('Energy') ]),
			E('th', { 'class': 'th' }, [ _('Flags') ])
		])
	];

	(st.ports || []).forEach(function(p) {
		/*
		 * The checkbox state is set as a DOM property rather than an
		 * attribute. Passing 'checked' as an attribute cannot express
		 * "off": E() would setAttribute('checked', null) for a false
		 * value, and any string - including "null" - checks the box.
		 */
		var sw = E('input', {
			'type': 'checkbox',
			'class': 'cbi-input-checkbox'
		});

		sw.checked = !!p.enabled;

		sw.addEventListener('change', function(ev) {
			var want = ev.target.checked;

			/*
			 * Cutting power drops whatever is attached, so always
			 * confirm before writing.
			 */
			var msg = want
				? _('Enable power on %s?').format(p.name)
				: _('Disable power on %s? Anything connected will lose power immediately.').format(p.name);

			var apply = function(value) {
				callSet(p.index, value ? 1 : 0).then(function(res) {
					if (res && res.ok === false)
						ui.addNotification(null, E('p', [
							E('span', { 'class': 'error' },
								[ _('Failed: ') + (res.error || _('unknown error')) ])
						]), 'error');

					onToggle();
				});
			};

			/*
			 * showModal(title, children, ...classes) - the children
			 * must be an array and any further arguments are CSS
			 * classes, not a callback. So the buttons are built here.
			 */
			ui.showModal(_('PoE port'), [
				E('p', [ msg ]),
				E('div', { 'class': 'left' }, [
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': function() {
							ui.hideModal();
							apply(want);
						}
					}, [ _('OK') ]),
					E('button', {
						'class': 'cbi-button cbi-button-neutral',
						'click': function() {
							/* re-render to snap back to real state */
							ui.hideModal();
							onToggle();
						}
					}, [ _('Cancel') ])
				])
			]);
		});

		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left' }, [ p.name ]),
			E('td', { 'class': 'td left' }, [ sw ]),
			E('td', { 'class': 'td left' }, [
				p.attached
					? E('span', { 'class': 'label success' },
						[ p.detected ? _('detected') : _('powered') ])
					: E('span', { 'class': 'label' },
						[ p.status_raw || _('none') ])
			]),
			E('td', { 'class': 'td left' }, [ p.class_label ]),
			E('td', { 'class': 'td left' }, [ p.mode || '-' ]),
			E('td', { 'class': 'td left' }, [ fmtPower(p.power_mw) ]),
			E('td', { 'class': 'td left' }, [ fmtEnergy(p.millijoules) ]),
			E('td', { 'class': 'td left' }, [ portFlags(p) ])
		]));
	});

	return E('div', { 'class': 'cbi-section' }, [
		E('h3', _('Ports')),
		E('table', { 'class': 'table cbi-section-table' }, rows)
	]);
}

return view.extend({
	load: function() {
		return callStatus();
	},

	render: function(data) {
		var self = this;

		if (!data || !data.present) {
			return E('div', { 'class': 'cbi-section' }, [
				E('h2', _('PoE')),
				E('p', { 'class': 'alert alert-warning' }, [
					_('No BCM59111 PSE detected. The poe0 device is missing from /sys/class/poe.')
				])
			]);
		}

		var summaryHost = E('div', {});
		var portHost   = E('div', {});

		var reload = function() {
			return callStatus().then(function(st) {
				dom.content(summaryHost, renderSummary(st));
				dom.content(portHost, renderPorts(st, reload));
			});
		};

		poll.add(reload, 5);

		return E('div', {}, [
			E('h2', _('PoE')),
			E('p', { 'class': 'cbi-map-descr' }, [
				_('Power over Ethernet ports driven by the Broadcom BCM59111 PSE controller.')
			]),
			E('p', { 'class': 'cbi-map-descr' }, [
				_('Ports operate in automatic mode, so a port only reports powered once a device is detected. Enabling an empty port will not latch.')
			]),
			summaryHost,
			portHost
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});