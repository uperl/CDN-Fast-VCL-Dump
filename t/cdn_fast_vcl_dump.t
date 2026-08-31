use Test2::V0 -no_srand => 1;
use v5.42;
use CDN::Fast::VCL::Dump;
use Path::Tiny qw( path tempdir );
use YAML::PP ();

# ---------------------------------------------------------------------------
# A tiny fake of WebService::Fastly::ApiFactory.  Each "api" it hands out
# records every call and returns whatever the test stubbed for
# "<Api>.<method>", defaulting to an empty list.
# ---------------------------------------------------------------------------

package Fake::Obj {
    sub new ($class, %attr) { return bless { %attr }, $class }
    our $AUTOLOAD;
    sub AUTOLOAD ($self, @) {
        ( my $name = $AUTOLOAD ) =~ s/.*:://;
        return () if $name eq q{DESTROY};
        return $self->{$name};
    }
}

package Fake::Factory {
    sub new ($class) { return bless { calls => [], stubs => {} }, $class }
    sub stub ($self, $key, $value) { $self->{stubs}{$key} = $value; return $self }
    sub calls ($self, $key) {
        return grep { "$_->{api}.$_->{method}" eq $key } $self->{calls}->@*;
    }
    sub get_api ($self, $name) { return Fake::Api->new( factory => $self, name => $name ) }
}

package Fake::Api {
    sub new ($class, %attr) { return bless { %attr }, $class }
    our $AUTOLOAD;
    sub AUTOLOAD ($self, %args) {
        ( my $method = $AUTOLOAD ) =~ s/.*:://;
        return () if $method eq q{DESTROY};
        my $factory = $self->{factory};
        my $key     = "$self->{name}.$method";
        push $factory->{calls}->@*, { api => $self->{name}, method => $method, args => \%args };
        my $stub = $factory->{stubs}{$key};
        return ref $stub eq 'CODE' ? $stub->(%args) : $stub;
    }
}

package main;

my $factory = Fake::Factory->new
    ->stub( 'Service.get_service' => Fake::Obj->new(
        name => 'Source Service', comment => 'the source', type => 'vcl',
    ) )
    ->stub( 'Version.get_service_version' => Fake::Obj->new( comment => 'v3 notes' ) )
    ->stub( 'Vcl.list_custom_vcl' => [
        Fake::Obj->new( name => 'main',        main => 1, content => "sub vcl_recv {\n  #FASTLY recv\n}\n" ),
        Fake::Obj->new( name => 'Extra Bits!', main => 0, content => "# helper\n" ),
    ] )
    ->stub( 'Snippet.list_snippets' => [
        Fake::Obj->new( name => 'set header', type => 'recv', priority => '100', dynamic => 0,
                        content => "set req.http.X-Test = \"1\";\n" ),
    ] )
    ->stub( 'Dictionary.list_dictionaries' => [
        Fake::Obj->new( name => 'features', write_only => 0, id => 'REAL-DICT-AAA' ),
        Fake::Obj->new( name => 'secrets',  write_only => 1, id => 'REAL-DICT-BBB' ),
    ] )
    ->stub( 'DictionaryItem.list_dictionary_items' => sub (%args) {
        return [] if $args{page} > 1;
        return [
            Fake::Obj->new( item_key => 'beta',  item_value => 'on' ),
            Fake::Obj->new( item_key => 'gamma', item_value => 'off' ),
        ];
    } )
    ->stub( 'Acl.list_acls' => [
        Fake::Obj->new( name => 'office net', id => 'REAL-ACL-CCC' ),
    ] )
    ->stub( 'AclEntry.list_acl_entries' => sub (%args) {
        return [] if $args{page} > 1;
        return [
            Fake::Obj->new( ip => '192.0.2.0',    subnet => 24,    negated => 0, comment => 'hq' ),
            Fake::Obj->new( ip => '198.51.100.7', subnet => undef, negated => 1, comment => '' ),
        ];
    } );

my $dir = tempdir;

