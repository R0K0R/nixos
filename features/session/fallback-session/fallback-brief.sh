# fallback-brief: the first message for Claude Code in the fallback session.
# Facts only, gathered the way the banner gathers them, plus the scope.

repo=${HM_REPO:-$HOME/config/home}
sys=$(system_epoch)
check=$(session-epoch-check)
lock=$repo/flake.lock
lrev=""
[ -r "$lock" ] && lrev=$(lock_system_rev "$lock")
lepoch=""
[ -n "$lrev" ] && lepoch=$(history_epoch_of_rev "$lrev")
match=$(newest_gen_of_epoch "$sys")
newest=$(newest_rev_of_epoch "$sys")
failed=$(hm_switch_state)/last-failed.log

cat <<MSG
I am in the FALLBACK SESSION on $(system_host): my login was diverted here because my
home-manager generation does not match the system it runs on. Please help me get a
working home again.

How this machine works: the system flake is admin-owned; my home is a standalone
home-manager repo ($repo) built on the system's homeLib. Each system revision has an
EPOCH, a hash over the system code loaded into user processes (graphics driver, PAM and
NSS modules, locale archive, global env). A home generation built for one epoch may break
under another. The history of deployed revisions is $EPOCH_HISTORY (JSON lines).

Facts:
- running system: rev $(system_rev), epoch ${sys:-<not recorded>}
- session check: $check
- $lock pins system rev ${lrev:-<none>}, whose epoch here is ${lepoch:-<unknown: never deployed on this machine>}
- newest home generation built for the running epoch: ${match:-<none>}
- newest clean system rev deployed with the running epoch: ${newest:-<none>}
- recent revs of this epoch: $(revs_of_epoch "$sys" | tr '\n' ' ')
MSG

if [ -s "$failed" ]; then
  printf -- '- the last hm-switch FAILED; tail of %s:\n\n```\n' "$failed"
  tail -n 40 "$failed"
  printf '```\n'
else
  printf -- '- no failed hm-switch is recorded\n'
fi

cat <<'MSG'

Tools: `hm-switch` (checks the lock against the epoch history, then home-manager switch;
`--update` relocks the system input to the newest revision of the running epoch),
`hm-rollback` (lists generations with their epochs; `hm-rollback N` activates one),
`session-epoch-check`.

Scope: only my home repo and my home generations. sudo, /etc, the system flake and
system generations are OUT of scope -- if the fix needs a system change, tell me what
to ask the admin instead. Please diagnose first and propose before switching.
MSG
