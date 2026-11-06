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

# proxy credentials live in the root-only part of pmxcfs
our $SECRETS_DIR = '/etc/pve/priv/env-manager';
our $SECRETS_PATH = "$SECRETS_DIR/proxy-secrets.json";
our $DB_VERSION = 1;

# a reservation for a start that was not confirmed within this time is
# considered stale (e.g. the worker was killed) and no longer counted.
our $START_RESERVATION_TTL = 600;

our $OPTION_DEFAULTS = {
    'max-envs' => 0, # 0 means unlimited
    'max-running' => 0,
    'max-creating' => 4,
    # URL fetched through each proxy to detect its exit IP. JSON answers with
    # 'ip' and optionally 'country'/'region'/'city' are understood, as is a
    # plain-text IP address.
    'proxy-check-url' => 'https://ipinfo.io/json',
    # consecutive failed checks after which a proxy is marked as failed
    'proxy-fail-threshold' => 3,
    # refuse to start environments whose bound proxy is failed/disabled
    'proxy-fail-closed' => 1,
};

# number of exit IP changes kept per proxy
our $EXIT_HISTORY_SIZE = 20;

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
        proxies => {},
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
    $db->{proxies} //= {};
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

my $new_id = sub {
    my ($prefix, $existing, $rand) = @_;

    $rand //= sub { int(rand(0xffffffff)) };

    for (1 .. 100) {
        my $id = sprintf('%s-%08x', $prefix, $rand->());
        return $id if !$existing->{$id};
    }
    die "unable to generate unique ID\n";
};

sub new_env_id {
    my ($db, $rand) = @_;
    return $new_id->('env', $db->{environments}, $rand);
}

sub new_proxy_id {
    my ($db, $rand) = @_;
    return $new_id->('px', $db->{proxies}, $rand);
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
    my ($env, $vm, $db) = @_;

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
        if ($entry->{health} eq 'ok' && $db) {
            my $proxy_health = binding_health($db, $env);
            $entry->{health} = $proxy_health if $proxy_health ne 'ok';
        }
    } else {
        $entry->{status} = 'absent';
        if ($state eq 'ready') {
            # the record says managed, but the VM is gone: needs attention
            $entry->{health} = 'missing';
        } else {
            $entry->{health} = $state;
        }
    }

    if ($db && (my $binding = $env->{'proxy-binding'})) {
        if (my $proxy = $db->{proxies}->{ $binding->{proxy} }) {
            $entry->{'proxy-state'} = $proxy->{state};
            $entry->{'proxy-label'} = proxy_label($proxy);
            $entry->{'exit-ip'} = $proxy->{'exit-ip'} if defined($proxy->{'exit-ip'});
        }
    }

    return $entry;
}

# ---------------------------------------------------------------------------
# proxy pool
#
# A proxy record describes an upstream proxy endpoint and its observed state:
#   { id, type, host, port, username, provider, region, notes, 'expires',
#     state => active|disabled|failed, fails, 'last-check' => {...},
#     'exit-ip', 'exit-country', 'exit-history' => [...] }
# Passwords are kept in a separate root-only file, keyed by proxy id.
#
# An environment binds to at most one proxy:
#   $env->{'proxy-binding'} = { proxy, bound, 'exit-ip' (accepted exit IP) }
# A proxy serves at most 'max-bindings' environments (default 1), so a
# long-term binding is not silently shared.
# ---------------------------------------------------------------------------

my $PROXY_TYPES = { http => 1, https => 1, socks5 => 1 };

sub proxy_label {
    my ($proxy) = @_;
    my $host = $proxy->{host} =~ m/:/ ? "[$proxy->{host}]" : $proxy->{host};
    return "$proxy->{type}://$host:$proxy->{port}";
}

