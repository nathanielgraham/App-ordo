package App::Ordo::Command::Ls;
use Moo;
use feature qw(say);
use utf8;
use open ':std', ':utf8'; # Set STDOUT and STDERR to UTF-8

extends 'App::Ordo::Command::Base';
use Data::Dumper;

use App::Ordo              qw($CURRENT_PATH epoch_to_tminus epoch_to_duration);
use Term::ANSIColor        qw(colored);
use Text::Table::Tiny 1.02 qw(generate_table);
use JSON::PP;

sub name    { "ls" }
sub summary { "List jobs and clusters in current path" }
sub usage   { "[filter] [--wide|-l] [--deps] [--tree] [--json]" }

sub option_spec {
   return {
      'wide|l' => 'Show all columns including %CPU/%MEM/NEEDS',
      'deps|d' => 'Show dependency arrows (multi-line)',
      'tree|t' => 'Show as dependency tree',
      'json|j' => 'Output as JSON',
   };
}

has 'base_cluster_id' => (is => 'rw');
has 'cluster_by_id' => (is => 'rw');
has 'items' => (is => 'rw');
has 'json' => (is => 'rw', default => sub { JSON::PP->new->ascii->pretty->allow_nonref } );

sub execute {
   my ( $self, $opt, @filter_words ) = @_;

   my $res = $self->api->call( 'find_cluster', {} );

   unless ( $res->{success} && $res->{clusters} && @{ $res->{clusters} } ) {
      say colored( ["bold yellow"], "No items found in current path" );
      return;
   }

   # Show local time
   my $now = scalar localtime;
   say colored( ["bright_black"], "Local time is $now" ) unless $opt->{json};

   $self->base_cluster_id($res->{clusters}[0]->{id});
   $self->items([]);

   $self->cluster_by_id( { map { $_->{id} => $_ } @{ $res->{clusters} } } );

   # Build hierarchy from current cluster
   my $base_path = $CURRENT_PATH;
   #$self->_add_cluster_and_children( \@items, $current_cluster->{id}, \%cluster_by_id );
   $self->_add_cluster_and_children( $self->base_cluster_id );

   # Apply filter
   if (@filter_words) {
      my $filter = lc join( ' ', @filter_words );
      $self->items( [ grep {
         my $name  = lc( $_->{full_path} || '' );
         my $state = lc( $_->{jobstate}  || '' );
         $name =~ /\Q$filter\E/ || $state eq $filter
      } @{ $self->items } ] );
   }

   if ( $opt->{json} ) {
      print $self->json->encode($self->items);
      return;
   }

   if ( $opt->{tree} ) {
      $self->_print_tree( $self->items );
      return;
   }

   $self->_print_table( $self->items, $opt );
}

sub _add_cluster_and_children {
   my ( $self, $cluster_id, $base_path ) = @_;

   my $cluster = $self->cluster_by_id->{$cluster_id} or return;
   #if ($cluster_id == $self->base_cluster_id) {
   my $cluster_path = $base_path ? "$base_path/$cluster->{name}" : $cluster->{name};
   push @{ $self->items },
     {
      id          => $cluster->{id},
      full_path   => $cluster_path,
      jobstate    => $cluster->{jobstate} || '—',
      server_name => '',
      pid         => '',
      last_start  => epoch_to_tminus( $cluster->{started} ),
      duration    => epoch_to_duration( $cluster->{started}, $cluster->{ended} ),
      next_start  => epoch_to_tminus( $cluster->{next_start} ),
      cal_id      => $cluster->{cal_id},
      pctcpu      => '',
      pctmem      => '',
      needs       => {},
      is_cluster  => 1,
     };

   # Jobs
   my @jobs = sort { $a->{id} <=> $b->{id} } @{ $cluster->{jobs} || [] };
   for my $job (@jobs) {
      push @{ $self->items },
        {
         id          => $job->{id},
         full_path   => "$cluster_path/$job->{name}",
         jobstate    => $job->{jobstate}    || '—',
         server_name => $job->{server_name} || '',
         pid         => $job->{pid} // '',
         last_start  => epoch_to_tminus( $job->{started} ),
         duration    => epoch_to_duration( $job->{started}, $job->{ended} ),
         next_start  => epoch_to_tminus( $job->{next_start} ),
         cal_id      => '',
         pctcpu      => $job->{pctcpu} // '',
         pctmem      => $job->{pctmem} // '',
         needs       => $job->{needs} || {},
         is_cluster  => 0,
        };
   }

   # Sub-clusters
   my @children = grep { $_->{parent_id} && $_->{parent_id} == $cluster_id } values %{ $self->cluster_by_id };
   @children = sort { $a->{id} <=> $b->{id} } @children;

   for my $child (@children) {
      $self->_add_cluster_and_children( $child->{id}, $cluster_path );
   }
}

