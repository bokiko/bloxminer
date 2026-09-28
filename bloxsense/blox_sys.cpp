/* BloxMiner: CPU topology, temperature sources and RAPL package power from sysfs.
 * Everything is read-only sysfs/procfs; $BLOX_SYSFS_ROOT prefixes every path (unit tests use fake trees). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <unistd.h>
#include <time.h>

#include "blox.h"

const char *blox_sysfs(const char *path, char *out, size_t outsz)
{
	const char *root = getenv("BLOX_SYSFS_ROOT");
	snprintf(out, outsz, "%s%s", root ? root : "", path);
	return out;
}

static bool read_str(const char *abs, char *buf, size_t sz)
{
	FILE *f = fopen(abs, "r");
	if (!f) return false;
	bool ok = fgets(buf, (int) sz, f) != NULL;
	fclose(f);
	if (!ok) return false;
	buf[strcspn(buf, "\r\n")] = '\0';
	return true;
}

static bool read_ll(const char *abs, long long *v)
{
	char b[64], *end;
	if (!read_str(abs, b, sizeof(b))) return false;
	*v = strtoll(b, &end, 10);
	return end != b;
}

static bool sys_ll(const char *rel, long long *v)
{
	char p[PATH_MAX];
	return read_ll(blox_sysfs(rel, p, sizeof(p)), v);
}

int blox_read_temp(const char *path)
{
	long long v;
	if (!path || !*path || !read_ll(path, &v)) return -1;
	if (v < -40000 || v > 150000) return -1;          /* millidegrees; implausible => unavailable */
	return (int) ((v + (v >= 0 ? 500 : -500)) / 1000);
}

static int pkg_index(const struct blox_topo *t, int pkg)
{
	for (int i = 0; i < t->npkg; i++) if (t->pkg_id[i] == pkg) return i;
	return -1;
}

/* Validated per-CCD temperature profiles: (family, model, #L3, #Tccd). Each entry was confirmed with a
 * controlled load pinned to one CCD at a time (only that CCD's Tccd rose). Add entries only that way. */
static const struct { int family, model, nl3, ntccd; const char *what; } ccd_profiles[] = {
	{ 25, 33, 1, 1, "Ryzen 5000 (Vermeer), 1 CCD" },
	{ 25, 33, 2, 2, "Ryzen 5000 (Vermeer), 2 CCD" },   /* 5950X load test 2026-09-26 */
};

static void cpuinfo(struct blox_topo *t)
{
	char p[PATH_MAX], line[256];
	FILE *f = fopen(blox_sysfs("/proc/cpuinfo", p, sizeof(p)), "r");
	t->family = t->model = -1;
	if (!f) return;
	while (fgets(line, sizeof(line), f)) {
		char *v = strchr(line, ':');
		if (!v) continue;
		v++; while (*v == ' ' || *v == '\t') v++;
		v[strcspn(v, "\r\n")] = '\0';
		if (!strncmp(line, "vendor_id", 9) && !t->vendor[0]) snprintf(t->vendor, sizeof(t->vendor), "%s", v);
		else if (!strncmp(line, "cpu family", 10) && t->family < 0) t->family = atoi(v);
		else if (!strncmp(line, "model name", 10) && !t->model_name[0]) snprintf(t->model_name, sizeof(t->model_name), "%s", v);
		else if (!strncmp(line, "model", 5) && (line[5] == '\t' || line[5] == ' ' || line[5] == ':') && t->model < 0) t->model = atoi(v);
	}
	fclose(f);
}

/* L3 cache id of a cpu: the cache index whose level is 3 */
static int l3_id(int cpu)
{
	char rel[128]; long long lvl, id;
	for (int i = 0; i < 10; i++) {
		snprintf(rel, sizeof(rel), "/sys/devices/system/cpu/cpu%d/cache/index%d/level", cpu, i);
		if (!sys_ll(rel, &lvl)) continue;
		if (lvl != 3) continue;
		snprintf(rel, sizeof(rel), "/sys/devices/system/cpu/cpu%d/cache/index%d/id", cpu, i);
		if (sys_ll(rel, &id)) return (int) id;
	}
	return -1;
}

