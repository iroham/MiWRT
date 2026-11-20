// One pass of the MiWRT app service. miwrt-hubd runs it every 30 seconds, from
// the copy it compiled in /tmp/miwrt when that is current, else from here.
import * as hub from 'miwrt.hub';
import * as extras from 'miwrt.extras';
import * as power from 'miwrt.power';
import * as tunnel from 'miwrt.tunnel';

hub.tick();
extras.guest_expire();
extras.wifi_schedule_tick();
extras.iot_watch_tick();
extras.services_tick();
power.energy_tick();
try { tunnel.tick(); } catch (e) { warn(`tunnel: ${e}\n`); }
