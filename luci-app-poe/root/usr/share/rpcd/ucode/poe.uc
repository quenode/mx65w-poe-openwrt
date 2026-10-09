#!/usr/bin/env ucode
'use strict';

import { readfile, writefile, stat } from 'fs';

const POE_ROOT = '/sys/class/poe';

/*
 * Port index -> LAN port name.
 *
 * The device tree sets port_base = 0 and the PSE enumerates its ports in
 * switch order, so port0 is lan11 and port1 is lan12. This is kept as
 * plain data rather than derived at runtime because the driver exposes no
 * name attribute; a future variant with more ports only needs this edit.
 */
const PORT_NAMES = [ 'lan11', 'lan12' ];

/* BCM59111 class field, indexed by the raw class value. */
const CLASS_NAMES = [
	'unknown', 'Class 1', 'Class 2', 'Class 3',
	'Class 4', 'reserved', 'Class 0', 'overcurrent'
];

/* Upper bound on port index, purely a guard against a bogus request. */
const MAX_PORTS = 16;

function rd(path) {
	let v = readfile(path);

	if (v == null)
		return null;

	v = trim(v);

	return v === '' ? null : v;
}

function rd_int(path) {
	let v = rd(path);

	if (v == null)
		return null;

	let n = +v;

	/* reject NaN */
	return n == n ? n : null;
}

function port_dir(idx) {
	return sprintf('%s/port%d', POE_ROOT, idx);
}

function read_port(idx) {
	let dir = port_dir(idx);

	if (!stat(dir))
		return null;

	let class_raw = rd(dir + '/class');
	let cls = rd_int(dir + '/class');
	let mode = rd(dir + '/mode');
	let power = rd_int(dir + '/power');

	/*
	 * `millijoules` is deliberately NOT exposed.
	 *
	 * The driver computes it as power_mw * jiffies_since_last_read and
	 * resets last_joule_time on every read. That makes it neither
	 * millijoules (no jiffies-to-seconds scaling) nor a cumulative total,
	 * just an interval delta whose value depends entirely on how often the
	 * attribute happens to be read. Surfacing it in a UI would report a
	 * different, meaningless figure on every poll.
	 */
	let p = {
		index: idx,
		name: (idx < length(PORT_NAMES)) ? PORT_NAMES[idx] : sprintf('port%d', idx),
		enabled: rd_int(dir + '/enabled'),
		class_raw: class_raw,
		class: cls,
		mode: mode,
		power_mw: power,
		overload: rd_int(dir + '/overload'),
		underload: rd_int(dir + '/underload'),
		denied: rd_int(dir + '/denied'),
	};

	/*
	 * Attachment state.
	 *
	 * The driver's `status` attribute cannot be used for this. It is
	 * defined with the same register, mask and bit offset as `enabled`
	 * (POE_STATPWR_REG / POE_SINGLE_BIT / POE_STATPWR_PORT_EN_OFF), so it
	 * only echoes the enable bit and never reports detection. The detect
	 * state in POE_STATP is reached only through the overload/underload
	 * match attributes, so presence is derived from the mode field - which
	 * the driver derives from the hardware class - with measured power as
	 * a fallback.
	 */
	p.attached = (mode != null && mode != 'UNK') || (power != null && power > 0);

	/* friendly class label, e.g. "4" -> "Class 4" */
	if (cls != null && cls >= 0 && cls < length(CLASS_NAMES))
		p.class_label = CLASS_NAMES[cls];
	else
		p.class_label = class_raw != null ? class_raw : 'unknown';

	return p;
}

function collect_ports() {
	let ports = [];
	let i = 0;

	/*
	 * Probe indices rather than parsing directory entries: keeps the
	 * ordering deterministic without depending on readdir sort order.
	 */
	while (i < MAX_PORTS && stat(port_dir(i))) {
		push(ports, read_port(i));
		i++;
	}

	return ports;
}

function rpc_status() {
	let dev = POE_ROOT + '/poe0';

	if (!stat(dev)) {
		return {
			present: false,
			budget_mw: null,
			faults: {},
			healthy: false,
			ports: [],
			total_power_mw: null,
		};
	}

	let faults = {
		failed_fet:  rd_int(dev + '/failed_fet'),
		failed_temp: rd_int(dev + '/failed_temp'),
		uvlo_main:   rd_int(dev + '/uvlo_main'),
		uvlo_vcc:    rd_int(dev + '/uvlo_vcc'),
	};

	let ports = collect_ports();
	let total = 0;

	for (let i = 0; i < length(ports); i++) {
		if (ports[i].power_mw != null)
			total += ports[i].power_mw;
	}

	return {
		present: true,
		budget_mw: rd_int(dev + '/power_budget'),
		faults: faults,
		healthy: faults.failed_fet == 0 && faults.failed_temp == 0 &&
		         faults.uvlo_main == 0 && faults.uvlo_vcc == 0,
		ports: ports,
		total_power_mw: total,
	};
}

/*
 * Enable or disable power on one port.
 *
 * Writing 0 to `enabled` cuts power to whatever is attached, so the caller
 * is expected to have confirmed intent.
 *
 * The result reports the *actual* state read back after the write rather
 * than the requested value, and those legitimately differ. In automatic
 * mode the PSE only asserts the enable bit once a device is actually
 * detected, so enabling an empty port reports requested=1, actual=0.
 * Reporting the request would show the UI a switch that is on when no
 * power is being delivered.
 */
function rpc_set(args) {
	let port = args['port'];
	let enabled = args['enabled'];

	if (port == null)
		return { ok: false, error: 'missing port' };

	/* Coerce and bound-check; also rejects NaN and any injection attempt. */
	port = +port;

	if (!(port >= 0 && port < MAX_PORTS) || port != (port | 0))
		return { ok: false, error: 'port out of range' };

	if (enabled == null)
		return { ok: false, error: 'missing enabled' };

	let want = (enabled == 1 || enabled == true || enabled == '1') ? 1 : 0;

	if (want == 0 && !(enabled == 0 || enabled == false || enabled == '0'))
		return { ok: false, error: 'enabled must be 0 or 1' };

	if (!stat(port_dir(port)))
		return { ok: false, error: 'no such port' };

	let written = writefile(sprintf('%s/enabled', port_dir(port)), want + '\n');
	let st = rpc_status();
	let actual = null;

	for (let i = 0; i < length(st.ports); i++) {
		if (st.ports[i].index == port)
			actual = st.ports[i].enabled;
	}

	return {
		ok: written != null,
		written: written,
		port: port,
		requested: want,
		actual: actual,
		status: st,
	};
}

/*
 * rpcd hands `call` a request object; the actual parameters live under
 * request.args. The values in an `args` declaration are type descriptors,
 * so 0 means "integer".
 */
const methods = {
	status: { call: () => rpc_status() },
	set: { args: { port: 0, enabled: 0 }, call: (request) => rpc_set(request?.args || {}) },
};

return { poe: methods };