subtest 'dump' => sub {
    my $tool = CDN::Fast::VCL::Dump->new( api => $factory );
    my $out  = $tool->dump( service_id => 'SRC-SERVICE', version => 3, dir => "$dir" );

    ok -f path( $out, 'index.yml' ), 'index.yml written';

    my $index = YAML::PP->new->load_string( path( $out, 'index.yml' )->slurp_utf8 );

    is $index->{format},         'cdn-fast-vcl-dump', 'format tag';
    is $index->{service}{ref},   'service_id_1',      'symbolic service ref, no real id';
    is $index->{version}{number}, 3,                  'version number recorded';
    unlike path( $out, 'index.yml' )->slurp_utf8, qr/SRC-SERVICE|REAL-DICT|REAL-ACL/,
        'no literal API ids anywhere in the manifest';

    # VCL -> plain .vcl files
    my ($main_vcl) = grep { $_->{main} } $index->{vcl}->@*;
    is $main_vcl->{name}, 'main', 'main vcl flagged';
    is path( $out, $main_vcl->{file} )->slurp_utf8, "sub vcl_recv {\n  #FASTLY recv\n}\n",
        'vcl content stored verbatim';
    like $main_vcl->{file}, qr{\Avcl/.*\.vcl\z}, 'vcl stored under vcl/ as .vcl';
    my ($extra) = grep { !$_->{main} } $index->{vcl}->@*;
    is path( $out, $extra->{file} )->basename, 'extra_bits.vcl', 'odd name sanitised';

    # snippet body -> .vcl, metadata -> index
    my ($snip) = $index->{snippets}->@*;
    is $snip->{type}, 'recv', 'snippet type kept in index';
    is path( $out, $snip->{file} )->slurp_utf8, "set req.http.X-Test = \"1\";\n", 'snippet body verbatim';

    # dictionary -> hash of key => value
    my ($features) = grep { $_->{name} eq 'features' } $index->{dictionaries}->@*;
    is $features->{ref}, 'dictionary_id_1', 'dictionary gets symbolic ref';
    is YAML::PP->new->load_string( path( $out, $features->{file} )->slurp_utf8 ),
        { beta => 'on', gamma => 'off' }, 'dictionary stored as plain key/value hash';

    my ($secrets) = grep { $_->{name} eq 'secrets' } $index->{dictionaries}->@*;
    ok !exists $secrets->{file}, 'write-only dictionary has no content file';

    # acl -> list of entries
    my ($acl) = $index->{acls}->@*;
    is $acl->{ref}, 'acl_id_1', 'acl gets symbolic ref';
    is YAML::PP->new->load_string( path( $out, $acl->{file} )->slurp_utf8 ),
        [
            { ip => '192.0.2.0', subnet => 24, negated => 0, comment => 'hq' },
            { ip => '198.51.100.7', negated => 1 },
        ],
        'acl stored as a list of entry hashes';
};

subtest 'load into an unrelated service + version' => sub {
    my $loader = Fake::Factory->new
        ->stub( 'Dictionary.create_dictionary' => sub (%args) {
            return Fake::Obj->new( id => "NEW-DICT-$args{name}" );
        } )
        ->stub( 'Acl.create_acl' => sub (%args) {
            return Fake::Obj->new( id => "NEW-ACL-$args{name}" );
        } );

    my $tool   = CDN::Fast::VCL::Dump->new( api => $loader );
    my $id_map = $tool->load( dir => "$dir", service_id => 'DEST-SERVICE', version => 1 );

    is $id_map->{service_id_1},   'DEST-SERVICE',       'service ref resolved to target';
    is $id_map->{dictionary_id_1}, 'NEW-DICT-features', 'dictionary ref resolved to freshly created id';
    is $id_map->{acl_id_1},        'NEW-ACL-office net', 'acl ref resolved to freshly created id';

    my @vcl = $loader->calls('Vcl.create_custom_vcl');
    is scalar(@vcl), 2, 'both custom VCLs recreated';
    is [ sort map { $_->{args}{name} } @vcl ], [ 'Extra Bits!', 'main' ], 'by original name';
    is +( grep { $_->{args}{name} eq 'main' } @vcl )[0]->{args}{content},
        "sub vcl_recv {\n  #FASTLY recv\n}\n", 'against the target version with original content';
    is +( grep { $_->{args}{name} eq 'main' } @vcl )[0]->{args}{version_id}, 1, 'target version used';

    my ($snip_call) = $loader->calls('Snippet.create_snippet');
    is $snip_call->{args}{type}, 'recv', 'snippet type carried across';

    my ($dict_items) = $loader->calls('DictionaryItem.bulk_update_dictionary_item');
    is $dict_items->{args}{dictionary_id}, 'NEW-DICT-features', 'items pushed to the new dictionary id';
    my @keys = sort map { $_->item_key } $dict_items->{args}{bulk_update_dictionary_list_request}->items->@*;
    is \@keys, [ 'beta', 'gamma' ], 'dictionary keys uploaded';

    my ($acl_entries) = $loader->calls('AclEntry.bulk_update_acl_entries');
    is $acl_entries->{args}{acl_id}, 'NEW-ACL-office net', 'entries pushed to the new acl id';
    my @ips = sort map { $_->ip } $acl_entries->{args}{bulk_update_acl_entries_request}->entries->@*;
    is \@ips, [ '192.0.2.0', '198.51.100.7' ], 'acl entries uploaded';

    # write-only dictionary is created but gets no items
    my @created = $loader->calls('Dictionary.create_dictionary');
    is scalar(@created), 2, 'both dictionaries created (including write-only)';
};

