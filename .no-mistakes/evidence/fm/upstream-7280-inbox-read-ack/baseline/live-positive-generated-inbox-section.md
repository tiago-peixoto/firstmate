# Firstmate instruction inbox
Firstmate steers you through durable message files in '/tmp/fm-lab.OjKmg1/state/rr-positive.inbox'.
When a terminal message says an instruction is waiting there - and at any natural checkpoint when you are unsure - list '/tmp/fm-lab.OjKmg1/state/rr-positive.inbox'/*.msg, read and act on each message in numeric order, then acknowledge each handled message by moving it: `mv '/tmp/fm-lab.OjKmg1/state/rr-positive.inbox'/NNN.msg '/tmp/fm-lab.OjKmg1/state/rr-positive.inbox'/handled/`.
The move IS the acknowledgement: without it firstmate rings again and eventually treats you as stuck. An empty or absent inbox needs no action.

