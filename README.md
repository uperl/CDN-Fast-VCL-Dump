# CDN::Fast::VCL::Dump ![static](https://github.com/uperl/CDN-Fast-VCL-Dump/workflows/static/badge.svg) ![linux](https://github.com/uperl/CDN-Fast-VCL-Dump/workflows/linux/badge.svg)

Dump and load Fastly VCL services to files

# SYNOPSIS

```perl
use CDN::Fast::VCL::Dump;

my $tool = CDN::Fast::VCL::Dump->new( api_key => $ENV{FASTLY_API_TOKEN} );

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
```

# DESCRIPTION

This module dumps the VCL configuration of a [Fastly](https://www.fastly.com)
service version to a directory of plain files, and loads such a directory back
into a _different_ service version.  Because nothing customer- or
service-specific is baked into the dump, the same dump can be uploaded to an
unrelated service, an unrelated version, or an entirely different customer
account.

The following objects are included:

- Custom VCL files

    Stored verbatim as plain text `.vcl` files.

- VCL snippets

    The snippet body is stored as a plain text `.vcl` file; the snippet metadata
    (type, priority, dynamic flag) is recorded in `index.yml`.

- Edge dictionaries

    Only the key/value pairs are stored, as a single YAML hash per dictionary.
    Individual dictionary-item objects (with their timestamps and ids) are **not**
    stored.  Write-only dictionaries are recorded by name only, since their contents
    cannot be read back.

- ACLs

    Only the ACL entries are stored, as a YAML list of `{ ip, subnet, negated,
    comment }` hashes per ACL.  Individual ACL-entry objects (with their ids) are
    **not** stored.

## Directory layout

```perl
index.yml               # manifest, read by load()
vcl/<name>.vcl          # one file per custom VCL
snippets/<name>.vcl     # one file per snippet
dictionaries/<name>.yml # { key => value, ... }
acls/<name>.yml         # [ { ip => ..., subnet => ..., ... }, ... ]
```

## Identifiers

The dump never contains a literal id for any object that the API identifies by
an opaque id (the service itself, dictionaries, ACLs).  Instead `index.yml`
gives each such object a symbolic reference -- `service_id_1`,
`dictionary_id_1`, `dictionary_id_2`, `acl_id_1`, and so on.  On ["load"](#load)
these references are resolved: `service_id_1` to the target service you pass in,
and each dictionary/ACL reference to the id of the object that `load` freshly
creates in the target version.  ["load"](#load) returns that mapping.

# CONSTRUCTOR

## new

```perl
my $tool = CDN::Fast::VCL::Dump->new( %options );
```

Options:

- api

    An already-constructed [WebService::Fastly::ApiFactory](https://metacpan.org/pod/WebService::Fastly::ApiFactory) (or anything answering
    `get_api`).  When given, `api_key` and `base_url` are ignored.

- api\_key

    A Fastly API token.  Used to build a [WebService::Fastly::ApiFactory](https://metacpan.org/pod/WebService::Fastly::ApiFactory) if `api`
    is not supplied.

- base\_url

    Optional API base URL override, passed through to
    [WebService::Fastly::Configuration](https://metacpan.org/pod/WebService::Fastly::Configuration).

# METHODS

## dump

```perl
$tool->dump(
  service_id => $service_id,
  dir        => $directory,
  version    => $version,   # optional
);
```

Dumps a service version into `$directory` (created if needed).  If `version` is
omitted the currently active version is used, or, if no version is active, the
highest-numbered version.

Returns the [Path::Tiny](https://metacpan.org/pod/Path::Tiny) object for the directory.

## load

```perl
my $id_map = $tool->load(
  dir        => $directory,
  service_id => $target_service_id,
  version    => $target_version,
);
```

Reads `index.yml` from `$directory` and recreates every object it references
in the target service version.  The target version must already exist and be
editable (not locked/active).

Returns a hashref mapping each symbolic reference from the dump to the real id
in the target account, e.g.:

```perl
{
  service_id_1   => 'aBcDeFgHiJkLmNoPqRsTu',
  dictionary_id_1 => '3vjTQ...',
  acl_id_1       => '7XpLm...',
}
```

Objects are only ever created, never updated or removed, so the target version
should normally be an empty (freshly cloned) version.  Dynamic snippets are
recreated with their dumped body, but any later out-of-band edits to a dynamic
snippet are not captured by ["dump"](#dump) and so are not reproduced here.

# SEE ALSO

- [WebService::Fastly](https://metacpan.org/pod/WebService::Fastly)
- [https://www.fastly.com/documentation/reference/api/](https://www.fastly.com/documentation/reference/api/)

# AUTHOR

Graham Ollis <plicease@cpan.org>

# COPYRIGHT AND LICENSE

This software is copyright (c) 2026 by Graham Ollis.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.
