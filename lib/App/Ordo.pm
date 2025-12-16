# lib/App/Ordo.pm
package App::Ordo;

use Moo;
use feature qw(say);
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
    $CURRENT_PATH
    extract_command
    epoch_to_tminus
    epoch_to_duration
);

our $VERSION = '1.0';

our $CURRENT_PATH = '/';

use JSON qw(encode_json decode_json);
use File::Path qw(make_path);
use File::Copy qw(copy);
use File::ShareDir qw(dist_file);
use Term::ANSIColor qw(colored);
use Term::ReadLine;
use Term::ReadKey qw(ReadMode ReadKey GetTerminalSize);

use App::Ordo::API;
use App::Ordo::Runner;

has 'api' => (
    is      => 'lazy',
    default => sub { App::Ordo::API->new },
);

has 'runner' => (
    is      => 'lazy',
    default => sub { App::Ordo::Runner->new(api => shift->api) },
);

# ------------------------------------------------------------------
# Interactive shell
# ------------------------------------------------------------------
sub run_interactive {
    my $self = shift;

    $self->ensure_session;

    my $term = Term::ReadLine->new('ordo');

    say colored(["bold white"], "Welcome to Ordo");
    say "Type 'help' for commands, empty line to refresh, Ctrl-D to exit.\n";

    while (defined(my $line = $term->readline("ordo:$CURRENT_PATH> ") // '')) {
        $line =~ s/^\s+|\s+$//g;
        next unless $line;
        $line = 'ls' if $line eq '';

        my @args = extract_command($line);
        $self->runner->run(@args);
    }

    say colored(["bold yellow"], "\nGoodbye!");
}

# ------------------------------------------------------------------
# Session handling
# ------------------------------------------------------------------
sub ensure_session {
    my ($self) = @_;

    my $config = $self->api->config;
    my $token  = $config->{token} // '';

    my $res = $self->api->call('login_user', { token => $token });

    if ($res->{success}) {
        $CURRENT_PATH = $res->{path} // '/';
        say colored(["bold green"], "Logged in — path: $CURRENT_PATH");
        return;
    }

    say colored(["bold yellow"], "No valid session — registering new user");
    my $email = $self->_prompt_for_email;

    $res = $self->api->call('register_user', { email => $email });

    die "Registration failed: " . ($res->{message} || 'server error') . "\n"
        unless $res->{success};

    $config->{token} = $res->{token};
    open my $fh, '>', $self->api->config_file
        or die "Cannot save config: $!";
    print $fh encode_json($config);
    close $fh;

    $CURRENT_PATH = $res->{path} // '/';
    say colored(["bold green"], "Registered and logged in!");
}

sub _prompt_for_email {
    my $email;
    while (1) {
        print colored(["bold white"], "Email address: ");
        chomp($email = <STDIN>);
        $email =~ s/^\s+|\s+$//g;
        last if $email && Email::Valid->address($email);
        say colored(["bold red"], "Invalid email — please try again");
    }
    return $email;
}

# ------------------------------------------------------------------
# Command line parsing
# ------------------------------------------------------------------
sub extract_command {
    my ($line) = @_;
    return () unless defined $line;

    my @args;
    my $current = '';
    my $in_quote = '';

    for my $char (split //, $line) {
        if ($in_quote) {
            $current .= $char;
            $in_quote = '' if $char eq $in_quote;
        } elsif ($char eq '"' || $char eq "'") {
            $in_quote = $char;
            $current .= $char;
        } elsif ($char =~ /\s/) {
            push @args, $current if length $current;
            $current = '';
        } else {
            $current .= $char;
        }
    }
    push @args, $current if length $current;

    # Strip surrounding quotes
    @args = map { /^['"](.*)['"]$/ ? $1 : $_ } @args;

    return @args;
}

# ------------------------------------------------------------------
# Time formatting helpers
# ------------------------------------------------------------------
sub epoch_to_tminus {
   my $epoch = shift;

   return '' unless $epoch && $epoch =~ /^\d+$/;

   my $current_epoch = time;
   my $sign          = $epoch > $current_epoch ? '-' : '+';

   my $duration = &epoch_to_duration( $current_epoch, $epoch );

   return "T$sign$duration";
}

sub epoch_to_duration {
   my ( $start, $end ) = @_;
   return '' unless $start;
   $end //= time;
   my $diff_seconds = abs( $end - $start );

   # Convert to days, hours, minutes, seconds
   my $days = int( $diff_seconds / ( 24 * 60 * 60 ) );
   $diff_seconds %= ( 24 * 60 * 60 );
   my $hours = int( $diff_seconds / ( 60 * 60 ) );
   $diff_seconds %= ( 60 * 60 );
   my $minutes  = int( $diff_seconds / 60 );
   my $seconds  = $diff_seconds % 60;
   my $duration = sprintf( "%02d:%02d:%02d", $hours, $minutes, $seconds );

   if ($days) {
      $duration .= " +$days" . 'd';
   }
   return $duration;
}

# ------------------------------------------------------------------
# Pager
# ------------------------------------------------------------------
sub less {
    my ($string) = @_;
    my @lines = split /\n/, $string;

    # Ensure each line ends with \n
    $_ .= "\n" for @lines;
    push @lines, "\n";

    my ($width, $height) = GetTerminalSize();
    $height -= 1;  # leave room for status line

    my $total_lines = @lines;

    # If fits on screen, just print
    if ($total_lines <= $height) {
        print for @lines;
        return;
    }

    my $current = 0;
    ReadMode 'cbreak';

    while (1) {
        system("clear");  # simple clear — works everywhere

        # Print visible lines
        for my $i ($current .. $current + $height - 1) {
            last if $i >= $total_lines;
            print $lines[$i];
        }

        # Status line
        my $percent = int(($current + $height) / $total_lines * 100);
        my $bottom = $current + $height;
        printf "\033[7m(line %d of %d, %d%%) [q quit, space/b/j/k]\033[0m\n",
            $bottom > $total_lines ? $total_lines : $bottom,
            $total_lines, $percent;

        my $key = ReadKey(0);

        last if $key eq 'q' || $key eq 'Q';

        $current += $height if $key eq ' ';     # page down
        $current -= $height if $key eq 'b';     # page up
        $current++ if $key eq 'j' || $key eq "\n" || $key eq "\r";  # line down
        $current-- if $key eq 'k';             # line up

        $current = 0 if $current < 0;
        $current = $total_lines - $height if $current > $total_lines - $height;
    }

    ReadMode 'normal';
    print "\n";
}
1;
