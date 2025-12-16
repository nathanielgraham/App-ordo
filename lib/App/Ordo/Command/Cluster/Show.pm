package App::Ordo::Command::Cluster::Show;
use Moo;
use feature qw(say);
extends 'App::Ordo::Command::Base';

use App::Ordo qw($CURRENT_PATH);
use Term::ANSIColor qw(colored);
use Text::Table::Tiny 1.02 qw(generate_table);

sub name    { "cluster show" }
sub summary { "Show detailed information about a cluster (current if no path)" }
sub usage   { "[path]" }

sub option_spec { {} }

sub execute {
    my ($self, $opt, $path) = @_;

    # No path → use current context
    $path = $CURRENT_PATH unless $path;
    $path = "/$path" if $path !~ m|^/|;

    my $res = $self->api->call('read_cluster', { name => $path });

    unless ($res->{success}) {
        say colored(["bold red"], "Cluster not found: $path");
        say $res->{message} if $res->{message};
        return;
    }

    my $c = $res;

    say colored(["bold cyan"], "Cluster: ") . colored(["bold white"], $c->{name});
    say colored(["cyan"], "Path: ") . $path;
    say colored(["cyan"], "State: ") . colored(["bold " . ($c->{jobstate} eq 'running' ? 'green' : 'yellow')], $c->{jobstate});
    say colored(["cyan"], "Description: ") . ($c->{description} || colored(["bright_black"], "(none)"));
    say colored(["cyan"], "Calendar: ") . ($c->{cal_id} ? "ID $c->{cal_id}" : colored(["bright_black"], "none"));
    say colored(["cyan"], "Created: ") . ($c->{creation_time}
        ? strftime("%a %b %d %H:%M:%S %Y", localtime($c->{creation_time}))
        : "unknown");

    if ($c->{jobs} && @{$c->{jobs}}) {
        say "\n" . colored(["bold green"], "Jobs in this cluster:");
        my $rows = [ [qw(ID NAME SERVER STATE SCRIPT)] ];
        for my $j (@{$c->{jobs}}) {
            my $state_color = $j->{jobstate} eq 'complete' ? 'green' :
                              $j->{jobstate} eq 'running'  ? 'magenta' :
                              $j->{jobstate} eq 'failed'   ? 'red' : 'yellow';
            push @$rows, [
                $j->{id},
                $j->{name},
                $j->{server_name} || '-',
                colored(["bold $state_color"], $j->{jobstate}),
                $j->{script} || '(no script)',
            ];
        }
        say generate_table(rows => $rows, header_row => 1);
    } else {
        say colored(["yellow"], "\nNo jobs in this cluster");
    }
    say "";
}

1;
