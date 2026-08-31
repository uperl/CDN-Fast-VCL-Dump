use warnings;
use v5.42;

package App::cfvd {

    # ABSTRACT: Command line interface to CDN::Fast::VCL::Dump

    use CDN::Fast::VCL::Dump ();
    use Getopt::Long::Descriptive qw( describe_options );

=head1 SYNOPSIS

 cfvd dump --service SU1Z0isxPaozGVKXdv0eY [--version 7] ./dump-dir
 cfvd load --service aBcDeFgHiJkLmNoPqRsTu --version 1  ./dump-dir

=head1 DESCRIPTION

C<App::cfvd> implements L<cfvd>, a thin command line wrapper around
L<CDN::Fast::VCL::Dump>.  There are two subcommands:

=over 4

=item C<cfvd dump --service I<id> [--version I<n>] I<directory>>

Dump a Fastly service version to I<directory> (created if needed).  With no
C<--version>, the active version is used, or the highest-numbered one.

=item C<cfvd load --service I<id> --version I<n> I<directory>>

Recreate everything in I<directory> in the given service version, which must
already exist and be editable.  The resolved id mapping is written to C<STDOUT>
as tab-separated C<< <reference> <id> >> lines.

=back

Run C<cfvd dump --help> or C<cfvd load --help> for the full option list.

=head2 Authentication

Every subcommand accepts:

=over 4

=item C<--token I<token>>

A Fastly API token.  Defaults to the C<FASTLY_API_TOKEN> environment variable.

=item C<--fastly-cli>

Take the token (and API endpoint) from the Fastly CLI's F<config.toml>.

=item C<--fastly-profile I<name>>

As C<--fastly-cli>, using the named profile.  Implies C<--fastly-cli>.

=item C<--fastly-config I<path>>

As C<--fastly-cli>, reading I<path> instead of the platform default.  Implies
C<--fastly-cli>.

=item C<--base-url I<url>>

Override the Fastly API base URL.

=back

If none of these is given and C<FASTLY_API_TOKEN> is not set, the Fastly CLI
config file is used, exactly as if C<--fastly-cli> had been passed.

=head1 METHODS

=head2 run

 my $exit = App::cfvd->run( \@ARGV );

Parse C<@ARGV>, run the requested subcommand, and return a process exit code:
C<0> on success, C<2> for a usage error, C<1> for a runtime failure.  All
diagnostics go to C<STDERR>.

=cut

    my $TOP_USAGE = <<'END_USAGE';
usage:
  cfvd dump --service <id> [--version <n>] [options] <directory>
  cfvd load --service <id> --version <n>   [options] <directory>
  cfvd dump --help | cfvd load --help
  cfvd --version

Dump a Fastly VCL service version to a directory of files, or load such a
directory back into another service version.
END_USAGE

    sub run ( $class, $argv ) {
        my @args = $argv->@*;

        return _err( $TOP_USAGE, 2 ) unless @args;

        if ( $args[0] eq 'help' || $args[0] eq '-h' || $args[0] eq '--help' ) {
            print $TOP_USAGE;
            return 0;
        }
        if ( $args[0] eq 'version' || $args[0] eq '--version' ) {
            say 'cfvd ' . ( $class->VERSION // 'dev' );
            return 0;
        }

        my $cmd = shift @args;
        return _err( "cfvd: unknown subcommand '$cmd'\n\n$TOP_USAGE", 2 )
            unless $cmd eq 'dump' || $cmd eq 'load';

        my $load = $cmd eq 'load';
        my ( $opt, $usage, @rest, @warn );
        my $parsed = eval {
            local @ARGV = @args;
            local $SIG{__WARN__} = sub ( $w ) { push @warn, $w };
            ( $opt, $usage ) = describe_options(
                "cfvd $cmd %o <directory>",
                [ 'service|s=s', 'service to read from / write to (required)' ],
                [   'version|n=i',
                    $load ? 'target service version (required)' : 'service version (default: active, else latest)',
                ],
                [],
                [ 'token=s',          'Fastly API token (default: $FASTLY_API_TOKEN)' ],
                [ 'fastly-cli',       'take the token from the Fastly CLI config file' ],
                [ 'fastly-profile=s', '...using this profile (implies --fastly-cli)' ],
                [ 'fastly-config=s',  '...from this config.toml (implies --fastly-cli)' ],
                [ 'base-url=s',       'override the Fastly API base URL' ],
                [],
                [ 'help', 'print this help and exit', { shortcircuit => 1 } ],
            );
            @rest = @ARGV;
            1;
        };
        return _err( join( '', @warn ) . ( $@ // '' ), 2 ) unless $parsed;

        if ( $opt->help ) {
            print $usage->text;
            return 0;
        }

        return _err( "cfvd $cmd: --service is required\n\n" . $usage->text, 2 )
            unless defined $opt->service;
        return _err( "cfvd load: --version is required\n\n" . $usage->text, 2 )
            if $load && !defined $opt->version;

        my $dir = shift @rest;
        return _err( "cfvd $cmd: a target directory is required\n\n" . $usage->text, 2 )
            unless defined $dir;
        return _err( "cfvd $cmd: unexpected extra arguments: @rest\n\n" . $usage->text, 2 )
            if @rest;

        my $tool = eval { _build_tool($opt) };
        return _err( $@, 1 ) unless $tool;

        my $exit = eval {
            if ($load) {
                my $map = $tool->load(
                    dir        => $dir,
                    service_id => $opt->service,
                    version    => $opt->version,
                );
                say "$_\t$map->{$_}" for sort keys $map->%*;
            }
            else {
                my $out = $tool->dump(
                    service_id => $opt->service,
                    dir        => $dir,
                    ( defined $opt->version ? ( version => $opt->version ) : () ),
                );
                say "$out";
            }
            0;
        };
        return defined $exit ? $exit : _err( $@, 1 );
    }

    sub _build_tool ($opt) {
        my %new;

        my $token = $opt->token;
        if ( defined $token && length $token ) {
            $new{api_key} = $token;
        }
        elsif ( defined $ENV{FASTLY_API_TOKEN} && length $ENV{FASTLY_API_TOKEN} ) {
            $new{api_key} = $ENV{FASTLY_API_TOKEN};
        }

        $new{fastly_cli}     = 1                    if $opt->fastly_cli;
        $new{fastly_profile} = $opt->fastly_profile if defined $opt->fastly_profile;
        $new{fastly_config}  = $opt->fastly_config  if defined $opt->fastly_config;
        $new{base_url}       = $opt->base_url       if defined $opt->base_url;

        $new{fastly_cli} = 1
            unless exists $new{api_key}
            || $new{fastly_cli}
            || defined $new{fastly_profile}
            || defined $new{fastly_config};

        return CDN::Fast::VCL::Dump->new(%new);
    }

    sub _err ( $msg, $code ) {
        $msg .= "\n" unless $msg =~ /\n\z/;
        print {*STDERR} $msg;
        return $code;
    }

=head1 SEE ALSO

L<cfvd>, L<CDN::Fast::VCL::Dump>

=cut

}
