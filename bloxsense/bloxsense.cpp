/* bloxsense: CPU topology, temperature and RAPL package power for BloxMiner-X's h-stats.sh.
 *
 * blox.h and blox_sys.cpp in this directory are copied byte-identical from BloxMiner 2.1.0
 * (bokiko/bloxminer, a reviewed ccminer derivative, GPL-3.0): bloxminer-work/ccminer-patched/{blox.h,blox_sys.cpp}.
 * Nothing in those two files was changed. This file is new: a small CLI around their existing, already-tested
 * topology/temperature/RAPL API. There is no hashing code here and no XMRig code.
 *
 * `bloxsense --json` prints one line of JSON:
 *   {"cpus":[{"cpu":N,"pkg":P,"core":C,"temp":T|null,"src":"core|ccd|pkg|none"}, ...],
 *    "pkg_temp":T|null, "power_w":W|null, "ccd_reason":"..."}
 *
 * Power is a bounded two-read RAPL sample: blox_rapl_watts() is called once to record a baseline energy
 * counter, the process sleeps ~0.55 s (CLOCK_MONOTONIC via blox_rapl_watts' own "now" argument), then
 * blox_rapl_watts() is called again; it does the Delta-energy/Delta-time math itself, including counter-wrap
 * handling (via max_energy_range_uj) and the plausibility checks (0 < W <= BLOX_RAPL_MAX_W, sample interval
 * below the range-derived maximum, AND above blox_rapl_watts()'s own hard floor of dt <= 0.5 s being rejected
 * outright - the 0.55 s sleep is deliberately a little over that floor, not exactly on it, since nanosleep
 * only guarantees "at least" the requested duration and this must clear that check with real margin, not by
 * luck). Any package that is missing or unreadable in either read makes the whole figure unavailable (never a
 * partial or a stale total): power_w is null in that case, exactly as blox_rapl_watts() already returns -1
 * when it is not confident in the number. blox_rapl_watts()/blox_sys.cpp are unchanged by this file.
 *
 * $BLOX_SYSFS_ROOT (a fake sysfs/procfs tree root, for tests) is honoured because blox_sysfs() in blox_sys.cpp
 * already reads it for every path this tool touches.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "blox.h"

static double mono_now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* Sleep ~0.55 s (550 ms), restarting across signal interruptions: comfortably above the 0.5 s floor
 * blox_rapl_watts() itself enforces (a sample with dt <= 0.5 s is rejected there), not sitting right on it. */
static void sleep_half_second(void)
{
	struct timespec req = { 0, 550000000L }, rem;
	while (nanosleep(&req, &rem) != 0) req = rem;
}

/* ccd_reason is built by blox_topo_init() from our own literals and %d/%s of small trusted fields, but this
 * tool's whole job is to hand out a stable JSON contract, so the string is escaped defensively regardless. */
static void put_json_string(const char *s)
{
	fputc('"', stdout);
	for (; *s; s++) {
		unsigned char c = (unsigned char) *s;
		switch (c) {
		case '"':  fputs("\\\"", stdout); break;
		case '\\': fputs("\\\\", stdout); break;
		case '\n': fputs("\\n", stdout); break;
		case '\t': fputs("\\t", stdout); break;
		default:
			if (c < 0x20) printf("\\u%04x", c);
			else fputc(c, stdout);
		}
	}
	fputc('"', stdout);
}

static const char *src_name(int src)
{
	switch (src) {
	case BLOX_T_CORE: return "core";
	case BLOX_T_CCD:  return "ccd";
	case BLOX_T_PKG:  return "pkg";
	default:          return "none";
	}
}

static void usage(const char *argv0)
{
	fprintf(stderr, "usage: %s --json\n", argv0);
}

int main(int argc, char **argv)
{
	bool json = false;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--json")) json = true;
		else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) { usage(argv[0]); return 0; }
	}
	if (!json) { usage(argv[0]); return 2; }

	struct blox_topo topo;
	blox_topo_init(&topo, -1);   /* -1 = auto: per-CCD temps only on a validated AMD profile, same as BloxMiner */

	struct blox_rapl rapl;
	blox_rapl_init(&rapl, &topo);
	double power_w = -1;
	if (rapl.usable) {
		blox_rapl_watts(&rapl, mono_now());   /* primes the counters; a rate needs a second read */
		sleep_half_second();
		power_w = blox_rapl_watts(&rapl, mono_now());
	}

	int pkg_temp = blox_pkg_temp(&topo);

	printf("{\"cpus\":[");
	bool first = true;
	for (int c = 0; c < topo.ncpu; c++) {
		if (!topo.cpu[c].present) continue;
		int src = BLOX_T_NONE;
		int temp = blox_cpu_temp(&topo, c, &src);
		if (!first) fputc(',', stdout);
		first = false;
		printf("{\"cpu\":%d,\"pkg\":%d,\"core\":%d,\"temp\":", c, topo.cpu[c].pkg, topo.cpu[c].core);
		if (temp >= 0) printf("%d", temp); else fputs("null", stdout);
		printf(",\"src\":\"%s\"}", src_name(src));
	}
	fputs("],\"pkg_temp\":", stdout);
	if (pkg_temp >= 0) printf("%d", pkg_temp); else fputs("null", stdout);
	fputs(",\"power_w\":", stdout);
	if (power_w >= 0) printf("%.1f", power_w); else fputs("null", stdout);
	fputs(",\"ccd_reason\":", stdout);
	put_json_string(topo.ccd_reason);
	fputs("}\n", stdout);
	return 0;
}
