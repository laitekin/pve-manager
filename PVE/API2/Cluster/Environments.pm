package PVE::API2::Cluster::Environments;

# Cluster-wide API for managed environments (see PVE::EnvManager).
#
# Guest operations (clone, config, start/stop, destroy) are not reimplemented
# here: they are delegated to the regular qemu-server API through a local API
# client acting with the caller's credentials, so all existing permission
# checks, locks and task logs of PVE stay in effect.

use strict;
use warnings;

use PVE::API2Tools;
use PVE::Cluster;
use PVE::Exception qw(raise_param_exc raise_perm_exc);
use PVE::INotify;
use PVE::JSONSchema qw(get_standard_option);
use PVE::ProcFSTools;
use PVE::RESTEnvironment qw(log_warn);
use PVE::RPCEnvironment;
use PVE::Tools qw(extract_param);
use PVE::UPID;

use PVE::EnvManager;
use PVE::API2::Cluster::BulkAction::Guest;

use base qw(PVE::RESTHandler);

PVE::JSONSchema::register_format(
    'pve-env-id',
    sub {
        my ($id, $noerr) = @_;
        if ($id !~ m/^env-[0-9a-f]{8}$/) {
            return undef if $noerr;
            die "invalid environment ID '$id'\n";
        }
        return $id;
    },
);

my $env_id_option = {
    description => "The environment ID.",
    type => 'string',
    format => 'pve-env-id',
};

my $env_properties = {
    id => $env_id_option,
    name => { type => 'string', description => "Environment (and VM) name." },
    vmid => get_standard_option('pve-vmid', { optional => 1 }),
    node => get_standard_option('pve-node', { optional => 1 }),
    template => get_standard_option('pve-vmid', {
            optional => 1,
            description => "The template the environment was cloned from.",
    }),
    os => {
        type => 'string',
        optional => 1,
        description => "Operating system family (windows, linux, ...).",
    },
    owner => get_standard_option('userid', { optional => 1 }),
    description => { type => 'string', optional => 1 },
    state => {
        type => 'string',
        enum => [qw(creating ready error deleting)],
        description => "Management state of the record.",
    },
    status => {
        type => 'string',
        optional => 1,
        description => "Live VM status ('running', 'stopped', ...; 'absent' if no VM exists).",
    },
    health => {
        type => 'string',
        optional => 1,
        description => "Summary for display: 'ok', 'missing' (VM vanished), 'creating',"
            . " 'error', 'deleting', 'proxy-failed' or 'exit-changed'.",
    },
    error => { type => 'string', optional => 1, description => "Last error, if any." },
    task => { type => 'string', optional => 1, description => "UPID of the last env task." },
    created => { type => 'integer', optional => 1 },
    'proxy-binding' => {
        type => 'object',
        optional => 1,
        description => "Bound proxy: 'proxy' ID, 'bound' time and the accepted 'exit-ip'.",
    },
    'proxy-state' => { type => 'string', optional => 1 },
    'proxy-label' => { type => 'string', optional => 1 },
    'exit-ip' => {
        type => 'string',
        optional => 1,
        description => "Last observed exit IP of the bound proxy.",
    },
};

my $get_vm_stats = sub {
    my $vmlist = PVE::Cluster::get_vmlist() || {};
    my $idlist = $vmlist->{ids} || {};
    my $rrd = PVE::Cluster::rrd_dump();

    my $stats = {};
    for my $vmid (keys %$idlist) {
        my $data = $idlist->{$vmid};
        $stats->{$vmid} = PVE::API2Tools::extract_vm_stats($vmid, $data, $rrd);
    }
    return $stats;
};

my $can_see_env = sub {
    my ($rpcenv, $authuser, $env) = @_;

    return 1 if $rpcenv->check($authuser, '/', ['Sys.Audit'], 1);
    return 1 if defined($env->{vmid}) && $rpcenv->check($authuser, "/vms/$env->{vmid}", ['VM.Audit'], 1);
    return 1 if defined($env->{owner}) && $env->{owner} eq $authuser;
    return 0;
};

my $check_env_priv = sub {
    my ($rpcenv, $authuser, $env, $privs) = @_;

    if (defined($env->{vmid})) {
        $rpcenv->check($authuser, "/vms/$env->{vmid}", $privs);
    } else {
        $rpcenv->check($authuser, '/vms', $privs);
    }
};

my $get_env = sub {
    my ($db, $id) = @_;
    my $env = $db->{environments}->{$id};
    raise_param_exc({ id => "environment '$id' does not exist" }) if !$env;
    return $env;
};

# true if the task is known to have ended; tasks on other nodes are assumed to
# still run (the record is then fixed by the worker or the next local check).
my $task_ended = sub {
    my ($upid) = @_;
    return 1 if !$upid;
    my $task = eval { PVE::UPID::decode($upid) } or return 1;
    return 0 if $task->{node} ne PVE::INotify::nodename();
    return PVE::ProcFSTools::check_process_running($task->{pid}, $task->{pstart}) ? 0 : 1;
};

# Mark records whose worker has died (e.g. node reboot during creation) as
# failed, so they neither stay 'creating' forever nor block the quota.
my $reconcile_stale = sub {
    my ($db, $stats) = @_;

    my $changed = 0;
    for my $env (values $db->{environments}->%*) {
        my $state = $env->{state} // '';
        next if $state ne 'creating' && $state ne 'deleting';
        next if !$env->{task} || !$task_ended->($env->{task});

        if ($state eq 'creating') {
            if (defined($env->{vmid}) && $stats->{ $env->{vmid} }) {
                # clone finished but the worker could not record it
                $env->{state} = 'ready';
            } else {
                $env->{state} = 'error';
                $env->{error} = 'creation was interrupted';
                delete $env->{vmid};
            }
        } else {
            $env->{state} = $stats->{ $env->{vmid} // -1 } ? 'ready' : 'error';
            $env->{error} = 'deletion was interrupted';
        }
        $changed = 1;
    }
    return $changed;
};

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    description => "Directory index.",
    permissions => { user => 'all' },
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => { name => { type => 'string' } },
        },
        links => [{ rel => 'child', href => "{name}" }],
    },
    code => sub {
        return [map { { name => $_ } } qw(action adopt envs options proxies proxy-check proxy-import templates)];
    },
});

