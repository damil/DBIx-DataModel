#----------------------------------------------------------------------
package DBIx::DataModel::Statement;
#----------------------------------------------------------------------
# see POD doc at end of file

use warnings;
use strict;
use Carp;
use List::Util       qw/min first/;
use List::MoreUtils  qw/firstval any/;
use Scalar::Util     qw/weaken refaddr reftype dualvar/;
use Storable         qw/dclone freeze/;
use Params::Validate qw/validate ARRAYREF HASHREF/;
use POSIX            qw/INT_MAX/;
use Acme::Damn       qw/damn/;
use namespace::autoclean;

{no strict 'refs'; *CARP_NOT = \@DBIx::DataModel::CARP_NOT;}

use overload

  # overload the stringification operator so that Devel::StackTrace is happy;
  # also useful to show the SQL (if in sqlized state)
  '""' => sub {
    my $self = shift;
    my $string = eval {my ($sql, @bind) = $self->sql;
                       __PACKAGE__ . "($sql // " . join(", ", @bind) . ")"; }
              || overload::StrVal($self);
  }
;


# sequence of states. Stored as dualvars for both ordering and printing
use constant {
  NEW      => dualvar(1, "new"     ),
  REFINED  => dualvar(2, "refined" ),
  SQLIZED  => dualvar(3, "sqlized" ),
  PREPARED => dualvar(4, "prepared"),
  EXECUTED => dualvar(5, "executed"),
};



#----------------------------------------------------------------------
# PUBLIC METHODS
#----------------------------------------------------------------------

sub new {
  my ($class, $meta_source, $schema, %other_args) = @_;

  # check $meta_source (must be an instance of a subclass of Meta::Source)
  $meta_source && $meta_source->isa('DBIx::DataModel::Meta::Source')
    or croak "invalid meta_source for DBIx::DataModel::Statement->new()";

  # check $schema
  $schema && ref($schema) && $schema->isa('DBIx::DataModel::Schema')
    or croak "invalid schema for DBIx::DataModel::Statement->new()";

  # build the object
  my $self = bless {
    status           => NEW,
    meta_source      => $meta_source,
    schema           => $schema,
    args             => {},
    pre_bound_params => {},
    bound_params     => [],
  }, $class;

  # add placeholder_regex
  my $prefix = $schema->{placeholder_prefix};
  $self->{placeholder_regex} = qr/^\Q$prefix\E(.+)/;

  # parse remaining args, if any
  $self->refine(%other_args) if %other_args;

  return $self;
}


# accessors
DBIx::DataModel::Meta::Utils->define_readonly_accessors(
  __PACKAGE__, qw/meta_source schema status/,
);

# additional accessor; here, 'metadm' is a synonym for 'meta_source'
sub metadm { 
  my $self = shift;
  return $self->{meta_source};
}





# don't remember why this "clone()" method was ever created.
# Keep the code  around for a while ...

# sub clone {
#   my ($self) = @_;
#   $self->{status} < PREPARED
#     or croak "can't clone() when in status $self->{status}";

#   return dclone($self); # THINK: should use Clone::clone instead?
# }


#----------------------------------------------------------------------
# PUBLIC METHODS IN RELATION WITH SELECT()
#----------------------------------------------------------------------


sub sql {
  my ($self) = @_;

  $self->{status} >= SQLIZED
    or croak "can't call sql() when in status $self->{status}";

  return wantarray ? ($self->{sql}, @{$self->{bound_params}})
                   : $self->{sql};
}


sub bind {
  my ($self, @args) = @_;

  # arguments can be a list, a hashref or an arrayref
  if (@args == 1) {
    for (reftype($args[0]) || "") {
      /^HASH$/  and do {@args = %{$args[0]}; last;};
      /^ARRAY$/ and do {my $i = 0; @args = map {($i++, $_)} @{$args[0]}; last};
      #otherwise
      croak "unexpected arg type to bind()";
    }
  }
  elsif (@args == 3) { # name => value, \%args (see L<DBI/bind_param>)
    my $indices = $self->{param_indices}{$args[0]};
    my $bind_param_args = pop @args;
    defined $indices or croak "no such named placeholder : $args[0]";
    $self->{bind_param_args}[$_] = $bind_param_args foreach @$indices;
  }
  elsif (@args % 2 == 1) {
    croak "odd number of args to bind()";
  }

  # do bind (different behaviour according to status)
  my %args = @args;
  if ($self->{status} < SQLIZED) {
    while (my ($k, $v) = each %args) {
      $self->{pre_bound_params}{$k} = $v;
    }
  }
  else {
    while (my ($k, $v) = each %args) {
      my $indices = $self->{param_indices}{$k} 
        or next; # silently ignore that binding (named placeholder unused)
      $self->{bound_params}[$_] = $v foreach @$indices;
    }
  }

  return $self;
}


