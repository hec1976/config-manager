#!/usr/bin/env perl
# Config Manager — REST (actions schema, umask-first, hardened)
# Version: 1.6.1 (2025-09-29)
#
# Änderungen ggü. 1.5.0:
# - allowed_roots optional gemacht via path_guard: off|audit|enforce (Default: off)
# - Symlinks weiterhin verboten (Defense-in-Depth)
# - apply_meta: auto-aktiv, sobald user|group|mode gesetzt (oder global/apply_meta=true)
# - Health-Check respektiert path_guard
# - Logging verbessert (BOOT/Meta-Entscheidungen)
#
# Änderungen ggü. 1.6.0:
# - Path-Guard: Fix in _is_allowed_path für leere allowed_roots
#   (audit: erlauben + Warn-Log; enforce: verbieten; bei gesetzter Liste Präfix-Check).
# - allowed_roots: Boot-Kanonisierung zu @ALLOWED_CANON (realpath, trailing slash, Dedupe) + Logging.
# - configs.json: atomare Writes in POST /raw/configs und DELETE /raw/configs/:name (write_atomic).
# - Actions: exec:systemctl is-active normalisiert ohne zweiten system()-Call; konsistentes JSON.
# - Style: Tabs→Spaces im is-active-Block; keine Funktionsänderung.
#
# Kurzbeschreibung:
# - Liest/schreibt generische Konfigurationsdateien (atomar, UTF-8/raw)
# - Backups mit Zeitstempel und Aufbewahrungs-Limit (pro-Config-Unterordner)
# - Rechte via umask 0007; Tempfile-0600-Problem gefixt (chmod vor rename)
# - Optional: apply_meta (user/group/mode) nach dem Schreiben/Restore
# - Pfad-Guard optional (off|audit|enforce) + Symlink-Verbot
# - ACL per allowed_ips (IPv4/IPv6 via Net::CIDR) + API-Token (ENV bevorzugt)
# - Keine Auto-Verzeichniserstellung (optional aktivierbar per Flag)
# - NEU: actions (Token→Arg-Array) statt commands/command_args, mit Legacy-Support

use strict;
use warnings;

use Mojolicious::Lite;
use JSON::MaybeXS qw(encode_json decode_json);
use File::Basename qw(basename dirname);
use File::Copy qw(copy);
use IO::Handle ();
use Time::Piece;
use Time::HiRes qw(time);
use FindBin qw($Bin);
use Log::Log4perl qw(:easy);
use File::Temp qw(tempfile);
use Fcntl qw(:DEFAULT :mode :flock O_RDONLY);
use Net::CIDR ();
use IPC::Open3;
use Symbol 'gensym';
use Cwd qw(getcwd realpath);
use Text::ParseWords qw(shellwords);
use POSIX (); # fsync

# ---------------- Umask (grundlegend) ----------------
umask 0007;  # Dateien: 0660, Verzeichnisse: 0770 (sofern respektiert)

my $VERSION = '1.6.1';

# ---------------- systemctl (konfigurierbar) ----------------
my $SYSTEMCTL       = '/usr/bin/systemctl';
my $SYSTEMCTL_FLAGS = '';

# ==================================================
# Logging-Setup & Konfiguration laden
# ==================================================
my $globalfile  = "$Bin/global.json";
my $configsfile = "$Bin/configs.json";
die "global.json fehlt\n"  unless -f $globalfile;
die "configs.json fehlt\n" unless -f $configsfile;

sub read_all {
  my ($path) = @_;
  open my $fh, '<:raw', $path or die "Kann $path nicht lesen: $!";
  local $/; my $data = <$fh>;
  close $fh;
  return $data;
}

my $global  = eval { decode_json(read_all($globalfile)) };
die "global.json ungültig: $@" if $@ || ref($global) ne 'HASH';

my $configs = eval { decode_json(read_all($configsfile)) };
die "configs.json ungültig: $@" if $@ || ref($configs) ne 'HASH';

# systemctl aus Config/ENV übernehmen (optional)
$SYSTEMCTL       = $global->{systemctl}       if defined $global->{systemctl}       && $global->{systemctl} ne '';
$SYSTEMCTL_FLAGS = exists $ENV{SYSTEMCTL_FLAGS} ? $ENV{SYSTEMCTL_FLAGS}
                  : (defined $global->{systemctl_flags} ? $global->{systemctl_flags} : '');


# ---------------- Logging ----------------
my $logfile = $global->{logfile} // "/var/log/mmbb/config-manager.log";
my $logdir  = dirname($logfile);
die "Log-Verzeichnis fehlt: $logdir\n" unless -d $logdir;
my $logconf = qq(
  log4perl.rootLogger = INFO, LOG
  log4perl.appender.LOG = Log::Log4perl::Appender::File
  log4perl.appender.LOG.filename = $logfile
  log4perl.appender.LOG.mode = append
  log4perl.appender.LOG.utf8 = 1
  log4perl.appender.LOG.layout = Log::Log4perl::Layout::PatternLayout
  log4perl.appender.LOG.layout.ConversionPattern = %d %-5p %m%n
);
Log::Log4perl->init(\$logconf);
my $logger = Log::Log4perl->get_logger();


