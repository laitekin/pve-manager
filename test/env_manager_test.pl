#!/usr/bin/perl

use strict;
use warnings;

use lib '..';

use Test::More;

use PVE::EnvManager;

# --- database (de)serialization ---

my $db = PVE::EnvManager::parse_db('');
is_deeply($db, PVE::EnvManager::empty_db(), 'empty input yields empty database');

eval { PVE::EnvManager::parse_db('{"version": 99}') };
like($@, qr/unsupported environment database version/, 'reject newer database version');

eval { PVE::EnvManager::parse_db('[1]') };
like($@, qr/not an object/, 'reject non-object database');

my $roundtrip = PVE::EnvManager::parse_db(PVE::EnvManager::encode_db({
    version => 1,
    environments => { 'env-00000001' => { id => 'env-00000001', vmid => 100 } },
}));
is($roundtrip->{environments}->{'env-00000001'}->{vmid}, 100, 'roundtrip keeps records');
is_deeply($roundtrip->{options}, {}, 'roundtrip adds missing options');

# --- helpers ---

is(PVE::EnvManager::os_family('win11'), 'windows', 'win11 is windows');
is(PVE::EnvManager::os_family('l26'), 'linux', 'l26 is linux');
is(PVE::EnvManager::os_family('other'), 'other', 'other is other');
is(PVE::EnvManager::os_family(undef), 'unknown', 'undef is unknown');

my $seq = 0;
my $rand = sub { return ++$seq };

$db = PVE::EnvManager::empty_db();
$db->{environments}->{'env-00000001'} = { id => 'env-00000001' };
is(PVE::EnvManager::new_env_id($db, $rand), 'env-00000002', 'new id skips existing one');

# --- creation admission ---

$db = PVE::EnvManager::empty_db();
$seq = 0;
my $used = { 100 => {}, 101 => {} };

my $e1 = PVE::EnvManager::reserve_creation(
    $db,
    name => 'a',
    owner => 'root@pam',
    used_ids => $used,
    rand => $rand,
    now => 1000,
    'request-id' => 'req1',
);
is($e1->{vmid}, 102, 'first free VMID allocated');
is($e1->{state}, 'creating', 'new record is in state creating');

my $e2 = PVE::EnvManager::reserve_creation($db, name => 'b', used_ids => $used, rand => $rand);
is($e2->{vmid}, 103, 'VMID reserved by pending env is not reused');

is(PVE::EnvManager::find_by_request_id($db, 'req1')->{id}, $e1->{id}, 'find by request id');
is(PVE::EnvManager::find_by_vmid($db, 103)->{id}, $e2->{id}, 'find by vmid');

$db->{options}->{'max-creating'} = 2;
eval { PVE::EnvManager::reserve_creation($db, name => 'c', used_ids => $used, rand => $rand) };
like($@, qr/too many environments being created/, 'max-creating enforced');

$e1->{state} = 'ready';
my $e3 = PVE::EnvManager::reserve_creation($db, name => 'c', used_ids => $used, rand => $rand);
ok($e3, 'creation slot released when creation finished');

$db->{options}->{'max-envs'} = 3;
$e2->{state} = 'ready';
$e3->{state} = 'ready';
eval { PVE::EnvManager::reserve_creation($db, name => 'd', used_ids => $used, rand => $rand) };
like($@, qr/environment limit reached \(3\/3\)/, 'max-envs enforced');

$e3->{state} = 'error';
delete $e3->{vmid};
ok(
    PVE::EnvManager::reserve_creation($db, name => 'd', used_ids => $used, rand => $rand),
    'failed creation without VM does not count towards max-envs',
);

# --- start admission ---

$db = PVE::EnvManager::empty_db();
$db->{options}->{'max-running'} = 2;
for my $i (1 .. 4) {
    my $id = sprintf('env-%08x', $i);
    $db->{environments}->{$id} = { id => $id, vmid => 100 + $i, state => 'ready' };
}

