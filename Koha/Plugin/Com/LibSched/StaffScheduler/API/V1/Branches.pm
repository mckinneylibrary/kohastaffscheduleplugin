package Koha::Plugin::Com::LibSched::StaffScheduler::API::V1::Branches;

use Modern::Perl;
use Mojo::Base 'Mojolicious::Controller';
use C4::Context;

sub list {
    my $c   = shift;
    my $dbh = C4::Context->dbh;
    my $rows = $dbh->selectall_arrayref(
        q{
            SELECT b.branchcode, b.branchname,
                   COALESCE(c.color_code, '#eab308') AS color_code
            FROM branches b
            LEFT JOIN koha_plugin_staffsched_branch_colors c
              ON b.branchcode = c.branchcode
            ORDER BY b.branchname
        },
        { Slice => {} }
    );
    my @out = map {
        {
            id         => $_->{branchcode},
            name       => $_->{branchname} // $_->{branchcode},
            color_code => $_->{color_code},
            is_active  => \1,
        }
    } @$rows;
    return $c->render(status => 200, json => \@out);
}

sub update_color {
    my $c          = shift;
    my $branchcode = $c->param('branchcode');
    my $payload    = $c->req->json // {};
    my $color      = $payload->{color_code} // '#eab308';

    my $dbh = C4::Context->dbh;
    $dbh->do(
        q{
            INSERT INTO koha_plugin_staffsched_branch_colors (branchcode, color_code)
            VALUES (?, ?)
            ON DUPLICATE KEY UPDATE color_code = VALUES(color_code)
        },
        undef, $branchcode, $color
    );
    return $c->render(status => 200, json => { branchcode => $branchcode, color_code => $color });
}

1;
