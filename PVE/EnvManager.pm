package PVE::EnvManager;

# Business layer for "environments": a persistent record that maps a managed,
# isolated system environment onto a QEMU VM (and, in later stages, onto
# proxy bindings, quotas and ownership).
#
# The database is a single JSON document stored on pmxcfs, so it is shared
# across the cluster and survives host restarts. All modifications must go
# through lock_db(), which serializes writers cluster-wide.
#
# The pure helper functions in this module have no dependency on a running
# PVE node so that they can be unit tested (see test/env_manager_test.pl).

use strict;
use warnings;

use JSON;

our $DB_DIR = '/etc/pve/env-manager';
our $DB_PATH = "$DB_DIR/environments.json";
our $DB_VERSION = 1;

# a reservation for a start that was not confirmed within this time is
# considered stale (e.g. the worker was killed) and no longer counted.
our $START_RESERVATION_TTL = 600;

our $OPTION_DEFAULTS = {
    'max-envs' => 0, # 0 means unlimited
    'max-running' => 0,
    'max-creating' => 4,
};

my $STATES = {
    creating => 1, # clone task queued or running
    ready => 1, # VM exists and is under management
    error => 1, # creation failed, see 'error' property
    deleting => 1, # destroy task queued or running
};

sub valid_state {
    my ($state) = @_;
    return defined($state) && $STATES->{$state} ? 1 : 0;
}

sub empty_db {
    return {
        version => $DB_VERSION,
        environments => {},
        options => {},
    };
}

sub parse_db {
    my ($raw) = @_;

    return empty_db() if !defined($raw) || $raw !~ m/\S/;

    my $db = eval { JSON::decode_json($raw) };
    die "unable to parse environment database - $@" if $@;
    die "unable to parse environment database - not an object\n" if ref($db) ne 'HASH';

    $db->{version} //= $DB_VERSION;
    die "unsupported environment database version '$db->{version}'\n"
        if $db->{version} > $DB_VERSION;

    $db->{environments} //= {};
    $db->{options} //= {};

    return $db;
}

sub encode_db {
    my ($db) = @_;
    return JSON->new->utf8->canonical->pretty->encode($db);
}

sub read_db {
    return empty_db() if !-f $DB_PATH;
    require PVE::Tools;
    my $raw = PVE::Tools::file_get_contents($DB_PATH);
    return parse_db($raw);
}

sub write_db {
    my ($db) = @_;
    require PVE::Tools;
    mkdir $DB_DIR if !-d $DB_DIR;
    PVE::Tools::file_set_contents($DB_PATH, encode_db($db));
}

# run $code with the database locked cluster-wide; the (possibly modified)
# database is written back afterwards, unless $code dies.
sub lock_db {
    my ($code, @param) = @_;

    require PVE::Cluster;

    my $res = PVE::Cluster::cfs_lock_domain(
        'env-manager',
        10,
        sub {
            my $db = read_db();
            my $r = $code->($db, @param);
            write_db($db);
            return $r;
        },
    );
    die $@ if $@;
    return $res;
}

sub get_options {
    my ($db) = @_;
    my $opts = { %$OPTION_DEFAULTS };
    for my $k (keys %$OPTION_DEFAULTS) {
        $opts->{$k} = $db->{options}->{$k} if defined($db->{options}->{$k});
    }
    return $opts;
}

sub os_family {
    my ($ostype) = @_;

    return 'unknown' if !defined($ostype) || $ostype eq '';
    return 'windows' if $ostype =~ m/^w/;
    return 'linux' if $ostype =~ m/^l\d/;
    return 'solaris' if $ostype eq 'solaris';
    return 'other';
}

sub new_env_id {
    my ($db, $rand) = @_;

    $rand //= sub { int(rand(0xffffffff)) };

    for (1 .. 100) {
        my $id = sprintf('env-%08x', $rand->());
        return $id if !$db->{environments}->{$id};
    }
    die "unable to generate unique environment ID\n";
}

sub find_by_vmid {
    my ($db, $vmid) = @_;
    for my $id (sort keys $db->{environments}->%*) {
        my $env = $db->{environments}->{$id};
        return $env if defined($env->{vmid}) && $env->{vmid} == $vmid;
    }
    return undef;
}

sub find_by_request_id {
    my ($db, $request_id) = @_;
    return undef if !defined($request_id);
    for my $id (sort keys $db->{environments}->%*) {
        my $env = $db->{environments}->{$id};
        return $env if defined($env->{'request-id'}) && $env->{'request-id'} eq $request_id;
    }
    return undef;
}

