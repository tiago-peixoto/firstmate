registered checks: contributions.check.sh delivery.check.sh 

## quiet (--seconds 60): rc=124 elapsed=60.2s wakes=0
--- stdout
checkpoint: no actionable wake within 60s
--- stderr

$ forge: head -> bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

## movement (--seconds 30): rc=0 elapsed=2.9s wakes=1
--- stdout
check: contributions delivery ea92d2fdcd819936c05a18447eca992d9aff76db615713b3dcfb7659bfc68755

--- stderr

$ fm-contributions.sh pending
{"type":"head","body":"head moved from aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa to bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}

## repeat (--seconds 2): rc=124 elapsed=2.2s wakes=1
--- stdout
checkpoint: no actionable wake within 2s
--- stderr

real	1m7.021s
user	0m14.378s
sys	0m34.134s
exit=0
