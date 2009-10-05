/*
 *  Copyright (C) 2009
 *      Authors (alphabetical) :
 *              Baruch Even <baruch@ev-en.org>
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU Public License as published by
 *  the Free Software Foundation; version 2 of the license.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU Lesser Public License for more details.
 */
using GLib;
using Sqlite;

namespace openBmap {
	public static double DOUBLE_EQ_DIFF = 0.00001;

	public bool double_eq(double x, double y, double diff) {
		if (Math.fabs(x-y) <= diff)
			return true;
		else
			return false;
	}

	public bool double_neq(double x, double y, double diff) {
		return !double_eq(x, y, diff);
	}

	public class GSMLocation : Object {
		private dynamic DBus.Object gsm_monitor_bus;
		private dynamic DBus.Object gsm_network_bus;
		private string dbpath;
		private Sqlite.Database db;
		private Sqlite.Statement stmt;

		construct {
			Timeout.add_seconds(5, cb_timer);
			try {	
				var dbus = DBus.Bus.get(DBus.BusType.SYSTEM);
				this.gsm_network_bus = dbus.get_object("org.freesmartphone.ogsmd", "/org/freesmartphone/GSM/Device", "org.freesmartphone.GSM.Network");
				this.gsm_monitor_bus = dbus.get_object("org.freesmartphone.ogsmd", "/org/freesmartphone/GSM/Device", "org.freesmartphone.GSM.Monitor");

				this.gsm_network_bus.GetStatus(get_status_reply);
				this.gsm_network_bus.Status += cb_get_status;
			} catch (DBus.Error e) {
				debug("DBus error while getting interface: %s", e.message);
			} catch (GLib.Error e) {
				debug("GLib error while getting interface");
			}

		}

		public GSMLocation(string dbpath) {
			this.dbpath = dbpath;
		}

		public bool active { get; private set; default = false; }
		public bool fix { get; private set; default = false; }
		public int timestamp {get; private set; default = 0; }
		public double lat { get; private set; default = 0.0; }
		public double lon { get; private set; default = 0.0; }

		public bool is_active() { return active; }
		public bool has_fix() { return fix; }

		public bool start() { return true; }
		public bool stop() { return true; }

		public signal void fix_changed();
		public signal void position_changed();

		public void openDB() {
			int result = Database.open(dbpath, out this.db);
			if (result != Sqlite.OK) {
				debug("Error opening db file: %d", result);
			}
			if (this.db != null) {
				result = this.db.prepare_v2("SELECT lat, lon FROM cells WHERE mcc=? AND mnc=? AND lac=? AND cid=?", -1, out this.stmt);
				if (result != 0) {
					debug("Error preparing SQL statement: %s", this.db.errmsg());
				}
			}
		}

		public void closeDB() {
			this.stmt = null;
			this.db = null;
		}

		/* Private */
		private string? last_code;
		private string? last_lac;
		private string? last_cid;
		private int mcc;
		private int mnc;
		
		private bool get_cell_location(int mcc, int mnc, int lac, int cid, out double lat, out double lon) {
			lat = 0.0;
			lon = 0.0;
			if (this.stmt == null)
				return false;

			debug("mcc=%d mnc=%d lac=%d cid=%d", mcc, mnc, lac, cid);
			bool retval = false;

			this.stmt.bind_int(1, mcc);
			this.stmt.bind_int(2, mnc);
			this.stmt.bind_int(3, lac);
			this.stmt.bind_int(4, cid);

			int ret = this.stmt.step();
			if (ret == Sqlite.ROW) {
				// Got data
				lat = this.stmt.column_double(0);
				lon = this.stmt.column_double(1);
				retval = true;
				debug("got data lat=%f lon=%f", lat, lon);
			} else if (ret == Sqlite.DONE) {
				// No data
				debug("no data");
			} else {
				// Error
				debug("Error executing SQL: %s", this.db.errmsg());
			}

			this.stmt.reset();

			return retval;
		}

		private bool cb_timer() {
			gsm_monitor_bus.GetServingCellInformation(get_serving_cell_reply);
			//gsm_monitor_bus.GetNeighbourCells(get_neighbour_cell_reply);
			return true;
		}

		private void process_cell_info(bool serving, HashTable<string, GLib.Value?> info) {
			GLib.Value? lac = info.lookup("lac");
			GLib.Value? cid = info.lookup("cid");
			if (lac == null || cid == null) {
				debug("lac or cid are missing");
				return;
			}

			string lac_str = lac.get_string();
			int lac_int = (int)lac_str.to_ulong(null, 16);

			string cid_str = cid.get_string();
			int cid_int = (int)cid_str.to_ulong(null, 16);

			if (lac_int == 0 || cid_int == 0) {
				debug("lac or cid of 0");
				return;
			}

			double lat;
			double lon;
			bool found = get_cell_location(this.mcc, this.mnc, lac_int, cid_int, out lat, out lon);
			if (!found) {
				if (this.fix) {
					this.fix = false;
					fix_changed();
				}
			} else {
				if (!this.fix) {
					this.fix = true;
					fix_changed();
				}
			}
			if (double_neq(this.lat, lat, DOUBLE_EQ_DIFF) || double_neq(this.lon, lon, DOUBLE_EQ_DIFF)) {
				this.lat = lat;
				this.lon = lon;
				this.position_changed();
			}
		}

		private void get_serving_cell_reply(HashTable<string, GLib.Value?> info, GLib.Error? e) {
			if (e == null)
				process_cell_info(true, info);
			else
				debug("get serving cell error %d text %s", e.code, e.message);
		}

		private void get_neighbour_cell_reply(HashTable<string, GLib.Value?>[] wrongdata, int len, GLib.Error? e) {
			if (e == null) {
				for (int i = 0; i < len; i++) {
					process_cell_info(false, wrongdata[i]);
				}
			} else
				debug("get neighbour cell error %d text %s", e.code, e.message);
		}

		private void cb_get_status(HashTable<string, GLib.Value?> info) {
			string tmp = info.lookup("registration").get_string();
			this.active = (tmp == "home" || tmp == "roaming");
			if (!this.active) {
				this.fix = false;
				this.last_code = null;
				this.last_lac = null;
				this.last_cid = null;
				fix_changed();
				return; // No reason to go any further
			}

			string code = info.lookup("code").get_string();
			string lac = info.lookup("lac").get_string();
			string cid = info.lookup("cid").get_string();
			debug("GSM status changed: code(mcc/mnc)=%s lac=%s cid=%s", code, lac, cid);
			if (cid != last_cid || lac != last_lac || code != last_code) {
				this.mcc = code.substring(0, 3).to_int();
				this.mnc = code.substring(3).to_int();
				debug("MCC=%d MNC=%d", this.mcc, this.mnc);

				// Refresh location
				cb_timer();
				last_code = code;
				last_lac = lac;
				last_cid = cid;
			}
		}

		private void get_status_reply(HashTable<string, GLib.Value?> info, GLib.Error? e) {
			if (e != null) {
				debug("error in reply, code=%d msg=%s", e.code, e.message);
				return;
			}

			cb_get_status(info);
		}
	}
}