/* Package of an AMD k10temp sensor: every CPU in its PCI device's local_cpulist ("0-3,8-11") must belong to
 * one and the same package. -1 when that cannot be established: the temperature is then unavailable. */
static int k10temp_pkg(const char *hwmon)
{
	char p[PATH_MAX], list[1024], rel[128];
	snprintf(p, sizeof(p), "%s/device/local_cpulist", hwmon);
	if (!read_str(p, list, sizeof(list))) return -1;
	int pkg = -1, n = 0;
	for (char *tok = list; *tok; ) {
		char *end; long a = strtol(tok, &end, 10), b = a;
		if (end == tok || a < 0) return -1;
		if (*end == '-') { tok = end + 1; b = strtol(tok, &end, 10); if (end == tok || b < a) return -1; }
		if (b >= BLOX_MAX_CPUS) return -1;
		for (long c = a; c <= b; c++) {
			long long pk;
			snprintf(rel, sizeof(rel), "/sys/devices/system/cpu/cpu%ld/topology/physical_package_id", c);
			if (!sys_ll(rel, &pk)) continue;                       /* offline CPU */
			if (pkg >= 0 && pk != pkg) return -1;                 /* spans packages: ambiguous */
			pkg = (int) pk; n++;
		}
		if (*end == ',') tok = end + 1;
		else if (*end == '\0') break;
		else return -1;
	}
	return n ? pkg : -1;
}

static bool find_label(const char *hwmon, const char *want, char *input, size_t sz)
{
	char p[PATH_MAX], lab[64];
	for (int i = 1; i < 64; i++) {
		snprintf(p, sizeof(p), "%s/temp%d_label", hwmon, i);
		if (!read_str(p, lab, sizeof(lab))) continue;
		if (!strcmp(lab, want)) { snprintf(input, sz, "%s/temp%d_input", hwmon, i); return true; }
	}
	return false;
}

static int count_tccd(const char *hwmon)
{
	char p[PATH_MAX], lab[64]; int n = 0;
	for (int i = 1; i < 64; i++) {
		snprintf(p, sizeof(p), "%s/temp%d_label", hwmon, i);
		if (read_str(p, lab, sizeof(lab)) && !strncmp(lab, "Tccd", 4)) n++;
	}
	return n;
}

