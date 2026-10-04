# Seeds runs and agent invocations into a state database whose schema the real
# no-mistakes CLI created. Offsets are seconds from the task branch creation.
import sqlite3, sys
database, branch, base = sys.argv[1], sys.argv[2], int(sys.argv[3])
db = sqlite3.connect(database)
def run(i, br, status, off):
    db.execute("INSERT INTO runs (id, repo_id, branch, head_sha, base_sha, status, created_at, updated_at) VALUES (?, 'r1', ?, 'h', 'b', ?, ?, ?)",
               (i, br, status, base + off, base + off))
n = [0]
def inv(run_id, purpose, mode, exit_status, dur, raw, delta):
    n[0] += 1
    db.execute("INSERT INTO agent_invocations (id, run_id, step_name, round, purpose, agent, session_mode, started_at, completed_at, duration_ms, exit_status,"
               " input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, reasoning_tokens, delta_input_tokens, delta_output_tokens, delta_cache_read_tokens)"
               " VALUES (?, ?, ?, 1, ?, 'claude', ?, ?, ?, ?, ?, ?, ?, ?, ?, 999, ?, ?, ?)",
               ("inv%02d" % n[0], run_id, purpose, purpose, mode, base + n[0], base + n[0], dur, exit_status) + raw + delta)
N = (None, None, None)
run("RUN-BEFORE-BRANCH", branch, "completed", -500)
run("RUN-A", branch, "failed", 100)
run("RUN-B", branch, "completed", 6000)
run("RUN-OTHER-BRANCH", "fm/other", "completed", 200)
inv("RUN-BEFORE-BRANCH", "review", "cold", "ok", 1000, (7777, 7777, 7777, 7777), (7777, 7777, 7777))
inv("RUN-OTHER-BRANCH", "review", "cold", "ok", 1000, (8888, 8888, 8888, 8888), (8888, 8888, 8888))
inv("RUN-A", "review", "cold", "ok", 1000, (100, 20, 50, 5), (100, 20, 50))
inv("RUN-A", "review-fix", "resumed", "error", 2000, (1000, 200, 500, 7), (300, 60, 100))
inv("RUN-A", "review", "cold", "cancelled", 50, (None, None, None, None), N)
inv("RUN-B", "review", "resumed", "ok", 400, (900, 90, 9, 3), N)
inv("RUN-B", "test", "started", "ok", 600, (10, 2, 0, 0), (10, 2, 0))
db.commit()
