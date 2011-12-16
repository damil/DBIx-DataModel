#----------------------------------------------------------------------
package DBIx::DataModel::Statement::Oracle;
#----------------------------------------------------------------------
use strict;
use warnings;
no strict 'refs';

use parent      qw/DBIx::DataModel::Statement/;
use mro         qw/c3/;
use DBD::Oracle qw/:ora_fetch_orient :ora_exe_modes/;
use Carp;
use POSIX       qw/LONG_MAX/;

sub sqlize {
  my ($self, @args) = @_;

  # merge new args into $self->{args}
  $self->refine(@args) if @args;

  # remove -limit and -offset from args; they will be handled later in 
  # prepare() and execute(), see below
  $self->{_ora_limit}  = delete $self->{args}{-limit};
  $self->{offset}      = delete $self->{args}{-offset};
  $self->{offset}      = 0 if    defined $self->{_ora_limit}
                            && ! defined $self->{offset};
  $self->refine(-prepare_attrs => {ora_exe_mode=>OCI_STMT_SCROLLABLE_READONLY})
    if defined $self->{offset};

  $self->next::method();
}

sub execute {
  my ($self, @args) = @_;
  $self->next::method(@args);

  if (my $offset = $self->{offset}) {
    $self->{sth}->ora_fetch_scroll(OCI_FETCH_ABSOLUTE, $offset+1)
  }

  return $self;
}



sub next {
  my ($self, $n_rows) = @_;

  # execute the statement
  $self->execute if $self->{status} < DBIx::DataModel::Statement::EXECUTED;

  # fallback to regular handling if didn't use -limit/-offset
  return $self->next::method($n_rows) if ! defined $self->{offset};

  # how many rows to retrieve
  $n_rows //= 1; # if undef, user wants 1 row
  $n_rows > 0  or croak "->next() : invalid argument, $n_rows";
  if ($self->{_ora_limit}) {
    my $row_num = $self->row_num;
    my $max = $self->{_ora_limit} - ($row_num - $self->offset);
    $n_rows = $max if $max < $n_rows;
  }

  # various data for generating rows
  my $sth = $self->{sth}          or croak "absent sth in statement";
  my $hash_key_name = $sth->{FetchHashKeyName} || 'NAME';
  my $cols          = $sth->{$hash_key_name};
  my @rows;

  # fetch the rows
 ROW:
  while ($n_rows--) {
    # build a data row
    my %row;
    my $old_pos = $self->{row_num} || 0;
    @row{@$cols} = @{$sth->ora_fetch_scroll(OCI_FETCH_NEXT, 0)};

    # only way to know if this row was fresh : ask for the cursor position
    my $new_pos = $sth->ora_scroll_position();
    if ($new_pos == $old_pos) {
      $self->{row_count} = $new_pos;
      last ROW;
    }

    # here we really got a fresh row, so add it to results
    push @rows, \%row;
    $self->{row_num} += 1;
  }

  my $callback = $self->{row_callback} or croak "absent callback in statement";
  $callback->($_) foreach @rows;
  return \@rows;
}


sub all {
  my ($self) = @_;

  # just call next() with a huge number
  return $self->next(POSIX::LONG_MAX);
}


sub row_count {
  my ($self) = @_;

  # execute the statement
  $self->execute if $self->{status} < DBIx::DataModel::Statement::EXECUTED;

  # fallback to regular handling if didn't use -limit/-offset
  return $self->next::method() if ! defined $self->{offset};

  if (! exists $self->{row_count}) {
    my $sth = $self->{sth};
    # remember current position 
    my $current_pos = $sth->ora_scroll_position();

    # goto last position and get the line number
    $sth->ora_fetch_scroll(OCI_FETCH_LAST, 0);
    $self->{row_count} = $sth->ora_scroll_position();

    # back to previous position (hack: first line must be 1, not 0)
    $sth->ora_fetch_scroll(OCI_FETCH_ABSOLUTE, $current_pos || 1);
  }

  return $self->{row_count};
}

1;

__END__

=head1 NAME

DBIx::DataModel::Statement::Oracle - Statement for interacting with DBD::Oracle

=head1 SYNOPSIS

  DBIx::DataModel->Schema("MySchema",
     statement_class => "DBIx::DataModel::Statement::Oracle",
  );

  my $statement = $source->select(
    ..., 
    -limit => 50, 
    -offset => 200,
    -result_as => 'statement,
  );
  my $total_rows = $statement->row_count;
  my $row_slice  = $statement->all;

=head1 DESCRIPTION

This subclass redefines some parent methods 
from L<DBIx::DataModel::Statement> in order to take advantage
of L<DBD::Oracle/"Scrollable Cursor Methods">.

This is interesting for applications that need to do pagination
within result sets, because Oracle has no support for LIMIT/OFFSET in SQL.
So here we use some special methods of the Oracle driver to retrieve
the total number of rows in a resultset, or to extract a given
slice of rows.

The API is exactly the same as other, regular DBIx::DataModel implementations.

=head1 AUTHOR

Laurent Dami, E<lt>laurent.dami AT etat  ge  chE<gt>, Dec 2011.

=head1 COPYRIGHT AND LICENSE

Copyright 2011 by Laurent Dami.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself. 
