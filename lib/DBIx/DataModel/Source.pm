#----------------------------------------------------------------------
package DBIx::DataModel::Source;
#----------------------------------------------------------------------

# see POD doc at end of file

use warnings;
no warnings 'uninitialized';
use strict;
use Carp;
use base 'DBIx::DataModel::Base';
use DBIx::DataModel::Statement;

our @CARP_NOT = qw/DBIx::DataModel         DBIx::DataModel::Schema
		   DBIx::DataModel::Table  DBIx::DataModel::View  
                   DBIx::DataModel::Iterator/;


#----------------------------------------------------------------------
# COMPILE-TIME PUBLIC METHODS
#----------------------------------------------------------------------


sub MethodFromJoin {
  my ($class, $meth_name, @roles) = @_;
  @roles or croak "MethodFromJoin: not enough arguments";

  # last arg may be a hashref of parameters to be passed to select()
  my $pre_args;
  $pre_args = pop @roles if ref $roles[-1];

  my $meth = sub {
    my ($self, @args) = @_;

    # if called without args, and just one role, and that role 
    # was previously expanded, then return the cached version
    if (@roles == 1 && !@args) {
      my $cached = $self->{$roles[0]};
      return $cached if $cached;
    }

    unshift @args, %$pre_args if $pre_args;

    my $statement = $self->join(@roles);
    return ref $self ? $statement->select(@args)   # when instance method
                     : $statement->refine(@args);  # when class method
  };

  $class->schema->_defineMethod($class, $meth_name, $meth);
  return $class;
}

# backwards compatibility
*MethodFromRoles = \&MethodFromJoin;


#----------------------------------------------------------------------
# RUNTIME PUBLIC METHODS
#----------------------------------------------------------------------

sub schema {
  my $self = shift;
  return $self->classData->{schema}; 
}


sub table {
  my $self = shift; 
  carp "the table() method is deprecated; call db_table() instead";
  return $self->db_table;
}

sub db_table {
  my $self = shift; 
  return $self->classData->{db_table};
}


sub selectImplicitlyFor {
  my $self = shift;

  if (@_) {
    not ref($self) 
      or croak "selectImplicitlyFor(value) should be called as class method";
    $self->classData->{selectImplicitlyFor} = shift;
  }
  return exists($self->classData->{selectImplicitlyFor}) ? 
    $self->classData->{selectImplicitlyFor} :  
    $self->schema->selectImplicitlyFor;
}



sub blessFromDB {
  my ($class, $record) = @_;
  not ref($class) 
    or croak "blessFromDB() should be called as class method";
  bless $record, $class;
  $record->applyColumnHandler('fromDB');
  return $record;
}




sub select {
  my ($class, @args) = @_;
  not ref($class) 
    or croak "select() should be called as class method";

  my $statement = $class->schema->classData->{statementClass}->new($class);
  return $statement->select(@args);
}


sub createStatement {
  my $class = shift;

  warn "->createStatement() is obsolete, use "
     . "->select(.., -resultAs => 'statement')";

  return $class->select(@_, -resultAs => 'statement');
}




sub applyColumnHandler {
  my ($self, $handlerName, $objects) = @_;

  my $targets        = $objects || [$self];
  my $columnHandlers = $self->classData->{columnHandlers} || {};
  my $results        = {};

  # iterate over all registered columnHandlers
  while (my ($columnName, $handlers) = each %$columnHandlers) {

    # is $handlerName registered in this column ?
    my $handler = $handlers->{$handlerName} or next;

    # apply that handler to all targets that possess the $columnName
    foreach my $obj (@$targets) {
      my $result = exists $obj->{$columnName} ? 
            $handler->($obj->{$columnName}, $obj, $columnName, $handlerName) :
            undef;
      if ($objects) { push(@{$results->{$columnName}}, $result); }
      else          { $results->{$columnName} = $result;         }
    }
  }

  return $results;
}


sub expand {
  my ($self, $role, @args) = @_;
  $self->{$role} = $self->$role(@args);
}

sub autoExpand {} # default; overridden in subclasses through AutoExpand()