sub count_envs {
    my ($db, $filter) = @_;
    my $count = 0;
    for my $env (values $db->{environments}->%*) {
        $count++ if $filter->($env);
    }
    return $count;
}

# envs that occupy a slot of the 'max-envs' limit: failed creations without a
# VM do not count, so a failure releases its reservation.
sub counts_towards_total {
    my ($env) = @_;
    return 0 if ($env->{state} // '') eq 'error' && !defined($env->{vmid});
    return 1;
}

# Pick the lowest free VMID in [$lower, $upper) that is neither used by an
# existing guest nor reserved by an environment record.
sub allocate_vmid {
    my ($db, $used_ids, $lower, $upper) = @_;

    $lower //= 100;
    $upper //= 1000 * 1000;

    my $reserved = {};
    for my $env (values $db->{environments}->%*) {
        $reserved->{ $env->{vmid} } = 1 if defined($env->{vmid});
    }

    for (my $i = $lower; $i < $upper; $i++) {
        return $i if !defined($used_ids->{$i}) && !$reserved->{$i};
    }
    die "unable to get any free VMID in range [$lower, $upper]\n";
}

# Admission control for a new environment. Must be called with the database
# locked. Dies if a limit would be exceeded; otherwise adds and returns a new
# record in state 'creating'.
sub reserve_creation {
    my ($db, %param) = @_;

    my $opts = get_options($db);

    if (my $max = $opts->{'max-envs'}) {
        my $total = count_envs($db, \&counts_towards_total);
        die "environment limit reached ($total/$max)\n" if $total >= $max;
    }

    if (my $max = $opts->{'max-creating'}) {
        my $creating = count_envs($db, sub { ($_[0]->{state} // '') eq 'creating' });
        die "too many environments being created concurrently ($creating/$max)\n"
            if $creating >= $max;
    }

    my $id = new_env_id($db, $param{rand});
    my $vmid = allocate_vmid($db, $param{used_ids} // {}, $param{lower}, $param{upper});

    my $env = {
        id => $id,
        vmid => $vmid,
        name => $param{name},
        state => 'creating',
        owner => $param{owner},
        created => $param{now} // time(),
    };
    for my $k (qw(template node description os request-id)) {
        $env->{$k} = $param{$k} if defined($param{$k});
    }

    $db->{environments}->{$id} = $env;

    return $env;
}

# Admission control for starting an environment, enforcing 'max-running'
# across concurrent requests. $running is a hash of VMIDs currently running.
# Returns 1 if no reservation is needed (already running), otherwise records
# a start reservation on the environment.
sub reserve_start {
    my ($db, $id, $running, $now) = @_;

    $now //= time();

    my $env = $db->{environments}->{$id} or die "environment '$id' does not exist\n";
    die "environment '$id' has no VM\n" if !defined($env->{vmid});

    return 1 if $running->{ $env->{vmid} };

    my $opts = get_options($db);
    if (my $max = $opts->{'max-running'}) {
        my $active = 0;
        for my $other (values $db->{environments}->%*) {
            next if $other->{id} eq $id;
            next if !defined($other->{vmid});
            if ($running->{ $other->{vmid} }) {
                $active++;
            } elsif (my $ts = $other->{'start-reserved'}) {
                $active++ if ($now - $ts) < $START_RESERVATION_TTL;
            }
        }
        die "running environment limit reached ($active/$max)\n" if $active >= $max;
    }

    $env->{'start-reserved'} = $now;
    return 0;
}

sub clear_start_reservation {
    my ($db, $id) = @_;
    my $env = $db->{environments}->{$id} or return;
    delete $env->{'start-reserved'};
}

# Combine a stored record with the live status of its VM (as returned by
# PVE::API2Tools::extract_vm_stats, or undef if the VM does not exist) into an
# API result entry. 'health' summarizes management state for the UI.
sub merge_status {
    my ($env, $vm) = @_;

    my $entry = { %$env };
    delete $entry->{'start-reserved'};

    my $state = $env->{state} // 'ready';

    if ($vm) {
        $entry->{node} = $vm->{node} if defined($vm->{node});
        $entry->{status} = $vm->{status} // 'unknown';
        for my $k (qw(cpu maxcpu mem maxmem disk maxdisk uptime netin netout lock)) {
            $entry->{$k} = $vm->{$k} if defined($vm->{$k});
        }
        $entry->{health} = $state eq 'ready' ? 'ok' : $state;
    } else {
        $entry->{status} = 'absent';
        if ($state eq 'ready') {
            # the record says managed, but the VM is gone: needs attention
            $entry->{health} = 'missing';
        } else {
            $entry->{health} = $state;
        }
    }

    return $entry;
}

1;
