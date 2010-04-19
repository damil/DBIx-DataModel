#----------------------------------------------------------------------
package DBIx::DataModel::Statement;
#----------------------------------------------------------------------
# see POD doc at end of file

use warnings;
use strict;
use Carp;
use List::Util      qw/min first/;
use Scalar::Util    qw/weaken/;
use UNIVERSAL       qw/isa/;
use Storable        qw/dclone/;
use POSIX           qw/INT_MAX/;

use overload

  # overload the coderef operator ->() for backwards compatibility
  # with previous "selectFromRoles" method. 
  '&{}' => sub {
    my $self = shift;
    carp "selectFromRoles is deprecated; use ->join(..)->select(..)";
    return sub {$self->select(@_)};
  },

  # overload the stringification operator so that Devel::StackTrace is happy;
  # also useful to show the SQL (if in sqlized state)
  '""' => sub {
    my $self = shift;
    my $string = eval {my ($sql, @bind) = $self->sql;
                       __PACKAGE__ . "($sql // " . join(", ", @bind) . ")"; }
      || overload::StrVal($self);
  }
;


our @CARP_NOT = qw/DBIx::DataModel::Schema DBIx::DataModel::Source
		   DBIx::DataModel::Table  DBIx::DataModel::View   /;


#----------------------------------------------------------------------
# PUBLIC METHODS
#----------------------------------------------------------------------

sub new {
  my ($class, $source, @args) = @_;

  # $source must be a subclass of Table or View 
  $source && !ref($source) && $source->isa('DBIx::DataModel::Source')
    or croak "invalid source for DBIx::DataModel::Statement->new()";

  # build the object
  my $self = bless {
    status           => "new",
    source           => $source,
    args             => {-where => $source->classData->{where}},
    pre_bound_params => {},
  }, $class;

  # add placeholderRegex
  my $prefix = $source->schema->classData->{placeholderPrefix};
  if ($prefix) {
    $self->{placeholderRegex} = qr/^\Q$prefix\E(.+)/;
  }

  $self->refine(@args) if @args;

  return $self;
}


sub clone {
  my ($self) = @_;
  $self->{status} eq "new" or $self->{status} eq "sqlized"
    or croak "can't clone() when in status $self->{status}";

  return dclone($self);
}

sub status {
  my ($self) = @_;
  return $self->{status};
}


sub sql {
  my ($self) = @_;

  $self->{status} ne "new"
    or croak "can't call sql() when in status $self->{status}";

  return wantarray ? ($self->{sql}, @{$self->{bound_params} || []})
                   : $self->{sql};
}


