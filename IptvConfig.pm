package IptvConfig;
use strict;
use warnings;
use Socket qw(inet_aton inet_ntoa);
use Fcntl qw(:DEFAULT :flock);
use Exporter 'import';
our @EXPORT_OK=qw(load_config ipv4 allowed_ip parse_url write_state read_state);
sub ipv4 {
 my ($v)=@_; return undef unless defined($v) && $v =~ /\A\d{1,3}(?:\.\d{1,3}){3}\z/;
 my @n=split(/\./,$v); return undef if grep { $_>255 || (length($_)>1 && /^0/) } @n;
 return unpack('N',pack('C4',@n));
}
sub allowed_ip {
 my ($ip,$cidrs)=@_;my $n=ipv4($ip);return 0 unless defined $n;
 for my $c(split(/,/,$cidrs||'')) {
  my($a,$p)=split('/',$c);next unless defined($p)&&$p =~ /^\d+$/&&$p<=32;
  my $v=ipv4($a);next unless defined $v;my $m=$p?((0xffffffff << (32-$p)) & 0xffffffff):0;
  return 1 if ($n & $m)==($v & $m);
 } return 0;
}
sub load_config {
 my($file)=@_;my @st=stat($file);die "config_missing\n" unless @st;
 die "config_permissions_require_0600\n" if ($st[2]&077)!=0 || ($st[4] != $< && $st[4] != 0);
 open(my $f,'<',$file) or die "config_unreadable\n";my %c;
 while(<$f>){s/\r?\n$//;next if /^\s*(?:#|$)/;die "invalid_config_line\n" unless /^([A-Z][A-Z0-9_]*)=(.*)$/;die "duplicate_config_key\n" if exists $c{$1};$c{$1}=$2;}
 close($f);return \%c;
}
sub parse_url {
 my($url,$cidrs,$ports)=@_;
 die "invalid_rtsp_url\n" unless $url =~ m{\Artsp://([0-9.]+)(?::([0-9]+))?(/[^\s\r\n#]*)\z};
 my($h,$p,$path)=($1,$2||554,$3);
 die "upstream_not_allowed\n" unless allowed_ip($h,$cidrs) && grep { $_ eq "$p" } split(',',$ports);
 die "invalid_upstream_port\n" if $p<1||$p>65535;return($h,0+$p,$path);
}
sub write_state {
 my($file,$data)=@_;my $tmp="$file.$$";
 sysopen(my $f,$tmp,O_WRONLY|O_CREAT|O_EXCL,0600) or die "state_create_failed\n";
 print $f map { "$_=$data->{$_}\n" } sort keys %$data;close($f) or die "state_write_failed\n";
 rename($tmp,$file) or die "state_rename_failed\n";
}
sub read_state { my($f)=@_;return {} unless -e $f;return load_config($f); }
1;
