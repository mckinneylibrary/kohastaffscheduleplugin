package Koha::Plugin::Com::LibSched::StaffScheduler;

use Modern::Perl;
use base qw(Koha::Plugins::Base);
use Koha::Token;
use C4::Context;
use C4::Auth qw();
use Koha::Patrons;
use JSON qw(encode_json decode_json);
use Data::UUID;
use Try::Tiny;

our $VERSION = '1.0.13';
our $metadata = {
    name            => 'Staff Scheduler',
    author          => 'LibSched',
    description     => 'Library staff scheduling — pulls staff, branches & holidays from Koha',
    date_authored   => '2026-05-27',
    date_updated    => '2026-05-27',
    minimum_version => '22.05.00.000',
    maximum_version => undef,
    version         => $VERSION,
    configure       => 1,
};

sub new {
    my ( $class, $args ) = @_;
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;
    my $self = $class->SUPER::new($args);
    return $self;
}

sub metadata { return $metadata; }

sub install {
    my ( $self, $args ) = @_;
    my $dbh = C4::Context->dbh;

    $dbh->do(q{
        CREATE TABLE IF NOT EXISTS `koha_plugin_staffsched_zones` (
            `id`          VARCHAR(36)  NOT NULL,
            `name`        VARCHAR(255) NOT NULL,
            `color_code`  VARCHAR(7)   NOT NULL DEFAULT '#bbf7d0',
            `is_active`   TINYINT(1)   NOT NULL DEFAULT 1,
            `created_at`  DATETIME     NOT NULL DEFAULT NOW(),
            PRIMARY KEY (`id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    });

    $dbh->do(q{
        CREATE TABLE IF NOT EXISTS `koha_plugin_staffsched_assignments` (
            `id`            VARCHAR(36)  NOT NULL,
            `employee_id`   INT          NOT NULL,
            `zone_id`       VARCHAR(36)  NULL,
            `location_id`   VARCHAR(10)  NULL,
            `shift_date`    DATE         NOT NULL,
            `start_time`    TIME         NOT NULL,
            `end_time`      TIME         NOT NULL,
            `is_base_shift` TINYINT(1)   NOT NULL DEFAULT 0,
            `series_id`     VARCHAR(36)  NULL,
            `custom_label`  VARCHAR(255) NULL,
            `notes`         TEXT         NULL,
            `created_at`    DATETIME     NOT NULL DEFAULT NOW(),
            `updated_at`    DATETIME     NOT NULL DEFAULT NOW() ON UPDATE NOW(),
            PRIMARY KEY (`id`),
            KEY `idx_employee_date` (`employee_id`, `shift_date`),
            KEY `idx_series`        (`series_id`),
            KEY `idx_shift_date`    (`shift_date`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    });

    $dbh->do(q{
        CREATE TABLE IF NOT EXISTS `koha_plugin_staffsched_branch_colors` (
            `branchcode`  VARCHAR(10) NOT NULL,
            `color_code`  VARCHAR(7)  NOT NULL DEFAULT '#eab308',
            PRIMARY KEY (`branchcode`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    });

    $dbh->do(q{
        CREATE TABLE IF NOT EXISTS `koha_plugin_staffsched_audit` (
            `id`           INT AUTO_INCREMENT NOT NULL,
            `employee_id`  INT          NULL,
            `action_type`  VARCHAR(100) NOT NULL,
            `details`      TEXT         NULL,
            `changed_by`   VARCHAR(255) NULL,
            `created_at`   DATETIME     NOT NULL DEFAULT NOW(),
            PRIMARY KEY (`id`),
            KEY `idx_employee`   (`employee_id`),
            KEY `idx_created_at` (`created_at`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    });

    return 1;
}

sub upgrade {
    my ( $self, $args ) = @_;
    # Re-run install() so any new CREATE TABLE IF NOT EXISTS statements
    # take effect for users who installed older versions before the
    # tables were defined.
    return $self->install($args);
}

sub uninstall {
    my ( $self, $args ) = @_;
    my $dbh = C4::Context->dbh;
    $dbh->do('DROP TABLE IF EXISTS `koha_plugin_staffsched_audit`');
    $dbh->do('DROP TABLE IF EXISTS `koha_plugin_staffsched_assignments`');
    $dbh->do('DROP TABLE IF EXISTS `koha_plugin_staffsched_branch_colors`');
    $dbh->do('DROP TABLE IF EXISTS `koha_plugin_staffsched_zones`');
    return 1;
}

sub tool {
    my ( $self, $args ) = @_;

    # Koha's plugin dispatcher (cgi-bin/koha/plugins/run.pl) only
    # honors the "Use tool plugins" permission for method=tool. ANY
    # other method name (api, asset, configure, etc.) is gated behind
    # plugins.manage, which is superlibrarian-only on most installs.
    # That meant non-superlibrarian staff hit auth.tt ("Access denied")
    # whenever the React bundle called method=api. Workaround: also
    # serve the JSON API through method=tool, branching on the
    # presence of an `endpoint` query param.
    if ( defined scalar $self->{cgi}->param('endpoint') ) {
        return $self->api($args);
    }

    my $template = $self->get_template( { file => 'tool.tt' } );

    # Serve static assets and API through run.pl. The plugin REST API
    # (/api/v1/contrib/<ns>/*) does NOT register reliably on every
    # hosted Koha install, but run.pl always works because it's the
    # standard plugin dispatcher.
    my $run_pl_base = '/cgi-bin/koha/plugins/run.pl?class=' . __PACKAGE__;

    # Point the React bundle at method=tool (not method=api) so the
    # request rides on the "Use tool plugins" permission instead of
    # superlibrarian-only plugins.manage. The tool sub above detects
    # the `endpoint` param and dispatches to api() in JSON mode.
    my $api_base = "$run_pl_base&method=tool";

    # Hand-build a JS string literal for api_base. JSON::encode_json
    # croaks on a non-reference scalar in older JSON.pm versions, and
    # api_base only contains ASCII URL chars — no need for full JSON
    # escaping. This avoids the HTML-entity bug where '&' inside a
    # <script> rendered via [% ... | html %] became literal '&amp;'.
    my $api_base_js_escaped = $api_base;
    $api_base_js_escaped =~ s/\\/\\\\/g;
    $api_base_js_escaped =~ s/"/\\"/g;
    my $api_base_js = qq{"$api_base_js_escaped"};

    # Modern Koha (22.11+) requires a CSRF token on every intranet POST.
    # Without one, C4::Auth rejects the request with an empty 403 before
    # our plugin code ever runs. Generate one here and expose it on the
    # window so the React bundle can send it as X-CSRF-TOKEN.
    my $csrf_token = Koha::Token->new->generate_csrf({
        session_id => scalar $self->{cgi}->cookie('CGISESSID'),
    }) // '';
    my $csrf_token_escaped = $csrf_token;
    $csrf_token_escaped =~ s/\\/\\\\/g;
    $csrf_token_escaped =~ s/"/\\"/g;
    my $csrf_token_js = qq{"$csrf_token_escaped"};

    $template->param(
        asset_base    => "$run_pl_base&method=asset&v=$VERSION&file=",
        api_base      => $api_base,
        api_base_js   => $api_base_js,
        csrf_token_js => $csrf_token_js,
    );

    $self->output_html( $template->output() );
}

# Serves bundled static assets (index.js, index.css, favicon, etc.) through
# the standard plugin dispatcher. Requires staff auth (handled by run.pl).
sub asset {
    my ( $self, $args ) = @_;
    my $cgi  = $self->{'cgi'};
    my $file = scalar $cgi->param('file') // '';

    # Whitelist allowed files + their Content-Types
    my %types = (
        'index.js'    => 'application/javascript; charset=utf-8',
        'index.css'   => 'text/css; charset=utf-8',
        'favicon.svg' => 'image/svg+xml',
    );

    unless ( exists $types{$file} ) {
        print $cgi->header( -status => '404 Not Found', -type => 'text/plain' );
        print "Not found";
        return;
    }

    # Resolve under bundle/htdocs/dist/assets (or root for favicon)
    my $bundle = $self->bundle_path;
    my $path =
        $file =~ /\.(js|css)$/
        ? "$bundle/htdocs/dist/assets/$file"
        : "$bundle/htdocs/dist/$file";

    unless ( -r $path ) {
        print $cgi->header( -status => '404 Not Found', -type => 'text/plain' );
        print "Asset missing on disk";
        return;
    }

    open my $fh, '<:raw', $path
      or do {
        print $cgi->header( -status => '500 Internal Server Error', -type => 'text/plain' );
        print "Read error";
        return;
      };
    my $content = do { local $/; <$fh> };
    close $fh;

    # Versioned URL (?v=$VERSION) means a fresh plugin install changes
    # the URL — so we can safely cache forever per-URL. Use immutable so
    # browsers don't even revalidate.
    print $cgi->header(
        -type           => $types{$file},
        -cache_control  => 'public, max-age=600, must-revalidate',
    );
    print $content;
    return;
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $saved = 0;
    if ( $cgi->param('save') ) {
        # Verify CSRF token on save
        my $token_ok = Koha::Token->new->check_csrf({
            session_id => scalar $cgi->cookie('CGISESSID'),
            token      => scalar $cgi->param('csrf_token'),
        });
        if ($token_ok) {
            my $perm = scalar $cgi->param('edit_permission') || 'any_staff';
            $perm = 'any_staff' unless $perm =~ /^(any_staff|superlibrarian)$/;
            $self->store_data({
                staff_categorycode => scalar $cgi->param('staff_categorycode') || 'STAFF',
                edit_permission    => $perm,
            });
            $saved = 1;
        }
    }

    my $template = $self->get_template( { file => 'configure.tt' } );

    # Always generate a fresh CSRF token for the form
    my $csrf_token = Koha::Token->new->generate_csrf({
        session_id => scalar $cgi->cookie('CGISESSID'),
    });

    $template->param(
        staff_categorycode => $self->retrieve_data('staff_categorycode') || 'STAFF',
        edit_permission    => $self->retrieve_data('edit_permission')    || 'any_staff',
        csrf_token         => $csrf_token,
        saved              => $saved,
    );

    $self->output_html( $template->output() );
}


sub staff_categorycode {
    my ($self) = @_;
    return $self->retrieve_data('staff_categorycode') || 'STAFF';
}

sub _uuid { return lc( Data::UUID->new->create_str ); }

# Sentinel ID for the virtual "Out" location. The frontend treats this
# like any other branch in pickers, but on the server it has special
# meaning: an assignment with location_id=__OUT__ + is_base_shift=1
# means "this staff member is OUT for the day", and we clear all other
# assignments for that employee on that date.
use constant OUT_LOCATION_ID => '__OUT__';

# Check whether the borrower with the given borrowernumber is a
# superlibrarian, via Koha's own canonical API. This avoids relying on
# C4::Context->userenv->{flags}, which in different Koha versions is
# variously the raw int bitfield, a parsed hashref of permission names,
# or unpopulated entirely in plugin context — none of which we can
# safely bit-test ourselves.
sub _patron_is_superlibrarian {
    my ($borrowernumber) = @_;
    return 0 unless $borrowernumber;
    my $patron = eval { Koha::Patrons->find($borrowernumber) };
    return 0 unless $patron;
    return $patron->is_superlibrarian ? 1 : 0;
}

# Who counts as an "admin" for scheduler-write purposes — i.e. who
# can edit branch hours, other people's task zones, manage zones /
# branches / closures, run series edits, etc.
#
# As of v1.0.13 this is hardcoded to superlibrarian-only. Earlier
# builds let an admin loosen this to "any logged-in staff" via the
# Configure page, but that effectively gave everyone full write
# access — including overwriting other staff's schedules — which is
# never what we want. Non-superlibrarian staff still get the two
# things they need (read the calendar, mutate their OWN task zones),
# enforced in _assignment_write_allowed below. The Configure page's
# edit_permission field is retained for back-compat but no longer
# consulted at runtime.
sub _edit_permission { return 'superlibrarian'; }

sub _user_can_edit {
    my ( $self, $borrowernumber ) = @_;
    return _patron_is_superlibrarian($borrowernumber);
}

# Is the *current* Koha user allowed to edit?
sub _is_admin {
    my ($self) = @_;
    my $env = C4::Context->userenv;
    return 0 unless $env && $env->{number};
    return $self->_user_can_edit( $env->{number} );
}

# Guard rail for write endpoints. Returns 1 if we already emitted a
# 403 response (caller should bail), 0 if the user is authorized.
sub _require_admin {
    my ($self) = @_;
    return 0 if $self->_is_admin;
    my $env  = C4::Context->userenv;
    my $mode = $self->_edit_permission;
    my $msg  = $mode eq 'superlibrarian'
        ? 'Editing requires a Koha superlibrarian account.'
        : 'Editing requires a logged-in Koha staff account.';
    # Echo enough context that the admin can diagnose without server
    # logs — e.g. "I'm logged in as superlibrarian but still get 403".
    $self->_json_response( 403, {
        error               => $msg,
        edit_permission     => $mode,
        seen_borrowernumber => ( $env && $env->{number} ) ? "" . $env->{number} : undef,
        seen_is_superlib    => ( $env && $env->{number} )
            ? ( _patron_is_superlibrarian( $env->{number} ) ? \1 : \0 )
            : \0,
    });
    return 1;
}

sub _json_response {
    my ( $self, $status, $payload ) = @_;
    my $cgi = $self->{cgi};
    print $cgi->header(
        -status        => "$status " . ( $status == 200 ? 'OK' : $status == 201 ? 'Created' : $status == 204 ? 'No Content' : $status == 400 ? 'Bad Request' : $status == 401 ? 'Unauthorized' : $status == 404 ? 'Not Found' : 'Error' ),
        -type          => 'application/json',
        -charset       => 'UTF-8',
        -cache_control => 'no-store',
    );
    if ( $status != 204 && defined $payload ) {
        print encode_json($payload);
    }
    return;
}

sub _read_body {
    my ($self) = @_;
    my $cgi = $self->{cgi};

    # Hosted-Koha workaround: real POSTs to /cgi-bin/koha/plugins/run.pl
    # get rejected with an empty 403 by ByWater's intranet auth layer
    # before any plugin code runs (CSRF + WAF combined). The frontend
    # therefore tunnels mutations through GET with the JSON body
    # base64-encoded in the _body_b64 query param. Decode that first.
    my $b64 = scalar $cgi->param('_body_b64');
    if ( defined $b64 && length $b64 ) {
        require MIME::Base64;
        my $decoded = eval { MIME::Base64::decode_base64($b64) };
        if ( defined $decoded && length $decoded ) {
            return eval { decode_json($decoded) };
        }
    }

    my $raw = $cgi->param('POSTDATA') // $cgi->param('PUTDATA') // '';
    if ( !$raw && $ENV{CONTENT_LENGTH} ) {
        local $/;
        read( STDIN, $raw, $ENV{CONTENT_LENGTH} );
    }
    return $raw ? eval { decode_json($raw) } : undef;
}

# Unified API dispatcher — invoked via run.pl?method=api&endpoint=<name>
sub api {
    my ( $self, $args ) = @_;
    my $cgi      = $self->{cgi};
    my $endpoint = scalar( $cgi->param('endpoint') ) // '';
    # The frontend tunnels POST/PUT/DELETE through GET (see _read_body)
    # by passing the intended verb in _method. Honor that override so
    # downstream logic still sees the logical method.
    my $method   = uc( scalar( $cgi->param('_method') )
                      || $ENV{REQUEST_METHOD} || 'GET' );
    my $op       = scalar( $cgi->param('op') ) // '';

    try {
        my $body = ( $method ne 'GET' && $method ne 'HEAD' ) ? $self->_read_body : undef;
        # Also accept _body_b64 on plain GETs (so endpoints that branch
        # on $body still work when the call is tunneled).
        if ( !defined $body && scalar $cgi->param('_body_b64') ) {
            $body = $self->_read_body;
        }
        my $dbh  = C4::Context->dbh;

        if ( $endpoint eq 'ping' ) {
            return $self->_json_response( 200, { ok => \1, version => $VERSION, time => time() } );
        }
        elsif ( $endpoint eq 'me' ) {
            return $self->_api_me;
        }
        elsif ( $endpoint eq 'staff' ) {
            return $self->_api_staff($dbh);
        }
        elsif ( $endpoint eq 'branches' ) {
            return $self->_api_branches( $dbh, $method, $body, $cgi );
        }
        elsif ( $endpoint eq 'closures' ) {
            return $self->_api_closures($dbh);
        }
        elsif ( $endpoint eq 'zones' ) {
            return $self->_api_zones( $dbh, $method, $op, $body, $cgi );
        }
        elsif ( $endpoint eq 'assignments' ) {
            return $self->_api_assignments( $dbh, $method, $op, $body, $cgi );
        }
        elsif ( $endpoint eq 'audit' ) {
            return $self->_api_audit( $dbh, $method, $body, $cgi );
        }
        else {
            return $self->_json_response( 404, { error => "Unknown endpoint: '$endpoint'" } );
        }
    }
    catch {
        my $err = "$_";
        warn "StaffScheduler api error: $err";
        return $self->_json_response( 500, { error => $err } );
    };
}

sub _api_me {
    my ($self) = @_;
    my $env = C4::Context->userenv;
    unless ( $env && $env->{number} ) {
        return $self->_json_response( 401, { error => 'Not authenticated' } );
    }
    my $first = $env->{firstname} // '';
    my $sur   = $env->{surname}   // '';
    my $name  = $first ? "$first $sur" : $sur;
    my $flags = $env->{flags} // 0;
    return $self->_json_response(
        200,
        {
            id       => "" . $env->{number},
            name     => $name,
            email    => $env->{emailaddress} // '',
            is_admin => $self->_user_can_edit( $env->{number} ) ? \1 : \0,
            is_superlibrarian => _patron_is_superlibrarian( $env->{number} ) ? \1 : \0,
            edit_permission   => $self->_edit_permission,
        }
    );
}

sub _api_staff {
    my ( $self, $dbh ) = @_;
    my $cat  = $self->staff_categorycode;
    my $rows = $dbh->selectall_arrayref(
        q{SELECT borrowernumber, firstname, surname, email, branchcode, categorycode, flags
          FROM borrowers WHERE categorycode = ? ORDER BY surname, firstname},
        { Slice => {} }, $cat
    );
    my @out;
    for my $r (@$rows) {
        my $first = $r->{firstname} // '';
        my $sur   = $r->{surname}   // '';
        my $name  = $first ? "$first $sur" : $sur;
        my $flags = $r->{flags}     // 0;
        push @out, {
            id        => "" . $r->{borrowernumber},
            name      => $name,
            email     => $r->{email} // '',
            is_admin  => $self->_user_can_edit( $r->{borrowernumber} ) ? \1 : \0,
            is_active => \1,
            role_id   => $r->{categorycode} // $cat,
            team_id   => undef,
        };
    }
    return $self->_json_response( 200, \@out );
}

sub _api_branches {
    my ( $self, $dbh, $method, $body, $cgi ) = @_;
    if ( $method eq 'GET' ) {
        my $rows = $dbh->selectall_arrayref(
            q{SELECT b.branchcode, b.branchname,
                     COALESCE(c.color_code, '#eab308') AS color_code
              FROM branches b
              LEFT JOIN koha_plugin_staffsched_branch_colors c
                ON b.branchcode = c.branchcode
              ORDER BY b.branchname},
            { Slice => {} }
        );
        # Color override for the virtual OUT location lives in the same
        # branch_colors table, keyed by the sentinel id.
        my $out_color_row = $dbh->selectrow_hashref(
            q{SELECT color_code FROM koha_plugin_staffsched_branch_colors
              WHERE branchcode = ?},
            undef, OUT_LOCATION_ID
        );
        my $out_color = ( $out_color_row && $out_color_row->{color_code} )
                      ? $out_color_row->{color_code}
                      : '#9ca3af';
        my @out = (
            {
                id         => OUT_LOCATION_ID,
                name       => 'Out',
                color_code => $out_color,
                is_active  => \1,
                is_virtual => \1,
            },
            map {
                {
                    id         => $_->{branchcode},
                    name       => $_->{branchname} // $_->{branchcode},
                    color_code => $_->{color_code},
                    is_active  => \1,
                }
            } @$rows
        );
        return $self->_json_response( 200, \@out );
    }
    elsif ( $method eq 'POST' ) {
        return if $self->_require_admin;
        my $branchcode = scalar( $cgi->param('id') ) // ( $body && $body->{branchcode} ) // '';
        my $color      = ( $body && $body->{color_code} ) // '#eab308';
        return $self->_json_response( 400, { error => 'branchcode required' } )
          unless $branchcode;
        $dbh->do(
            q{INSERT INTO koha_plugin_staffsched_branch_colors (branchcode, color_code)
              VALUES (?, ?)
              ON DUPLICATE KEY UPDATE color_code = VALUES(color_code)},
            undef, $branchcode, $color
        );
        return $self->_json_response( 200,
            { branchcode => $branchcode, color_code => $color } );
    }
    return $self->_json_response( 405, { error => "Method $method not allowed" } );
}

sub _api_closures {
    my ( $self, $dbh ) = @_;
    my @out;
    my $sp = $dbh->selectall_arrayref(
        q{SELECT id, branchcode, day, month, year, title, description
          FROM special_holidays
          WHERE COALESCE(isexception, 0) = 0 AND year > 0},
        { Slice => {} }
    );
    for my $r (@$sp) {
        push @out, {
            id           => 'sp-' . $r->{id},
            closure_date => sprintf( '%04d-%02d-%02d', $r->{year}, $r->{month}, $r->{day} ),
            description  => $r->{title} || $r->{description} || 'Holiday',
            location_id  => $r->{branchcode},
        };
    }
    my $rep = $dbh->selectall_arrayref(
        q{SELECT id, branchcode, day, month, title, description
          FROM repeatable_holidays WHERE day > 0 AND month > 0},
        { Slice => {} }
    );
    my $cur_year = ( localtime )[5] + 1900;
    for my $y ( $cur_year, $cur_year + 1 ) {
        for my $r (@$rep) {
            push @out, {
                id           => "rep-$r->{id}-$y",
                closure_date => sprintf( '%04d-%02d-%02d', $y, $r->{month}, $r->{day} ),
                description  => $r->{title} || $r->{description} || 'Holiday',
                location_id  => $r->{branchcode},
            };
        }
    }
    return $self->_json_response( 200, \@out );
}

sub _api_zones {
    my ( $self, $dbh, $method, $op, $body, $cgi ) = @_;
    if ( $method eq 'GET' ) {
        my $rows = $dbh->selectall_arrayref(
            q{SELECT id, name, color_code, is_active
              FROM koha_plugin_staffsched_zones ORDER BY name},
            { Slice => {} }
        );
        my @out = map {
            {
                id         => $_->{id},
                name       => $_->{name},
                color_code => $_->{color_code},
                is_active  => $_->{is_active} ? \1 : \0,
            }
        } @$rows;
        return $self->_json_response( 200, \@out );
    }
    elsif ( $method eq 'POST' && $op eq 'delete' ) {
        return if $self->_require_admin;
        my $id = scalar( $cgi->param('id') ) // '';
        return $self->_json_response( 400, { error => 'id required' } ) unless $id;
        $dbh->do( 'DELETE FROM koha_plugin_staffsched_zones WHERE id = ?',
            undef, $id );
        return $self->_json_response( 204, undef );
    }
    elsif ( $method eq 'POST' && $op eq 'update' ) {
        return if $self->_require_admin;
        my $id = scalar( $cgi->param('id') ) // '';
        return $self->_json_response( 400, { error => 'id required' } ) unless $id;
        my @sets;
        my @vals;
        for my $col (qw(name color_code is_active)) {
            next unless $body && exists $body->{$col};
            my $v = $body->{$col};
            $v = $v ? 1 : 0 if $col eq 'is_active';
            push @sets, "$col = ?";
            push @vals, $v;
        }
        if (@sets) {
            $dbh->do(
                'UPDATE koha_plugin_staffsched_zones SET '
                  . join( ', ', @sets )
                  . ' WHERE id = ?',
                undef, @vals, $id
            );
        }
        my $row = $dbh->selectrow_hashref(
            q{SELECT id, name, color_code, is_active
              FROM koha_plugin_staffsched_zones WHERE id = ?},
            undef, $id
        ) || {};
        return $self->_json_response(
            200,
            {
                id         => $row->{id},
                name       => $row->{name},
                color_code => $row->{color_code},
                is_active  => $row->{is_active} ? \1 : \0,
            }
        );
    }
    elsif ( $method eq 'POST' ) {
        return if $self->_require_admin;
        my $id     = _uuid();
        my $name   = ( $body && $body->{name} )       // 'Untitled';
        my $color  = ( $body && $body->{color_code} ) // '#bbf7d0';
        my $active = ( $body && exists $body->{is_active} )
          ? ( $body->{is_active} ? 1 : 0 )
          : 1;
        $dbh->do(
            q{INSERT INTO koha_plugin_staffsched_zones (id, name, color_code, is_active)
              VALUES (?, ?, ?, ?)},
            undef, $id, $name, $color, $active
        );
        return $self->_json_response(
            201,
            {
                id         => $id,
                name       => $name,
                color_code => $color,
                is_active  => $active ? \1 : \0,
            }
        );
    }
    return $self->_json_response( 405, { error => "Method $method not allowed" } );
}

sub _assignment_row_to_obj {
    my ($r) = @_;
    return {
        id            => $r->{id},
        employee_id   => "" . $r->{employee_id},
        zone_id       => $r->{zone_id},
        location_id   => $r->{location_id},
        shift_date    => $r->{shift_date},
        start_time    => $r->{start_time},
        end_time      => $r->{end_time},
        is_base_shift => $r->{is_base_shift} ? \1 : \0,
        series_id     => $r->{series_id},
        custom_label  => $r->{custom_label},
        notes         => $r->{notes},
    };
}

sub _insert_assignment {
    my ( $dbh, $a ) = @_;
    my $id = _uuid();
    $dbh->do(
        q{INSERT INTO koha_plugin_staffsched_assignments
              (id, employee_id, zone_id, location_id, shift_date,
               start_time, end_time, is_base_shift, series_id,
               custom_label, notes)
          VALUES (?,?,?,?,?,?,?,?,?,?,?)},
        undef,
        $id,
        int( $a->{employee_id} // 0 ),
        $a->{zone_id},
        $a->{location_id},
        $a->{shift_date},
        $a->{start_time},
        $a->{end_time},
        ( $a->{is_base_shift} ? 1 : 0 ),
        $a->{series_id},
        $a->{custom_label},
        $a->{notes},
    );
    _apply_out_override( $dbh, $id, $a );
    my $row = $dbh->selectrow_hashref(
        q{SELECT * FROM koha_plugin_staffsched_assignments WHERE id = ?},
        undef, $id
    );
    return _assignment_row_to_obj($row);
}

# If this assignment marks the employee as OUT for the day, wipe out
# every other assignment (branch hours AND task zones) for that
# employee on that date. "Out" is total: no branch, no zone work.
sub _apply_out_override {
    my ( $dbh, $id, $a ) = @_;
    return unless $a && $a->{is_base_shift};
    return unless ( $a->{location_id} // '' ) eq OUT_LOCATION_ID;
    my $emp   = int( $a->{employee_id} // 0 );
    my $date  = $a->{shift_date};
    my $start = $a->{start_time};
    my $end   = $a->{end_time};
    return unless $emp && $date && $start && $end;

    # Delete only assignments that OVERLAP the OUT window — someone
    # can't be OUT and assigned to a zone at the same time, but a
    # different zone block earlier or later that day is still valid.
    # Half-open overlap: existing.start < OUT.end AND existing.end > OUT.start.
    $dbh->do(
        q{DELETE FROM koha_plugin_staffsched_assignments
          WHERE employee_id = ?
            AND shift_date  = ?
            AND id         <> ?
            AND start_time  < ?
            AND end_time    > ?},
        undef, $emp, $date, $id, $end, $start
    );
}

# Current user's borrowernumber, or 0 if not logged in.
sub _current_borrowernumber {
    my $env = C4::Context->userenv;
    return ( $env && $env->{number} ) ? int( $env->{number} ) : 0;
}

# Display name "First Last" for the current user, for audit log.
sub _current_display_name {
    my $env = C4::Context->userenv;
    return 'System' unless $env;
    my $first = $env->{firstname} // '';
    my $sur   = $env->{surname}   // '';
    my $name  = $first ? "$first $sur" : $sur;
    return $name || ( $env->{cardnumber} // 'System' );
}

# Permission rule for assignment writes:
#   - Admins (per Configure setting) can do anything.
#   - Non-admin staff can only mutate TASK ZONES (is_base_shift = 0)
#     whose employee_id is their own borrowernumber.
#   - $existing is the row already in the DB (undef for inserts).
#   - $proposed is what they want it to become (undef for deletes).
# Returns (1, '') if allowed, (0, $reason) if not.
sub _assignment_write_allowed {
    my ( $self, $existing, $proposed ) = @_;
    return ( 1, '' ) if $self->_is_admin;

    my $me = _current_borrowernumber;
    return ( 0, 'Not authenticated' ) unless $me;

    if ($existing) {
        return ( 0, 'Only superlibrarians can modify branch hours' )
            if $existing->{is_base_shift};
        return ( 0, "You can only modify your own task zones" )
            if int( $existing->{employee_id} // 0 ) != $me;
    }
    if ($proposed) {
        return ( 0, 'Only superlibrarians can create branch hours' )
            if $proposed->{is_base_shift};
        my $emp = int( $proposed->{employee_id} // 0 );
        return ( 0, "You can only create task zones for yourself" )
            if $emp && $emp != $me;
    }
    return ( 1, '' );
}

# Write one audit row. Best-effort: failures here must never block the
# real write that already succeeded.
sub _write_audit {
    my ( $self, $dbh, $employee_id, $action_type, $details ) = @_;
    eval {
        $dbh->do(
            q{INSERT INTO koha_plugin_staffsched_audit
                  (employee_id, action_type, details, changed_by)
              VALUES (?, ?, ?, ?)},
            undef,
            ( defined $employee_id && $employee_id ne '' )
                ? int($employee_id) : undef,
            $action_type,
            $details // '',
            $self->_current_display_name,
        );
    };
}

sub _audit_kind {
    my ($row_or_payload) = @_;
    return $row_or_payload->{is_base_shift} ? 'BRANCH_SHIFT' : 'ZONE_SHIFT';
}

sub _audit_summary {
    my ($a) = @_;
    return '' unless $a;
    my $date  = $a->{shift_date}  // '';
    my $start = ( $a->{start_time} // '' );
    my $end   = ( $a->{end_time}   // '' );
    $start =~ s/:00$//; $end =~ s/:00$//;
    return "$date $start-$end";
}

sub _api_assignments {
    my ( $self, $dbh, $method, $op, $body, $cgi ) = @_;
    if ( $method eq 'GET' ) {
        my $date = scalar $cgi->param('shift_date');
        my $from = scalar $cgi->param('from');
        my $to   = scalar $cgi->param('to');
        my $sql  = q{SELECT id, employee_id, zone_id, location_id, shift_date,
                            start_time, end_time, is_base_shift, series_id,
                            custom_label, notes
                     FROM koha_plugin_staffsched_assignments};
        my @where;
        my @vals;
        if ($date) { push @where, 'shift_date = ?';  push @vals, $date; }
        elsif ($from) {
            push @where, 'shift_date >= ?';
            push @vals, $from;
            if ($to) { push @where, 'shift_date <= ?'; push @vals, $to; }
        }
        $sql .= ' WHERE ' . join( ' AND ', @where ) if @where;
        $sql .= ' ORDER BY shift_date, start_time';
        my $rows = $dbh->selectall_arrayref( $sql, { Slice => {} }, @vals );
        return $self->_json_response( 200,
            [ map { _assignment_row_to_obj($_) } @$rows ] );
    }
    elsif ( $method eq 'POST' && $op eq 'delete' ) {
        my $id         = scalar $cgi->param('id');
        my $series_id  = scalar $cgi->param('series_id');
        my $after_date = scalar $cgi->param('after_date');

        # Series delete is admin-only — it can affect rows belonging to
        # anyone in the series. Single delete: check the row's owner.
        if ( $series_id && $after_date ) {
            return if $self->_require_admin;
            my $rows = $dbh->selectall_arrayref(
                q{SELECT id, employee_id, is_base_shift, shift_date,
                         start_time, end_time
                  FROM koha_plugin_staffsched_assignments
                  WHERE series_id = ? AND shift_date >= ?},
                { Slice => {} }, $series_id, $after_date
            );
            $dbh->do(
                q{DELETE FROM koha_plugin_staffsched_assignments
                  WHERE series_id = ? AND shift_date >= ?},
                undef, $series_id, $after_date
            );
            for my $r (@$rows) {
                $self->_write_audit( $dbh, $r->{employee_id},
                    _audit_kind($r) . '_DELETE',
                    'Series delete: ' . _audit_summary($r) );
            }
            return $self->_json_response( 204, undef );
        }

        my $existing = $dbh->selectrow_hashref(
            q{SELECT * FROM koha_plugin_staffsched_assignments WHERE id = ?},
            undef, $id
        );
        return $self->_json_response( 404, { error => 'Not found' } )
            unless $existing;
        my ( $ok, $why ) = $self->_assignment_write_allowed( $existing, undef );
        return $self->_json_response( 403, { error => $why } ) unless $ok;
        $dbh->do(
            q{DELETE FROM koha_plugin_staffsched_assignments WHERE id = ?},
            undef, $id
        );
        $self->_write_audit( $dbh, $existing->{employee_id},
            _audit_kind($existing) . '_DELETE',
            'Deleted ' . _audit_summary($existing) );
        return $self->_json_response( 204, undef );
    }
    elsif ( $method eq 'POST' && $op eq 'update' ) {
        my $id         = scalar $cgi->param('id');
        my $series_id  = scalar $cgi->param('series_id');
        my $after_date = scalar $cgi->param('after_date');

        # Series update is admin-only (it can rewrite many rows).
        if ( $series_id && $after_date ) {
            return if $self->_require_admin;
        }
        else {
            my $existing = $dbh->selectrow_hashref(
                q{SELECT * FROM koha_plugin_staffsched_assignments WHERE id = ?},
                undef, $id
            );
            return $self->_json_response( 404, { error => 'Not found' } )
                unless $existing;
            # Merge proposed body onto existing for the check.
            my %proposed = %$existing;
            for my $k ( keys %{ $body || {} } ) {
                $proposed{$k} = $body->{$k};
            }
            my ( $ok, $why ) = $self->_assignment_write_allowed(
                $existing, \%proposed );
            return $self->_json_response( 403, { error => $why } ) unless $ok;
        }

        my @cols = qw(employee_id zone_id location_id shift_date start_time
                      end_time is_base_shift series_id custom_label notes);
        my @sets;
        my @vals;
        for my $col (@cols) {
            next unless $body && exists $body->{$col};
            my $v = $body->{$col};
            $v = $v ? 1 : 0     if $col eq 'is_base_shift';
            $v = int( $v // 0 ) if $col eq 'employee_id';
            push @sets, "$col = ?";
            push @vals, $v;
        }
        return $self->_json_response( 400, { error => 'No fields' } ) unless @sets;
        my $sql = 'UPDATE koha_plugin_staffsched_assignments SET '
          . join( ', ', @sets );
        if ( $series_id && $after_date ) {
            $sql .= ' WHERE series_id = ? AND shift_date >= ?';
            $dbh->do( $sql, undef, @vals, $series_id, $after_date );
        }
        else {
            $sql .= ' WHERE id = ?';
            $dbh->do( $sql, undef, @vals, $id );
        }
        my $row = $dbh->selectrow_hashref(
            q{SELECT * FROM koha_plugin_staffsched_assignments WHERE id = ?},
            undef, $id
        );
        # If the update flipped this assignment into an OUT marker,
        # wipe out the day's other assignments too.
        _apply_out_override( $dbh, $id, $row ) if $row;
        if ($row) {
            $self->_write_audit( $dbh, $row->{employee_id},
                _audit_kind($row) . '_UPDATE',
                'Updated ' . _audit_summary($row) );
        }
        return $self->_json_response( 200,
            $row ? _assignment_row_to_obj($row) : { id => $id } );
    }
    elsif ( $method eq 'POST' ) {
        return $self->_json_response( 400, { error => 'Invalid payload' } )
          unless ref($body);
        my @items = ref($body) eq 'ARRAY' ? @$body : ($body);
        for my $item (@items) {
            my ( $ok, $why ) =
                $self->_assignment_write_allowed( undef, $item );
            return $self->_json_response( 403, { error => $why } ) unless $ok;
        }
        my @created;
        for my $item (@items) {
            my $obj = _insert_assignment( $dbh, $item );
            push @created, $obj;
            $self->_write_audit( $dbh, $item->{employee_id},
                _audit_kind($item) . '_CREATE',
                'Created ' . _audit_summary($item) );
        }
        if ( ref($body) eq 'ARRAY' ) {
            return $self->_json_response( 201, \@created );
        }
        return $self->_json_response( 201, $created[0] );
    }
    return $self->_json_response( 405, { error => "Method $method not allowed" } );
}

sub _api_audit {
    my ( $self, $dbh, $method, $body, $cgi ) = @_;
    if ( $method eq 'GET' ) {
        my $from = scalar $cgi->param('from');
        my $to   = scalar $cgi->param('to');
        my $sql  = q{SELECT a.id, a.employee_id, a.action_type, a.details,
                            a.changed_by, a.created_at,
                            TRIM(CONCAT_WS(' ', b.firstname, b.surname)) AS employee_name
                     FROM koha_plugin_staffsched_audit a
                     LEFT JOIN borrowers b ON b.borrowernumber = a.employee_id};
        my @where;
        my @vals;
        if ($from) { push @where, 'a.created_at >= ?'; push @vals, "$from 00:00:00"; }
        if ($to)   { push @where, 'a.created_at <= ?'; push @vals, "$to 23:59:59"; }
        $sql .= ' WHERE ' . join( ' AND ', @where ) if @where;
        $sql .= ' ORDER BY a.created_at DESC LIMIT 500';
        my $rows = $dbh->selectall_arrayref( $sql, { Slice => {} }, @vals );
        my @out  = map {
            {
                id            => "" . $_->{id},
                employee_id   => defined $_->{employee_id} ? "" . $_->{employee_id} : undef,
                action_type   => $_->{action_type},
                details       => $_->{details},
                changed_by    => $_->{changed_by},
                created_at    => $_->{created_at},
                employee_name => $_->{employee_name},
            }
        } @$rows;
        return $self->_json_response( 200, \@out );
    }
    elsif ( $method eq 'POST' ) {
        # Any logged-in staff can append to the audit log — server-side
        # writes already record every assignment mutation, but the
        # frontend may still post supplementary entries (e.g. notes on
        # bulk operations) that should never be silently dropped.
        $body ||= {};
        $dbh->do(
            q{INSERT INTO koha_plugin_staffsched_audit
                  (employee_id, action_type, details, changed_by)
              VALUES (?, ?, ?, ?)},
            undef,
            ( defined $body->{employee_id} && $body->{employee_id} ne '' )
              ? int( $body->{employee_id} )
              : undef,
            $body->{action_type} // 'unknown',
            $body->{details}     // '',
            $body->{changed_by}  // '',
        );
        return $self->_json_response( 201, { ok => \1 } );
    }
    return $self->_json_response( 405, { error => "Method $method not allowed" } );
}

1;
