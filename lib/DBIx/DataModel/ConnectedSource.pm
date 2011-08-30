#----------------------------------------------------------------------
package DBIx::DataModel::ConnectedSource;
#----------------------------------------------------------------------
# see POD doc at end of file

use warnings;
use strict;
use Carp;
use Params::Validate qw/validate ARRAYREF HASHREF/;
use Scalar::Util     qw/reftype/;
use Acme::Damn       qw/damn/;
use Module::Load     qw/load/;
use namespace::autoclean;

use DBIx::DataModel;
use DBIx::DataModel::Meta::Utils;

{no strict 'refs'; *CARP_NOT = \@DBIx::DataModel::CARP_NOT;}


sub new {
  my ($class, $meta_source, $schema) = @_;

  my $self = bless {meta_source => $meta_source, schema => $schema}, $class;
}


# accessors
DBIx::DataModel::Meta::Utils->define_readonly_accessors(
  __PACKAGE__, qw/meta_source schema/,
);

# additional accessor; here, 'metadm' is a synonym for 'meta_source'
sub metadm { 
  my $self = shift;
  return $self->{meta_source};
}

# several methods are delegated to the Statement class.
foreach my $method (qw/select fetch fetch_cached bless_from_DB/) {
  no strict 'refs';
  *{$method} = sub {
    my $self = shift;

    my $stmt_class = $self->{schema}->metadm->statement_class;
    load $stmt_class;
    my $statement  = $stmt_class->new($self->{meta_source}, $self->{schema});
    return $statement->$method(@_);
  };
}



#----------------------------------------------------------------------
# INSERT
#----------------------------------------------------------------------

