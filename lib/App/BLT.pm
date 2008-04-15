#!/usr/bin/perl

use strict;
use warnings;

# Globals (since we're an ad-hoc library):
our ($home, $pid_filename, %rc_settings, $last_fetch_filename,
    $timeline, $check_public, $VERSION);

sub print_masthead {
  print <<EOT;
blt - bash loves twitter - shell/twitter integration
Copyright (c) 2008 Thomas Thurman - tthurman\@gnome.org - http://marnanel.org
blt is released in the hope that it will be useful, but with NO WARRANTY.
blt is released under the terms of the GNU General Public Licence.

EOT
}

sub print_help {
  print <<EOT;
Choose at most one mode:
  -c, --check = print updates from Twitter
  -s, --set = update Twitter from command line (default)
  -h, --help = show this text
  -v, --version = show version number
  -a, --as=USER = post as USER, if you add them in ~/.bltrc.xml

Switches:
  -F, --force  = always check, even if we checked recently
  -S, --sync   = don't check in the background
  -P, --public = read the public timeline (not for posting!)
EOT
}

sub add_to_bashrc {
  my $bashrc = "$home/.bashrc";

  if (-e $bashrc) { # if they don't have one, don't bother checking

    local $/;
    undef $/;

    open BASHRC, "<$bashrc" or die "Can't open $bashrc: $!";
    my $bashrc = <BASHRC>;
    close BASHRC or die "Can't close $bashrc: $!";

    return if ($bashrc =~ /^[^#\n]*PROMPT_COMMAND/m);
  }

  print "\nAttempting to add ourselves to $bashrc...";

  # FIXME: this is broken; $0 may be a relative path
  open BASHRC, ">>$bashrc" or die "Can't open $bashrc: $!";
  print BASHRC "\n\n# Added by $0\nexport PROMPT_COMMAND=\"$0 --check\"\n"
        or die "Can't write to $bashrc: $!";
  close BASHRC or die "Can't close $bashrc: $!";

  print "done.\n\n";
  print "You will need to log out and back in to get\n";
  print "automatic notifications.\n";
}

sub already_running_in_background {
  if (-e $pid_filename) {

    my @stats = stat($pid_filename);
    my $age = time-($stats[9]);

    if ($age > 60) {
      # oh, that's just silly. Nobody takes a whole minute
      unlink $pid_filename;
      return 0;
    }

    # Maybe we should also check that the PID is valid,
    # but I think that's overkill.

    return 1;
  } else {
    return 0;
  }
}

#############################
# Here's our roll-your-own Twitter library
# because Net::Twitter is a bit clunky.
# It is very simple, and still in a lot of flux.
#
# This will eventually become Net::Twitter::Simple,
# or something like that.
#############################

sub twitter_useragent {

  # If we get here, we need LWP. But don't "use" it because that's an
  # implicit BEGIN{} (so we will always incur the hit of loading it,
  # even though the general case is that we don't need it).
  eval { require LWP::UserAgent; };

  # Create a user agent object
  my $ua = LWP::UserAgent->new(timeout => 5);

  # Dn't authenticate if they're asking for -c -P
  unless ($check_public) {
      $ua->credentials('twitter.com:80', 'Twitter API',
          $rc_settings{user},
          $rc_settings{pass},
      );
  }

  $ua->default_header('X-Twitter-Client' => 'blt');
  $ua->default_header('X-Twitter-Client-Version' => $VERSION);
  $ua->default_header('X-Twitter-Client-URL' => 'http://marnanel.org/projects/blt/');

  return $ua;
}

sub twitter_post {
  my ($status) = @_;

  my $ua = twitter_useragent();
  my $response = $ua->post(
    'http://twitter.com/statuses/update.xml',
    {
      status => $status,
      source => 'blt',
    }
  );

  die $response->status_line unless $response->is_success;

}

sub twitter_following {

  my ($since) = @_;

  my $ua = twitter_useragent();

  if (defined $since) {
    eval {
      require POSIX; import POSIX qw(setlocale LC_ALL strftime);
      setlocale(LC_ALL(), 'C');
      # note that the "since" parameter is not currently working with Twitter
      $ua->default_header('If-Modified-Since', strftime("%a, %d %b %Y %T GMT", gmtime($since)));
    }
  }

  my $response = $ua->get(
    "http://twitter.com/statuses/${timeline}_timeline.xml",
  );

  unless ($check_public) {
    open LAST_FETCH, ">$last_fetch_filename" or die "Can't open $last_fetch_filename: $!";
    print LAST_FETCH time;
    close LAST_FETCH or die "Can't close $last_fetch_filename: $!";
  }

  if ($response->code == 500 && $response->status_line =~ /Can't connect/) {
    return "blt: failed to reach twitter; won't check again for a while\n".$response->status_line."\n";
  }

  return '' if $response->code == 304; # Not Modified
  die $response->status_line unless $response->is_success;

  my (@results, $screenname, $text);

  for (@{parsefile(new IO::Scalar \($response->content))->[0]->{'content'}}) {

    for my $field (@{ $_->{'content'} }) {
      if ($field->{'name'} eq 'text') {
        $text = $field->{'content'}->[0]->{'content'};
      } elsif ($field->{'name'} eq 'user') {
        for my $user_field (@{ $field->{'content'}}) {
          if ($user_field->{'name'} eq 'screen_name') {
            $screenname = $user_field->{'content'}->[0]->{'content'};
            last; # that's all we need to know about a user
          }
        }
      }
    }

    push @results, [$screenname, $text];
  }

  my $result = '';

  foreach (@results) {

    my ($screenname, $text) = @{$_};
    $result .= "<$screenname> $text\n";
  }

  return $result;
}

1;