my $running = { 101 => 1 };
is(PVE::EnvManager::reserve_start($db, 'env-00000001', $running, 5000), 1, 'running env needs no slot');
is(PVE::EnvManager::reserve_start($db, 'env-00000002', $running, 5000), 0, 'second env gets slot');
eval { PVE::EnvManager::reserve_start($db, 'env-00000003', $running, 5001) };
like($@, qr/running environment limit reached \(2\/2\)/, 'pending start counts towards max-running');

ok(
    eval { PVE::EnvManager::reserve_start($db, 'env-00000003', $running, 5000 + 601); 1 },
    'stale start reservation expires',
) or diag($@);

PVE::EnvManager::clear_start_reservation($db, 'env-00000002');
PVE::EnvManager::clear_start_reservation($db, 'env-00000003');
is(PVE::EnvManager::reserve_start($db, 'env-00000004', $running, 7000), 0, 'slot free after clear');

# --- status merging ---

my $merged = PVE::EnvManager::merge_status(
    { id => 'env-00000001', vmid => 101, state => 'ready', 'start-reserved' => 1, node => 'a' },
    { status => 'running', node => 'b', cpu => 0.5, mem => 10, maxmem => 20 },
);
is($merged->{health}, 'ok', 'healthy env');
is($merged->{node}, 'b', 'live node wins over stored node');
is($merged->{status}, 'running', 'live status');
ok(!exists($merged->{'start-reserved'}), 'internal fields are hidden');

$merged = PVE::EnvManager::merge_status({ id => 'x', vmid => 1, state => 'ready' }, undef);
is($merged->{health}, 'missing', 'vanished VM is reported as missing');
is($merged->{status}, 'absent', 'vanished VM status');

$merged = PVE::EnvManager::merge_status({ id => 'x', state => 'creating' }, undef);
is($merged->{health}, 'creating', 'pending env is not missing');

# --- proxy parsing ---

my $p = PVE::EnvManager::parse_proxy_line('socks5://us%40r:p%3Ass@1.2.3.4:1080');
is_deeply(
    $p,
    { type => 'socks5', host => '1.2.3.4', port => 1080, username => 'us@r', password => 'p:ss' },
    'parse URL form with escaped credentials',
);
$p = PVE::EnvManager::parse_proxy_line('proxy.example.com:8000:user:secret');
is_deeply(
    $p,
    {
        type => 'http',
        host => 'proxy.example.com',
        port => 8000,
        username => 'user',
        password => 'secret',
    },
    'parse host:port:user:pass form',
);
$p = PVE::EnvManager::parse_proxy_line('http://[2001:db8::1]:3128');
is($p->{host}, '2001:db8::1', 'parse IPv6 host');
is(PVE::EnvManager::parse_proxy_line('socks5h://h:1')->{type}, 'socks5', 'socks5h is socks5');
eval { PVE::EnvManager::parse_proxy_line('ftp://h:1') };
like($@, qr/unsupported proxy type/, 'reject unknown type');
eval { PVE::EnvManager::parse_proxy_line('h:99999') };
like($@, qr/invalid proxy port/, 'reject invalid port');
eval { PVE::EnvManager::parse_proxy_line('h:1:u') };
like($@, qr/unable to parse/, 'reject three-part form');

# --- check response parsing ---

is_deeply(
    PVE::EnvManager::parse_check_response('{"ip":"5.6.7.8","country":"US","city":"X","loc":"1,2"}'),
    { ip => '5.6.7.8', country => 'US', city => 'X' },
    'parse JSON check response',
);
is(PVE::EnvManager::parse_check_response("5.6.7.8\n")->{ip}, '5.6.7.8', 'parse plain IP');
is(PVE::EnvManager::parse_check_response('2001:db8::2')->{ip}, '2001:db8::2', 'parse plain IPv6');
eval { PVE::EnvManager::parse_check_response('<html>blocked</html>') };
like($@, qr/did not return an IP/, 'reject non-IP body');

# --- pool, binding and health ---

$db = PVE::EnvManager::empty_db();
$seq = 0;
$db->{environments}->{'env-00000001'} = { id => 'env-00000001', vmid => 101, state => 'ready' };
$db->{environments}->{'env-00000002'} = { id => 'env-00000002', vmid => 102, state => 'ready' };

