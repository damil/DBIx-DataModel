## TODO: -returning => [], meaning return a list of arrayrefs containing primKeys


package DBIx::DataModel::Source::Table;

use warnings;
no warnings 'uninitialized';
use strict;
use mro 'c3';
use parent 'DBIx::DataModel::Source';
use Carp;
use Storable     qw/freeze/;
use Scalar::Util qw/refaddr reftype/;
use namespace::autoclean;

{no strict 'refs'; *CARP_NOT = \@DBIx::DataModel::CARP_NOT;}


# 'insert class method only available if schema is in singleton mode;
# this method is delegated to the Statement class.
DBIx::DataModel::Source::_delegate_to_statement_class('insert');

sub _singleInsert {
  my ($self, %options) = @_; 
  # assumes that %$self only contains scalars

  my $class  = ref $self or croak "_singleInsert called as class method";

  # call DB insert
  my @result = $self->_rawInsert(%options);

  # if $options{-returning} was a scalar or arrayref, return that result
  return @result if @result; 

  # otherwise: first make sure we have the primary key
  my @prim_key_cols = $class->primary_key;
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




sub _rawInsert {
  my ($self, %options) = @_; 
  my $class  = ref $self or croak "_rawInsert called as class method";
  my $metadm = $class->metadm;

  my $use_returning 
    = $options{-returning} && ref $options{-returning} ne 'HASH';

  # clone $self as mere unblessed hash (for SQLA) and extract ref to $schema 
  my %values = %$self;
  my $schema = delete $values{__schema};
  # THINK: this cloning %values = %$self is inefficient because data was 
  # already cloned in Statement::insert(). But quite hard to improve :-((

  # perform the insertion
  my @sqla_args   = ($metadm->db_from, \%values);
  push @sqla_args, {returning => $options{-returning}} if $use_returning;
  my ($sql, @bind) = $schema->sql_abstract->insert(@sqla_args);
  $self->schema->_debug($sql . " / " . join(", ", @bind) );
  my $sth = $schema->dbh->prepare($sql);
  $sth->execute(@bind);

  return $sth->fetchrow_array if $use_returning;
  return;                      # otherwise
}



sub _get_last_insert_id {
  my ($self, $col) = @_;
  my $class = ref $self;
  my ($dbh, %dbh_options) = $class->schema->dbh;
  my $table  = $self->metadm->db_from;

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



sub _weed_out_subtrees {
  my ($self) = @_; 
  my $class = ref $self;

  # which "components" were declared through Schema->Composition(...)
  my %is_component = map {($_ => 1)} $class->componentRoles;

  my %subrecords;

  # extract references that correspond to component names
  foreach my $k (keys %$self) {
    next if $k eq '__schema';
    my $v = $self->{$k};
    if (ref $v) {
      $is_component{$k} ? $subrecords{$k} = $v 
                        : carp "unexpected reference $k in record, deleted";
      delete $self->{$k};
    }
  }

  return keys %subrecords ? \%subrecords : undef;
}



sub has_invalid_columns {
  my ($self) = @_;
  my $results = $self->apply_column_handler('validate');
  my @invalid;			# names of invalid columns
  while (my ($k, $v) = each %$results) {
    push @invalid, $k if defined($v) and not $v;
  }
  return @invalid ? \@invalid : undef;
}





#------------------------------------------------------------
# Internal utility functions
#------------------------------------------------------------

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


#------------------------------------------------------------
# update and delete
#------------------------------------------------------------

# update() and delete(): differentiate between usage as
# $obj->update(), or $class->update(@args). In both cases, we then
# delegate to the Statement class

foreach my $method (qw/update delete/) {
  no strict 'refs';
  *$method = sub {
    my $self = shift;

    my $metadm      = $self->metadm;
    my $meta_schema = $metadm->schema;
    my $schema;

    if (ref $self) { # if called as $obj->$method()
      not @_ or croak "$method() : too many arguments";
      @_ = ($self);
      $schema = delete $self->{__schema};
    }

    # otherwise, if in single-schema mode, or called as $class->$method(@args)
    $schema ||= $meta_schema->class->singleton;

    # delegate to the statement class
    my $statement   = $meta_schema->statement_class->new($metadm, $schema);
    return $statement->$method(@_);
  };
}



1; # End of DBIx::DataModel::Source::Table

__END__




=head1 NAME

DBIx::DataModel::Source::Table - Parent for Table classes

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



