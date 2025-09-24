package App::ordo;
use strict;
use warnings;
our $VERSION = '0.01';
use Exporter 'import';
our @EXPORT_OK = qw(hello);

# ABSTRACT: A utility module for the ordo script

=head1 NAME

App::ordo - A utility module for the ordo script

=head1 DESCRIPTION

This module provides utility functions for the C<ordo> script. See C<script/ordo> for usage details.

=head1 FUNCTIONS

=head2 hello

Returns a greeting string.

  use App::ordo qw(hello);
  print hello("World");  # Outputs: Hello, World!

=cut

sub hello {
    my ($name) = @_;
    return "Hello, $name!\n";
}

1;
