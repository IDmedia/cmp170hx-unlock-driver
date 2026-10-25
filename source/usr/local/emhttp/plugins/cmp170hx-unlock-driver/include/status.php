<?php
// Read-only status for the settings page. ?refresh=1 first refreshes kernel-support/upgrade info (network).
header('Content-Type: application/json');
header('Cache-Control: no-store');

$name = 'cmp170hx-unlock-driver';
$cmp  = "/usr/local/emhttp/plugins/$name/include/cmp.sh";
$run  = "/tmp/$name";

function sh($cmd) { return trim((string)shell_exec($cmd . ' 2>/dev/null')); }
function ini($file, $raw = true) {
    return is_readable($file) ? (parse_ini_file($file, false, $raw ? INI_SCANNER_RAW : INI_SCANNER_NORMAL) ?: []) : [];
}

if (isset($_GET['refresh'])) {
    shell_exec($cmp . ' refresh' . ($_GET['refresh'] === 'force' ? ' force' : '') . ' >/dev/null 2>&1');
}

$out = [
    'unraid_version' => ini('/etc/unraid-version', false)['version'] ?? '',
    'kernel'   => sh('uname -r'),
    'conflict' => file_exists('/boot/config/plugins/nvidia-driver.plg') || file_exists('/var/log/plugins/nvidia-driver.plg'),
    'state'    => ini("$run/state"),
    'settings' => ini("/boot/config/plugins/$name/settings.cfg"),
];

$ms = @file_get_contents("$run/manifest-status");
$out['kernel_support'] = $ms === false ? '' : ['0' => 'supported', '2' => 'unsupported'][trim($ms)] ?? 'unknown';

$manifest = json_decode((string)@file_get_contents("$run/manifest-" . $out['kernel'] . '.json'), true);
$out['available'] = [];
foreach (($manifest['packages'] ?? []) as $p) {
    $out['available'][] = ['driver' => $p['driver'], 'cmpunlocker' => $p['cmpunlocker'], 'profile' => $p['profile']];
}
$out['upgrade'] = json_decode((string)@file_get_contents("$run/upgrade.json"), true);

// CMP 170HX cards on the PCI bus (works before the driver loads)
$cards = [];
foreach (explode("\n", sh('lspci -nn -d 10de:')) as $l) {
    if (preg_match('/^(\S+).*\[10de:(20c2|2082)\]/i', $l, $m)) {
        $cards[] = ['slot' => $m[1], 'id' => strtolower($m[2]), 'profile' => strtolower($m[2]) === '20c2' ? '8gb' : '10gb'];
    }
}
$out['cards'] = $cards;
$profiles = array_unique(array_column($cards, 'profile'));
$out['detected_profile'] = count($profiles) === 0 ? '' : (count($profiles) > 1 ? 'mixed' : reset($profiles));

// GPUs as the driver sees them; thresholds follow cmpunlocker verify.sh
$gpus = [];
$smi = sh('nvidia-smi --query-gpu=index,name,pci.bus_id,pci.device_id,memory.total,pcie.link.gen.current,pcie.link.gen.max,ecc.mode.current --format=csv,noheader,nounits');
foreach (array_filter(explode("\n", $smi)) as $l) {
    $f = array_map('trim', explode(',', $l));
    if (count($f) < 8) continue;
    $id  = strtolower(substr($f[3], 2, 4));
    $mem = (int)$f[4];
    if ($id === '20c2')      $unlock = $mem >= 60000 ? 'unlocked' : ($mem <= 16384 ? 'stock' : 'unexpected');
    elseif ($id === '2082')  $unlock = ($mem >= 35000 && $mem < 60000) ? 'unlocked' : ($mem <= 16384 ? 'stock' : 'unexpected');
    else                     $unlock = 'not_cmp';
    $gpus[] = ['index' => $f[0], 'name' => $f[1], 'bus' => preg_replace('/^0+:/', '', $f[2]), 'device' => $id,
               'memory_mib' => $mem, 'gen_current' => $f[5], 'gen_max' => $f[6], 'ecc' => $f[7], 'unlock' => $unlock];
}
$out['gpus'] = $gpus;

$out['module'] = [
    'version' => sh("modinfo nvidia | awk '/^version:/{print \$2; exit}'"),
    'license' => sh("modinfo nvidia | awk -F': *' '/^license:/{print \$2; exit}'"),
];
$out['pma_ok']   = (int)sh('dmesg | grep -c "late PMA extension status=0x0"') > 0;
$out['gen2_log'] = sh('tail -n 3 /var/log/gen2.log');
$out['installed_package'] = sh('ls /var/log/packages | grep -E "^cmp170hx-(nvidia|modules)-"');
$pkgs = "/boot/config/plugins/$name/packages";
$out['cached_package'] = sh("ls -1 $pkgs/" . escapeshellarg($out['kernel']) . "/*.txz $pkgs/nvidia/*.txz | xargs -r -n1 basename");

echo json_encode($out);