# Parse one proxy line. Accepted forms:
#   type://[user[:pass]@]host:port
#   host:port[:user:pass]
# Returns a hash with type, host, port and optionally username/password.
sub parse_proxy_line {
    my ($line, $default_type) = @_;

    $default_type //= 'http';
    $line =~ s/^\s+|\s+$//g;
    die "empty proxy line\n" if $line eq '';

    my $res = {};
    my $rest = $line;
    if ($rest =~ s!^([a-z0-9]+)://!!i) {
        my $type = lc($1);
        $type = 'socks5' if $type eq 'socks5h' || $type eq 'socks';
        $res->{type} = $type;
        if ($rest =~ s/^(.*)@//) {
            my ($user, $pass) = split(/:/, $1, 2);
            $res->{username} = uri_unescape($user);
            $res->{password} = uri_unescape($pass) if defined($pass);
        }
        $rest =~ s!/+$!!;
        if ($rest =~ m/^\[([0-9a-fA-F:.]+)\]:(\d+)$/ || $rest =~ m/^([^:\[\]\s]+):(\d+)$/) {
            ($res->{host}, $res->{port}) = ($1, $2);
        } else {
            die "unable to parse proxy address '$rest'\n";
        }
    } else {
        my @parts = split(/:/, $rest);
        die "unable to parse proxy line '$line'\n" if @parts != 2 && @parts != 4;
        $res->{type} = $default_type;
        ($res->{host}, $res->{port}) = @parts[0, 1];
        if (@parts == 4) {
            ($res->{username}, $res->{password}) = @parts[2, 3];
        }
    }

    die "unsupported proxy type '$res->{type}'\n" if !$PROXY_TYPES->{ $res->{type} };
    die "invalid proxy host '$res->{host}'\n" if $res->{host} !~ m/^[A-Za-z0-9.:_-]+$/;
    die "invalid proxy port '$res->{port}'\n"
        if $res->{port} !~ m/^\d+$/ || $res->{port} < 1 || $res->{port} > 65535;
    $res->{port} += 0;

    return $res;
}

sub uri_unescape {
    my ($str) = @_;
    return $str if !defined($str);
    $str =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
    return $str;
}

