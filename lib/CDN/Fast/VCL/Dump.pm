use warnings;
use v5.42;

package CDN::Fast::VCL::Dump {

    # ABSTRACT: Dump and load Fastly VCL services to files

    use Carp qw( croak );
    use Path::Tiny qw( path );
    use YAML::PP ();
    use constant {
        _FORMAT      => 'cdn-fast-vcl-dump',
        _FORMAT_VER  => 1,
        _PER_PAGE    => 100,
        _SERVICE_REF => 'service_id_1',
    };

=head1 SYNOPSIS

 use CDN::Fast::VCL::Dump;

 my $tool = CDN::Fast::VCL::Dump->new( api_key => $ENV{FASTLY_API_TOKEN} );

 # ...or reuse the credentials of the Fastly CLI (~/.config/fastly/config.toml):

 my $tool = CDN::Fast::VCL::Dump->new( fastly_cli => 1 );

 # dump a service + version to a directory of files
 $tool->dump(
   service_id => 'SU1Z0isxPaozGVKXdv0eY',
   version    => 7,                # optional, defaults to the active/latest version
   dir        => './my-service-dump',
 );

 # ... later, possibly against a completely unrelated service,
 #     version, or even customer account:

 my $tool2 = CDN::Fast::VCL::Dump->new( api_key => $OTHER_TOKEN );

 $tool2->load(
   dir        => './my-service-dump',
   service_id => 'aBcDeFgHiJkLmNoPqRsTu',   # target service
   version    => 1,                          # target version (editable / not locked)
 );

=head1 DESCRIPTION

This module dumps the VCL configuration of a L<Fastly|https://www.fastly.com>
service version to a directory of plain files, and loads such a directory back
into a I<different> service version.  Because nothing customer- or
service-specific is baked into the dump, the same dump can be uploaded to an
unrelated service, an unrelated version, or an entirely different customer
account.

The following objects are included:

=over 4

=item Custom VCL files

Stored verbatim as plain text C<.vcl> files.

=item VCL snippets

The snippet body is stored as a plain text C<.vcl> file; the snippet metadata
(type, priority, dynamic flag) is recorded in F<index.yml>.

=item Edge dictionaries

Only the key/value pairs are stored, as a single YAML hash per dictionary.
Individual dictionary-item objects (with their timestamps and ids) are B<not>
stored.  Write-only dictionaries are recorded by name only, since their contents
cannot be read back.

=item ACLs

Only the ACL entries are stored, as a YAML list of C<{ ip, subnet, negated,
comment }> hashes per ACL.  Individual ACL-entry objects (with their ids) are
B<not> stored.

=back

=head2 Directory layout

 index.yml               # manifest, read by load()
 vcl/<name>.vcl          # one file per custom VCL
 snippets/<name>.vcl     # one file per snippet
 dictionaries/<name>.yml # { key => value, ... }
 acls/<name>.yml         # [ { ip => ..., subnet => ..., ... }, ... ]

=head2 Identifiers

The dump never contains a literal id for any object that the API identifies by
an opaque id (the service itself, dictionaries, ACLs).  Instead F<index.yml>
gives each such object a symbolic reference -- C<service_id_1>,
C<dictionary_id_1>, C<dictionary_id_2>, C<acl_id_1>, and so on.  On L</load>
these references are resolved: C<service_id_1> to the target service you pass in,
and each dictionary/ACL reference to the id of the object that C<load> freshly
creates in the target version.  L</load> returns that mapping.

=head1 CONSTRUCTOR

=head2 new

 my $tool = CDN::Fast::VCL::Dump->new( %options );

Options:

=over 4

=item api

An already-constructed L<WebService::Fastly::ApiFactory> (or anything answering
C<get_api>).  When given, C<api_key> and C<base_url> are ignored.

=item api_key

=item token

A Fastly API token.  Used to build a L<WebService::Fastly::ApiFactory> if C<api>
is not supplied.

=item fastly_cli

If true, and neither C<api> nor C<api_key> was given, read the API token (and
the API endpoint) from the config file maintained by the
L<Fastly CLI|https://www.fastly.com/documentation/reference/cli/> -- the same
F<config.toml> that C<fastly profile> commands write.  See
L</fastly_cli_config_file> for how its location is determined per platform.

=item fastly_profile

Name of the profile to read from that config file.  Implies C<< fastly_cli => 1 >>.
When omitted, the profile marked C<default> is used (or the only profile, if
there is exactly one).

=item fastly_config

Path to a specific F<config.toml> to read instead of the platform default.
Implies C<< fastly_cli => 1 >>.

=item base_url

Optional API base URL override, passed through to
L<WebService::Fastly::Configuration>.  Takes precedence over an endpoint found
in the Fastly CLI config.

=back

=cut

    sub new ($class, %options) {
        my $self = bless {
            api      => $options{api},
            api_key  => $options{api_key} // $options{token},
            base_url => $options{base_url},
            yaml     => YAML::PP->new,
        }, $class;

        if ( !defined $self->{api} && !defined $self->{api_key}
            && ( $options{fastly_cli}
                || defined $options{fastly_profile}
                || defined $options{fastly_config} ) )
        {
            my $auth = $class->_read_fastly_cli_auth(
                file    => $options{fastly_config},
                profile => $options{fastly_profile},
            );
            $self->{api_key} = $auth->{token};
            $self->{base_url} //= $auth->{api_endpoint};
        }

        croak 'no Fastly API credentials: pass "api", "api_key", or "fastly_cli"'
            unless defined $self->{api} || defined $self->{api_key};
        return $self;
    }

    sub _factory ($self) {
        return $self->{api} //= do {
            require WebService::Fastly::ApiFactory;
            my %args = ( api_key => { 'Fastly-Key' => $self->{api_key} } );
            $args{base_url} = $self->{base_url} if defined $self->{base_url};
            WebService::Fastly::ApiFactory->new(%args);
        };
    }

