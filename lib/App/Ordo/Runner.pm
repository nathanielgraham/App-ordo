package App::Ordo::Runner;
use Moo;
use feature qw(say);
use utf8;
use open ':std', ':utf8';
use Term::ANSIColor qw(colored);
use Email::Valid;
use JSON qw(encode_json);
use Term::ReadLine::Perl5;
use DateTime::TimeZone;
use App::Ordo qw($CURRENT_PATH extract_command);
use App::Ordo::API;
use App::Ordo::Command::Help;
use App::Ordo::Command::Ls;
use App::Ordo::Command::Cd;
use App::Ordo::Command::User::Show;
use App::Ordo::Command::Job::Create;
use App::Ordo::Command::Job::Update;
use App::Ordo::Command::Job::Hold;
use App::Ordo::Command::Job::Release;
use App::Ordo::Command::Job::Ice;
use App::Ordo::Command::Job::Melt;
use App::Ordo::Command::Job::Run;
use App::Ordo::Command::Job::Log;
use App::Ordo::Command::Job::Logs;
use App::Ordo::Command::Job::Delete;
use App::Ordo::Command::Job::Show;
use App::Ordo::Command::Cluster::Create;
use App::Ordo::Command::Cluster::Update;
use App::Ordo::Command::Cluster::Hold;
use App::Ordo::Command::Cluster::Release;
use App::Ordo::Command::Cluster::Ice;
use App::Ordo::Command::Cluster::Melt;
use App::Ordo::Command::Cluster::Run;
use App::Ordo::Command::Cluster::Delete;
use App::Ordo::Command::Cluster::Show;
use App::Ordo::Command::Cal::List;
use App::Ordo::Command::Cal::Create;
use App::Ordo::Command::Cal::Delete;
use App::Ordo::Command::Cal::Show;
use App::Ordo::Command::Cal::Attach;
use App::Ordo::Command::Cal::Detach;
use App::Ordo::Command::Cal::Cron::Add;
use App::Ordo::Command::Cal::Cron::Delete;
use App::Ordo::Command::Server::List;
use App::Ordo::Command::Server::Add;
use App::Ordo::Command::Server::Delete;
use App::Ordo::Command::Sync;

# Full command tree
my %COMMANDS = (
    ls       => 'App::Ordo::Command::Ls',
    cd       => 'App::Ordo::Command::Cd',

    help => 'App::Ordo::Command::Help',
    sync => 'App::Ordo::Command::Sync',

    user => {
        show   => 'App::Ordo::Command::User::Show',
    },

    job => {
        create  => 'App::Ordo::Command::Job::Create',
        update  => 'App::Ordo::Command::Job::Update',
        hold    => 'App::Ordo::Command::Job::Hold',
        release => 'App::Ordo::Command::Job::Release',
        ice     => 'App::Ordo::Command::Job::Ice',
        melt    => 'App::Ordo::Command::Job::Melt',
        run     => 'App::Ordo::Command::Job::Run',
        show    => 'App::Ordo::Command::Job::Show',
        log     => 'App::Ordo::Command::Job::Log',
        logs    => 'App::Ordo::Command::Job::Logs',
        delete  => 'App::Ordo::Command::Job::Delete',
    },

    cluster => {
        create => 'App::Ordo::Command::Cluster::Create',
        update => 'App::Ordo::Command::Cluster::Update',
        hold => 'App::Ordo::Command::Cluster::Hold',
        release => 'App::Ordo::Command::Cluster::Release',
        ice => 'App::Ordo::Command::Cluster::Ice',
        melt => 'App::Ordo::Command::Cluster::Melt',
        run    => 'App::Ordo::Command::Cluster::Run',
        delete => 'App::Ordo::Command::Cluster::Delete',
        show   => 'App::Ordo::Command::Cluster::Show',
    },

    cal => {
        list   => 'App::Ordo::Command::Cal::List',
        create => 'App::Ordo::Command::Cal::Create',
        delete => 'App::Ordo::Command::Cal::Delete',
        show   => 'App::Ordo::Command::Cal::Show',
        attach => 'App::Ordo::Command::Cal::Attach',
        detach => 'App::Ordo::Command::Cal::Detach',
        cron   => {
            add    => 'App::Ordo::Command::Cal::Cron::Add',
            delete => 'App::Ordo::Command::Cal::Cron::Delete',
        },
    },

    server => {
        list   => 'App::Ordo::Command::Server::List',
        add    => 'App::Ordo::Command::Server::Add',
        delete => 'App::Ordo::Command::Server::Delete',
    },
);

has 'api' => (is => 'lazy');
sub _build_api { App::Ordo::API->new }

sub run {
    my ($self, @args) = @_;

    my $first = $args[0];

    # Special case: ALL help commands get the full command tree
    if ($first eq 'help') {
        App::Ordo::Command::Help->new(
            api      => $self->api,
            commands => \%COMMANDS,
        )->run(@args);
        return;
    }

    # Normal tree dispatch
    my $node = \%COMMANDS;
    my @path;

    while (@args && ref($node) eq 'HASH' && exists $node->{$args[0]}) {
        push @path, shift @args;
        $node = $node->{$path[-1]};
    }

    my $cmd_name = join ' ', @path;
    my $cmd_class = ref($node) eq '' ? $node : undef;

    unless ($cmd_class) {
        say colored(["bold red"], "Unknown command: @args");
        say "Try 'help' for available commands";
        return;
    }

    eval {
        $cmd_class->new(api => $self->api)->run(@args);
    };
    if ($@) {
        chomp $@;
        say colored(["bold red"], "Error: $@");
    }
}

sub run_interactive {
    my $self = shift;

    my $term = Term::ReadLine::Perl5->new('ordo');

    print "\n";
    say colored(["bold white"], "Welcome to Ordo - the hierarchical job scheduler");
    $self->ensure_session;
    say "\nType 'help' for commands, Ctrl-D to exit.\n";

    while (defined(my $line = $term->readline("ordo:$CURRENT_PATH> "))) {
        $line =~ s/^\s+|\s+$//g;
        next unless $line;
        $self->run(App::Ordo::extract_command($line));
    }

    say colored(["bold yellow"], "\nGoodbye!");
}

sub prompt_for_email {
    my $email;
    while (1) {
        print colored(["bold white"], "Email address: ");
        chomp($email = <STDIN>);
        $email =~ s/^\s+|\s+$//g;
        last if $email && Email::Valid->address($email);
        say colored(["bold red"], "Invalid email - please try again");
    }
    return $email;
}

sub ensure_session {
    my ($self) = @_;

    my $config = $self->api->config;
    my $token  = $config->{token} // '';

    my $res = $self->api->call('login_user', { token => $token });

    if ($res->{success}) {
       if ( $res->{level} == 0 ) {
          say "Already registered. Please check your email to confirm";
          exit; 
       }

       $App::Ordo::CURRENT_PATH = $res->{path} // '/';
       say colored(["bold green"], "Logged in as $res->{email} to $res->{host} \@$res->{path}");
       return;
    }

    say colored(["bold yellow"], "No valid session - registering new user");
    my $email = $self->prompt_for_email;

    $res = $self->api->call('register_user', { email => $email });
    die "Registration failed: " . ($res->{message} || 'server error') . "\n"
        unless $res->{success};

    $config->{token} = $res->{token};
    open my $fh, '>', $self->api->config_file
        or die "Cannot save config: $!";
    print $fh encode_json($config);
    close $fh;

    say $res->{message};
    exit;
}

1;
