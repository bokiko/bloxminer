/* Unit tests for bloxsense/blox_sys.cpp against fake sysfs trees ($BLOX_SYSFS_ROOT).
 * blox_sys.cpp and blox.h here are byte-identical to BloxMiner 2.1.0's reviewed originals (see bloxsense/bloxsense.cpp
 * header), so this file is adapted directly from bloxminer's tests/engine/test_sys.cpp: same fixtures, same checks.
 * Build: c++ -std=c++17 -Wall -I../../bloxsense test_sys.cpp ../../bloxsense/blox_sys.cpp -o test_sys */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <limits.h>
#include <string>

#include "blox.h"

static int fails = 0, checks = 0;
#define CHECK(cond, ...) do { checks++; if (!(cond)) { fails++; printf("  FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static std::string root;

static void mkdirs(const std::string &p)
{
	std::string cur;
	for (size_t i = 0; i < p.size(); i++) {
		cur += p[i];
		if (p[i] == '/' && cur.size() > 1) mkdir(cur.c_str(), 0755);
	}
	mkdir(p.c_str(), 0755);
}

static void put(const std::string &rel, const std::string &val)
{
	std::string p = root + rel;
	mkdirs(p.substr(0, p.rfind('/')));
	FILE *f = fopen(p.c_str(), "w");
	fprintf(f, "%s\n", val.c_str());
	fclose(f);
}

static void fresh(const char *name)
{
	char tmpl[] = "/tmp/bloxsysXXXXXX";
	root = mkdtemp(tmpl);
	setenv("BLOX_SYSFS_ROOT", root.c_str(), 1);
	printf("- %s\n", name);
}

static void cpuinfo(const char *vendor, int fam, int model, const char *name)
{
	char b[512];
	snprintf(b, sizeof(b), "processor\t: 0\nvendor_id\t: %s\ncpu family\t: %d\nmodel\t\t: %d\nmodel name\t: %s", vendor, fam, model, name);
	put("/proc/cpuinfo", b);
}

/* cpu c: package, core, L3 id (-1 = no L3 entry) */
static void cpu(int c, int pkg, int core, int l3)
{
	char b[160];
	snprintf(b, sizeof(b), "/sys/devices/system/cpu/cpu%d/topology/physical_package_id", c); put(b, std::to_string(pkg));
	snprintf(b, sizeof(b), "/sys/devices/system/cpu/cpu%d/topology/core_id", c); put(b, std::to_string(core));
	if (l3 >= 0) {
		snprintf(b, sizeof(b), "/sys/devices/system/cpu/cpu%d/cache/index3/level", c); put(b, "3");
		snprintf(b, sizeof(b), "/sys/devices/system/cpu/cpu%d/cache/index3/id", c); put(b, std::to_string(l3));
	}
}

/* hwmon N with name and labelled temps "label=millideg,..." */
static void hwmon(int n, const char *name, const char *const *labels, const int *mdeg, int cnt, const char *pci = NULL,
                  const char *local_cpulist = NULL)
{
	char b[160];
	snprintf(b, sizeof(b), "/sys/class/hwmon/hwmon%d/name", n); put(b, name);
	for (int i = 0; i < cnt; i++) {
		snprintf(b, sizeof(b), "/sys/class/hwmon/hwmon%d/temp%d_label", n, i + 1); put(b, labels[i]);
		snprintf(b, sizeof(b), "/sys/class/hwmon/hwmon%d/temp%d_input", n, i + 1); put(b, std::to_string(mdeg[i]));
	}
	if (pci) {
		char dev[PATH_MAX], lnk[PATH_MAX];
		snprintf(dev, sizeof(dev), "%s/sys/devices/pci0000:00/%s", root.c_str(), pci); mkdirs(dev);
		if (local_cpulist) { FILE *f = fopen((std::string(dev) + "/local_cpulist").c_str(), "w"); fprintf(f, "%s\n", local_cpulist); fclose(f); }
		snprintf(lnk, sizeof(lnk), "%s/sys/class/hwmon/hwmon%d/device", root.c_str(), n);
		if (symlink(dev, lnk) != 0) perror("symlink");
	}
}

