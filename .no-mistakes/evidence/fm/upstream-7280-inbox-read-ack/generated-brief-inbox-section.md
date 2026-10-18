# Firstmate instruction inbox
Firstmate steers you through durable message files in '/tmp/fm-lab.jT2X6X/state/rcpt1.inbox'.
When a terminal message says an instruction is waiting there - and at any natural checkpoint when you are unsure - list them with `find '/tmp/fm-lab.jT2X6X/state/rcpt1.inbox' -maxdepth 1 -name '*.msg' 2>/dev/null | sort -V` and read each message in numeric order.
Immediately after reading each message, before acting, record that you read it: `'/home/firstmate/.no-mistakes/worktrees/5284051b2355/01M57PBNACQWBD7RWWZK07DQQV/bin/fm-task-inbox-read.sh' '/tmp/fm-lab.jT2X6X/state/rcpt1.inbox'/NNN.msg`.
Do not record a read before actually reading the message; if the command fails, report the failure rather than assuming it was acknowledged.
Then act on the message and acknowledge completed handling by moving it: `mv '/tmp/fm-lab.jT2X6X/state/rcpt1.inbox'/NNN.msg '/tmp/fm-lab.jT2X6X/state/rcpt1.inbox'/handled/`.
The read receipt stops unread-instruction alarms while you work; it does not mean the work is complete or replace the handled/ move.
An empty or absent inbox needs no action.