void blox_topo_init(struct blox_topo *t, int ccd_opt)
{
	char p[PATH_MAX], rel[160], name[64];
	memset(t, 0, sizeof(*t));
	cpuinfo(t);

	/* ---- cpus */
	for (int c = 0; c < BLOX_MAX_CPUS; c++) {
		long long pkg, core;
		struct blox_cpu *u = &t->cpu[c];
		u->pkg = u->core = u->l3 = -1;
		snprintf(rel, sizeof(rel), "/sys/devices/system/cpu/cpu%d/topology/physical_package_id", c);
		if (!sys_ll(rel, &pkg)) continue;
		snprintf(rel, sizeof(rel), "/sys/devices/system/cpu/cpu%d/topology/core_id", c);
		if (!sys_ll(rel, &core)) continue;
		u->present = true; u->pkg = (int) pkg; u->core = (int) core; u->l3 = l3_id(c);
		t->ncpu = c + 1; t->threads++;
		if (pkg_index(t, u->pkg) < 0 && t->npkg < BLOX_MAX_PKGS) t->pkg_id[t->npkg++] = u->pkg;
	}
	for (int c = 0; c < t->ncpu; c++) {       /* physical cores = unique (pkg, core) */
		if (!t->cpu[c].present) continue;
		bool seen = false;
		for (int d = 0; d < c && !seen; d++)
			seen = t->cpu[d].present && t->cpu[d].pkg == t->cpu[c].pkg && t->cpu[d].core == t->cpu[c].core;
		if (!seen) t->cores++;
	}
	int l3s[BLOX_MAX_CPUS], nl3 = 0;          /* sorted unique L3 ids */
	for (int c = 0; c < t->ncpu; c++) {
		int id = t->cpu[c].l3; bool dup = false;
		if (!t->cpu[c].present || id < 0) continue;
		for (int i = 0; i < nl3 && !dup; i++) dup = l3s[i] == id;
		if (!dup) l3s[nl3++] = id;
	}
	for (int i = 1; i < nl3; i++) for (int j = i; j > 0 && l3s[j - 1] > l3s[j]; j--) { int x = l3s[j]; l3s[j] = l3s[j - 1]; l3s[j - 1] = x; }
	t->nl3 = nl3;

	/* ---- hwmon: package temps, Intel per-core, AMD per-CCD */
	char k10[BLOX_MAX_PKGS][PATH_MAX]; int nk10 = 0;
	for (int h = 0; h < 64; h++) {
		char hw[PATH_MAX];
		snprintf(rel, sizeof(rel), "/sys/class/hwmon/hwmon%d", h);
		blox_sysfs(rel, hw, sizeof(hw));
		snprintf(p, sizeof(p), "%s/name", hw);
		if (!read_str(p, name, sizeof(name))) continue;
		if (!strcmp(name, "k10temp") && nk10 < BLOX_MAX_PKGS) {
			snprintf(k10[nk10++], PATH_MAX, "%s", hw);
		} else if (!strcmp(name, "coretemp")) {
			char lab[64]; long long pk;
			snprintf(p, sizeof(p), "%s/temp1_label", hw);
			if (!read_str(p, lab, sizeof(lab)) || sscanf(lab, "Package id %lld", &pk) != 1) continue;
			int pi = pkg_index(t, (int) pk);
			if (pi < 0) continue;
			snprintf(t->pkg_temp_path[pi], sizeof(t->pkg_temp_path[pi]), "%s/temp1_input", hw);
			for (int c = 0; c < t->ncpu; c++) {
				struct blox_cpu *u = &t->cpu[c];
				char want[32], in[160];
				if (!u->present || u->pkg != (int) pk) continue;
				snprintf(want, sizeof(want), "Core %d", u->core);
				if (find_label(hw, want, in, sizeof(in))) { snprintf(u->temp_path, sizeof(u->temp_path), "%s", in); u->temp_src = BLOX_T_CORE; }
			}
		}
	}
	for (int k = 0; k < nk10; k++) {            /* AMD package temp per socket: Tctl, else Tdie */
		int pkg = nk10 == 1 && t->npkg == 1 ? t->pkg_id[0] : k10temp_pkg(k10[k]);
		int pi = pkg >= 0 ? pkg_index(t, pkg) : -1;
		if (pi < 0) continue;
		if (!find_label(k10[k], "Tctl", t->pkg_temp_path[pi], sizeof(t->pkg_temp_path[pi])))
			find_label(k10[k], "Tdie", t->pkg_temp_path[pi], sizeof(t->pkg_temp_path[pi]));
	}

	/* ---- per-CCD decision (AMD) */
	t->ntccd = nk10 == 1 ? count_tccd(k10[0]) : 0;
	const char *why = NULL; char buf[128];
	if (nk10 == 0)                      why = "no AMD k10temp sensor";
	else if (ccd_opt == 0)              why = "off (ccd-temp-map=0)";
	else if (t->npkg > 1 || nk10 > 1)   why = "multi-socket: package temperature per socket";
	else if (t->ntccd == 0)             why = "no Tccd sensors (Tctl only)";
	else if (t->nl3 == 0)               why = "no L3 topology in sysfs";
	else if (t->nl3 % t->ntccd)         why = "L3 count is not a multiple of the Tccd count";
	if (!why && ccd_opt < 0) {
		const char *prof = NULL;
		for (size_t i = 0; i < sizeof(ccd_profiles) / sizeof(ccd_profiles[0]); i++)
			if (ccd_profiles[i].family == t->family && ccd_profiles[i].model == t->model &&
			    ccd_profiles[i].nl3 == t->nl3 && ccd_profiles[i].ntccd == t->ntccd) prof = ccd_profiles[i].what;
		if (prof) { snprintf(buf, sizeof(buf), "validated profile: %s", prof); t->ccd_mode = 1; }
		else {
			snprintf(buf, sizeof(buf), "no validated profile for family %d model %d (L3 %d, Tccd %d); ccd-temp-map=1 forces it",
				t->family, t->model, t->nl3, t->ntccd);
			why = buf;
		}
	} else if (!why) {
		snprintf(buf, sizeof(buf), "forced (ccd-temp-map=1): heuristic L3 order -> Tccd order, %d L3 per CCD", t->nl3 / t->ntccd);
		t->ccd_mode = 1;
	}
	snprintf(t->ccd_reason, sizeof(t->ccd_reason), "%s", why ? why : buf);
	if (t->ccd_mode) {
		int ratio = t->nl3 / t->ntccd;
		for (int c = 0; c < t->ncpu; c++) {
			struct blox_cpu *u = &t->cpu[c]; int r = -1; char want[16], in[160];
			if (!u->present || u->l3 < 0) continue;
			for (int i = 0; i < nl3; i++) if (l3s[i] == u->l3) r = i;
			if (r < 0) continue;
			snprintf(want, sizeof(want), "Tccd%d", r / ratio + 1);
			if (find_label(k10[0], want, in, sizeof(in))) { snprintf(u->temp_path, sizeof(u->temp_path), "%s", in); u->temp_src = BLOX_T_CCD; }
		}
	}
}

