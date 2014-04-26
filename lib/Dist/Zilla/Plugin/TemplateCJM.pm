#---------------------------------------------------------------------
package Dist::Zilla::Plugin::TemplateCJM;
#
# Copyright 2009 Christopher J. Madsen
#
# Author: Christopher J. Madsen <perl@cjmweb.net>
# Created: 24 Sep 2009
#
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See either the
# GNU General Public License or the Artistic License for more details.
#
# ABSTRACT: Process templates, including version numbers & changes
#---------------------------------------------------------------------

our $VERSION = '4.22';
# This file is part of {{$dist}} {{$dist_version}} ({{$date}})

=head1 SYNOPSIS

In your F<dist.ini>:

  [TemplateCJM]
  changelog = Changes      ; this is the default
  changes   = 1            ; this is the default
  file      = README       ; this is the default
  report_versions = 1      ; this is the default
  date_format     =        ; this is the default

=head1 DEPENDENCIES

TemplateCJM requires {{$t->dependency_link('Dist::Zilla')}} and
L<Text::Template>.  I also recommend applying F<Template_strict.patch>
to Text::Template.  This will add support for the STRICT option, which
will help catch errors in your templates.

=cut

use Moose;
use Moose::Autobox;
use Moose::Util::TypeConstraints;
use List::Util ();

# We operate as an InstallTool instead of a FileMunger because the
# prerequisites have not been collected when FileMungers are run.
with(
  'Dist::Zilla::Role::InstallTool',
  'Dist::Zilla::Role::BeforeRelease',
  'Dist::Zilla::Role::ModuleInfo',
  'Dist::Zilla::Role::TextTemplate',
  'Dist::Zilla::Role::FileFinderUser' => {
    default_finders => [ ':InstallModules' ],
  },
);

sub mvp_multivalue_args { qw(file) }

=attr changelog

This is the name of the F<Changes> file.  It defaults to F<Changes>.

=cut

has changelog => (
  is   => 'ro',
  isa  => 'Str',
  default  => 'Changes',
);

=attr changelog_re

This is the regex used to extract the version and release date from
the F<Changes> file.  It defaults to C<(\d[\d._]*)\s+(.+)>
(i.e. version number at beginning of the line, followed by whitespace,
and everything after that is the release date).  It it automatically
anchored at the beginning of the line.  Note: your version lines
I<must not> begin with whitespace.  All other lines I<must> begin with
whitespace.

=cut

coerce 'RegexpRef', from 'Str', via { qr/$_/ };

has changelog_re => (
  is   => 'ro',
  isa  => 'RegexpRef',
  coerce   => 1,
  default  => sub { qr/(\d[\d._]*)\s+(.+)/ },
);

=attr changes

This is the number of releases to include in the C<$changes> variable
passed to templates.  It defaults to 1 (meaning only changes in the
current release).  This is useful when you make a major release
immediately followed by a bugfix release.

=cut

has changes => (
  is   => 'ro',
  isa  => 'Int',
  default  => 1,
);

=attr date_format

This is the DateTime CLDR format to use for the C<$date> variable in
templates.  The default value is the empty string, which means to use
the date exactly as it appeared in the F<Changes> file.

=cut

has date_format => (
  is   => 'ro',
  isa  => 'Str',
  default  => '',
);

=attr file

This is the name of a file to process with Text::Template in step 2.
The C<file> attribute may be listed any number of times.  If you don't
list any C<file>s, it defaults to F<README>.  If you do specify any
C<file>s, then F<README> is not processed unless explicitly specified.

=cut

has template_files => (
  is   => 'ro',
  isa  => 'ArrayRef',
  lazy => 1,
  init_arg => 'file',
  default  => sub { [ 'README' ] },
);

=attr finder

This FileFinder provides the list of files that are processed in step
3.  The default is C<:InstallModules>.  The C<finder> attribute may be
listed any number of times.

=attr report_versions

If true (the default), report the version of each module processed.

=cut

has report_versions => (
  is      => 'ro',
  isa     => 'Bool',
  default => 1,
);

#---------------------------------------------------------------------
# Main entry point:

