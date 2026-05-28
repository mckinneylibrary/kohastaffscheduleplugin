package Koha::Plugin::Com::LibSched::StaffScheduler::API::V1::Ping;

use Modern::Perl;
use Mojo::Base 'Mojolicious::Controller';

sub get {
    my $c = shift;
    return $c->render(
        status => 200,
        json   => {
            ok      => \1,
            plugin  => 'Koha::Plugin::Com::LibSched::StaffScheduler',
            version => $Koha::Plugin::Com::LibSched::StaffScheduler::VERSION,
            time    => time(),
        }
    );
}

1;