int blox_pkg_temp(const struct blox_topo *t)
{
	int best = -1;
	for (int i = 0; i < t->npkg; i++) { int v = blox_read_temp(t->pkg_temp_path[i]); if (v > best) best = v; }
	return best;
}

int blox_cpu_temp(const struct blox_topo *t, int cpu, int *src)
{
	int v = -1;
	*src = BLOX_T_NONE;
	if (cpu < 0 || cpu >= t->ncpu || !t->cpu[cpu].present) return -1;
	if (t->cpu[cpu].temp_path[0] && (v = blox_read_temp(t->cpu[cpu].temp_path)) >= 0) { *src = t->cpu[cpu].temp_src; return v; }
	int pi = pkg_index(t, t->cpu[cpu].pkg);
	if (pi >= 0 && (v = blox_read_temp(t->pkg_temp_path[pi])) >= 0) { *src = BLOX_T_PKG; return v; }
	return -1;
}

/* ---- RAPL: only top-level "package-N" domains (Intel "psys" would double count), one per topology package */
void blox_rapl_init(struct blox_rapl *r, const struct blox_topo *t)
{
	char rel[64], dir[PATH_MAX], p[PATH_MAX], name[64];
	int found[BLOX_MAX_PKGS] = { 0 };
	memset(r, 0, sizeof(*r));
	for (int d = 0; d < 32; d++) {
		long long e, range; int pk;
		snprintf(rel, sizeof(rel), "/sys/class/powercap/intel-rapl:%d", d);
		blox_sysfs(rel, dir, sizeof(dir));
		snprintf(p, sizeof(p), "%s/name", dir);
		if (!read_str(p, name, sizeof(name)) || sscanf(name, "package-%d", &pk) != 1) continue;
		int pi = pkg_index(t, pk);
		if (pi < 0) { snprintf(r->reason, sizeof(r->reason), "RAPL %s has no matching CPU package", name); return; }
		found[pi]++;
		snprintf(p, sizeof(p), "%s/energy_uj", dir);
		if (!read_ll(p, &e)) { snprintf(r->reason, sizeof(r->reason), "RAPL energy_uj not readable (needs root)"); return; }
		snprintf(p, sizeof(p), "%s/max_energy_range_uj", dir);
		if (!read_ll(p, &range) || range <= 0) { snprintf(r->reason, sizeof(r->reason), "RAPL max_energy_range_uj not readable"); return; }
		if (r->n >= BLOX_MAX_PKGS) break;
		snprintf(r->path[r->n], sizeof(r->path[r->n]), "%s/energy_uj", dir);
		r->pkg[r->n] = pk; r->range[r->n] = (uint64_t) range; r->n++;
	}
	if (t->npkg == 0) { snprintf(r->reason, sizeof(r->reason), "no CPU topology"); return; }
	for (int i = 0; i < t->npkg; i++)
		if (found[i] != 1) {
			snprintf(r->reason, sizeof(r->reason), found[i] ? "duplicate RAPL domain for package %d" : "no RAPL package domain for package %d", t->pkg_id[i]);
			return;
		}
	r->usable = true;
	snprintf(r->reason, sizeof(r->reason), "%d package domain%s", r->n, r->n > 1 ? "s" : "");
}