sub refine {
  my ($self, %more_args) = @_;

  $self->{status} <= REFINED
    or croak "can't refine() when in status $self->{status}";
  $self->{status} = REFINED;

  my $args = $self->{args};

  while (my ($k, $v) = each %more_args) {

  SWITCH:
    for ($k) {

      # -where : combine with previous 'where' clauses in same statement
      /^-where$/ and do {
        my $sqla = $self->{schema}->sql_abstract;
        $args->{-where} = $sqla->merge_conditions($args->{-where}, $v);
        last SWITCH;
      };

      # -fetch : special select() on primary key
      /^-fetch$/ and do {
        # build a -where clause on primary key
        my $primary_key = ref($v) ? $v : [$v];
        my @pk_columns  = $self->{meta_source}->primary_key;
        @pk_columns
          or croak "fetch: no primary key in source $self->{meta_source}";
        @pk_columns == @$primary_key
          or croak sprintf "fetch from %s: primary key should have %d values",
                           $self->{meta_source}, scalar(@pk_columns);
        List::MoreUtils::all {defined $_} @$primary_key
          or croak "fetch from $self->{meta_source}: "
                 . "undefined val in primary key";

        my %where = ();
        @where{@pk_columns} = @$primary_key;
        my $sqla = $self->{schema}->sql_abstract;
        $args->{-where} = $sqla->merge_conditions($args->{-where}, \%where);

        # want a single record as result
        $args->{-result_as} = "firstrow";

        last SWITCH;
      };

      # -columns : store in $self->{args}{-columns}; can restrict previous list
      /^-columns$/ and do {
        my @cols = ref $v ? @$v : ($v);
        if (my $old_cols = $args->{-columns}) {
          unless (@$old_cols == 1 && $old_cols->[0] eq '*' ) {
            foreach my $col (@cols) {
              any {$_ eq $col} @$old_cols
                or croak "can't restrict -columns on '$col' (was not in the) "
                       . "previous -columns list";
            }
          }
        }
        $args->{-columns} = \@cols;
        last SWITCH;
      };


      # other args are just stored, will be used later
      /^-( order_by  | group_by | having    | for
         | result_as | post_SQL | pre_exec  | post_exec  | post_bless
         | limit     | offset   | page_size | page_index | column_types
         | prepare_attrs        | dbi_prepare_method
         )$/x
         and do {$args->{$k} = $v; last SWITCH};

      # otherwise
      croak "invalid arg : $k";

    } # end SWITCH
  } # end while

  return $self;
}




sub sqlize {
  my ($self, @args) = @_;

  $self->{status} < SQLIZED
    or croak "can't sqlize() when in status $self->{status}";

  # merge new args into $self->{args}
  $self->refine(@args) if @args;

  # shortcuts
  my $args         = $self->{args};
  my $meta_source  = $self->{meta_source};
  my $source_where = $meta_source->{where};
  my $sql_abstract = $self->{schema}->sql_abstract;

  # build arguments for SQL::Abstract::More
  $self->refine(-where => $source_where) if $source_where;
  my @args_to_copy = qw/-columns -where -order_by -group_by -having
                        -limit -offset -page_size -page_index/;
  my %sqla_args = (-from         => $meta_source->db_from,
                   -want_details => 1);
  $args->{$_} and $sqla_args{$_} = $args->{$_} for @args_to_copy;
  $sqla_args{-columns} ||= $meta_source->default_columns;

  # "-for" (e.g. "update", "read only")
  if (($args->{-result_as}||"") ne 'subquery') {
    if ($args->{-for}) {
      $sqla_args{-for} = $args->{-for};
    }
    elsif (!exists $args->{-for}) {
      $sqla_args{-for} = $self->{schema}->select_implicitly_for;
    }
  }

  # generate SQL
  my $sqla_result = $sql_abstract->select(%sqla_args);

  # maybe post-process the SQL
  if ($args->{-post_SQL}) {
    ($sqla_result->{sql}, @{$sqla_result->{bind}})
      = $args->{-post_SQL}->($sqla_result->{sql}, @{$sqla_result->{bind}});
  }

  # keep $sql / @bind / aliases in $self, and set new status
  $self->{bound_params} = $sqla_result->{bind};
  $self->{$_} = $sqla_result->{$_} for qw/sql aliased_tables aliased_columns/;
  $self->{status}       = SQLIZED;

  # analyze placeholders, and replace by pre_bound params if applicable
  if (my $regex = $self->{placeholder_regex}) {
    for (my $i = 0; $i < @{$self->{bound_params}}; $i++) {
      $self->{bound_params}[$i] =~ $regex 
        and push @{$self->{param_indices}{$1}}, $i;
    }
  }
  $self->bind($self->{pre_bound_params}) if $self->{pre_bound_params};

  # compute callback to apply to data rows
  my $callback = $self->{args}{-post_bless};
  weaken(my $weak_self = $self);   # weaken to avoid a circular ref in closure
  $self->{row_callback} = sub {
    my $row = shift;
    $weak_self->bless_from_DB($row);
    $callback->($row) if $callback;
  };

  return $self;
}



