#!/usr/bin/perl
# SPDX-FileCopyrightText: 2024 The Remph
# SPDX-License-Identifier: GPL-3.0-or-later
#
# See the __END__ of the script for documentation in POD format -- this
# can be viewed more nicely by piping `pod2man xdg2lynxcfg.pl' into `man -l -'
# or `mandoc -a', or running `perldoc -F xdg2lynxcfg.pl'
#
# Throughout this script, (?<named>captures) are used instead of numbers,
# since the regexes proliferated and nested faster than I could keep track
# of the numbers, and named captures are nice and stable. /n is used in
# regexen frequently here, so unnamed captures are just clusters for
# efficiency and clarity
#
# TODO:
# - (NON_)XWINDOWS?
# - should be able to add arbitrary stuff, although maybe that's out of scope
# - What about unicode? Does the freedesktop standard for .desktop entries
#   say anything explicit about encoding? If it doesn't mandate UTF-8, should
#   probably <use open locale ':std' => IO => ':locale';>

use strict;
use warnings;
use 5.10.0;	# (?<captures>), `state'; /n also wants 5.22, fucksake. If we
		# go with that tho, we can have s///r with 5.14
use File::BaseDir 'data_files';
use File::DesktopEntry;
use Getopt::Std;
use Pod::Usage;

our $VERSION = 0;

my $word = qr/[\w-]+?/;	# My word! Modified \w set which also includes hyphen
# This matches foo/bar, foo/, /bar, etc.
my $mime_rgx = qr| (?<type>$word)? / (?<subtype> ($word\.)* $word (\+$word)* )? |xn;
#                                                   tree  susubtype suffix


# Array of references to arrays each containing four elements: two for the
# MIME components respectively before and after the slash (either can be
# undef for `match anything'), the entry to be added or removed, and a
# 4-bit number which will be odd for add and even for remove, and will have
# the second bit set if the operation is to be forced (unconditional). Good
# thing about an array is that it preserves the order of elements as added
my @preferred;
sub parse_preferred_open {
	die if @_;
	m/^ ($mime_rgx:)? (?<pref>.+?) (?<op>[+-]{1,2}) $/xn or return;
	my $flags = (substr $+{op}, 0, 1) eq "+" | ((length($+{op}) == 2) << 1);
	push @preferred, [ @+{qw/type subtype pref/}, $flags ];
}

# Key is desktop entry (without .desktop); value is string to exec instead
# of File::DesktopEntry::get('Exec')
my %exec_overrides;
sub parse_exec_override {
	die if @_;
	my ($entry, $exec) = split '=';

	local $_;
	for ($entry, $exec) {
		return 0 unless defined and /./;
	}
	warn "missing %s: <$entry=$exec>" if $exec !~ /%s/;

	$exec_overrides{$entry} = $exec;
	return 1;
}

my %opt;
sub main::HELP_MESSAGE { pod2usage(0) }
sub parse_cmdline {
	die if @_;
	my $optstr = 'hVf:';
	$Getopt::Std::STANDARD_HELP_VERSION = 1;
	getopts($optstr => \%opt) or die;

	if ($opt{h} or $opt{V}) {
		Getopt::Std::version_mess($optstr);
		&HELP_MESSAGE if $opt{h};
		exit 0;
	}

	&parse_preferred_open or &parse_exec_override or die "Can't parse $_"
		while defined($_ = shift @ARGV);
}


sub desktop_exec_to_lynx {
	state %entries;	# Contains objects of type File::DesktopEntry,
			# indexed by argument to new()

	die unless @_ == 1;
	my $dentry = shift;
	return $exec_overrides{$dentry} if exists $exec_overrides{$dentry};

	# Cache results of File::DesktopEntry lookup
	unless (exists $entries{$dentry}) {
		$entries{$dentry} = File::DesktopEntry->new($dentry);
	}

	# Postprocess heuristically
	local $_ = $entries{$dentry}->get('Exec');
	# Sorry about all those format specifiers, we only do %s here
	s/%[A-Za-z]/%s/g;
	# For those who hadn't the sense to properly option-end the cmdline
	s/(\s)%s/$1--$1%s/ unless m/\s--\s/;
	return $_;
}

