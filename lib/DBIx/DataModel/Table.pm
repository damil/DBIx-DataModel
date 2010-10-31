## TODO: -returning => [], meaning return a list of arrayrefs containing primKeys


package DBIx::DataModel::Table;

use warnings;
no warnings 'uninitialized';
use strict;
use Carp;
use base 'DBIx::DataModel::Source';
use Storable     qw/freeze/;
use Scalar::Util qw/refaddr reftype/;


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
  no warnings 'uninitialized';
  if (reftype $_[-1] eq 'HASH') {
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
  my $class = shift;
  not ref($class) or croak "insert() should be called as class method";

  # end of list may contain options, recognized because option name is a scalar
  my $options      = $class->_parseEndingOptions(\@_, qr/^-returning$/);
  my $want_subhash = ref $options->{-returning} eq 'HASH';

  # records to insert
  my @records = @_;

  # if data is received as arrayrefs, transform it into a list of hashrefs.
  # NOTE : this is kind of dumb; a more efficient implementation
  # would be to prepare one single DB statement and then execute it on
  # each data row, or even SQL like INSERT ... VALUES(...), VALUES(..), ...
  # (supported by some DBMS), but that would require some refactoring 
  # of _singleInsert and _rawInsert.
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
  @records or croak "insert(): not record to insert";

  # insert each record, one by one
  my @results;
  foreach my $record (@records) {
    bless $record, $class;
    $record->applyColumnHandler('toDB');

    # remove subtrees and noUpdateColumns
    delete $record->{$_} foreach $class->noUpdateColumns;
    my $subrecords = $record->_weed_out_subtrees;

    # do the insertion. Result depends on %$options
    my @single_result = $record->_singleInsert(%$options);

    # insert the subtrees into DB, and keep the return vals if $want_subhash
    if ($subrecords) {
      my $subresults = $record->_insert_subtrees($subrecords, %$options);
      if ($want_subhash) {
        ref $single_result[0] eq 'HASH'
          or die "_singleInsert(..., -returning => {}) "
               . "did not return a hashref";
        $single_result[0]{$_} = $subresults->{$_} for keys %$subresults;
      }
    }

    push @results, @single_result;
  }

  # choose what to return according to context
  return @results if wantarray;             # list context
  return          if not defined wantarray; # void context
  carp "insert({...}, {...}, ..) called in scalar context" if @results > 1;
  return $results[0];                       # scalar context
}


sub _singleInsert {
  my ($self, %options) = @_; 
  # assumes %$self only contains scalars, and noUpdateColumns
  #  have already been removed 

  my $class  = ref $self or croak "_singleInsert called as class method";

  # call DB insert
  my @result = $self->_rawInsert(%options);

  # if $options{-returning} was a scalar or arrayref, return that result
  return @result if @result; 

  # otherwise: first make sure we have the primary key
  my @prim_key_cols = $class->primKey;
  if (grep {not defined $self->{$_}} @prim_key_cols) {
    my $n_columns = @prim_key_cols;
    not ($n_columns > 1) 
      or croak "cannot ask for last_insert_id: primary key in $class "
             . "has $n_columns columns";
    my $pk_col = $prim_key_cols[0];
    $self->{$pk_col} = $self->_get_last_insert_id($pk_col);
  }

  # now return the primary key, either as a hashref or as a list
  if ($options{-returning} && ref $options{-returning} eq 'HASH') {
    my %result;
    $result{$_} = $self->{$_} for @prim_key_cols;
    return \%result;
  }
  else {
    return @{$self}{@prim_key_cols};
  }
}



sub _get_last_insert_id {
  my ($self, $col) = @_;
  my $class = ref $self;
  my ($dbh, %dbh_options) = $class->schema->dbh;
  my $table  = $class->db_table;

  my $id
      # either callback given by client ...
      = $dbh_options{last_insert_id} ? 
          $dbh_options{last_insert_id}->($dbh, $table, $col)

      # or catalog and/or schema given by client ...
      : (exists $dbh_options{catalog} || exists $dbh_options{schema}) ?
          $dbh->last_insert_id($dbh_options{catalog}, $dbh_options{schema},
                               $table, $col)

      # or plain call to last_insert_id() with all undefs
      :   $dbh->last_insert_id(undef, undef, undef, undef);

  return $id;
}


sub _rawInsert {
  my ($self, %options) = @_; 
  my $class = ref $self or croak "_rawInsert called as class method";
  my $use_returning 
    = $options{-returning} && ref $options{-returning} ne 'HASH';

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
  my @sqla_args   = ($class->db_table, \%clone);
  push @sqla_args, {returning => $options{-returning}} if $use_returning;
  my ($sql, @bind) = $schema_data->{sqlAbstr}->insert(@sqla_args);
  $class->_debug($sql . " / " . join(", ", @bind) );
  my $sth = $class->schema->dbh->prepare($sql);
  $schema_data->{lasth} = $sth if $schema_data->{keepLasth};
  $sth->execute(@bind);
  return $sth->fetchrow_array if $use_returning;
  return;                      # otherwise
}


sub _weed_out_subtrees {
  my ($self) = @_; 
  my $class = ref $self;

  # which "components" were declared through Schema->Composition(...)
  my %is_component = map {($_ => 1)} $class->componentRoles;

  my %subrecords;

  # extract references that correspond to component names
  foreach my $k (keys %$self) {
    my $v = $self->{$k};
    if (ref $v) {
      $is_component{$k} ? $subrecords{$k} = $v 
                        : carp "unexpected reference $k in record, deleted";
      delete $self->{$k};
    }
  }

  return keys %subrecords ? \%subrecords : undef;
}


sub _insert_subtrees {
  my ($self, $subrecords, %options) = @_;
  my $class = ref $self;
  my %results;

  while (my ($role, $arrayref) = each %$subrecords) {
    reftype $arrayref eq 'ARRAY'
      or croak "Expected an arrayref for component role $role in $class";
    next if not @$arrayref;

    # insert via the "insert_into_..." method
    my $meth = "insert_into_$role";
    $results{$role} = [$self->$meth(@$arrayref, %options)];

    # also reinject in memory into source object
    $self->{$role} = $arrayref; 
  }

  return \%results;
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

Copyright 2006, 2010 Laurent Dami.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.



