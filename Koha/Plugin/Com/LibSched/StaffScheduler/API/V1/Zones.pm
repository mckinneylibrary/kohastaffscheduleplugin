package Koha::Plugin::Com::LibSched::StaffScheduler::API::V1::Zones;

use Modern::Perl;
use Mojo::Base 'Mojolicious::Controller';
use C4::Context;
use Data::UUID;

sub _uuid {
    return lc( Data::UUID->new->create_str );
}

sub list {
    my $c   = shift;
    my $dbh = C4::Context->dbh;
    my $rows = $dbh->selectall_arrayref(
        q{
            SELECT id, name, color_code, is_active
            FROM koha_plugin_staffsched_zones
            ORDER BY name
        },
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
    return $c->render(status => 200, json => \@out);
}

sub create {
    my $c       = shift;
    my $payload = $c->req->json // {};
    my $id      = _uuid();
    my $name    = $payload->{name}       // 'Untitled';
    my $color   = $payload->{color_code} // '#bbf7d0';
    my $active  = exists $payload->{is_active} ? ( $payload->{is_active} ? 1 : 0 ) : 1;

    my $dbh = C4::Context->dbh;
    $dbh->do(
        q{
            INSERT INTO koha_plugin_staffsched_zones (id, name, color_code, is_active)
            VALUES (?, ?, ?, ?)
        },
        undef, $id, $name, $color, $active
    );
    return $c->render(
        status => 201,
        json   => {
            id         => $id,
            name       => $name,
            color_code => $color,
            is_active  => $active ? \1 : \0,
        }
    );
}

sub update {
    my $c       = shift;
    my $id      = $c->param('zone_id');
    my $payload = $c->req->json // {};

    my $dbh = C4::Context->dbh;
    my @sets;
    my @vals;
    for my $col (qw(name color_code is_active)) {
        next unless exists $payload->{$col};
        my $v = $payload->{$col};
        $v = $v ? 1 : 0 if $col eq 'is_active';
        push @sets, "$col = ?";
        push @vals, $v;
    }
    if (@sets) {
        my $sql = 'UPDATE koha_plugin_staffsched_zones SET '
          . join( ', ', @sets ) . ' WHERE id = ?';
        $dbh->do( $sql, undef, @vals, $id );
    }
    my $row = $dbh->selectrow_hashref(
        q{SELECT id, name, color_code, is_active FROM koha_plugin_staffsched_zones WHERE id = ?},
        undef, $id
    ) || {};
    return $c->render(
        status => 200,
        json   => {
            id         => $row->{id},
            name       => $row->{name},
            color_code => $row->{color_code},
            is_active  => $row->{is_active} ? \1 : \0,
        }
    );
}

1;
