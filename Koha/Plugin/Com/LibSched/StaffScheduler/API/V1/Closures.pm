package Koha::Plugin::Com::LibSched::StaffScheduler::API::V1::Closures;

use Modern::Perl;
use Mojo::Base 'Mojolicious::Controller';
use C4::Context;

# Returns closure events derived from Koha holidays.
# - special_holidays: specific calendar dates
# - repeatable_holidays with year=0: annual (expanded for this and next year)
sub list {
    my $c   = shift;
    my $dbh = C4::Context->dbh;

    my @out;

    my $sp = $dbh->selectall_arrayref(
        q{
            SELECT id, branchcode, day, month, year, title, description
            FROM special_holidays
            WHERE COALESCE(isexception, 0) = 0
              AND year > 0
        },
        { Slice => {} }
    );
    for my $r (@$sp) {
        my $date = sprintf( '%04d-%02d-%02d', $r->{year}, $r->{month}, $r->{day} );
        push @out, {
            id           => 'sp-' . $r->{id},
            closure_date => $date,
            description  => $r->{title} || $r->{description} || 'Holiday',
            location_id  => $r->{branchcode},
        };
    }

    my $rep = $dbh->selectall_arrayref(
        q{
            SELECT id, branchcode, day, month, title, description
            FROM repeatable_holidays
            WHERE day > 0 AND month > 0
        },
        { Slice => {} }
    );
    my ($cur_year) = (localtime)[5];
    $cur_year += 1900;
    for my $y ( $cur_year, $cur_year + 1 ) {
        for my $r (@$rep) {
            my $date = sprintf( '%04d-%02d-%02d', $y, $r->{month}, $r->{day} );
            push @out, {
                id           => "rep-$r->{id}-$y",
                closure_date => $date,
                description  => $r->{title} || $r->{description} || 'Holiday',
                location_id  => $r->{branchcode},
            };
        }
    }

    return $c->render(status => 200, json => \@out);
}

1;
