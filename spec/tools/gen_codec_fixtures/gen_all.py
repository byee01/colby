import shutil, os
import gen_common, gen_status, gen_uart
for folder in ('advertisement', 'probe_status', 'node_status', 'uart_frames'):
    shutil.rmtree(os.path.join(gen_common.ROOT, folder), ignore_errors=True)
gen_common.gen_advertisements()
gen_status.gen_probe_status()
gen_status.gen_node_status()
gen_uart.gen_uart()
print(gen_common.counts, sum(gen_common.counts.values()))