sub prepare {
  my ($self, @args) = @_;

  my $meta_source = $self->{meta_source};

  $self->sqlize(@args) if @args or $self->{status} < SQLIZED;

  $self->{status} == SQLIZED
    or croak "can't prepare() when in status $self->{status}";

  # log the statement and bind values
  $self->schema->_debug("PREPARE $self->{sql} / @{$self->{bound_params}}");

  # call the database
  my $dbh          = $self->{schema}->dbh or croak "Schema has no dbh";
  my $method       = $self->{args}{-dbi_prepare_method}
                  || $self->{schema}->dbi_prepare_method;
  my @prepare_args = ($self->{sql});
  push @prepare_args, $self->{prepare_attrs} if $self->{prepare_attrs};
  $self->{sth}  = $dbh->$method(@prepare_args);

  # new status and return
  $self->{status} = PREPARED;
  return $self;
}



sub execute {
  my ($self, @bind_args) = @_;

  # if not prepared yet, prepare it
  $self->prepare              if $self->{status} < PREPARED;

  # TODO: DON'T REMEMBER why the line below was here. Keep it around for a while ...
  push @bind_args, offset => $self->{offset}  if $self->{offset};

  $self->bind(@bind_args)      if @bind_args;

  # shortcuts
  my $args = $self->{args};
  my $sth  = $self->{sth};

  # previous row_count, row_num and reuse_row are no longer valid
  delete $self->{reuse_row};
  delete $self->{row_count};
  $self->{row_num} = $self->offset;

  # pre_exec callback
  $args->{-pre_exec}->($sth)   if $args->{-pre_exec};

  # check that all placeholders were properly bound to values
  my @unbound;
  while (my ($k, $indices) = each %{$self->{param_indices} || {}}) {
    exists $self->{bound_params}[$indices->[0]] or push @unbound, $k;
  }
  not @unbound 
    or croak "unbound placeholders (probably a missing foreign key) : "
            . CORE::join(", ", @unbound);

  # bind parameters and execute
  if ($self->{bind_param_args}) { # need to bind one by one because of DBI args
    my $n_bound_params = @{$self->{bound_params}};
    for my $i (0 .. $n_bound_params-1) {
      my @bind = ($i, $self->{bound_params}[$i]);
      my $bind_args = $self->{bind_param_args}[$i];
      push @bind, $bind_args   if $bind_args;
      $sth->bind_param(@bind);
    }
    $sth->execute;
  }
  else {                          # otherwise just call DBI::execute(...)
    $sth->execute(@{$self->{bound_params}});
  }

  # post_exec callback
  $args->{-post_exec}->($sth)  if $args->{-post_exec};

  $self->{status} = EXECUTED;
  return $self;
}


