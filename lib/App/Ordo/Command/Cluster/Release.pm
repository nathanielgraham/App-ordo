package App::Ordo::Command::Cluster::Release;
use Moo;
extends 'App::Ordo::Command::Base';

sub name    { "cluster release" }
sub summary { "Release a held cluster" }
sub usage   { "<path/name>" }

sub option_spec { {} }

sub execute {
    my ($self, $opt, $name) = @_;
    unless ($name) {
        say colored(["bold red"], "Usage: release hold <path/name>");
        return;
    }

    my $res = $self->api->call('release_cluster', { name => $name });

    $res->{success}
        ? say colored(["bold yellow"], "Cluster '$name' held")
        : say colored(["bold red"], "Failed: " . ($res->{message} || 'error'));
}

1;