__PACKAGE__->register_method({
    name => 'list',
    path => 'envs',
    method => 'GET',
    # may repair stale records, which needs write access to pmxcfs
    protected => 1,
    description => "List managed environments with their live VM status.",
    permissions => {
        description => "Only environments whose VM you can audit (VM.Audit), or that you own,"
            . " are listed. Sys.Audit on '/' shows all.",
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => {
                $env_properties->%*,
                cpu => { type => 'number', optional => 1 },
                maxcpu => { type => 'number', optional => 1 },
                mem => { type => 'integer', optional => 1 },
                maxmem => { type => 'integer', optional => 1 },
                disk => { type => 'integer', optional => 1 },
                maxdisk => { type => 'integer', optional => 1 },
                uptime => { type => 'integer', optional => 1 },
            },
        },
        links => [{ rel => 'child', href => "{id}" }],
    },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        my $stats = $get_vm_stats->();
        my $db = PVE::EnvManager::read_db();

        if ($reconcile_stale->($db, $stats)) {
            $db = PVE::EnvManager::lock_db(sub {
                my ($locked_db) = @_;
                $reconcile_stale->($locked_db, $stats);
                return $locked_db;
            });
        }

        my $res = [];
        for my $id (sort keys $db->{environments}->%*) {
            my $env = $db->{environments}->{$id};
            next if !$can_see_env->($rpcenv, $authuser, $env);
            my $vm = defined($env->{vmid}) ? $stats->{ $env->{vmid} } : undef;
            push @$res, PVE::EnvManager::merge_status($env, $vm, $db);
        }

        return $res;
    },
});

__PACKAGE__->register_method({
    name => 'templates',
    path => 'templates',
    method => 'GET',
    description => "List VM templates that can be used to create environments.",
    permissions => {
        description => "Only templates with VM.Clone permission are listed.",
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => {
                vmid => get_standard_option('pve-vmid'),
                node => get_standard_option('pve-node'),
                name => { type => 'string', optional => 1 },
                ostype => { type => 'string', optional => 1 },
                os => { type => 'string' },
                maxcpu => { type => 'number', optional => 1 },
                maxmem => { type => 'integer', optional => 1 },
                maxdisk => { type => 'integer', optional => 1 },
            },
        },
    },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        my $stats = $get_vm_stats->();
        my $props = PVE::Cluster::get_guest_config_properties(['ostype', 'template']);

        my $res = [];
        for my $vmid (sort { $a <=> $b } keys %$stats) {
            my $vm = $stats->{$vmid};
            next if $vm->{type} ne 'qemu';
            next if !$vm->{template} && !($props->{$vmid}->{template});
            next if !$rpcenv->check($authuser, "/vms/$vmid", ['VM.Clone'], 1);

            my $ostype = $props->{$vmid}->{ostype};
            push @$res, {
                vmid => $vmid + 0,
                node => $vm->{node},
                name => $vm->{name},
                ostype => $ostype,
                os => PVE::EnvManager::os_family($ostype),
                maxcpu => $vm->{maxcpu},
                maxmem => $vm->{maxmem},
                maxdisk => $vm->{maxdisk},
            };
        }
        return $res;
    },
});

my $option_properties = {
    'max-envs' => {
        description => "Maximum number of environments (0 = unlimited).",
        type => 'integer',
        minimum => 0,
        optional => 1,
    },
    'max-running' => {
        description => "Maximum number of concurrently running environments (0 = unlimited).",
        type => 'integer',
        minimum => 0,
        optional => 1,
    },
    'max-creating' => {
        description => "Maximum number of environments being created concurrently"
            . " (0 = unlimited).",
        type => 'integer',
        minimum => 0,
        optional => 1,
    },
    'proxy-check-url' => {
        description => "URL fetched through each proxy to determine its exit IP (JSON with"
            . " an 'ip' property, or a plain-text IP).",
        type => 'string',
        pattern => 'https?://\\S+',
        maxLength => 512,
        optional => 1,
    },
    'proxy-fail-threshold' => {
        description => "Consecutive failed checks after which a proxy is marked failed.",
        type => 'integer',
        minimum => 1,
        maximum => 100,
        optional => 1,
    },
    'proxy-fail-closed' => {
        description => "Refuse to start environments whose proxy is failed, expired or whose"
            . " exit IP changed.",
        type => 'boolean',
        optional => 1,
    },
};

__PACKAGE__->register_method({
    name => 'get_options',
    path => 'options',
    method => 'GET',
    description => "Get environment limits.",
    permissions => { user => 'all' },
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => {
        type => 'object',
        properties => $option_properties,
    },
    code => sub {
        my $db = PVE::EnvManager::read_db();
        my $opts = PVE::EnvManager::get_options($db);
        $opts->{'proxy-fail-closed'} = $opts->{'proxy-fail-closed'} ? 1 : 0;
        return $opts;
    },
});

__PACKAGE__->register_method({
    name => 'set_options',
    path => 'options',
    method => 'PUT',
    description => "Set environment limits.",
    permissions => {
        check => ['perm', '/', ['Sys.Modify']],
    },
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => $option_properties,
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        PVE::EnvManager::lock_db(sub {
            my ($db) = @_;
            for my $k (keys %$option_properties) {
                $db->{options}->{$k} = $param->{$k} if defined($param->{$k});
            }
        });
        return undef;
    },
});