sub setup_installer {
  my ($self) = @_;

  my $files = $self->zilla->files;

  # Get release date & changes from Changes file:
  my $changelog = $self->changelog;
  my $changesFile = $files->grep(sub{ $_->name eq $changelog })->head
      or die "No $changelog file\n";

  my ($release_date, $changes, $release_datetime) = $self->check_Changes($changesFile);

  # Process template_files:
  my %data = (
     changes => $changes,
     date    => $release_date,
     datetime=> $release_datetime,
     dist    => $self->zilla->name,
     meta    => $self->zilla->distmeta,
     t       => \$self,
     version => $self->zilla->version,
     zilla   => \$self->zilla,
  );

  $data{dist_version} = $data{version};

  # The STRICT option hasn't been implemented in a released version of
  # Text::Template, but you can apply Template_strict.patch.  Since
  # Text::Template ignores unknown options, this code will still work
  # even if you don't apply the patch; you just won't get strict checking.
  my %parms = (
    STRICT => 1,
    BROKEN => sub { $self->template_error(@_) },
  );

  my $any = $self->template_files->any;

  foreach my $file ($files->grep(sub { $_->name eq $any })->flatten) {
    $self->log('Processing ' . $file->name);
    $self->_cur_filename($file->name);
    $self->_cur_offset(0);
    $file->content($self->fill_in_string($file->content, \%data, \%parms));
  } # end foreach $file

  # Munge POD sections in modules:
  $files = $self->found_files;

  foreach my $file ($files->flatten) {
    $self->munge_file($file, \%data, \%parms);
  } # end foreach $file
} # end setup_installer

#---------------------------------------------------------------------
# Make sure we have a release date:

has _release_date => (
  is       => 'rw',
  isa      => 'Str',
  init_arg => undef,
);

has _release_datetime => (
  is       => 'rw',
  isa      => 'DateTime',
  init_arg => undef,
);

sub before_release
{
  my $self = shift;

  my $release_date = $self->_release_date;

  $self->log_fatal(["Invalid release date in %s: %s",
                    $self->changelog, $release_date ])
      if not $release_date or not $self->_release_datetime or $release_date =~ /^[[:upper:]]+$/;

} # end before_release

#---------------------------------------------------------------------
# Make sure that we've listed this release in Changes:
#
# Returns:
#   A list (release_date, change_text, release_datetime)

sub check_Changes
{
  my ($self, $changesFile) = @_;

  my $file = $changesFile->name;

  my $version = $self->zilla->version;

  # Get the number of releases to include from Changes:
  my $list_releases = $self->changes;

  # Read the Changes file and find the line for dist_version:
  my $changelog = $changesFile->content;

  my ($release_date, $text);

  my $re = $self->changelog_re;

  while ($changelog =~ m/(.*\n)/g) {
    my $line = $1;
    if ($line =~ /^$re/) {
      die "ERROR: $file begins with version $1, expected version $version"
          unless $1 eq $version;
      $release_date = $2;
      $text = '';
      while ($changelog =~ m/(.*\n)/g) {
        $line = $1;
        last if $line =~ /^\S/ and --$list_releases <= 0;
        $text .= $line;
      }
      $text =~ s/\A\s*\n//;     # Remove leading blank lines
      $text =~ s/\s*\z/\n/;     # Normalize trailing whitespace
      die "ERROR: $file contains no history for version $version"
          unless length($text) > 1;
      last;
    } # end if found the first version in Changes
  } # end while more lines in Changes

  undef $changelog;

  # Report the results:
  die "ERROR: Can't find any versions in $file" unless $release_date;

  $self->_release_date($release_date); # Remember it for before_release

  # Try to parse the release date:
  require DateTime::Format::Natural;

  my $parser = DateTime::Format::Natural->new(
    format    => 'mm/dd/yy',
    time_zone => 'local',
  );

  # If the date is YYYY-MM-DD with optional time,
  # you may have a release note after the date.
  my $release_datetime = $parser->parse_datetime(
    $release_date =~ m{
      ^ ( \d{4}-\d\d-\d\d
          (?: \s \d\d:\d\d (?: :\d\d)? )?
        ) \b
    }x ? "$1" : $release_date
  );

  if ($parser->success) {
    $self->_release_datetime($release_datetime); # Remember it for before_release
  } else {
    $self->log_debug("Unable to parse '${release_date}'");
    $release_datetime = undef;
  }

  if ($release_datetime and $self->date_format) {
    $release_date = $release_datetime->format_cldr($self->date_format);
  }

  # Return the results:
  chomp $text;

  $self->log("Version $version released $release_date");
  $self->zilla->chrome->logger->log($text); # No prefix

  return ($release_date, $text, $release_datetime);
} # end check_Changes

#---------------------------------------------------------------------
# Process all POD sections of a module as templates:

