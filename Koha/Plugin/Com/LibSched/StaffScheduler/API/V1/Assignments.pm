package Koha::Plugin::Com::LibSched::StaffScheduler::API::V1::Assignments;

use Modern::Perl;
use Mojo::Base 'Mojolicious::Controller';
use C4::Context;
use Data::UUID;

sub _uuid {
    return lc( Data::UUID->new->create_str );
}

sub _row_to_obj {
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

sub list {
    my $c    = shift;
    my $date = $c->param('shift_date');
    my $from = $c->param('from');
    my $to   = $c->param('to');

    my $dbh = C4::Context->dbh;
    my $sql = q{
        SELECT id, employee_id, zone_id, location_id, shift_date,
               start_time, end_time, is_base_shift, series_id,
               custom_label, notes
        FROM koha_plugin_staffsched_assignments
    };
    my @where;
    my @vals;
    if ($date) {
        push @where, 'shift_date = ?';
        push @vals,  $date;
    }
    elsif ($from) {
        push @where, 'shift_date >= ?';
        push @vals,  $from;
        if ($to) {
            push @where, 'shift_date <= ?';
            push @vals,  $to;
        }
    }
    $sql .= ' WHERE ' . join( ' AND ', @where ) if @where;
    $sql .= ' ORDER BY shift_date, start_time';
    my $rows = $dbh->selectall_arrayref( $sql, { Slice => {} }, @vals );
    return $c->render( status => 200, json => [ map { _row_to_obj($_) } @$rows ] );
}

sub _insert_one {
    my ( $dbh, $a ) = @_;
    my $id = _uuid();
    $dbh->do(
        q{
            INSERT INTO koha_plugin_staffsched_assignments
                (id, employee_id, zone_id, location_id, shift_date,
                 start_time, end_time, is_base_shift, series_id,
                 custom_label, notes)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
        },
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
    my $row = $dbh->selectrow_hashref(
        q{SELECT * FROM koha_plugin_staffsched_assignments WHERE id = ?},
        undef, $id
    );
    return _row_to_obj($row);
}

sub create {
    my $c       = shift;
    my $payload = $c->req->json;
    my $dbh     = C4::Context->dbh;

    if ( ref($payload) eq 'ARRAY' ) {
        my @created = map { _insert_one( $dbh, $_ ) } @$payload;
        return $c->render( status => 201, json => \@created );
    }
    elsif ( ref($payload) eq 'HASH' ) {
        my $created = _insert_one( $dbh, $payload );
        return $c->render( status => 201, json => $created );
    }
    return $c->render( status => 400, json => { error => 'Invalid payload' } );
}

sub update {
    my $c          = shift;
    my $id         = $c->param('assignment_id');
    my $series_id  = $c->param('series_id');
    my $after_date = $c->param('after_date');
    my $payload    = $c->req->json // {};

    my @cols = qw(employee_id zone_id location_id shift_date start_time end_time
                  is_base_shift series_id custom_label notes);
    my @sets;
    my @vals;
    for my $col (@cols) {
        next unless exists $payload->{$col};
        my $v = $payload->{$col};
        $v = $v ? 1 : 0          if $col eq 'is_base_shift';
        $v = int( $v // 0 )      if $col eq 'employee_id';
        push @sets, "$col = ?";
        push @vals, $v;
    }
    return $c->render( status => 400, json => { error => 'No fields to update' } )
      unless @sets;

    my $dbh = C4::Context->dbh;
    my $sql = 'UPDATE koha_plugin_staffsched_assignments SET ' . join( ', ', @sets );

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
    return $c->render( status => 200, json => $row ? _row_to_obj($row) : { id => $id } );
}

sub delete {
    my $c          = shift;
    my $id         = $c->param('assignment_id');
    my $series_id  = $c->param('series_id');
    my $after_date = $c->param('after_date');

    my $dbh = C4::Context->dbh;
    if ( $series_id && $after_date ) {
        $dbh->do(
            q{DELETE FROM koha_plugin_staffsched_assignments
              WHERE series_id = ? AND shift_date >= ?},
            undef, $series_id, $after_date
        );
    }
    else {
        $dbh->do(
            q{DELETE FROM koha_plugin_staffsched_assignments WHERE id = ?},
            undef, $id
        );
    }
    return $c->rendered(204);
}

1;
