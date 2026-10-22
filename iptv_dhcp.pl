#!/usr/bin/perl
# MIT. Captured identity is local configuration, never generated or logged here.
use strict;
use warnings;
use Socket;
use IO::Select;
BEGIN { my $d=__FILE__; $d =~ s{[^/]+$}{};unshift @INC,($d||'.'); }
use IptvConfig qw(load_config ipv4 write_state);
sub opt {my($n,$v)=@_;die "option_too_long\n" if length($v)>255;return pack('CC',$n,length($v)).$v;}
sub packet {
 my($mode,$xid,$mac,$identity,$host,$ip,$server)=@_;
 die "invalid_identity\n" unless length($xid)==4&&length($mac)==6&&length($identity)>=1&&length($identity)<=255&&length($host)<=255;
 my $ci=$mode eq 'renew'?inet_aton($ip):pack('N',0);
 my $v=pack('CCCC',1,1,6,0).$xid.pack('nn',0,0x8000).$ci.pack('NNN',0,0,0).$mac.("\0"x202).pack('N',0x63825363);
 $v.=opt(53,pack('C',$mode eq 'discover'?1:3)).opt(55,pack('C*',1,3,51,54,58,59)).opt(57,pack('n',1500));
 $v.=opt(12,$host) if length($host);$v.=opt(60,$identity).opt(61,"\x01".$mac);
 $v.=opt(50,inet_aton($ip)).opt(54,inet_aton($server)) if $mode eq 'request';
 return $v."\xff";
}
sub decode {
 my($v,$xid,$mac)=@_;return undef unless length($v)>=240 && substr($v,0,4) eq pack('CCCC',2,1,6,0) && substr($v,4,4) eq $xid && substr($v,28,6) eq $mac && substr($v,236,4) eq pack('N',0x63825363);
 my %o;my $pos=240;
 while($pos<length($v)){my $n=ord(substr($v,$pos++,1));last if $n==255;next if $n==0;return undef if $pos>=length($v);my $len=ord(substr($v,$pos++,1));return undef if $pos+$len>length($v)||exists($o{$n});$o{$n}=substr($v,$pos,$len);$pos+=$len;}
 return undef unless exists($o{53})&&length($o{53})==1;
 my $type=ord($o{53});return {TYPE=>6} if $type==6;
 return undef unless ($type==2||$type==5)&&defined($o{54})&&length($o{54})==4;
 my $ip=inet_ntoa(substr($v,16,4));return undef if !ipv4($ip)||ipv4($ip)>=0xe0000000;
 my %r=(TYPE=>$type,IP=>$ip,SERVER=>inet_ntoa($o{54}));
 for my $k(1,51,58){return undef if exists($o{$k})&&length($o{$k})!=4;}
 if(exists $o{1}){my $bits=sprintf('%032b',unpack('N',$o{1}));return undef unless $bits=~/^1+0*$/;$r{PREFIX}=length(($bits=~/^(1*)/)[0]);}
 if(exists $o{3}){return undef if !length($o{3})||length($o{3})%4;$r{GATEWAY}=inet_ntoa(substr($o{3},0,4));}
 $r{SECONDS}=unpack('N',$o{51}) if exists $o{51};$r{T1}=unpack('N',$o{58}) if exists $o{58};return \%r;
}
sub acquire {
 my($c,$renew,$mock)=@_;my $iface=$c->{IPTV_INTERFACE}||'';die "invalid_interface\n" unless $iface=~/\A[A-Za-z0-9_.:-]{1,15}\z/;
 my $hex=$c->{STB_MAC_HEX}||'';my $id=$c->{OPTION60_HEX}||'';my $host=$c->{DHCP_HOSTNAME}||'';
 die "invalid_stb_mac\n" unless $hex=~/\A[0-9a-fA-F]{12}\z/&&!(hex(substr($hex,0,2))&1)&&$hex ne '000000000000';
 die "invalid_option60_hex\n" unless $id=~/\A(?:[0-9a-fA-F]{2}){1,255}\z/;
 die "invalid_hostname\n" if length($host)>255||$host=~/[^\x21-\x7e]/;
 my $mac=pack('H*',$hex);my $identity=pack('H*',$id);
 open(my $random,'<','/dev/urandom') or die "random_unavailable\n";read($random,my $xid,4)==4 or die "random_unavailable\n";close $random;
 socket(my $s,PF_INET,SOCK_DGRAM,getprotobyname('udp')) or die "dhcp_socket_failed\n";
 setsockopt($s,SOL_SOCKET,SO_BROADCAST,pack('i',1)) or die "broadcast_option_failed\n";
 my($listen_port,$server_port,$dest)=(68,67,'255.255.255.255');
 if($mock){($listen_port,$server_port,$dest)=(0,$c->{MOCK_DHCP_PORT}||0,'127.0.0.1');die "invalid_mock_port\n" unless $server_port=~/^\d+$/&&$server_port>1024&&$server_port<=65535;}
 else {die "dhcp_live_requires_linux_root\n" unless $^O eq 'linux' && $<==0;
  # Linux SO_BINDTODEVICE=25. Failure is fatal: never fall back to another interface.
  setsockopt($s,SOL_SOCKET,25,"$iface\0") or die "bind_to_interface_failed\n";
 }
 bind($s,sockaddr_in($listen_port,inet_aton($mock?'127.0.0.1':'0.0.0.0'))) or die "dhcp_bind_failed\n";
 my $wait=3;my $sel=IO::Select->new($s);
 my $receive=sub {
  my($wanted,$server)=@_;my $end=time()+$wait;
  while(time()<$end){next unless $sel->can_read($end-time());recv($s,my $buf,8192,0) or next;my $r=decode($buf,$xid,$mac);next unless $r;die "dhcp_nak\n" if $r->{TYPE}==6;next unless $r->{TYPE}==$wanted;next if defined($server)&&$r->{SERVER} ne $server;return $r;}return undef;
 };
 my $send=sub{my($mode,$ip,$server)=@_;my $v=packet($mode,$xid,$mac,$identity,$host,$ip,$server);send($s,$v,0,sockaddr_in($server_port,inet_aton($dest))) or die "dhcp_send_failed\n";};
 my $ack;
 for(1..3){
  if($renew){die "invalid_renew_address\n" unless ipv4($renew);$send->('renew',$renew,undef);$ack=$receive->(5,undef);}
  else {$send->('discover',undef,undef);my $offer=$receive->(2,undef);next unless $offer;$send->('request',$offer->{IP},$offer->{SERVER});$ack=$receive->(5,$offer->{SERVER});die "ack_address_mismatch\n" if $ack&&$ack->{IP} ne $offer->{IP};}
  last if $ack;
 }
 close $s;die "dhcp_timeout\n" unless $ack;
 die "incomplete_lease\n" unless defined($ack->{PREFIX})&&$ack->{GATEWAY}&&($ack->{SECONDS}||0)>=30&&$ack->{SECONDS}<=604800;
 $ack->{T1}=int($ack->{SECONDS}/2) unless ($ack->{T1}||0)>0&&$ack->{T1}<$ack->{SECONDS};
 delete $ack->{TYPE};$ack->{ACQUIRED}=time();return $ack;
}
sub main {
 my($cfg,$output,$renew,$mock);while(@ARGV){my $a=shift @ARGV;if($a eq '--config'){$cfg=shift @ARGV}elsif($a eq '--output'){$output=shift @ARGV}elsif($a eq '--renew'){$renew=shift @ARGV}elsif($a eq '--mock-loopback'){$mock=1}else{die "usage: iptv_dhcp.pl --config FILE --output LEASE [--renew IP] [--mock-loopback]\n"}}
 die "config_and_output_required\n" unless $cfg&&$output;my $c=load_config($cfg);my $lease=acquire($c,$renew,$mock);write_state($output,$lease);print "lease_acquired\n";
}
main() unless caller;
1;