static void rapl(int d, const char *name, long long e, long long range)
{
	char b[160];
	snprintf(b, sizeof(b), "/sys/class/powercap/intel-rapl:%d/name", d); put(b, name);
	snprintf(b, sizeof(b), "/sys/class/powercap/intel-rapl:%d/energy_uj", d); put(b, std::to_string(e));
	snprintf(b, sizeof(b), "/sys/class/powercap/intel-rapl:%d/max_energy_range_uj", d); put(b, std::to_string(range));
}

static struct blox_topo T;

static int temp_of(int c, int *src) { return blox_cpu_temp(&T, c, src); }

int main()
{
	int src;

	/* ---- Ryzen 9 5950X: 16C/32T, 2 CCD, L3 0/1, Tccd1/2 -> validated profile */
	fresh("5950X (Vermeer 2 CCD) auto");
	cpuinfo("AuthenticAMD", 25, 33, "AMD Ryzen 9 5950X 16-Core Processor");
	for (int c = 0; c < 32; c++) cpu(c, 0, c % 16, (c % 16) < 8 ? 0 : 1);
	{ const char *l[] = { "Tctl", "Tccd1", "Tccd2" }; int v[] = { 70000, 61000, 66000 }; hwmon(0, "k10temp", l, v, 3); }
	blox_topo_init(&T, -1);
	CHECK(T.threads == 32 && T.cores == 16 && T.npkg == 1, "topology %d/%d/%d", T.threads, T.cores, T.npkg);
	CHECK(T.ccd_mode == 1, "ccd mode off: %s", T.ccd_reason);
	CHECK(temp_of(3, &src) == 61 && src == BLOX_T_CCD, "cpu3 -> Tccd1");
	CHECK(temp_of(12, &src) == 66 && src == BLOX_T_CCD, "cpu12 (core 12, CCD2) -> Tccd2");
	CHECK(temp_of(28, &src) == 66, "cpu28 (core 12 SMT) -> Tccd2");
	CHECK(blox_pkg_temp(&T) == 70, "pkg temp Tctl");

	fresh("5950X ccd-temp-map=0");
	cpuinfo("AuthenticAMD", 25, 33, "AMD Ryzen 9 5950X 16-Core Processor");
	for (int c = 0; c < 32; c++) cpu(c, 0, c % 16, (c % 16) < 8 ? 0 : 1);
	{ const char *l[] = { "Tctl", "Tccd1", "Tccd2" }; int v[] = { 70000, 61000, 66000 }; hwmon(0, "k10temp", l, v, 3); }
	blox_topo_init(&T, 0);
	CHECK(T.ccd_mode == 0 && temp_of(12, &src) == 70 && src == BLOX_T_PKG, "off -> package temp");

	/* ---- Ryzen 7 5800X: 1 CCD */
	fresh("5800X (Vermeer 1 CCD) auto");
	cpuinfo("AuthenticAMD", 25, 33, "AMD Ryzen 7 5800X 8-Core Processor");
	for (int c = 0; c < 16; c++) cpu(c, 0, c % 8, 0);
	{ const char *l[] = { "Tctl", "Tccd1" }; int v[] = { 80000, 77000 }; hwmon(0, "k10temp", l, v, 2); }
	blox_topo_init(&T, -1);
	CHECK(T.ccd_mode == 1 && temp_of(5, &src) == 77 && src == BLOX_T_CCD, "5800X Tccd1: %s", T.ccd_reason);

	/* ---- Ryzen 9 3950X (Zen 2): 4 CCX (L3) on 2 CCD -> not validated: auto = package, forced = L3 pairs */
	fresh("3950X (Zen 2) auto and forced");
	cpuinfo("AuthenticAMD", 23, 113, "AMD Ryzen 9 3950X 16-Core Processor");
	for (int c = 0; c < 32; c++) cpu(c, 0, c % 16, (c % 16) / 4);
	{ const char *l[] = { "Tctl", "Tccd1", "Tccd2" }; int v[] = { 72000, 60000, 64000 }; hwmon(0, "k10temp", l, v, 3); }
	blox_topo_init(&T, -1);
	CHECK(T.ccd_mode == 0 && temp_of(9, &src) == 72 && src == BLOX_T_PKG, "zen2 auto must not map: %s", T.ccd_reason);
	CHECK(strstr(T.ccd_reason, "no validated profile") != NULL, "reason: %s", T.ccd_reason);
	blox_topo_init(&T, 1);
	CHECK(T.ccd_mode == 1, "forced on");
	CHECK(temp_of(0, &src) == 60 && temp_of(7, &src) == 60, "CCX 0,1 -> Tccd1");
	CHECK(temp_of(8, &src) == 64 && temp_of(15, &src) == 64, "CCX 2,3 -> Tccd2");

	/* ---- Tctl only (APU): nTccd == 0 -> package temp, no division by zero */
	fresh("Tctl only (nTccd = 0), forced");
	cpuinfo("AuthenticAMD", 25, 80, "AMD Ryzen 7 5700G with Radeon Graphics");
	for (int c = 0; c < 16; c++) cpu(c, 0, c % 8, 0);
	{ const char *l[] = { "Tctl" }; int v[] = { 55000 }; hwmon(0, "k10temp", l, v, 1); }
	blox_topo_init(&T, 1);
	CHECK(T.ccd_mode == 0 && temp_of(2, &src) == 55 && src == BLOX_T_PKG, "tctl only: %s", T.ccd_reason);

	/* ---- non-integral L3/Tccd ratio -> package temp even when forced */
	fresh("3 L3 / 2 Tccd, forced");
	cpuinfo("AuthenticAMD", 25, 33, "AMD test");
	for (int c = 0; c < 12; c++) cpu(c, 0, c, c / 4);
	{ const char *l[] = { "Tctl", "Tccd1", "Tccd2" }; int v[] = { 50000, 40000, 45000 }; hwmon(0, "k10temp", l, v, 3); }
	blox_topo_init(&T, 1);
	CHECK(T.ccd_mode == 0 && strstr(T.ccd_reason, "multiple") != NULL, "non-integral: %s", T.ccd_reason);

	/* ---- no L3 info in sysfs */
	fresh("no L3 topology");
	cpuinfo("AuthenticAMD", 25, 33, "AMD test");
	for (int c = 0; c < 8; c++) cpu(c, 0, c, -1);
	{ const char *l[] = { "Tctl", "Tccd1" }; int v[] = { 50000, 40000 }; hwmon(0, "k10temp", l, v, 2); }
	blox_topo_init(&T, 1);
	CHECK(T.ccd_mode == 0 && temp_of(1, &src) == 50, "no l3: %s", T.ccd_reason);

	/* ---- 2-socket EPYC: per-CCD off, package temp per socket via k10temp PCI node, power sums 2 packages */
	fresh("2-socket AMD");
	cpuinfo("AuthenticAMD", 25, 1, "AMD EPYC 7543 32-Core Processor");
	for (int c = 0; c < 8; c++) cpu(c, c < 4 ? 0 : 1, c % 4, c < 4 ? 0 : 8);
	{ const char *l[] = { "Tctl", "Tccd1" }; int v0[] = { 60000, 50000 }, v1[] = { 65000, 51000 };
	  /* sockets are found through each sensor's local_cpulist, listed here in the opposite order of the PCI numbers */
	  hwmon(0, "k10temp", l, v1, 2, "0000:00:19.3", "4-7"); hwmon(1, "k10temp", l, v0, 2, "0000:00:18.3", "0-3"); }
	rapl(0, "package-0", 1000000, 262143328850LL); rapl(1, "package-1", 2000000, 262143328850LL);
	blox_topo_init(&T, -1);
	CHECK(T.npkg == 2 && T.ccd_mode == 0 && strstr(T.ccd_reason, "multi-socket"), "2s: %s", T.ccd_reason);
	CHECK(temp_of(1, &src) == 60 && temp_of(6, &src) == 65 && src == BLOX_T_PKG, "per-socket package temps");
	{
		struct blox_rapl r; blox_rapl_init(&r, &T);
		CHECK(r.usable && r.n == 2, "rapl 2 packages: %s", r.reason);
		CHECK(blox_rapl_watts(&r, 100.0) < 0, "first sample has no rate");
		rapl(0, "package-0", 1000000 + 100000000LL, 262143328850LL);  /* +100 J in 2 s = 50 W */
		rapl(1, "package-1", 2000000 + 200000000LL, 262143328850LL);  /* +200 J = 100 W */
		double w = blox_rapl_watts(&r, 102.0);
		CHECK(w > 149.9 && w < 150.1, "sum of packages = 150 W, got %.1f", w);
	}

	/* ---- 2 sockets, sensors without locality information -> no guessed socket temperature */
	fresh("2-socket AMD, no local_cpulist");
	cpuinfo("AuthenticAMD", 25, 1, "AMD EPYC");
	for (int c = 0; c < 4; c++) cpu(c, c < 2 ? 0 : 1, c % 2, c < 2 ? 0 : 8);
	{ const char *l[] = { "Tctl" }; int v0[] = { 60000 }, v1[] = { 65000 };
	  hwmon(0, "k10temp", l, v0, 1, "0000:00:18.3"); hwmon(1, "k10temp", l, v1, 1, "0000:00:19.3"); }
	blox_topo_init(&T, -1);
	CHECK(temp_of(0, &src) == -1 && temp_of(3, &src) == -1 && blox_pkg_temp(&T) == -1, "unassociated sensors are not used");

	/* ---- locality lists: a range list on one socket works, a list spanning both sockets is ambiguous */
	fresh("2-socket AMD, ranged and spanning local_cpulist");
	cpuinfo("AuthenticAMD", 25, 1, "AMD EPYC");
	for (int c = 0; c < 8; c++) cpu(c, c < 4 ? 0 : 1, c % 4, c < 4 ? 0 : 8);
	{ const char *l[] = { "Tctl" }; int v0[] = { 60000 }, v1[] = { 65000 };
	  hwmon(0, "k10temp", l, v0, 1, "0000:00:18.3", "0-1,2-3"); hwmon(1, "k10temp", l, v1, 1, "0000:00:19.3", "3-5"); }
	blox_topo_init(&T, -1);
	CHECK(temp_of(1, &src) == 60 && src == BLOX_T_PKG, "ranged list on socket 0");
	CHECK(temp_of(6, &src) == -1, "list spanning both sockets is not used");

	/* ---- one package domain missing on a 2-socket box -> no partial "total" */
	fresh("2-socket, one RAPL domain");
	cpuinfo("AuthenticAMD", 25, 1, "AMD EPYC");
	for (int c = 0; c < 4; c++) cpu(c, c < 2 ? 0 : 1, c % 2, c < 2 ? 0 : 8);
	rapl(0, "package-0", 1000, 262143328850LL);
	blox_topo_init(&T, -1);
	{ struct blox_rapl r; blox_rapl_init(&r, &T); CHECK(!r.usable && strstr(r.reason, "no RAPL package domain"), "partial: %s", r.reason); }

	/* ---- Intel i9-10900K: coretemp per core, SMT off, psys domain must not be counted */
	fresh("Intel 10900K, SMT off, psys");
	cpuinfo("GenuineIntel", 6, 165, "Intel(R) Core(TM) i9-10900K CPU @ 3.70GHz");
	for (int c = 0; c < 10; c++) cpu(c, 0, c, 0);
	{ const char *l[] = { "Package id 0", "Core 0", "Core 1", "Core 2", "Core 3", "Core 4", "Core 5", "Core 6", "Core 7", "Core 8", "Core 9" };
	  int v[] = { 70000, 60000, 61000, 62000, 63000, 64000, 65000, 66000, 67000, 68000, 69000 }; hwmon(2, "coretemp", l, v, 11); }
	rapl(0, "package-0", 5000000, 262143328850LL); rapl(1, "psys", 9000000, 262143328850LL);
	blox_topo_init(&T, -1);
	CHECK(T.threads == 10 && T.cores == 10, "smt off topo");
	CHECK(temp_of(4, &src) == 64 && src == BLOX_T_CORE, "core 4 temp");
	CHECK(blox_pkg_temp(&T) == 70, "intel package");
	{
		struct blox_rapl r; blox_rapl_init(&r, &T);
		CHECK(r.usable && r.n == 1, "psys ignored: n=%d %s", r.n, r.reason);
		blox_rapl_watts(&r, 10.0);
		rapl(0, "package-0", 5000000 + 250000000LL, 262143328850LL);  /* 250 J / 2 s = 125 W */
		rapl(1, "psys", 9000000 + 600000000LL, 262143328850LL);
		double w = blox_rapl_watts(&r, 12.0);
		CHECK(w > 124.9 && w < 125.1, "package only = 125 W, got %.1f", w);
	}

	/* ---- RAPL counter wrap, too-long gap, non-root */
	fresh("RAPL wrap / gap / unreadable");
	cpuinfo("AuthenticAMD", 25, 33, "AMD Ryzen 9 5900X 12-Core Processor");
	for (int c = 0; c < 4; c++) cpu(c, 0, c, 0);
	rapl(0, "package-0", 65532610987LL - 100000000LL, 65532610987LL);
	blox_topo_init(&T, -1);
	{
		struct blox_rapl r; blox_rapl_init(&r, &T);
		blox_rapl_watts(&r, 50.0);
		rapl(0, "package-0", 78000000LL, 65532610987LL);                /* wrapped: +100 J + 78 J = 178 J / 2 s */
		double w = blox_rapl_watts(&r, 52.0);
		CHECK(w > 88.9 && w < 89.1, "wrap handled: 89 W, got %.1f", w);
		rapl(0, "package-0", 90000000LL, 65532610987LL);
		CHECK(blox_rapl_watts(&r, 152.0) < 0, "gap longer than the wrap time is rejected");
		rapl(0, "package-0", 90000000LL + 4000200000LL, 65532610987LL);  /* 4000.2 J in 2 s = 2000.1 W */
		CHECK(blox_rapl_watts(&r, 154.0) < 0, "above the power bound is rejected");
		rapl(0, "package-0", 65532610988LL, 65532610987LL);             /* counter beyond its range */
		CHECK(blox_rapl_watts(&r, 156.0) < 0, "counter beyond max_energy_range_uj is rejected");
		rapl(0, "package-0", 100000000LL, 65532610987LL);
		blox_rapl_watts(&r, 158.0);
		rapl(0, "package-0", 100000000LL + 3999800000LL, 65532610987LL);  /* 1999.9 W */
		double wb = blox_rapl_watts(&r, 160.0);
		CHECK(wb > 1999.8 && wb < 2000.0, "just below the bound is accepted, got %.1f", wb);
		chmod((root + "/sys/class/powercap/intel-rapl:0/energy_uj").c_str(), 0);
		if (geteuid() != 0) {
			struct blox_rapl r2; blox_rapl_init(&r2, &T);
			CHECK(!r2.usable && strstr(r2.reason, "root"), "unreadable: %s", r2.reason);
		}
	}

	/* ---- no sensors at all */
	fresh("no hwmon at all");
	cpuinfo("GenuineIntel", 6, 1, "Some CPU");
	for (int c = 0; c < 2; c++) cpu(c, 0, c, -1);
	blox_topo_init(&T, -1);
	CHECK(temp_of(0, &src) == -1 && src == BLOX_T_NONE && blox_pkg_temp(&T) == -1, "no sensor -> -1");
	{ struct blox_rapl r; blox_rapl_init(&r, &T); CHECK(!r.usable, "no rapl"); }

	printf("%d checks, %d failed\n", checks, fails);
	return fails ? 1 : 0;
}
