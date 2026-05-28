package Koha::Plugin::Com::LibSched::StaffScheduler::API::V1::Staff;

use Modern::Perl;
use Mojo::Base 'Mojolicious::Controller';
use C4::Context;
use Koha::Plugin::Com::LibSched::StaffScheduler;

sub list {
    my $c = shift;
    my $plugin = Koha::Plugin::Com::LibSched::StaffScheduler->new;
    my $cat    = $plugin->staff_categorycode;

    my $dbh = C4::Context->dbh;
    my $rows = $dbh->selectall_arrayref(
        q{
            SELECT borrowernumber, firstname, surname, email,
                   branchcode, categorycode, flags
            FROM borrowers
            WHERE categorycode = ?
            ORDER BY surname, firstname
        },
        { Slice => {} }, $cat
    );

    my @staff;
    for my $r (@$rows) {
        my $first = $r->{firstname} // '';
        my $sur   = $r->{surname}   // '';
        my $name  = $first ? "$first $sur" : $sur;
        my $flags = $r->{flags} // 0;
        push @staff, {
            id        => "" . $r->{borrowernumber},
            name      => $name,
            email     => $r->{email} // '',
            is_admin  => ( $flags && ( $flags == 1 || ( $flags & 1 ) ) ) ? \1 : \0,
            is_active => \1,
            role_id   => $r->{categorycode} // $cat,
            team_id   => undef,
        };
    }

    return $c->render(status => 200, json => \@staff);
}

1;