__PACKAGE__->register_method({
    name => 'create',
    path => 'envs',
    method => 'POST',
    description => "Create one or more environments by cloning a VM template.",
    permissions => {
        description => "Requires VM.Allocate on '/vms', plus everything the qemu clone, config"
            . " and start API calls require (VM.Clone on the template, ...).",
        check => ['perm', '/vms', ['VM.Allocate']],
    },
    protected => 1,
    expose_credentials => 1,
    parameters => {
        additionalProperties => 0,
        properties => {
            template => get_standard_option('pve-vmid', {
                    description => "VMID of the template to clone.",
            }),
            name => {
                type => 'string',
                format => 'dns-name',
                description => "Name for the environment. With 'count' > 1, '-<n>' is appended.",
            },
            count => {
                type => 'integer',
                minimum => 1,
                maximum => 100,
                default => 1,
                optional => 1,
                description => "Number of environments to create.",
            },
            target => get_standard_option('pve-node', {
                    optional => 1,
                    description => "Target node (defaults to the template's node; requires"
                        . " shared storage for a different node).",
            }),
            storage => get_standard_option('pve-storage-id', {
                    optional => 1,
                    description => "Target storage for a full clone.",
            }),
            full => {
                type => 'boolean',
                optional => 1,
                default => 1,
                description => "Create a full copy instead of a linked clone.",
            },
            cores => {
                type => 'integer',
                minimum => 1,
                maximum => 8192,
                optional => 1,
                description => "Override the number of CPU cores per socket.",
            },
            memory => {
                type => 'integer',
                minimum => 16,
                optional => 1,
                description => "Override the memory size in MiB.",
            },
            description => {
                type => 'string',
                maxLength => 8192,
                optional => 1,
            },
            start => {
                type => 'boolean',
                optional => 1,
                default => 0,
                description => "Start the environments after creation.",
            },
            'request-id' => {
                type => 'string',
                pattern => '[A-Za-z0-9_.:-]{1,64}',
                optional => 1,
                description => "Client generated idempotency key. Repeating a request with the"
                    . " same key does not create duplicates (count is then ignored).",
            },
            'max-workers' => {
                type => 'integer',
                minimum => 1,
                maximum => 16,
                default => 2,
                optional => 1,
                description => "Maximum number of clone tasks running in parallel.",
            },
        },
    },
    returns => {
        type => 'string',
        description => "UPID of the worker.",
    },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        my $template = $param->{template};
        my $count = $param->{count} // 1;
        my $full = $param->{full} // 1;
        my $request_id = $param->{'request-id'};

        my $vmlist = PVE::Cluster::get_vmlist() || {};
        my $tmpl_info = $vmlist->{ids}->{$template}
            or raise_param_exc({ template => "VM $template does not exist" });
        raise_param_exc({ template => "VM $template is not a QEMU VM" })
            if $tmpl_info->{type} ne 'qemu';

        my $tmpl_node = $tmpl_info->{node};
        my $ostype =
            ((PVE::Cluster::get_guest_config_property('ostype', $template) // {})->{$template} // {})
            ->{ostype};

        $rpcenv->check($authuser, "/vms/$template", ['VM.Clone']);

        # reserve all records up front, so concurrent requests cannot overshoot
        # the limits and the client immediately sees the queued environments.
        my $dc_conf = PVE::Cluster::cfs_read_file('datacenter.cfg');
        my $next_id = $dc_conf->{'next-id'} // {};

        my $envs = PVE::EnvManager::lock_db(sub {
            my ($db) = @_;

            if (defined($request_id)) {
                my $existing = PVE::EnvManager::find_by_request_id($db, $request_id);
                if ($existing) {
                    my @all = grep {
                        ($_->{'request-id'} // '') eq $request_id
                    } values $db->{environments}->%*;
                    return { existing => [sort { $a->{vmid} <=> $b->{vmid} } @all] };
                }
            }

            my $used = (PVE::Cluster::get_vmlist() || {})->{ids} || {};
            my $res = [];
            for my $i (1 .. $count) {
                my $name = $count > 1 ? "$param->{name}-$i" : $param->{name};
                push @$res, PVE::EnvManager::reserve_creation(
                    $db,
                    name => $name,
                    owner => $authuser,
                    template => $template,
                    node => $param->{target} // $tmpl_node,
                    description => $param->{description},
                    os => PVE::EnvManager::os_family($ostype),
                    'request-id' => $request_id,
                    used_ids => $used,
                    lower => $next_id->{lower},
                    upper => $next_id->{upper},
                );
            }
            return { new => $res };
        });

        if (my $existing = $envs->{existing}) {
            my $ids = join(', ', map { $_->{id} } @$existing);
            my $upid = $existing->[0]->{task};
            return $upid if $upid;
            die "request '$request_id' was already processed: $ids\n";
        }
        $envs = $envs->{new};

        my $worker = sub {
            my $upid = shift;

            PVE::EnvManager::lock_db(sub {
                my ($db) = @_;
                $db->{environments}->{ $_->{id} }->{task} = $upid for @$envs;
            });

            my $api_client = PVE::API2::Cluster::BulkAction::Guest::create_client();

            my $by_vmid = { map { $_->{vmid} => $_ } @$envs };
            my $startlist = {
                0 => { map { $_->{vmid} => { node => $tmpl_node, type => 'qemu' } } @$envs },
            };

            my $set_result = sub {
                my ($id, $state, $error) = @_;
                PVE::EnvManager::lock_db(sub {
                    my ($db) = @_;
                    my $env = $db->{environments}->{$id} or return;
                    $env->{state} = $state;
                    if (defined($error)) {
                        $env->{error} = $error;
                        delete $env->{vmid} if $state eq 'error';
                    } else {
                        delete $env->{error};
                    }
                });
            };

            my $start_task = sub {
                my ($client, $vmid, $guest) = @_;
                my $env = $by_vmid->{$vmid};

                my $clone_param = {
                    newid => $vmid,
                    name => $env->{name},
                    full => $full ? 1 : 0,
                };
                $clone_param->{target} = $param->{target} if $param->{target};
                $clone_param->{storage} = $param->{storage} if $param->{storage};
                $clone_param->{description} = $param->{description}
                    if defined($param->{description});

                print "Creating environment $env->{id} '$env->{name}' as VM $vmid\n";
                my $res = eval {
                    $client->post("/nodes/$tmpl_node/qemu/$template/clone", $clone_param);
                };
                if (my $err = $@) {
                    log_warn("environment $env->{id}: clone failed - $err");
                    $set_result->($env->{id}, 'error', "clone failed - $err");
                    return undef;
                }
                return $res;
            };

            my $created = [];
            my $check_task = sub {
                my ($client, $vmid, $guest, $is_error, $task) = @_;
                my $env = $by_vmid->{$vmid};

                if ($is_error) {
                    my $err = $task ? $task->{exitstatus} : 'could not query task status';
                    log_warn("environment $env->{id}: clone failed - $err\n");
                    $set_result->($env->{id}, 'error', "clone failed - $err");
                    return;
                }

                my $node = $param->{target} // $tmpl_node;
                my $conf = {};
                $conf->{cores} = $param->{cores} if $param->{cores};
                $conf->{memory} = $param->{memory} if $param->{memory};
                if (scalar(keys %$conf)) {
                    eval { $client->put("/nodes/$node/qemu/$vmid/config", $conf) };
                    if (my $err = $@) {
                        # the VM exists: keep it managed, but report the problem
                        log_warn("environment $env->{id}: setting resources failed - $err");
                        $set_result->($env->{id}, 'ready', "setting resources failed - $err");
                        return;
                    }
                }

                print "Environment $env->{id} created (VM $vmid on node $node)\n";
                $set_result->($env->{id}, 'ready', undef);
                push @$created, $env;
            };

            my $max_workers = $param->{'max-workers'} // 2;
            my $failed = PVE::API2::Cluster::BulkAction::Guest::handle_task_foreach_guest($startlist, $max_workers, $start_task, $check_task);

            if ($param->{start} && scalar(@$created)) {
                print "Starting created environments\n";
                my $start_failed = start_envs($api_client, [map { $_->{id} } @$created],
                    $max_workers);
                push @$failed, @$start_failed;
            }

            if (scalar(@$failed)) {
                die "some environments failed: VM " . join(', ', @$failed) . "\n";
            }
        };

        my $upid = eval { $rpcenv->fork_worker('envcreate', undef, $authuser, $worker) };
        if (my $err = $@) {
            PVE::EnvManager::lock_db(sub {
                my ($db) = @_;
                for my $env (@$envs) {
                    my $cur = $db->{environments}->{ $env->{id} } or next;
                    $cur->{state} = 'error';
                    $cur->{error} = "unable to start worker - $err";
                    delete $cur->{vmid};
                }
            });
            die $err;
        }
        return $upid;
    },
});

# Start the given environments, enforcing the 'max-running' limit.
# Returns the list of VMIDs that failed.
sub start_envs {
    my ($api_client, $ids, $max_workers, $timeout) = @_;

    my $stats = $get_vm_stats->();
    my $db = PVE::EnvManager::read_db();

    my $startlist = { 0 => {} };
    my $vmid_to_id = {};
    for my $id (@$ids) {
        my $env = $db->{environments}->{$id};
        if (!$env) {
            log_warn("environment $id does not exist\n");
            next;
        }
        my $vmid = $env->{vmid};
        if (!defined($vmid) || !$stats->{$vmid}) {
            log_warn("environment $id: VM " . ($vmid // '-') . " does not exist\n");
            next;
        }
        $startlist->{0}->{$vmid} = { node => $stats->{$vmid}->{node}, type => 'qemu' };
        $vmid_to_id->{$vmid} = $id;
    }

    my $start_task = sub {
        my ($client, $vmid, $guest) = @_;
        my $id = $vmid_to_id->{$vmid};

        my $running = {};
        my $cur = $get_vm_stats->();
        for my $v (keys %$cur) {
            $running->{$v} = 1 if ($cur->{$v}->{status} // '') eq 'running';
        }

        my $already = PVE::EnvManager::lock_db(sub {
            my ($locked_db) = @_;
            my $env = $locked_db->{environments}->{$id} or die "environment '$id' vanished\n";
            if (!$running->{$vmid}) {
                my $err = PVE::EnvManager::check_start_allowed($locked_db, $env);
                die "not starting environment $id: $err\n" if $err;
            }
            return PVE::EnvManager::reserve_start($locked_db, $id, $running);
        });
        if ($already) {
            print "Environment $id (VM $vmid) already running\n";
            return 1;
        }

        print "Starting environment $id (VM $vmid)\n";
        my $params = {};
        $params->{timeout} = $timeout if defined($timeout);
        return $client->post("/nodes/$guest->{node}/qemu/$vmid/status/start", $params);
    };

    my $check_task = sub {
        my ($client, $vmid, $guest, $is_error, $task) = @_;
        my $id = $vmid_to_id->{$vmid};
        PVE::EnvManager::lock_db(sub {
            my ($locked_db) = @_;
            PVE::EnvManager::clear_start_reservation($locked_db, $id);
        });
        if ($is_error) {
            my $err = $task ? $task->{exitstatus} : 'could not query task status';
            log_warn("starting environment $id (VM $vmid) failed: $err\n");
        }
    };

    my $failed = PVE::API2::Cluster::BulkAction::Guest::handle_task_foreach_guest($startlist, $max_workers // 4, $start_task, $check_task);

    # reservations of starts that failed before a task was created
    PVE::EnvManager::lock_db(sub {
        my ($locked_db) = @_;
        PVE::EnvManager::clear_start_reservation($locked_db, $vmid_to_id->{$_}) for @$failed;
    });

    return $failed;
}

__PACKAGE__->register_method({
    name => 'action',
    path => 'action',
    method => 'POST',
    description => "Run a power action on one or more environments, with a result per"
        . " environment in the task log.",
    permissions => {
        description => "Requires VM.PowerMgmt on each environment's VM.",
        user => 'all',
    },
    protected => 1,
    expose_credentials => 1,
    parameters => {
        additionalProperties => 0,
        properties => {
            action => {
                type => 'string',
                enum => [qw(start shutdown stop reboot)],
            },
            ids => {
                type => 'array',
                items => $env_id_option,
                description => "The environments to act on.",
            },
            'max-workers' => {
                type => 'integer',
                minimum => 1,
                maximum => 64,
                default => 4,
                optional => 1,
            },
        },
    },
    returns => {
        type => 'string',
        description => "UPID of the worker.",
    },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        my $action = $param->{action};
        my $ids = $param->{ids};
        raise_param_exc({ ids => "no environment given" }) if !scalar(@$ids);

        my $db = PVE::EnvManager::read_db();
        for my $id (@$ids) {
            my $env = $get_env->($db, $id);
            raise_param_exc({ ids => "environment '$id' has no VM" }) if !defined($env->{vmid});
            $check_env_priv->($rpcenv, $authuser, $env, ['VM.PowerMgmt']);
        }

        my $max_workers = $param->{'max-workers'} // 4;

        my $worker = sub {
            my $api_client = PVE::API2::Cluster::BulkAction::Guest::create_client();

            my $failed;
            if ($action eq 'start') {
                $failed = start_envs($api_client, $ids, $max_workers);
            } else {
                my $stats = $get_vm_stats->();
                my $startlist = { 0 => {} };
                my $vmid_to_id = {};
                for my $id (@$ids) {
                    my $vmid = $db->{environments}->{$id}->{vmid};
                    if (!$stats->{$vmid}) {
                        log_warn("environment $id: VM $vmid does not exist\n");
                        next;
                    }
                    $startlist->{0}->{$vmid} = { node => $stats->{$vmid}->{node}, type => 'qemu' };
                    $vmid_to_id->{$vmid} = $id;
                }

                my $start_task = sub {
                    my ($client, $vmid, $guest) = @_;
                    my $status = $client->get("/nodes/$guest->{node}/qemu/$vmid/status/current");
                    if ($status->{status} ne 'running') {
                        print "Environment $vmid_to_id->{$vmid} (VM $vmid) is not running\n";
                        return 1;
                    }
                    print "Environment $vmid_to_id->{$vmid} (VM $vmid): $action\n";
                    return $client->post("/nodes/$guest->{node}/qemu/$vmid/status/$action", {});
                };
                my $check_task = sub {
                    my ($client, $vmid, $guest, $is_error, $task) = @_;
                    if ($is_error) {
                        my $err = $task ? $task->{exitstatus} : 'could not query task status';
                        log_warn("environment $vmid_to_id->{$vmid} (VM $vmid): $action failed: $err\n");
                    }
                };

                $failed = PVE::API2::Cluster::BulkAction::Guest::handle_task_foreach_guest($startlist, $max_workers, $start_task, $check_task);
            }

            if (scalar(@$failed)) {
                die "$action failed for VM " . join(', ', @$failed) . "\n";
            }
        };

        return $rpcenv->fork_worker("env$action", undef, $authuser, $worker);
    },
});

__PACKAGE__->register_method({
    name => 'adopt',
    path => 'adopt',
    method => 'POST',
    description => "Register an existing VM as managed environment.",
    permissions => {
        description => "Requires VM.Allocate on the VM.",
        user => 'all',
    },
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => {
            vmid => get_standard_option('pve-vmid'),
            name => { type => 'string', maxLength => 128, optional => 1 },
            description => { type => 'string', maxLength => 8192, optional => 1 },
            owner => get_standard_option('userid', { optional => 1 }),
        },
    },
    returns => $env_id_option,
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        my $vmid = $param->{vmid};
        $rpcenv->check($authuser, "/vms/$vmid", ['VM.Allocate']);

        my $stats = $get_vm_stats->();
        my $vm = $stats->{$vmid} or raise_param_exc({ vmid => "VM $vmid does not exist" });
        raise_param_exc({ vmid => "VM $vmid is not a QEMU VM" }) if $vm->{type} ne 'qemu';
        raise_param_exc({ vmid => "VM $vmid is a template" }) if $vm->{template};

        my $ostype =
            ((PVE::Cluster::get_guest_config_property('ostype', $vmid) // {})->{$vmid} // {})
            ->{ostype};

        return PVE::EnvManager::lock_db(sub {
            my ($db) = @_;
            if (my $existing = PVE::EnvManager::find_by_vmid($db, $vmid)) {
                raise_param_exc({ vmid => "VM $vmid is already managed as $existing->{id}" });
            }
            my $id = PVE::EnvManager::new_env_id($db);
            $db->{environments}->{$id} = {
                id => $id,
                vmid => $vmid,
                name => $param->{name} // $vm->{name} // "vm$vmid",
                node => $vm->{node},
                os => PVE::EnvManager::os_family($ostype),
                owner => $param->{owner} // $authuser,
                state => 'ready',
                created => time(),
                (defined($param->{description}) ? (description => $param->{description}) : ()),
            };
            return $id;
        });
    },
});

__PACKAGE__->register_method({
    name => 'read',
    path => 'envs/{id}',
    method => 'GET',
    description => "Get an environment.",
    permissions => {
        description => "Requires VM.Audit on the environment's VM, or ownership.",
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => { id => $env_id_option },
    },
    returns => { type => 'object', properties => $env_properties },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        my $db = PVE::EnvManager::read_db();
        my $env = $get_env->($db, $param->{id});
        raise_perm_exc() if !$can_see_env->($rpcenv, $authuser, $env);

        my $stats = $get_vm_stats->();
        my $vm = defined($env->{vmid}) ? $stats->{ $env->{vmid} } : undef;
        return PVE::EnvManager::merge_status($env, $vm, $db);
    },
});

__PACKAGE__->register_method({
    name => 'update',
    path => 'envs/{id}',
    method => 'PUT',
    description => "Update environment metadata.",
    permissions => {
        description => "Requires VM.Config.Options on the environment's VM. Changing the"
            . " owner requires Permissions.Modify on '/vms'.",
        user => 'all',
    },
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => {
            id => $env_id_option,
            name => { type => 'string', maxLength => 128, optional => 1 },
            description => { type => 'string', maxLength => 8192, optional => 1 },
            owner => get_standard_option('userid', { optional => 1 }),
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        PVE::EnvManager::lock_db(sub {
            my ($db) = @_;
            my $env = $get_env->($db, $param->{id});
            $check_env_priv->($rpcenv, $authuser, $env, ['VM.Config.Options']);

            if (defined($param->{owner})) {
                $rpcenv->check($authuser, '/vms', ['Permissions.Modify']);
                $env->{owner} = $param->{owner};
            }
            $env->{name} = $param->{name} if defined($param->{name});
            if (defined($param->{description})) {
                if ($param->{description} eq '') {
                    delete $env->{description};
                } else {
                    $env->{description} = $param->{description};
                }
            }
        });
        return undef;
    },
});

__PACKAGE__->register_method({
    name => 'delete',
    path => 'envs/{id}',
    method => 'DELETE',
    description => "Delete an environment. By default, its VM is stopped and destroyed.",
    permissions => {
        description => "Requires VM.Allocate on the environment's VM.",
        user => 'all',
    },
    protected => 1,
    expose_credentials => 1,
    parameters => {
        additionalProperties => 0,
        properties => {
            id => $env_id_option,
            'keep-vm' => {
                type => 'boolean',
                optional => 1,
                default => 0,
                description => "Only remove the environment record and keep the VM.",
            },
        },
    },
    returns => {
        type => 'string',
        optional => 1,
        description => "UPID of the worker, if the VM is destroyed.",
    },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();
        my $id = $param->{id};

        my $db = PVE::EnvManager::read_db();
        my $env = $get_env->($db, $id);
        $check_env_priv->($rpcenv, $authuser, $env, ['VM.Allocate']);

        my $stats = $get_vm_stats->();
        my $vmid = $env->{vmid};
        my $vm = defined($vmid) ? $stats->{$vmid} : undef;

        my $remove_record = sub {
            PVE::EnvManager::lock_db(sub {
                my ($locked_db) = @_;
                delete $locked_db->{environments}->{$id};
            });
        };

        if ($param->{'keep-vm'} || !$vm) {
            die "environment is being created, cannot remove it now\n"
                if ($env->{state} // '') eq 'creating' && !$task_ended->($env->{task});
            $remove_record->();
            return undef;
        }

        die "VM $vmid is a template, refusing to destroy it\n" if $vm->{template};

        PVE::EnvManager::lock_db(sub {
            my ($locked_db) = @_;
            my $cur = $get_env->($locked_db, $id);
            die "environment is busy ($cur->{state})\n"
                if $cur->{state} ne 'ready' && $cur->{state} ne 'error';
            $cur->{state} = 'deleting';
        });

        my $worker = sub {
            my $upid = shift;

            PVE::EnvManager::lock_db(sub {
                my ($locked_db) = @_;
                $locked_db->{environments}->{$id}->{task} = $upid
                    if $locked_db->{environments}->{$id};
            });

            my $client = PVE::API2::Cluster::BulkAction::Guest::create_client();
            my $node = $vm->{node};

            eval {
                my $status = $client->get("/nodes/$node/qemu/$vmid/status/current");
                if ($status->{status} eq 'running') {
                    print "Stopping VM $vmid\n";
                    my $stop = $client->post("/nodes/$node/qemu/$vmid/status/stop", {});
                    my $task = PVE::API2::Cluster::BulkAction::Guest::wait_for_task_finished($client, $node, $stop);
                    die "stopping VM $vmid failed: $task->{exitstatus}\n"
                        if PVE::UPID::status_is_error($task->{exitstatus});
                }

                print "Destroying VM $vmid\n";
                my $destroy = $client->delete(
                    "/nodes/$node/qemu/$vmid",
                    { purge => 1, 'destroy-unreferenced-disks' => 1 },
                );
                my $task = PVE::API2::Cluster::BulkAction::Guest::wait_for_task_finished($client, $node, $destroy);
                die "destroying VM $vmid failed: $task->{exitstatus}\n"
                    if PVE::UPID::status_is_error($task->{exitstatus});
            };
            if (my $err = $@) {
                PVE::EnvManager::lock_db(sub {
                    my ($locked_db) = @_;
                    my $cur = $locked_db->{environments}->{$id} or return;
                    $cur->{state} = 'ready';
                    $cur->{error} = "delete failed - $err";
                });
                die $err;
            }

            $remove_record->();
            print "Environment $id removed\n";
        };

        my $upid = eval { $rpcenv->fork_worker('envdestroy', $vmid, $authuser, $worker) };
        if (my $err = $@) {
            PVE::EnvManager::lock_db(sub {
                my ($locked_db) = @_;
                my $cur = $locked_db->{environments}->{$id} or return;
                $cur->{state} = 'ready';
            });
            die $err;
        }
        return $upid;
    },
});

# ---------------------------------------------------------------------------
# proxy pool
# ---------------------------------------------------------------------------

PVE::JSONSchema::register_format(
    'pve-env-proxy-id',
    sub {
        my ($id, $noerr) = @_;
        if ($id !~ m/^px-[0-9a-f]{8}$/) {
            return undef if $noerr;
            die "invalid proxy ID '$id'\n";
        }
        return $id;
    },
);

my $proxy_id_option = {
    description => "The proxy ID.",
    type => 'string',
    format => 'pve-env-proxy-id',
};

my $proxy_meta_properties = {
    provider => {
        type => 'string',
        maxLength => 64,
        optional => 1,
        description => "Provider name, for reference.",
    },
    region => {
        type => 'string',
        maxLength => 64,
        optional => 1,
        description => "Region/country as declared by the provider.",
    },
    notes => { type => 'string', maxLength => 1024, optional => 1 },
    expires => {
        type => 'integer',
        minimum => 0,
        optional => 1,
        description => "Lease end as UNIX epoch (0 = no expiry). Expired proxies are"
            . " treated as unusable.",
    },
    'max-bindings' => {
        type => 'integer',
        minimum => 0,
        maximum => 1000,
        optional => 1,
        description => "How many environments may use this proxy (0 = unlimited,"
            . " default 1 = exclusive).",
    },
};

my $proxy_endpoint_properties = {
    type => {
        type => 'string',
        enum => [qw(http https socks5)],
        optional => 1,
        description => "Proxy protocol.",
    },
    host => {
        type => 'string',
        pattern => '[A-Za-z0-9.:_-]+',
        maxLength => 255,
        optional => 1,
    },
    port => { type => 'integer', minimum => 1, maximum => 65535, optional => 1 },
    username => { type => 'string', maxLength => 255, optional => 1 },
    password => { type => 'string', maxLength => 255, optional => 1 },
};

my $proxy_public = sub {
    my ($db, $proxy) = @_;
    my $entry = { %$proxy };
    delete $entry->{'exit-history'};
    $entry->{label} = PVE::EnvManager::proxy_label($proxy);
    $entry->{bindings} = PVE::EnvManager::proxy_bindings($db, $proxy->{id});
    $entry->{expired} = 1 if PVE::EnvManager::proxy_is_expired($proxy);
    return $entry;
};

__PACKAGE__->register_method({
    name => 'proxy_list',
    path => 'proxies',
    method => 'GET',
    description => "List the proxy pool (without credentials).",
    permissions => {
        description => "Requires Sys.Audit on '/', or VM.Config.Network on '/vms' (to pick a"
            . " proxy for an environment).",
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => {
        type => 'array',
        items => { type => 'object', properties => { id => $proxy_id_option } },
        links => [{ rel => 'child', href => "{id}" }],
    },
    code => sub {
        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        raise_perm_exc("/, Sys.Audit")
            if !$rpcenv->check($authuser, '/', ['Sys.Audit'], 1)
            && !$rpcenv->check($authuser, '/vms', ['VM.Config.Network'], 1);

        my $db = PVE::EnvManager::read_db();
        return [map { $proxy_public->($db, $db->{proxies}->{$_}) } sort keys $db->{proxies}->%*];
    },
});

my $store_password = sub {
    my ($proxy_id, $password) = @_;
    my $secrets = PVE::EnvManager::read_secrets();
    if (defined($password) && $password ne '') {
        $secrets->{$proxy_id} = { password => $password };
    } else {
        delete $secrets->{$proxy_id};
    }
    PVE::EnvManager::write_secrets($secrets);
};

my $add_proxy_locked = sub {
    my ($param) = @_;

    my $password = delete $param->{password};
    return PVE::EnvManager::lock_db(sub {
        my ($db) = @_;
        my $proxy = PVE::EnvManager::add_proxy($db, $param);
        $proxy->{'has-password'} = 1 if defined($password) && $password ne '';
        $store_password->($proxy->{id}, $password);
        return $proxy->{id};
    });
};

__PACKAGE__->register_method({
    name => 'proxy_create',
    path => 'proxies',
    method => 'POST',
    description => "Add a proxy to the pool, either via 'url' or via type/host/port.",
    permissions => {
        check => ['perm', '/', ['Sys.Modify']],
    },
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => {
            url => {
                type => 'string',
                maxLength => 1024,
                optional => 1,
                description => "Proxy as 'type://user:pass\@host:port' or"
                    . " 'host:port[:user:pass]'.",
            },
            $proxy_endpoint_properties->%*,
            $proxy_meta_properties->%*,
        },
    },
    returns => $proxy_id_option,
    code => sub {
        my ($param) = @_;

        my $endpoint;
        if (defined(my $url = extract_param($param, 'url'))) {
            $endpoint = eval { PVE::EnvManager::parse_proxy_line($url, $param->{type}) };
            raise_param_exc({ url => "$@" }) if $@;
            for my $k (qw(host port username password)) {
                raise_param_exc({ $k => "cannot be combined with 'url'" })
                    if defined($param->{$k});
            }
        } else {
            for my $k (qw(type host port)) {
                raise_param_exc({ $k => "property is missing" }) if !defined($param->{$k});
            }
            $endpoint = {};
        }

        my $data = { %$param, %$endpoint };
        return $add_proxy_locked->($data);
    },
});

__PACKAGE__->register_method({
    name => 'proxy_import',
    path => 'proxy-import',
    method => 'POST',
    description => "Import multiple proxies, one per line. Lines that fail are reported, the"
        . " others are added.",
    permissions => {
        check => ['perm', '/', ['Sys.Modify']],
    },
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => {
            data => {
                type => 'string',
                maxLength => 1024 * 1024,
                description => "Proxy lines ('type://user:pass\@host:port' or"
                    . " 'host:port[:user:pass]'). Empty lines and lines starting with '#'"
                    . " are ignored.",
            },
            'default-type' => {
                type => 'string',
                enum => [qw(http https socks5)],
                default => 'http',
                optional => 1,
                description => "Type for lines without scheme.",
            },
            $proxy_meta_properties->%*,
        },
    },
    returns => {
        type => 'object',
        properties => {
            added => { type => 'array', items => $proxy_id_option },
            errors => { type => 'array', items => { type => 'string' } },
        },
    },
    code => sub {
        my ($param) = @_;

        my $data = extract_param($param, 'data');
        my $default_type = extract_param($param, 'default-type') // 'http';

        my $res = { added => [], errors => [] };
        my $lineno = 0;
        for my $line (split(/\r?\n/, $data)) {
            $lineno++;
            next if $line =~ m/^\s*(?:#|$)/;
            my $id = eval {
                my $endpoint = PVE::EnvManager::parse_proxy_line($line, $default_type);
                $add_proxy_locked->({ %$param, %$endpoint });
            };
            if (my $err = $@) {
                chomp $err;
                push $res->{errors}->@*, "line $lineno: $err";
            } else {
                push $res->{added}->@*, $id;
            }
        }
        return $res;
    },
});

__PACKAGE__->register_method({
    name => 'proxy_read',
    path => 'proxies/{proxyid}',
    method => 'GET',
    description => "Get a proxy, including its exit IP history.",
    permissions => {
        check => ['perm', '/', ['Sys.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => { proxyid => $proxy_id_option },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my $db = PVE::EnvManager::read_db();
        my $proxy = $db->{proxies}->{ $param->{proxyid} }
            or raise_param_exc({ proxyid => "proxy does not exist" });
        my $entry = $proxy_public->($db, $proxy);
        $entry->{'exit-history'} = $proxy->{'exit-history'} // [];
        return $entry;
    },
});

__PACKAGE__->register_method({
    name => 'proxy_update',
    path => 'proxies/{proxyid}',
    method => 'PUT',
    description => "Update a proxy. Changing the endpoint keeps existing bindings, but resets"
        . " the observed state.",
    permissions => {
        check => ['perm', '/', ['Sys.Modify']],
    },
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => {
            proxyid => $proxy_id_option,
            $proxy_endpoint_properties->%*,
            $proxy_meta_properties->%*,
            state => {
                type => 'string',
                enum => [qw(active disabled)],
                optional => 1,
                description => "Enable or disable the proxy. Re-enabling a failed proxy resets"
                    . " its failure counter.",
            },
            delete => {
                type => 'string',
                format => 'pve-configid-list',
                optional => 1,
                description => "Properties to remove (provider, region, notes, expires,"
                    . " username, password).",
            },
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my $id = extract_param($param, 'proxyid');
        my $delete = [PVE::Tools::split_list(extract_param($param, 'delete') // '')];
        my $password = extract_param($param, 'password');

        PVE::EnvManager::lock_db(sub {
            my ($db) = @_;
            my $proxy = $db->{proxies}->{$id}
                or raise_param_exc({ proxyid => "proxy does not exist" });

            my $endpoint_changed = 0;
            for my $k (qw(type host port username)) {
                next if !defined($param->{$k});
                $endpoint_changed = 1 if ($proxy->{$k} // '') ne $param->{$k};
                $proxy->{$k} = $param->{$k};
            }
            for my $k (keys %$proxy_meta_properties) {
                $proxy->{$k} = $param->{$k} if defined($param->{$k});
            }
            for my $k (@$delete) {
                raise_param_exc({ delete => "cannot delete '$k'" })
                    if $k !~ m/^(?:provider|region|notes|expires|username|password)$/;
                if ($k eq 'password') {
                    $password = '';
                } else {
                    $endpoint_changed = 1 if $k eq 'username';
                    delete $proxy->{$k};
                }
            }

            if (defined($password)) {
                $store_password->($id, $password);
                if ($password ne '') {
                    $proxy->{'has-password'} = 1;
                } else {
                    delete $proxy->{'has-password'};
                }
                $endpoint_changed = 1;
            }

            if (my $state = $param->{state}) {
                $proxy->{state} = $state;
                $proxy->{fails} = 0;
            }

            if ($endpoint_changed) {
                $proxy->{fails} = 0;
                delete $proxy->{'last-check'};
            }
        });
        return undef;
    },
});

__PACKAGE__->register_method({
    name => 'proxy_delete',
    path => 'proxies/{proxyid}',
    method => 'DELETE',
    description => "Remove a proxy from the pool.",
    permissions => {
        check => ['perm', '/', ['Sys.Modify']],
    },
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => {
            proxyid => $proxy_id_option,
            force => {
                type => 'boolean',
                optional => 1,
                default => 0,
                description => "Also remove existing bindings.",
            },
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;
        PVE::EnvManager::lock_db(sub {
            my ($db) = @_;
            PVE::EnvManager::remove_proxy($db, $param->{proxyid}, $param->{force});
            $store_password->($param->{proxyid}, undef);
        });
        return undef;
    },
});

# Fetch the check URL through the proxy using curl. The configuration,
# including credentials, is passed on stdin so that it does not show up in
# the process list.
sub run_proxy_check {
    my ($proxy, $password, $url, $timeout) = @_;

    $timeout //= 20;

    my $quote = sub {
        my ($str) = @_;
        $str =~ s/(["\\])/\\$1/g;
        return "\"$str\"";
    };

    my $scheme = $proxy->{type} eq 'socks5' ? 'socks5h' : $proxy->{type};
    my $host = $proxy->{host} =~ m/:/ ? "[$proxy->{host}]" : $proxy->{host};

    my $cfg = "silent\nshow-error\nfail\n";
    $cfg .= "proxy = " . $quote->("$scheme://$host:$proxy->{port}") . "\n";
    if (defined($proxy->{username})) {
        $cfg .= "proxy-user = " . $quote->("$proxy->{username}:" . ($password // '')) . "\n";
    }
    $cfg .= "max-time = $timeout\n";
    $cfg .= "url = " . $quote->($url) . "\n";
    $cfg .= "write-out = " . $quote->("\\n%{time_total}") . "\n";

    my $out = '';
    my $err = '';
    eval {
        PVE::Tools::run_command(
            ['curl', '--config', '-'],
            input => $cfg,
            outfunc => sub { $out .= "$_[0]\n" },
            errfunc => sub { $err .= "$_[0]\n" },
            timeout => $timeout + 10,
        );
    };
    if (my $cmd_err = $@) {
        $err =~ s/\s+$//;
        return { ok => 0, error => ($err ne '' ? $err : "$cmd_err") =~ s/\s+$//r };
    }

    $out =~ s/\s+$//;
    my ($body, $time) = $out =~ m/^(.*)\n([0-9.]+)$/s;
    return { ok => 0, error => "unexpected curl output" } if !defined($time);

    my $info = eval { PVE::EnvManager::parse_check_response($body) };
    if (my $parse_err = $@) {
        chomp $parse_err;
        return { ok => 0, error => $parse_err };
    }

    return { ok => 1, latency => int($time * 1000), %$info };
}

my $check_one = sub {
    my ($proxy_id) = @_;

    my $db = PVE::EnvManager::read_db();
    my $proxy = $db->{proxies}->{$proxy_id} or die "proxy '$proxy_id' does not exist\n";
    my $url = PVE::EnvManager::get_options($db)->{'proxy-check-url'};
    my $secrets = PVE::EnvManager::read_secrets();

    my $result =
        run_proxy_check($proxy, ($secrets->{$proxy_id} // {})->{password}, $url);

    my $events = PVE::EnvManager::lock_db(sub {
        my ($locked_db) = @_;
        return [] if !$locked_db->{proxies}->{$proxy_id}; # removed meanwhile
        return PVE::EnvManager::apply_check_result($locked_db, $proxy_id, $result);
    });

    return ($result, $events);
};

__PACKAGE__->register_method({
    name => 'proxy_check',
    path => 'proxies/{proxyid}/check',
    method => 'POST',
    description => "Check a proxy now: reachability, authentication, exit IP and latency.",
    permissions => {
        check => ['perm', '/', ['Sys.Modify']],
    },
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => { proxyid => $proxy_id_option },
    },
    returns => {
        type => 'object',
        properties => {
            ok => { type => 'boolean' },
            latency => { type => 'integer', optional => 1, description => "In milliseconds." },
            ip => { type => 'string', optional => 1 },
            country => { type => 'string', optional => 1 },
            region => { type => 'string', optional => 1 },
            city => { type => 'string', optional => 1 },
            error => { type => 'string', optional => 1 },
            events => { type => 'array', items => { type => 'string' } },
        },
    },
    code => sub {
        my ($param) = @_;
        my ($result, $events) = $check_one->($param->{proxyid});
        return { %$result, ok => $result->{ok} ? 1 : 0, events => $events };
    },
});

__PACKAGE__->register_method({
    name => 'proxy_check_all',
    path => 'proxy-check',
    method => 'POST',
    description => "Check all enabled proxies in a background task (used by the periodic"
        . " health check).",
    permissions => {
        check => ['perm', '/', ['Sys.Modify']],
    },
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => { type => 'string', description => "UPID of the worker." },
    code => sub {
        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        my $worker = sub {
            my $db = PVE::EnvManager::read_db();
            my $ids = [
                grep { $db->{proxies}->{$_}->{state} ne 'disabled' }
                    sort keys $db->{proxies}->%*
            ];
            print "checking " . scalar(@$ids) . " proxies\n";

            my $failed = 0;
            for my $id (@$ids) {
                my ($result, $events) = eval { $check_one->($id) };
                if (my $err = $@) {
                    log_warn("$id: $err");
                    $failed++;
                    next;
                }
                if ($result->{ok}) {
                    print "$id: ok, exit $result->{ip}, $result->{latency} ms\n";
                } else {
                    log_warn("$id: check failed - $result->{error}\n");
                    $failed++;
                }
                print "$_\n" for @$events;
            }
            print "$failed of " . scalar(@$ids) . " checks failed\n";
        };

        return $rpcenv->fork_worker('envproxycheck', undef, $authuser, $worker);
    },
});

# ---------------------------------------------------------------------------
# environment <-> proxy binding
# ---------------------------------------------------------------------------

__PACKAGE__->register_method({
    name => 'bind_proxy',
    path => 'envs/{id}/proxy',
    method => 'POST',
    description => "Bind a proxy to an environment for long-term use.",
    permissions => {
        description => "Requires VM.Config.Network on the environment's VM.",
        user => 'all',
    },
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => {
            id => $env_id_option,
            proxy => $proxy_id_option,
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        return PVE::EnvManager::lock_db(sub {
            my ($db) = @_;
            my $env = $get_env->($db, $param->{id});
            $check_env_priv->($rpcenv, $authuser, $env, ['VM.Config.Network']);
            return PVE::EnvManager::bind_proxy($db, $param->{id}, $param->{proxy});
        });
    },
});

__PACKAGE__->register_method({
    name => 'unbind_proxy',
    path => 'envs/{id}/proxy',
    method => 'DELETE',
    description => "Remove the proxy binding of an environment.",
    permissions => {
        description => "Requires VM.Config.Network on the environment's VM.",
        user => 'all',
    },
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => { id => $env_id_option },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        PVE::EnvManager::lock_db(sub {
            my ($db) = @_;
            my $env = $get_env->($db, $param->{id});
            $check_env_priv->($rpcenv, $authuser, $env, ['VM.Config.Network']);
            PVE::EnvManager::unbind_proxy($db, $param->{id});
        });
        return undef;
    },
});

__PACKAGE__->register_method({
    name => 'accept_exit_ip',
    path => 'envs/{id}/accept-exit-ip',
    method => 'POST',
    description => "Accept the bound proxy's current exit IP after it changed.",
    permissions => {
        description => "Requires VM.Config.Network on the environment's VM.",
        user => 'all',
    },
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => { id => $env_id_option },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        return PVE::EnvManager::lock_db(sub {
            my ($db) = @_;
            my $env = $get_env->($db, $param->{id});
            $check_env_priv->($rpcenv, $authuser, $env, ['VM.Config.Network']);
            return PVE::EnvManager::accept_exit_ip($db, $param->{id});
        });
    },
});

1;
