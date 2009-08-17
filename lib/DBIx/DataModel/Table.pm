package DBIx::DataModel::Table;

use warnings;
no warnings 'uninitialized';
use strict;
use Carp;
use base 'DBIx::DataModel::Source';
use Storable     qw/freeze/;
use Scalar::Util qw/refaddr/;


sub DefaultColumns {
  my ($class, $columns) = @_;
  $class->classData->{columns} = $columns;
}




sub ColumnType {
  my ($class, $typeName, @args) = @_;

  not ref($class) or croak "'ColumnType' is a class method";

  my $handlers = $class->schema->classData->{columnHandlers}{$typeName} or 
    croak "unknown ColumnType : $typeName";

  foreach my $column (@args) {
    $class->ColumnHandlers($column, %$handlers)
  }
  return $class;
}


sub ColumnHandlers {
  my ($class, $columnName, %handlers) = @_;

  not ref($class) or croak "'ColumnHandlers' is a class method";

  while (my ($handlerName, $coderef) = each %handlers) {
    $class->classData->{columnHandlers}{$columnName}{$handlerName} = $coderef;
  }
  return $class;
}



sub AutoExpand {
  my ($class, @roles) = @_;

  not ref($class) or croak "'AutoExpand' is a class method";

  # check that we only AutoExpand on composition roles
  my $joins = $class->schema->classData->{joins}{$class};
  foreach my $role (@roles) {
    $joins->{$role}{is_composition}
      or croak "cannot AutoExpand on $role: not a composition";
  }

  # closure to iterate on the roles
  my $autoExpand = sub {
    my ($self, $recurse) = @_;
    foreach my $role (@roles) {
      my $r = $self->expand($role); # can be an object ref or an array ref
      if ($r and $recurse) {
	$r = [$r] unless ref($r) eq 'ARRAY';
	$_->autoExpand($recurse) foreach @$r;
      }
    }
  };

  $class->schema->_defineMethod($class => autoExpand => $autoExpand, "silent");
  return $class;
}


sub autoInsertColumns {
  my $self = shift; 
  return $self->schema->autoInsertColumns,
         @{$self->classData->{autoInsertColumns} || []};
}

sub autoUpdateColumns {
  my $self = shift; 
  return $self->schema->autoUpdateColumns,
         @{$self->classData->{autoUpdateColumns} || []};
}

sub noUpdateColumns {
  my $self = shift; 
  return $self->schema->noUpdateColumns, 
         @{$self->classData->{noUpdateColumns} || []};
}



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



sub componentRoles {
  my $self  = shift; 
  my $class = ref($self) || $self;
  my $join_info =  $class->schema->classData->{joins}{$class};
  return grep {$join_info->{$_}{is_composition}} keys %$join_info;
}




sub fetch {
  my $class = shift;
  not ref($class) or croak "fetch should be called as class method";
  my %select_args;

  # if last argument is a hashref, it contains arguments to the select() call
  if (UNIVERSAL::isa($_[-1], 'HASH')) {
    %select_args = %{pop @_};
  }

  return $class->select(-fetch => \@_, %select_args);
}


sub fetch_cached {
  my $class = shift;
  my $dbh_addr    = refaddr $class->schema->dbh;
  my $freeze_args = freeze \@_;
  return $class->classData->{fetch_cached}{$dbh_addr}{$freeze_args} 
            ||= $class->fetch(@_);
}


sub insert {
  my ($class, @records) = @_;
  not ref($class) or croak "insert() should be called as class method";

  # if data is received as arrayrefs, transform it into a list of hashrefs.
  # NOTE : this is kind of dumb; a more efficient implementation
  # would be to prepare one single DB statement and then execute it on
  # each data row, but that would require some refactoring of _singleInsert
  # and _rawInsert.
  if (ref $records[0] eq 'ARRAY') {
    my $header_row = shift @records;
    foreach my $data_row (@records) {
      ref $data_row eq 'ARRAY' 
        or croak "data row after a header row should be an arrayref";
      @$data_row == @$header_row
        or croak "number of items in data row not same as header row";
      my %real_record;
      @real_record{@$header_row} = @$data_row;
      $data_row = \%real_record;
    }
  }

  # check that there is at least one record to insert
  @records or croak "insert(): not enough arguments";

  my @ids; # to hold primary keys of inserted records

  # insert each record, one by one
  foreach my $record (@records) {
    bless $record, $class;
    $record->applyColumnHandler('toDB');

    # remove subtrees and noUpdateColumns
    delete $record->{$_} foreach $class->noUpdateColumns;
    my $subrecords = $record->_weed_out_subtrees;

    # do the insertion
    push @ids, $record->_singleInsert();

    # insert the subtrees
    $record->_insert_subtrees($subrecords);
  }

  # choose what to return according to context
  return @ids if wantarray;             # list context
  return      if not defined wantarray; # void context
  carp "insert({...}, {...}, ..) called in scalar context" if @records > 1;
  return $ids[0];                       # scalar context
}


