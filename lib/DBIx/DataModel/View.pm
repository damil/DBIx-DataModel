package DBIx::DataModel::View;

use warnings;
use strict;
use Carp;
use base 'DBIx::DataModel::Source';


# Redefines the method inherited from DBIx::DataModel::Source,
# calling handlers from every parent class.
# TODO : this method is mostly obsolete (superseded by Statement::_blessFromDB)
# but can we remove it completeley ? Think...

sub applyColumnHandler { 
  my ($self, $handlerName, $objects) = @_;

  my $class = ref($self) || $self;
  my $targets = $objects || [$self];
  my %results;			# accumulates result from each parent table

  # recursive call to each parent table
  #   UNSOLVED POTENTIAL CONFLICT : what if several parents 
  #   have handlers for the same columnn ?
  foreach my $table (@{$self->classData->{parentTables}}) {
    my $result = $table->applyColumnHandler($handlerName, $targets);
    my @k = keys %$result;
    @results{@k} = @{$result}{@k};
  }

  return \%results;
};


# Support for Storable::{freeze,thaw} : just a stupid blank operation,
# but that will force Storable::thaw to try to reload the view ... 
# and then we can catch it and generate it on the fly (see @INC below)

sub STORABLE_freeze {
  my ($self, $is_cloning) = @_;

  return if $is_cloning;
  my $copy = {%$self};
  return Storable::freeze($copy);
}

sub STORABLE_thaw {
  my ($self, $is_cloning, $serialized) = @_;

  return if $is_cloning;
  my $copy = Storable::thaw($serialized);
  %$self = %$copy;
}

# Add a coderef handler into @INC, so that when Storable::thaw tries to load
# a view, we take control, generate the View on the fly, and return
# a fake file to load.

push @INC, sub { # coderef into @INC: see L<perlfunc/require>
  my ($coderef, $filename) = @_;

  # did we try to load an AutoView ?
  my ($schema, $view) = ($filename =~ m[^(.+?)/AutoView/(.+)$])
    or return;

  # is it really an AutoView in DBIx::DataModel ?
  $schema =~ s[/][::]g;
  $schema->isa('DBIx::DataModel::Schema')
    or return;

  # OK, this is really our business, so generate the view on the fly
  $view = $schema->join(__FROM_THAW => $view);

  # return a fake filehandle in memory so that "require" is happy
  my $fake_file = "1";
  my $fh;
  if ($] >= 5.008) { open $fh, "<", \$fake_file or die $!; } # modern Perl
  else             { eval "use IO::String; 1" or die $@;     # older versions
                     $fh = IO::String->new($fake_file);    }

  return $fh;
};




1; # End of DBIx::DataModel::View

__END__

=head1 NAME

DBIx::DataModel::View - Parent for View classes


=head1 DESCRIPTION

This is the parent class for all view classes created through

  $schema->View($classname, ...);

=head1 METHODS

Methods are documented in 
L<DBIx::DataModel::Doc::Reference|DBIx::DataModel::Doc::Reference>.
This module implements

=over

=item L<applyColumnHandler|DBIx::DataModel::Doc::Reference/applyColumnHandler>

=back


=head1 SUPPORT FOR STORABLE

If an instance of a dynamically created view is serialized
through L<Storable/freeze> and then deserialized in
another process through L<Storable/thaw>, then it may
happen that the second process does not know about the 
dynamic view. Therefore this class adds a coderef handler
into C<@INC>, so that it can take control when C<thaw> attempts
to load the class from a file, and recreate the view
dynamically.

=head1 AUTHOR

Laurent Dami, C<< <laurent.dami AT etat.ge.ch> >>

=head1 COPYRIGHT & LICENSE

Copyright 2006, 2008 Laurent Dami.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.
