package Koha::Plugin::Com::LibSched::StaffScheduler::API::V1::Audit;

use Modern::Perl;
use Mojo::Base 'Mojolicious::Controller';
use C4::Context;

sub list {
    my $c    = shift;
    my $from = $c->param('from');
    my $to   = $c->param('to');

    my $dbh = C4::Context->dbh;
    my $sql = q{
        SELECT a.id, a.employee_id, a.action_type, a.details,
               a.changed_by, a.created_at,
               TRIM(CONCAT_WS(' ', b.firstname, b.surname)) AS employee_name
        FROM koha_plugin_staffsched_audit a
        LEFT JOIN borrowers b ON b.borrowernumber = a.employee_id
    };
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
    return $c->render( status => 200, json => \@out );
}

sub create {
    my $c       = shift;
    my $payload = $c->req->json // {};
    my $dbh     = C4::Context->dbh;
    $dbh->do(
        q{
            INSERT INTO koha_plugin_staffsched_audit
                (employee_id, action_type, details, changed_by)
            VALUES (?, ?, ?, ?)
        },
        undef,
        ( defined $payload->{employee_id} && $payload->{employee_id} ne '' )
          ? int( $payload->{employee_id} )
          : undef,
        $payload->{action_type} // 'unknown',
        $payload->{details}     // '',
        $payload->{changed_by}  // '',
    );
    return $c->render( status => 201, json => { ok => \1 } );
}

1;
