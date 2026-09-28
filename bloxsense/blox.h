/* BloxMiner additions: CPU topology, sensors, per-core stats snapshot, terminal dashboard, log file.
 * GPL-3.0 (part of a ccminer derivative). Nothing here touches hashing. */
#pragma once

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <signal.h>

#define BLOX_MAX_CPUS 1024
#define BLOX_MAX_PKGS 8
#define BLOX_MAX_ROWS 140          /* = MAX_GPUS: one row per thread at most */
#define BLOX_ROW_CPUS 8
#define BLOX_RAPL_MAX_W 2000.0      /* plausibility bound for one CPU package (W) */

/* ---- topology and sensors (blox_sys.cpp) ---- */
enum blox_tsrc { BLOX_T_NONE = 0, BLOX_T_PKG, BLOX_T_CCD, BLOX_T_CORE };

struct blox_cpu {
	bool present;
	int pkg, core, l3;             /* -1 when unknown */
	char temp_path[160];           /* per-CPU temperature input (CCD or core), empty = use package temp */
	int  temp_src;                 /* BLOX_T_CCD / BLOX_T_CORE / BLOX_T_NONE */
};

struct blox_topo {
	int ncpu;                      /* highest present cpu index + 1 */
	struct blox_cpu cpu[BLOX_MAX_CPUS];
	int npkg, pkg_id[BLOX_MAX_PKGS];
	char pkg_temp_path[BLOX_MAX_PKGS][160];
	char vendor[16], model_name[80];
	int family, model;
	int cores, threads;            /* physical cores / logical cpus present */
	int nl3, ntccd;
	int ccd_mode;                  /* 1 = per-CCD temps in use */
	char ccd_reason[128];          /* why per-CCD temps are on/off (shown by --sensors) */
};

struct blox_rapl {
	int n;
	char path[BLOX_MAX_PKGS][160];
	int pkg[BLOX_MAX_PKGS];
	uint64_t range[BLOX_MAX_PKGS], last_e[BLOX_MAX_PKGS];
	double last_t[BLOX_MAX_PKGS];
	bool have_last[BLOX_MAX_PKGS];
	bool usable;                   /* every topology package has exactly one readable package domain */
	char reason[128];
};

const char *blox_sysfs(const char *path, char *out, size_t outsz);   /* prefixes $BLOX_SYSFS_ROOT (tests) */
void blox_topo_init(struct blox_topo *t, int ccd_opt);              /* ccd_opt: -1 auto, 0 off, 1 forced */
int  blox_read_temp(const char *path);                              /* degrees C, -1 when unreadable */
int  blox_pkg_temp(const struct blox_topo *t);                      /* hottest package, -1 when none */
int  blox_cpu_temp(const struct blox_topo *t, int cpu, int *src);   /* falls back to package temp */
void blox_rapl_init(struct blox_rapl *r, const struct blox_topo *t);
double blox_rapl_watts(struct blox_rapl *r, double now);            /* total W, -1 when not valid */
void blox_sensors_dump(FILE *f, int ccd_opt);                       /* --sensors */

/* A thread is overdue when its current batch has run longer than twice its longest batch so far + 30 s,
 * clamped to 300..600 s (2.0.0 rule, shared by the API and the sampler). */
static inline long blox_stale_limit(double maxdur)
{
	long l = (long) (2.0 * maxdur) + 30;
	if (l < 300) l = 300;
	if (l > 600) l = 600;
	return l;
}

/* ---- per-core snapshot + service thread (blox_stats.cpp) ---- */
struct blox_row {
	int pkg, core;                 /* -1/-1 for a per-thread row */
	int ncpu, cpus[BLOX_ROW_CPUS];
	double khs;                    /* sum of fresh thread rates in kH/s */
	int temp, temp_src;            /* -1 when none */
	bool pending;                  /* no thread of this row has finished a batch yet (startup) */
};

struct blox_snap {
	uint64_t gen;
	double mono;                   /* monotonic time of the sample */
	int rows;
	bool percore;                  /* rows are physical cores (else one row per thread) */
	int threads_cfg, threads_covered;
	bool stall;
	double fresh_khs;
	double power_w;                /* -1 when unavailable */
	int pkg_temp;                  /* -1 when unavailable */
	struct blox_row row[BLOX_MAX_ROWS];
};

extern int blox_ccd_opt;               /* --ccd-temp-map auto|0|1 */
extern int blox_stats_interval;        /* --stats-interval seconds (periodic table) */
extern bool blox_no_dashboard;         /* --no-dashboard */
extern bool blox_thread_log;           /* --thread-log */
extern struct blox_topo blox_topology;

void blox_prepare(void);               /* topology + RAPL discovery */
bool blox_start(void);                 /* service thread: sampler, dashboard, signal watcher */
bool blox_snapshot(struct blox_snap *out);
double blox_mono(void);
bool blox_algo_is_verus(void);         /* ccminer.cpp: opt_algo is the Verus slot */
void blox_install_signals(bool background);

/* ---- terminal + log (blox_ui.cpp) ---- */
extern FILE *blox_log_fp;              /* plain-text log (--log-file), NULL when off */
extern bool blox_dash_active;
void blox_log_open(const char *path);
void blox_log_line_locked(const char *line);   /* caller holds applog_lock */
void blox_banner(void);
void blox_ui_init(void);
void blox_ui_tick(const struct blox_snap *s, bool full_redraw, bool resized);
void blox_ui_periodic(const struct blox_snap *s);
void blox_ui_restore(void);            /* normal context only (proper_exit) */
