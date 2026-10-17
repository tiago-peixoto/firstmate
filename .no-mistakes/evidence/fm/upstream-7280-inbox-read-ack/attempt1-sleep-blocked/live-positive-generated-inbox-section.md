# Firstmate instruction inbox
Firstmate steers you through durable message files in '/tmp/fm-lab.ALSGIT/state/rr-positive.inbox'.
When a terminal message says an instruction is waiting there - and at any natural checkpoint when you are unsure - list '/tmp/fm-lab.ALSGIT/state/rr-positive.inbox'/*.msg and read each message in numeric order.
Immediately after reading each message, before acting, record that you read it: `'/home/firstmate/.no-mistakes/worktrees/5284051b2355/01M5598DH6TJ7W4HZVJMJZKJYV/bin/fm-task-inbox-read.sh' '/tmp/fm-lab.ALSGIT/state/rr-positive.inbox'/NNN.msg`.
Do not record a read before actually reading the message; if the command fails, report the failure rather than assuming it was acknowledged.
Then act on the message and acknowledge completed handling by moving it: `mv '/tmp/fm-lab.ALSGIT/state/rr-positive.inbox'/NNN.msg '/tmp/fm-lab.ALSGIT/state/rr-positive.inbox'/handled/`.
The read receipt stops unread-instruction alarms while you work; it does not mean the work is complete or replace the handled/ move.
An empty or absent inbox needs no action.