sub bind {
  my ($self, @args) = @_;

  # arguments can be a list, a hashref or an arrayref
  if (@args == 1) {
    if    (isa $args[0], 'HASH')  {@args = %{$args[0]}}
    elsif (isa $args[0], 'ARRAY') {my $i = 0;
                                   @args = map {($i++, $_)} @{$args[0]}}
    else                          {croak "unexpected arg type to bind()"}
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
  if ($self->{status} eq "new") {
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

  $self->{status} eq "new"
    or croak "can't refine() when in status $self->{status}";

  my $args = $self->{args};

  while (my ($k, $v) = each %more_args) {

  SWITCH:
    for ($k) {
      /^-where$/ and do {$self->_add_conditions($v); last SWITCH};
      /^-fetch$/ and do {
        # build a -where clause on primary key
        my $primKey    = ref($v) ? $v : [$v];
        my @pk_columns = $self->{source}->primKey;
        @pk_columns == @$primKey
          or croak sprintf "fetch from %s: primary key should have %d values",
                           $self->{source}, scalar(@pk_columns);
        my %where = ();
        @where{@pk_columns} = @$primKey;
        $self->_add_conditions(\%where);

        # want a single record as result
        $args->{-resultAs} = "firstrow";

        last SWITCH;
      };
      /^(-distinct | -columns | -orderBy  | -groupBy   | -having | -for
       | -resultAs | -postSQL | -preExec  | -postExec  | -postFetch
       | -limit    | -offset  | -pageSize | -pageIndex | -columnTypes  )$/x
         and do {$args->{$k} = $v; last SWITCH};
      # otherwise
      croak "invalid arg : $k";
    } # end SWITCH
  } # end while

  return $self;
}




sub sqlize {
  my ($self, @args) = @_;

  $self->{status} eq "new"
    or croak "can't sqlize() when in status $self->{status}";

  # merge new args into $self->{args}
  $self->refine(@args) if @args;

  # some parameter analysis and/or rewriting
  $self->_reorganize_columns;
  $self->_reorganize_pagination;
  $self->_compute_fromDB_handlers;

  # shortcuts
  my $args         = $self->{args};
  my $source       = $self->{source};
  my $sql_abstract = $source->schema->classData->{sqlAbstr};
  my $sql_dialect  = $source->schema->classData->{sqlDialect};

  # compute "-groupBy" and "-having"
  my $groupBy = ref($args->{-groupBy}) ? join(", ", @{$args->{-groupBy}})
                                       : $args->{-groupBy};
  my ($having, @bind_having) = $sql_abstract->where($args->{-having});
  $having =~ s[\bWHERE\b][HAVING];

  # "-for" (e.g. "update", "read only")
  if (!exists($args->{-for}) && ($args->{-resultAs}||"") ne 'subquery') {
    $args->{-for} = $source->selectImplicitlyFor;
  }

  # translate +/- prefixes to -orderBy args into SQL ASC/DESC
  my $orderBy = $args->{-orderBy} || [];
  ref $orderBy or $orderBy = [$orderBy];
  my %direction = ('+' => 'ASC', '-' => 'DESC');
  s/^([-+])(.*)/$2 $direction{$1}/ foreach @$orderBy;

  # generate SQL and add final clauses (GROUP BY, HAVING, FOR)
  my ($sql, @bind) = $sql_abstract->select($source->db_table,
                                           $args->{-columns},
                                           $args->{-where},
                                           $orderBy);
  $sql =~ s[^SELECT ][SELECT DISTINCT ]i             if $args->{-distinct};
  $sql =~ s[ORDER BY|$][ GROUP BY $groupBy $&]i      if $groupBy;
  $sql =~ s[ORDER BY|$][ $having $&]i
    and push @bind, @bind_having                     if $having;
  $self->_limit_offset($sql_dialect->{limitOffset},
                       \$sql, \@bind)                if $args->{-limit};
  $sql .= " FOR $args->{-for}"                       if $args->{-for};

  # maybe post-process the SQL
  ($sql, @bind) = $args->{-postSQL}->($sql, @bind) if $args->{-postSQL};

  # keep $sql / @bind in $self, and set new status
  $self->{sql}          = $sql;
  $self->{bound_params} = \@bind;
  $self->{status}       = "sqlized";

  # analyze placeholders, and replace by pre_bound params if applicable
  if (my $regex = $self->{placeholderRegex}) {
    for (my $i = 0; $i < @bind; $i++) {
      $bind[$i] =~ $regex and push @{$self->{param_indices}{$1}}, $i;
    }
  }
  $self->bind($self->{pre_bound_params}) if $self->{pre_bound_params};

  # compute callback to apply to data rows
  my $callback = $self->{args}{-postFetch};
  weaken(my $weak_self = $self);   # weaken to avoid a circular ref in closure
  $self->{row_callback} 
    = $callback ? sub {$weak_self->_blessFromDB($_[0]);
                       $callback->($_[0])               }
                : sub {$weak_self->_blessFromDB($_[0]); };
  return $self;
}





sub prepare {
  my ($self, @args) = @_;

  my $source = $self->{source};

  $self->sqlize(@args) if @args or $self->{status} eq "new";

  $self->{status} eq "sqlized"
    or croak "can't prepare() when in status $self->{status}";

  # log the statement and bind values
  $source->_debug("PREPARE $self->{sql} / @{$self->{bound_params}}");

  # call the database
  my $dbh    = $source->schema->dbh or croak "Schema has no dbh";
  my $method = $source->schema->dbiPrepareMethod;
  $self->{sth} = $dbh->$method($self->{sql});

  # keep lasth if required to
  my $schema_data = $source->schema->classData;
  $schema_data->{lasth} = $self->{sth}    if $schema_data->{keepLasth};

  # new status and return
  $self->{status} = "prepared";
  return $self;
}



sub execute {
  my ($self, @bind_args) = @_;

  # if not prepared yet, prepare it
  $self->prepare          if $self->{status} eq 'new'
                          or $self->{status} eq 'sqlized';

  push @bind_args, offset => $self->{offset}  if $self->{offset};

  $self->bind(@bind_args)                     if @bind_args;

  # shortcuts
  my $args = $self->{args};
  my $sth  = $self->{sth};

  # previous rowCount, rowNum and reuseRow are no longer valid
  delete $self->{reuseRow};
  delete $self->{rowCount};
  $self->{rowNum} = $self->offset;


  # preExec callback
  $args->{-preExec}->($sth)                if $args->{-preExec};

  # check that all placeholders were properly bound to values
  my @unbound;
  while (my ($k, $indices) = each %{$self->{param_indices} || {}}) {
    exists $self->{bound_params}[$indices->[0]] or push @unbound, $k;
  }
  not @unbound 
    or croak "unbound placeholders (probably a missing foreign key) : "
            . join(", ", @unbound);

  # bind parameters and execute
  if ($self->{bind_param_args}) { # need to bind one by one because of DBI args
    my $n_bound_params = @{$self->{bound_params}};
    for my $i (0 .. $n_bound_params-1) {
      my @bind = ($i, $self->{bound_params}[$i]);
      my $bind_args = $self->{bind_param_args}[$i];
      push @bind, $bind_args               if $bind_args;
      $sth->bind_param(@bind);
    }
    $sth->execute;
  }
  else {                          # otherwise just call DBI::execute(...)
    $sth->execute(@{$self->{bound_params}});
  }

  # postExec callback
  $args->{-postExec}->($sth)               if $args->{-postExec};

  $self->{status} = 'executed';
  return $self;
}



sub select {
  my $self = shift;

  # parse named or positional arguments
  my %more_args;
  if ($_[0] and not ref($_[0]) and $_[0] =~ /^-/) { # called with named args
    %more_args = @_;
  }
  else { # we were called with unnamed args (all optional!), so we try
         # to guess which is which from their datatypes.
    $more_args{-columns} = shift unless !@_ or isa $_[0], 'HASH' ;
    $more_args{-where}   = shift unless !@_ or isa $_[0], 'ARRAY';
    $more_args{-orderBy} = shift unless !@_ or isa $_[0], 'HASH' ;
    croak "too many args for select()" if @_;
  }

  $self->refine(%more_args)   if keys %more_args;
  $self->sqlize               if $self->{status} eq "new";

  my $args = $self->{args}; # all combined args

  my $callbacks = join ", ", grep {exists $args->{$_}} 
                                  qw/-preExec -postExec -postFetch/;

 SWITCH:
  my ($resultAs, @key_cols) 
    = ref $args->{-resultAs} ? @{$args->{-resultAs}}
                             : ($args->{-resultAs} || "rows");
  for ($resultAs) {

    # CASE sql : just return the SQL and bind values
    /^sql$/i        and do {
      not $callbacks 
        or croak "$callbacks incompatible with -resultAs=>'sql'";
      return $self->sql;
    };

    # CASE subquery : return a ref to an arrayref with SQL and bind values
    /^subquery$/i        and do {
      not $callbacks 
        or croak "$callbacks incompatible with -resultAs=>'subquery'";
      my ($sql, @bind) = $self->sql;
      return \ ["($sql)", @bind];
    };

    # for all other cases, must first execute the statement
    $self->execute;

    # CASE sth : return the DBI statement handle
    /^sth$/i        and do {
        not $args->{-postFetch}
          or croak "-postFetch incompatible with -resultAs=>'sth'";
        return $self->{sth};
      };

    # CASE statement : the DBIx::DataModel::Statement object 
    /^(fast[-_ ]?)?(statement|cursor|iter(ator)?)$/i and do {
        $self->reuseRow if $1; # if "fast"
        return $self;
      };

    # CASE rows : all data rows (this is the default)
    /^(rows|arrayref)$/i       and return $self->all;

    # CASE firstrow : just the first row
    /^firstrow$/i   and return $self->next;

    # CASE hashref : all data rows, put into a hashref
    /^hashref$/i   and do {
      @key_cols or @key_cols = $self->{source}->primKey;
      my %hash;
      while (my $row = $self->next) {
        my @key           = @{$row}{@key_cols};
        my $last_key_item = pop @key;
        my $node          = \%hash;
        $node = $node->{$_} ||= {} foreach @key;
        $node->{$last_key_item} = $row;
      }
      return \%hash;
    };

    # CASE flat_arrayref : flattened columns from each row
    /^flat(?:_array(?:ref)?)?$/ and do {
      $self->reuseRow;
      my @cols;
      while (my $row = $self->next) {
        push @cols, values %$row;
      }
      return \@cols;
    };


    # OTHERWISE
    croak "unknown -resultAs value: $_"; 
  }
}


sub reuseRow {
  my ($self) = @_;

  $self->{status} eq 'executed'
    or croak "cannot reuseRow() when in state $self->{status}";

  # create a reusable hash and bind_columns to it (see L<DBI/bind_columns>)
  my %row;
  $self->{sth}->bind_columns(\(@row{@{$self->{sth}{NAME}}}));
  $self->{reuseRow} = \%row; 
}



sub rowCount {
  my ($self) = @_;
  $self->{status} eq 'executed'
    or croak "cannot count rows when in state $self->{status}";

  if (! exists $self->{rowCount}) {
    my ($sql, @bind) = $self->sql;
    $sql =~ s[^SELECT\b.*?\bFROM\b][SELECT COUNT(*) FROM]i
      or croak "can't count rows from sql: $sql";
    $sql =~ s[\bLIMIT \? OFFSET \?][]i
      and splice @bind, -2;
    my $schema = $self->{source}->schema;
    my $dbh    = $schema->dbh or croak "Schema has no dbh";
    my $method = $schema->dbiPrepareMethod;
    my $sth    = $dbh->$method($sql);
    $sth->execute(@bind);
    ($self->{rowCount}) = $sth->fetchrow_array;
  }

  return $self->{rowCount};
}


sub rowNum {
  my ($self) = @_;
  return $self->{rowNum};
}

sub next {
  my ($self, $n_rows) = @_;

  $self->{status} eq "executed"
    or croak "can't call next() when in status $self->{status}";

  my $sth      = $self->{sth}          or croak "absent sth in statement";
  my $callback = $self->{row_callback} or croak "absent callback in statement";

  if (not defined $n_rows) {  # if user wants a single row
    # fetch a single record, either into the reusable row, or into a fresh hash
    my $row = $self->{reuseRow} ? ($sth->fetch ? $self->{reuseRow} : undef)
                                : $sth->fetchrow_hashref;
    if ($row) {
      $callback->($row);
      $self->{rowNum} +=1;
    }
    return $row;
  }
  else {              # if user wants an arrayref of size $n_rows
    $n_rows > 0            or croak "->next() : invalid argument, $n_rows";
    not $self->{reuseRow}  or croak "reusable row, cannot retrieve several";
    my @rows;
    while ($n_rows--) {
      my $row = $sth->fetchrow_hashref or last;
      push @rows, $row;
    }
    $callback->($_) foreach @rows;
    $self->{rowNum} += @rows;
    return \@rows;
  }
}



sub all {
  my ($self) = @_;

  $self->{status} eq "executed"
    or croak "can't call all() when in status $self->{status}";

  my $sth      = $self->{sth}          or croak "absent sth in statement";
  my $callback = $self->{row_callback} or croak "absent callback in statement";

  not $self->{reuseRow}  or croak "reusable row, cannot retrieve several";
  my $rows = $sth->fetchall_arrayref({});
  $callback->($_) foreach @$rows;
  $self->{rowNum} += @$rows;
  return $rows;
}


sub pageSize   { shift->{args}{-pageSize}  || POSIX::INT_MAX   }
sub pageIndex  { shift->{args}{-pageIndex} || 1                }
sub offset     { shift->{offset}           || 0                }


sub pageCount {
  my ($self) = @_;

  my $rowCount = $self->rowCount or return 0;
  my $pageSize = $self->pageSize || 1;

  return int(($rowCount - 1) / $pageSize) + 1;
}

sub gotoPage {
  my ($self, $pageIndex) = @_;

  # if negative index, count down from last page
  $pageIndex += $self->pageCount + 1    if $pageIndex < 0;

  $pageIndex >= 1 or croak "illegal pageIndex: $pageIndex";

  $self->{pageIndex} = $pageIndex;
  $self->{offset}    = ($pageIndex - 1) * $self->pageSize;
  $self->execute     unless $self->{rowNum} == $self->{offset};

  return $self;
}


sub shiftPages {
  my ($self, $delta) = @_;

  my $pageIndex = $self->pageIndex + $delta;
  $pageIndex >= 1 or croak "illegal page index: $pageIndex";

  $self->gotoPage($pageIndex);
}

sub nextPage {
  my ($self) = @_;

  $self->shiftPages(1);
}


sub pageBoundaries {
  my ($self) = @_;

  my $first = $self->offset + 1;
  my $last  = min($self->rowCount, $first + $self->pageSize - 1);
  return ($first, $last);
}


sub pageRows {
  my ($self) = @_;
  return $self->next($self->pageSize);
}



#----------------------------------------------------------------------
# PRIVATE METHODS
#----------------------------------------------------------------------

sub _blessFromDB {
  my ($self, $row) = @_;
  bless $row, $self->{source};
  while (my ($column, $handler) = each %{$self->{fromDBHandlers} || {}}) {
    $handler->($row->{$column}, $row, $column, 'fromDB');
  }
  return $row;
}


sub _compute_fromDB_handlers {
  my ($self) = @_;
  my $source = $self->{source};

  my %handlers;  # {columnName => {handlers} }

  # get handlers from parent classes
  if ($source->isa('DBIx::DataModel::View')) { 
    # if View : merge handlers from all parent tables
    foreach my $table (@{$source->classData->{parentTables}}) {
      my $table_handlers = $table->classData->{columnHandlers} || {};
      $handlers{$_} = $table_handlers->{$_} foreach keys %$table_handlers;
    }
  }
  else { 
    # if Table: copy from class
    %handlers = %{$source->classData->{columnHandlers} || {}};
  }

  # iterate over aliasedColumns ({alias => {source => Source, column => ..}})
  while (my ($alias, $aliased) = each %{$self->{aliasedColumns} || {}}) {
    my $col_source = $aliased->{source};
    if (!$col_source) {
      $handlers{$alias} = $handlers{$aliased->{column}};
    }
    else {
      $handlers{$alias} = $col_source->classData->{columnHandlers}
                                                  {$aliased->{column}};
    }
  }

  # handlers may be overridden from args{-columnTypes}
  if (my $colTypes = $self->{args}{-columnTypes}) {
    while (my ($type, $columns) = each %$colTypes) {
      ref $columns or $columns = [$columns];
      my $type_handlers = $source->schema->classData->{columnHandlers}{$type}
        or croak "no such column type: $type";
      $handlers{$_} = $type_handlers foreach @$columns;
    }
  }

  # just keep the "fromDB" handlers
  while (my ($column, $handlers) = each %handlers) {
    my $fromDBHandler = $handlers->{fromDB} or next;
    $self->{fromDBHandlers}{$column} = $fromDBHandler;
  }

  return $self;
}



sub _reorganize_columns {
  my ($self) = @_;
  my $source     = $self->{source};
  my $args       = $self->{args};

  # translate "-distinct" into "-columns"
  if ($args->{-distinct}) {
    not exists($args->{-columns}) or 
      croak "cannot specify both -distinct and -columns";
    $args->{-columns} = $args->{-distinct};
  }

  # default (usually '*')
  $args->{-columns} ||= $source->classData->{columns}; 

  # private array; clone because we will apply some changes
  my @cols = ref $args->{-columns} ? @{$args->{-columns}} : $args->{-columns};

  # expand column aliases, e.g. "table.column_name|alias"
  my $alias_syntax = $source->schema->classData->{sqlDialect}{columnAlias};
  foreach my $col (@cols) {
    my ($orig, $colsource, $colname, $alias) 
      = ($col =~ /^(               # $1: colsource.colname
                    (?:(\w+?)\.)?  # $2: optional colsource
                    ([^|]+)        # $3: colname
                   )               #     end of $1
                   (?:\|(.+))?     # $4: optional alias
                   $               #     end of string
                 /x)
        or croak "invalid column: $col";

    # remember aliased columns in statement (for applying fromDBHandlers)
    if ($alias || $colsource) {
      my $info = {column => $colname};
      $info->{source} 
        = $self->_resolve_source($source, $colsource, $col) if $colsource;
      $self->{aliasedColumns}{$alias || $colname} = $info;
    }

    # replace "|" alias syntax by regular SQL
    $col = sprintf $alias_syntax, $orig, $alias if $alias;
  }

  # reorganized columns back into %$args
  $args->{-columns} = \@cols;
}


sub _resolve_source {
  my ($self, 
      $source,      # a datasource (a subclass of Table or View)
      $colsource,   # prefix in -columns => [qw/... colsource.colname .../]
      $col)         # full string colsource.colname|alias (just for croak msg)
    = @_;

  my $db_table     = $source->db_table;
  my $tableAliases = $source->classData->{tableAliases}    # for views
                   || {$db_table => {table => $source}}; # fake for tables

  # first try an exact match
  my $related      = $tableAliases->{$colsource};

  # if not, try case-insensitive match
  if (!$related) {
    my $uc_colsource = uc $colsource;
    my $match = first {$uc_colsource eq uc $_} keys %$tableAliases
      or croak "cannot resolve data source for $col";
    $related = $tableAliases->{$match};
  }
  return $related->{table};
}


sub _reorganize_pagination {
  my ($self) = @_;
  my $args   = $self->{args};

  croak "missing -pageSize" if $args->{-pageIndex} and not $args->{-pageSize};

  if ($args->{-pageSize}) {
    not exists $args->{$_} or croak "conflicting parameters: -pageSize and $_"
      for qw/-limit -offset/;
    $args->{-limit} = $args->{-pageSize};
    if ($args->{-pageIndex}) {
      $args->{-offset} = ($args->{-pageIndex} - 1) * $args->{-pageSize};
    }
  }
}


sub _limit_offset {
  my ($self, $handler, $sql_ref, $bind_ref) = @_;

  $self->{offset} ||= $self->{args}{-offset} || 0;

  # call handler
  $handler or croak "sqlDialect does not handle limit/offset";
  my ($sql, @bind) = $handler->(qw/?limit ?offset/);

  # add limit/offset as placeholders into the SQL 
  $$sql_ref .= " " . $sql;
  push @$bind_ref, @bind;

  # pre-bind values to the placeholders
  $self->bind(limit  => $self->{args}{-limit},
              offset => $self->{offset}      );
}


sub _add_conditions { # merge conditions for L<SQL::Abstract/where>
  my ($self, $new_conditions) = @_;
  my %merged;

  foreach my $cond ($self->{args}{-where}, $new_conditions) {
    if    (isa $cond, 'HASH')  {
      foreach my $col (keys %$cond) {
        $merged{$col} = $merged{$col} ? [-and => $merged{$col}, $cond->{$col}]
                                      : $cond->{$col};
      }
    }
    elsif (isa $cond, 'ARRAY') {
      $merged{-nest} = $merged{-nest} ? {-and => [$merged{-nest}, $cond]}
                                      : $cond;
    }
    elsif ($cond) {
      $merged{$cond} = \"";
    }
  }
  $self->{args}{-where} = \%merged;
}



1; # End of DBIx::DataModel::Statement

__END__

=head1 NAME

DBIx::DataModel::Statement - DBIx::DataModel statement objects

=head1 SYNOPSIS

  # statement creation
  my $stmt = DBIx::DataModel::Statement->new($source, @args);
  # or
  my $stmt = My::Table->createStatement;
  #or
  my $stmt = My::Table->join(qw/role1 role2 .../);

  # statement refinement (adding clauses)
  $stmt->refine(-where => {col1 => {">" => 123},
                           col2 => "?foo"})     # ?foo is a named placeholder
  $stmt->refine(-where => {col3 => 456,
                           col4 => "?bar",
                           col5 => {"<>" => "?foo"}},
                -orderBy => ...);

  # early binding for named placeholders
  $stmt->bind(bar => 987);

  # database prepare (with optional further refinements to the statement)
  $stmt->prepare(-columns => qw/.../); 

  # late binding for named placeholders
  $stmt->bind(foo => 654);

  # database execute (with optional further bindings)
  $stmt->execute(foo => 321); 

  # get the results
  my $list = $stmt->all;
  #or
  while (my $row = $stmt->next) {
    ...
  }

=head1 DESCRIPTION


The purpose of a I<statement> object 
is to retrieve rows from the database and bless
them as objects of appropriate table or view classes.

Internally the statement builds and then encapsulates a
C<DBI> statement handle (sth). 

The design principles for statements are described in the 
L<DESIGN|DBIx::DataModel::Doc::Design/"STATEMENT OBJECTS"> 
section of the manual (purpose, lifecycle, etc.).

=head1 METHODS

=head2 new

  my $statement = DBIx::DataModel::Statement->new($source, @args);

Creates a new statement. The first parameter C<$source> is a 
subclass of L<DBIx::DataModel::Table|DBIx::DataModel::Table>
or L<DBIx::DataModel::View|DBIx::DataModel::View>. 
Other parameters are optional and directly transmitted
to L</refine>.

=head2 clone

Returns a copy of the statement. This is only possible
when in states C<new> or C<sqlized>, i.e. before
a DBI sth has been created.


=head2 status

Returns the current status or the statement (one of
C<new>, C<sqlized>, C<prepared>, C<executed>).

=head2 sql

  $sql         = $statement->sql;
  (sql, @bind) = $statement->sql;

In scalar context, returns the SQL code for this
statement (or C<undef> if the statement is not
yet C<sqlized>). 

In list context, returns the SQL code followed
by the bind values, suitable for a call to 
L<DBI/execute>.

Obviously, this method is only available after the
statement has been sqlized (through direct call 
to the L</sqlize> method, or indirect call via
L</prepare>, L</execute> or L</select>).


=head2 bind

  $statement->bind(foo => 123, bar => 456);
  $statement->bind({foo => 123, bar => 456}); # equivalent to above

  $statement->bind(0 => 123, 1 => 456);
  $statement->bind([123, 456]);               # equivalent to above

Takes a list of bindings (name-value pairs), and associates
them to placeholders within the statement. If successive
bindings occur on the same named placeholder, the last
value silently overrides previous values. If a binding
has no corresponding named placeholder, it is ignored.
Names can be any string (including numbers), except
reserved words C<limit> and C<offset>, which have a special
use for pagination.


The list may alternatively be given as a hashref. This 
is convenient for example in situations like

  my $statement = $source->some_method;
  foreach my $row (@{$source->select}) {
    my $subrows = $statement->bind($row)->select;
  }

The list may also be given as an
arrayref; this is equivalent to a hashref
in which keys are positions within the array.

Finally, there is a ternary form 
of C<bind> for passing DBI-specific arguments.

  use DBI qw/:sql_types/;
  $statement->bind(foo => $val, {TYPE => SQL_INTEGER});

See L<DBI/"bind_param"> for explanations.


=head2 refine

  $statement->refine(%args);

Set up some named parameters on the statement, that
will be used later by the C<select> method (see
that method for a complete list of available parameters).

The main use of C<refine> is to set up some additional
C<-where> conditions, like in 

  $statement->refine(-where => {col1 => $value1, col2 => {">" => $value2}});

These conditions are accumulated into the statement,
implicitly combined as an AND, until
generation of SQL through the C<sqlize> method.
After this step, no further refinement is allowed.

The C<-where> parameter is the only one with a special 
combinatory logic.
Other named parameters to C<refine>, like C<-columns>, C<-orderBy>, 
etc., are simply stored into the statement, for later
use by the C<select> method; the latest specified value overrides
any previous value.

=head2 sqlize

  $statement->sqlize(@args);

Generates SQL from all parameters accumulated so far in the statement.
The statement switches from state C<new> to state C<sqlized>,
which forbids any further refinement of the statement
(but does not forbid further bindings).

Arguments are optional, and are just a shortcut instead of writing

  $statement->refine(@args)->sqlize;

=head2 prepare

  $statement->prepare(@args);

Method C<sqlized> is called automatically if necessary.
Then the SQL is sent to the database, and the returned DBI C<sth>
is stored internally within the statement.
The state switches to "prepared".

Arguments are optional, and are just a shortcut instead of writing

  $statement->sqlize(@args)->prepare;


=head2 execute

  $statement->execute(@bindings);

Translates the internal named bindings into positional
bindings, calls L<DBI/execute> on the internal C<sth>, 
and applies the C<-preExec> and C<-postExec> callbacks 
if necessary.
The state switches to "executed".

Arguments are optional, and are just a shortcut instead of writing

  $statement->bind(@bindings)->execute;

An executed statement can be executed again, possibly with some 
different bindings. When this happens, the internal result
set is reset, and fresh data rows can be retrieved through 
the L</next> or L</all> methods.


=head2 select

This is the frontend method to most methods above: it will
automatically take the statement through the necessary
state transitions, passing appropriate arguments
at each step. The C<select> API is complex and is fully 
described in L<DBIx::DataModel::Doc::Reference/select>.

=head2 rowCount

Returns the number of rows corresponding to the current
executed statement. Raises an exception if the statement
is not in state "executed".

Note : usually this involves an additional call to 
the database (C<SELECT COUNT(*) FROM ...>), unless
the database driver implements a specific method 
for counting rows (see for example 
L<DBIx::DataModel::Statement::JDBC>).

=head2 rowNum

Returns the index number of the next row to be fetched
(starting at C<< $self->offset >>, or 0 by default).


=head2 next

  while (my $row = $statement->next) {...}

  my $slice_arrayref = $statement->next(10);

If called without argument, returns the next data row, or
C<undef> if there are no more data rows.
If called with a numeric argument, attempts to retrieve
that number of rows, and returns an arrayref; the size
of the array may be smaller than required, if there were
no more data rows. The numeric argument is forbidden 
on fast statements (i.e. when L</reuseRow> has been called).

Each row is blessed into an object of the proper class,
and is passed to the C<-postFetch> callback (if applicable).


=head2 all

  my $rows = $statement->all;

Similar to the C<next> method, but 
returns an arrayref containing all remaining rows.
This method is forbidden on fast statements
(i.e. when L</reuseRow> has been called).




=head2 pageSize

Returns the page size (requested number of rows), as it was set 
through the C<-pageSize> argument to C<refine()> or C<select()>.

=head2 pageIndex

Returns the current page index (starting at 1).
Always returns 1 if no pagination is activated
(no C<-pageSize> argument was provided).

=head2 offset

Returns the current I<requested> row offset (starting at 0).
This offset changes when a request is made to go to another page;
but it does not change when retrieving successive rows through the 
L</next> method.

=head2 pageCount

Calls L</rowCount> to get the total number of rows
for the current statement, and then computes the
total number of pages.

=head2 gotoPage

  $statement->gotoPage($pageIndex);

Goes to the beginning of the specified page; usually this
involves a new call to L</execute>, unless the current
statement has methods to scroll through the result set
(see for example L<DBIx::DataModel::Statement::JDBC>).

Like for Perl arrays, a negative index is interpreted
as going backwards from the last page.


=head2 shiftPages

  $statement->shiftPages($delta);

Goes to the beginning of the page corresponding to
the current page index + C<$delta>.

=head2 pageBoundaries

  my ($first, $last) = $statement->pageBoundaries;

Returns the indices of first and last rows on the current page.
These numbers are given in "user coordinates", i.e. starting
at 1, not 0 : so if C<-pageSize> is 10 and C<-pageIndex> is 
3, the boundaries are 21 / 30, while technically the current
offset is 20. On the last page, the C<$last> index corresponds
to C<rowCount> (so C<$last - $first> is not always equal
to C<pageSize + 1>).

=head2 pageRows

Returns an arrayref of rows corresponding to the current page
(maximum C<-pageSize> rows).

=head2 reuseRow

Creates an internal memory location that will be reused
for each row retrieved from the database; this is the
implementation for C<< select(-resultAs => "fast_statement") >>.




=head1 PRIVATE METHOD NAMES

The following methods or functions are used
internally by this module and 
should be considered as reserved names, not to be
redefined in subclasses :

=over

=item _blessFromDB

=item _compute_fromDB_handlers

=item _reorganize_columns

=item _reorganize_pagination

=item _resolve_source

=item _limit_offset

=item _add_conditions

=back



=head1 AUTHOR

Laurent Dami, E<lt>laurent.dami AT etat  ge  chE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2008 by Laurent Dami.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself. 



