#!/usr/bin/env bash
# CPU gate: x86-64 + AES-NI (XMRig's build adds -maes globally, cmake/flags.cmake) + SSE2 baseline.
#
# A separate, tiny file - not engines/rx/h-run.sh itself - SPECIFICALLY so it can be sourced on its own, with
# NO other side effect at all (no cd, no manifest sourcing, no trap, nothing), by anything that needs to know
# "can this host run RandomX": this engine's own h-run.sh (which sources it right below, then calls cpu_ok()
# in plain sight before its own `hugepages -rx`) AND the top-level dispatcher (bloxminer/h-run.sh, which
# sources it and calls cpu_ok() in plain sight BEFORE it ever reserves huge pages for rx via
# note_rx_hugepages_start - PR #2 review, Codex).
#
# PR #2 follow-up review (Codex): an earlier version of this reuse had the dispatcher source engines/rx/
# h-run.sh ITSELF in a special env-var-gated "preflight-only" mode, relying on that file's own early
# `return $rc` to stop before any of its other side effects. That was harder to verify by inspection than it
# needed to be (does the early return actually fire before the EXIT trap gets installed? does sourcing the
# WHOLE file risk leaking something else into the dispatcher's shell?) even though it worked correctly. This
# file removes that whole class of question: it is nothing but a function definition, so sourcing it can never
# have a side effect beyond defining cpu_ok() in the caller's shell - there is no "early return" for a
# reviewer to have to trust, because there is nothing else in the file to return early FROM. Both callers then
# call cpu_ok() themselves, directly, as an ordinary command, right in their own visible control flow - one
# function, defined once, is what makes it impossible for the two checks to ever drift apart, whichever file
# calls it.
#
# This file does not make engines/rx/h-run.sh aware a dispatcher exists (see h-common.sh's own header
# comment on that boundary): it is a plain sibling file inside this engine's own directory, referencing
# nothing dispatcher-specific, sourced by relative name like any other file in this engine's own directory.
cpu_ok() {   # CPUINFO overridable for testing
	local f; f=" $(grep -m1 '^flags' "${CPUINFO:-/proc/cpuinfo}" | cut -d: -f2) "
	for x in aes sse2; do [[ $f == *" $x "* ]] || return 1; done
}