# Reorder semicolon-separated .desktop options in accordance with command
# line arguments
sub shuffle_options {
	die unless @_ == 3;
	local $_;
	my ($type, $subtype) = (shift, shift);
	my @desktoptions = map { s/\.desktop$//r } split ';', shift;
	my $changes_made = @desktoptions == 1;	# then don't need to warn about no changes

	foreach (@preferred) {
		if (	(not defined $_->[0] or $_->[0] eq $type) and
			(not defined $_->[1] or $_->[1] eq $subtype))
		{
			my ($preferred_opt, $flags, $found) = (@$_[2,3], undef);
			@desktoptions = grep { $_ ne $preferred_opt or $found = 0 } @desktoptions;

			if ($flags % 2) {
				# flags are odd, so we add to the top of the
				# list: if the second bit is set, then this is
				# unconditional; else, it only happens if there
				# was a match
				unshift @desktoptions, $preferred_opt
					if $flags >> 1 or defined $found;
			} else {
				# Flags are even, so we remove from the list
				# (already done). If the second bit is not set,
				# it's just a demotion rather than an eradication,
				# so we put the entry back on the bottom
				push @desktoptions, $preferred_opt unless $flags >> 1;
			}

			$changes_made = 1;
		}
	}

	warn "options for $+{mime}:\t@desktoptions" unless $changes_made;
	return @desktoptions;
}


## MAIN ##

# init
&parse_cmdline;
$, = ':', $\ = "\n";
# Two-arg open a la ARGV::readonly, ensuring read-only while still opening
# `-' as stdin
for ($opt{f}) {
	# Is that reverse() right?
	@ARGV = map "< $_\0" => defined ? s|^(\s)|./$1|r : reverse data_files(qw/applications mimeinfo.cache/);
}

while (<>) {
	chomp;

	# We could be reading several files cat(1) from stdin, so just take
	# random floating mimeinfo headers as a fact of life...
	next if $_ eq '[MIME Cache]';
	# ...but still mention when they are conspicuous in their absence
	warn 'Missing mimeinfo header' if $. == 1;

	# . (dot) is used here intentionally instead of \w or $word, to
	# handle (ignore) any potential fucked-up desktop filenames
	unless (
		m/^(?<mime>$mime_rgx)=(?<opts>(.+?\.desktop;)+)$/n
		and defined $+{type} and defined $+{subtype}
	) {
		warn 'malformed record';
		next;
	}

	print 'VIEWER', $+{mime}, desktop_exec_to_lynx((shuffle_options(@+{qw/type subtype opts/}))[0]);
	# Did Larry Wall mention something about fingernails floating in
	# porridge?
#} continue {
#	close ARGV if eof; # FIXME: fuck knows
}

__END__

=head1 NAME

xdg2lynxcfg (gesundheit) E<ndash> Convert XDG desktop entries to lynx.cfg

=head1 SYNOPSIS

xdg2lynxcfg [options] [directives]

=head1 OPTIONS

=over

=item B<-h>, B<--help>

Print this help and exit

=item B<-V>, B<--version>

Print version information and exit

=item B<-f> I<FILE>

Use FILE as input. If FILE is -, read input from stdin. Without this, defaults
to searching the XDG data directories for applications/mimeinfo.cache

=back

=head1 ARGUMENTS

Strictly speaking, these are directives

=head2 Exec override

Directives of the form C<I<app>='I<args> -- %s'> (really, anything
containing an C<=>) override the Exec portion of the I<app>.desktop entry,
so if I<app> is launched from lynx, it will be with the command-line
arguments after the C<=>. That string is passed straight into lynx.cfg, so
it must follow lynx's rule about always having a C<%s>, which should
probably be preceded by a C<-->

=head2 Preference

Directives of the form C<I<mimeB</>type>:I<app>+> increase the precedence
of I<app> to open the MIME type listed before the colon, so it will be
picked over any other options when available. Likewise,
C<I<mimeB</>type>:I<app>-> will decrease their precedence, so any other
options for that MIME type will be prefered. The plus or minus can be
doubled, where C<++> and C<--> respectively mean to always or never
to use I<app> for I<mime/type> always, even when I<app> is (not) present
in the .desktop entries.

In both cases, the leading MIME type and colon are optional and omitting
these will apply the rule to all MIME types; if the portion of the MIME
type before and/or after the slash is omitted, the omitted portion matches
anything.

=head1 EXAMPLES

=over

=item C<xdg2lynxcfg image/gif:mpv++ ida-- image/:imv-dir+ mpv='mpv -- %s'>

=over

=item	Always use mpv(1) to open image/gif, even if XDG doesn't think
	that's an option

=item	Never use ida(1) to open anything

=item	Prefer imv-dir(1) for images

=item	If and when mpv(1) is used, use it without command-line options, just
	to simply open files

=back

=back

=head1 ENVIRONMENT VARIABLES

=over

=item B<XDG_DATA_HOME>, B<XDG_DATA_DIRS>

If set, searched for applications/mimeinfo.cache, unless B<-f> is passed.
Also searched for applications/*.desktop entries if they are needed

=back

=head1 FILES

=over

=item B</usr/share/applications/mimeinfo.cache>

Default input file, unless overridden by the above environment variables or
options

=item B</usr/share/applications>

Default location searched for *.desktop entries, unless overridden by the
above environment variables

=back

=head1 NOTES

B<-f> is not cumulative, and there is no mechanism for including other
lynx.cfg files or fragments. God forbid anyone use cat(1) for the one thing
it's I<actually for>

=head1 SEE ALSO

lynx(1)

=head1 COPYRIGHT

E<copy> 2024 The Remph <lhr@disroot.org>. This program is free software:
you can redistribute it and/or modify it under the terms of the GNU
General Public License as published by the Free Software Foundation,
either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public
License for more details. A full copy of the GNU GPL can be found at
<https://www.gnu.org/licenses/gpl.txt>

=cut