=head2 fastly_cli_config_file

 my $path = CDN::Fast::VCL::Dump->fastly_cli_config_file;

Returns the L<Path::Tiny> location of the F<config.toml> used by the
L<Fastly CLI|https://www.fastly.com/documentation/reference/cli/>, following the
same platform rules the CLI itself uses:

=over 4

=item *

C<$XDG_CONFIG_HOME/fastly/config.toml>, or F<~/.config/fastly/config.toml>, on
most Unix systems;

=item *

F<~/Library/Application Support/fastly/config.toml> on macOS;

=item *

F<%APPDATA%\fastly\config.toml> on Windows;

=item *

falling back to F<~/.fastly/config.toml>.

=back

Returns C<undef> if none of those paths exists.

=cut

    sub _home {
        for my $var ( qw( HOME USERPROFILE ) ) {
            return $ENV{$var} if defined $ENV{$var} && length $ENV{$var};
        }
        my $home = eval { ( getpwuid $> )[7] };
        return ( defined $home && length $home ) ? $home : undef;
    }

    sub _fastly_cli_config_candidates {
        my $home = _home();
        my @dirs;
        if ( $^O eq 'MSWin32' ) {
            push @dirs, $ENV{APPDATA} if defined $ENV{APPDATA} && length $ENV{APPDATA};
        }
        elsif ( $^O eq 'darwin' ) {
            push @dirs, "$home/Library/Application Support" if defined $home;
        }
        elsif ( defined $ENV{XDG_CONFIG_HOME} && length $ENV{XDG_CONFIG_HOME} ) {
            push @dirs, $ENV{XDG_CONFIG_HOME};
        }
        elsif ( defined $home ) {
            push @dirs, "$home/.config";
        }

        my @files = map { path( $_, 'fastly', 'config.toml' ) } @dirs;
        push @files, path( $home, '.fastly', 'config.toml' ) if defined $home;
        return @files;
    }

    sub fastly_cli_config_file ($class) {
        for my $file ( _fastly_cli_config_candidates() ) {
            return $file if $file->is_file;
        }
        return undef;
    }

    # -> { profile => $name, token => $token, api_endpoint => $url_or_undef }
    sub _read_fastly_cli_auth ($class, %args) {
        my $file = defined $args{file}
            ? path( $args{file} )
            : $class->fastly_cli_config_file;
        croak 'could not locate a Fastly CLI config.toml (looked at: '
            . join( ', ', _fastly_cli_config_candidates() ) . ')'
            unless defined $file;
        croak "Fastly CLI config file not found: $file" unless $file->is_file;

        croak "reading the Fastly CLI config requires TOML::Tiny: $@"
            unless eval { require TOML::Tiny; 1 };
        my ( $data, $err ) = TOML::Tiny::from_toml( $file->slurp_utf8 );
        croak "could not parse Fastly CLI config $file: $err" if $err;

        my $profiles = ( ref $data eq 'HASH' && ref $data->{profile} eq 'HASH' )
            ? $data->{profile}
            : {};

        my ( $name, $profile ) = ( $args{profile} );
        if ( defined $name ) {
            $profile = $profiles->{$name}
                or croak "no profile named '$name' in $file";
        }
        else {
            my @names = sort keys $profiles->%*;
            my @default = grep { $profiles->{$_}{default} } @names;
            if ( @default == 1 ) {
                $name = $default[0];
            }
            elsif ( @names == 1 ) {
                $name = $names[0];
            }
            else {
                croak "no default profile in $file; pass fastly_profile => ...";
            }
            $profile = $profiles->{$name};
        }

        my $token = $profile->{token};
        croak "Fastly CLI profile '$name' in $file has no API token"
            . " (add one with: fastly profile update $name)"
            unless defined $token && length $token;

        my $endpoint = ref $data->{fastly} eq 'HASH' ? $data->{fastly}{api_endpoint} : undef;
        undef $endpoint unless defined $endpoint && length $endpoint;

        return { profile => $name, token => $token, api_endpoint => $endpoint };
    }

    sub _api ($self, $name) {
        return $self->_factory->get_api($name);
    }

    # walk a paginated list endpoint, returning a single arrayref of all rows
    sub _paginate ($self, $code) {
        my @rows;
        my $page = 1;
        while (1) {
            my $batch = $code->($page) // [];
            last unless $batch->@*;
            push @rows, $batch->@*;
            last if $batch->@* < _PER_PAGE;
            $page++;
        }
        return \@rows;
    }

    # turn an arbitrary object name into a safe, unique file name
    sub _file_name ($name, $ext, $seen) {
        my $base = lc( ($name // '') =~ s/[^A-Za-z0-9._-]+/_/gr );
        $base =~ s/^[._]+//;
        $base =~ s/[._]+$//;
        $base = 'unnamed' unless length $base;
        my $file = "$base.$ext";
        my $n    = 1;
        while ( $seen->{$file}++ ) {
            $n++;
            $file = "${base}-${n}.$ext";
        }
        return $file;
    }

    sub _bool ($value) {
        return $value ? 1 : 0;
    }

=head1 METHODS

=head2 dump

 $tool->dump(
   service_id => $service_id,
   dir        => $directory,
   version    => $version,   # optional
 );

Dumps a service version into C<$directory> (created if needed).  If C<version> is
omitted the currently active version is used, or, if no version is active, the
highest-numbered version.

Returns the L<Path::Tiny> object for the directory.

=cut

    sub dump ($self, %args) {
        my $service_id = $args{service_id} // croak 'service_id is required';
        my $dir        = path( $args{dir} // croak 'dir is required' );

        my $version = $args{version} // $self->_default_version($service_id);

        my $service = $self->_api('Service')->get_service( service_id => $service_id );
        my $version_obj = $self->_api('Version')->get_service_version(
            service_id => $service_id,
            version_id => $version,
        );

        my $index = {
            format         => _FORMAT,
            format_version => _FORMAT_VER,
            generated_by   => __PACKAGE__ . ' ' . (__PACKAGE__->VERSION // 'dev'),
            service        => {
                ref     => _SERVICE_REF,
                name    => $service->name,
                comment => $service->comment,
                type    => $service->type,
            },
            version => {
                number  => 0 + $version,
                comment => $version_obj->comment,
            },
            vcl          => [],
            snippets     => [],
            dictionaries => [],
            acls         => [],
        };

        $dir->mkdir;

        $self->_dump_vcl( $service_id, $version, $dir, $index );
        $self->_dump_snippets( $service_id, $version, $dir, $index );
        $self->_dump_dictionaries( $service_id, $version, $dir, $index );
        $self->_dump_acls( $service_id, $version, $dir, $index );

        $dir->child('index.yml')->spew_utf8( $self->{yaml}->dump_string($index) );

        return $dir;
    }

    sub _default_version ($self, $service_id) {
        my $versions = $self->_api('Version')->list_service_versions( service_id => $service_id ) // [];
        croak "service $service_id has no versions" unless $versions->@*;
        my ($active) = grep { $_->active } $versions->@*;
        return $active->number if $active;
        return ( sort { $b->number <=> $a->number } $versions->@* )[0]->number;
    }

    sub _dump_vcl ($self, $service_id, $version, $dir, $index) {
        my $list = $self->_api('Vcl')->list_custom_vcl(
            service_id => $service_id,
            version_id => $version,
        ) // [];
        return unless $list->@*;

        my $vcl_dir = $dir->child('vcl');
        $vcl_dir->mkdir;
        my %seen;
        for my $vcl ( sort { $a->name cmp $b->name } $list->@* ) {
            my $file = _file_name( $vcl->name, 'vcl', \%seen );
            $vcl_dir->child($file)->spew_utf8( $vcl->content // '' );
            push $index->{vcl}->@*, {
                name => $vcl->name,
                main => _bool( $vcl->main ),
                file => "vcl/$file",
            };
        }
        return;
    }

    sub _dump_snippets ($self, $service_id, $version, $dir, $index) {
        my $list = $self->_api('Snippet')->list_snippets(
            service_id => $service_id,
            version_id => $version,
        ) // [];
        return unless $list->@*;

        my $snip_dir = $dir->child('snippets');
        $snip_dir->mkdir;
        my %seen;
        for my $snip ( sort { $a->name cmp $b->name } $list->@* ) {
            my $file = _file_name( $snip->name, 'vcl', \%seen );
            $snip_dir->child($file)->spew_utf8( $snip->content // '' );
            push $index->{snippets}->@*, {
                name     => $snip->name,
                type     => $snip->type,
                priority => ( $snip->priority // 100 ) . q{},
                dynamic  => _bool( $snip->dynamic ),
                file     => "snippets/$file",
            };
        }
        return;
    }

    sub _dump_dictionaries ($self, $service_id, $version, $dir, $index) {
        my $list = $self->_api('Dictionary')->list_dictionaries(
            service_id => $service_id,
            version_id => $version,
        ) // [];
        return unless $list->@*;

        my $dict_dir = $dir->child('dictionaries');
        $dict_dir->mkdir;
        my %seen;
        my $n = 0;
        for my $dict ( sort { $a->name cmp $b->name } $list->@* ) {
            $n++;
            my $entry = {
                ref        => "dictionary_id_$n",
                name       => $dict->name,
                write_only => _bool( $dict->write_only ),
            };
            if ( !$dict->write_only ) {
                my $items = $self->_paginate(sub ($page) {
                    $self->_api('DictionaryItem')->list_dictionary_items(
                        service_id    => $service_id,
                        dictionary_id => $dict->id,
                        page          => $page,
                        per_page      => _PER_PAGE,
                    );
                });
                my %kv = map { ( $_->item_key => $_->item_value // '' ) } $items->@*;
                my $file = _file_name( $dict->name, 'yml', \%seen );
                $dict_dir->child($file)->spew_utf8( $self->{yaml}->dump_string( \%kv ) );
                $entry->{file} = "dictionaries/$file";
            }
            push $index->{dictionaries}->@*, $entry;
        }
        return;
    }

    sub _dump_acls ($self, $service_id, $version, $dir, $index) {
        my $list = $self->_api('Acl')->list_acls(
            service_id => $service_id,
            version_id => $version,
        ) // [];
        return unless $list->@*;

        my $acl_dir = $dir->child('acls');
        $acl_dir->mkdir;
        my %seen;
        my $n = 0;
        for my $acl ( sort { $a->name cmp $b->name } $list->@* ) {
            $n++;
            my $entries = $self->_paginate(sub ($page) {
                $self->_api('AclEntry')->list_acl_entries(
                    service_id => $service_id,
                    acl_id     => $acl->id,
                    page       => $page,
                    per_page   => _PER_PAGE,
                );
            });
            my @items = map {
                my $e = $_;
                my $item = { ip => $e->ip, negated => _bool( $e->negated ) };
                $item->{subnet} = 0 + $e->subnet if defined $e->subnet;
                $item->{comment} = $e->comment
                    if defined $e->comment && length $e->comment;
                $item;
            } $entries->@*;

            my $file = _file_name( $acl->name, 'yml', \%seen );
            $acl_dir->child($file)->spew_utf8( $self->{yaml}->dump_string( \@items ) );
            push $index->{acls}->@*, {
                ref  => "acl_id_$n",
                name => $acl->name,
                file => "acls/$file",
            };
        }
        return;
    }

=head2 load

 my $id_map = $tool->load(
   dir        => $directory,
   service_id => $target_service_id,
   version    => $target_version,
 );

Reads F<index.yml> from C<$directory> and recreates every object it references
in the target service version.  The target version must already exist and be
editable (not locked/active).

Returns a hashref mapping each symbolic reference from the dump to the real id
in the target account, e.g.:

 {
   service_id_1   => 'aBcDeFgHiJkLmNoPqRsTu',
   dictionary_id_1 => '3vjTQ...',
   acl_id_1       => '7XpLm...',
 }

Objects are only ever created, never updated or removed, so the target version
should normally be an empty (freshly cloned) version.  Dynamic snippets are
recreated with their dumped body, but any later out-of-band edits to a dynamic
snippet are not captured by L</dump> and so are not reproduced here.

=cut

    sub load ($self, %args) {
        my $dir            = path( $args{dir} // croak 'dir is required' );
        my $target_service = $args{service_id} // croak 'service_id is required';
        my $target_version = $args{version} // croak 'version is required';

        my $index = $self->{yaml}->load_string( $dir->child('index.yml')->slurp_utf8 );
        croak 'directory does not contain a ' . _FORMAT . ' dump'
            unless ref $index eq 'HASH' && ( $index->{format} // '' ) eq _FORMAT;

        my %id_map = ( _SERVICE_REF() => $target_service );

        $self->_load_vcl( $index, $dir, $target_service, $target_version );
        $self->_load_snippets( $index, $dir, $target_service, $target_version );
        $self->_load_dictionaries( $index, $dir, $target_service, $target_version, \%id_map );
        $self->_load_acls( $index, $dir, $target_service, $target_version, \%id_map );

        return \%id_map;
    }

    sub _load_vcl ($self, $index, $dir, $service_id, $version) {
        for my $vcl ( ( $index->{vcl} // [] )->@* ) {
            $self->_api('Vcl')->create_custom_vcl(
                service_id => $service_id,
                version_id => $version,
                name       => $vcl->{name},
                content    => $dir->child( $vcl->{file} )->slurp_utf8,
                main       => _bool( $vcl->{main} ),
            );
        }
        return;
    }

    sub _load_snippets ($self, $index, $dir, $service_id, $version) {
        for my $snip ( ( $index->{snippets} // [] )->@* ) {
            $self->_api('Snippet')->create_snippet(
                service_id => $service_id,
                version_id => $version,
                name       => $snip->{name},
                type       => $snip->{type},
                content    => $dir->child( $snip->{file} )->slurp_utf8,
                priority   => ( $snip->{priority} // 100 ) . q{},
                ( defined $snip->{dynamic} ? ( dynamic => _bool( $snip->{dynamic} ) ) : () ),
            );
        }
        return;
    }

    sub _load_dictionaries ($self, $index, $dir, $service_id, $version, $id_map) {
        require WebService::Fastly::Object::BulkUpdateDictionaryItem;
        require WebService::Fastly::Object::BulkUpdateDictionaryListRequest;

        for my $dict ( ( $index->{dictionaries} // [] )->@* ) {
            my $created = $self->_api('Dictionary')->create_dictionary(
                service_id => $service_id,
                version_id => $version,
                name       => $dict->{name},
                write_only => _bool( $dict->{write_only} ),
            );
            $id_map->{ $dict->{ref} } = $created->id;

            next unless defined $dict->{file};
            my $kv = $self->{yaml}->load_string( $dir->child( $dict->{file} )->slurp_utf8 ) // {};
            my @items = map {
                WebService::Fastly::Object::BulkUpdateDictionaryItem->new(
                    op         => 'upsert',
                    item_key   => $_,
                    item_value => $kv->{$_},
                );
            } sort keys $kv->%*;
            next unless @items;

            $self->_api('DictionaryItem')->bulk_update_dictionary_item(
                service_id                          => $service_id,
                dictionary_id                       => $created->id,
                bulk_update_dictionary_list_request =>
                    WebService::Fastly::Object::BulkUpdateDictionaryListRequest->new( items => \@items ),
            );
        }
        return;
    }

    sub _load_acls ($self, $index, $dir, $service_id, $version, $id_map) {
        require WebService::Fastly::Object::BulkUpdateAclEntry;
        require WebService::Fastly::Object::BulkUpdateAclEntriesRequest;

        for my $acl ( ( $index->{acls} // [] )->@* ) {
            my $created = $self->_api('Acl')->create_acl(
                service_id => $service_id,
                version_id => $version,
                name       => $acl->{name},
            );
            $id_map->{ $acl->{ref} } = $created->id;

            my $items = $self->{yaml}->load_string( $dir->child( $acl->{file} )->slurp_utf8 ) // [];
            my @entries = map {
                WebService::Fastly::Object::BulkUpdateAclEntry->new(
                    op      => 'create',
                    ip      => $_->{ip},
                    negated => _bool( $_->{negated} ),
                    ( defined $_->{subnet}  ? ( subnet  => $_->{subnet} )  : () ),
                    ( defined $_->{comment} ? ( comment => $_->{comment} ) : () ),
                );
            } $items->@*;
            next unless @entries;

            $self->_api('AclEntry')->bulk_update_acl_entries(
                service_id                     => $service_id,
                acl_id                         => $created->id,
                bulk_update_acl_entries_request =>
                    WebService::Fastly::Object::BulkUpdateAclEntriesRequest->new( entries => \@entries ),
            );
        }
        return;
    }

=head1 SEE ALSO

=over 4

=item L<cfvd>

A command line interface to this module.

=item L<WebService::Fastly>

=item L<https://www.fastly.com/documentation/reference/api/>

=item L<https://www.fastly.com/documentation/reference/cli/>

The Fastly CLI, whose F<config.toml> the C<fastly_cli> option reads.

=back

=cut

}