sub find_proxy_by_endpoint {
    my ($db, $type, $host, $port, $username) = @_;
    for my $proxy (values $db->{proxies}->%*) {
        next if $proxy->{type} ne $type || lc($proxy->{host}) ne lc($host);
        next if $proxy->{port} != $port;
        next if ($proxy->{username} // '') ne ($username // '');
        return $proxy;
    }
    return undef;
}

# Add a proxy record; returns it. Dies on duplicates.
sub add_proxy {
    my ($db, $param, $rand) = @_;

    if (my $dup = find_proxy_by_endpoint(
        $db, $param->{type}, $param->{host}, $param->{port}, $param->{username},
    )) {
        die "proxy " . proxy_label($dup) . " already exists as $dup->{id}\n";
    }

    my $id = new_proxy_id($db, $rand);
    my $proxy = {
        id => $id,
        state => 'active',
        fails => 0,
    };
    for my $k (qw(type host port username provider region notes expires max-bindings)) {
        $proxy->{$k} = $param->{$k} if defined($param->{$k}) && $param->{$k} ne '';
    }
    $db->{proxies}->{$id} = $proxy;
    return $proxy;
}

sub proxy_bindings {
    my ($db, $proxy_id) = @_;
    my $res = [];
    for my $id (sort keys $db->{environments}->%*) {
        my $env = $db->{environments}->{$id};
        my $binding = $env->{'proxy-binding'} or next;
        push @$res, $id if $binding->{proxy} eq $proxy_id;
    }
    return $res;
}

sub proxy_is_expired {
    my ($proxy, $now) = @_;
    return 0 if !$proxy->{expires};
    return ($now // time()) >= $proxy->{expires} ? 1 : 0;
}

sub bind_proxy {
    my ($db, $env_id, $proxy_id, $now) = @_;

    $now //= time();

    my $env = $db->{environments}->{$env_id} or die "environment '$env_id' does not exist\n";
    my $proxy = $db->{proxies}->{$proxy_id} or die "proxy '$proxy_id' does not exist\n";

    if (my $cur = $env->{'proxy-binding'}) {
        return $cur if $cur->{proxy} eq $proxy_id;
        die "environment '$env_id' is already bound to proxy '$cur->{proxy}', unbind it first\n";
    }

    die "proxy '$proxy_id' is $proxy->{state}\n" if $proxy->{state} ne 'active';
    die "proxy '$proxy_id' has expired\n" if proxy_is_expired($proxy, $now);

    my $max = $proxy->{'max-bindings'} // 1;
    if ($max > 0) {
        my $count = scalar(proxy_bindings($db, $proxy_id)->@*);
        die "proxy '$proxy_id' is already used by $count environment(s)\n" if $count >= $max;
    }

    my $binding = { proxy => $proxy_id, bound => $now };
    $binding->{'exit-ip'} = $proxy->{'exit-ip'} if defined($proxy->{'exit-ip'});
    $env->{'proxy-binding'} = $binding;
    return $binding;
}

sub unbind_proxy {
    my ($db, $env_id) = @_;
    my $env = $db->{environments}->{$env_id} or die "environment '$env_id' does not exist\n";
    return delete $env->{'proxy-binding'};
}

# accept the proxy's current exit IP as the expected one for the binding
sub accept_exit_ip {
    my ($db, $env_id) = @_;
    my $env = $db->{environments}->{$env_id} or die "environment '$env_id' does not exist\n";
    my $binding = $env->{'proxy-binding'} or die "environment '$env_id' has no proxy\n";
    my $proxy = $db->{proxies}->{ $binding->{proxy} } or die "bound proxy does not exist\n";
    die "exit IP of proxy '$proxy->{id}' is not known yet\n" if !defined($proxy->{'exit-ip'});
    $binding->{'exit-ip'} = $proxy->{'exit-ip'};
    return $binding;
}

# Health of an environment's proxy binding: 'ok', 'proxy-failed' (proxy
# failed, disabled, removed or expired) or 'exit-changed' (the proxy's exit
# IP differs from the one accepted for this binding).
sub binding_health {
    my ($db, $env, $now) = @_;

    my $binding = $env->{'proxy-binding'} or return 'ok';
    my $proxy = $db->{proxies}->{ $binding->{proxy} } or return 'proxy-failed';

    return 'proxy-failed' if $proxy->{state} ne 'active' || proxy_is_expired($proxy, $now);

    my $expected = $binding->{'exit-ip'};
    my $actual = $proxy->{'exit-ip'};
    return 'exit-changed' if defined($expected) && defined($actual) && $expected ne $actual;

    return 'ok';
}

# Returns an error message if an environment must not be started because
# of its proxy binding (fail-closed), undef otherwise.
sub check_start_allowed {
    my ($db, $env, $now) = @_;

    my $opts = get_options($db);
    return undef if !$opts->{'proxy-fail-closed'};

    my $health = binding_health($db, $env, $now);
    return undef if $health eq 'ok';

    my $proxy_id = $env->{'proxy-binding'}->{proxy};
    return "bound proxy '$proxy_id' is not usable" if $health eq 'proxy-failed';
    return "exit IP of bound proxy '$proxy_id' changed, accept or rebind first"
        if $health eq 'exit-changed';
    return "proxy binding not healthy ($health)";
}

# Parse the body returned by the check URL into { ip, country, region, city }.
sub parse_check_response {
    my ($body) = @_;

    $body //= '';
    $body =~ s/^\s+|\s+$//g;

    my $res = {};
    if ($body =~ m/^\{/) {
        my $data = eval { JSON::decode_json($body) };
        die "invalid JSON from check URL\n" if !$data || ref($data) ne 'HASH';
        $res->{ip} = $data->{ip} // $data->{query} // $data->{origin};
        $res->{country} = $data->{country} // $data->{country_code} // $data->{countryCode};
        $res->{region} = $data->{region} // $data->{regionName};
        $res->{city} = $data->{city};
    } else {
        $res->{ip} = $body;
    }

    my $ip = $res->{ip} // '';
    die "check URL did not return an IP address\n"
        if $ip !~ m/^(?:\d{1,3}(?:\.\d{1,3}){3}|[0-9a-fA-F:]*:[0-9a-fA-F:.]+)$/;

    for my $k (keys %$res) {
        delete $res->{$k} if !defined($res->{$k}) || ref($res->{$k});
    }
    return $res;
}

# Apply a check result to a proxy. $result is either
#   { ok => 1, latency => ms, ip => ..., country => ..., ... }
# or { ok => 0, error => '...' }.
# Returns a list of event strings (for the task log).
sub apply_check_result {
    my ($db, $proxy_id, $result, $now) = @_;

    $now //= time();

    my $proxy = $db->{proxies}->{$proxy_id} or die "proxy '$proxy_id' does not exist\n";
    my $opts = get_options($db);
    my $events = [];

    my $check = { time => $now, ok => $result->{ok} ? 1 : 0 };
    $check->{latency} = $result->{latency} if defined($result->{latency});
    $check->{error} = $result->{error} if defined($result->{error});
    $proxy->{'last-check'} = $check;

    if (!$result->{ok}) {
        $proxy->{fails} = ($proxy->{fails} // 0) + 1;
        if ($proxy->{state} eq 'active' && $proxy->{fails} >= $opts->{'proxy-fail-threshold'}) {
            $proxy->{state} = 'failed';
            push @$events, "proxy $proxy_id marked as failed after $proxy->{fails} failed checks";
        }
        return $events;
    }

    $proxy->{fails} = 0;
    if ($proxy->{state} eq 'failed') {
        $proxy->{state} = 'active';
        push @$events, "proxy $proxy_id recovered";
    }

    my $ip = $result->{ip};
    my $old = $proxy->{'exit-ip'};
    if (defined($ip) && (!defined($old) || $old ne $ip)) {
        $proxy->{'exit-ip'} = $ip;
        $proxy->{'exit-since'} = $now;
        my $history = ($proxy->{'exit-history'} //= []);
        unshift @$history, { ip => $ip, time => $now };
        splice(@$history, $EXIT_HISTORY_SIZE) if @$history > $EXIT_HISTORY_SIZE;
        push @$events, defined($old)
            ? "proxy $proxy_id exit IP changed from $old to $ip"
            : "proxy $proxy_id exit IP is $ip";
    }
    for my $k (qw(country region city)) {
        if (defined($result->{$k})) {
            $proxy->{"exit-$k"} = $result->{$k};
        }
    }

    # first successful check after binding: remember the exit IP
    for my $env_id (proxy_bindings($db, $proxy_id)->@*) {
        my $binding = $db->{environments}->{$env_id}->{'proxy-binding'};
        $binding->{'exit-ip'} //= $ip if defined($ip);
        if (defined($binding->{'exit-ip'}) && defined($ip) && $binding->{'exit-ip'} ne $ip) {
            push @$events, "environment $env_id: exit IP differs from bound $binding->{'exit-ip'}";
        }
    }

    return $events;
}

sub remove_proxy {
    my ($db, $proxy_id, $force) = @_;
    $db->{proxies}->{$proxy_id} or die "proxy '$proxy_id' does not exist\n";
    my $bound = proxy_bindings($db, $proxy_id);
    if (scalar(@$bound)) {
        die "proxy '$proxy_id' is bound to " . join(', ', @$bound) . "\n" if !$force;
        delete $db->{environments}->{$_}->{'proxy-binding'} for @$bound;
    }
    delete $db->{proxies}->{$proxy_id};
    return $bound;
}

# --- secrets (root only) ---

sub read_secrets {
    return {} if !-f $SECRETS_PATH;
    require PVE::Tools;
    my $raw = PVE::Tools::file_get_contents($SECRETS_PATH);
    return {} if $raw !~ m/\S/;
    return JSON::decode_json($raw);
}

sub write_secrets {
    my ($secrets) = @_;
    require PVE::Tools;
    mkdir $SECRETS_DIR if !-d $SECRETS_DIR;
    PVE::Tools::file_set_contents($SECRETS_PATH, JSON->new->utf8->canonical->encode($secrets), 0600);
}

1;