# ---- Mojolicious Secrets (optional) ----
my $sec = $global->{secret};
my @secrets = ref($sec) eq 'ARRAY' ? @$sec : ($sec // 'change-this-long-random-secret-please');
app->secrets(\@secrets);
# Warnen, falls das Default-Secret aktiv ist (nur Logging)
if (grep { defined($_) && $_ eq 'change-this-long-random-secret-please' } @secrets) {
  $logger->warn('[config-manager] WARNING: default Mojolicious secret in use - please set a long random secret in global.json');
}



# ==================================================
# Security & Verzeichnisse
# ==================================================
my $api_token   = defined $ENV{API_TOKEN} && $ENV{API_TOKEN} ne '' ? $ENV{API_TOKEN} : $global->{api_token};
my $allowed_ips = $global->{allowed_ips};
$allowed_ips = [] unless ref($allowed_ips) eq 'ARRAY';

my $tmpDir     = $global->{tmpDir}     // "$Bin/tmp";
my $backupRoot = $global->{backupDir}  // "$Bin/backup";
die "Backup-Verzeichnis fehlt: $backupRoot\n" unless -d $backupRoot;
die "Tmp-Verzeichnis fehlt: $tmpDir\n"       unless -d $tmpDir;

my $maxBackups = $global->{maxBackups} // 10;

# -------- Pfad-Guard (abschaltbar) --------
# path_guard: "off" | "audit" | "enforce"     (default: off)
# allowed_roots: ["/etc/...", ...]              (nur für audit/enforce)
my $path_guard = lc($ENV{PATH_GUARD} // ($global->{path_guard} // 'off'));

# allowed_roots: beim Boot kanonisieren + deduplizieren
my @ALLOWED_CANON = ();
if (ref($global->{allowed_roots}) eq 'ARRAY') {
  my %seen;
  for my $r (@{ $global->{allowed_roots} }) {
    for my $cr (_canon_root($r)) {     # 0 oder 1 Eintrag
      next if $seen{$cr}++;
      push @ALLOWED_CANON, $cr;
    }
  }
}

# optional: ins Log, was effektiv gilt
if (@ALLOWED_CANON) {
  $logger->info('ALLOWED_ROOTS='.join(',', @ALLOWED_CANON));
} else {
  $logger->info('ALLOWED_ROOTS=(leer)');
}


# Optionales Verhalten
my $apply_meta_enabled         = $global->{apply_meta}           // 0;  # globaler Default
my $auto_create_backup_subdirs = $global->{auto_create_backups}  // 0;  # Verzeichnisse automatisch anlegen?
my $fsync_dir_enabled          = $global->{fsync_dir}            // 0;  # Parent-Verzeichnis fsync nach rename


# -------- Canonicalisierung für allowed_roots & Pfade (robust) --------
sub _canon_root {
  my ($p) = @_;
  return () unless defined $p && length $p;

  my $rp = realpath($p);
  return () unless defined $rp && length $rp;

  # trailing slash erzwingen (präziser Präfix-Vergleich: /etc/ ≠ /etc2/)
  $rp =~ s{/*$}{};
  $rp .= '/';
  return $rp;
}

sub _canon_dir_of_path {
  my ($p) = @_;
  return () unless defined $p && length $p;

  # existierende Datei → realpath(file), sonst → realpath(dirname(file))
  my $rp = -e $p ? realpath($p) : realpath(dirname($p));
  return () unless defined $rp && length $rp;

  $rp =~ s{/*$}{};
  $rp .= '/';
  return $rp;
}


# ==================================================
# Hilfsfunktionen (Security, FS, Ownership)
# ==================================================
sub _mode_str {
  my ($path) = @_;
  return undef unless -e $path;
  my $m = (stat($path))[2];
  return sprintf('%04o', S_IMODE($m));
}

sub _cur_umask {
  my $o = umask();
  umask($o); # restore
  return $o;
}

sub _fsync_dir {
  return unless $fsync_dir_enabled;
  my ($path) = @_;
  my $dir = dirname($path);
  sysopen(my $dh, $dir, O_RDONLY) or return; # best effort
  POSIX::fsync(fileno($dh));
  close $dh;
}

sub _is_allowed_path {
  my ($p) = @_;

  # Symlink am Ziel hart verbieten (Defense-in-Depth)
  return 0 if -l $p;

  # Guard vollständig aus
  return 1 if $path_guard eq 'off';

  # Keine allowed_roots definiert?
  # (Im audit-Mode erlauben wir, aber loggen einen Warnhinweis; in enforce → verbieten)
  return ($path_guard eq 'audit')
    ? do { $logger->warn("PATH-GUARD audit: keine allowed_roots definiert"); 1 }
    : 0
    unless @ALLOWED_CANON;

  # Kanonische Basis (Datei oder Elternverzeichnis)
  my $dircanon = _canon_dir_of_path($p);
  return 0 unless $dircanon;  # Pfad nicht auflösbar

  # Präziser Präfix-Vergleich (mit trailing slash)
  for my $root (@ALLOWED_CANON) {
    return 1 if ($dircanon eq $root) || (index($dircanon, $root) == 0);
  }

  if ($path_guard eq 'audit') {
    $logger->warn("PATH-GUARD audit: $p außerhalb allowed_roots (dircanon=$dircanon)");
    return 1;
  }
  return 0; # enforce
}


sub _name2uid { my ($n)=@_; return undef unless defined $n && length $n; return $n =~ /^\d+$/ ? 0+$n : scalar((getpwnam($n))[2]); }
sub _name2gid { my ($n)=@_; return undef unless defined $n && length $n; return $n =~ /^\d+$/ ? 0+$n : scalar((getgrnam($n))[2]); }

sub _apply_meta {
  my ($e,$path) = @_;

  # Auto-enable, wenn user/group/mode gesetzt
  my $auto_wanted = (defined $e->{user} || defined $e->{group} || defined $e->{mode}) ? 1 : 0;
  my $enabled = defined $e->{apply_meta} ? $e->{apply_meta} : ($apply_meta_enabled || $auto_wanted);

  unless ($enabled) { $logger->info("APPLY_META skipped (disabled) path=$path"); return; }

  die "Pfad nicht erlaubt" unless _is_allowed_path($path);
  die "refuse symlink" if -l $path;

  my $uid = _name2uid($e->{user});
  my $gid = _name2gid($e->{group});

  my $mode;
  if (defined $e->{mode}) {
    my $m = "$e->{mode}";
    $m =~ s/^0+//;                       # 0640 -> 640
    die "ungültiger mode" unless $m =~ /^[0-7]{3,4}$/;
    $mode = oct($m);
  }

  if (defined $uid || defined $gid) {
    my $u = defined($uid) ? $uid : -1;
    my $g = defined($gid) ? $gid : -1;
    chown($u, $g, $path) or die "chown failed: $!";
  }
  chmod($mode, $path) if defined $mode;
}

# Backup-Unterordner je Config (kollisionsfrei)
sub _backup_dir_for {
  my ($name) = @_;
  my $sub = $name;
  $sub =~ s{[^A-Za-z0-9._-]+}{_}g;
  return "$backupRoot/$sub";
}

# ==================================================
# Konfigurations-Mapping (configs.json) — Actions-Normalisierung
# ==================================================
my %cfgmap;

sub _derive_actions {
  my ($entry) = @_;
  my %actions;

  if (ref($entry->{actions}) eq 'HASH') {
    while (my ($k,$v)=each %{$entry->{actions}}) { $actions{$k} = (ref($v) eq 'ARRAY') ? [@$v] : []; }
    return \%actions;
  }
  if (ref($entry->{commands}) eq 'HASH') {
    while (my ($k,$v)=each %{$entry->{commands}}) { $actions{$k} = (ref($v) eq 'ARRAY') ? [@$v] : []; }
    return \%actions;
  }
  if (ref($entry->{command_args}) eq 'HASH') {
    my @tokens = ref($entry->{commands}) eq 'ARRAY' ? @{$entry->{commands}} : keys %{$entry->{command_args}};
    for my $t (@tokens) { my $arr = $entry->{command_args}{$t}; $actions{$t} = (ref($arr) eq 'ARRAY') ? [@$arr] : []; }
    return \%actions;
  }
  if (ref($entry->{commands}) eq 'ARRAY' && grep { $_ eq 'run' } @{$entry->{commands}}) {
    $actions{run} = [];
  }
  return \%actions;
}

sub _rebuild_cfgmap_from {
  my ($cfg) = @_;
  %cfgmap = ();
  while (my ($name,$entry) = each %{$cfg}) {
    next if !defined $name || $name =~ m{[/\\]} || $name =~ m{\.\.};

    my $actions = _derive_actions($entry);
    my $path    = $entry->{path};

    $cfgmap{$name} = {
      %$entry,
      id         => $name,
      service    => $entry->{service}  // $name,
      category   => $entry->{category} // 'uncategorized',
      path       => $path,
      actions    => $actions,
      backup_dir => _backup_dir_for($name),
      # legacy Felder (Anzeige/Audit)
      commands      => $entry->{commands},
      command_args  => $entry->{command_args},
    };
  }
}
_rebuild_cfgmap_from($configs);

$logger->info(sprintf('BOOT version=%s umask=%04o path_guard=%s apply_meta_default=%d',
  $VERSION, _cur_umask(), $path_guard, $apply_meta_enabled?1:0));

# ==================================================
# Request-Helfer & Access-Control
# ==================================================
sub _req_meta {
  my ($c) = @_;
  return {
    req_id => $c->stash('req_id') // '',
    ip     => $c->stash('client_ip') // '',
    method => $c->req->method // '',
    path   => $c->req->url->path->to_string // '',
    ua     => $c->req->headers->user_agent // '',
  };
}

sub _fmt_req {
  my ($c) = @_;
  my $m = _req_meta($c);
  return sprintf('req_id=%s ip=%s %s %s', $m->{req_id}, $m->{ip}, $m->{method}, $m->{path});
}

# Trusted Proxies (optional)
my %TRUSTED = map { $_ => 1 } (
  ref($global->{trusted_proxies}) eq 'ARRAY' ? @{$global->{trusted_proxies}} : ()
);

sub _client_ip {
  my ($c) = @_;
  my $rip = $c->tx->remote_address // '';
  if ($TRUSTED{$rip}) {
    my $xff = $c->req->headers->header('X-Forwarded-For') // '';
    if ($xff) {
      my @ips = map { s/^\s+|\s+$//gr } split /,/, $xff; # erste ist original client
      return $ips[0] // $rip;
    }
  }
  return $rip;
}

# CORS: optional erlaubte Origins
my %ALLOW_ORIGIN = map { $_ => 1 } (
  ref($global->{allow_origins}) eq 'ARRAY' ? @{$global->{allow_origins}} : ()
);

app->hook(before_dispatch => sub {
  my $c = shift;

  $c->stash(req_id => sprintf('%x-%x', int(time()*1000), $$));
  $c->stash(t0     => time());
  $c->stash(client_ip => _client_ip($c));

  my $origin = $c->req->headers->origin // '*';
  if (%ALLOW_ORIGIN) {
    $c->res->headers->header('Access-Control-Allow-Origin' => ($ALLOW_ORIGIN{$origin} ? $origin : 'null'));
  } else {
    $c->res->headers->header('Access-Control-Allow-Origin' => $origin);
  }
  $c->res->headers->header('Access-Control-Allow-Methods' => 'GET, POST, DELETE, OPTIONS');
  $c->res->headers->header('Access-Control-Allow-Headers' => 'Content-Type, X-API-Token, Authorization');
  $c->res->headers->header('Access-Control-Max-Age'       => '86400');
  $c->res->headers->header('Vary'                         => 'Origin');
  $c->res->headers->header('X-Content-Type-Options' => 'nosniff');
  $c->res->headers->header('X-Frame-Options'        => 'DENY');
  $c->res->headers->header('Referrer-Policy'        => 'no-referrer');
  if ($c->req->is_secure) {
    $c->res->headers->header('Strict-Transport-Security' => 'max-age=31536000; includeSubDomains');
  }
  

  $logger->info(sprintf('REQ  %s', _fmt_req($c)));
  return $c->render(text => '', status => 204) if $c->req->method eq 'OPTIONS';

  # IP-ACL
  if ($allowed_ips && @{$allowed_ips}) {
    my $rip = $c->stash('client_ip') // '';
    unless (Net::CIDR::cidrlookup($rip, @{$allowed_ips})) {
      $logger->info(sprintf('REQ  %s -> 403 Forbidden', _fmt_req($c)));
      return $c->render(status => 403, json => { ok=>0, error => 'Forbidden' });
    }
  }

  # Token-Auth (Header X-API-Token oder Bearer)
  if (defined $api_token && length $api_token) {
    my $hdr     = $c->req->headers->header('X-API-Token') // '';
    my $auth    = $c->req->headers->authorization // '';
    my $bearer  = $auth =~ /^Bearer\s+(.+)/i ? $1 : '';
    my $token   = $hdr || $bearer;
    unless ($token eq $api_token) {
      $logger->info(sprintf('REQ  %s -> 401 Unauthorized', _fmt_req($c)));
      return $c->render(status => 401, json => { ok=>0, error => 'Unauthorized' });
    }
  }
});

app->hook(after_dispatch => sub {
  my $c = shift;
  my $t0 = $c->stash('t0') // time();
  my $dt = time() - $t0;
  my $code = $c->res->code // 200;
  my $bytes = $c->res->headers->content_length;
  $bytes = length($c->res->body // '') unless defined $bytes;
  $logger->info(sprintf('RESP %s status=%d time=%.3fs bytes=%d', _fmt_req($c), $code, $dt, $bytes));
});

# ==================================================
# I/O-Helfer (Atomic Write, Plain Fallback)
# ==================================================
sub write_atomic {
  my ($path, $bytes) = @_;
  my $dir = dirname($path);

  my ($fh, $tmp) = tempfile('.tmp_XXXXXX', DIR => $dir, UNLINK => 0);
  binmode($fh, ':raw') or die "binmode failed: $!";
  print {$fh} $bytes or die "write failed: $!";
  eval { $fh->flush() if $fh->can('flush'); 1 };
  eval { $fh->sync()  if $fh->can('sync');  1 };
  close $fh or die "close failed: $!";

  # Tempfile-Mode auf umask-basierten Mode setzen (z.B. 0660 bei umask 0007)
  my $mode = 0666 & ~_cur_umask();
  chmod $mode, $tmp or die "chmod($tmp) failed: $!";

  rename $tmp, $path or die "rename failed: $!";
  _fsync_dir($path);
  return 'atomic';
}

sub safe_write_file {
  my ($path, $bytes) = @_;
  my $method = 'atomic';
  my $ok = eval { write_atomic($path, $bytes); 1 };
  if (!$ok) {
    $method = 'plain';
    open my $fh, '>:raw', $path or die "plain open failed: $!";
    print {$fh} $bytes or die "plain write failed: $!";
    eval { $fh->flush() if $fh->can('flush'); 1 };
    eval { $fh->sync()  if $fh->can('sync');  1 };
    close $fh or die "plain close failed: $!";
  }
  return $method;
}

# ==================================================
# ROUTES
# ==================================================
get '/' => sub { shift->render(json => { ok=>1, name=>'config-manager', version=>$VERSION }) };

# Liste der Konfigurationen (Metadaten)
get '/configs' => sub {
  my $c = shift;
  my @list;
  for my $name (sort keys %cfgmap) {
    my $e = $cfgmap{$name};
    my $filename = $e->{path} =~ m{/([^/]+)$} ? $1 : $e->{path};
    my ($ext) = $filename =~ /\.([^.]+)$/;
    my $actions = $e->{actions} // {};
    my @tokens  = sort keys %{$actions};
    push @list, {
      id=>$name, filename=>$filename, filetype=>lc($ext // 'txt'),
      category=>$e->{category}, actions=>\@tokens
    };
  }
  $c->res->headers->content_type('application/json');
  $c->render(json => { ok=>1, configs => \@list });
};

# Datei-Inhalt abrufen
get '/config/*name' => sub {
  my $c = shift;
  my $name = $c->stash('name');
  return $c->render(json=>{ok=>0,error=>'Ungültiger Name'}, status=>400)
    if $name =~ m{[/\\]} || $name =~ m{\.\.};
  my $e = $cfgmap{$name} or return $c->render(json=>{ok=>0,error=>"Unbekannte Konfiguration: $name"}, status=>404);
  my $p = $e->{path};
  return $c->render(json=>{ok=>0,error=>"Pfad nicht erlaubt"}, status=>400) unless _is_allowed_path($p);
  $logger->info(sprintf('READ %s name=%s path=%s', _fmt_req($c), $name, $p));
  return $c->render(json=>{ok=>0,error=>"Datei $p nicht vorhanden"}, status=>404) unless -f $p;
  open my $fh, "<:raw", $p or return $c->render(json=>{ok=>0,error=>"Kann Datei nicht lesen: $!"}, status=>500);
  my $data = do { local $/; <$fh> }; close $fh;
  $c->res->headers->content_type('application/octet-stream');
  $c->render(data => $data);
};

# Datei speichern (+ Backup)
post '/config/*name' => sub {
  my $c = shift;
  my $name = $c->stash('name');
  return $c->render(json=>{ok=>0,error=>'Ungültiger Name'}, status=>400)
    if $name =~ m{[/\\]} || $name =~ m{\.\.};
  my $e = $cfgmap{$name} or return $c->render(json=>{ok=>0,error=>"Unbekannte Konfiguration: $name"}, status=>404);

  my $path  = $e->{path};
  return $c->render(json=>{ok=>0,error=>"Pfad nicht erlaubt"}, status=>400) unless _is_allowed_path($path);
  $logger->info(sprintf('SAVE begin %s name=%s path=%s', _fmt_req($c), $name, $path));

  my $content = $c->req->body // '';
  if (($c->req->headers->content_type // '') =~ m{application/json}i) {
    my $j = eval { $c->req->json };
    if (!$@ && ref($j) eq 'HASH' && exists $j->{content}) { $content = $j->{content} // ''; }
  }

  # Backup in Subdir je Config
  my $bdir = $e->{backup_dir};
  if (!-d $bdir) {
    if ($auto_create_backup_subdirs) {
      mkdir $bdir or return $c->render(json=>{ok=>0,error=>"Backup-Verzeichnis konnte nicht angelegt werden: $!"}, status=>500);
    } else {
      return $c->render(json=>{ok=>0,error=>"Backup-Verzeichnis fehlt: $bdir"}, status=>500);
    }
  }

  if (-f $path) {
    my $ts = localtime->strftime('%Y%m%d_%H%M%S');
    my $bfile = "$bdir/".basename($path).".bak.$ts";
    copy($path, $bfile) or return $c->render(json=>{ok=>0,error=>"Backup fehlgeschlagen: $!"}, status=>500);
    $logger->info("SAVE backup $bfile");
    my @b = sort { $b cmp $a } grep { defined } glob("$bdir/".basename($path).".bak.*");
    if (@b > $maxBackups) { unlink @b[$maxBackups..$#b]; }
  }

  my $method;
  eval { $method = safe_write_file($path, $content); 1 } or return $c->render(json=>{ok=>0,error=>"Kann Datei nicht speichern: $@"}, status=>500);

  # Loggen, ob Meta angewendet würde
  my $meta_wanted = defined $e->{apply_meta} ? $e->{apply_meta}
                  : ($apply_meta_enabled || defined($e->{user}) || defined($e->{group}) || defined($e->{mode}));
  $logger->info("SAVE meta_wanted=".($meta_wanted?1:0)." user=".($e->{user}//'')." group=".($e->{group}//'')." mode=".($e->{mode}//''));

  # Optional: apply_meta (Owner/Mode)
  eval { _apply_meta($e, $path); 1 } or do { $logger->warn("apply_meta Fehler: $@"); };

  my $applied_mode = _mode_str($path);
  my ($uid,$gid)   = ((stat($path))[4], (stat($path))[5]);
  my $size         = -s $path;

  $logger->info(sprintf('SAVE done %s method=%s size=%s mode=%s', _fmt_req($c), ($method//'unknown'), ($size//'?'), ($applied_mode//'----')));

  $c->render(json => {
    ok=>1,
    saved     => $name, path => $path, method => $method,
    requested => { user=>$e->{user}, group=>$e->{group}, mode=>$e->{mode}, apply_meta => ($meta_wanted ? JSON::MaybeXS::true : JSON::MaybeXS::false) },
    applied   => { uid=>$uid, gid=>$gid, mode=>$applied_mode }
  });
};

# Liste der Backups (Dateinamen)
get '/backups/*name' => sub {
  my $c = shift;
  my $name = $c->stash('name');
  return $c->render(json=>{ok=>0,error=>'Ungültiger Name'}, status=>400) if $name =~ m{[/\\]} || $name =~ m{\.\.};
  my $e = $cfgmap{$name} or return $c->render(json=>{ok=>0,error=>"Unbekannte Konfiguration: $name"}, status=>404);
  my $bdir = $e->{backup_dir};
  return $c->render(json=>{ok=>0,error=>"Backup-Verzeichnis fehlt: $bdir"}, status=>500) unless -d $bdir;
  my $base = basename($e->{path});
  my @files = sort { $b cmp $a } grep { defined } glob("$bdir/$base.bak.*");
  @files = map { s{^\Q$bdir\E/}{}r } @files;
  $c->render(json => { ok=>1, backups => \@files });
};

# Download der Backup-Datei
get '/backupfile/*name/*filename' => sub {
  my $c = shift;
  my $name = $c->stash('name');
  my $filename = $c->stash('filename');
  return $c->render(json=>{ok=>0,error=>'Ungültiger Name/Filename'}, status=>400)
    if $name =~ m{[/\\]} || $name =~ m{\.\.} || $filename =~ m{[/\\]} || $filename =~ m{\.\.};

  my $e = $cfgmap{$name} or return $c->render(json=>{ok=>0,error=>"Unbekannte Konfiguration: $name"}, status=>404);
  my $bdir = $e->{backup_dir};
  my $base = basename($e->{path});
  return $c->render(json=>{ok=>0,error=>'Ungültiger Backup-Name'}, status=>400)
    unless $filename =~ /^\Q$base\E\.bak\.\d{8}_\d{6}$/;

  my $file = "$bdir/$filename";
  return $c->render(json=>{ok=>0,error=>'Backup nicht gefunden'}, status=>404) unless -f $file;

  $c->res->headers->content_type('application/octet-stream');
  $c->res->headers->content_disposition("attachment; filename=\"$filename\"");
  return $c->reply->file($file);
};

# Inhalt der Backup-Datei als Text (Preview)
get '/backupcontent/*name/*filename' => sub {
  my $c = shift;
  my $name = $c->stash('name');
  my $filename = $c->stash('filename');
  return $c->render(json=>{ok=>0,error=>'Ungültiger Name/Filename'}, status=>400)
    if $name =~ m{[/\\]} || $name =~ m{\.\.} || $filename =~ m{[/\\]} || $filename =~ m{\.\.};

  my $e = $cfgmap{$name} or return $c->render(json=>{ok=>0,error=>"Unbekannte Konfiguration: $name"}, status=>404);
  my $bdir = $e->{backup_dir};
  my $base = basename($e->{path});
  return $c->render(json=>{ok=>0,error=>'Ungültiger Backup-Name'}, status=>400)
    unless $filename =~ /^\Q$base\E\.bak\.\d{8}_\d{6}$/;

  my $file = "$bdir/$filename";
  return $c->render(json=>{ok=>0,error=>'Backup nicht gefunden'}, status=>404) unless -f $file;

  open my $fh, '<:raw', $file or return $c->render(json=>{ok=>0,error=>"Die Backup-Datei konnte nicht geöffnet werden: $!"}, status=>500);
  my $content = do { local $/; <$fh> }; close $fh;
  $c->render(json => { ok=>1, content => $content });
};

# Restore: Backup → Ziel
post '/restore/*name/*filename' => sub {
  my $c = shift;
  my $name = $c->stash('name');
  my $filename = $c->stash('filename');
  return $c->render(json=>{ok=>0,error=>'Ungültiger Name/Filename'}, status=>400)
    if $name =~ m{[/\\]} || $name =~ m{\.\.} || $filename =~ m{[/\\]} || $filename =~ m{\.\.};

  my $e = $cfgmap{$name} or return $c->render(json=>{ok=>0,error=>"Unbekannte Konfiguration: $name"}, status=>404);
  my $base = basename($e->{path});
  my $bdir = $e->{backup_dir};
  return $c->render(json=>{ok=>0,error=>'Ungültiger Backup-Name'}, status=>400)
    unless $filename =~ /^\Q$base\E\.bak\.\d{8}_\d{6}$/;

  my $src  = "$bdir/$filename";
  my $dest = $e->{path};
  return $c->render(json=>{ok=>0,error=>'Backup nicht gefunden'}, status=>404) unless -f $src;
  return $c->render(json=>{ok=>0,error=>'Pfad nicht erlaubt'}, status=>400) unless _is_allowed_path($dest);

  $logger->info(sprintf('RESTORE begin %s name=%s from=%s dest=%s', _fmt_req($c), $name, $src, $dest));

  copy($src, $dest) or return $c->render(json=>{ok=>0,error=>"Wiederherstellung fehlgeschlagen: $!"}, status=>500);

  # Optional: apply_meta nach Restore
  eval { _apply_meta($e, $dest); 1 } or do { $logger->warn("apply_meta Fehler: $@"); };

  my $applied_mode = _mode_str($dest);
  my ($uid,$gid)   = ((stat($dest))[4], (stat($dest))[5]);

  $logger->info("RESTORE done $filename -> $dest");

  my $meta_wanted = defined $e->{apply_meta} ? $e->{apply_meta}
                  : ($apply_meta_enabled || defined($e->{user}) || defined($e->{group}) || defined($e->{mode}));

  $c->render(json => {
    ok=>1,
    restored  => $name, from => $filename,
    requested => { user=>$e->{user}, group=>$e->{group}, mode=>$e->{mode}, apply_meta => ($meta_wanted ? JSON::MaybeXS::true : JSON::MaybeXS::false) },
    applied   => { uid=>$uid, gid=>$gid, mode=>$applied_mode }
  });
};

# Service-/Job-Aktionen (actions) + Unit-Steuerung
post '/action/*name/*cmd' => sub {
  my $c = shift;
  my ($name, $cmd) = ($c->stash('name'), $c->stash('cmd'));

  return $c->render(json=>{ok=>0,error=>'Ungültiger Name/Befehl'}, status=>400)
    if !defined $name || !defined $cmd || $name =~ m{[/\\]} || $name =~ m{\.\.} || $cmd  =~ m{[/\\]} || $cmd  =~ m{\.\.};

  my $tool  = $SYSTEMCTL;
  my $flags = $SYSTEMCTL_FLAGS // '';
  my @ctl = ($tool, shellwords($flags));

  $logger->info(sprintf('ACTION begin %s name=%s cmd=%s', _fmt_req($c), $name, $cmd));

  # Globaler systemctl-Aufruf ohne Dienst (Kompatibilität)
  if ($cmd eq 'daemon-reload') {
    my $rc = system(@ctl, 'daemon-reload');
    $logger->info("ACTION systemctl daemon-reload rc=$rc");
    return $rc == 0
      ? $c->render(json=>{ok=>1, action=>'daemon-reload', status=>'ok'})
      : $c->render(json=>{ok=>0,error=>"daemon-reload fehlgeschlagen (rc=$rc)"}, status=>500);
  }

  # Konfig-Eintrag laden
  my $e = $cfgmap{$name} or return $c->render(json=>{ok=>0,error=>"Unbekannte Konfiguration: $name"}, status=>404);
  my $svc = $e->{service} // $name;

  # Whitelist (actions)
  my $actmap = $e->{actions};
  return $c->render(json=>{ok=>0,error=>'Aktion nicht erlaubt'}, status=>400)
    unless (ref($actmap) eq 'HASH' && exists $actmap->{$cmd});

  my $raw_args = $actmap->{$cmd};
  return $c->render(json=>{ok=>0,error=>"actions[$cmd] muss Array sein"}, status=>400)
    unless ref($raw_args) eq 'ARRAY';

  my @extra = @$raw_args;
  for my $a (@extra) {
    return $c->render(json=>{ok=>0,error=>"Ungültiges Argument in actions[$cmd]"}, status=>400)
      unless defined $a && $a =~ /^[A-Za-z0-9._:+@\/=\-,]+$/;
  }

  # Runner (bash:/..., perl:/..., exec:/...) — nutzt @extra
  if ($svc =~ m{^(bash|sh|perl|exec):(/.+)$}) {
    my ($runner, $script) = ($1, $2);

    return $c->render(json=>{ok=>0,error=>'Script-Pfad muss absolut sein'}, status=>400) unless $script =~ m{^/};
    return $c->render(json=>{ok=>0,error=>"Script nicht gefunden: $script"}, status=>404) unless -f $script;
    if ($runner eq 'exec') {
      return $c->render(json=>{ok=>0,error=>"Binary nicht ausführbar: $script"}, status=>400) unless -x $script;
    } else {
      return $c->render(json=>{ok=>0,error=>"Script nicht lesbar: $script"}, status=>400) unless -r $script;
    }

    # Guardrails für exec:.../systemctl
    my $is_systemctl_exec = ($runner eq 'exec' && $script =~ m{/systemctl$});
    if ($is_systemctl_exec) {
      my %deny = map { $_ => 1 } qw(
        poweroff reboot halt kexec rescue emergency default isolate exit switch-root
        set-environment unset-environment
      );
      my $sub = $extra[0] // '';
      return $c->render(json=>{ok=>0,error=>'Subcommand verboten'}, status=>400) if $deny{$sub};

      if (($e->{category} // '') eq 'service' && $cmd =~ /^(start|restart|reload|stop_start)$/) {
        my $rc = system($SYSTEMCTL, shellwords($SYSTEMCTL_FLAGS // ''), 'daemon-reload');
        $logger->info("ACTION auto daemon-reload (exec:systemctl) rc=$rc");
        return $c->render(json=>{ok=>0,error=>"daemon-reload (auto) fehlgeschlagen (rc=$rc)"},
                          status=>500) unless $rc == 0;
      }
    }

    my @argv =
        $runner eq 'perl' ? ('/usr/bin/perl', $script, @extra)
      : ($runner eq 'bash' || $runner eq 'sh') ? ('/bin/bash', $script, @extra)
      : ($runner eq 'exec') ? ($script, @extra)
      : return $c->render(json=>{ok=>0,error=>"Unbekannter Runner: $runner"}, status=>400);

    my $cwd_prev = getcwd();
    my ($script_dir) = $script =~ m{^(.+)/[^/]+$};
    chdir $script_dir if defined $script_dir;

    $logger->info(sprintf('SCRIPT begin %s runner=%s script=%s args=%s', _fmt_req($c), $runner, $script, (join(' ', @extra) || '-')));

    my $start = time();
    my $timeout = ($global->{script_timeout} && $global->{script_timeout} =~ /^\d+$/)
       ? 0 + $global->{script_timeout} : 60;
    my $err = gensym;
    my ($out_r, $pid, $buf_out, $buf_err) = (undef, undef, '', '');

    eval {
      $pid = open3(undef, $out_r, $err, @argv);
      local $SIG{ALRM} = sub { die "timeout\n" };
      alarm $timeout;

      while (1) {
        my $rin = '';
        vec($rin, fileno($out_r), 1) = 1 if $out_r && defined fileno($out_r);
        vec($rin, fileno($err),  1) = 1 if $err   && defined fileno($err);
        my $n = select($rin, undef, undef, 1);
        last if $n <= 0;

        my $tmp;
        if ($out_r && vec($rin, fileno($out_r), 1)) {
          my $r = sysread($out_r, $tmp, 8192);
          $buf_out .= $tmp if defined $r && $r > 0;
        }
        if ($err && vec($rin, fileno($err), 1)) {
          my $r = sysread($err, $tmp, 8192);
          $buf_err .= $tmp if defined $r && $r > 0;
        }
        my $eof_out = ($out_r && defined fileno($out_r)) ? eof($out_r) : 1;
        my $eof_err = ($err   && defined fileno($err))   ? eof($err)   : 1;
        last if $eof_out && $eof_err;
      }

      waitpid($pid, 0);
      alarm 0;
      close $out_r if $out_r;
      close $err   if $err;
      1;
    } or do {
      my $err_msg = $@ // 'unknown';
      kill 9, $pid if $pid;
      waitpid($pid, 0) if $pid;
      chdir $cwd_prev if defined $cwd_prev;
      my $dur = time() - $start;
      if ($err_msg =~ /timeout/) {
        $logger->warn(sprintf('SCRIPT timeout %s runner=%s script=%s after=%.3fs', _fmt_req($c), $runner, $script, $dur));
        return $c->render(json=>{ok=>0,error=>"Script timeout nach ${timeout}s"}, status=>504);
      } else {
        $logger->warn(sprintf('SCRIPT failed %s runner=%s script=%s after=%.3fs err=%s', _fmt_req($c), $runner, $script, $dur, $err_msg));
        return $c->render(json=>{ok=>0,error=>"Script-Ausführung fehlgeschlagen: $err_msg"}, status=>500);
      }
    };

    chdir $cwd_prev if defined $cwd_prev;

    my $status = $?; my $rc=$status>>8; my $dur = time()-$start;

    my $MAX = 65536;
    my $out_show = length($buf_out) > $MAX ? (substr($buf_out,0,$MAX)."...[truncated]") : $buf_out;
    my $err_show = length($buf_err) > $MAX ? (substr($buf_err,0,$MAX)."...[truncated]") : $buf_err;

    $logger->info(sprintf('SCRIPT done %s rc=%d time=%.3fs bytes_out=%d bytes_err=%d', _fmt_req($c), $rc, $dur, length($buf_out), length($buf_err)));

    # Optional: Status normalisieren für exec:systemctl is-active (kein zweiter system()-Call)
    if ($is_systemctl_exec) {
      my $sub = $extra[0] // '';
      if ($sub eq 'is-active' && defined $extra[1]) {
        my $u = $extra[1];
        my $status2 = ($rc == 0) ? 'running' : 'stopped';
        return $c->render(json=>{ok=>1, action=>"exec-systemctl $cmd", unit=>$u, status=>$status2, rc=>$rc});
      }
    }

  my $ok = ($rc == 0) ? 1 : 0;
  
  return $c->render(json=>{
    ok     => $ok,
    action => 'script',
    runner => $runner,
    script => $script,
    args   => \@extra,
    rc     => $rc,
    stdout => $out_show,
    stderr => $err_show,
  });

  # Sonderfall: "service":"systemctl" — Subcommand ohne Unit
  if ($svc eq 'systemctl') {
    return $c->render(json=>{ok=>0,error=>'Ungültiger systemctl-Subcommand'}, status=>400) unless $cmd =~ /^[A-Za-z0-9._:@-]+$/;
    my %deny = map { $_ => 1 } qw(poweroff reboot halt kexec rescue emergency set-environment unset-environment default isolate exit switch-root);
    return $c->render(json=>{ok=>0,error=>'Subcommand verboten'}, status=>400) if $deny{$cmd};
    my $rc = system($SYSTEMCTL, shellwords($SYSTEMCTL_FLAGS // ''), $cmd);
    $logger->info("ACTION systemctl $cmd rc=$rc");
    return $rc == 0
      ? $c->render(json=>{ok=>1, action=>"systemctl $cmd", status=>'ok'})
      : $c->render(json=>{ok=>0,error=>"systemctl $cmd fehlgeschlagen (rc=$rc)"} , status=>500);
  }

  # Echte Dienste mit Unit-Namen
  my $run = sub { my ($subcmd) = @_; system($SYSTEMCTL, shellwords($SYSTEMCTL_FLAGS // ''), $subcmd, $svc) == 0 };

  my $is_service_cat = ( ($e->{category} // '') eq 'service' );
  my $cmd_triggers   = ($cmd =~ /^(start|restart|reload|stop_start)$/);
  if ($is_service_cat && $cmd_triggers) {
    my $rc = system($SYSTEMCTL, shellwords($SYSTEMCTL_FLAGS // ''), 'daemon-reload');
    $logger->info("ACTION auto daemon-reload for category=service svc=$svc rc=$rc");
    return $c->render(json=>{ok=>0,error=>"daemon-reload (auto) fehlgeschlagen (rc=$rc)"}, status=>500) unless $rc == 0;
  }

  if ($cmd eq 'stop_start') {
    $run->('stop')   or return $c->render(json=>{ok=>0,error=>'Stop fehlgeschlagen'}, status=>500);
    $run->('start')  or return $c->render(json=>{ok=>0,error=>'Start fehlgeschlagen'}, status=>500);
    my $active = system($SYSTEMCTL, shellwords($SYSTEMCTL_FLAGS // ''), 'is-active', $svc) == 0;
    $logger->info("ACTION $svc stop_start active=".($active?1:0));
    return $active ? $c->render(json=>{ok=>1,action=>'stop_start',status=>'running'})
                   : $c->render(json=>{ok=>0,error=>'Dienst nicht aktiv nach stop_start'}, status=>500);
  }
  elsif ($cmd eq 'restart') {
    $run->('restart') or return $c->render(json=>{ok=>0,error=>'Restart fehlgeschlagen'}, status=>500);
    my $active = system($SYSTEMCTL, shellwords($SYSTEMCTL_FLAGS // ''), 'is-active', $svc) == 0;
    $logger->info("ACTION $svc restart active=".($active?1:0));
    return $active ? $c->render(json=>{ok=>1,action=>'restart',status=>'running'})
                   : $c->render(json=>{ok=>0,error=>'Dienst nicht aktiv nach restart'}, status=>500);
  }
  elsif ($cmd eq 'status') {
    my $active = system($SYSTEMCTL, shellwords($SYSTEMCTL_FLAGS // ''), 'is-active', $svc) == 0;
    $logger->info("ACTION $svc status=".($active?'running':'stopped'));
    return $c->render(json=>{ok=>1,action=>'status',status=>($active?'running':'stopped')});
  }
  elsif ($cmd eq 'reload') {
    # Idempotentes Verhalten: Ist die Unit nicht aktiv, ist reload ein NOOP (kein 500)
    my $active = system($SYSTEMCTL, shellwords($SYSTEMCTL_FLAGS // ''), 'is-active', $svc) == 0;
    unless ($active) {
      $logger->info("ACTION $svc reload noop (inactive)");
      return $c->render(json=>{
        ok=>1, action=>'reload', status=>'stopped', note=>'inactive - reload skipped'
      });
    }
    # Unit ist aktiv -> reguläres reload
    $run->('reload') or return $c->render(json=>{ok=>0,error=>"Reload fehlgeschlagen"}, status=>500);
    $logger->info("ACTION $svc reload ok=1");
    return $c->render(json=>{ok=>1,action=>'reload',status=>'ok'});
  }
  elsif ($cmd =~ /^(start|stop)$/) {
    $run->($cmd) or return $c->render(json=>{ok=>0,error=>"Aktion $cmd fehlgeschlagen"}, status=>500);
    $logger->info("ACTION $svc $cmd ok=1");
    return $c->render(json=>{ok=>1,action=>$cmd,status=>'ok'});
  }
  else {
    return $c->render(json=>{ok=>0,error=>"Unbekannter Befehl: $cmd"}, status=>400);
  }
};

# Rohzugriff auf configs.json (lesen)
get '/raw/configs' => sub {
  my $c = shift;
  my $json = read_all($configsfile);
  $c->res->headers->content_type('application/json');
  $c->render(data => $json);
};

# Rohzugriff auf configs.json (schreiben)
post '/raw/configs' => sub {
  my $c = shift;
  my $newdata = $c->req->body // '';
  my $parsed;
  eval { $parsed = decode_json($newdata); 1 } or return $c->render(status=>400, json=>{ok=>0,error=>"Ungültiges JSON: $@"});
  return $c->render(status=>400, json=>{ok=>0,error=>'JSON muss ein Objekt (HASH) sein'}) unless ref($parsed) eq 'HASH';

  eval {
    write_atomic($configsfile, $newdata);   # ← einzig relevante Änderung
    1
  } or do {
    return $c->render(status=>500, json=>{ok=>0,error=>"Fehler beim Schreiben: $@"});
  };

  _rebuild_cfgmap_from($parsed);
  $c->render(json => { ok=>1, saved => 1, reload => 1 });
};


# configs.json neu laden (ohne schreiben)
post '/raw/configs/reload' => sub {
  my $c = shift;
  my $json = read_all($configsfile);
  my $cfg = eval { decode_json($json) } or return $c->render(json=>{ok=>0,error=>'Ungültiges JSON im File'}, status=>500);
  return $c->render(json=>{ok=>0,error=>'configs.json muss ein Objekt (HASH) sein'}, status=>500) unless ref($cfg) eq 'HASH';
  _rebuild_cfgmap_from($cfg);
  $c->render(json => { ok=>1, reloaded => 1 });
};

# configs.json: Eintrag löschen
del '/raw/configs/:name' => sub {
  my $c = shift;
  my $name = $c->stash('name');
  my $json = read_all($configsfile);
  my $cfg = eval { decode_json($json) } or return $c->render(status=>400, json=>{ok=>0,error=>"Ungültiges JSON: $@"});
  return $c->render(status=>400, json=>{ok=>0,error=>'configs.json muss ein Objekt (HASH) sein'}) unless ref($cfg) eq 'HASH';
  return $c->render(status=>404, json=>{ok=>0,error=>"Eintrag $name existiert nicht"}) unless exists $cfg->{$name};

  delete $cfg->{$name};
  my $new = encode_json($cfg);

  eval {
    write_atomic($configsfile, $new);       # ← hier ersetzen
    1
  } or return $c->render(status=>500, json=>{ok=>0,error=>"Fehler beim Schreiben: $@"});

  _rebuild_cfgmap_from($cfg);
  $c->render(json => { ok=>1, deleted => $name, reload => 1 });
};


# Health-Check
get '/health' => sub {
  my $c = shift;
  my @missing;
  push @missing, "Backup-Verzeichnis fehlt: $backupRoot" unless -d $backupRoot;
  push @missing, "Tmp-Verzeichnis fehlt: $tmpDir"       unless -d $tmpDir;
  for my $name (sort keys %cfgmap) {
    my $f = $cfgmap{$name}{path};
    push @missing, "$name → fehlt: $f" unless -f $f;
    if ($path_guard ne 'off' && ! _is_allowed_path($f)) {
      push @missing, "$name → Pfad nicht erlaubt (Guard=$path_guard): $f";
    }
    my $bd = $cfgmap{$name}{backup_dir};
    push @missing, "$name → Backup-Dir fehlt: $bd" unless -d $bd;
  }
  return @missing ? $c->render(json=>{ok=>0,error=>join('; ',@missing)}, status=>503)
                  : $c->render(json=>{ok=>1, status=>'ok'});
};

# Catch-all
any '/*whatever' => sub {
  my $c = shift;
  $c->render(json=>{ok=>0,error=>"Unbekannte Route: ".$c->req->method." ".$c->req->url->to_string}, status=>404);
};

# ==================================================
# Start
# ==================================================
my $listen_url;
if ($global->{ssl_enable} && $global->{ssl_cert_file} && $global->{ssl_key_file}) {
  $listen_url = "https://$global->{listen}?cert=$global->{ssl_cert_file}&key=$global->{ssl_key_file}";
  $logger->info("HTTPS: $listen_url");
} else {
  $listen_url = "http://$global->{listen}";
  $logger->info("HTTP: $listen_url");
}

app->start('daemon','-l',$listen_url);