subtest 'constructor validation' => sub {
    like dies { CDN::Fast::VCL::Dump->new }, qr/api_key/, 'needs credentials or an api object';
    like dies { CDN::Fast::VCL::Dump->new( api => $factory )->dump( dir => 'x' ) },
        qr/service_id/, 'dump requires service_id';
    like dies { CDN::Fast::VCL::Dump->new( api => $factory )->load( dir => "$dir" ) },
        qr/service_id/, 'load requires a target service_id';
};

subtest 'auth from the Fastly CLI config' => sub {
    my $cfg = Path::Tiny->tempfile( SUFFIX => '.toml' );
    $cfg->spew_utf8( <<'TOML' );
config_version = 6

[fastly]
api_endpoint = "https://api.example.test"

[profile]
  [profile.user]
    default = true
    email = "me@example.com"
    token = "TOKEN-DEFAULT"
  [profile.work]
    default = false
    token = "TOKEN-WORK"
TOML

    my $auth = CDN::Fast::VCL::Dump->_read_fastly_cli_auth( file => "$cfg" );
    is $auth->{token},        'TOKEN-DEFAULT',             'default profile token';
    is $auth->{profile},      'user',                      'default profile name';
    is $auth->{api_endpoint}, 'https://api.example.test',  'api endpoint picked up';

    is CDN::Fast::VCL::Dump->_read_fastly_cli_auth( file => "$cfg", profile => 'work' )->{token},
        'TOKEN-WORK', 'named profile token';

    like dies { CDN::Fast::VCL::Dump->_read_fastly_cli_auth( file => "$cfg", profile => 'nope' ) },
        qr/no profile named 'nope'/, 'unknown profile dies';

    like dies { CDN::Fast::VCL::Dump->_read_fastly_cli_auth( file => "$cfg.does-not-exist" ) },
        qr/not found/, 'missing config file dies';

    my $sso = Path::Tiny->tempfile( SUFFIX => '.toml' );
    $sso->spew_utf8( qq{[profile]\n  [profile.sso]\n    default = true\n    token = ""\n} );
    like dies { CDN::Fast::VCL::Dump->_read_fastly_cli_auth( file => "$sso" ) },
        qr/has no API token/, 'empty token is rejected';

    # constructor pulls token + endpoint out of the CLI config
    my $tool = CDN::Fast::VCL::Dump->new( fastly_config => "$cfg" );
    is $tool->{api_key},  'TOKEN-DEFAULT',            'token stored on the object';
    is $tool->{base_url}, 'https://api.example.test', 'api_endpoint used as base_url';

    is CDN::Fast::VCL::Dump->new( fastly_config => "$cfg", base_url => 'https://override.test' )->{base_url},
        'https://override.test', 'explicit base_url wins over the CLI config';

    is CDN::Fast::VCL::Dump->new( fastly_config => "$cfg", api_key => 'EXPLICIT' )->{api_key},
        'EXPLICIT', 'explicit api_key wins over the CLI config';

    # the token reaches WebService::Fastly as the Fastly-Key credential
    SKIP: {
        my $ok = eval { require WebService::Fastly::ApiFactory; 1 };
        skip 'WebService::Fastly::ApiFactory not loadable in this environment', 2 unless $ok;
        my $client = CDN::Fast::VCL::Dump->new( fastly_config => "$cfg" )->_factory->api_client;
        is $client->{config}{api_key}{'Fastly-Key'}, 'TOKEN-DEFAULT', 'token passed as Fastly-Key';
        is $client->{config}{base_url}, 'https://api.example.test', 'base_url passed through';
    }
};

done_testing;
