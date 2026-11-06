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

done_testing();
