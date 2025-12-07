package App::ordo;
use strict;
use warnings;
use feature qw(say);
use Exporter 'import';
our @EXPORT_OK = qw(one_shot_mode run_interactive_shell);

our $VERSION = '1.0';

use JSON qw(encode_json decode_json);
use File::Spec;
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::ShareDir qw(dist_file);
use Mojo::UserAgent;
use Term::ReadLine;
use Term::ANSIColor qw(colored);
use Text::Table::Tiny 1.02 qw(generate_table);
use Term::ReadKey;
use Term::Size 'chars';
use Email::Valid;
use POSIX qw(strftime);
use Date::Parse;
use DateTime::TimeZone;
use Getopt::Long qw(GetOptionsFromString);
use List::Util qw(min);

# ------------------------------------------------------------------
# Module-level cached variables
# ------------------------------------------------------------------
my $CONFIG_DIR  = File::Spec->catdir($ENV{HOME}, '.config', 'App-ordo');
my $CONFIG_FILE = File::Spec->catfile($CONFIG_DIR, 'ordo_config.json');
my $PATH_FILE   = File::Spec->catfile($CONFIG_DIR, 'current_path');

my $cached_config;   # ← config cache
my $cached_tz;       # ← timezone cache

# ------------------------------------------------------------------
# Config loading — simple, works everywhere
# ------------------------------------------------------------------
sub load_config {
    return $cached_config if $cached_config;

    unless (-d $CONFIG_DIR) {
        make_path($CONFIG_DIR);
        my $default = dist_file('App-ordo', 'ordo_config.json');
        copy($default, $CONFIG_FILE) or die "Cannot copy default config: $!";
        chmod 0600, $CONFIG_FILE;
    }

    open my $fh, '<', $CONFIG_FILE or die "Cannot read $CONFIG_FILE: $!";
    my $json = do { local $/; <$fh> };
    close $fh;

    $cached_config = eval { decode_json($json) } // {};
    die "Invalid JSON in $CONFIG_FILE: $@\n" if $@;

    return $cached_config;
}

# ------------------------------------------------------------------
# Timezone — cached once
# ------------------------------------------------------------------
sub tz {
    return $cached_tz if $cached_tz;
    $cached_tz = DateTime::TimeZone->new(name => 'local')->name;
    return $cached_tz;
}

# ------------------------------------------------------------------
# Path persistence
# ------------------------------------------------------------------
sub load_current_path {
    return '/' unless -e $PATH_FILE;
    open my $fh, '<', $PATH_FILE or return '/';
    chomp(my $path = <$fh>);
    close $fh;
    $path =~ s{^/+}{/};
    $path =~ s{/+$}{};
    return $path || '/';
}

sub save_current_path {
    my $path = shift // '/';
    $path =~ s{^/+}{/};
    $path =~ s{/+$}{};
    $path = '/' if $path eq '';
    open my $fh, '>', $PATH_FILE or die "Cannot save path: $!";
    print $fh "$path\n";
    close $fh;
}

