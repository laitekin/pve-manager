package PVE::API2::Egress;

use strict;
use warnings;
use JSON;
use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;
use PVE::Tools;
use base qw(PVE::RESTHandler);

# The adapter invokes one fixed executable with JSON on stdin. No shell or secret argv.
sub manage {
    my ($action, $payload) = @_;
    my $output = '';
    my $ok = eval {
        PVE::Tools::run_command(
            ['/opt/pve-egress/venv/bin/pve-egress-manage', $action],
            input => encode_json($payload // {}),
            outfunc => sub { $output .= shift; },
            errfunc => sub { },
            timeout => 120,
        );
        1;
    };
    my $result = eval { decode_json($output) };
    die "Egress management service is unavailable\n" if !$result;
    die(($result->{error} // 'Egress management failed') . "\n") if !$ok || $result->{error};
    return $result;
}

my $parameters = {
    additionalProperties => 0,
    properties => { node => get_standard_option('pve-node') },
};

__PACKAGE__->register_method({
    name => 'index', path => '', method => 'GET', protected => 1, proxyto => 'node',
    description => 'Read egress draft, runtime status and audit history without credentials.',
    permissions => { check => ['perm', '/nodes/{node}', ['Sys.Audit']] },
    parameters => $parameters,
    returns => { type => 'object', additionalProperties => 1, properties => {} },
    code => sub { return manage('view'); },
});

for my $operation (['save', 'config', 'PUT'], ['validate', 'validate', 'POST']) {
    my ($action, $path, $method) = @$operation;
    __PACKAGE__->register_method({
        name => $action, path => $path, method => $method, protected => 1, proxyto => 'node',
        description => 'Validate or save versioned egress configuration and write-only credentials.',
        permissions => { check => ['perm', '/nodes/{node}', ['Sys.Modify']] },
        parameters => {
            additionalProperties => 0,
            properties => {
                node => get_standard_option('pve-node'),
                document => { type => 'string', maxLength => 256000 },
            },
        },
        returns => { type => 'object', additionalProperties => 1, properties => {} },
        code => sub {
            my ($param) = @_;
            my $payload = eval { decode_json($param->{document}) };
            die "Invalid egress document\n" if ref($payload) ne 'HASH';
            $payload->{actor} = PVE::RPCEnvironment::get()->get_user() if $action eq 'save';
            return manage($action, $payload);
        },
    });
}

__PACKAGE__->register_method({
    name => 'apply', path => 'apply', method => 'POST', protected => 1, proxyto => 'node',
    description => 'Apply saved egress revision using preflight checks and a PVE worker.',
    permissions => { check => ['perm', '/nodes/{node}', ['Sys.Modify']] },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            revision => { type => 'integer', minimum => 0 },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;
        my $rpcenv = PVE::RPCEnvironment::get();
        my $user = $rpcenv->get_user();
        return $rpcenv->fork_worker('egressapply', undef, $user, sub {
            manage('apply', { revision => $param->{revision}, actor => $user });
            print "Egress configuration applied; awaiting per-environment health checks\n";
        });
    },
});

1;