sub join {
  my ($self, $first_role, @other_roles) = @_;

  my $class         = ref $self || $self;
  my $isa_view      = $class->isa('DBIx::DataModel::View');
  my $schema        = $class->schema;
  my $joins         = $schema->classData->{joins};
  my $table_classes = $isa_view ? $class->classData->{parentTables}
                                : [$class];

  # find first join information
  my ($join_data) = grep {$_} map {$joins->{$_}{$first_role}} @$table_classes
    or croak "could not find role $first_role in $class";

  # build search criteria on %$self from first join information
  my (%criteria, @left_cols);
  while (my ($left_col, $right_col) = each %{$join_data->{where}}) {
    $criteria{$right_col} = "?$left_col";
    push @left_cols, $left_col;
  }

  # choose source and build a statement
  my $source 
    = @other_roles  ? $schema->join($join_data->{table}, 
                                    @other_roles)     # build a view
                    : $join_data->{table};            # just take the table
  my $statement = $source->select(-where    => \%criteria,
                                  -resultAs => 'statement');

  # if called as an instance method
  if (ref $self) {

    # check that all foreign keys are present
    my $missing = join ", ", grep {not exists $self->{$_}} @left_cols;
    not $missing
      or croak "cannot follow role '$first_role': missing column '$missing'";

    # bind to foreign keys
    $statement->bind(map {($_ => $self->{$_})} @left_cols);
  }

  return $statement;
}


# backwards compatibility
*selectFromRoles = \&join;


sub primKey {
  my $self = shift; 

  # get primKey columns
  my @primKey = @{$self->classData->{primKey}};

  # if called as instance method, get primKey values
  @primKey = @{$self}{@primKey} if ref $self;

  # choose what to return depending on context
  return @primKey if wantarray;
  not(@primKey > 1) 
    or croak "cannot return a multi-column primary key in a scalar context";
  return $primKey[0];
}


#----------------------------------------------------------------------
# RUNTIME PRIVATE METHODS OR FUNCTIONS
#----------------------------------------------------------------------



sub _debug { # internal method to send debug messages
  my ($self, $msg) = @_;
  my $debug = $self->schema->classData->{debug};
  if ($debug) {
    if (ref $debug && $debug->can('debug')) { $debug->debug($msg) }
    else                                    { carp $msg; }
  }
}


1; # End of DBIx::DataModel::Source

__END__

=head1 NAME

DBIx::DataModel::Source - Abstract parent for Table and View 

=head1 DESCRIPTION

Abstract parent class for L<DBIx::DataModel::Table|DBIx::DataModel::Table> and
L<DBIx::DataModel::View|DBIx::DataModel::View>. For internal use only.


=head1 METHODS

Methods are documented in
L<DBIx::DataModel::Doc::Reference|DBIx::DataModel::Doc::Reference>.
This module implements

=over

=item L<MethodFromJoin|DBIx::DataModel::Doc::Reference/MethodFromJoin>

=item L<schema|DBIx::DataModel::Doc::Reference/schema>

=item L<db_table|DBIx::DataModel::Doc::Reference/db_table>

=item L<selectImplicitlyFor|DBIx::DataModel::Doc::Reference/selectImplicitlyFor>

=item L<blessFromDB|DBIx::DataModel::Doc::Reference/blessFromDB>

=item L<select|DBIx::DataModel::Doc::Reference/select>

=item L<applyColumnHandler|DBIx::DataModel::Doc::Reference/applyColumnHandler>

=item L<expand|DBIx::DataModel::Doc::Reference/expand>

=item L<autoExpand|DBIx::DataModel::Doc::Reference/autoExpand>

=item L<join|DBIx::DataModel::Doc::Reference/join>

=item L<primKey|DBIx::DataModel::Doc::Reference/primKey>

=back

=head1 PRIVATE METHOD NAMES

The following methods or functions are used
internally by this module and 
should be considered as reserved names, not to be
redefined in subclasses :

=over

=item _debug

=back


=head1 AUTHOR

Laurent Dami, E<lt>laurent.dami AT etat  ge  chE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2006, 2008 by Laurent Dami.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself. 