sub _singleInsert {
  my ($self) = @_; # assumes %$self only contains scalars, and noUpdateColumns
                   # have already been removed 
  my $class  = ref $self or croak "_singleInsert called as class method";

  $self->_rawInsert;

  # make sure the object has its own key
  my @primKeyCols = $class->primKey;
  unless (@{$self}{@primKeyCols}) {
    my $n_columns = @primKeyCols;
    not ($n_columns > 1) 
      or croak "cannot ask for last_insert_id: primary key in $class "
             . "has $n_columns columns";

    my ($dbh, %dbh_options) = $class->schema->dbh;

    # fill the primary key from last_insert_id returned by the DBMS
    $self->{$primKeyCols[0]}
      = $dbh->last_insert_id($dbh_options{catalog}, 
                             $dbh_options{schema}, 
                             $class->db_table, 
                             $primKeyCols[0]);
  }

  return $self->{$primKeyCols[0]};
}


sub _rawInsert {
  my ($self) = @_; 
  my $class  = ref $self or croak "_rawInsert called as class method";

  # need to clone into a plain hash because that's what SQL::Abstract wants...
  my %clone = %$self;

  for my $method (qw/autoInsertColumns autoUpdateColumns/) {
    my %autoColumns = $self->$method;
    while (my ($col, $handler) = each %autoColumns) {
      $clone{$col} = $handler->(\%clone, $class);
    }
  }

  # perform the insertion
  my $schema_data = $class->schema->classData;
  my ($sql, @bind) = $schema_data->{sqlAbstr}
                                 ->insert($class->db_table, \%clone);
  $class->_debug($sql . " / " . join(", ", @bind) );
  my $sth = $class->schema->dbh->prepare($sql);
  $schema_data->{lasth} = $sth if $schema_data->{keepLasth};
  $sth->execute(@bind);
}


sub _weed_out_subtrees {
  my ($self) = @_; 
  my $class = ref $self;

  my %is_component;
  $is_component{$_} = 1 foreach $class->componentRoles;
  my $subrecords = {};

  foreach my $k (keys %$self) {
    my $v = $self->{$k};
    if (ref $v) {
      $is_component{$k} ? $subrecords->{$k} = $v 
                        : carp "unexpected reference $k in record, deleted";
      delete $self->{$k};
    }
  }
  return $subrecords;
}


sub _insert_subtrees {
  my ($self, $subrecords) = @_;
  my $class = ref $self;
  if (keys %$subrecords) {  # if there are component objects to insert
    while (my ($role, $arrayref) = each %$subrecords) { # insert_into each role
      UNIVERSAL::isa($arrayref, 'ARRAY')
          or croak "Expected an arrayref for component role $role in $class";
      next if not @$arrayref;
      my $meth = "insert_into_$role";
      $self->$meth(@$arrayref);
      $self->{$role} = $arrayref;
    }
  }
}

sub update { _modifyData('update', @_); }

sub delete { _modifyData('delete', @_); }


sub hasInvalidColumns {
  my ($self) = @_;
  my $results = $self->applyColumnHandler('validate');
  my @invalid;			# names of invalid columns
  while (my ($k, $v) = each %$results) {
    push @invalid, $k if defined($v) and not $v;
  }
  return @invalid ? \@invalid : undef;
}





#------------------------------------------------------------
# Internal utility functions
#------------------------------------------------------------