sub _print_tree {
   my ( $self, $items ) = @_;
   print colored( ["bold cyan"], "$CURRENT_PATH/\n" );

   my %parents;
   for my $item (@$items) {
      next if $item->{is_cluster};
      my @deps = keys %{ $item->{needs} || {} };
      $parents{ $item->{id} } = \@deps if @deps;
   }

   for my $item (@$items) {
      my $prefix = $item->{is_cluster} ? "" : ( $parents{ $item->{id} } ? "└── " : "├── " );
      my $state_color =
          $item->{jobstate} eq 'complete' ? 'green'
        : $item->{jobstate} eq 'running'  ? 'magenta'
        : $item->{jobstate} eq 'failed'   ? 'red'
        :                                   'yellow';

      print "$prefix" . colored( ["bold $state_color"], $item->{full_path} ) . colored( ["bright_black"], "  $item->{jobstate}  $item->{server_name}" );

      if ( my $deps = $parents{ $item->{id} } ) {
         my @sorted = sort @$deps;
         print "    " . colored( ["bright_black"], "↑ " . join( "    ↑ ", @sorted ) );
      }
   }
   print "";
}

sub _print_table {
   my ( $self, $items, $opt ) = @_;

   my @headers = ( "ID", "PATH", "STATE", "SERVER", "PID", "LAST_START", "DURATION", "NEXT_START", "CALENDAR" );
   push @headers, ( "%CPU", "%MEM", "NEEDS" ) if $opt->{wide};

   my @rows = ( \@headers );

   for my $item (@$items) {
      my @deps = sort keys %{ $item->{needs} || {} };

      my $state_color =
          $item->{jobstate} eq 'complete' ? 'green'
        : $item->{jobstate} eq 'immutable' ? 'cyan'
        : $item->{jobstate} eq 'running'  ? 'magenta'
        : $item->{jobstate} eq 'failed'   ? 'red'
        : $item->{jobstate} eq 'waiting'  ? 'yellow'
        :                                   'white';

      my $path_display =
        $item->{is_cluster}
        ? colored( ["bold blue"], $item->{full_path} . '/')
        : $item->{full_path};

      my @row = (
         $item->{id}, $path_display,
         colored( ["bold $state_color"], $item->{jobstate} ),
         $item->{server_name} || '',
         $item->{pid} // '',
         $item->{last_start} || '',
         $item->{duration}   || '',
         $item->{next_start} || '',
         $item->{cal_id} ? "ID $item->{cal_id}" : '',
      );

      push @row, ( $item->{pctcpu} // '', $item->{pctmem} // '', @deps ? join( ",", @deps ) : '', ) if $opt->{wide};

      if ( $opt->{deps} && @deps ) {
         push @rows, \@row;
         push @rows, [ ('') x 9, "← $_" ] for @deps;
      }
      else {
         push @rows, \@row;
      }
   }

   say generate_table(
      rows       => \@rows,
      header_row => 1,
      style      => 'boxrule',
   );
}

1;