# ------------------------------------------------------------------
# Terminal size
# ------------------------------------------------------------------
sub get_term_size {
    my ($c, $r) = chars();
    return ($c // 80, $r // 24);
}

# ------------------------------------------------------------------
# First-time registration
# ------------------------------------------------------------------
sub register_new_user {
    my ($ua, $api) = @_;
    say colored(["bold yellow"], "\nWelcome to Ordo — first-time setup\n");
    say "We need to register you with the server.\n";

    my $email;
    while (1) {
        print "Enter your email address: ";
        chomp($email = <STDIN>);
        last if Email::Valid->address(-address => $email, -mxcheck => 1);
        say colored(["red"], "Invalid email — please try again.");
    }

    say "Registering...";
    my $res = $ua->post("$api" => json => { command => 'register_user', email => $email })->result;

    if ($res->is_success && ($res->json->{success} // 0)) {
        say colored(["bold green"], "\nSuccess! " . ($res->json->{message} || 'Registered'));
        return $res->json->{token};
    }
    say colored(["bold red"], "\nRegistration failed: " . ($res->message || 'server error'));
    exit 1;
}

# ------------------------------------------------------------------
# Date helpers
# ------------------------------------------------------------------
sub date_to_epoch {
    my $date = shift // return undef;
    return $date if $date =~ /^\d+$/;
    my $t = Date::Parse::str2time($date);
    return $t if $t;
    chomp($t = qx/date -d "$date" +%s/ // '');
    return $t || undef;
}

sub epoch_to_tminus {
    my $epoch = shift // return '';
    return unless $epoch && $epoch =~ /^\d+$/;
    my $diff = abs($epoch - time);
    my $sign = $epoch > time ? '-' : '+';
    my $d = int($diff / 86400); $diff %= 86400;
    my $h = int($diff / 3600);  $diff %= 3600;
    my $m = int($diff / 60);
    my $s = $diff % 60;
    my $out = sprintf("T%s%02d:%02d:%02d", $sign, $h, $m, $s);
    $out .= " +${d}d" if $d;
    return $out;
}

sub format_time {
    my $opt = shift // return ('', '', '');
    my $s = $opt->{started} // return ('', '', '');
    my $e = $opt->{ended};

    my $started = $s ? strftime("%b %d %H:%M:%S", localtime($s)) : '';
    my $ended   = $e ? strftime("%b %d %H:%M:%S", localtime($e)) : '';
    my $end_sec = $e || time;

    my $dur = $end_sec - $s;
    my $h   = int($dur / 3600);
    my $m   = int(($dur % 3600) / 60);
    my $sec = $dur % 60;

    my $duration = sprintf("%02d:%02d:%02d", $h, $m, $sec);

    return ($started, $ended, $duration);
}

# ------------------------------------------------------------------
# Duration helper — you were missing this!
# ------------------------------------------------------------------
sub epoch_to_duration {
    my ($start, $end) = @_;
    return '' unless $start && $end && $start =~ /^\d+$/ && $end =~ /^\d+$/;

    my $diff = abs($end - $start);
    my $days = int($diff / 86400);
    $diff %= 86400;
    my $h = int($diff / 3600);
    my $m = int($diff / 60) % 60;
    my $s = $diff % 60;

    my $out = sprintf("%02d:%02d:%02d", $h, $m, $s);
    $out .= " +${days}d" if $days;
    return $out;
}

# ------------------------------------------------------------------
# extract_command & less (your originals)
# ------------------------------------------------------------------
sub extract_command {
    my $string = shift // return ();
    my @parts;
    my $current = '';
    my $in_quotes = '';
    for my $i (0 .. length($string)-1) {
        my $char = substr($string, $i, 1);
        if ($in_quotes) {
            $current .= $char;
            $in_quotes = '' if $char eq $in_quotes && substr($string, $i-1, 1) ne '\\';
        } elsif ($char eq '"' || $char eq "'") {
            $in_quotes = $char;
            $current .= $char;
        } elsif ($char =~ /\s/) {
            push @parts, $current if length $current;
            $current = '';
        } else {
            $current .= $char;
        }
    }
    push @parts, $current if length $current;
    @parts = map { s/^['"]|['"]$//gr } @parts;
    return @parts;
}

sub less {
    my $text = shift // return;
    my @lines = split /\n/, $text;
    $_ .= "\n" for @lines;
    push @lines, "\n";

    my ($w, $h) = get_term_size();
    $h -= 1;
    my $total = @lines;
    my $pos = 0;

    return print @lines if $total <= $h;

    ReadMode('cbreak');
    while (1) {
        print "\033[1;1H";
        print join '', @lines[$pos .. min($pos+$h-1, $total-1)];
        my $pct = int(($pos + $h) / $total * 100);
        print "\033[$h;1H\033[K\033[7m(line ", $pos+$h, " of $total, $pct%) [q=quit, space=next]\033[0m";

        my $k = ReadKey(0);
        last if $k eq 'q';
        $pos += $h if $k eq ' ';
        $pos = 0 if $pos < 0;
        $pos = $total - $h if $pos > $total - $h;
    }
    ReadMode('normal');
    print "\033[1;1H";
}

# ------------------------------------------------------------------
# string2hash 
# ------------------------------------------------------------------
sub string2hash {
    my $string = shift // '';
    my %options;

    my ($cmds) = $string =~ /(.*?)(?:\s+-.*)?$/;
    my ($opts) = $string =~ /(\s+-.*)$/;

    my @cmd_parts = extract_command($cmds);
    my ($verb, $noun, $name) = @cmd_parts;

    if ($opts) {
        GetOptionsFromString(
            $opts, \%options,
            "command=s", "token=s", "state:s", "user:s", "host:s", "newname:s", "password:s", "script:s",
            "email:s", "level:i", "cron:s", "at:s", "cal:s", "cal_id:i", "force", "count:i", "needs:i@",
            "description:s", "server_id:i", "name:s", "job_id:i", "cluster_id:i", "server:s", "org_id:i",
            "pid:i", "id:s", "match:s", "tz:s", "begin:s", "expire:s", "parent_id:i", "retrys:i",
            "delay:i", "loops:i", "fail_alarm:i", "mode:i", "clonable:i", "log:i", "json:s", "needs_any:i"
        );

        if ($opts =~ /--needs/) {
            my @needs;
            GetOptionsFromString($opts, 'needs=i{,}' => \@needs);
            $options{needs} = \@needs if @needs;
        }
    }

    my $config = load_config();
    my $aliases = $config->{aliases} // {};

    my $cmd = $aliases->{$verb} // ($noun ? join('_', $verb, $noun) : $verb);
    return { success => 0, message => 'command not found' } unless $cmd;

    for my $o (qw(at begin expire)) {
        if ($options{$o}) {
            my $seconds = date_to_epoch($options{$o});
            $options{$o} = $seconds if defined $seconds;
        }
    }

    $options{tz} //= tz();  # ← now calls the function

    my $res = { token => $config->{token} // '', command => $cmd, %options };
    $res->{name} = $name if defined $name && length $name;

    return $res;
}

# ------------------------------------------------------------------
# Display functions
# ------------------------------------------------------------------
sub print_table {
    my $json = shift // return;
    return unless ref $json eq 'HASH' && $json->{success};
    my $rows = [ [qw(key value)] ];
    for my $k (sort keys %$json) {
        next if $k eq 'success';
        my $row = ref $json->{$k} eq 'ARRAY' ? join(' ', map { $_->{id} } @{$json->{$k}}) 
               : ref $json->{$k} eq 'HASH' ? join(' ', keys %{$json->{$k}}) 
               : $json->{$k};
        push @$rows, [ $k, $row ];
    }
    less(generate_table(rows => $rows, header_row => 1));
}

sub find_monitor {
    my $json = shift // return;
    return unless $json->{servers};
    my $rows = [ [qw(ID ALIAS %MEMORY %DISK LOADAVG PING UPTIME OS UPDATED USER@HOST)] ];
    for my $s (@{$json->{servers}}) {
        my $pmem = $s->{total_memory} ? sprintf("%.2f", ($s->{used_memory} / $s->{total_memory}) * 100) : '';
        my $pdisk = $s->{total_disk} ? sprintf("%.2f", ($s->{used_disk} / $s->{total_disk}) * 100) : '';
        my $uptime = $s->{uptime} ? sprintf("%.2f days", $s->{uptime} / 86400) : '';
        my $ping = $s->{ping} ? sprintf("%.2f ms", $s->{ping}) : '';
        my $update = $s->{update_time} ? sprintf("%is ago", time - $s->{update_time}) : '';
        my $cpu = $s->{cpu} ? sprintf("%.2f (%i)", $s->{cpu}, $s->{cores} || 1) : '';
        push @$rows, [ $s->{id}, $s->{name}, $pmem, $pdisk, $cpu, $ping, $uptime, $s->{os}, $update, $s->{user} . '@' . $s->{host} ];
    }
    say generate_table(rows => $rows, header_row => 1);
}

sub find_log {
    my $json = shift // return;
    return unless $json && $json->{success} && $json->{logs};
    print "\nJob history for $json->{path}/$json->{name}\n";
    my $rows = [ [qw(ID JOB_ID PID STARTED ENDED EXIT_CODE SIGNAL)] ];
    for my $l (@{$json->{logs}}) {
        my $started = $l->{started} ? strftime("%b %d %H:%M:%S", localtime($l->{started})) : '';
        my $ended = $l->{ended} ? strftime("%b %d %H:%M:%S", localtime($l->{ended})) : '';
        push @$rows, [ $l->{id}, $l->{job_id}, $l->{pid}, $started, $ended, $l->{exit_code}, $l->{signal} ];
    }
    say generate_table(rows => $rows, header_row => 1);
}

sub read_log {
    my $json = shift // return;
    return unless $json && $json->{out};
    less($json->{out});
}

sub find_cal {
    my $json = shift // return;
    return unless $json->{cals} && @{$json->{cals}};
    print "Local time is " . localtime(time) . " " . tz() . "\n";
    for my $cal (@{$json->{cals}}) {
        my $crows = [ [qw(ID CALENDAR NEXT_START TIME_ZONE CLUSTER_IDS DESCRIPTION)] ];
        my $cnext = $cal->{next_start} ? strftime("%b %d %H:%M:%S", localtime($cal->{next_start})) : '';
        my $cluster_ids = join(',', @{$cal->{cluster_ids} // []});
        push @$crows, [ $cal->{id}, $cal->{name}, $cnext, $cal->{tz}, $cluster_ids, $cal->{description} ];
        say generate_table(rows => $crows, header_row => 1, style => 'classic');
        next unless $cal->{crons} && @{$cal->{crons}};
        my $rows = [ [qw(ID QUARTZ_CRONTAB NEXT_START BEGIN EXPIRE DESCRIPTION)] ];
        for my $cron (@{$cal->{crons}}) {
            my $description = $cron->{description} || $cron->{english};
            my $start = $cron->{begin} ? strftime("%b %d %H:%M:%S %Y", localtime($cron->{begin})) : '';
            my $end = $cron->{expire} ? strftime("%b %d %H:%M:%S %Y", localtime($cron->{expire})) : 'never';
            my $next = $cron->{next_start} ? strftime("%b %d %H:%M:%S %Y", localtime($cron->{next_start})) : '';
            push @$rows, [ $cron->{id}, $cron->{name}, $next, $start, $end, $description ];
        }
        say generate_table(rows => $rows, header_row => 1, style => 'classic');
    }
}

sub find_cluster {
    my $json = shift // return;
    return unless $json->{clusters} && @{$json->{clusters}};
    print "Local time is " . localtime(time) . " " . tz() . "\n";
    my %cluster = map { $_->{id} => $_ } @{$json->{clusters}};
    my @paths;
    for my $c (@{$json->{clusters}}) {
        my @parts;
        my $next = $c->{id};
        while ($next) {
            unshift @parts, $next;
            $next = $cluster{$next}->{parent_id};
            $next = undef unless $next && exists $cluster{$next};
        }
        push @paths, \@parts;
    }
    my $path_padding = ' ';
    my $rows = [ [qw(ID CLUSTER/JOB STATE SERVER NEEDS %MEM %CPU PID LAST_START DURATION NEXT_START CALENDAR)] ];
    for my $i (0 .. $#paths) {
        my @parts = @{$paths[$i]};
        my $cluster_id = $parts[-1];
        my @show_parts = @parts;
        shift @show_parts unless $i == 0;
        my $path = join('/', map { $cluster{$_}->{name} } @show_parts);
        $path .= '/' if $i == 0;
        $path = $path_padding . $path unless $i == 0;
        my $blue_path = colored($path, 'bold blue');
        my $c = $cluster{$cluster_id};
        my $credo = $c->{retry_count} || $c->{loop_count};
        my $cstate = $c->{jobstate} // '';
        $cstate = colored($cstate, 'bold green') if $cstate =~ /^(complete|ice|pruned)$/;
        $cstate = colored($cstate, 'bold red') if $cstate =~ /^(failed|zombie|killed|hold)$/;
        $cstate = colored($cstate, 'bold magenta') if $cstate eq 'running';
        $cstate = colored($cstate, 'bold cyan') if $cstate eq 'immutable';
        $cstate = colored($cstate, 'bold yellow') if $cstate =~ /^(ready|waiting|looping|retrying)$/;
        $cstate .= "($credo)" if $credo;
        my ($started, $ended, $duration) = format_time($c);
        my $needs = join(' ', keys %{$c->{needs} // {}});
        my $ctminus = epoch_to_tminus($c->{next_start});
        my $ctplus = epoch_to_tminus($c->{started});
        my $cdur = epoch_to_duration($c->{started}, $c->{ended} || time);
        push @$rows, [ $c->{id}, $blue_path, $cstate, '', $needs, '', '', '', $ctplus, $cdur, $ctminus, $c->{cal_id} ];
        next unless $c->{jobs} && @{$c->{jobs}};
        for my $j (@{$c->{jobs}}) {
            my $pathname = $i == 0 ? $path_padding . $j->{name} : "$path/$j->{name}";
            my $jtminus = epoch_to_tminus($j->{next_start});
            my $jtplus = epoch_to_tminus($j->{started});
            my $jdur = epoch_to_duration($j->{started}, $j->{ended} || time);
            my ($started, $ended, $duration) = format_time($j);
            my $redo = $j->{retry_count} || $j->{loop_count};
            my $jstate = $j->{jobstate} // '';
            $jstate = colored($jstate, 'bold green') if $jstate =~ /^(complete|ice|pruned)$/;
            $jstate = colored($jstate, 'bold red') if $jstate =~ /^(failed|zombie|killed|hold)$/;
            $jstate = colored($jstate, 'bold magenta') if $jstate eq 'running';
            $jstate = colored($jstate, 'bold yellow') if $jstate =~ /^(ready|waiting|looping|retrying)$/;
            $jstate .= "($redo)" if $redo;
            push @$rows, [ $j->{id}, $pathname, $jstate, $j->{server_name}, join(' ', keys %{$j->{needs} // {}}), $j->{pctmem}, $j->{pctcpu}, $j->{pid}, $jtplus, $duration, '', '' ];
        }
    }
    say generate_table(rows => $rows, header_row => 1, style => 'classic');
}

# ------------------------------------------------------------------
# Request & dispatch
# ------------------------------------------------------------------
sub send_request {
    my $req = shift // return { success => 0, message => 'No request' };
    my $config = load_config();
    my $ua = Mojo::UserAgent->new(ssl_opts => { insecure => 1 });
    $ua->inactivity_timeout(10)->max_redirects(0)->connect_timeout(4)->request_timeout(5);
    my $res = $ua->post($config->{api} => { Accept => 'application/json' } => json => $req)->result->json // { success => 0 };
    return $res;
}

sub after_dispatch {
    my ($command, $json) = @_;
    return unless $command && $json;
    my %dispatch = (
        change_cluster => sub { save_current_path($json->{path}) if $json->{success} },
        login_user => sub { },
        register_user => sub { },
        find_cluster => \&find_cluster,
        read_job => \&print_table,
        read_cluster => \&print_table,
        read_path => \&print_table,
        find_cal => \&find_cal,
        read_cal => \&find_cal,
        find_log => \&find_log,
        read_log => \&read_log,
        find_monitor => \&find_monitor,
        read_monitor => \&print_table,
        create_monitor => \&print_table,
        new_token => sub { load_config(); },  # Reload config after token change
        read_user => \&print_table,
        help_commands => sub { say "Help: Use 'ls' for cluster view, 'job run <name>', etc." },
    );
    if (my $sub = $dispatch{$command}) {
        $sub->($json);
    } else {
        print_table($json);
    }
}

# ------------------------------------------------------------------
# One-shot mode
# ------------------------------------------------------------------
sub one_shot_mode {
    my @args = @_;
    my $config = load_config();
    my $current_path = load_current_path();

    if (@args && ($args[0] eq '--path' || $args[0] eq '-p')) {
        shift @args;
        $current_path = shift @args // '/';
    }

    @args = ('find cluster') unless @args;  # Default to ls-like

    my $line = join(' ', @args);
    my $req = string2hash($line) or exit 1;

    if ($current_path ne '/' && ($req->{name} // '') !~ m|^/|) {
        $req->{name} = File::Spec->catdir($current_path, $req->{name} // '');
    }

    my $res = send_request($req);
    after_dispatch($res->{command_reply}, $res);

    if ($req->{command} eq 'change_cluster' && $res->{success}) {
        save_current_path($res->{path} || $req->{name} || $current_path);
    }

    exit($res->{success} ? 0 : 1);
}

# ------------------------------------------------------------------
# Interactive shell
# ------------------------------------------------------------------
sub run_interactive_shell {
    my $config = load_config();
    my $api = $config->{api} or die "No API URL in config\n";

    my $ua = Mojo::UserAgent->new(ssl_opts => { insecure => 1 });
    $ua->inactivity_timeout(10)->max_redirects(0)->connect_timeout(4)->request_timeout(5);

    my $token = $config->{token} // '';
    my $login = send_request({ command => 'login_user', token => $token });

    my $host = $login->{host} // 'localhost';
    my $cluster = load_current_path();

    unless ($login->{success}) {
        $token = register_new_user($ua, $api);
        $config = load_config();            # ← RELOAD config from disk
        $config->{token} = $token;
        open my $fh, '>', $CONFIG_FILE or die "Cannot save config: $!";
        print $fh encode_json($config);
        close $fh;
        $login = send_request({ command => 'login_user', token => $token });
        $host = $login->{host} // $host;
    } else {
        say colored(['bold green'], "Welcome back!");
    }

    say "Local time is " . localtime(time) . " " . tz() . "\n";
    say "Type 'help' for commands.\n";

    my $term = Term::ReadLine->new('ordo');
    while (defined(my $line = $term->readline("$host:$cluster> ") // '')) {
        $line =~ s/^\s+|\s+$//g;
        next unless $line;
        $line = 'find cluster' if $line eq '';

        my $req = string2hash($line) or next;
        $req->{token} = $token;

        if ($cluster ne '/' && ($req->{name} // '') !~ m|^/|) {
            $req->{name} = File::Spec->catdir($cluster, $req->{name} // '');
            $req->{name} =~ s|^/+|/|;
        }

        my $res = send_request($req);

        after_dispatch($res->{command_reply}, $res);

        say colored(['green'], "Command successful.") if $res->{success};
        say colored(['red'], "Command failed: $res->{message}") if !$res->{success} && $res->{message};

        if ($req->{command} eq 'change_cluster' && $res->{success}) {
            $cluster = $res->{path} || $req->{name} || $cluster;
            save_current_path($cluster);
        }
    }
    say "\nGoodbye!";
}

1;