double blox_rapl_watts(struct blox_rapl *r, double now)
{
	if (!r->usable) return -1;
	double total = 0; bool ok = true;
	for (int i = 0; i < r->n; i++) {
		long long e;
		if (!read_ll(r->path[i], &e) || e < 0 || (uint64_t) e > r->range[i]) { r->have_last[i] = false; ok = false; continue; }
		if (r->have_last[i]) {
			/* one bound for both checks: at BLOX_RAPL_MAX_W the counter wraps once per maxdt seconds, so a
			 * longer gap could hide a wrap, and a higher reading is not a CPU package */
			double dt = now - r->last_t[i];
			double maxdt = (double) r->range[i] / 1e6 / BLOX_RAPL_MAX_W;
			double de = (double) e - (double) r->last_e[i];
			if (de < 0) de += (double) r->range[i];
			double w = dt > 0 ? de / 1e6 / dt : -1;
			if (dt <= 0.5 || dt > maxdt || w <= 0 || w > BLOX_RAPL_MAX_W) ok = false;
			else total += w;
		} else ok = false;
		r->last_e[i] = (uint64_t) e; r->last_t[i] = now; r->have_last[i] = true;
	}
	return ok ? total : -1;
}

void blox_sensors_dump(FILE *f, int ccd_opt)
{
	static struct blox_topo t;
	struct blox_rapl r;
	blox_topo_init(&t, ccd_opt);
	fprintf(f, "CPU        %s | vendor %s family %d model %d\n", t.model_name[0] ? t.model_name : "?", t.vendor, t.family, t.model);
	fprintf(f, "Topology   %d package(s), %d cores, %d threads, %d L3 group(s), %d Tccd sensor(s)\n",
		t.npkg, t.cores, t.threads, t.nl3, t.ntccd);
	fprintf(f, "Per-CCD    %s\n", t.ccd_reason);
	for (int i = 0; i < t.npkg; i++)
		fprintf(f, "Package %d  temp %d C  (%s)\n", t.pkg_id[i], blox_read_temp(t.pkg_temp_path[i]),
			t.pkg_temp_path[i][0] ? t.pkg_temp_path[i] : "no sensor");
	fprintf(f, "cpu pkg core  l3  src   temp  path\n");
	for (int c = 0; c < t.ncpu; c++) {
		const struct blox_cpu *u = &t.cpu[c]; int src;
		if (!u->present) continue;
		int v = blox_cpu_temp(&t, c, &src);
		const char *s = src == BLOX_T_CCD ? "ccd" : src == BLOX_T_CORE ? "core" : src == BLOX_T_PKG ? "pkg" : "none";
		fprintf(f, "%3d %3d %4d %3d  %-4s %4d  %s\n", c, u->pkg, u->core, u->l3, s, v, u->temp_path[0] ? u->temp_path : "-");
	}
	blox_rapl_init(&r, &t);
	fprintf(f, "Power      %s\n", r.reason);
	if (r.usable) {
		struct timespec ts;
		clock_gettime(CLOCK_MONOTONIC, &ts); blox_rapl_watts(&r, ts.tv_sec + ts.tv_nsec / 1e9);
		sleep(1);
		clock_gettime(CLOCK_MONOTONIC, &ts);
		fprintf(f, "Power      %.0f W (1 s sample)\n", blox_rapl_watts(&r, ts.tv_sec + ts.tv_nsec / 1e9));
	}
}
