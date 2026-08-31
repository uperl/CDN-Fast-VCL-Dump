use Test2::V0 -no_srand => 1;
use v5.42;
use App::cfvd;

# ---------------------------------------------------------------------------
# Fake the underlying CDN::Fast::VCL::Dump: App::cfvd only ever calls
# ->new / ->dump / ->load on it.
# ---------------------------------------------------------------------------

package Fake::Tool {
    our ( @NEW, @DUMP, @LOAD );
    sub new ( $class, %opt ) { push @NEW, \%opt; return bless {}, $class }
    sub dump ( $self, %args ) { push @DUMP, \%args; return "$args{dir}" }
    sub load ( $self, %args ) {
        push @LOAD, \%args;
        return { service_id_1 => 'DEST-SVC', acl_id_1 => 'NEW-ACL' };
    }
}

package main;

no warnings 'redefine';
*CDN::Fast::VCL::Dump::new = sub ( $class, %opt ) { return Fake::Tool->new(%opt) };
use warnings;

sub run_cfvd (@argv) {
    local ( @Fake::Tool::NEW, @Fake::Tool::DUMP, @Fake::Tool::LOAD ) = ();
    my ( $out, $err ) = ( '', '' );
    my $exit;
    {
        open my $o, '>', \$out or die;
        open my $e, '>', \$err or die;
        local ( *STDOUT, *STDERR ) = ( $o, $e );
        $exit = App::cfvd->run( [@argv] );
    }
    return {
        exit => $exit,
        out  => $out,
        err  => $err,
        new  => [@Fake::Tool::NEW],
        dump => [@Fake::Tool::DUMP],
        load => [@Fake::Tool::LOAD],
    };
}

subtest 'help and version' => sub {
    my $h = run_cfvd('--help');
    is $h->{exit}, 0, '--help exits 0';
    like $h->{out}, qr/\bcfvd dump\b/, 'usage printed to stdout';

    my $v = run_cfvd('--version');
    is $v->{exit}, 0, '--version exits 0';
    like $v->{out}, qr/^cfvd /, 'prints program name and version';

    is run_cfvd()->{exit},           2, 'no arguments is a usage error';
    is run_cfvd('wibble')->{exit},   2, 'unknown subcommand is a usage error';
    like run_cfvd('wibble')->{err}, qr/unknown subcommand 'wibble'/, '...with a message';

    my $dh = run_cfvd(qw( dump --help ));
    is $dh->{exit}, 0, 'dump --help exits 0';
    like $dh->{out}, qr/--fastly-profile/, 'per-subcommand option list on stdout';
    is $dh->{dump}, [], 'nothing dispatched';

    my $bad = run_cfvd(qw( dump --bogus ./d ));
    is $bad->{exit}, 2, 'unknown option is a usage error';
    like $bad->{err}, qr/[Uu]nknown option/, '...naming the option';
};

subtest 'dump dispatch' => sub {
    local $ENV{FASTLY_API_TOKEN} = 'ENVTOK';
    my $r = run_cfvd(qw( dump --service SVC --version 4 ./out-dir ));
    is $r->{exit}, 0, 'exit 0';
    is $r->{dump}[0], { service_id => 'SVC', version => 4, dir => './out-dir' },
        'dump() called with parsed service, version, and positional dir';
    is $r->{out}, "./out-dir\n", 'prints the dump directory';
    is $r->{new}[0]{api_key}, 'ENVTOK', 'token taken from FASTLY_API_TOKEN';

    my $no_ver = run_cfvd(qw( dump -s SVC ./d ));
    ok !exists $no_ver->{dump}[0]{version}, 'version omitted when not given';

    is run_cfvd(qw( dump --version 4 ./d ))->{exit}, 2, '--service is required';
    like run_cfvd(qw( dump --service SVC ))->{err}, qr/directory is required/, 'dir is required';
    is run_cfvd(qw( dump --service SVC a b ))->{exit}, 2, 'extra args rejected';
};

subtest 'load dispatch' => sub {
    local $ENV{FASTLY_API_TOKEN} = 'ENVTOK';
    my $r = run_cfvd(qw( load --service DST --version 2 ./in-dir ));
    is $r->{exit}, 0, 'exit 0';
    is $r->{load}[0], { service_id => 'DST', version => 2, dir => './in-dir' },
        'load() called with parsed args';
    is $r->{out}, "acl_id_1\tNEW-ACL\nservice_id_1\tDEST-SVC\n",
        'id map printed as sorted tab-separated lines';

    is run_cfvd(qw( load --service DST ./in-dir ))->{exit}, 2, 'load requires --version';
    like run_cfvd(qw( load --service DST ./in-dir ))->{err}, qr/--version is required/, '...with a message';
};

subtest 'authentication option translation' => sub {
    local $ENV{FASTLY_API_TOKEN};
    delete $ENV{FASTLY_API_TOKEN};

    is run_cfvd(qw( dump -s S ./d --token ABC ))->{new}[0],
        { api_key => 'ABC' }, '--token becomes api_key';

    is run_cfvd(qw( dump -s S ./d --fastly-cli ))->{new}[0],
        { fastly_cli => 1 }, '--fastly-cli';

    is run_cfvd(qw( dump -s S ./d --fastly-profile work ))->{new}[0],
        { fastly_profile => 'work' }, '--fastly-profile';

    is run_cfvd(qw( dump -s S ./d --fastly-config /x/config.toml ))->{new}[0],
        { fastly_config => '/x/config.toml' }, '--fastly-config';

    is run_cfvd(qw( dump -s S ./d --token ABC --base-url https://api.example ))->{new}[0],
        { api_key => 'ABC', base_url => 'https://api.example' }, '--base-url';

    is run_cfvd(qw( dump -s S ./d ))->{new}[0],
        { fastly_cli => 1 }, 'defaults to the Fastly CLI config when nothing else is given';
};

subtest 'runtime failures map to exit 1' => sub {
    local $ENV{FASTLY_API_TOKEN} = 'ENVTOK';
    no warnings 'redefine';
    local *Fake::Tool::dump = sub { die "boom\n" };
    use warnings;
    my $r = run_cfvd(qw( dump -s S --version 1 ./d ));
    is $r->{exit}, 1, 'a dying dump() gives exit 1';
    like $r->{err}, qr/boom/, 'the error reaches stderr';
};

done_testing;