sub select {
  my $self = shift;

  $self->refine(@_) if @_;

  my $args = $self->{args}; # all combined args

  my $callbacks = CORE::join ", ", grep {exists $args->{$_}} 
                                        qw/-pre_exec -post_exec -post_bless/;

 SWITCH:
  my ($result_as, @key_cols) 
    = ref $args->{-result_as} ? @{$args->{-result_as}}
                              : ($args->{-result_as} || "rows");
  for ($result_as) {

    # CASE statement : the DBIx::DataModel::Statement object 
    /^statement$/i and do {
        delete $self->{args}{-result_as};
        return $self;
      };

    # for all other cases, must first sqlize the statement
    $self->sqlize if $self->{status} < SQLIZED;

    # CASE sql : just return the SQL and bind values
    /^sql$/i        and do {
      not $callbacks 
        or croak "$callbacks incompatible with -result_as=>'sql'";
      return $self->sql;
    };

    # CASE subquery : return a ref to an arrayref with SQL and bind values
    /^subquery$/i        and do {
      not $callbacks 
        or croak "$callbacks incompatible with -result_as=>'subquery'";
      my ($sql, @bind) = $self->sql;
      return \ ["($sql)", @bind];
    };

    # for all other cases, must first execute the statement
    $self->execute;

    # CASE sth : return the DBI statement handle
    /^sth$/i        and do {
        not $args->{-post_bless}
          or croak "-post_bless incompatible with -result_as=>'sth'";
        return $self->{sth};
      };

    # CASE rows : all data rows (this is the default)
    /^(rows|arrayref)$/i       and return $self->all;

    # CASE firstrow : just the first row
    /^firstrow$/i   and return $self->next;

    # CASE hashref : all data rows, put into a hashref
    /^hashref$/i   and do {
      @key_cols or @key_cols = $self->{meta_source}->primary_key
        or croak "-result_as=>'hashref' impossible: no primary key";
      my %hash;
      while (my $row = $self->next) {
        my @key;
        foreach my $col (@key_cols) {
          my $val = $row->{$col};
          $val = '' if not defined $val; # $val might be 0, so no '||'
          push @key, $val;
        }
        my $last_key_item = pop @key;
        my $node          = \%hash;
        $node = $node->{$_} ||= {} foreach @key;
        $node->{$last_key_item} = $row;
      }
      return \%hash;
    };

    # CASE fast_statement : creates a reusable row
    /^fast[-_]statement$/i and do {
        $self->_build_reuse_row;
        return $self;
      };

    # CASE flat_arrayref : flattened columns from each row
    /^flat(?:_array(?:ref)?)?$/ and do {
      $self->_build_reuse_row;
      my @vals;
      my $hash_key_name = $self->{sth}{FetchHashKeyName} || 'NAME';
      my $cols = $self->{sth}{$hash_key_name};
      while (my $row = $self->next) {
        push @vals, @{$row}{@$cols};
      }
      return \@vals;
    };


    # OTHERWISE
    croak "unknown -result_as value: $_"; 
  }
}


sub fetch {
  my $self = shift;
  my %select_args;

  # if last argument is a hashref, it contains arguments to the select() call
  no warnings 'uninitialized';
  if (reftype $_[-1] eq 'HASH') {
    %select_args = %{pop @_};
  }

  return $self->select(-fetch => \@_, %select_args);
}


sub fetch_cached {
  my $self = shift;
  my $dbh_addr    = refaddr $self->schema->dbh;
  my $freeze_args = freeze \@_;
  return $self->{meta_source}{fetch_cached}{$dbh_addr}{$freeze_args}
           ||= $self->fetch(@_);
}





sub row_count {
  my ($self) = @_;

  if (! exists $self->{row_count}) {
    $self->sqlize if $self->{status} < SQLIZED;
    my ($sql, @bind) = $self->sql;
    $sql =~ s[^SELECT\b.*?\bFROM\b][SELECT COUNT(*) FROM]i
      or croak "can't count rows from sql: $sql";

    # TODO : line below is NOT PORTABLE. Should accomodate for all
    # limit-offset syntaxes !!!
    $sql =~ s[\bLIMIT \? OFFSET \?][]i
      and splice @bind, -2;

    my $dbh    = $self->{schema}->dbh or croak "Schema has no dbh";
    my $method = $self->{schema}->dbi_prepare_method;
    my $sth    = $dbh->$method($sql);
    $sth->execute(@bind);
    ($self->{row_count}) = $sth->fetchrow_array;
  }

  return $self->{row_count};
}


sub row_num {
  my ($self) = @_;
  return $self->{row_num};
}