my $px = PVE::EnvManager::add_proxy($db, { type => 'http', host => 'h', port => 1 }, $rand);
is($px->{state}, 'active', 'new proxy is active');
eval { PVE::EnvManager::add_proxy($db, { type => 'http', host => 'H', port => 1 }, $rand) };
like($@, qr/already exists/, 'duplicate proxy rejected');

my $b = PVE::EnvManager::bind_proxy($db, 'env-00000001', $px->{id}, 100);
is($b->{proxy}, $px->{id}, 'bind proxy');
eval { PVE::EnvManager::bind_proxy($db, 'env-00000002', $px->{id}, 100) };
like($@, qr/already used by 1/, 'proxy is exclusive by default');
is(PVE::EnvManager::bind_proxy($db, 'env-00000001', $px->{id})->{bound}, 100, 'rebinding same is a no-op');

my $env1 = $db->{environments}->{'env-00000001'};
is(PVE::EnvManager::binding_health($db, $env1), 'ok', 'unchecked binding is ok');

my $ev = PVE::EnvManager::apply_check_result($db, $px->{id}, { ok => 1, ip => '9.9.9.9', latency => 50 }, 200);
is($px->{'exit-ip'}, '9.9.9.9', 'exit ip recorded');
is($env1->{'proxy-binding'}->{'exit-ip'}, '9.9.9.9', 'binding adopts first exit ip');
is(scalar(@$ev), 1, 'one event for first exit ip');

$ev = PVE::EnvManager::apply_check_result($db, $px->{id}, { ok => 1, ip => '8.8.8.8' }, 300);
is(PVE::EnvManager::binding_health($db, $env1), 'exit-changed', 'exit ip change detected');
like(
    PVE::EnvManager::check_start_allowed($db, $env1),
    qr/exit IP .* changed/,
    'start blocked on exit change',
);
is(scalar($px->{'exit-history'}->@*), 2, 'exit history kept');
PVE::EnvManager::accept_exit_ip($db, 'env-00000001');
is(PVE::EnvManager::binding_health($db, $env1), 'ok', 'accepted new exit ip');

for my $t (1 .. 2) {
    PVE::EnvManager::apply_check_result($db, $px->{id}, { ok => 0, error => 'timeout' }, 400 + $t);
}
is($px->{state}, 'active', 'still active below fail threshold');
$ev = PVE::EnvManager::apply_check_result($db, $px->{id}, { ok => 0, error => 'timeout' }, 403);
is($px->{state}, 'failed', 'failed after threshold');
like($ev->[0], qr/marked as failed/, 'failure event');
is(PVE::EnvManager::binding_health($db, $env1), 'proxy-failed', 'binding reports failed proxy');
like(PVE::EnvManager::check_start_allowed($db, $env1), qr/not usable/, 'start blocked (fail-closed)');

my $merged_px = PVE::EnvManager::merge_status($env1, { status => 'running', node => 'n' }, $db);
is($merged_px->{health}, 'proxy-failed', 'merged health reflects proxy');
is($merged_px->{'proxy-state'}, 'failed', 'merged proxy state');

$db->{options}->{'proxy-fail-closed'} = 0;
ok(!defined(PVE::EnvManager::check_start_allowed($db, $env1)), 'fail-open when configured');

PVE::EnvManager::apply_check_result($db, $px->{id}, { ok => 1, ip => '8.8.8.8' }, 500);
is($px->{state}, 'active', 'proxy recovers on success');

$px->{expires} = 600;
is(PVE::EnvManager::binding_health($db, $env1, 700), 'proxy-failed', 'expired proxy is not usable');
delete $px->{expires};

eval { PVE::EnvManager::remove_proxy($db, $px->{id}) };
like($@, qr/is bound to env-00000001/, 'bound proxy cannot be removed');
is_deeply(PVE::EnvManager::remove_proxy($db, $px->{id}, 1), ['env-00000001'], 'forced removal');
ok(!$env1->{'proxy-binding'}, 'forced removal drops binding');

done_testing();