sub munge_file
{
  my ($self, $file, $dataRef, $parmsRef) = @_;

  # Extract information from the module:
  my $pmFile  = $file->name;
  my $pm_info = $self->get_module_info($file);

  my $version = $pm_info->version;

  if (not $version and $pmFile =~ m!^lib/(.+)\.pod$!) {
    ($dataRef->{module} = $1) =~ s!/!::!g;
    $version = $dataRef->{dist_version};
  }

  die "ERROR: Can't find version in $pmFile" unless $version;

  # level => 'debug' doesn't work here; see RT#77622:
  my $log_method = ($self->report_versions ? 'log' : 'log_debug');
  $self->$log_method("$pmFile: VERSION $version");

  $dataRef->{version} = "$version";
  $dataRef->{module}  = $pm_info->name || $dataRef->{module};
  $dataRef->{pm_info} = \$pm_info;

  $parmsRef->{FILENAME} = $pmFile;

  # Process all POD sections:
  my $content = $file->content;

  $self->_cur_filename($pmFile);
  $self->_cur_content(\$content);

  $content =~ s{( ^=(?!cut\b)\w .*? (?: \z | ^=cut\b ) )}
               {
                 $self->_cur_offset($-[0]);
                 $self->fill_in_string($1, $dataRef, $parmsRef)
               }xgems;

  # And comments at BOL:
  #   Text::Template breaks on strings that have the closing delimiter
  #   without the opening one.  Only process comments that have at
  #   least one matched set of delimiters.
  $content =~ s{( ^\# .* \{\{ .* \}\} .* )}
               {
                 $self->_cur_offset($-[0]);
                 $self->fill_in_string($1, $dataRef, $parmsRef)
               }xgem;

  $file->content($content);
  $self->_cur_content(undef);

  return;
} # end munge_file
#---------------------------------------------------------------------

=method build_instructions

  $t->build_instructions( [$prefix] )

A template can use this method to add build instructions for the
distribution (normally used in README).  C<$prefix> is prepended to
each line, and defaults to a single TAB.

It returns either

	perl Build.PL
	./Build
	./Build test
	./Build install

or

	perl Makefile.PL
	make
	make test
	make install

depending on whether your distribution includes a Build.PL.  The
string will NOT end with a newline.

It throws an error if neither Build.PL nor Makefile.PL is found.

=cut

sub build_instructions
{
  my ($self, $indent) = @_;

  $indent = "\t" unless defined $indent;

  # Compute build instructions:
  my $builder = $self->zilla->files
                     ->map(sub{ $_->name })
                     ->grep(sub{ /^(?:Build|Makefile)\.PL$/ })
                     ->sort->head;

  $self->log_fatal("Unable to locate Build.PL or Makefile.PL in distribution\n".
                   "TemplateCJM must come after ModuleBuild or MakeMaker")
      unless $builder;

  my $build = ($builder eq 'Build.PL' ? './Build' : 'make');

  join("\n", map { $indent . $_ }
    "perl $builder",
    "$build",
    "$build test",
    "$build install",
  );
} # end build_instructions
#---------------------------------------------------------------------

=method dependency_link

  $t->dependency_link('Foo::Bar')

A template can use this method to add a link to the documentation of a
required module.  It returns either

  L<Foo::Bar> (VERSION or later)

or

  L<Foo::Bar>

depending on whether VERSION is non-zero.  (It determines VERSION by
checking C<requires> and C<recommends> in your prerequisites.)

=cut

sub dependency_link
{
  my ($self, $module) = @_;

  my $meta = $self->zilla->distmeta->{prereqs}{runtime} || {};
  my $ver;

  for my $key (qw(requires recommends)) {
    last if defined($ver = $meta->{$key}{$module});
  } # end for each $key

  $self->log("WARNING: Can't find $module in prerequisites")
      unless defined $ver;

  if ($ver) { "L<$module> ($ver or later)" }
  else      { "L<$module>" }
} # end dependency_link
#---------------------------------------------------------------------

=method dependency_list

  $t->dependency_list

A template can use this method to add a list of required modules.
It returns a string like:

  Package                Minimum Version
  ---------------------- ---------------
  perl                    5.8.0
  List::Util
  Moose                   0.90

If C<perl> is one of the dependencies, it is listed first.  Also, its
version (if >= 5.6.0) will be normalized into double-decimal form,
even if the prerequisites list it as floating point.

All other dependencies are listed in ASCIIbetical order.  The string
will NOT end with a newline.

If there are no dependencies, the string C<None.> will be returned.

=cut

sub dependency_list
{
  my ($self) = @_;

  my %requires = %{ $self->zilla->distmeta->{prereqs}{runtime}{requires} };

  my @modules = sort grep { $_ ne 'perl' } keys %requires;

  if ($requires{perl}) {
    unshift @modules, 'perl';
    # Standardize Perl version number:
    require version;  version->VERSION(0.77);
    (my $v = $requires{perl}) =~ s/_//g;
    $v = version->parse($v);
    $requires{perl} = $v->normal if $v >= 5.006;
  } # end if minimum Perl version

  return 'None.' unless @modules;

  s/^v// for values %requires;

  my $width = List::Util::max(6, map { length $_ } @modules) + 1;

  my $text = sprintf("  %-${width}s %s\n  ", 'Package', 'Minimum Version');
  $text .= ('-' x $width) . " ---------------\n";

  ++$width;

  foreach my $req (@modules) {
    $text .= sprintf("  %-${width}s %s\n", $req, $requires{$req} || '');
  }

  $text =~ s/\s+\z//;           # Remove final newline

  $text;
} # end dependency_list

#---------------------------------------------------------------------
# Report a template error and die:

has _cur_filename => (
  is   => 'rw',
  isa  => 'Str',
);

# This is a reference to the text we're processing templates in
has _cur_content => (
  is   => 'rw',
  isa  => 'Maybe[ScalarRef]',
);

# This is the position in _cur_content where this template began
has _cur_offset => (
  is   => 'rw',
  isa  => 'Int',
);

sub template_error
{
  my ($self, %e) = @_;

  # Calculate the line number where the template started:
  my $offset = $self->_cur_offset;
  if ($offset) {
    $offset = substr(${ $self->_cur_content }, 0, $offset) =~ tr/\n//;
  }

  # Put the filename & line number into the error message:
  my $err = $e{error};
  my $fn  = $self->_cur_filename;
  $err =~ s/ at template line (\d+)/ " at $fn line " . ($1 + $offset) /eg;

  die $err;
} # end template_error

#---------------------------------------------------------------------
no Moose;
__PACKAGE__->meta->make_immutable;
1;

__END__

=head1 DESCRIPTION

This plugin is the successor to L<Module::Build::DistVersion>.
It performs the following actions:

=over

=item 1.

It opens the F<Changes> file, and finds the first version listed.  The
line must begin with the version number, and everything after the
version number is considered to be the release date.  The version
number from Changes must match Dist::Zilla's idea of the
distribution version, or the process stops here with an error.

=item 2.

It processes each template file with Text::Template.  Template files
are specified with the L<< C<file> attribute|/"file" >>.  Any number of
templates may be present.

Each template may use the following variables:

=over

=item C<$changes>

The changes in the current release.  This is a string containing all
lines in F<Changes> following the version/release date line up to (but
not including) the next line that begins with a non-whitespace
character (or end-of-file).  The string does B<not> end with a newline
(since version 0.08).

You can include the changes from more than one release by setting the
L<< C<changes> attribute/"changes" >>.  This is useful when you make a
major release immediately followed by a bugfix release.

=item C<$date>

The release date taken from F<Changes> and reformatted using L</date_format>.
If C<date_format> is the empty string, or if the release date cannot
be parsed as a date, this is the date exactly as it appears in
F<Changes>.

=item C<$datetime>

The release date taken from F<Changes> as a L<DateTime> object, or
C<undef> if the release date could not be parsed as a date.

=item C<$dist>

The name of the distribution.

=item C<%meta>

The hash of metadata that will be stored in F<META.yml>.

=item C<$t>

The TemplateCJM object that is processing the template.

=item C<$version>

The distribution's version number.  (Also available as C<$dist_version>.)

=item C<$zilla>

The Dist::Zilla object that is creating the distribution.

=back

=item 3.

For each module to be installed, it processes each POD section and
each comment that starts at the beginning of a line through
Text::Template.

Each section may use the same variables as step 2, plus the following:

=over

=item C<$module>

The name of the module being processed (i.e., its package).
In the case of a pure-POD file without a C<package> declaration,
this is derived from its filename (which must match the regex
C<^lib/(.+)\.pod$>).

=item C<$pm_info>

A Module::Metadata object containing information about the
module.  (Note that the filename in C<$pm_info> will not be correct.)

=item C<$version>

The module's version number.  This may be different than the
distribution's version, which is available as C<$dist_version>.
In the case of a pure-POD file without a C<$VERSION> declaration,
this will be the same as C<$dist_version>.

=back

=back

It also peforms a L<BeforeRelease|Dist::Zilla::Role::BeforeRelease>
check to ensure that the release date in the changelog is a valid date.
(I set the date to NOT until I'm ready to release.)

=for Pod::Loom-omit
CONFIGURATION AND ENVIRONMENT

=for Pod::Coverage
before_release
check_Changes
munge_file
mvp_multivalue_args
setup_installer
template_error

=cut