sub next {
  my ($self, $n_rows) = @_;

  $self->execute if $self->{status} < EXECUTED;

  my $sth      = $self->{sth}          or croak "absent sth in statement";
  my $callback = $self->{row_callback} or croak "absent callback in statement";

  if (not defined $n_rows) {  # if user wants a single row
    # fetch a single record, either into the reusable row, or into a fresh hash
    my $row = $self->{reuse_row} ? ($sth->fetch ? $self->{reuse_row} : undef)
                                 : $sth->fetchrow_hashref;
    if ($row) {
      $callback->($row);
      $self->{row_num} +=1;
    }
    return $row;
  }
  else {              # if user wants an arrayref of size $n_rows
    $n_rows > 0            or croak "->next() : invalid argument, $n_rows";
    not $self->{reuse_row} or croak "reusable row, cannot retrieve several";
    my @rows;
    while ($n_rows--) {
      my $row = $sth->fetchrow_hashref or last;
      push @rows, $row;
    }
    $callback->($_) foreach @rows;
    $self->{row_num} += @rows;
    return \@rows;
  }
}

sub all {
  my ($self) = @_;

  $self->execute if $self->{status} < EXECUTED;

  my $sth      = $self->{sth}          or croak "absent sth in statement";
  my $callback = $self->{row_callback} or croak "absent callback in statement";

  not $self->{reuse_row}  or croak "reusable row, cannot retrieve several";
  my $rows = $sth->fetchall_arrayref({});
  $callback->($_) foreach @$rows;
  $self->{row_num} += @$rows;

  return $rows;
}


sub page_size   { shift->{args}{-page_size}  || POSIX::INT_MAX   }
sub page_index  { shift->{args}{-page_index} || 1                }
sub offset      { shift->{offset}            || 0                }


sub page_count {
  my ($self) = @_;

  my $row_count = $self->row_count or return 0;
  my $page_size = $self->page_size || 1;

  return int(($row_count - 1) / $page_size) + 1;
}

sub goto_page {
  my ($self, $page_index) = @_;

  # if negative index, count down from last page
  $page_index += $self->page_count + 1    if $page_index < 0;

  $page_index >= 1 or croak "illegal page_index: $page_index";

  $self->{page_index} = $page_index;
  $self->{offset}     = ($page_index - 1) * $self->page_size;
  $self->execute     unless $self->{row_num} == $self->{offset};

  return $self;
}


sub shift_pages {
  my ($self, $delta) = @_;

  my $page_index = $self->page_index + $delta;
  $page_index >= 1 or croak "illegal page index: $page_index";

  $self->goto_page($page_index);
}

sub next_page {
  my ($self) = @_;

  $self->shift_pages(1);
}


sub page_boundaries {
  my ($self) = @_;

  my $first = $self->offset + 1;
  my $last  = min($self->row_count, $first + $self->page_size - 1);
  return ($first, $last);
}


sub page_rows {
  my ($self) = @_;
  return $self->next($self->page_size);
}


sub bless_from_DB {
  my ($self, $row) = @_;

  # inject ref to $schema if in multi-schema mode
  $row->{__schema} = $self->{schema} unless $self->{schema}{is_singleton};

  # bless into appropriate class
  bless $row, $self->{meta_source}->class;
  # apply handlers
  $self->{from_DB_handlers} or $self->_compute_from_DB_handlers;
  while (my ($column_name, $handler) 
           = each %{$self->{from_DB_handlers}}) {
    exists $row->{$column_name}
      and $handler->($row->{$column_name}, $row, $column_name, 'from_DB');
  }

  return $row;
}


#----------------------------------------------------------------------
# PRIVATE METHODS IN RELATION WITH SELECT()
#----------------------------------------------------------------------

sub _build_reuse_row {
  my ($self) = @_;

  $self->{status} == EXECUTED
    or croak "cannot _build_reuse_row() when in state $self->{status}";

  # create a reusable hash and bind_columns to it (see L<DBI/bind_columns>)
  my %row;
  my $hash_key_name = $self->{sth}{FetchHashKeyName} || 'NAME';
  $self->{sth}->bind_columns(\(@row{@{$self->{sth}{$hash_key_name}}}));
  $self->{reuse_row} = \%row; 
}