sub insert {
  my $self = shift;

  # end of list may contain options, recognized because option name is a scalar
  my $options      = $self->_parse_ending_options(\@_, qr/^-returning$/);
  my $want_subhash = ref $options->{-returning} eq 'HASH';

  # records to insert
  my @records = @_;
  @records or croak "insert(): no record to insert";

  my $got_records_as_arrayrefs = ref $records[0] eq 'ARRAY';

  # if data is received as arrayrefs, transform it into a list of hashrefs.
  # NOTE : this is kind of dumb; a more efficient implementation
  # would be to prepare one single DB statement and then execute it on
  # each data row, or even SQL like INSERT ... VALUES(...), VALUES(..), ...
  # (supported by some DBMS), but that would require some refactoring 
  # of _singleInsert and _rawInsert.
  if ($got_records_as_arrayrefs) {
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

  # insert each record, one by one
  my @results;
  my $meta_source        = $self->{meta_source};
  my %no_update_column   = $meta_source->no_update_column;
  my %auto_insert_column = $meta_source->auto_insert_column;
  my %auto_update_column = $meta_source->auto_update_column;

  my $source_class = $self->{meta_source}->class;
  while (my $record = shift @records) {
    # shallow copy in order not to perturb the caller
    $record = {%$record} unless $got_records_as_arrayrefs;

    # bless, apply column handers and remove unwanted cols
    bless $record, $source_class;
    $record->apply_column_handler('to_DB');
    delete $record->{$_} foreach keys %no_update_column;
    while (my ($col, $handler) = each %auto_insert_column) {
      $record->{$col} = $handler->($record, $source_class);
    }
    while (my ($col, $handler) = each %auto_update_column) {
      $record->{$col} = $handler->($record, $source_class);
    }

    # inject schema
    $record->{__schema} = $self->{schema};

    # remove subtrees (will be inserted later)
    my $subrecords = $record->_weed_out_subtrees;

    # do the insertion. Result depends on %$options.
    my @single_result = $record->_singleInsert(%$options);

    # NOTE: at this point, $record is expected to hold its own primary key

    # insert the subtrees into DB, and keep the return vals if $want_subhash
    if ($subrecords) {
      my $subresults = $record->_insert_subtrees($subrecords, %$options);
      if ($want_subhash) {
        ref $single_result[0] eq 'HASH'
          or die "_single_insert(..., -returning => {}) "
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



sub _parse_ending_options {
  my ($class_or_self, $args_ref, $regex) = @_;

  # end of list may contain options, recognized because option name is a
  # scalar matching the given regex
  my %options;
  while (@$args_ref >= 2 && !ref $args_ref->[-2] 
                         && $args_ref->[-2] && $args_ref->[-2] =~ $regex) {
    my ($opt_val, $opt_name) = (pop @$args_ref, pop @$args_ref);
    $options{$opt_name} = $opt_val;
  }
  return \%options;
}


#----------------------------------------------------------------------
# UPDATE
#----------------------------------------------------------------------

my $update_spec = {
  -set   => {type => HASHREF},
  -where => {type => HASHREF|ARRAYREF},
};



sub update {
  my $self = shift;

  # parse arguments
  @_ or croak "update() : not enough arguments";
  my $is_positional_args = ref $_[0] || $_[0] !~ /^-/;
  my %args;
  if ($is_positional_args) {
    reftype $_[-1] eq 'HASH'
      or croak "update(): expected a hashref as last argument";
    $args{-set} = pop @_;
    $args{-where} = [-key => @_] if @_;
  }
  else {
    %args = validate(@_, $update_spec);
  }

  my $to_set = {%{$args{-set}}}; # shallow copy
  $self->_maybe_inject_primary_key($to_set, \%args);

  my $meta_source  = $self->{meta_source};
  my $source_class = $meta_source->class;
  my $where        = $args{-where};

  # if this is an update of a single record ...
  if (!$where) {
    # bless it, so that we can call methods on it
    bless $to_set, $source_class;

    # apply column handlers (no_update, auto_update, 'to_DB')
    my %no_update_column = $meta_source->no_update_column;
    delete $to_set->{$_} foreach keys %no_update_column;
    my %auto_update_column = $meta_source->auto_update_column;
    while (my ($col, $handler) = each %auto_update_column) {
      $to_set->{$col} = $handler->($to_set, $source_class);
    }
    $to_set->apply_column_handler('to_DB');

    # remove references to foreign objects (including '__schema')
    delete $to_set->{__schema};
    my @sub_refs = grep {ref $to_set->{$_}} keys %$to_set;
    if (@sub_refs) {
      carp "data passed to update() contained nested references : ",
            CORE::join ", ", @sub_refs;
      delete $to_set->{@sub_refs};
      # TODO : recursive update (or insert)
    }

    # now unbless and remove the primary key
    damn $to_set;
    my @primary_key = $self->{meta_source}->primary_key;
    $where = {map {$_ => delete $to_set->{$_}} @primary_key};
  }

  else {
    # otherwise, it will be a bulk update, no handlers applied
  }

  # database request
  my $schema = $self->{schema};
  my @sqla_args = ($meta_source->db_from, $to_set, $where);
  my ($sql, @bind) = $schema->sql_abstract->update(@sqla_args);
  $schema->_debug($sql . " / " . CORE::join(", ", @bind) );
  my $method = $schema->dbi_prepare_method;
  my $sth    = $schema->dbh->$method($sql);
  $sth->execute(@bind);
}



#----------------------------------------------------------------------
# DELETE
#----------------------------------------------------------------------

my $delete_spec = {
  -where => {type => HASHREF|ARRAYREF},
};

sub delete {
  my $self = shift;

  # parse arguments
  @_ or croak "delete() : not enough arguments";
  my $is_positional_args = ref $_[0] || $_[0] !~ /^-/;
  my %args;
  my $to_delete = {};
  if ($is_positional_args) {
    if (reftype $_[0] eq 'HASH') { # @_ contains a hashref to delete
      @_ == 1 
        or croak "delete() : too many arguments";
      $to_delete = {%{$_[0]}}; # shallow copy
    }
    else {                         # @_ contains a primary key to delete
      $args{-where} = [-key => @_];
    }
  }
  else {
    %args = validate(@_, $delete_spec);
  }

  $self->_maybe_inject_primary_key($to_delete, \%args);

  my $meta_source  = $self->{meta_source};
  my $source_class = $meta_source->class;
  my $where        = $args{-where};

  # if this is a delete of a single record ...
  if (!$where) {
    # cascaded delete
    foreach my $component_name ($meta_source->components) {
      my $components = $to_delete->{$component_name} or next;
      ref $components eq 'ARRAY'
        or croak "delete() : component $component_name is not an arrayref";
      $_->delete foreach @$components;
    }
    # build $where from primary key
    $where = {map {$_ => $to_delete->{$_}} $self->{meta_source}->primary_key};
  }

  else {
    # otherwise, it will be a bulk delete, no handlers applied
  }

  # database request
  my $schema = $self->{schema};
  my @sqla_args = ($meta_source->db_from, $where);
  my ($sql, @bind) = $schema->sql_abstract->delete(@sqla_args);
  $schema->_debug($sql . " / " . CORE::join(", ", @bind) );
  my $method = $schema->dbi_prepare_method;
  my $sth    = $schema->dbh->$method($sql);
  $sth->execute(@bind);
}


#----------------------------------------------------------------------
# JOIN
#----------------------------------------------------------------------

sub join {
  my ($self, $first_role, @other_roles) = @_;

  # direct references to utility objects
  my $schema      = $self->schema;
  my $metadm      = $self->metadm;
  my $meta_schema = $schema->metadm;

  # find first join information
  my $class  = $metadm->class;
  my $path   = $metadm->path($first_role)
    or croak "could not find role $first_role in $class";

  # build search criteria on %$self from first join information
  my (%criteria, @left_cols);
  my $prefix;
  while (my ($left_col, $right_col) = each %{$path->{on}}) {
    $prefix ||= $schema->placeholder_prefix;
    $criteria{$right_col} = "$prefix$left_col";
    push @left_cols, $left_col;
  }

  # choose source (just a table or build a join) and then build a statement
  my $source = @other_roles  ? $meta_schema->define_join($path->{to}{name},
                                                         @other_roles)
                             : $path->{to};
  my @stmt_args = ($source, $schema, -where => \%criteria);

  # keep a reference to @left_cols so that Source::join can bind them
  push @stmt_args, -_left_cols => \@left_cols;

  # build and return the new statement
  my $statement = $meta_schema->statement_class->new(@stmt_args);
  return $statement;
}


#----------------------------------------------------------------------
# Utilities
#----------------------------------------------------------------------


sub _maybe_inject_primary_key {
  my ($self, $record, $args) = @_;

  # if primary key was supplied separately, inject it into the record
  my $where = $args->{-where};
  if (ref $where eq 'ARRAY' && $where->[0] eq '-key') {
    # got the primary key in the form -where => [-key => @pk_vals]
    my @pk_cols = $self->{meta_source}->primary_key;
    my @pk_vals = @{$where}[1 .. $#$where];
    @pk_cols == @pk_vals
      or croak sprintf "got %d cols in primary key, expected %d",
                        scalar(@pk_vals), scalar(@pk_cols);
    @{$record}{@pk_cols} = @pk_vals;
    delete $args->{-where};
  }
}


1;