sub _modifyData { # called by methods 'update' and 'delete'.
                  # .. actually the factorization of code is not so 
                  #    great, maybe should find another, better way
  my $toDo        = shift;
  my $self        = shift;
  my $class       = ref($self) || $self;
  my $db_table    = $class->db_table;
  my $dbh         = $class->schema->dbh or croak "Schema has no dbh";
  my @primKeyCols = $class->primKey;

  if (not ref($self)) {		# called as class method
    scalar(@_) or croak "not enough args for '$toDo' called as class method";

    # $self becomes a hashref to a copy of the values passed as last argument
    $self = ref($_[-1]) ? {%{pop @_}} : {};

    # if primary key is given as a first argument, add it into the hashref
    @{$self}{@primKeyCols} = @_ if @_;

    bless $self, $class;
  }
  else { # called as instance method
    croak "too many args for '$toDo' called as instance method" if @_;

    if ($toDo eq 'delete') {
      # cascaded delete
      foreach my $role ($class->componentRoles) {
        my $component_items = $self->{$role} or next;
        $_->delete foreach @$component_items;
      }
    }
  }

  # convert values into database format
  $self->applyColumnHandler('toDB');

  # move values of primary keys into a specific '%where' structure
  my %where;
  foreach my $col (@primKeyCols) {
    $where{$col} = delete $self->{$col} or 
      croak "no value for primary column $col in table $class";
  }

  if ($toDo eq 'update') {
    delete $self->{$_} foreach $self->noUpdateColumns;

    # references to foreign objects should not be passed either (see 'expand')
    foreach (keys %$self) {
      delete $self->{$_} if ref($self->{$_});
    }

    my %autoUpdate = $self->autoUpdateColumns;
    while (my ($col, $handler) = each %autoUpdate) {
      $self->{$col} = $handler->($self, $class, \%where);
    }
  }

  # unbless $self into just a hashref and perform the update
  my $schema_data = $self->schema->classData;
  my $sqlA        = $schema_data->{sqlAbstr};
  bless $self, 'HASH';
  my ($sql, @bind) 
    = ($toDo eq 'update') ? $sqlA->update($db_table, $self, \%where) 
                          : $sqlA->delete($db_table, \%where);
  $class->_debug($sql . " / " . join(", ", @bind) );
  my $sth = $dbh->prepare($sql);
  $schema_data->{lasth} = $sth if $schema_data->{keepLasth};
  $sth->execute(@bind);
}


1; # End of DBIx::DataModel::Table

__END__




=head1 NAME

DBIx::DataModel::Table - Parent for Table classes

=head1 DESCRIPTION

This is the parent class for all table classes created through

  $schema->Table($classname, ...);

=head1 METHODS

Methods are documented in 
L<DBIx::DataModel::Doc::Reference|DBIx::DataModel::Doc::Reference>.
This module implements

=over

=item L<DefaultColumns|DBIx::DataModel::Doc::Reference/DefaultColumns>

=item L<ColumnType|DBIx::DataModel::Doc::Reference/ColumnType>

=item L<ColumnHandlers|DBIx::DataModel::Doc::Reference/ColumnHandlers>

=item L<AutoExpand|DBIx::DataModel::Doc::Reference/AutoExpand>

=item L<autoUpdateColumns|DBIx::DataModel::Doc::Reference/autoUpdateColumns>

=item L<noUpdateColumns|DBIx::DataModel::Doc::Reference/noUpdateColumns>

=item L<primKey|DBIx::DataModel::Doc::Reference/primKey>

=item L<fetch|DBIx::DataModel::Doc::Reference/fetch>

=item L<fetch_cached|DBIx::DataModel::Doc::Reference/fetch_cached>

=item L<insert|DBIx::DataModel::Doc::Reference/insert>

=item L<_singleInsert|DBIx::DataModel::Doc::Reference/_singleInsert>

=item L<_rawInsert|DBIx::DataModel::Doc::Reference/_rawInsert>

=item L<update|DBIx::DataModel::Doc::Reference/update>

=item L<hasInvalidColumns|DBIx::DataModel::Doc::Reference/hasInvalidColumns>

=back


=head1 AUTHOR

Laurent Dami, C<< <laurent.dami AT etat.ge.ch> >>


=head1 COPYRIGHT & LICENSE

Copyright 2006 Laurent Dami.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.



