package Koha::Plugin::Com::LibSched::StaffScheduler::API::V1::Me;

use Modern::Perl;
use Mojo::Base 'Mojolicious::Controller';

sub get {
    my $c = shift;
    my $user = $c->stash('koha.user');
    unless ($user) {
        return $c->render(status => 401, json => { error => 'Not authenticated' });
    }
    my $flags = eval { $user->flags } // 0;
    my $first = eval { $user->firstname } // '';
    my $sur   = eval { $user->surname }   // '';
    my $name  = $first ? "$first $sur" : $sur;
    return $c->render(
        status => 200,
        json   => {
            id       => "" . $user->borrowernumber,
            name     => $name,
            email    => $user->email // '',
            is_admin => ( $flags && ( $flags == 1 || ( $flags & 1 ) ) ) ? \1 : \0,
        }
    );
}

1;