sub _compute_from_DB_handlers {
  my ($self) = @_;
  my $meta_source    = $self->{meta_source};
  my $meta_schema    = $self->{schema}->metadm;
  my %handlers       = $meta_source->_consolidate_hash('column_handlers');
  my %aliased_tables = $meta_source->aliased_tables;

  # iterate over aliased_columns
  while (my ($alias, $column) = each %{$self->{aliased_columns} || {}}) {
    my $table_name;
    $column =~ s/^(.+)\.// and $table_name = $1;
    if (!$table_name) {
      $handlers{$alias} = $handlers{$column};
    }
    else {
      $table_name = $aliased_tables{$table_name} || $table_name;

      my $table   = $meta_schema->table($table_name)
                 || firstval {($_->{db_name} || '') eq $table_name}
                             ($meta_source, $meta_source->ancestors)
                 # THINK: might perform a case-insensitive search 
                 # (as second pass)
        or croak "unknown table name: $table_name";

      $handlers{$alias} = $table->{column_handlers}->{$column};
    }
  }

  # handlers may be overridden from args{-column_types}
  # TODO: TEST TEST TEST
  if (my $col_types = $self->{args}{-column_types}) {
    while (my ($type_name, $columns) = each %$col_types) {
      ref $columns or $columns = [$columns];
      my $type = $self->{schema}->metadm->type($type_name)
        or croak "no such column type: $type_name";
      $handlers{$_} = $type->{handlers} foreach @$columns;
    }
  }

  # just keep the "from_DB" handlers
  my $from_DB_handlers = {};
  while (my ($column, $col_handlers) = each %handlers) {
    my $from_DB_handler = $col_handlers->{from_DB} or next;
    $from_DB_handlers->{$column} = $from_DB_handler;
  }
  $self->{from_DB_handlers} = $from_DB_handlers;

  return $self;
}



#----------------------------------------------------------------------
# INSERT
#----------------------------------------------------------------------


# TODO : refactor to be consistent with select() : statement status,
# steps prepare/execute, etc. Right now this is just a direct transposition
# from code formerly in Source/Table.pm.


sub insert {
  my $self = shift;

  # check status
  $self->{status} == NEW
    or croak "can't insert() when in status $self->{status}";

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

  # some checks
  $self->{status} == NEW
    or croak "can't update() when in status $self->{status}";
  @_ or croak "update() : not enough arguments";

  # parse arguments
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

  # some checks
  $self->{status} == NEW
    or croak "can't delete() when in status $self->{status}";
  @_ or croak "select() : not enough arguments";

  # parse arguments
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
      my $components = $self->{$component_name} or next;
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

  $self->{status} == NEW
    or croak "can't call sql() when in status $self->{status}";

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
  my $statement = $meta_schema->statement_class->new($source, $schema);
  $statement->refine(-where => \%criteria);

  # keep a reference to @left_cols so that Source::join can bind them
  $statement->{left_cols} = \@left_cols;

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



1; # End of DBIx::DataModel::Statement

__END__

=head1 NAME

DBIx::DataModel::Statement - DBIx::DataModel statement objects

=head1 DESCRIPTION

The purpose of a I<statement> object is to retrieve rows from the
database and bless them as objects of appropriate classes.

Internally the statement builds and then encapsulates a C<DBI>
statement handle (sth).

The design principles for statements are described in the
L<DESIGN|DBIx::DataModel::Doc::Design/"STATEMENT OBJECTS"> section of
the manual (purpose, lifecycle, etc.).

=head1 METHODS

=head2 new

  my $statement 
    = DBIx::DataModel::Statement->new($meta_source, $schema, %options);

This is the statement constructor; C<$meta_source> is an
instance of L<DBIx::DataModel::Meta::Source> (either
a meta-table or a meta-join), and C<schema> is an instance
of L<DBIx::DataModel::Schema>. If present, C<%options> are delegated
to the L<refine()|DBIx::DataModel::Doc::Reference/refine()> method.

Explicit calls to the statement constructor are exceptional;
the usual way to create a statement is through a schema's 
L<table()|DBIx::DataModel::Doc::Reference/Schema::table()>
or 
L<join()|DBIx::DataModel::Doc::Reference/Schema::join()>
method.




=head1 PRIVATE METHOD NAMES

The following methods or functions are used
internally by this module and 
should be considered as reserved names, not to be
redefined in subclasses :

=over

=item _bless_from_DB

=item _compute_from_DB_handlers

=back


