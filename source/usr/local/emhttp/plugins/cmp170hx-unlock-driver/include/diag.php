<?php
header('Content-Type: text/plain');
header('Content-Disposition: attachment; filename="cmp170hx-diagnostics-' . date('Ymd-His') . '.txt"');
passthru('/usr/local/emhttp/plugins/cmp170hx-unlock-driver/include/cmp.sh diag 2>&1');
